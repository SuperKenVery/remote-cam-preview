import Foundation
import Network
import OSLog

private let photoHTTPLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "RemoteCamPreview",
    category: "PhotoHTTP"
)

enum PhotoHTTPConnectionError: LocalizedError {
    case malformedResponse
    case unexpectedStatus(Int)
    case truncatedBody
    case oversizedBody

    var errorDescription: String? {
        switch self {
        case .malformedResponse: "成片 HTTP 响应格式无效"
        case .unexpectedStatus(let status): "成片 HTTP 请求失败（\(status)）"
        case .truncatedBody: "成片 HTTP 响应提前结束"
        case .oversizedBody: "成片 HTTP 响应超过声明长度"
        }
    }
}

enum PhotoHTTPConnection {
    static func serve(
        over connection: NetworkConnection<TCP>,
        store: PhotoResourceStore,
        bearerToken: String
    ) async throws {
        do {
            let request = try await readHeader(over: connection)
            let response = try await PhotoHTTPService(store: store).response(
                for: request,
                expectedBearerToken: bearerToken
            )
            var header = "HTTP/1.1 200 OK\r\n"
            for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
                header += "\(name): \(value)\r\n"
            }
            header += "Connection: close\r\n\r\n"
            try await connection.send(Data(header.utf8))
            for try await chunk in response.chunks() {
                try Task.checkCancellation()
                try await connection.send(chunk)
            }
            try await connection.send(Data(), endOfStream: true)
        } catch {
            let status: Int
            switch error {
            case PhotoTransferError.unauthorized: status = 401
            case PhotoTransferError.notFound, PhotoTransferError.expired: status = 404
            default: status = 400
            }
            let body = Data(error.localizedDescription.utf8)
            let response = Data(
                "HTTP/1.1 \(status) Error\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
            )
            try? await connection.send(response)
            try? await connection.send(body, endOfStream: true)
            throw error
        }
    }

    static func download(
        metadata: PhotoMetadata,
        bearerToken: String,
        over connection: NetworkConnection<TCP>
    ) async throws -> URL {
        let request = Data(
            "GET \(metadata.downloadPath) HTTP/1.1\r\nHost: wifi-aware-peer\r\nAuthorization: Bearer \(bearerToken)\r\nAccept: \(metadata.mimeType)\r\nConnection: close\r\n\r\n".utf8
        )
        try Task.checkCancellation()
        try await connection.send(request)

        var buffered = Data()
        let separator = Data("\r\n\r\n".utf8)
        var bodyStart: Data.Index?
        while bodyStart == nil {
            try Task.checkCancellation()
            let frame = try await connection.receive(atLeast: 1, atMost: 4_096)
            buffered.append(frame.content)
            guard buffered.count <= PhotoHTTPService.maximumHeaderBytes + 4_096 else {
                throw PhotoHTTPConnectionError.malformedResponse
            }
            if let range = buffered.range(of: separator) { bodyStart = range.upperBound }
        }

        let index = bodyStart!
        let headerData = buffered[..<index]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw PhotoHTTPConnectionError.malformedResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw PhotoHTTPConnectionError.malformedResponse }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw PhotoHTTPConnectionError.malformedResponse
        }
        guard status == 200 else { throw PhotoHTTPConnectionError.unexpectedStatus(status) }
        let contentLength = headerValue("content-length", in: lines).flatMap(Int64.init)
        guard contentLength == metadata.byteSize else {
            throw PhotoTransferError.invalidLength(
                expected: metadata.byteSize,
                actual: contentLength ?? -1
            )
        }

        let fileExtension = URL(filePath: metadata.fileName).pathExtension
        let receivedFileName = fileExtension.isEmpty
            ? "remote-cam-receive-\(metadata.photoId)"
            : "remote-cam-receive-\(metadata.photoId).\(fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: receivedFileName)
        photoHTTPLogger.notice(
            "Downloading photo bytes=\(metadata.byteSize) mime=\(metadata.mimeType, privacy: .public) extension=\(fileExtension, privacy: .public)"
        )
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            var received: Int64 = 0
            let initialBody = Data(buffered[index...])
            if !initialBody.isEmpty {
                guard Int64(initialBody.count) <= metadata.byteSize else {
                    throw PhotoHTTPConnectionError.oversizedBody
                }
                try handle.write(contentsOf: initialBody)
                received += Int64(initialBody.count)
            }

            while received < metadata.byteSize {
                try Task.checkCancellation()
                let maximum = min(64 * 1_024, Int(metadata.byteSize - received))
                let frame = try await connection.receive(atLeast: 1, atMost: maximum)
                guard !frame.content.isEmpty else { throw PhotoHTTPConnectionError.truncatedBody }
                guard received + Int64(frame.content.count) <= metadata.byteSize else {
                    throw PhotoHTTPConnectionError.oversizedBody
                }
                try handle.write(contentsOf: frame.content)
                received += Int64(frame.content.count)
            }
            try handle.close()
            photoHTTPLogger.notice("Photo download completed bytes=\(received)")
            return fileURL
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    private static func readHeader(over connection: NetworkConnection<TCP>) async throws -> Data {
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            let frame = try await connection.receive(atLeast: 1, atMost: 4_096)
            guard !frame.content.isEmpty else { throw PhotoTransferError.malformedRequest }
            data.append(frame.content)
            guard data.count <= PhotoHTTPService.maximumHeaderBytes else {
                throw PhotoTransferError.malformedRequest
            }
        }
        return data
    }

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        let prefix = name.lowercased() + ":"
        return lines.first { $0.lowercased().hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }
}
