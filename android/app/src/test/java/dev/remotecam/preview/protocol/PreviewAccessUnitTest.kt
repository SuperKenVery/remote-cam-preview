package dev.remotecam.preview.protocol

import dev.remotecam.preview.media.CodecParameterSets
import dev.remotecam.preview.media.EncodedAccessUnit
import dev.remotecam.preview.network.rtpNalsForAccessUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewAccessUnitTest {
    @Test
    fun `parameter sets and IDR form one RTP access unit with one marker`() {
        val parameterSets = listOf(
            byteArrayOf(0x40, 0x01, 0x11),
            byteArrayOf(0x42, 0x01, 0x22),
            byteArrayOf(0x44, 0x01, 0x33),
        )
        val idr = byteArrayOf(0x26, 0x01, 0x55, 0x66)
        val accessUnit = EncodedAccessUnit(
            data = AnnexB.join(listOf(idr)),
            presentationTimeUs = 1_000_000,
            keyFrame = true,
            codecConfig = false,
        )
        val nals = rtpNalsForAccessUnit(
            accessUnit,
            CodecParameterSets(listOf(AnnexB.join(parameterSets))),
        )
        val packets = HevcRtpPacketizer(
            payloadType = 98,
            ssrc = 0x1020_3040,
            initialSequence = 100,
            maxRtpPacketSize = 1_200,
        ).packetize(nals, timestamp = 90_000)

        val reconstructed = HevcRtpDepacketizer.depacketize(packets, 98)
        assertTrue((parameterSets + idr).toTypedArray().contentDeepEquals(reconstructed.toTypedArray()))
        assertEquals(1, packets.count { it.marker })
        assertTrue(packets.last().marker)
    }
}
