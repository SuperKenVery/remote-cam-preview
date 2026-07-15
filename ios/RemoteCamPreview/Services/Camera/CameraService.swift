import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Observation

struct CapturedPhoto: Sendable {
    var data: Data
    var fileName: String
    var mimeType: String
    var dimensions: PixelDimensions
}

enum CameraServiceError: LocalizedError {
    case permissionDenied
    case noBackCamera
    case noFrontCamera
    case cannotAddInput
    case cannotAddPhotoOutput
    case cannotAddVideoOutput
    case notReady
    case photoDataUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "相机权限被拒绝。请在“设置”中允许相机访问。"
        case .noBackCamera: "未找到可用的后置相机。"
        case .noFrontCamera: "未找到可用的前置相机。"
        case .cannotAddInput: "无法将相机接入拍摄管线。"
        case .cannotAddPhotoOutput: "无法创建静态照片输出。"
        case .cannotAddVideoOutput: "无法创建实时预览输出。"
        case .notReady: "相机尚未准备好。"
        case .photoDataUnavailable: "相机没有生成最终照片文件。"
        case .captureFailed(let message): "静态照片处理失败：\(message)"
        }
    }
}

@MainActor
@Observable
final class CameraService {
    let captureSession = AVCaptureSession()

    private(set) var isReady = false
    private(set) var isCapturingPhoto = false
    private(set) var authorizationMessage: String?
    private(set) var cameraPosition: AVCaptureDevice.Position = .back
    private(set) var zoomFactor: CGFloat = 1
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    private(set) var zoomPresets: [CGFloat] = [1]
    private(set) var canSwitchCamera = false
    private(set) var previewDimensions: PixelDimensions?
    var onVideoSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? {
        didSet { videoDelegate.onSampleBuffer = onVideoSampleBuffer }
    }

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoDelegate = CameraVideoDelegate()
    private var photoDelegates: [Int64: CameraPhotoDelegate] = [:]
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    init() {
        videoDelegate.onDimensionsChanged = { [weak self] dimensions in
            Task { @MainActor in
                self?.previewDimensions = dimensions
            }
        }
    }

    func prepare() async throws {
        guard !configured else { return }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard authorized else {
            authorizationMessage = CameraServiceError.permissionDenied.localizedDescription
            throw CameraServiceError.permissionDenied
        }

        try configureSession()
        configured = true
        isReady = true
    }

    func start() {
        guard configured, !captureSession.isRunning else { return }
        captureSession.startRunning()
    }

    func stop() {
        if captureSession.isRunning { captureSession.stopRunning() }
        isCapturingPhoto = false
    }

    func capturePhoto() async throws -> CapturedPhoto {
        guard isReady, captureSession.isRunning else { throw CameraServiceError.notReady }
        isCapturingPhoto = true

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            settings.photoQualityPrioritization = .quality
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .balanced
        }

        return try await withCheckedThrowingContinuation { continuation in
            let uniqueID = settings.uniqueID
            let delegate = CameraPhotoDelegate(
                expectsHEVC: settings.processedFileType == .heic,
                completion: { [weak self] result in
                    Task { @MainActor in
                        self?.isCapturingPhoto = false
                        self?.photoDelegates[uniqueID] = nil
                        continuation.resume(with: result)
                    }
                }
            )
            photoDelegates[uniqueID] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func setZoomFactor(_ requestedDisplayFactor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let displayFactor = min(max(requestedDisplayFactor, zoomRange.lowerBound), zoomRange.upperBound)
        let deviceFactor = displayFactor / device.displayVideoZoomFactorMultiplier
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = min(
                max(deviceFactor, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
            device.unlockForConfiguration()
            zoomFactor = device.videoZoomFactor * device.displayVideoZoomFactorMultiplier
        } catch {
            return
        }
    }

    func switchCamera() throws {
        guard !isCapturingPhoto else { throw CameraServiceError.notReady }
        let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        guard let camera = Self.preferredCamera(position: newPosition) else {
            throw newPosition == .front ? CameraServiceError.noFrontCamera : CameraServiceError.noBackCamera
        }
        let newInput = try AVCaptureDeviceInput(device: camera)
        let oldInput = videoInput

        captureSession.beginConfiguration()
        if let oldInput { captureSession.removeInput(oldInput) }
        guard captureSession.canAddInput(newInput) else {
            if let oldInput, captureSession.canAddInput(oldInput) { captureSession.addInput(oldInput) }
            captureSession.commitConfiguration()
            throw CameraServiceError.cannotAddInput
        }
        captureSession.addInput(newInput)
        videoInput = newInput
        configureVideoConnection()
        captureSession.commitConfiguration()

        updateCameraState(for: camera, resetZoom: true)
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .photo

        guard let camera = Self.preferredCamera(position: .back) else {
            throw CameraServiceError.noBackCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else { throw CameraServiceError.cannotAddInput }
        captureSession.addInput(input)
        videoInput = input

        guard captureSession.canAddOutput(photoOutput) else {
            throw CameraServiceError.cannotAddPhotoOutput
        }
        captureSession.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraServiceError.cannotAddVideoOutput
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        videoOutput.setSampleBufferDelegate(
            videoDelegate,
            queue: DispatchQueue(label: "com.example.RemoteCamPreview.camera-video", qos: .userInteractive)
        )
        captureSession.addOutput(videoOutput)

        configureVideoConnection()
        updateCameraState(for: camera, resetZoom: true)
    }

    private func configureVideoConnection() {
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func updateCameraState(for device: AVCaptureDevice, resetZoom: Bool) {
        cameraPosition = device.position
        let formatDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        previewDimensions = PixelDimensions(
            width: Int(formatDimensions.height),
            height: Int(formatDimensions.width)
        )
        let multiplier = device.displayVideoZoomFactorMultiplier
        let minimum = device.minAvailableVideoZoomFactor * multiplier
        let availableMaximum = device.maxAvailableVideoZoomFactor * multiplier

        var presets = [minimum]
        presets.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors.map {
            CGFloat(truncating: $0) * multiplier
        })
        if minimum <= 1, availableMaximum >= 1 { presets.append(1) }
        zoomPresets = presets
            .filter { $0 >= minimum && $0 <= availableMaximum }
            .sorted()
            .reduce(into: []) { result, factor in
                if result.last.map({ abs($0 - factor) > 0.05 }) ?? true {
                    result.append(factor)
                }
            }

        let nativeMaximum = zoomPresets.last ?? minimum
        let userMaximum = max(5, nativeMaximum * 5)
        zoomRange = minimum...min(availableMaximum, userMaximum)
        canSwitchCamera = Self.preferredCamera(
            position: device.position == .back ? .front : .back
        ) != nil

        if resetZoom {
            setZoomFactor(zoomRange.contains(1) ? 1 : minimum)
        } else {
            zoomFactor = device.videoZoomFactor * multiplier
        }
    }

    private static func preferredCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]

        for deviceType in deviceTypes {
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: position) {
                return device
            }
        }
        return nil
    }
}

private final class CameraVideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    var onDimensionsChanged: (@Sendable (PixelDimensions) -> Void)?
    private var lastDimensions: PixelDimensions?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let dimensions = PixelDimensions(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            if dimensions != lastDimensions {
                lastDimensions = dimensions
                onDimensionsChanged?(dimensions)
            }
        }
        onSampleBuffer?(sampleBuffer)
    }
}

private final class CameraPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let expectsHEVC: Bool
    private let completion: @Sendable (Result<CapturedPhoto, Error>) -> Void
    private var completed = false

    init(
        expectsHEVC: Bool,
        completion: @escaping @Sendable (Result<CapturedPhoto, Error>) -> Void
    ) {
        self.expectsHEVC = expectsHEVC
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !completed else { return }
        completed = true
        if let error {
            completion(.failure(CameraServiceError.captureFailed(error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(CameraServiceError.photoDataUnavailable))
            return
        }

        let dimensions = Self.dimensions(of: photo, data: data)
        let fileExtension = expectsHEVC ? "heic" : "jpg"
        completion(.success(CapturedPhoto(
            data: data,
            fileName: "RemoteCam-\(Self.fileTimestamp).\(fileExtension)",
            mimeType: expectsHEVC ? "image/heic" : "image/jpeg",
            dimensions: dimensions
        )))
    }

    private static func dimensions(of photo: AVCapturePhoto, data: Data) -> PixelDimensions {
        if let pixelBuffer = photo.pixelBuffer {
            return PixelDimensions(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return PixelDimensions(width: 0, height: 0) }
        return PixelDimensions(width: width, height: height)
    }

    private static var fileTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
