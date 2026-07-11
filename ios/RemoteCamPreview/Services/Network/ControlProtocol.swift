import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct ControlMessage: Codable, Equatable, Sendable {
    static let protocolVersion = "1.0"
    static let maximumEncodedSize = 64 * 1024

    var type: String
    var requestId: String
    var protocolVersion: String
    var payload: [String: JSONValue]

    init(
        type: String,
        requestId: String = UUID().uuidString,
        protocolVersion: String = Self.protocolVersion,
        payload: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.requestId = requestId
        self.protocolVersion = protocolVersion
        self.payload = payload
    }

    static func heartbeatPing(timestamp: Date = Date()) -> Self {
        Self(
            type: "heartbeat.ping",
            payload: ["sentAtMs": .integer(Int(timestamp.timeIntervalSince1970 * 1_000))]
        )
    }

    static func heartbeatPong(sentAtMs: Int, requestId: String) -> Self {
        Self(type: "heartbeat.pong", requestId: requestId, payload: ["sentAtMs": .integer(sentAtMs)])
    }

    static func photoReceivePreference(enabled: Bool) -> Self {
        Self(type: "photo.receivePreference", payload: ["enabled": .bool(enabled)])
    }

    static func photoAvailable(_ metadata: PhotoMetadata, expiresInSeconds: Int = 300) -> Self {
        Self(
            type: "photo.available",
            payload: [
                "metadata": .object(metadata.controlPayload),
                "expiresInSeconds": .integer(expiresInSeconds),
            ]
        )
    }

    static func keyframeRequest(mediaSsrc: UInt32, reason: String) -> Self {
        Self(
            type: "keyframe.request",
            payload: [
                "mediaSsrc": .integer(Int(mediaSsrc)),
                "reason": .string(reason),
            ]
        )
    }

    static func sessionHello(
        sessionId: String,
        display: MonitorDisplayCapabilities,
        receivePhotos: Bool
    ) -> Self {
        Self(
            type: "session.hello",
            payload: [
                "role": .string("monitor"),
                "sessionId": .string(sessionId),
                "supportedProtocolVersions": .array([.string(Self.protocolVersion)]),
                "display": .object([
                    "nativeWidthPx": .integer(display.nativePixels.width),
                    "nativeHeightPx": .integer(display.nativePixels.height),
                    "viewportWidthPx": .integer(display.viewportPixels.width),
                    "viewportHeightPx": .integer(display.viewportPixels.height),
                    "orientation": .string(display.orientation.rawValue),
                ]),
                "hevc": .object([
                    "profiles": .array(display.hevc.profiles.map(JSONValue.string)),
                    "maxWidthPx": .integer(display.hevc.maximumDimensions.width),
                    "maxHeightPx": .integer(display.hevc.maximumDimensions.height),
                    "maxFps": .integer(display.hevc.maximumFramesPerSecond),
                    "maxLevelIdc": .integer(153),
                ]),
                "photoReceiveEnabled": .bool(receivePhotos),
            ]
        )
    }

    static func sessionAccepted(
        requestId: String,
        sessionId: String,
        accessToken: String,
        configId: String,
        preview: PreviewConfiguration,
        destinationAddress: String,
        rtpPort: UInt16,
        rtcpPort: UInt16,
        payloadType: UInt8,
        rtpSSRC: UInt32,
        maximumPacketSize: Int,
        rtpService: String?,
        rtcpService: String?,
        photoEndpoint: PhotoEndpointAdvertisement
    ) -> Self {
        var payload: [String: JSONValue] = [
            "role": .string("capture"),
            "sessionId": .string(sessionId),
            "accessToken": .string(accessToken),
            "preview": .object([
                "configId": .string(configId),
                "widthPx": .integer(preview.dimensions.width),
                "heightPx": .integer(preview.dimensions.height),
                "fps": .integer(preview.framesPerSecond),
                "bitrateBps": .integer(preview.bitrate),
                "profile": .string(preview.profile),
                "levelIdc": .integer(120),
                "rotationDegrees": .integer(0),
                "clockRate": .integer(90_000),
                "noBFrames": .bool(true),
                "sampleAspectRatio": .object([
                    "width": .integer(1),
                    "height": .integer(1),
                ]),
            ]),
            "rtp": .object([
                "destinationAddress": .string(destinationAddress),
                "rtpPort": .integer(Int(rtpPort)),
                "rtcpPort": .integer(Int(rtcpPort)),
                "payloadType": .integer(Int(payloadType)),
                "ssrc": .integer(Int(rtpSSRC)),
                "maxRtpPacketSize": .integer(maximumPacketSize),
            ]),
        ]
        if case .object(var rtp)? = payload["rtp"] {
            if let rtpService { rtp["rtpService"] = .string(rtpService) }
            if let rtcpService { rtp["rtcpService"] = .string(rtcpService) }
            payload["rtp"] = .object(rtp)
        }
        if let port = photoEndpoint.port {
            payload["photoEndpoint"] = .object(["port": .integer(Int(port))])
        } else if let service = photoEndpoint.service {
            payload["photoEndpoint"] = .object(["serviceName": .string(service)])
        }
        return Self(type: "session.accepted", requestId: requestId, payload: payload)
    }

    static func previewStart(configId: String) -> Self {
        Self(type: "preview.start", payload: ["configId": .string(configId)])
    }

    static func photoTransferResult(
        photoId: String,
        status: String,
        errorCode: String? = nil
    ) -> Self {
        var payload: [String: JSONValue] = [
            "photoId": .string(photoId),
            "status": .string(status),
        ]
        if let errorCode { payload["errorCode"] = .string(errorCode) }
        return Self(type: "photo.transferResult", payload: payload)
    }
}

enum ControlProtocolError: LocalizedError, Equatable {
    case messageTooLarge(Int)
    case unsupportedMajorVersion(String)
    case malformedMessage
    case noConnection

    var errorDescription: String? {
        switch self {
        case .messageTooLarge(let bytes): "控制消息过大（\(bytes) 字节）"
        case .unsupportedMajorVersion(let version): "不支持协议主版本 \(version)"
        case .malformedMessage: "控制消息格式无效"
        case .noConnection: "控制通道尚未连接"
        }
    }
}

enum ControlMessageCodec {
    private static let knownTypes: Set<String> = [
        "session.hello", "session.accepted", "preview.start", "preview.stop",
        "preview.reconfigure", "preview.tierRequest", "photo.receivePreference",
        "photo.captured", "photo.available", "photo.transferResult", "heartbeat.ping",
        "heartbeat.pong", "keyframe.request", "error", "session.end",
    ]

    static func encode(_ message: ControlMessage) throws -> Data {
        try validate(message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(message)
        guard data.count <= ControlMessage.maximumEncodedSize else {
            throw ControlProtocolError.messageTooLarge(data.count)
        }
        return data
    }

    static func decode(_ data: Data) throws -> ControlMessage {
        guard data.count <= ControlMessage.maximumEncodedSize else {
            throw ControlProtocolError.messageTooLarge(data.count)
        }
        try JSONLexicalValidator.validate(data)
        guard let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else {
            throw ControlProtocolError.malformedMessage
        }
        try validate(message)
        return message
    }

    private static func validate(_ message: ControlMessage) throws {
        guard message.protocolVersion.range(
            of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$",
            options: .regularExpression
        ) != nil else { throw ControlProtocolError.malformedMessage }
        guard message.protocolVersion.split(separator: ".").first == "1" else {
            throw ControlProtocolError.unsupportedMajorVersion(message.protocolVersion)
        }
        guard knownTypes.contains(message.type),
              message.requestId.range(
                of: "^[A-Za-z0-9._~-]{1,64}$",
                options: .regularExpression
              ) != nil
        else { throw ControlProtocolError.malformedMessage }

        try validateJSONTree(.object(message.payload))

        switch message.type {
        case "session.hello":
            try validateSessionHello(message.payload)
        case "session.accepted":
            try validateSessionAccepted(message.payload)
        case "preview.start":
            guard case .string(let configId)? = message.payload["configId"], isConfigId(configId) else {
                throw ControlProtocolError.malformedMessage
            }
        case "photo.receivePreference":
            guard case .bool? = message.payload["enabled"] else {
                throw ControlProtocolError.malformedMessage
            }
        case "heartbeat.ping", "heartbeat.pong":
            guard case .integer(let value)? = message.payload["sentAtMs"], value >= 0 else {
                throw ControlProtocolError.malformedMessage
            }
        case "keyframe.request":
            guard case .integer(let ssrc)? = message.payload["mediaSsrc"],
                  (1 ... Int(UInt32.max)).contains(ssrc),
                  case .string(let reason)? = message.payload["reason"],
                  ["startup", "loss", "decoderReset", "reconfigure"].contains(reason)
            else { throw ControlProtocolError.malformedMessage }
        case "photo.available":
            guard case .object(let metadata)? = message.payload["metadata"],
                  case .integer(let expires)? = message.payload["expiresInSeconds"],
                  (1 ... 3_600).contains(expires),
                  (try? PhotoMetadata(controlPayload: metadata)) != nil
            else { throw ControlProtocolError.malformedMessage }
        case "photo.transferResult":
            try validatePhotoTransferResult(message.payload)
        default:
            break
        }
    }

    private static func validateSessionHello(_ payload: [String: JSONValue]) throws {
        guard case .string("monitor")? = payload["role"],
              case .string(let sessionId)? = payload["sessionId"], isToken(sessionId),
              case .array(let versions)? = payload["supportedProtocolVersions"],
              (1 ... 8).contains(versions.count),
              case .object(let display)? = payload["display"],
              case .object(let hevc)? = payload["hevc"],
              case .bool? = payload["photoReceiveEnabled"]
        else { throw ControlProtocolError.malformedMessage }

        var seenVersions = Set<String>()
        for version in versions {
            guard case .string(let value) = version,
                  value.utf8.count <= 16,
                  value.range(
                      of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$",
                      options: .regularExpression
                  ) != nil,
                  seenVersions.insert(value).inserted
            else { throw ControlProtocolError.malformedMessage }
        }

        guard integer(display["nativeWidthPx"], in: 1 ... 16_384) != nil,
              integer(display["nativeHeightPx"], in: 1 ... 16_384) != nil,
              integer(display["viewportWidthPx"], in: 1 ... 16_384) != nil,
              integer(display["viewportHeightPx"], in: 1 ... 16_384) != nil,
              case .string(let orientation)? = display["orientation"],
              ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"].contains(orientation),
              case .array(let profiles)? = hevc["profiles"],
              (1 ... 2).contains(profiles.count),
              integer(hevc["maxWidthPx"], in: 16 ... 16_384) != nil,
              integer(hevc["maxHeightPx"], in: 16 ... 16_384) != nil,
              integer(hevc["maxFps"], in: 1 ... 240) != nil,
              integer(hevc["maxLevelIdc"], in: 30 ... 186) != nil
        else { throw ControlProtocolError.malformedMessage }

        var seenProfiles = Set<String>()
        for profile in profiles {
            guard case .string(let value) = profile,
                  ["main", "main10"].contains(value),
                  seenProfiles.insert(value).inserted
            else { throw ControlProtocolError.malformedMessage }
        }
    }

    private static func validateSessionAccepted(_ payload: [String: JSONValue]) throws {
        guard case .string("capture")? = payload["role"],
              case .string(let sessionId)? = payload["sessionId"], isToken(sessionId),
              case .string(let accessToken)? = payload["accessToken"], isToken(accessToken),
              case .object(let preview)? = payload["preview"],
              case .object(let rtp)? = payload["rtp"],
              case .object(let photoEndpoint)? = payload["photoEndpoint"]
        else { throw ControlProtocolError.malformedMessage }

        guard case .string(let configId)? = preview["configId"], isConfigId(configId),
              integer(preview["widthPx"], in: 16 ... 16_384) != nil,
              integer(preview["heightPx"], in: 16 ... 16_384) != nil,
              case .object(let aspect)? = preview["sampleAspectRatio"],
              integer(aspect["width"], in: 1 ... 65_535) != nil,
              integer(aspect["height"], in: 1 ... 65_535) != nil,
              integer(preview["fps"], in: 1 ... 240) != nil,
              integer(preview["bitrateBps"], in: 100_000 ... 200_000_000) != nil,
              case .string(let profile)? = preview["profile"], ["main", "main10"].contains(profile),
              integer(preview["levelIdc"], in: 30 ... 186) != nil,
              let rotation = integer(preview["rotationDegrees"], in: 0 ... 270),
              [0, 90, 180, 270].contains(rotation),
              integer(preview["clockRate"], in: 90_000 ... 90_000) != nil,
              case .bool(true)? = preview["noBFrames"]
        else { throw ControlProtocolError.malformedMessage }

        guard case .string(let destination)? = rtp["destinationAddress"],
              (1 ... 255).contains(destination.utf8.count),
              integer(rtp["rtpPort"], in: 1 ... 65_535) != nil,
              integer(rtp["rtcpPort"], in: 1 ... 65_535) != nil,
              integer(rtp["payloadType"], in: 96 ... 127) != nil,
              integer(rtp["ssrc"], in: 1 ... Int(UInt32.max)) != nil,
              integer(rtp["maxRtpPacketSize"], in: 256 ... 65_507) != nil
        else { throw ControlProtocolError.malformedMessage }

        let port = integer(photoEndpoint["port"], in: 1 ... 65_535)
        let service: String?
        if case .string(let value)? = photoEndpoint["serviceName"] { service = value }
        else { service = nil }
        guard (port != nil) != (service != nil) else { throw ControlProtocolError.malformedMessage }
        if let service {
            guard service.utf8.count <= 22,
                  service.range(
                      of: "^_[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?\\._tcp$",
                      options: .regularExpression
                  ) != nil
            else { throw ControlProtocolError.malformedMessage }
        }
    }

    private static func validatePhotoTransferResult(_ payload: [String: JSONValue]) throws {
        guard case .string(let photoId)? = payload["photoId"], isToken(photoId),
              case .string(let status)? = payload["status"],
              ["saved", "failed", "cancelled"].contains(status)
        else { throw ControlProtocolError.malformedMessage }
        if status != "saved" {
            guard case .string(let code)? = payload["errorCode"],
                  code.range(of: "^[A-Z][A-Z0-9_]{1,63}$", options: .regularExpression) != nil
            else { throw ControlProtocolError.malformedMessage }
        }
    }

    private static func integer(_ value: JSONValue?, in range: ClosedRange<Int>) -> Int? {
        guard case .integer(let result)? = value, range.contains(result) else { return nil }
        return result
    }

    private static func isToken(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
    }

    private static func isConfigId(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._~-]{1,64}$", options: .regularExpression) != nil
    }

    private static func validateJSONTree(_ root: JSONValue) throws {
        var nodes = 0
        func walk(_ value: JSONValue, depth: Int) throws {
            nodes += 1
            guard nodes <= 4_096, depth <= 16 else { throw ControlProtocolError.malformedMessage }
            switch value {
            case .string(let string):
                guard string.utf8.count <= 4_096 else { throw ControlProtocolError.malformedMessage }
            case .integer(let integer):
                guard String(integer).count <= 65 else { throw ControlProtocolError.malformedMessage }
            case .double(let number):
                guard number.isFinite else { throw ControlProtocolError.malformedMessage }
            case .object(let object):
                guard object.count <= 128,
                      object.keys.allSatisfy({ $0.utf8.count <= 128 })
                else { throw ControlProtocolError.malformedMessage }
                for child in object.values { try walk(child, depth: depth + 1) }
            case .array(let array):
                guard array.count <= 256 else { throw ControlProtocolError.malformedMessage }
                for child in array { try walk(child, depth: depth + 1) }
            case .bool, .null:
                break
            }
        }
        try walk(root, depth: 0)
    }
}

private enum JSONLexicalValidator {
    static func validate(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ControlProtocolError.malformedMessage
        }
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw ControlProtocolError.malformedMessage }
        }

        private mutating func parseValue(depth: Int) throws {
            guard depth <= 16, index < bytes.count else {
                throw ControlProtocolError.malformedMessage
            }
            nodes += 1
            guard nodes <= 4_096 else { throw ControlProtocolError.malformedMessage }

            switch bytes[index] {
            case 0x7b: try parseObject(depth: depth) // {
            case 0x5b: try parseArray(depth: depth) // [
            case 0x22: _ = try parseString()
            case 0x74: try consume([0x74, 0x72, 0x75, 0x65]) // true
            case 0x66: try consume([0x66, 0x61, 0x6c, 0x73, 0x65]) // false
            case 0x6e: try consume([0x6e, 0x75, 0x6c, 0x6c]) // null
            case 0x2d, 0x30 ... 0x39: try parseNumber()
            default: throw ControlProtocolError.malformedMessage
            }
        }

        private mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x7d) { return }

            var keys = Set<String>()
            var members = 0
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw ControlProtocolError.malformedMessage
                }
                let key = try parseString()
                guard key.utf8.count <= 128, keys.insert(key).inserted else {
                    throw ControlProtocolError.malformedMessage
                }
                members += 1
                guard members <= 128 else { throw ControlProtocolError.malformedMessage }
                skipWhitespace()
                guard consumeIf(0x3a) else { throw ControlProtocolError.malformedMessage }
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x7d) { return }
                guard consumeIf(0x2c) else { throw ControlProtocolError.malformedMessage }
                skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x5d) { return }

            var count = 0
            while true {
                count += 1
                guard count <= 256 else { throw ControlProtocolError.malformedMessage }
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x5d) { return }
                guard consumeIf(0x2c) else { throw ControlProtocolError.malformedMessage }
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            guard consumeIf(0x22) else { throw ControlProtocolError.malformedMessage }

            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let encoded = Data(bytes[start ..< index])
                    guard let value = try? JSONDecoder().decode(String.self, from: encoded),
                          value.utf8.count <= 4_096
                    else { throw ControlProtocolError.malformedMessage }
                    return value
                }
                if byte < 0x20 { throw ControlProtocolError.malformedMessage }
                if byte == 0x5c {
                    index += 1
                    guard index < bytes.count else { throw ControlProtocolError.malformedMessage }
                    switch bytes[index] {
                    case 0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74:
                        index += 1
                    case 0x75:
                        index += 1
                        guard index + 4 <= bytes.count,
                              bytes[index ..< index + 4].allSatisfy(Self.isHexDigit)
                        else { throw ControlProtocolError.malformedMessage }
                        index += 4
                    default:
                        throw ControlProtocolError.malformedMessage
                    }
                } else {
                    index += 1
                }
            }
            throw ControlProtocolError.malformedMessage
        }

        private mutating func parseNumber() throws {
            let start = index
            _ = consumeIf(0x2d)
            guard index < bytes.count else { throw ControlProtocolError.malformedMessage }

            if consumeIf(0x30) {
                guard index == bytes.count || !Self.isDigit(bytes[index]) else {
                    throw ControlProtocolError.malformedMessage
                }
            } else {
                guard index < bytes.count, (0x31 ... 0x39).contains(bytes[index]) else {
                    throw ControlProtocolError.malformedMessage
                }
                index += 1
                while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            }

            if consumeIf(0x2e) {
                guard index < bytes.count, Self.isDigit(bytes[index]) else {
                    throw ControlProtocolError.malformedMessage
                }
                while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, (bytes[index] == 0x65 || bytes[index] == 0x45) {
                index += 1
                if index < bytes.count, (bytes[index] == 0x2b || bytes[index] == 0x2d) { index += 1 }
                guard index < bytes.count, Self.isDigit(bytes[index]) else {
                    throw ControlProtocolError.malformedMessage
                }
                while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            }
            guard index - start <= 64 else { throw ControlProtocolError.malformedMessage }
        }

        private mutating func consume(_ literal: [UInt8]) throws {
            guard index + literal.count <= bytes.count,
                  bytes[index ..< index + literal.count].elementsEqual(literal)
            else { throw ControlProtocolError.malformedMessage }
            index += literal.count
        }

        private mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }

        private static func isDigit(_ byte: UInt8) -> Bool { (0x30 ... 0x39).contains(byte) }
        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}
