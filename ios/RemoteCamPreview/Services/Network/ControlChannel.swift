import Foundation
import Network

actor ControlChannel {
    private var connection: NetworkConnection<WebSocket>?
    private var requestOrder: [String] = []
    private var requestBodies: [String: Data] = [:]
    private let maximumRememberedRequestIds = 1_024

    func attach(_ connection: NetworkConnection<WebSocket>) {
        self.connection = connection
        requestOrder.removeAll(keepingCapacity: true)
        requestBodies.removeAll(keepingCapacity: true)
    }

    func detach() {
        connection = nil
        requestOrder.removeAll(keepingCapacity: true)
        requestBodies.removeAll(keepingCapacity: true)
    }

    func send(_ message: ControlMessage) async throws {
        guard let connection else { throw ControlProtocolError.noConnection }
        let body = try ControlMessageCodec.encode(message)
        guard let text = String(data: body, encoding: .utf8) else {
            throw ControlProtocolError.malformedMessage
        }

        try await withTimeout(.seconds(5)) {
            try await connection.send(text)
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
        let first = try await receiveMessage(timeout: .seconds(5))
        guard first.type == "session.hello" else {
            throw ControlProtocolError.malformedMessage
        }
        guard try observe(first) == .new else { throw ControlProtocolError.malformedMessage }
        await onMessage(first)
        try await run(onMessage: onMessage)
    }

    private func runReceiveLoop(
        onMessage: @escaping @Sendable (ControlMessage) async -> Void
    ) async throws {
        guard let connection else { throw ControlProtocolError.noConnection }

        while !Task.isCancelled {
            _ = connection // Keep the selected connection stable for this receive loop.
            let message = try await receiveMessage(timeout: .seconds(7))
            if try observe(message) == .duplicate {
                // session.hello has a cached response at the controller; other identical events
                // are already complete and remain side-effect free when silently acknowledged.
                if message.type == "session.hello" { await onMessage(message) }
                continue
            }
            await onMessage(message)
        }
    }

    private func receiveMessage(timeout: Duration) async throws -> ControlMessage {
        guard let connection else { throw ControlProtocolError.noConnection }
        let frame = try await withTimeout(timeout) {
            try await connection.receive()
        }
        guard frame.metadata.opcode == .text else {
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

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum RequestObservation {
    case new
    case duplicate
}
