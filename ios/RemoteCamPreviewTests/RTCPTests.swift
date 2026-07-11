import Foundation
import XCTest
@testable import RemoteCamPreview

final class RTCPTests: XCTestCase {
    func testSharedReceiverReportVector() throws {
        let vectors = try TestSupport.vector(named: "rtcp")
        let item = try XCTUnwrap((vectors["validReceiverReports"] as? [[String: Any]])?.first)
        let blocks = try XCTUnwrap(item["blocks"] as? [[String: Any]])
        let block = try XCTUnwrap(blocks.first)
        let packet = RTCP.receiverReport(
            senderSSRC: UInt32(try int(item, "senderSsrc")),
            mediaSSRC: UInt32(try int(block, "sourceSsrc")),
            fractionLost: UInt8(try int(block, "fractionLost")),
            cumulativeLost: Int32(try int(block, "cumulativeLost")),
            extendedHighestSequence: UInt32(try int(block, "extendedHighestSequence")),
            jitter: UInt32(try int(block, "interarrivalJitter")),
            lastSenderReport: UInt32(try int(block, "lastSenderReport")),
            delaySinceLastSenderReport: UInt32(try int(block, "delaySinceLastSenderReport"))
        )
        XCTAssertEqual(packet, try TestSupport.data(hex: try XCTUnwrap(item["packetHex"] as? String)))
    }

    func testSharedPLIAndCompoundDatagram() throws {
        let vectors = try TestSupport.vector(named: "rtcp")
        let pli = try XCTUnwrap((vectors["validPli"] as? [[String: Any]])?.first)
        let sender = UInt32(try int(pli, "senderSsrc"))
        let media = UInt32(try int(pli, "mediaSsrc"))
        XCTAssertEqual(
            RTCP.pictureLossIndication(senderSSRC: sender, mediaSSRC: media),
            try TestSupport.data(hex: try XCTUnwrap(pli["packetHex"] as? String))
        )

        let compound = try XCTUnwrap((vectors["validDatagrams"] as? [[String: Any]])?.first)
        XCTAssertTrue(try RTCP.containsPictureLossIndication(
            TestSupport.data(hex: try XCTUnwrap(compound["datagramHex"] as? String)),
            expectedMediaSSRC: media
        ))
    }

    private func int(_ object: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap((object[key] as? NSNumber)?.intValue)
    }
}
