import Foundation
import XCTest
@testable import RemoteCamPreview

final class SessionStateMachineTests: XCTestCase {
    func testSharedValidStateVectors() throws {
        let vector = try TestSupport.vector(named: "session-state")
        let valid = try XCTUnwrap(vector["valid"] as? [[String: Any]])
        for item in valid {
            let initial = try XCTUnwrap(ProtocolSessionState(rawValue: try XCTUnwrap(item["initial"] as? String)))
            let events = try XCTUnwrap(item["events"] as? [String])
            let expected = try XCTUnwrap(item["expectedStates"] as? [String])
            var machine = SessionStateMachine(state: initial)
            var actual: [String] = []
            for event in events { actual.append(try machine.apply(event).rawValue) }
            XCTAssertEqual(actual, expected, item["name"] as? String ?? "")
        }
    }
}

