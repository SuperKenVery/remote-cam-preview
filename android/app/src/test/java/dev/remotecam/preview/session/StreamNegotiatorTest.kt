package dev.remotecam.preview.session

import dev.remotecam.preview.model.CameraStreamCapability
import dev.remotecam.preview.model.DisplayCapability
import dev.remotecam.preview.model.DisplayOrientation
import dev.remotecam.preview.model.HevcCapability
import dev.remotecam.preview.model.PixelSize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamNegotiatorTest {
    @Test
    fun `resolution follows native viewport instead of fixed preset`() {
        val monitor = DisplayCapability(
            nativePixels = PixelSize(1179, 2556),
            viewport = PixelSize(1179, 2360),
            orientation = DisplayOrientation.PORTRAIT,
            hevcDecoder = HevcCapability(true, PixelSize(3840, 2160), 60, setOf("Main")),
        )
        val camera = CameraStreamCapability(
            captureSizes = listOf(PixelSize(4032, 3024), PixelSize(3840, 2160), PixelSize(1920, 1080)),
            hevcEncoder = HevcCapability(true, PixelSize(3840, 2160), 60, setOf("Main")),
        )
        val profile = StreamNegotiator.negotiate(camera, monitor)

        assertTrue(profile.size in camera.captureSizes)
        assertNotEquals(PixelSize(1280, 720), profile.size)
        assertNotEquals(PixelSize(1920, 1080), profile.size)
        assertTrue(profile.size.width <= 3840 && profile.size.height <= 2160)
        assertEquals(90, profile.rotationDegrees)
        assertEquals(30, profile.frameRate)
        assertEquals(10_000_000, profile.bitRate)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `HEVC is mandatory`() {
        StreamNegotiator.negotiate(
            CameraStreamCapability(
                listOf(PixelSize(1920, 1080)),
                HevcCapability(false, null, 0),
            ),
            DisplayCapability(
                PixelSize(1000, 2000),
                PixelSize(1000, 1800),
                DisplayOrientation.PORTRAIT,
                HevcCapability(true, PixelSize(1920, 1080), 30),
            ),
        )
    }
}
