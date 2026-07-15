import Foundation
import Network
import OSLog

private let controlChannelLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "RemoteCamPreview",
    category: "ControlChannel"
)

enum ControlChannelError: LocalizedError, CustomNSError {
    case timedOut(operation: String, seconds: Int)

    static var errorDomain: String { "RemoteCamPreview.ControlChannel" }

    var errorCode: Int { 1_001 }

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let seconds):
            "控制通道在\(seconds)秒内未完成：\(operation)。"
        }
    }

    var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: errorDescription ?? "控制通道超时。",
            NSUnderlyingErrorKey: URLError(.timedOut)
        ]
    }
}

actor ControlChannel {
    private var connection: NetworkConnection<WebSocket>?
    private var requestOrder: [String] = []
    private var requestBodies: [String: Data] = [:]
    private var initialHelloInFlight = false
    private let maximumRememberedRequestIds = 1_024

    func attach(_ connection: NetworkConnection<WebSocket>) {
        self.connection = connection
        requestOrder.removeAll(keepingCapacity: true)
        requestBodies.removeAll(keepingCapacity: true)
        initialHelloInFlight = false
        controlChannelLogger.notice("Attached WebSocket; initial state=\(Self.stateDescription(connection.state), privacy: .public)")
    }

    func detach() {
        if let connection {
            controlChannelLogger.notice("Detaching WebSocket; final state=\(Self.stateDescription(connection.state), privacy: .public)")
        } else {
            controlChannelLogger.debug("Detach requested without an attached WebSocket")
        }
        connection = nil
        requestOrder.removeAll(keepingCapacity: true)
        requestBodies.removeAll(keepingCapacity: true)
        initialHelloInFlight = false
    }

    func send(_ message: ControlMessage) async throws {
        guard let connection else {
            controlChannelLogger.error("Cannot send \(message.type, privacy: .public): no attached WebSocket")
            throw ControlProtocolError.noConnection
        }
        controlChannelLogger.debug("Preparing to send \(message.type, privacy: .public)")
        let body = try ControlMessageCodec.encode(message)
        guard let text = String(data: body, encoding: .utf8) else {
            throw ControlProtocolError.malformedMessage
        }

        // NetworkConnection is lazy: the first send/receive starts a one-to-one connection.
        // Waiting for `.ready` before issuing any I/O leaves it in `.setup` forever.
        let isEstablishing = connection.state != .ready
        if isEstablishing {
            controlChannelLogger.notice(
                "Starting control data path with first send type=\(message.type, privacy: .public) state=\(Self.stateDescription(connection.state), privacy: .public)"
            )
        }
        try await withTimeout(
            .seconds(5),
            operationName: isEstablishing
                ? "建立 Wi-Fi Aware 控制数据路径并发送 \(message.type)"
                : "发送 \(message.type)",
            seconds: 5
        ) {
            try await connection.send(text)
        }
        if isEstablishing {
            controlChannelLogger.notice(
                "Initial control send completed state=\(Self.stateDescription(connection.state), privacy: .public)"
            )
        }
        if message.type == "session.hello" || message.type == "session.accepted" {
            controlChannelLogger.notice("Sent \(message.type, privacy: .public)")
        } else {
            controlChannelLogger.debug("Sent \(message.type, privacy: .public)")
        }
    }

    func run(
        onMessage: @escaping @Sendable (ControlMessage) async -> Void = { _ in }
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.runReceiveLoop(onMessage: onMessage) }
            group.addTask { try await self.runHeartbeatLoop() }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Server-side entry point. The capture endpoint must not originate an application heartbeat
    /// or accept any other command until the monitor identifies the session with its first hello.
    func runServer(
        onMessage: @escaping @Sendable (ControlMessage) async -> Void
    ) async throws {
        controlChannelLogger.notice("Server receive loop waiting for initial session.hello")
        let first = try await receiveMessage(
            timeout: .seconds(5),
            operation: "等待首个 session.hello",
            seconds: 5
        )
        guard first.type == "session.hello" else {
            controlChannelLogger.error("Rejected initial control message type=\(first.type, privacy: .public); expected session.hello")
            throw ControlProtocolError.malformedMessage
        }
        guard try observe(first) == .new else { throw ControlProtocolError.malformedMessage }
        initialHelloInFlight = true
        controlChannelLogger.notice("Received initial session.hello")
        let initialHelloTask = Task { [weak self] in
            await onMessage(first)
            await self?.initialHelloDidFinish()
        }
        defer {
            initialHelloTask.cancel()
            initialHelloInFlight = false
        }
        try await run(onMessage: onMessage)
    }

    private func runReceiveLoop(
        onMessage: @escaping @Sendable (ControlMessage) async -> Void
    ) async throws {
        guard let connection else { throw ControlProtocolError.noConnection }

        while !Task.isCancelled {
            _ = connection // Keep the selected connection stable for this receive loop.
            let message = try await receiveMessage(
                timeout: .seconds(7),
                operation: "等待控制消息或心跳",
                seconds: 7
            )
            if try observe(message) == .duplicate {
                controlChannelLogger.debug("Received duplicate \(message.type, privacy: .public)")
                // session.hello has a cached response at the controller; other identical events
                // are already complete and remain side-effect free when silently acknowledged.
                if message.type == "session.hello", !initialHelloInFlight {
                    await onMessage(message)
                }
                continue
            }
            controlChannelLogger.debug("Received \(message.type, privacy: .public)")
            await onMessage(message)
        }
    }

    private func receiveMessage(
        timeout: Duration,
        operation: String,
        seconds: Int
    ) async throws -> ControlMessage {
        guard let connection else { throw ControlProtocolError.noConnection }
        let frame = try await withTimeout(
            timeout,
            operationName: operation,
            seconds: seconds
        ) {
            try await connection.receive()
        }
        guard frame.metadata.opcode == .text else {
            controlChannelLogger.error("Received non-text WebSocket frame while \(operation, privacy: .public)")
            throw ControlProtocolError.malformedMessage
        }
        return try ControlMessageCodec.decode(frame.content)
    }

    private func observe(_ message: ControlMessage) throws -> RequestObservation {
        let canonical = try ControlMessageCodec.encode(message)
        if let existing = requestBodies[message.requestId] {
            guard existing == canonical else { throw ControlProtocolError.malformedMessage }
            return .duplicate
        }
        requestOrder.append(message.requestId)
        requestBodies[message.requestId] = canonical
        if requestOrder.count > maximumRememberedRequestIds {
            let overflow = requestOrder.count - maximumRememberedRequestIds
            let removed = Array(requestOrder.prefix(overflow))
            requestOrder.removeFirst(overflow)
            for requestId in removed { requestBodies[requestId] = nil }
        }
        return .new
    }

    private func runHeartbeatLoop() async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            try await send(.heartbeatPing())
        }
    }

    private func initialHelloDidFinish() {
        initialHelloInFlight = false
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operationName: String,
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                controlChannelLogger.error(
                    "Timed out after \(seconds)s: \(operationName, privacy: .public)"
                )
                throw ControlChannelError.timedOut(
                    operation: operationName,
                    seconds: seconds
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func stateDescription(_ state: NetworkConnection<WebSocket>.State) -> String {
        switch state {
        case .setup:
            "setup"
        case .preparing:
            "preparing"
        case .ready:
            "ready"
        case .waiting(let error):
            "waiting(\(error.localizedDescription))"
        case .failed(let error):
            "failed(\(error.localizedDescription))"
        case .cancelled:
            "cancelled"
        @unknown default:
            "unknown"
        }
    }
}

private enum RequestObservation {
    case new
    case duplicate
}
