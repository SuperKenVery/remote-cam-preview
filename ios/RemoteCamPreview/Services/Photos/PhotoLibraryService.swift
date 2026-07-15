import Foundation
import OSLog
import Photos

private let photoLibraryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "RemoteCamPreview",
    category: "PhotoLibrary"
)

enum PhotoLibraryError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "照片库写入权限被拒绝。请在“设置”中允许添加照片。"
    }
}

struct PhotoLibraryService: Sendable {
    func save(data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        photoLibraryLogger.notice("Photo add-only authorization status=\(status.rawValue)")
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    func saveFile(at url: URL, originalFileName: String? = nil) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        photoLibraryLogger.notice("Photo add-only authorization status=\(status.rawValue)")
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = originalFileName
                request.addResource(with: .photo, fileURL: url, options: options)
            }
            photoLibraryLogger.notice(
                "PhotoKit saved received resource extension=\(url.pathExtension, privacy: .public)"
            )
        } catch {
            let nsError = error as NSError
            photoLibraryLogger.error(
                "PhotoKit save failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code) extension=\(url.pathExtension, privacy: .public)"
            )
            throw error
        }
    }
}
