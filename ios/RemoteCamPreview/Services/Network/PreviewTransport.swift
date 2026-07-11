import Foundation
import Network
import WiFiAware

struct PreviewListenerAdvertisement: Sendable {
    var rtpPort: UInt16
    var rtcpPort: UInt16
    var rtpService: String?
    var rtcpService: String?
}

struct PreviewNetworkConfiguration: Sendable {
    var destinationAddress: String
    var rtpPort: UInt16
    var rtcpPort: UInt16
    var payloadType: UInt8
    var mediaSSRC: UInt32
    var maximumRTPPacketSize: Int
    var rtpService: String?
    var rtcpService: String?
}

enum PreviewTransportError: LocalizedError {
    case missingAwarePeer
    case missingServiceDeclaration
    case invalidNegotiation
    case listenerTimedOut
    case connectionTimedOut
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingAwarePeer: "无法识别当前 Wi-Fi Aware 对端。"
        case .missingServiceDeclaration: "实时预览的 Wi-Fi Aware 服务没有在 Info.plist 中声明。"
        case .invalidNegotiation: "实时预览网络参数无效。"
        case .listenerTimedOut: "RTP/RTCP 监听端点启动超时。"
        case .connectionTimedOut: "RTP/RTCP 数据路径连接超时。"
        case .notConnected: "RTP 实时预览通道尚未连接。"
        }
    }
}

@MainActor
final class PreviewTransport {
    var onRTPPacket: (@MainActor (RTPPacket) -> Void)?
    var onKeyFrameRequested: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private var rtpListener: NetworkListener<UDP>?
    private var rtcpListener: NetworkListener<UDP>?
    private var rtpConnection: NetworkConnection<UDP>?
    private var rtcpConnection: NetworkConnection<UDP>?
    private var rtpListenerTask: Task<Void, Never>?
    private var rtcpListenerTask: Task<Void, Never>?
    private var rtpReceiveTask: Task<Void, Never>?
    private var rtcpSendTask: Task<Void, Never>?
    private var sendDrainTask: Task<Void, Never>?
    private var sendQueue: [Data] = []
    private var receiverSSRC = UInt32.random(in: 1 ... .max)
    private var mediaSSRC: UInt32?
    private var expectedPayloadType: UInt8?
    private var maximumPacketSize = 1_200
    private var receiveStatistics = RTPReceiveStatistics()
    private var lastPLIAt: ContinuousClock.Instant?

    func prepareCamera(
        peer: WAPairedDevice,
        rtpPublishableService: WAPublishableService?,
        rtcpPublishableService: WAPublishableService?,
        rtpServiceName: String,
        rtcpServiceName: String,
        mediaSSRC: UInt32,
        payloadType: UInt8,
        maximumPacketSize: Int
    ) async throws -> PreviewListenerAdvertisement {
        stop()
        self.mediaSSRC = mediaSSRC
        expectedPayloadType = payloadType
        self.maximumPacketSize = maximumPacketSize

        let rtpProvider: WAPublisherListener
        let rtcpProvider: WAPublisherListener
        let advertisedRTPService: String?
        let advertisedRTCPService: String?
        if #available(iOS 26.4, *) {
            rtpProvider = .wifiAware(.addingConnections(from: .selected([peer])))
            rtcpProvider = .wifiAware(.addingConnections(from: .selected([peer])))
            advertisedRTPService = nil
            advertisedRTCPService = nil
        } else {
            guard let rtpPublishableService, let rtcpPublishableService else {
                throw PreviewTransportError.missingServiceDeclaration
            }
            rtpProvider = .wifiAware(.connecting(
                to: rtpPublishableService,
                from: .selected([peer]),
                datapath: .realtime
            ))
            rtcpProvider = .wifiAware(.connecting(
                to: rtcpPublishableService,
                from: .selected([peer]),
                datapath: .realtime
            ))
            advertisedRTPService = rtpServiceName
            advertisedRTCPService = rtcpServiceName
        }

        let parameters = Self.parameters
        let rtpListener = try NetworkListener<UDP>(for: rtpProvider, using: parameters)
            .newConnectionLimit(1)
        let rtcpListener = try NetworkListener<UDP>(for: rtcpProvider, using: parameters)
            .newConnectionLimit(1)
        self.rtpListener = rtpListener
        self.rtcpListener = rtcpListener

        rtpListenerTask = Task { [weak self] in
            do {
                try await rtpListener.run { connection in
                    guard let self else { return }
                    self.rtpConnection = connection
                    self.startSendDrainIfNeeded()
                    // Keep the accepted datagram flow alive until the session is cancelled.
                    while !Task.isCancelled {
                        _ = try await connection.receive()
                    }
                }
            } catch is CancellationError {
                // Session ended normally.
            } catch {
                self?.onError?(error)
            }
        }

        rtcpListenerTask = Task { [weak self] in
            do {
                try await rtcpListener.run { connection in
                    guard let self else { return }
                    self.rtcpConnection = connection
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        guard message.content.count <= RTCP.maximumDatagramSize,
                              let mediaSSRC = self.mediaSSRC
                        else { continue }
                        if try RTCP.containsPictureLossIndication(
                            message.content,
                            expectedMediaSSRC: mediaSSRC
                        ) {
                            self.onKeyFrameRequested?()
                        }
                    }
                }
            } catch is CancellationError {
                // Session ended normally.
            } catch RTCPError.unsupportedPacket {
                // Ignore RTCP feedback types not negotiated by v1.
            } catch {
                self?.onError?(error)
            }
        }

        let ports = try await waitForPorts(rtpListener: rtpListener, rtcpListener: rtcpListener)
        return PreviewListenerAdvertisement(
            rtpPort: ports.rtp,
            rtcpPort: ports.rtcp,
            rtpService: advertisedRTPService,
            rtcpService: advertisedRTCPService
        )
    }

    func connectMonitor(
        peer: WAPairedDevice,
        controlRemoteEndpoint: NWEndpoint?,
        configuration: PreviewNetworkConfiguration,
        rtpSubscribableService: WASubscribableService?,
        rtcpSubscribableService: WASubscribableService?
    ) async throws {
        stop()
        guard (96 ... 127).contains(configuration.payloadType),
              configuration.mediaSSRC != 0,
              (256 ... 65_507).contains(configuration.maximumRTPPacketSize)
        else { throw PreviewTransportError.invalidNegotiation }

        mediaSSRC = configuration.mediaSSRC
        expectedPayloadType = configuration.payloadType
        maximumPacketSize = min(configuration.maximumRTPPacketSize, 1_500)
        receiverSSRC = UInt32.random(in: 1 ... .max)

        let endpoints: (rtp: WAEndpoint, rtcp: WAEndpoint)
        if #available(iOS 26.4, *),
           let controlRemoteEndpoint,
           let rtpPort = NWEndpoint.Port(rawValue: configuration.rtpPort),
           let rtcpPort = NWEndpoint.Port(rawValue: configuration.rtcpPort),
           let rtp = controlRemoteEndpoint.wifiAware(port: rtpPort),
           let rtcp = controlRemoteEndpoint.wifiAware(port: rtcpPort) {
            endpoints = (rtp, rtcp)
        } else {
            guard configuration.rtpService != nil,
                  configuration.rtcpService != nil,
                  let rtpSubscribableService,
                  let rtcpSubscribableService
            else { throw PreviewTransportError.missingServiceDeclaration }
            async let rtp = discover(service: rtpSubscribableService, peer: peer)
            async let rtcp = discover(service: rtcpSubscribableService, peer: peer)
            endpoints = try await (rtp, rtcp)
        }

        let parameters = Self.parameters
        let rtpConnection = NetworkConnection<UDP>(to: endpoints.rtp, using: parameters)
        let rtcpConnection = NetworkConnection<UDP>(to: endpoints.rtcp, using: parameters)
        self.rtpConnection = rtpConnection
        self.rtcpConnection = rtcpConnection

        rtpReceiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await rtpConnection.receive()
                    guard let self,
                          message.content.count <= self.maximumPacketSize,
                          let expectedPayloadType = self.expectedPayloadType,
                          let mediaSSRC = self.mediaSSRC
                    else { continue }
                    do {
                        let packet = try RTPPacket(
                            encoded: message.content,
                            maximumPacketSize: self.maximumPacketSize
                        )
                        guard packet.payloadType == expectedPayloadType,
                              packet.ssrc == mediaSSRC
                        else { continue }
                        let gapDetected = self.receiveStatistics.ingest(packet)
                        self.onRTPPacket?(packet)
                        if gapDetected { self.requestKeyFrame() }
                    } catch {
                        self.requestKeyFrame()
                    }
                }
            } catch is CancellationError {
                // Session ended normally.
            } catch {
                self?.onError?(error)
            }
        }

        rtcpSendTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, let report = self.makeReceiverReport() else { return }
                    try await rtcpConnection.send(report)
                    try await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {
                // Session ended normally.
            } catch {
                self?.onError?(error)
            }
        }

        // A Wi-Fi Aware UDP listener does not surface a flow until the initiator sends a datagram.
        // This bounded probe creates the RTP flow; the capture endpoint consumes it before sending RTP.
        try await rtpConnection.send(Data("RCP1".utf8))
        try await waitForConnections(rtp: rtpConnection, rtcp: rtcpConnection)
    }

    func sendRTP(_ packet: RTPPacket) {
        guard packet.encoded().count <= maximumPacketSize else { return }
        guard sendQueue.count < 512 else {
            // A blocked sender must not grow memory or latency without bound.
            sendQueue.removeAll(keepingCapacity: true)
            return
        }
        sendQueue.append(packet.encoded())
        startSendDrainIfNeeded()
    }

    func requestKeyFrame() {
        guard let mediaSSRC, let rtcpConnection else { return }
        let now = ContinuousClock.now
        if let lastPLIAt, now - lastPLIAt < .milliseconds(250) { return }
        lastPLIAt = now
        let packet = RTCP.pictureLossIndication(senderSSRC: receiverSSRC, mediaSSRC: mediaSSRC)
        Task { [weak self] in
            do { try await rtcpConnection.send(packet) }
            catch { self?.onError?(error) }
        }
    }

    func stop() {
        rtpListenerTask?.cancel()
        rtcpListenerTask?.cancel()
        rtpReceiveTask?.cancel()
        rtcpSendTask?.cancel()
        sendDrainTask?.cancel()
        rtpListenerTask = nil
        rtcpListenerTask = nil
        rtpReceiveTask = nil
        rtcpSendTask = nil
        sendDrainTask = nil
        rtpListener = nil
        rtcpListener = nil
        rtpConnection = nil
        rtcpConnection = nil
        sendQueue.removeAll(keepingCapacity: false)
        receiveStatistics = RTPReceiveStatistics()
        mediaSSRC = nil
        expectedPayloadType = nil
        lastPLIAt = nil
    }

    private static var parameters: NWParametersBuilder<UDP> {
        NWParametersBuilder.parameters {
            UDP()
        }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.interactiveVideo)
    }

    private func startSendDrainIfNeeded() {
        guard sendDrainTask == nil, rtpConnection != nil, !sendQueue.isEmpty else { return }
        sendDrainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let connection = self.rtpConnection, !self.sendQueue.isEmpty {
                let datagram = self.sendQueue.removeFirst()
                do {
                    try await connection.send(datagram)
                } catch {
                    self.sendQueue.removeAll(keepingCapacity: true)
                    self.onError?(error)
                    break
                }
            }
            self.sendDrainTask = nil
            if !self.sendQueue.isEmpty { self.startSendDrainIfNeeded() }
        }
    }

    private func makeReceiverReport() -> Data? {
        guard let mediaSSRC else { return nil }
        return RTCP.receiverReport(
            senderSSRC: receiverSSRC,
            mediaSSRC: mediaSSRC,
            fractionLost: receiveStatistics.fractionLost,
            cumulativeLost: receiveStatistics.cumulativeLost,
            extendedHighestSequence: receiveStatistics.extendedHighestSequence,
            jitter: receiveStatistics.jitter
        )
    }

    private func waitForPorts(
        rtpListener: NetworkListener<UDP>,
        rtcpListener: NetworkListener<UDP>
    ) async throws -> (rtp: UInt16, rtcp: UInt16) {
        for _ in 0 ..< 400 {
            if let rtp = rtpListener.port?.rawValue,
               let rtcp = rtcpListener.port?.rawValue {
                return (rtp, rtcp)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PreviewTransportError.listenerTimedOut
    }

    private func waitForConnections(
        rtp: NetworkConnection<UDP>,
        rtcp: NetworkConnection<UDP>
    ) async throws {
        for _ in 0 ..< 400 {
            if rtp.state == .ready, rtcp.state == .ready { return }
            if case .failed = rtp.state { throw PreviewTransportError.notConnected }
            if case .failed = rtcp.state { throw PreviewTransportError.notConnected }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PreviewTransportError.connectionTimedOut
    }

    private func discover(service: WASubscribableService, peer: WAPairedDevice) async throws -> WAEndpoint {
        let provider: WASubscriberBrowser = .wifiAware(
            .connecting(to: .selected([peer]), from: service)
        )
        let browser = NetworkBrowser(
            for: provider,
            using: NWParameters.udp.wifiAware { $0.performanceMode = .realtime }
        )
        return try await withThrowingTaskGroup(of: WAEndpoint.self) { group in
            group.addTask {
                try await browser.run { endpoints in
                    guard let endpoint = endpoints.first else { return .continue }
                    return .finish(endpoint)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw PreviewTransportError.connectionTimedOut
            }
            let endpoint = try await group.next()!
            group.cancelAll()
            return endpoint
        }
    }
}

private struct RTPReceiveStatistics {
    private var baseSequence: UInt16?
    private var highestSequence: UInt16?
    private var sequenceCycles: UInt32 = 0
    private var received: UInt32 = 0
    private var lost: Int32 = 0
    private var previousTransit: Int64?
    private var jitterEstimate: Double = 0

    var cumulativeLost: Int32 { lost }
    var extendedHighestSequence: UInt32 {
        sequenceCycles | UInt32(highestSequence ?? 0)
    }
    var jitter: UInt32 { UInt32(max(0, min(Double(UInt32.max), jitterEstimate.rounded()))) }
    var fractionLost: UInt8 {
        guard let baseSequence, let highestSequence else { return 0 }
        let expected = Int64(sequenceCycles | UInt32(highestSequence)) - Int64(baseSequence) + 1
        guard expected > 0 else { return 0 }
        let ratio = Double(max(0, expected - Int64(received))) / Double(expected)
        return UInt8(max(0, min(255, Int((ratio * 256).rounded(.down)))))
    }

    mutating func ingest(_ packet: RTPPacket) -> Bool {
        let sequence = packet.sequenceNumber
        var gapDetected = false
        if baseSequence == nil {
            baseSequence = sequence
            highestSequence = sequence
        } else if let highestSequence {
            let delta = sequence &- highestSequence
            if delta > 0, delta < 0x8000 {
                if sequence < highestSequence { sequenceCycles &+= 1 << 16 }
                if delta > 1 {
                    lost = min(8_388_607, lost + Int32(delta - 1))
                    gapDetected = true
                }
                self.highestSequence = sequence
            }
        }
        received &+= 1

        let arrivalNanoseconds = DispatchTime.now().uptimeNanoseconds
        // A monotonic clock is enough for the RFC 3550 relative-transit calculation.
        let arrival90k = Int64(arrivalNanoseconds / 1_000_000_000 * 90_000)
            + Int64(arrivalNanoseconds % 1_000_000_000) * 90_000 / 1_000_000_000
        let transit = arrival90k - Int64(packet.timestamp)
        if let previousTransit {
            let difference = Double(abs(transit - previousTransit))
            jitterEstimate += (difference - jitterEstimate) / 16
        }
        previousTransit = transit
        return gapDetected
    }
}
