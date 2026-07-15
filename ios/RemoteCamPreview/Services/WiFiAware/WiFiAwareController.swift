import Foundation
import Network
import Observation
import OSLog
import UIKit
import VideoToolbox
import WiFiAware

private let wifiAwareLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "RemoteCamPreview",
    category: "WiFiAware"
)

@MainActor
@Observable
final class WiFiAwareController {
    enum Event: Sendable {
        case searching
        case connecting
        case connected(peerName: String?)
        case interrupted(reason: String)
        case failed(availability: WiFiAwareAvailability?, reason: String)
        case previewNegotiated(
            configuration: PreviewConfiguration,
            mediaSSRC: UInt32,
            payloadType: UInt8,
            maximumPacketSize: Int
        )
        case previewStarted
        case previewStopped
        case rtpPacket(RTPPacket)
        case keyFrameRequested
        case message(ControlMessage)
        case diagnostic(SessionErrorReport)
    }

    static let serviceName = "_remote-cam._tcp"

    private(set) var pairedDevices: [WAPairedDevice] = []
    private(set) var discoveredEndpoints: [WAEndpoint] = []
    var capturePreviewDimensionsProvider: (() -> PixelDimensions?)?

    private let controlChannel = ControlChannel()
    private let previewTransport = PreviewTransport()
    private let photoResources: PhotoResourceStore
    private var listener: NetworkListener<WebSocket>?
    private var connection: NetworkConnection<WebSocket>?
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var pairedDevicesTask: Task<Void, Never>?
    private var httpListener: NetworkListener<TCP>?
    private var httpTask: Task<Void, Never>?
    private var photoHTTPPort: UInt16?
    private var photoRemoteEndpoint: NWEndpoint?
    private var sessionId: String?
    private var accessToken: String?
    private var negotiatedConfigId: String?
    private var cachedSessionHello: ControlMessage?
    private var cachedSessionAccepted: ControlMessage?

    init(photoResources: PhotoResourceStore = PhotoResourceStore()) {
        self.photoResources = photoResources
    }

    func checkAvailability() -> WiFiAwareAvailability {
        guard WACapabilities.supportedFeatures.contains(.wifiAware) else {
            wifiAwareLogger.error("Wi-Fi Aware capability check failed: feature unsupported")
            return .unsupported
        }
        guard publishableService != nil,
              subscribableService != nil
        else {
            wifiAwareLogger.error("Wi-Fi Aware capability check failed: one or more services are undeclared")
            return .serviceDeclarationMissing
        }
        wifiAwareLogger.notice("Wi-Fi Aware capability and service declaration checks passed")
        observePairedDevices()
        return .available
    }

    func startPublishing(
        to peer: WAPairedDevice,
        localRole: DeviceRole,
        receivePhotos: Bool,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) {
        wifiAwareLogger.notice(
            "Starting control publisher role=\(String(describing: localRole), privacy: .public) peer=\(peer.name ?? "unnamed-peer", privacy: .private(mask: .hash)) receivePhotos=\(receivePhotos)"
        )
        guard let service = publishableService else {
            wifiAwareLogger.error("Cannot start control publisher: service declaration missing")
            eventHandler(.failed(
                availability: .serviceDeclarationMissing,
                reason: "Wi-Fi Aware 服务没有在 Info.plist 中声明。"
            ))
            return
        }

        stopNetworkTasks()
        configurePreviewCallbacks(eventHandler: eventHandler)
        eventHandler(.searching)

        do {
            let provider: WAPublisherListener = .wifiAware(
                .connecting(
                    to: service,
                    from: .selected([peer]),
                    datapath: .realtime
                )
            )
            let parameters = NWParametersBuilder.parameters {
                WebSocket {
                    TCP().noDelay(true).keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
                }
                .maximumMessageSize(ControlMessage.maximumEncodedSize)
                .autoReplyPing(true)
                // WAEndpoint is opaque rather than URL-backed. Network.framework cannot
                // synthesize an HTTP WebSocket opening request for it (nw_ws_create_state
                // reports "unable to create url endpoint"), so coordinated iOS peers begin
                // WebSocket framing directly once the Aware-bound TCP connection is ready.
                .skipHandshake(true)
            }
            .wifiAware { $0.performanceMode = .realtime }
            .serviceClass(.interactiveVideo)

            let listener = try NetworkListener<WebSocket>(for: provider, using: parameters)
                .newConnectionLimit(1)
                .onStateUpdate { _, state in
                    Self.logListenerState(state)
                    switch state {
                    case .waiting:
                        // Aware listeners commonly report ENETDOWN while the selected data path
                        // is being activated, then transition directly to ready. Keep searching.
                        break
                    case .failed(let error):
                        eventHandler(Self.event(for: error))
                    case .cancelled:
                        break
                    case .setup, .ready:
                        break
                    @unknown default:
                        break
                    }
                }
            self.listener = listener

            listenerTask = Task { [weak self] in
                do {
                    wifiAwareLogger.notice("Running Wi-Fi Aware control listener")
                    try await listener.run { connection in
                        guard let self else { return }
                        wifiAwareLogger.notice(
                            "Control listener accepted WebSocket remote=\(Self.destinationDescription(connection.remoteEndpoint), privacy: .private(mask: .hash))"
                        )
                        self.connection = connection
                        self.photoRemoteEndpoint = connection.remoteEndpoint
                        await self.controlChannel.attach(connection)
                        eventHandler(.connected(peerName: Self.peerName(from: connection.remoteEndpoint)))
                        if localRole == .monitor {
                            let id = Self.makeSessionId()
                            self.sessionId = id
                            wifiAwareLogger.notice("Publisher-side monitor sending initial session.hello")
                            try await self.controlChannel.send(.sessionHello(
                                sessionId: id,
                                display: Self.displayCapabilities,
                                receivePhotos: receivePhotos
                            ))
                        }
                        try await self.runControlSession(
                            localRole: localRole,
                            eventHandler: eventHandler
                        )
                    }
                } catch is CancellationError {
                    wifiAwareLogger.notice("Control listener task cancelled")
                } catch {
                    wifiAwareLogger.error(
                        "Control listener session failed: \(Self.errorDescription(error), privacy: .public)"
                    )
                    await self?.controlChannel.detach()
                    self?.invalidateSessionResources()
                    eventHandler(.diagnostic(Self.diagnostic(
                        error,
                        title: "控制连接中断",
                        stage: localRole == .camera ? "拍摄端控制会话" : "监看端控制会话",
                        suggestion: Self.controlSuggestion(for: error)
                    )))
                    eventHandler(.interrupted(reason: error.localizedDescription))
                }
            }
        } catch {
            wifiAwareLogger.fault(
                "Failed to create Wi-Fi Aware control listener: \(Self.errorDescription(error), privacy: .public)"
            )
            eventHandler(.diagnostic(Self.diagnostic(
                error,
                title: "无法启动控制服务",
                stage: "拍摄端 Wi-Fi Aware 监听器",
                suggestion: "确认两台设备已完成系统配对、Wi-Fi 已开启，然后结束会话并重试。"
            )))
            eventHandler(.failed(availability: nil, reason: error.localizedDescription))
        }
    }

    func startBrowsing(
        onEndpointsChanged: @escaping @MainActor ([WAEndpoint]) -> Void,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) {
        wifiAwareLogger.notice("Starting Wi-Fi Aware control service browser")
        guard let service = subscribableService else {
            wifiAwareLogger.error("Cannot start control browser: service declaration missing")
            eventHandler(.failed(
                availability: .serviceDeclarationMissing,
                reason: "Wi-Fi Aware 订阅服务没有声明。"
            ))
            return
        }

        browserTask?.cancel()
        eventHandler(.searching)

        let provider: WASubscriberBrowser = .wifiAware(
            .connecting(to: .userSpecifiedDevices, from: service)
        )
        let parameters = NWParameters.tcp
            .wifiAware { $0.performanceMode = .realtime }
        let browser = NetworkBrowser(for: provider, using: parameters)

        browserTask = Task { [weak self] in
            do {
                try await browser.run { endpoints in
                    wifiAwareLogger.notice("Control browser endpoints changed count=\(endpoints.count)")
                    self?.discoveredEndpoints = endpoints
                    onEndpointsChanged(endpoints)
                }
            } catch is CancellationError {
                wifiAwareLogger.notice("Control browser task cancelled")
            } catch {
                wifiAwareLogger.error(
                    "Control browser failed: \(Self.errorDescription(error), privacy: .public)"
                )
                await self?.controlChannel.detach()
                self?.invalidateSessionResources()
                eventHandler(.diagnostic(Self.diagnostic(
                    error,
                    title: "发现对端失败",
                    stage: "Wi-Fi Aware 服务发现",
                    suggestion: "让发布端保持在等待页面，确认两台设备的系统配对仍有效后重试。"
                )))
                eventHandler(.interrupted(reason: error.localizedDescription))
            }
        }
    }

    func connect(
        to endpoint: WAEndpoint,
        localRole: DeviceRole,
        receivePhotos: Bool,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) {
        wifiAwareLogger.notice(
            "Connecting control WebSocket role=\(String(describing: localRole), privacy: .public) peer=\(endpoint.device.name ?? "unnamed-peer", privacy: .private(mask: .hash)) receivePhotos=\(receivePhotos)"
        )
        stopNetworkTasks()
        configurePreviewCallbacks(eventHandler: eventHandler)
        eventHandler(.connecting)

        let parameters = NWParametersBuilder.parameters {
            WebSocket {
                TCP().noDelay(true).keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
            }
            .maximumMessageSize(ControlMessage.maximumEncodedSize)
            .autoReplyPing(true)
            .skipHandshake(true)
        }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.interactiveVideo)

        let connection = NetworkConnection<WebSocket>(to: endpoint, using: parameters)
            .onStateUpdate { _, state in
                Self.logConnectionState(state)
                switch state {
                case .ready:
                    eventHandler(.connected(peerName: endpoint.device.name))
                case .waiting:
                    // Transient waiting is part of Wi-Fi Aware data-path establishment. The
                    // initial send timeout reports a real failure if it does not recover.
                    break
                case .failed(let error):
                    eventHandler(Self.event(for: error))
                case .cancelled:
                    eventHandler(.interrupted(reason: "连接已结束"))
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
        self.connection = connection
        photoRemoteEndpoint = connection.remoteEndpoint

        listenerTask = Task { [weak self] in
            guard let self else { return }
            do {
                await controlChannel.attach(connection)
                if localRole == .monitor {
                    let id = Self.makeSessionId()
                    self.sessionId = id
                    wifiAwareLogger.notice("Monitor sending initial session.hello")
                    try await controlChannel.send(.sessionHello(
                        sessionId: id,
                        display: Self.displayCapabilities,
                        receivePhotos: receivePhotos
                    ))
                }
                try await runControlSession(
                    localRole: localRole,
                    eventHandler: eventHandler
                )
            } catch is CancellationError {
                wifiAwareLogger.notice("Outgoing control session task cancelled")
            } catch {
                wifiAwareLogger.error(
                    "Outgoing control session failed: \(Self.errorDescription(error), privacy: .public)"
                )
                await controlChannel.detach()
                invalidateSessionResources()
                eventHandler(.diagnostic(Self.diagnostic(
                    error,
                    title: "控制连接中断",
                    stage: localRole == .camera ? "拍摄端控制会话" : "监看端控制会话",
                    suggestion: Self.controlSuggestion(for: error)
                )))
                eventHandler(.interrupted(reason: error.localizedDescription))
            }
        }
    }

    func send(_ message: ControlMessage) async throws {
        try await controlChannel.send(message)
    }

    func sendRTP(_ packet: RTPPacket) {
        previewTransport.sendRTP(packet)
    }

    func requestKeyFrame() {
        previewTransport.requestKeyFrame()
    }

    func downloadPhoto(_ metadata: PhotoMetadata) async throws -> URL {
        guard let accessToken else { throw WiFiAwarePhotoError.sessionTokenUnavailable }
        guard let port = photoHTTPPort,
           let remoteEndpoint = connection?.currentPath?.remoteEndpoint
               ?? connection?.remoteEndpoint
               ?? photoRemoteEndpoint,
           let endpointPort = NWEndpoint.Port(rawValue: port),
           let awareEndpoint = remoteEndpoint.wifiAware(port: endpointPort)
        else { throw WiFiAwarePhotoError.peerUnavailable }

        let parameters = NWParametersBuilder.parameters {
            TCP().noDelay(true)
        }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.background)
        let connection = NetworkConnection<TCP>(to: awareEndpoint, using: parameters)
        return try await PhotoHTTPConnection.download(
            metadata: metadata,
            bearerToken: accessToken,
            over: connection
        )
    }

    func stop() {
        wifiAwareLogger.notice("Stopping Wi-Fi Aware session and invalidating ephemeral resources")
        stopNetworkTasks()
        connection = nil
        listener = nil
        httpListener = nil
        httpTask?.cancel()
        httpTask = nil
        photoHTTPPort = nil
        photoRemoteEndpoint = nil
        sessionId = nil
        accessToken = nil
        negotiatedConfigId = nil
        cachedSessionHello = nil
        cachedSessionAccepted = nil
        discoveredEndpoints = []
        Task { await controlChannel.detach() }
        Task { await photoResources.removeAll() }
    }

    private var publishableService: WAPublishableService? {
        WAPublishableService.allServices[Self.serviceName]
    }

    private var subscribableService: WASubscribableService? {
        WASubscribableService.allServices[Self.serviceName]
    }

    private func stopNetworkTasks() {
        listenerTask?.cancel()
        browserTask?.cancel()
        listenerTask = nil
        browserTask = nil
        connection = nil
        listener = nil
        httpTask?.cancel()
        httpTask = nil
        httpListener = nil
        photoHTTPPort = nil
        previewTransport.stop()
    }

    private func observePairedDevices() {
        guard pairedDevicesTask == nil else { return }
        pairedDevicesTask = Task { [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    self?.pairedDevices = devices.values.sorted { $0.id < $1.id }
                }
            } catch {
                // The connection flow surfaces actionable framework errors.
            }
        }
    }

    private func configurePreviewCallbacks(
        eventHandler: @escaping @MainActor (Event) -> Void
    ) {
        previewTransport.onRTPPacket = { packet in eventHandler(.rtpPacket(packet)) }
        previewTransport.onKeyFrameRequested = { eventHandler(.keyFrameRequested) }
        previewTransport.onError = { error in
            eventHandler(.diagnostic(Self.diagnostic(
                error,
                title: "实时预览通道失败",
                stage: "HEVC RTP/RTCP 附加数据路径",
                suggestion: "保持两台设备解锁且距离较近，结束当前会话后重新连接。"
            )))
            eventHandler(.interrupted(reason: "实时预览通道失败：\(error.localizedDescription)"))
        }
    }

    private func runControlSession(
        localRole: DeviceRole,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) async throws {
        let handler: @Sendable (ControlMessage) async -> Void = { [weak self] message in
            guard let self else { return }
            await self.handleIncoming(
                message,
                localRole: localRole,
                eventHandler: eventHandler
            )
        }
        if localRole == .camera {
            try await controlChannel.runServer(onMessage: handler)
        } else {
            try await controlChannel.run(onMessage: handler)
        }
    }

    private func invalidateSessionResources() {
        previewTransport.stop()
        httpTask?.cancel()
        httpTask = nil
        httpListener = nil
        photoHTTPPort = nil
        sessionId = nil
        accessToken = nil
        negotiatedConfigId = nil
        cachedSessionHello = nil
        cachedSessionAccepted = nil
        Task { await photoResources.removeAll() }
    }

    private func currentPeer() async throws -> WAPairedDevice {
        guard let path = connection?.currentPath,
              let awarePath = try await path.wifiAware
        else { throw PreviewTransportError.missingAwarePeer }
        return awarePath.endpoint.device
    }

    private static func event(for error: NWError) -> Event {
        if let wifiAwareError = error.wifiAware {
            switch wifiAwareError {
            case .wifiAwareUnsupported:
                return .failed(availability: .unsupported, reason: wifiAwareError.localizedDescription)
            case .entitlementMissing:
                return .failed(availability: .entitlementMissing, reason: wifiAwareError.localizedDescription)
            case .serviceNotDeclared:
                return .failed(availability: .serviceDeclarationMissing, reason: wifiAwareError.localizedDescription)
            case .noRadioResources:
                return .failed(availability: .noRadioResources, reason: wifiAwareError.localizedDescription)
            case .noPairedDevices:
                return .interrupted(reason: "还没有已配对设备，请先使用系统配对界面。")
            default:
                break
            }
        }
        return .interrupted(reason: error.localizedDescription)
    }

    private static func logListenerState(_ state: NetworkListener<WebSocket>.State) {
        switch state {
        case .setup:
            wifiAwareLogger.notice("Control listener state=setup")
        case .ready:
            wifiAwareLogger.notice("Control listener state=ready")
        case .waiting(let error):
            wifiAwareLogger.error(
                "Control listener state=waiting error=\(errorDescription(error), privacy: .public)"
            )
        case .failed(let error):
            wifiAwareLogger.error(
                "Control listener state=failed error=\(errorDescription(error), privacy: .public)"
            )
        case .cancelled:
            wifiAwareLogger.notice("Control listener state=cancelled")
        @unknown default:
            wifiAwareLogger.error("Control listener entered an unknown state")
        }
    }

    private static func logConnectionState(_ state: NetworkConnection<WebSocket>.State) {
        switch state {
        case .setup:
            wifiAwareLogger.notice("Outgoing control connection state=setup")
        case .preparing:
            wifiAwareLogger.notice("Outgoing control connection state=preparing")
        case .ready:
            wifiAwareLogger.notice("Outgoing control connection state=ready")
        case .waiting(let error):
            wifiAwareLogger.error(
                "Outgoing control connection state=waiting error=\(errorDescription(error), privacy: .public)"
            )
        case .failed(let error):
            wifiAwareLogger.error(
                "Outgoing control connection state=failed error=\(errorDescription(error), privacy: .public)"
            )
        case .cancelled:
            wifiAwareLogger.notice("Outgoing control connection state=cancelled")
        @unknown default:
            wifiAwareLogger.error("Outgoing control connection entered an unknown state")
        }
    }

    private static func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)[\(nsError.code)]: \(nsError.localizedDescription)"
    }

    private static func peerName(from endpoint: NWEndpoint?) -> String? {
        endpoint?.wifiAware?.device.name
    }

    private func handleIncoming(
        _ message: ControlMessage,
        localRole: DeviceRole,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) async {
        if message.type == "heartbeat.ping",
           case .integer(let sentAtMs)? = message.payload["sentAtMs"] {
            try? await controlChannel.send(.heartbeatPong(sentAtMs: sentAtMs, requestId: message.requestId))
        } else if message.type == "session.hello", localRole == .camera,
                  case .string(let sessionId)? = message.payload["sessionId"] {
            do {
                if let cachedSessionHello, let cachedSessionAccepted {
                    guard cachedSessionHello == message else {
                        throw ControlProtocolError.malformedMessage
                    }
                    try await controlChannel.send(cachedSessionAccepted)
                } else {
                    self.sessionId = sessionId
                    let accessToken = Self.makeAccessToken()
                    self.accessToken = accessToken
                    let peer = try await currentPeer()
                    let mediaSSRC = UInt32.random(in: 1 ... .max)
                    let payloadType: UInt8 = 96
                    let maximumPacketSize = 1_200
                    let previewEndpoint = try await previewTransport.prepareCamera(
                        peer: peer,
                        mediaSSRC: mediaSSRC,
                        payloadType: payloadType,
                        maximumPacketSize: maximumPacketSize
                    )
                    let photoEndpoint = try await startPhotoServerForCurrentPeer()
                    let preview = Self.previewConfiguration(
                        from: message,
                        captureDimensions: capturePreviewDimensionsProvider?()
                    )
                    let configId = Self.makeConfigId()
                    negotiatedConfigId = configId
                    eventHandler(.previewNegotiated(
                        configuration: preview,
                        mediaSSRC: mediaSSRC,
                        payloadType: payloadType,
                        maximumPacketSize: maximumPacketSize
                    ))
                    let accepted = ControlMessage.sessionAccepted(
                        requestId: message.requestId,
                        sessionId: sessionId,
                        accessToken: accessToken,
                        configId: configId,
                        preview: preview,
                        destinationAddress: Self.destinationDescription(connection?.localEndpoint),
                        rtpPort: previewEndpoint.rtpPort,
                        rtcpPort: previewEndpoint.rtcpPort,
                        payloadType: payloadType,
                        rtpSSRC: mediaSSRC,
                        maximumPacketSize: maximumPacketSize,
                        photoEndpoint: photoEndpoint
                    )
                    wifiAwareLogger.notice(
                        "Prepared session.accepted preview=\(preview.dimensions.width)x\(preview.dimensions.height) destinationLength=\(Self.destinationDescription(self.connection?.localEndpoint).utf8.count) rtpPort=\(previewEndpoint.rtpPort) rtcpPort=\(previewEndpoint.rtcpPort) photoPort=\(photoEndpoint.port)"
                    )
                    cachedSessionHello = message
                    cachedSessionAccepted = accepted
                    try await controlChannel.send(accepted)
                }
            } catch {
                wifiAwareLogger.error(
                    "Capture session.hello handling failed: \(Self.errorDescription(error), privacy: .public)"
                )
                invalidateSessionResources()
                eventHandler(.diagnostic(Self.diagnostic(
                    error,
                    title: "会话协商失败",
                    stage: "拍摄端处理 session.hello",
                    suggestion: "拍摄端未能及时建立 RTP、RTCP 或照片监听器。保持两台设备解锁后重试。"
                )))
                eventHandler(.interrupted(reason: error.localizedDescription))
            }
        } else if message.type == "session.accepted", localRole == .monitor {
            do {
                guard case .string(let id)? = message.payload["sessionId"],
                      case .string(let token)? = message.payload["accessToken"],
                      id == sessionId
                else { throw ControlProtocolError.malformedMessage }
                sessionId = id
                accessToken = token

                if case .object(let endpoint)? = message.payload["photoEndpoint"] {
                    if case .integer(let port)? = endpoint["port"],
                       let value = UInt16(exactly: port) {
                        photoHTTPPort = value
                    } else {
                        throw ControlProtocolError.malformedMessage
                    }
                } else {
                    throw ControlProtocolError.malformedMessage
                }

                let negotiatedPreview = try Self.previewConfiguration(fromAccepted: message)
                let preview = negotiatedPreview.configuration
                negotiatedConfigId = negotiatedPreview.configId
                let network = try Self.previewNetworkConfiguration(from: message)
                eventHandler(.previewNegotiated(
                    configuration: preview,
                    mediaSSRC: network.mediaSSRC,
                    payloadType: network.payloadType,
                    maximumPacketSize: network.maximumRTPPacketSize
                ))
                try await previewTransport.connectMonitor(
                    controlRemoteEndpoint: connection?.currentPath?.remoteEndpoint
                        ?? connection?.remoteEndpoint
                        ?? photoRemoteEndpoint,
                    configuration: network
                )
                try await controlChannel.send(.previewStart(configId: negotiatedPreview.configId))
            } catch {
                invalidateSessionResources()
                eventHandler(.diagnostic(Self.diagnostic(
                    error,
                    title: "预览连接失败",
                    stage: "监看端处理 session.accepted",
                    suggestion: "监看端未能建立协商后的 RTP/RTCP 数据路径。确认两端系统版本与 Wi-Fi Aware 配对状态后重试。"
                )))
                eventHandler(.interrupted(reason: error.localizedDescription))
            }
        } else if message.type == "preview.start", localRole == .camera {
            guard case .string(let configId)? = message.payload["configId"],
                  configId == negotiatedConfigId
            else {
                eventHandler(.interrupted(reason: "监看端请求了未协商的预览配置。"))
                return
            }
            eventHandler(.previewStarted)
        } else if message.type == "preview.stop" {
            eventHandler(.previewStopped)
        } else if message.type == "keyframe.request", localRole == .camera {
            eventHandler(.keyFrameRequested)
        } else if message.type == "session.end" {
            invalidateSessionResources()
            eventHandler(.interrupted(reason: "对端已结束会话"))
        } else if message.type == "photo.transferResult", localRole == .camera,
                  case .string(let photoId)? = message.payload["photoId"],
                  case .string(let status)? = message.payload["status"],
                  status == "saved" {
            await photoResources.acknowledge(photoId: photoId)
        }
        eventHandler(.message(message))
    }

    private func startPhotoServerForCurrentPeer() async throws -> PhotoEndpointAdvertisement {
        if let photoHTTPPort {
            return PhotoEndpointAdvertisement(port: photoHTTPPort)
        }
        guard let connection,
              let path = connection.currentPath,
              let awarePath = try await path.wifiAware
        else { throw WiFiAwarePhotoError.peerUnavailable }
        guard let accessToken else { throw WiFiAwarePhotoError.sessionTokenUnavailable }

        let provider: WAPublisherListener = .wifiAware(
            .addingConnections(from: .selected([awarePath.endpoint.device]))
        )
        let parameters = NWParametersBuilder.parameters {
            TCP().noDelay(true)
        }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.background)
        // Keep the listener available for every photo in this session. NetworkListener's
        // newConnectionLimit is a lifetime acceptance count, not a concurrency limit; setting
        // it to 1 makes the first download succeed and every later download wait forever.
        let listener = try NetworkListener<TCP>(for: provider, using: parameters)
        httpListener = listener
        httpTask = Task { [weak self] in
            do {
                try await listener.run { photoConnection in
                    guard let self else { return }
                    wifiAwareLogger.notice("Accepted photo HTTP connection")
                    do {
                        try await PhotoHTTPConnection.serve(
                            over: photoConnection,
                            store: self.photoResources,
                            bearerToken: accessToken
                        )
                        wifiAwareLogger.notice("Completed photo HTTP connection")
                    } catch {
                        wifiAwareLogger.error(
                            "Photo HTTP connection failed without stopping listener: \(Self.errorDescription(error), privacy: .public)"
                        )
                    }
                }
            } catch is CancellationError {
                // The session intentionally ended.
            } catch {
                // The control connection will report a failed client transfer.
            }
        }

        for _ in 0 ..< 250 {
            if let port = listener.port?.rawValue, port != 0 {
                photoHTTPPort = port
                return PhotoEndpointAdvertisement(port: port)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WiFiAwarePhotoError.listenerTimedOut
    }

    private static var displayCapabilities: MonitorDisplayCapabilities {
        let bounds = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.nativeBounds }
            .first ?? CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let dimensions = PixelDimensions(
            width: max(1, Int(bounds.width)),
            height: max(1, Int(bounds.height))
        )
        let maximumDecodeDimensions = dimensions.height >= dimensions.width
            ? PixelDimensions(width: 2_160, height: 3_840)
            : PixelDimensions(width: 3_840, height: 2_160)
        return MonitorDisplayCapabilities(
            nativePixels: dimensions,
            viewportPixels: dimensions,
            orientation: Self.currentOrientation,
            hevc: HEVCDecodeCapabilities(
                supported: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                maximumDimensions: maximumDecodeDimensions,
                maximumFramesPerSecond: 60,
                profiles: ["main", "main10"]
            )
        )
    }

    private static var currentOrientation: PreviewOrientation {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
    }

    private static func previewConfiguration(
        from hello: ControlMessage,
        captureDimensions: PixelDimensions?
    ) -> PreviewConfiguration {
        let requested = captureDimensions ?? PixelDimensions(width: 1_080, height: 1_440)
        var maximum = requested.height >= requested.width
            ? PixelDimensions(width: 2_160, height: 3_840)
            : PixelDimensions(width: 3_840, height: 2_160)
        if case .object(let hevc)? = hello.payload["hevc"],
           case .integer(let maxWidth)? = hevc["maxWidthPx"],
           case .integer(let maxHeight)? = hevc["maxHeightPx"] {
            maximum = PixelDimensions(width: maxWidth, height: maxHeight)
        }
        let dimensions = PreviewNegotiator.aspectPreservingDimensions(
            requested: requested,
            maximum: maximum
        )
        return PreviewConfiguration(
            dimensions: dimensions,
            framesPerSecond: 30,
            bitrate: 10_000_000,
            profile: "main",
            level: "120"
        )
    }

    private static func previewConfiguration(fromAccepted message: ControlMessage) throws -> NegotiatedPreview {
        guard case .object(let preview)? = message.payload["preview"],
              case .string(let configId)? = preview["configId"],
              case .integer(let width)? = preview["widthPx"],
              case .integer(let height)? = preview["heightPx"],
              case .integer(let fps)? = preview["fps"],
              case .integer(let bitrate)? = preview["bitrateBps"],
              case .string(let profile)? = preview["profile"],
              case .integer(let level)? = preview["levelIdc"],
              (16 ... 16_384).contains(width),
              (16 ... 16_384).contains(height),
              (1 ... 240).contains(fps),
              (100_000 ... 200_000_000).contains(bitrate),
              ["main", "main10"].contains(profile),
              (30 ... 186).contains(level),
              configId.range(
                  of: "^[A-Za-z0-9._~-]{1,64}$",
                  options: .regularExpression
              ) != nil
        else { throw ControlProtocolError.malformedMessage }
        return NegotiatedPreview(
            configId: configId,
            configuration: PreviewConfiguration(
                dimensions: PixelDimensions(width: width, height: height),
                framesPerSecond: fps,
                bitrate: bitrate,
                profile: profile,
                level: String(level)
            )
        )
    }

    private static func previewNetworkConfiguration(
        from message: ControlMessage
    ) throws -> PreviewNetworkConfiguration {
        guard case .object(let rtp)? = message.payload["rtp"],
              case .string(let destinationAddress)? = rtp["destinationAddress"],
              case .integer(let rtpPort)? = rtp["rtpPort"],
              case .integer(let rtcpPort)? = rtp["rtcpPort"],
              case .integer(let payloadType)? = rtp["payloadType"],
              case .integer(let ssrc)? = rtp["ssrc"],
              case .integer(let maximumPacketSize)? = rtp["maxRtpPacketSize"],
              let rtpPortValue = UInt16(exactly: rtpPort),
              let rtcpPortValue = UInt16(exactly: rtcpPort),
              let payloadTypeValue = UInt8(exactly: payloadType),
              let ssrcValue = UInt32(exactly: ssrc),
              !destinationAddress.isEmpty,
              destinationAddress.utf8.count <= 255,
              (96 ... 127).contains(payloadType),
              (256 ... 65_507).contains(maximumPacketSize)
        else { throw ControlProtocolError.malformedMessage }
        return PreviewNetworkConfiguration(
            destinationAddress: destinationAddress,
            rtpPort: rtpPortValue,
            rtcpPort: rtcpPortValue,
            payloadType: payloadTypeValue,
            mediaSSRC: ssrcValue,
            maximumRTPPacketSize: maximumPacketSize
        )
    }

    private static func destinationDescription(_ endpoint: NWEndpoint?) -> String {
        let description = endpoint?.debugDescription ?? "wifi-aware-peer"
        let sanitized = String(decoding: description.utf8.prefix(255), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
        return sanitized.isEmpty ? "wifi-aware-peer" : sanitized
    }

    private static func makeSessionId() -> String {
        "session_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeAccessToken() -> String {
        "token_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeConfigId() -> String {
        "config_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func diagnostic(
        _ error: Error,
        title: String,
        stage: String,
        suggestion: String
    ) -> SessionErrorReport {
        if let networkError = error as? NWError,
           let awareError = networkError.wifiAware {
            return SessionErrorReport(
                title: title,
                stage: stage,
                message: awareError.localizedDescription,
                domain: "WiFiAware.WAError",
                code: networkError.errorCode,
                underlyingDomain: "Network.NWError",
                underlyingCode: networkError.errorCode,
                underlyingMessage: networkError.localizedDescription,
                suggestion: suggestion
            )
        }
        return SessionErrorReport(
            error: error,
            title: title,
            stage: stage,
            suggestion: suggestion
        )
    }

    private static func controlSuggestion(for error: Error) -> String {
        if error is ControlChannelError {
            return "控制消息未在限定时间内完成。若发生在等待控制消息阶段，通常表示拍摄端仍在创建 RTP、RTCP 或照片附加连接；保持两端解锁并重试。"
        }
        return "确认两台设备保持解锁、Wi-Fi 已开启且系统配对仍有效，然后结束会话并重试。"
    }

}

private struct NegotiatedPreview: Sendable {
    var configId: String
    var configuration: PreviewConfiguration
}

struct PhotoEndpointAdvertisement: Sendable {
    var port: UInt16
}

enum WiFiAwarePhotoError: LocalizedError {
    case peerUnavailable
    case sessionTokenUnavailable
    case listenerTimedOut

    var errorDescription: String? {
        switch self {
        case .peerUnavailable: "无法从当前 Wi-Fi Aware 数据路径识别已选择的对端。"
        case .sessionTokenUnavailable: "本次会话的临时访问令牌尚未建立。"
        case .listenerTimedOut: "成片 HTTP 服务启动超时。"
        }
    }
}
