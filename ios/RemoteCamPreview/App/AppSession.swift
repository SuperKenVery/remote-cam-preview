import Foundation
import Observation
import WiFiAware

@MainActor
@Observable
final class AppSession {
    private let dependencies: AppDependencies
    private var photoReceiveTask: Task<Void, Never>?

    var routePath: [AppRoute] = []
    var role: DeviceRole?
    var phase: SessionPhase = .checkingCapability
    var receivePhotos = true
    var statusDetail: String?
    var photoTransferStatus: String?
    var lastError: String?
    var selectedPreviewConfiguration: PreviewConfiguration?
    private(set) var isPreviewStreaming = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func prepare() async {
        dependencies.mediaPipeline.onRTPPacket = { [weak controller = dependencies.wifiAware] packet in
            Task { @MainActor in controller?.sendRTP(packet) }
        }
        dependencies.mediaPipeline.onError = { [weak self] error in
            Task { @MainActor in self?.lastError = "实时预览失败：\(error.localizedDescription)" }
        }
        phase = .checkingCapability
        let availability = dependencies.wifiAware.checkAvailability()
        phase = availability == .available ? .roleSelection : .unavailable(availability)
    }

    func choose(_ role: DeviceRole) {
        self.role = role
        phase = .unpaired
        routePath = [.session]
    }

    func startPublishing() {
        phase = .searching
        lastError = nil
        guard let role else { return }
        dependencies.wifiAware.startPublishing(
            localRole: role,
            receivePhotos: receivePhotos
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func connect(to endpoint: WAEndpoint) {
        phase = .connecting
        lastError = nil
        guard let role else { return }
        dependencies.wifiAware.connect(
            to: endpoint,
            localRole: role,
            receivePhotos: receivePhotos
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func pairerPresented() {
        phase = .pairing
    }

    func pairingDismissed() {
        if case .pairing = phase { phase = .unpaired }
    }

    func updateReceivePhotos(_ enabled: Bool) async {
        receivePhotos = enabled
        guard case .connected = phase else { return }

        let message = ControlMessage.photoReceivePreference(enabled: enabled)
        do {
            try await dependencies.wifiAware.send(message)
        } catch {
            lastError = "未能同步成片接收设置：\(error.localizedDescription)"
        }
    }

    func startCameraIfNeeded() async {
        guard role == .camera else { return }
        do {
            try await dependencies.camera.prepare()
            dependencies.camera.onVideoSampleBuffer = { [weak self] sampleBuffer in
                Task { @MainActor in
                    guard let self, self.isPreviewStreaming else { return }
                    self.dependencies.mediaPipeline.encode(sampleBuffer)
                }
            }
            dependencies.camera.start()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func capturePhoto() async {
        guard role == .camera else { return }
        do {
            photoTransferStatus = "正在处理照片…"
            let photo = try await dependencies.camera.capturePhoto()
            try await dependencies.photoLibrary.save(data: photo.data)
            photoTransferStatus = "已保存到本机照片库"

            guard receivePhotos, case .connected = phase else { return }
            let resource = try await dependencies.photoResources.register(
                data: photo.data,
                fileName: photo.fileName,
                mimeType: photo.mimeType,
                dimensions: photo.dimensions
            )
            try await dependencies.wifiAware.send(.photoAvailable(resource.metadata))
            photoTransferStatus = "成片已提供给监看端"
        } catch {
            photoTransferStatus = nil
            lastError = "拍照或保存失败：\(error.localizedDescription)"
        }
    }

    func retry() async {
        dependencies.wifiAware.stop()
        photoReceiveTask?.cancel()
        photoReceiveTask = nil
        isPreviewStreaming = false
        dependencies.mediaPipeline.stop()
        await prepare()
        if role != nil {
            phase = .unpaired
        }
    }

    func endSession() {
        dependencies.wifiAware.stop()
        photoReceiveTask?.cancel()
        photoReceiveTask = nil
        dependencies.camera.onVideoSampleBuffer = nil
        dependencies.camera.stop()
        dependencies.mediaPipeline.stop()
        role = nil
        routePath = []
        phase = .roleSelection
        statusDetail = nil
        photoTransferStatus = nil
        lastError = nil
        selectedPreviewConfiguration = nil
        isPreviewStreaming = false
    }

    private func handle(_ event: WiFiAwareController.Event) {
        switch event {
        case .searching:
            phase = .searching
        case .connecting:
            phase = .connecting
        case .connected(let peerName):
            phase = .connected(peerName: peerName)
            statusDetail = "控制通道已建立；会话令牌仅在本次连接内有效。"
        case .interrupted(let reason):
            photoReceiveTask?.cancel()
            photoReceiveTask = nil
            isPreviewStreaming = false
            dependencies.mediaPipeline.stop()
            phase = .interrupted(reason: reason)
        case .failed(let availability, let reason):
            if let availability {
                phase = .unavailable(availability)
            } else {
                phase = .interrupted(reason: reason)
            }
        case .previewNegotiated(let configuration, let mediaSSRC, let payloadType, let maximumPacketSize):
            selectedPreviewConfiguration = configuration
            if role == .camera {
                do {
                    try dependencies.mediaPipeline.configureEncoder(
                        configuration,
                        mediaSSRC: mediaSSRC,
                        payloadType: payloadType,
                        maximumPacketSize: maximumPacketSize
                    )
                } catch {
                    lastError = "无法配置 HEVC 编码器：\(error.localizedDescription)"
                }
            }
        case .previewStarted:
            isPreviewStreaming = true
            dependencies.mediaPipeline.requestKeyFrame()
        case .previewStopped:
            isPreviewStreaming = false
        case .rtpPacket(let packet):
            guard role == .monitor else { return }
            dependencies.mediaPipeline.ingest(packet)
        case .keyFrameRequested:
            guard role == .camera else { return }
            dependencies.mediaPipeline.requestKeyFrame()
        case .message(let message):
            handle(message)
        }
    }

    private func handle(_ message: ControlMessage) {
        switch message.type {
        case "session.hello" where role == .camera:
            if case .bool(let enabled)? = message.payload["photoReceiveEnabled"] {
                receivePhotos = enabled
            }
        case "photo.receivePreference" where role == .camera:
            if case .bool(let enabled)? = message.payload["enabled"] {
                receivePhotos = enabled
            }
        case "photo.available" where role == .monitor && receivePhotos:
            guard case .object(let payload)? = message.payload["metadata"],
                  let metadata = try? PhotoMetadata(controlPayload: payload)
            else {
                lastError = "远端成片元数据无效。"
                return
            }
            photoReceiveTask?.cancel()
            photoReceiveTask = Task { [weak self] in
                await self?.receivePhoto(metadata)
            }
        case "photo.transferResult" where role == .camera:
            if case .string(let status)? = message.payload["status"] {
                photoTransferStatus = status == "saved" ? "监看端已保存成片" : "监看端未能保存成片"
            }
        default:
            break
        }
    }

    private func receivePhoto(_ metadata: PhotoMetadata) async {
        photoTransferStatus = "正在接收成片…"
        do {
            let temporaryURL = try await dependencies.wifiAware.downloadPhoto(metadata)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try Task.checkCancellation()
            try await dependencies.photoResources.validateReceivedFile(at: temporaryURL, metadata: metadata)
            try Task.checkCancellation()
            try await dependencies.photoLibrary.saveFile(at: temporaryURL)
            try await dependencies.wifiAware.send(.photoTransferResult(
                photoId: metadata.photoId,
                status: "saved"
            ))
            photoTransferStatus = "成片已校验并保存"
            photoReceiveTask = nil
        } catch is CancellationError {
            photoTransferStatus = nil
            photoReceiveTask = nil
        } catch {
            try? await dependencies.wifiAware.send(.photoTransferResult(
                photoId: metadata.photoId,
                status: "failed",
                errorCode: "PHOTO_RECEIVE_FAILED"
            ))
            photoTransferStatus = nil
            lastError = "成片接收失败：\(error.localizedDescription)"
            photoReceiveTask = nil
        }
    }
}
