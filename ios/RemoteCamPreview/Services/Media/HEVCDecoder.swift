import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum HEVCDecoderError: LocalizedError {
    case invalidParameterSets
    case cannotCreateFormat(OSStatus)
    case cannotCreateSession(OSStatus)
    case cannotCreateSample(OSStatus)
    case decodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidParameterSets: "缺少 HEVC VPS/SPS/PPS"
        case .cannotCreateFormat(let status): "无法创建 HEVC 格式描述（\(status)）"
        case .cannotCreateSession(let status): "无法创建 HEVC 解码器（\(status)）"
        case .cannotCreateSample(let status): "无法创建 HEVC 样本（\(status)）"
        case .decodeFailed(let status): "HEVC 解码失败（\(status)）"
        }
    }
}

final class HEVCDecoder: @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    func configure(parameterSets: [Data]) throws {
        guard parameterSets.count >= 3 else { throw HEVCDecoderError.invalidParameterSets }
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()

        let retained = parameterSets.map { $0 as NSData }
        let pointers = retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = retained.map(\.length)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw HEVCDecoderError.cannotCreateFormat(status)
        }

        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else {
            throw HEVCDecoderError.cannotCreateSession(createStatus)
        }
        formatDescription = description
        session = newSession
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    func decode(nalUnits: [Data], presentationTime: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let session, let formatDescription else {
            throw HEVCDecoderError.invalidParameterSets
        }

        var avcc = Data()
        for nal in nalUnits {
            guard nal.count >= 2, nal.count <= Int(UInt32.max) else {
                throw HEVCDecoderError.cannotCreateSample(-1)
            }
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw HEVCDecoderError.cannotCreateSample(status)
        }
        status = avcc.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(
                with: buffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard status == noErr else { throw HEVCDecoderError.cannotCreateSample(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw HEVCDecoderError.cannotCreateSample(status)
        }

        var flags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard decodeStatus == noErr else { throw HEVCDecoderError.decodeFailed(decodeStatus) }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()
    }

    deinit { invalidate() }

    private func invalidateLocked() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        refcon, _, status, _, imageBuffer, presentationTime, _ in
        guard let refcon else { return }
        let decoder = Unmanaged<HEVCDecoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let imageBuffer else {
            decoder.onError?(HEVCDecoderError.decodeFailed(status))
            return
        }
        decoder.onFrame?(imageBuffer, presentationTime)
    }
}
