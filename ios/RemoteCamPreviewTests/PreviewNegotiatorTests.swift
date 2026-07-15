import XCTest
@testable import RemoteCamPreview

final class PreviewNegotiatorTests: XCTestCase {
    func testDimensionLimitPreservesPortraitAspectRatio() {
        let result = PreviewNegotiator.aspectPreservingDimensions(
            requested: PixelDimensions(width: 1_170, height: 2_532),
            maximum: PixelDimensions(width: 3_840, height: 2_160)
        )

        XCTAssertEqual(result, PixelDimensions(width: 998, height: 2_160))
        XCTAssertEqual(
            result.aspectRatio,
            PixelDimensions(width: 1_170, height: 2_532).aspectRatio,
            accuracy: 0.001
        )
    }

    func testPortraitDecoderLimitKeepsNativeViewportDimensions() {
        let result = PreviewNegotiator.aspectPreservingDimensions(
            requested: PixelDimensions(width: 1_170, height: 2_532),
            maximum: PixelDimensions(width: 2_160, height: 3_840)
        )

        XCTAssertEqual(result, PixelDimensions(width: 1_170, height: 2_532))
    }

    func testUsesMonitorViewportInsteadOfFixedPreset() throws {
        let monitor = MonitorDisplayCapabilities(
            nativePixels: PixelDimensions(width: 1_179, height: 2_556),
            viewportPixels: PixelDimensions(width: 1_179, height: 2_360),
            orientation: .portrait,
            hevc: HEVCDecodeCapabilities(
                supported: true,
                maximumDimensions: PixelDimensions(width: 3_840, height: 2_160),
                maximumFramesPerSecond: 60,
                profiles: ["main"]
            )
        )
        let result = try PreviewNegotiator.negotiate(
            monitor: monitor,
            captureFormats: [
                CaptureFormatCandidate(dimensions: PixelDimensions(width: 720, height: 1_280), maximumFramesPerSecond: 30),
                CaptureFormatCandidate(dimensions: PixelDimensions(width: 1_180, height: 2_096), maximumFramesPerSecond: 30),
            ]
        )
        XCTAssertEqual(result.dimensions, PixelDimensions(width: 1_180, height: 2_096))
        XCTAssertEqual(result.framesPerSecond, 30)
        XCTAssertEqual(result.bitrate, 10_000_000)
    }
}
