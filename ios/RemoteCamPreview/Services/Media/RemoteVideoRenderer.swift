import AVFoundation
import CoreMedia
import CoreVideo
import Observation
import SwiftUI

@MainActor
@Observable
final class RemoteVideoRenderer {
    private weak var view: RemoteVideoUIView?
    private(set) var hasFrame = false

    func attach(_ view: RemoteVideoUIView) {
        self.view = view
    }

    func display(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let view else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if view.displayLayer.status == .failed { view.displayLayer.flush() }
        view.displayLayer.enqueue(sample)
        hasFrame = true
    }

    func reset() {
        view?.displayLayer.flushAndRemoveImage()
        hasFrame = false
    }
}

struct RemoteVideoView: UIViewRepresentable {
    let renderer: RemoteVideoRenderer

    func makeUIView(context: Context) -> RemoteVideoUIView {
        let view = RemoteVideoUIView()
        renderer.attach(view)
        return view
    }

    func updateUIView(_ view: RemoteVideoUIView, context: Context) {
        renderer.attach(view)
    }
}

final class RemoteVideoUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        let layer = layer as! AVSampleBufferDisplayLayer
        layer.videoGravity = .resizeAspect
        return layer
    }
}
