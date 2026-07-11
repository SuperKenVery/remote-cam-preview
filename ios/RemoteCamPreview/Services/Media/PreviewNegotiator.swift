import Foundation

enum PreviewNegotiationError: LocalizedError, Equatable {
    case hevcUnsupported
    case noCompatibleFormat

    var errorDescription: String? {
        switch self {
        case .hevcUnsupported: "监看端不支持 HEVC 解码"
        case .noCompatibleFormat: "没有符合双方能力的相机预览格式"
        }
    }
}

enum PreviewNegotiator {
    static let targetFramesPerSecond = 30
    static let targetBitrate = 10_000_000

    static func negotiate(
        monitor: MonitorDisplayCapabilities,
        captureFormats: [CaptureFormatCandidate]
    ) throws -> PreviewConfiguration {
        guard monitor.hevc.supported else { throw PreviewNegotiationError.hevcUnsupported }

        let maximum = monitor.hevc.maximumDimensions
        let candidates = captureFormats.filter {
            $0.dimensions.width <= maximum.width &&
            $0.dimensions.height <= maximum.height &&
            $0.maximumFramesPerSecond >= min(targetFramesPerSecond, monitor.hevc.maximumFramesPerSecond)
        }
        guard !candidates.isEmpty else { throw PreviewNegotiationError.noCompatibleFormat }

        let viewport = monitor.viewportPixels
        let selected = candidates.max { lhs, rhs in
            score(lhs, viewport: viewport) < score(rhs, viewport: viewport)
        }!
        let fps = min(
            targetFramesPerSecond,
            monitor.hevc.maximumFramesPerSecond,
            selected.maximumFramesPerSecond
        )
        return PreviewConfiguration(
            dimensions: selected.dimensions,
            framesPerSecond: fps,
            bitrate: targetBitrate,
            profile: monitor.hevc.profiles.contains("main10") ? "main10" : "main",
            level: "auto"
        )
    }

    private static func score(
        _ candidate: CaptureFormatCandidate,
        viewport: PixelDimensions
    ) -> (Int, Double, Int) {
        let candidateRatio = candidate.dimensions.aspectRatio
        let viewportRatio = viewport.aspectRatio
        let retainedFraction = min(candidateRatio / viewportRatio, viewportRatio / candidateRatio)
        let usefulPixels = min(
            Double(viewport.area),
            Double(candidate.dimensions.area) * retainedFraction
        )
        let excessPixels = max(0, candidate.dimensions.area - viewport.area)
        return (Int(usefulPixels), retainedFraction, -excessPixels)
    }
}

