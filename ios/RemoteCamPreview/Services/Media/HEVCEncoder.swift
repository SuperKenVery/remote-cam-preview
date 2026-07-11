import CoreMedia
import Foundation
import VideoToolbox

struct EncodedHEVCAccessUnit: Sendable {
    var nalUnits: [Data]
    var parameterSets: [Data]
    var presentationTime: CMTime
    var isKeyFrame: Bool
}

enum HEVCEncoderError: LocalizedError {
    case cannotCreate(OSStatus)
    case propertyFailed(CFString, OSStatus)
    case encodeFailed(OSStatus)
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let status): "无法创建 HEVC 编码器（\(status)）"
        case .propertyFailed(let key, let status): "HEVC 编码参数 \(key) 设置失败（\(status)）"
        case .encodeFailed(let status): "HEVC 编码失败（\(status)）"
        case .malformedOutput: "HEVC 编码输出无效"
        }
    }
}

final class HEVCEncoder: @unchecked Sendable {
    var onAccessUnit: (@Sendable (EncodedHEVCAccessUnit) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?

    func configure(width: Int32, height: Int32, bitrate: Int, framesPerSecond: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()

        let specification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any,
        ] as CFDictionary
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { throw HEVCEncoderError.cannotCreate(status) }
        session = newSession

        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber)
        try set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        try set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 2] as CFArray)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (framesPerSecond * 2) as CFNumber)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
        guard prepareStatus == noErr else { throw HEVCEncoderError.encodeFailed(prepareStatus) }
    }

    func encode(_ sampleBuffer: CMSampleBuffer, forceKeyFrame: Bool = false) throws {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw HEVCEncoderError.malformedOutput
        }
        lock.lock()
        defer { lock.unlock() }
        guard let session else { throw HEVCEncoderError.cannotCreate(-1) }

        var flags: VTEncodeInfoFlags = []
        let properties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard status == noErr else { throw HEVCEncoderError.encodeFailed(status) }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()
    }

    deinit { invalidate() }

    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { throw HEVCEncoderError.cannotCreate(-1) }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw HEVCEncoderError.propertyFailed(key, status) }
    }

    private func invalidateLocked() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func handle(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            onError?(HEVCEncoderError.encodeFailed(status))
            return
        }
        do {
            let isKeyFrame = Self.isKeyFrame(sampleBuffer)
            let nalUnits = try Self.nalUnits(from: sampleBuffer)
            let parameterSets = isKeyFrame ? try Self.parameterSets(from: sampleBuffer) : []
            onAccessUnit?(EncodedHEVCAccessUnit(
                nalUnits: nalUnits,
                parameterSets: parameterSets,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                isKeyFrame: isKeyFrame
            ))
        } catch {
            onError?(error)
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        Unmanaged<HEVCEncoder>.fromOpaque(refcon).takeUnretainedValue()
            .handle(status: status, sampleBuffer: sampleBuffer)
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]], let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func parameterSets(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw HEVCEncoderError.malformedOutput
        }
        var count = 0
        var headerLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard countStatus == noErr else { throw HEVCEncoderError.malformedOutput }

        return try (0 ..< count).map { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { throw HEVCEncoderError.malformedOutput }
            return Data(bytes: pointer, count: size)
        }
    }

    private static func nalUnits(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw HEVCEncoderError.malformedOutput
        }
        let totalLength = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: totalLength)
        let status = bytes.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: buffer.baseAddress!)
        }
        guard status == noErr else { throw HEVCEncoderError.malformedOutput }

        var result: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 |
                Int(bytes[offset + 1]) << 16 |
                Int(bytes[offset + 2]) << 8 |
                Int(bytes[offset + 3])
            offset += 4
            guard length >= 2, offset + length <= bytes.count else {
                throw HEVCEncoderError.malformedOutput
            }
            result.append(Data(bytes[offset ..< offset + length]))
            offset += length
        }
        guard offset == bytes.count else { throw HEVCEncoderError.malformedOutput }
        return result
    }
}

