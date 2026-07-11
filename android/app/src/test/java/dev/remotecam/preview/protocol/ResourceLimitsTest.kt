package dev.remotecam.preview.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertArrayEquals
import org.junit.Test

class ResourceLimitsTest {
    @Test
    fun `parameter sets and IDR form one RTP access unit with one final marker`() {
        val nals = listOf(
            byteArrayOf(0x40, 0x01, 0x0c),
            byteArrayOf(0x42, 0x01, 0x01, 0x02),
            byteArrayOf(0x44, 0x01, 0x03),
            byteArrayOf(0x26, 0x01, 0x55, 0x66),
        )
        val packets = HevcRtpPacketizer(
            payloadType = 98,
            ssrc = 0x10203040,
            initialSequence = 10,
            maxRtpPacketSize = 64,
        ).packetize(nals, timestamp = 90_000)

        assertEquals(1, packets.count { it.marker })
        assertTrue(packets.last().marker)
        val decoded = HevcRtpDepacketizer.depacketize(packets, expectedPayloadType = 98)
        assertEquals(nals.size, decoded.size)
        nals.zip(decoded).forEach { (expected, actual) -> assertArrayEquals(expected, actual) }
    }

    @Test(expected = IllegalArgumentException::class)
    fun `zero SSRC is rejected`() {
        RtpPacket(98, 1, 1, 0, true, byteArrayOf(0x26, 0x01))
    }

    @Test
    fun `sequence gap damages only bounded frame`() {
        val frameBuffer = BoundedRtpFrameBuffer(payloadType = 98, maxFrames = 2)
        frameBuffer.offer(RtpPacket(98, 10, 1, 1, false, byteArrayOf(0x62, 0x01, 0x93.toByte(), 1)))
        frameBuffer.offer(RtpPacket(98, 12, 1, 1, true, byteArrayOf(0x62, 0x01, 0x53, 2)))
        val frame = frameBuffer.drain(1)
        assertTrue(frame!!.damaged)
        assertEquals(0, frame.annexB.size)
    }
}
