import CoreMedia
import Foundation
import Observation

@MainActor
@Observable
final class MediaPipeline {
    let renderer = RemoteVideoRenderer()

    private let encoder = HEVCEncoder()
    private let decoder = HEVCDecoder()
    private var packetizer = HEVCRTPPacketizer(ssrc: UInt32.random(in: .min ... .max))
    private var depacketizer = HEVCRTPDepacketizer()
    private var currentAccessUnit: [Data] = []
    private var currentTimestamp: UInt32?
    private var parameterSets: [Data] = []
    private var forceNextKeyFrame = false

    var onRTPPacket: (@Sendable (RTPPacket) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    init() {
        encoder.onAccessUnit = { [weak self] accessUnit in
            Task { @MainActor in self?.handle(accessUnit) }
        }
        encoder.onError = { [weak self] error in
            Task { @MainActor in self?.onError?(error) }
        }
        decoder.onFrame = { [weak self] pixelBuffer, presentationTime in
            Task { @MainActor in self?.renderer.display(pixelBuffer, presentationTime: presentationTime) }
        }
        decoder.onError = { [weak self] error in
            Task { @MainActor in self?.onError?(error) }
        }
    }

    func configureEncoder(
        _ configuration: PreviewConfiguration,
        mediaSSRC: UInt32,
        payloadType: UInt8,
        maximumPacketSize: Int
    ) throws {
        packetizer = HEVCRTPPacketizer(
            payloadType: payloadType,
            ssrc: mediaSSRC,
            maximumPacketSize: maximumPacketSize
        )
        try encoder.configure(
            width: Int32(configuration.dimensions.width),
            height: Int32(configuration.dimensions.height),
            bitrate: configuration.bitrate,
            framesPerSecond: configuration.framesPerSecond
        )
    }

    func encode(_ sampleBuffer: CMSampleBuffer, forceKeyFrame: Bool = false) {
        let shouldForce = forceKeyFrame || forceNextKeyFrame
        forceNextKeyFrame = false
        do { try encoder.encode(sampleBuffer, forceKeyFrame: shouldForce) }
        catch { onError?(error) }
    }

    func requestKeyFrame() {
        forceNextKeyFrame = true
    }

    func ingest(_ packet: RTPPacket) {
        do {
            for nal in try depacketizer.ingest(packet) {
                let type = (nal.data.first! >> 1) & 0x3f
                if (32 ... 34).contains(type) {
                    parameterSets.removeAll { (($0.first! >> 1) & 0x3f) == type }
                    parameterSets.append(nal.data)
                    if parameterSets.count >= 3 { try decoder.configure(parameterSets: parameterSets) }
                    continue
                }

                if currentTimestamp != nal.timestamp {
                    currentAccessUnit.removeAll(keepingCapacity: true)
                    currentTimestamp = nal.timestamp
                }
                currentAccessUnit.append(nal.data)
                if nal.endsAccessUnit {
                    try decoder.decode(
                        nalUnits: currentAccessUnit,
                        presentationTime: CMTime(value: Int64(nal.timestamp), timescale: 90_000)
                    )
                    currentAccessUnit.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            currentAccessUnit.removeAll(keepingCapacity: true)
            onError?(error)
        }
    }

    func stop() {
        encoder.invalidate()
        decoder.invalidate()
        currentAccessUnit.removeAll()
        currentTimestamp = nil
        parameterSets.removeAll()
        forceNextKeyFrame = false
        renderer.reset()
    }

    private func handle(_ accessUnit: EncodedHEVCAccessUnit) {
        do {
            let timestamp = UInt32(
                max(0, CMTimeConvertScale(accessUnit.presentationTime, timescale: 90_000, method: .roundTowardZero).value)
            )
            let units = accessUnit.parameterSets + accessUnit.nalUnits
            for packet in try packetizer.packetize(accessUnit: units, timestamp: timestamp) {
                onRTPPacket?(packet)
            }
        } catch {
            onError?(error)
        }
    }
}
