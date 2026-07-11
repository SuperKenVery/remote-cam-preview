import CryptoKit
import Foundation

struct PhotoMetadata: Codable, Equatable, Sendable {
    var photoId: String
    var fileName: String
    var mimeType: String
    var byteSize: Int64
    var widthPx: Int
    var heightPx: Int
    var sha256: String
    var downloadPath: String

    var dimensions: PixelDimensions {
        PixelDimensions(width: widthPx, height: heightPx)
    }

    var controlPayload: [String: JSONValue] {
        [
            "photoId": .string(photoId),
            "fileName": .string(fileName),
            "mimeType": .string(mimeType),
            "byteSize": .integer(Int(byteSize)),
            "widthPx": .integer(widthPx),
            "heightPx": .integer(heightPx),
            "sha256": .string(sha256),
            "downloadPath": .string(downloadPath),
        ]
    }

    init(
        photoId: String,
        fileName: String,
        mimeType: String,
        byteSize: Int64,
        widthPx: Int,
        heightPx: Int,
        sha256: String,
        downloadPath: String
    ) {
        self.photoId = photoId
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.sha256 = sha256
        self.downloadPath = downloadPath
    }

    init(controlPayload: [String: JSONValue]) throws {
        guard case .string(let photoId)? = controlPayload["photoId"],
              case .string(let fileName)? = controlPayload["fileName"],
              case .string(let mimeType)? = controlPayload["mimeType"],
              case .integer(let byteSize)? = controlPayload["byteSize"],
              case .integer(let widthPx)? = controlPayload["widthPx"],
              case .integer(let heightPx)? = controlPayload["heightPx"],
              case .string(let sha256)? = controlPayload["sha256"],
              case .string(let downloadPath)? = controlPayload["downloadPath"],
              photoId.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil,
              !fileName.contains("/"), !fileName.contains("\\"), fileName != ".", fileName != "..",
              ["image/jpeg", "image/heic", "image/heif", "image/dng", "image/x-adobe-dng"].contains(mimeType),
              (1 ... 536_870_912).contains(byteSize),
              (1 ... 65_535).contains(widthPx), (1 ... 65_535).contains(heightPx),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              downloadPath == "/v1/photos/\(photoId)"
        else { throw PhotoTransferError.malformedRequest }

        self.init(
            photoId: photoId,
            fileName: fileName,
            mimeType: mimeType,
            byteSize: Int64(byteSize),
            widthPx: widthPx,
            heightPx: heightPx,
            sha256: sha256,
            downloadPath: downloadPath
        )
    }
}

struct PhotoResource: Sendable {
    var metadata: PhotoMetadata
    var fileURL: URL
    var expiresAt: Date
}

enum PhotoTransferError: LocalizedError, Equatable {
    case notFound
    case expired
    case invalidLength(expected: Int64, actual: Int64)
    case checksumMismatch
    case malformedRequest
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .notFound: "成片资源不存在"
        case .expired: "成片资源已过期"
        case .invalidLength(let expected, let actual): "成片长度不符（应为 \(expected)，实际为 \(actual)）"
        case .checksumMismatch: "成片 SHA-256 校验失败"
        case .malformedRequest: "HTTP 请求格式无效"
        case .unauthorized: "会话令牌无效"
        }
    }
}

actor PhotoResourceStore {
    private var resources: [String: PhotoResource] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 5 * 60) {
        self.lifetime = lifetime
    }

    func register(
        data: Data,
        fileName: String,
        mimeType: String,
        dimensions: PixelDimensions
    ) throws -> PhotoResource {
        removeExpired()
        let photoId = "photo_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = FileManager.default.temporaryDirectory
            .appending(path: "remote-cam-\(photoId).photo")
        try data.write(to: url, options: [.atomic, .completeFileProtection])

        let metadata = PhotoMetadata(
            photoId: photoId,
            fileName: fileName,
            mimeType: mimeType,
            byteSize: Int64(data.count),
            widthPx: dimensions.width,
            heightPx: dimensions.height,
            sha256: SHA256.hash(data: data).hexString,
            downloadPath: "/v1/photos/\(photoId)"
        )
        let resource = PhotoResource(
            metadata: metadata,
            fileURL: url,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        resources[photoId] = resource
        return resource
    }

    func resource(photoId: String) throws -> PhotoResource {
        removeExpired()
        guard let resource = resources[photoId] else { throw PhotoTransferError.notFound }
        guard resource.expiresAt > Date() else {
            try? FileManager.default.removeItem(at: resource.fileURL)
            resources[photoId] = nil
            throw PhotoTransferError.expired
        }
        return resource
    }

    func acknowledge(photoId: String) {
        guard let resource = resources.removeValue(forKey: photoId) else { return }
        try? FileManager.default.removeItem(at: resource.fileURL)
    }

    func removeAll() {
        for resource in resources.values {
            try? FileManager.default.removeItem(at: resource.fileURL)
        }
        resources.removeAll()
    }

    func validateReceivedFile(at url: URL, metadata: PhotoMetadata) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualLength = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualLength == metadata.byteSize else {
            throw PhotoTransferError.invalidLength(expected: metadata.byteSize, actual: actualLength)
        }
        guard try Self.sha256(of: url) == metadata.sha256.lowercased() else {
            throw PhotoTransferError.checksumMismatch
        }
    }

    private func removeExpired() {
        let now = Date()
        let expired = resources.values.filter { $0.expiresAt <= now }
        for resource in expired {
            try? FileManager.default.removeItem(at: resource.fileURL)
            resources[resource.metadata.photoId] = nil
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }
}

struct PhotoHTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var fileURL: URL?

    func chunks(chunkSize: Int = 64 * 1024) -> AsyncThrowingStream<Data, Error> {
        guard let fileURL else {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }
                    while !Task.isCancelled {
                        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                        if chunk.isEmpty { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct PhotoHTTPService: Sendable {
    static let maximumHeaderBytes = 8 * 1024
    let store: PhotoResourceStore

    func response(for request: Data, expectedBearerToken: String) async throws -> PhotoHTTPResponse {
        guard request.count <= Self.maximumHeaderBytes,
              let string = String(data: request, encoding: .utf8)
        else { throw PhotoTransferError.malformedRequest }

        let lines = string.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw PhotoTransferError.malformedRequest }
        let requestParts = first.split(separator: " ")
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              requestParts[2] == "HTTP/1.1"
        else { throw PhotoTransferError.malformedRequest }

        let authorization = lines.first {
            $0.lowercased().hasPrefix("authorization:")
        }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        guard authorization == "Bearer \(expectedBearerToken)" else {
            throw PhotoTransferError.unauthorized
        }

        let path = String(requestParts[1])
        let prefix = "/v1/photos/"
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            throw PhotoTransferError.malformedRequest
        }
        let photoId = String(path.dropFirst(prefix.count))
        let resource = try await store.resource(photoId: photoId)
        return PhotoHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": resource.metadata.mimeType,
                "Content-Length": String(resource.metadata.byteSize),
                "Digest": "sha-256=\(resource.metadata.sha256)",
                "Cache-Control": "no-store",
            ],
            fileURL: resource.fileURL
        )
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
