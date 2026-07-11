import Foundation

enum RTCPError: LocalizedError, Equatable {
    case malformedPacket
    case unsupportedPacket
    case unexpectedSSRC

    var errorDescription: String? {
        switch self {
        case .malformedPacket: "RTCP 数据包无效"
        case .unsupportedPacket: "RTCP 数据包类型不受支持"
        case .unexpectedSSRC: "RTCP 数据包的 SSRC 与当前会话不符"
        }
    }
}

enum RTCP {
    static let maximumDatagramSize = 1_500

    static func receiverReport(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        fractionLost: UInt8,
        cumulativeLost: Int32,
        extendedHighestSequence: UInt32,
        jitter: UInt32,
        lastSenderReport: UInt32 = 0,
        delaySinceLastSenderReport: UInt32 = 0
    ) -> Data {
        precondition(senderSSRC != 0 && mediaSSRC != 0)
        let clampedLoss = max(-8_388_608, min(8_388_607, cumulativeLost))
        let unsignedLoss = UInt32(bitPattern: clampedLoss) & 0x00ff_ffff

        var packet = Data(capacity: 32)
        packet.append(0x81) // V=2, one report block
        packet.append(201) // Receiver Report
        packet.appendUInt16(7)
        packet.appendUInt32(senderSSRC)
        packet.appendUInt32(mediaSSRC)
        packet.append(fractionLost)
        packet.append(UInt8(truncatingIfNeeded: unsignedLoss >> 16))
        packet.append(UInt8(truncatingIfNeeded: unsignedLoss >> 8))
        packet.append(UInt8(truncatingIfNeeded: unsignedLoss))
        packet.appendUInt32(extendedHighestSequence)
        packet.appendUInt32(jitter)
        packet.appendUInt32(lastSenderReport)
        packet.appendUInt32(delaySinceLastSenderReport)
        return packet
    }

    static func pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32) -> Data {
        precondition(senderSSRC != 0 && mediaSSRC != 0)
        var packet = Data(capacity: 12)
        packet.append(0x81) // V=2, FMT=1 (PLI)
        packet.append(206) // Payload-Specific Feedback
        packet.appendUInt16(2)
        packet.appendUInt32(senderSSRC)
        packet.appendUInt32(mediaSSRC)
        return packet
    }

    static func containsPictureLossIndication(
        _ datagram: Data,
        expectedMediaSSRC: UInt32
    ) throws -> Bool {
        guard (4 ... maximumDatagramSize).contains(datagram.count), datagram.count.isMultiple(of: 4) else {
            throw RTCPError.malformedPacket
        }

        var offset = 0
        var packetCount = 0
        var containsPLI = false
        while offset < datagram.count {
            packetCount += 1
            guard packetCount <= 16, offset + 4 <= datagram.count else {
                throw RTCPError.malformedPacket
            }
            let first = datagram[offset]
            let packetType = datagram[offset + 1]
            let words = Int(datagram[offset + 2]) << 8 | Int(datagram[offset + 3])
            let packetLength = (words + 1) * 4
            guard first >> 6 == 2,
                  first & 0x20 == 0,
                  packetLength >= 4,
                  offset + packetLength <= datagram.count
            else { throw RTCPError.malformedPacket }

            switch packetType {
            case 201:
                let reportCount = Int(first & 0x1f)
                guard packetLength == 8 + reportCount * 24 else {
                    throw RTCPError.malformedPacket
                }
            case 206 where first & 0x1f == 1:
                guard packetLength == 12 else { throw RTCPError.malformedPacket }
                let mediaSSRC = datagram.uint32(at: offset + 8)
                guard mediaSSRC != 0 else { throw RTCPError.malformedPacket }
                guard mediaSSRC == expectedMediaSSRC else { throw RTCPError.unexpectedSSRC }
                containsPLI = true
            default:
                throw RTCPError.unsupportedPacket
            }
            offset += packetLength
        }
        return containsPLI
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

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}
