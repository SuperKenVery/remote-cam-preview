package dev.remotecam.preview.session

import dev.remotecam.preview.model.CameraStreamCapability
import dev.remotecam.preview.model.DisplayCapability
import dev.remotecam.preview.model.DisplayOrientation
import dev.remotecam.preview.model.PixelSize
import dev.remotecam.preview.model.StreamProfile
import kotlin.math.abs
import kotlin.math.min

/** Selects a native-viewport-oriented stream; there are deliberately no 720p/1080p presets. */
object StreamNegotiator {
    fun negotiate(
        camera: CameraStreamCapability,
        monitor: DisplayCapability,
        preferredFps: Int = 30,
        preferredBitRate: Int = 10_000_000,
    ): StreamProfile {
        require(camera.captureSizes.isNotEmpty()) { "Camera has no usable capture sizes" }
        require(camera.hevcEncoder.supported) { "HEVC encoder unavailable" }
        require(monitor.hevcDecoder.supported) { "HEVC decoder unavailable" }

        val rotate = monitor.orientation == DisplayOrientation.PORTRAIT ||
            monitor.orientation == DisplayOrientation.PORTRAIT_UPSIDE_DOWN
        val encoderMax = requireNotNull(camera.hevcEncoder.maxSize)
        val decoderMax = requireNotNull(monitor.hevcDecoder.maxSize)
        val maxWidth = min(encoderMax.width, decoderMax.width)
        val maxHeight = min(encoderMax.height, decoderMax.height)
        val viewport = monitor.viewport

        // CameraX can only guarantee discrete camera/encoder sizes. Keep the coded size in
        // sensor-buffer orientation and carry display rotation separately in the profile.
        val candidates = camera.captureSizes.distinct().filter { source ->
            source.width <= maxWidth && source.height <= maxHeight
        }

        require(candidates.isNotEmpty()) { "No mutually supported stream size" }
        val viewportRatio = viewport.aspectRatio
        val selected = candidates.maxBy { size ->
            val displayed = if (rotate && size.width > size.height) size.rotated() else size
            val cropPenalty = abs(kotlin.math.ln(displayed.aspectRatio / viewportRatio))
            size.pixels.toDouble() / (1.0 + cropPenalty * 2.0)
        }
        val fps = min(preferredFps, min(camera.hevcEncoder.maxFps, monitor.hevcDecoder.maxFps))
        require(fps > 0) { "No mutually supported frame rate" }
        return StreamProfile(
            size = selected,
            frameRate = fps,
            bitRate = preferredBitRate,
            rotationDegrees = if (rotate) 90 else 0,
        )
    }
}
