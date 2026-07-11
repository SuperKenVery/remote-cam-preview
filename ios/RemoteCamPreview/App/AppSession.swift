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
    var lastError: SessionErrorReport?
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
            Task { @MainActor in
                self?.lastError = Self.report(
                    error,
                    title: "实时预览失败",
                    stage: "HEVC 编解码或 RTP 处理",
                    suggestion: "结束当前会话后重试；若持续出现，请记录两端角色和错误代码。"
                )
            }
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

    func startPublishing(to peer: WAPairedDevice) {
        phase = .searching
        lastError = nil
        guard let role else { return }
        dependencies.wifiAware.startPublishing(
            to: peer,
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
            lastError = Self.report(
                error,
                title: "未能同步成片接收设置",
                stage: "控制通道发送 photo.receivePreference",
                suggestion: "确认控制连接仍然有效，然后重试此开关。"
            )
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
            lastError = Self.report(
                error,
                title: "相机启动失败",
                stage: "AVFoundation 相机准备",
                suggestion: "确认相机权限已授予，且没有其他应用占用相机。"
            )
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
            lastError = Self.report(
                error,
                title: "拍照或保存失败",
                stage: "静态照片拍摄与本机照片库保存",
                suggestion: "确认相机和照片权限后重试。"
            )
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
        case .diagnostic(let report):
            lastError = report
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
                    lastError = Self.report(
                        error,
                        title: "无法配置 HEVC 编码器",
                        stage: "VideoToolbox 编码器配置",
                        suggestion: "协商尺寸可能不受本机硬件编码器支持；记录尺寸与错误代码后重试。"
                    )
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
                lastError = SessionErrorReport(
                    title: "远端成片元数据无效",
                    stage: "解析 photo.available",
                    message: "控制消息中的照片元数据不符合 v1 协议。",
                    code: 1,
                    suggestion: "确认两端安装的是同一协议版本的应用。"
                )
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
            lastError = Self.report(
                error,
                title: "成片接收失败",
                stage: "Wi-Fi Aware HTTP 下载、完整性校验或照片库保存",
                suggestion: "查看错误域和代码判断是网络超时、SHA-256 校验失败还是照片库写入失败。"
            )
            photoReceiveTask = nil
        }
    }

    private static func report(
        _ error: Error,
        title: String,
        stage: String,
        suggestion: String
    ) -> SessionErrorReport {
        SessionErrorReport(
            error: error,
            title: title,
            stage: stage,
            suggestion: suggestion
        )
    }
}
