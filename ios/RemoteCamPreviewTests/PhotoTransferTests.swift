import Foundation
import XCTest
@testable import RemoteCamPreview

final class PhotoTransferTests: XCTestCase {
    func testSharedMetadataAndIntegrityVector() async throws {
        let vector = try TestSupport.vector(named: "photo-integrity")
        let validMetadata = try XCTUnwrap(vector["validMetadata"] as? [[String: Any]])
        let metadataObject = try XCTUnwrap(validMetadata.first?["metadata"] as? [String: Any])
        let payload = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONSerialization.data(withJSONObject: metadataObject)
        )
        let metadata = try PhotoMetadata(controlPayload: payload)
        XCTAssertEqual(metadata.byteSize, 28)
        XCTAssertEqual(metadata.downloadPath, "/v1/photos/\(metadata.photoId)")

        let integrity = try XCTUnwrap(vector["integrity"] as? [[String: Any]])
        let matching = try XCTUnwrap(integrity.first { $0["valid"] as? Bool == true })
        let content = try TestSupport.data(hex: try XCTUnwrap(matching["contentHex"] as? String))
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = PhotoResourceStore()
        try await store.validateReceivedFile(at: url, metadata: metadata)
    }

    func testInvalidSharedMetadataIsRejected() throws {
        let vector = try TestSupport.vector(named: "photo-integrity")
        let invalid = try XCTUnwrap(vector["invalidMetadata"] as? [[String: Any]])
        for item in invalid {
            let object = try XCTUnwrap(item["metadata"] as? [String: Any])
            let payload = try JSONDecoder().decode(
                [String: JSONValue].self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertThrowsError(try PhotoMetadata(controlPayload: payload), item["name"] as? String ?? "")
        }
    }
}

