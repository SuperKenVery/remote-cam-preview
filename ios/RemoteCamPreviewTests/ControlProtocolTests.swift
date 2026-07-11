import Foundation
import XCTest
@testable import RemoteCamPreview

final class ControlProtocolTests: XCTestCase {
    func testEverySharedValidControlVectorDecodes() throws {
        let vector = try TestSupport.vector(named: "control-messages")
        let valid = try XCTUnwrap(vector["valid"] as? [[String: Any]])

        for item in valid {
            let name = try XCTUnwrap(item["name"] as? String)
            let message = try XCTUnwrap(item["message"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            XCTAssertNoThrow(try ControlMessageCodec.decode(data), name)
        }
    }

    func testEverySharedInvalidControlVectorIsRejected() throws {
        let vector = try TestSupport.vector(named: "control-messages")
        let invalid = try XCTUnwrap(vector["invalid"] as? [[String: Any]])
        XCTAssertEqual(invalid.count, 10)

        for item in invalid {
            let name = try XCTUnwrap(item["name"] as? String)
            let data: Data
            if let wireText = item["wireText"] as? String {
                data = Data(wireText.utf8)
            } else {
                let message = try XCTUnwrap(item["message"] as? [String: Any])
                data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            }
            XCTAssertThrowsError(try ControlMessageCodec.decode(data), name)
        }
    }

    func testUnsupportedMajorVersionIsRejected() throws {
        let message = ControlMessage(
            type: "heartbeat.ping",
            requestId: "ping-1",
            protocolVersion: "2.0",
            payload: ["sentAtMs": .integer(1)]
        )
        XCTAssertThrowsError(try ControlMessageCodec.encode(message)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .unsupportedMajorVersion("2.0"))
        }
    }

    func testCanonicalEnvelopeUsesStringVersionAndSharedNames() throws {
        let message = ControlMessage.keyframeRequest(mediaSsrc: 0x1020_3040, reason: "loss")
        let object = try JSONSerialization.jsonObject(with: ControlMessageCodec.encode(message)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "keyframe.request")
        XCTAssertEqual(object?["protocolVersion"] as? String, "1.0")
    }
}
