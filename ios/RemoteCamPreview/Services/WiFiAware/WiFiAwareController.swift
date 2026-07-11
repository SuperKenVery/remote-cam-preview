import Foundation
import Network
import Observation
import UIKit
import VideoToolbox
import WiFiAware

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
    }

    static let serviceName = "_remote-cam._tcp"
    static let photoServiceName = "_remote-photo._tcp"
    static let rtpServiceName = "_remote-preview._udp"
    static let rtcpServiceName = "_remote-feedback._udp"

    private(set) var pairedDeviceCount = 0
    private(set) var discoveredEndpoints: [WAEndpoint] = []

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
    private var photoServiceEndpoint: WAEndpoint?
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
            return .unsupported
        }
        guard publishableService != nil,
              subscribableService != nil,
              photoPublishableService != nil,
              photoSubscribableService != nil,
              rtpPublishableService != nil,
              rtpSubscribableService != nil,
              rtcpPublishableService != nil,
              rtcpSubscribableService != nil
        else {
            return .serviceDeclarationMissing
        }
        observePairedDevices()
        return .available
    }

    func startPublishing(
        localRole: DeviceRole,
        receivePhotos: Bool,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) {
        guard let service = publishableService else {
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
                    from: .userSpecifiedDevices,
                    datapath: .realtime
                )
            )
            let parameters = NWParametersBuilder.parameters {
                WebSocket {
                    TCP().noDelay(true).keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
                }
                .maximumMessageSize(ControlMessage.maximumEncodedSize)
                .autoReplyPing(true)
            }
            .wifiAware { $0.performanceMode = .realtime }
            .serviceClass(.interactiveVideo)

            let listener = try NetworkListener<WebSocket>(for: provider, using: parameters)
                .newConnectionLimit(1)
                .onStateUpdate { _, state in
                    switch state {
                    case .waiting(let error):
                        eventHandler(Self.event(for: error, waiting: true))
                    case .failed(let error):
                        eventHandler(Self.event(for: error, waiting: false))
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
                    try await listener.run { connection in
                        guard let self else { return }
                        self.connection = connection
                        self.photoRemoteEndpoint = connection.remoteEndpoint
                        await self.controlChannel.attach(connection)
                        eventHandler(.connected(peerName: Self.peerName(from: connection.remoteEndpoint)))
                        if localRole == .monitor {
                            let id = Self.makeSessionId()
                            self.sessionId = id
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
                    // The session intentionally ended.
                } catch {
                    await self?.controlChannel.detach()
                    self?.invalidateSessionResources()
                    eventHandler(.interrupted(reason: error.localizedDescription))
                }
            }
        } catch {
            eventHandler(.failed(availability: nil, reason: error.localizedDescription))
        }
    }

    func startBrowsing(
        onEndpointsChanged: @escaping @MainActor ([WAEndpoint]) -> Void,
        eventHandler: @escaping @MainActor (Event) -> Void
    ) {
        guard let service = subscribableService else {
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
                    self?.discoveredEndpoints = endpoints
                    onEndpointsChanged(endpoints)
                }
            } catch is CancellationError {
                // The session intentionally ended.
            } catch {
                await self?.controlChannel.detach()
                self?.invalidateSessionResources()
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
        stopNetworkTasks()
        configurePreviewCallbacks(eventHandler: eventHandler)
        eventHandler(.connecting)

        let parameters = NWParametersBuilder.parameters {
            WebSocket {
                TCP().noDelay(true).keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
            }
            .maximumMessageSize(ControlMessage.maximumEncodedSize)
            .autoReplyPing(true)
        }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.interactiveVideo)

        let connection = NetworkConnection<WebSocket>(to: endpoint, using: parameters)
            .onStateUpdate { _, state in
                switch state {
                case .ready:
                    eventHandler(.connected(peerName: endpoint.device.name))
                case .waiting(let error):
                    eventHandler(Self.event(for: error, waiting: true))
                case .failed(let error):
                    eventHandler(Self.event(for: error, waiting: false))
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
                // The session intentionally ended.
            } catch {
                await controlChannel.detach()
                invalidateSessionResources()
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
        let awareEndpoint: WAEndpoint
        if #available(iOS 26.4, *),
           let port = photoHTTPPort,
           let remoteEndpoint = connection?.remoteEndpoint ?? photoRemoteEndpoint,
           let endpoint = remoteEndpoint.wifiAware(port: NWEndpoint.Port(rawValue: port)!) {
            awareEndpoint = endpoint
        } else if let photoServiceEndpoint {
            awareEndpoint = photoServiceEndpoint
        } else {
            throw WiFiAwarePhotoError.peerUnavailable
        }

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
        stopNetworkTasks()
        connection = nil
        listener = nil
        httpListener = nil
        httpTask?.cancel()
        httpTask = nil
        photoHTTPPort = nil
        photoRemoteEndpoint = nil
        photoServiceEndpoint = nil
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

    private var photoPublishableService: WAPublishableService? {
        WAPublishableService.allServices[Self.photoServiceName]
    }

    private var photoSubscribableService: WASubscribableService? {
        WASubscribableService.allServices[Self.photoServiceName]
    }

    private var rtpPublishableService: WAPublishableService? {
        WAPublishableService.allServices[Self.rtpServiceName]
    }

    private var rtpSubscribableService: WASubscribableService? {
        WASubscribableService.allServices[Self.rtpServiceName]
    }

    private var rtcpPublishableService: WAPublishableService? {
        WAPublishableService.allServices[Self.rtcpServiceName]
    }

    private var rtcpSubscribableService: WASubscribableService? {
        WASubscribableService.allServices[Self.rtcpServiceName]
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
        photoServiceEndpoint = nil
        previewTransport.stop()
    }

    private func observePairedDevices() {
        guard pairedDevicesTask == nil else { return }
        pairedDevicesTask = Task { [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    self?.pairedDeviceCount = devices.count
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
        photoServiceEndpoint = nil
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

    private static func event(for error: NWError, waiting: Bool) -> Event {
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
        return waiting
            ? .interrupted(reason: "网络暂时不可用：\(error.localizedDescription)")
            : .interrupted(reason: error.localizedDescription)
    }

    private static func peerName(from endpoint: NWEndpoint?) -> String? {
        if #available(iOS 26.4, *) {
            return endpoint?.wifiAware?.device.name
        }
        return nil
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
                        rtpPublishableService: rtpPublishableService,
                        rtcpPublishableService: rtcpPublishableService,
                        rtpServiceName: Self.rtpServiceName,
                        rtcpServiceName: Self.rtcpServiceName,
                        mediaSSRC: mediaSSRC,
                        payloadType: payloadType,
                        maximumPacketSize: maximumPacketSize
                    )
                    let photoEndpoint = try await startPhotoServerForCurrentPeer()
                    let preview = Self.previewConfiguration(from: message)
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
                        rtpService: previewEndpoint.rtpService,
                        rtcpService: previewEndpoint.rtcpService,
                        photoEndpoint: photoEndpoint
                    )
                    cachedSessionHello = message
                    cachedSessionAccepted = accepted
                    try await controlChannel.send(accepted)
                }
            } catch {
                invalidateSessionResources()
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
                    } else if case .string(let service)? = endpoint["serviceName"],
                              service == Self.photoServiceName {
                        photoServiceEndpoint = try await discoverPhotoService()
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
                let peer = try await currentPeer()
                eventHandler(.previewNegotiated(
                    configuration: preview,
                    mediaSSRC: network.mediaSSRC,
                    payloadType: network.payloadType,
                    maximumPacketSize: network.maximumRTPPacketSize
                ))
                try await previewTransport.connectMonitor(
                    peer: peer,
                    controlRemoteEndpoint: connection?.remoteEndpoint ?? photoRemoteEndpoint,
                    configuration: network,
                    rtpSubscribableService: rtpSubscribableService,
                    rtcpSubscribableService: rtcpSubscribableService
                )
                try await controlChannel.send(.previewStart(configId: negotiatedPreview.configId))
            } catch {
                invalidateSessionResources()
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
            return PhotoEndpointAdvertisement(port: photoHTTPPort, service: nil)
        }
        guard let connection,
              let path = connection.currentPath,
              let awarePath = try await path.wifiAware
        else { throw WiFiAwarePhotoError.peerUnavailable }
        guard let accessToken else { throw WiFiAwarePhotoError.sessionTokenUnavailable }

        let provider: WAPublisherListener
        let advertisedService: String?
        if #available(iOS 26.4, *) {
            provider = .wifiAware(
                .addingConnections(from: .selected([awarePath.endpoint.device]))
            )
            advertisedService = nil
        } else {
            guard let service = photoPublishableService else {
                throw WiFiAwarePhotoError.photoServiceMissing
            }
            provider = .wifiAware(
                .connecting(
                    to: service,
                    from: .selected([awarePath.endpoint.device]),
                    datapath: .realtime
                )
            )
            advertisedService = Self.photoServiceName
        }
        let parameters = NWParametersBuilder.parameters {
            TCP().noDelay(true)
        }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.background)
        let listener = try NetworkListener<TCP>(for: provider, using: parameters)
            .newConnectionLimit(1)
        httpListener = listener
        httpTask = Task { [weak self] in
            do {
                try await listener.run { photoConnection in
                    guard let self else { return }
                    try await PhotoHTTPConnection.serve(
                        over: photoConnection,
                        store: self.photoResources,
                        bearerToken: accessToken
                    )
                }
            } catch is CancellationError {
                // The session intentionally ended.
            } catch {
                // The control connection will report a failed client transfer.
            }
        }

        for _ in 0 ..< 250 {
            if let port = listener.port?.rawValue {
                photoHTTPPort = port
                return PhotoEndpointAdvertisement(
                    port: advertisedService == nil ? port : nil,
                    service: advertisedService
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WiFiAwarePhotoError.listenerTimedOut
    }

    private func discoverPhotoService() async throws -> WAEndpoint {
        guard let connection,
              let path = connection.currentPath,
              let awarePath = try await path.wifiAware,
              let service = photoSubscribableService
        else { throw WiFiAwarePhotoError.peerUnavailable }

        let provider: WASubscriberBrowser = .wifiAware(
            .connecting(to: .selected([awarePath.endpoint.device]), from: service)
        )
        let parameters = NWParameters.tcp
            .wifiAware { $0.performanceMode = .realtime }
        let browser = NetworkBrowser(for: provider, using: parameters)

        return try await withThrowingTaskGroup(of: WAEndpoint.self) { group in
            group.addTask {
                try await browser.run { endpoints in
                    guard let endpoint = endpoints.first else { return .continue }
                    return .finish(endpoint)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw WiFiAwarePhotoError.listenerTimedOut
            }
            let endpoint = try await group.next()!
            group.cancelAll()
            return endpoint
        }
    }

    private static var displayCapabilities: MonitorDisplayCapabilities {
        let bounds = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.nativeBounds }
            .first ?? CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let dimensions = PixelDimensions(
            width: max(1, Int(bounds.width)),
            height: max(1, Int(bounds.height))
        )
        return MonitorDisplayCapabilities(
            nativePixels: dimensions,
            viewportPixels: dimensions,
            orientation: Self.currentOrientation,
            hevc: HEVCDecodeCapabilities(
                supported: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                maximumDimensions: PixelDimensions(width: 3_840, height: 2_160),
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

    private static func previewConfiguration(from hello: ControlMessage) -> PreviewConfiguration {
        var width = 1_920
        var height = 1_080
        if case .object(let display)? = hello.payload["display"] {
            if case .integer(let value)? = display["viewportWidthPx"] { width = value }
            if case .integer(let value)? = display["viewportHeightPx"] { height = value }
        }
        width = max(16, min(3_840, width)) & ~1
        height = max(16, min(2_160, height)) & ~1
        return PreviewConfiguration(
            dimensions: PixelDimensions(width: width, height: height),
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
        let rtpService: String?
        if case .string(let value)? = rtp["rtpService"] { rtpService = value }
        else { rtpService = nil }
        let rtcpService: String?
        if case .string(let value)? = rtp["rtcpService"] { rtcpService = value }
        else { rtcpService = nil }
        return PreviewNetworkConfiguration(
            destinationAddress: destinationAddress,
            rtpPort: rtpPortValue,
            rtcpPort: rtcpPortValue,
            payloadType: payloadTypeValue,
            mediaSSRC: ssrcValue,
            maximumRTPPacketSize: maximumPacketSize,
            rtpService: rtpService,
            rtcpService: rtcpService
        )
    }

    private static func destinationDescription(_ endpoint: NWEndpoint?) -> String {
        let description = endpoint?.debugDescription ?? "wifi-aware-peer"
        return String(decoding: description.utf8.prefix(255), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
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

}

private struct NegotiatedPreview: Sendable {
    var configId: String
    var configuration: PreviewConfiguration
}

struct PhotoEndpointAdvertisement: Sendable {
    var port: UInt16?
    var service: String?
}

enum WiFiAwarePhotoError: LocalizedError {
    case additionalConnectionsUnavailable
    case peerUnavailable
    case sessionTokenUnavailable
    case listenerTimedOut
    case photoServiceMissing

    var errorDescription: String? {
        switch self {
        case .additionalConnectionsUnavailable:
            "成片 HTTP 通道需要 iOS 26.4 或更高版本的 Wi-Fi Aware 附加连接 API。"
        case .peerUnavailable: "无法从当前 Wi-Fi Aware 数据路径识别已选择的对端。"
        case .sessionTokenUnavailable: "本次会话的临时访问令牌尚未建立。"
        case .listenerTimedOut: "成片 HTTP 服务启动超时。"
        case .photoServiceMissing: "成片 Wi-Fi Aware 服务没有在 Info.plist 中声明。"
        }
    }
}
