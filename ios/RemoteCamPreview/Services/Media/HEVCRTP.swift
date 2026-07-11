import Foundation

struct RTPPacket: Equatable, Sendable {
    static let headerSize = 12

    var marker: Bool
    var payloadType: UInt8
    var sequenceNumber: UInt16
    var timestamp: UInt32
    var ssrc: UInt32
    var payload: Data

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(0x80)
        data.append((marker ? 0x80 : 0) | (payloadType & 0x7f))
        data.appendUInt16(sequenceNumber)
        data.appendUInt32(timestamp)
        data.appendUInt32(ssrc)
        data.append(payload)
        return data
    }

    init(
        marker: Bool,
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    ) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    init(encoded data: Data, maximumPacketSize: Int = 2_048) throws {
        guard data.count >= Self.headerSize, data.count <= maximumPacketSize else {
            throw HEVCRTPError.malformedPacket
        }
        let bytes = [UInt8](data.prefix(Self.headerSize))
        guard bytes[0] >> 6 == 2, bytes[0] & 0x0f == 0 else {
            throw HEVCRTPError.unsupportedRTPHeader
        }
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7f
        sequenceNumber = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        ssrc = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        payload = data.dropFirst(Self.headerSize)
        guard !payload.isEmpty else { throw HEVCRTPError.malformedPacket }
    }
}

enum HEVCRTPError: LocalizedError, Equatable {
    case malformedNALUnit
    case malformedPacket
    case unsupportedRTPHeader
    case packetTooSmall
    case fragmentDiscontinuity
    case resourceLimit

    var errorDescription: String? {
        switch self {
        case .malformedNALUnit: "HEVC NAL 单元无效"
        case .malformedPacket: "RTP 包无效"
        case .unsupportedRTPHeader: "RTP 头格式不受支持"
        case .packetTooSmall: "路径 MTU 太小，无法封装 HEVC"
        case .fragmentDiscontinuity: "HEVC 分片丢失或乱序"
        case .resourceLimit: "HEVC/RTP 输入超过会话资源上限"
        }
    }
}

struct HEVCRTPPacketizer: Sendable {
    var payloadType: UInt8 = 96
    var ssrc: UInt32
    var maximumPacketSize: Int = 1_200
    private(set) var nextSequenceNumber: UInt16

    init(
        payloadType: UInt8 = 96,
        ssrc: UInt32,
        maximumPacketSize: Int = 1_200,
        initialSequenceNumber: UInt16 = .random(in: .min ... .max)
    ) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.maximumPacketSize = maximumPacketSize
        nextSequenceNumber = initialSequenceNumber
    }

    mutating func packetize(accessUnit nalUnits: [Data], timestamp: UInt32) throws -> [RTPPacket] {
        guard maximumPacketSize > RTPPacket.headerSize + 5 else {
            throw HEVCRTPError.packetTooSmall
        }
        guard (1 ... 1_024).contains(nalUnits.count),
              nalUnits.allSatisfy({ (2 ... 16 * 1_024 * 1_024).contains($0.count) }),
              nalUnits.reduce(into: 0, { $0 += $1.count }) <= 64 * 1_024 * 1_024
        else { throw HEVCRTPError.resourceLimit }

        var packets: [RTPPacket] = []
        let maxPayload = maximumPacketSize - RTPPacket.headerSize
        var firstUnaggregatedIndex = 0

        if nalUnits.count >= 2 {
            var aggregationSize = 2
            var aggregationCount = 0
            for nal in nalUnits {
                guard nal.count <= UInt16.max else { break }
                let candidate = aggregationSize + 2 + nal.count
                guard candidate <= maxPayload else { break }
                aggregationSize = candidate
                aggregationCount += 1
            }
            if aggregationCount >= 2 {
                let aggregated = Array(nalUnits.prefix(aggregationCount))
                var layerId = UInt8.max
                var temporalId = UInt8.max
                var forbiddenBit: UInt8 = 0
                for nal in aggregated {
                    forbiddenBit |= nal[0] & 0x80
                    layerId = min(layerId, ((nal[0] & 0x01) << 5) | ((nal[1] >> 3) & 0x1f))
                    temporalId = min(temporalId, nal[1] & 0x07)
                }
                guard temporalId != 0 else { throw HEVCRTPError.malformedNALUnit }
                var payload = Data([
                    forbiddenBit | (48 << 1) | (layerId >> 5),
                    (layerId << 3) | temporalId,
                ])
                for nal in aggregated {
                    payload.append(UInt8(truncatingIfNeeded: nal.count >> 8))
                    payload.append(UInt8(truncatingIfNeeded: nal.count))
                    payload.append(nal)
                }
                packets.append(makePacket(
                    payload: payload,
                    timestamp: timestamp,
                    marker: aggregationCount == nalUnits.count
                ))
                firstUnaggregatedIndex = aggregationCount
            }
        }

        for nalIndex in firstUnaggregatedIndex ..< nalUnits.count {
            let nalUnit = nalUnits[nalIndex]
            guard nalUnit.count >= 2 else { throw HEVCRTPError.malformedNALUnit }
            if nalUnit.count <= maxPayload {
                packets.append(makePacket(
                    payload: nalUnit,
                    timestamp: timestamp,
                    marker: nalIndex == nalUnits.count - 1
                ))
                guard packets.count <= 4_096 else { throw HEVCRTPError.resourceLimit }
                continue
            }

            let bytes = [UInt8](nalUnit.prefix(2))
            let originalType = (bytes[0] >> 1) & 0x3f
            let fuIndicator0 = (bytes[0] & 0x81) | (49 << 1)
            let fuIndicator1 = bytes[1]
            let fragmentCapacity = maxPayload - 3
            let body = nalUnit.dropFirst(2)
            var offset = 0

            while offset < body.count {
                let count = min(fragmentCapacity, body.count - offset)
                let start = offset == 0
                let end = offset + count == body.count
                var payload = Data([fuIndicator0, fuIndicator1])
                payload.append((start ? 0x80 : 0) | (end ? 0x40 : 0) | originalType)
                payload.append(body[offset ..< offset + count])
                packets.append(makePacket(
                    payload: payload,
                    timestamp: timestamp,
                    marker: end && nalIndex == nalUnits.count - 1
                ))
                guard packets.count <= 4_096 else { throw HEVCRTPError.resourceLimit }
                offset += count
            }
        }
        return packets
    }

    private mutating func makePacket(payload: Data, timestamp: UInt32, marker: Bool) -> RTPPacket {
        defer { nextSequenceNumber &+= 1 }
        return RTPPacket(
            marker: marker,
            payloadType: payloadType,
            sequenceNumber: nextSequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            payload: payload
        )
    }
}

struct DepacketizedNALUnit: Equatable, Sendable {
    var data: Data
    var timestamp: UInt32
    var endsAccessUnit: Bool
}

struct HEVCRTPDepacketizer: Sendable {
    private var fragmentBuffer: Data?
    private var fragmentTimestamp: UInt32?
    private var expectedSequenceNumber: UInt16?

    mutating func ingest(_ packet: RTPPacket) throws -> [DepacketizedNALUnit] {
        guard packet.payload.count >= 2 else { throw HEVCRTPError.malformedPacket }
        let payload = [UInt8](packet.payload)
        let nalType = (payload[0] >> 1) & 0x3f

        switch nalType {
        case 0 ... 47:
            resetFragments()
            return [DepacketizedNALUnit(
                data: packet.payload,
                timestamp: packet.timestamp,
                endsAccessUnit: packet.marker
            )]

        case 48:
            resetFragments()
            return try unpackAggregation(packet)

        case 49:
            return try ingestFragment(packet)

        default:
            throw HEVCRTPError.malformedPacket
        }
    }

    private mutating func ingestFragment(_ packet: RTPPacket) throws -> [DepacketizedNALUnit] {
        guard packet.payload.count >= 4 else { throw HEVCRTPError.malformedPacket }
        let payload = [UInt8](packet.payload)
        let start = payload[2] & 0x80 != 0
        let end = payload[2] & 0x40 != 0
        let originalType = payload[2] & 0x3f

        if start {
            let originalHeader0 = (payload[0] & 0x81) | (originalType << 1)
            fragmentBuffer = Data([originalHeader0, payload[1]])
            fragmentBuffer?.append(packet.payload.dropFirst(3))
            guard fragmentBuffer!.count <= 16 * 1_024 * 1_024 else {
                resetFragments()
                throw HEVCRTPError.resourceLimit
            }
            fragmentTimestamp = packet.timestamp
            expectedSequenceNumber = packet.sequenceNumber &+ 1
        } else {
            guard fragmentBuffer != nil,
                  fragmentTimestamp == packet.timestamp,
                  expectedSequenceNumber == packet.sequenceNumber
            else {
                resetFragments()
                throw HEVCRTPError.fragmentDiscontinuity
            }
            fragmentBuffer?.append(packet.payload.dropFirst(3))
            guard fragmentBuffer!.count <= 16 * 1_024 * 1_024 else {
                resetFragments()
                throw HEVCRTPError.resourceLimit
            }
            expectedSequenceNumber = packet.sequenceNumber &+ 1
        }

        guard end, let nal = fragmentBuffer else { return [] }
        let result = DepacketizedNALUnit(
            data: nal,
            timestamp: packet.timestamp,
            endsAccessUnit: packet.marker
        )
        resetFragments()
        return [result]
    }

    private mutating func unpackAggregation(_ packet: RTPPacket) throws -> [DepacketizedNALUnit] {
        var offset = 2
        var result: [DepacketizedNALUnit] = []
        while offset < packet.payload.count {
            guard result.count < 1_024 else { throw HEVCRTPError.resourceLimit }
            guard offset + 2 <= packet.payload.count else { throw HEVCRTPError.malformedPacket }
            let length = Int(packet.payload[offset]) << 8 | Int(packet.payload[offset + 1])
            offset += 2
            guard length >= 2, offset + length <= packet.payload.count else {
                throw HEVCRTPError.malformedPacket
            }
            result.append(DepacketizedNALUnit(
                data: packet.payload[offset ..< offset + length],
                timestamp: packet.timestamp,
                endsAccessUnit: false
            ))
            offset += length
        }
        if !result.isEmpty { result[result.count - 1].endsAccessUnit = packet.marker }
        return result
    }

    private mutating func resetFragments() {
        fragmentBuffer = nil
        fragmentTimestamp = nil
        expectedSequenceNumber = nil
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
