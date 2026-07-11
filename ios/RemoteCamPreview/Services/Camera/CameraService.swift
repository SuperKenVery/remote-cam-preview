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
    var onVideoSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? {
        didSet { videoDelegate.onSampleBuffer = onVideoSampleBuffer }
    }

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoDelegate = CameraVideoDelegate()
    private var photoDelegates: [Int64: CameraPhotoDelegate] = [:]
    private var configured = false

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

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else { throw CameraServiceError.noBackCamera }

        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else { throw CameraServiceError.cannotAddInput }
        captureSession.addInput(input)

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

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private final class CameraVideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
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

