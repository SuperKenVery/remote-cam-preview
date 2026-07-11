import Foundation
import XCTest
@testable import RemoteCamPreview

final class HEVCRTPTests: XCTestCase {
    func testSingleNALMatchesSharedVector() throws {
        let item = try sharedValidItem(named: "single NAL unit")
        try assertPacketizerMatches(item)
    }

    func testFUFragmentationMatchesSharedVector() throws {
        let item = try sharedValidItem(named: "FU fragmentation reordering and sequence wrap")
        try assertPacketizerMatches(item)
    }

    func testAggregationMatchesSharedVector() throws {
        let item = try sharedValidItem(named: "VPS SPS PPS aggregation and sequence wrap")
        try assertPacketizerMatches(item)
    }

    func testFragmentRoundTrip() throws {
        let item = try sharedValidItem(named: "FU fragmentation reordering and sequence wrap")
        let nalHex = try XCTUnwrap((item["nalUnitsHex"] as? [String])?.first)
        let original = try TestSupport.data(hex: nalHex)
        let config = try XCTUnwrap(item["config"] as? [String: Any])
        var packetizer = HEVCRTPPacketizer(
            payloadType: UInt8(try int(config, "payloadType")),
            ssrc: UInt32(try int(config, "ssrc")),
            maximumPacketSize: try int(config, "maxRtpPacketSize"),
            initialSequenceNumber: UInt16(try int(config, "initialSequence"))
        )
        let packets = try packetizer.packetize(
            accessUnit: [original],
            timestamp: UInt32(try int(config, "timestamp"))
        )
        var depacketizer = HEVCRTPDepacketizer()
        let output = try packets.flatMap { try depacketizer.ingest($0) }
        XCTAssertEqual(output.map(\.data), [original])
        XCTAssertTrue(output.last?.endsAccessUnit == true)
    }

    private func assertPacketizerMatches(_ item: [String: Any]) throws {
        let config = try XCTUnwrap(item["config"] as? [String: Any])
        let nalHex = try XCTUnwrap(item["nalUnitsHex"] as? [String])
        let expectedHex = try XCTUnwrap(item["packetsHex"] as? [String])
        var packetizer = HEVCRTPPacketizer(
            payloadType: UInt8(try int(config, "payloadType")),
            ssrc: UInt32(try int(config, "ssrc")),
            maximumPacketSize: try int(config, "maxRtpPacketSize"),
            initialSequenceNumber: UInt16(try int(config, "initialSequence"))
        )
        let packets = try packetizer.packetize(
            accessUnit: try nalHex.map(TestSupport.data(hex:)),
            timestamp: UInt32(try int(config, "timestamp"))
        )
        XCTAssertEqual(packets.map { $0.encoded() }, try expectedHex.map(TestSupport.data(hex:)))
        XCTAssertEqual(Int(packetizer.nextSequenceNumber), try int(item, "nextSequence"))
    }

    private func sharedValidItem(named name: String) throws -> [String: Any] {
        let vector = try TestSupport.vector(named: "hevc-rtp")
        let valid = try XCTUnwrap(vector["valid"] as? [[String: Any]])
        return try XCTUnwrap(valid.first { $0["name"] as? String == name })
    }

    private func int(_ object: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap((object[key] as? NSNumber)?.intValue)
    }
}
