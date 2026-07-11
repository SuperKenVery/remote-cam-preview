package dev.remotecam.preview.protocol

import java.nio.ByteBuffer
import kotlin.math.min

const val RTP_CLOCK_RATE = 90_000
const val MAX_HEVC_NAL_BYTES = 16 * 1024 * 1024
const val MAX_HEVC_ACCESS_UNIT_BYTES = 64 * 1024 * 1024
const val MAX_NALS_PER_ACCESS_UNIT = 1_024
const val MAX_RTP_PACKETS_PER_ACCESS_UNIT = 4_096
private const val MAX_AGGREGATED_NALS = 64

class HevcRtpException(val code: String, message: String) : IllegalArgumentException("$code: $message")

data class RtpPacket(
    val payloadType: Int,
    val sequenceNumber: Int,
    val timestamp: Long,
    val ssrc: Long,
    val marker: Boolean,
    val payload: ByteArray,
) {
    init {
        require(payloadType in 0..127)
        require(sequenceNumber in 0..0xffff)
        require(timestamp in 0..0xffff_ffffL)
        require(ssrc in 1..0xffff_ffffL) { "RTP SSRC must be non-zero" }
        require(payload.isNotEmpty())
    }

    fun encode(): ByteArray = ByteBuffer.allocate(12 + payload.size).apply {
        put(0x80.toByte())
        put((payloadType or if (marker) 0x80 else 0).toByte())
        putShort(sequenceNumber.toShort())
        putInt(timestamp.toInt())
        putInt(ssrc.toInt())
        put(payload)
    }.array()

    companion object {
        fun decode(bytes: ByteArray, maxPacketSize: Int = 65_535): RtpPacket {
            if (bytes.size !in 13..maxPacketSize) fail("MALFORMED_RTP", "packet length out of range")
            val first = bytes[0].toInt() and 0xff
            if (first ushr 6 != 2) fail("MALFORMED_RTP", "RTP version must be two")
            if ((first and 0x3f) != 0) {
                fail("UNSUPPORTED_RTP_HEADER", "padding, extension, and CSRC are not negotiated")
            }
            val ssrc = u32(bytes, 8)
            if (ssrc == 0L) fail("MALFORMED_RTP", "SSRC must be non-zero")
            return RtpPacket(
                payloadType = bytes[1].toInt() and 0x7f,
                marker = (bytes[1].toInt() and 0x80) != 0,
                sequenceNumber = u16(bytes, 2),
                timestamp = u32(bytes, 4),
                ssrc = ssrc,
                payload = bytes.copyOfRange(12, bytes.size),
            )
        }

        private fun u16(bytes: ByteArray, offset: Int): Int =
            ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

        private fun u32(bytes: ByteArray, offset: Int): Long =
            ((bytes[offset].toLong() and 0xff) shl 24) or
                ((bytes[offset + 1].toLong() and 0xff) shl 16) or
                ((bytes[offset + 2].toLong() and 0xff) shl 8) or
                (bytes[offset + 3].toLong() and 0xff)

        private fun fail(code: String, message: String): Nothing = throw HevcRtpException(code, message)
    }
}

private data class NalHeader(val type: Int, val layerId: Int, val temporalIdPlusOne: Int)

private fun parseNalHeader(nal: ByteArray, allowPacketizationTypes: Boolean = false): NalHeader {
    if (nal.size < 2) fail("MALFORMED_HEVC_NAL", "NAL unit lacks its two-byte header")
    if ((nal[0].toInt() and 0x80) != 0) fail("MALFORMED_HEVC_NAL", "forbidden_zero_bit is set")
    val type = (nal[0].toInt() ushr 1) and 0x3f
    val layer = ((nal[0].toInt() and 1) shl 5) or ((nal[1].toInt() ushr 3) and 0x1f)
    val tid = nal[1].toInt() and 7
    if (tid == 0) fail("MALFORMED_HEVC_NAL", "nuh_temporal_id_plus1 is zero")
    val maxType = if (allowPacketizationTypes) 50 else 47
    if (type > maxType) fail("UNSUPPORTED_HEVC_NAL_TYPE", "unsupported NAL type $type")
    return NalHeader(type, layer, tid)
}

private fun makeNalHeader(type: Int, layerId: Int, tid: Int): ByteArray = byteArrayOf(
    ((type shl 1) or (layerId ushr 5)).toByte(),
    (((layerId and 0x1f) shl 3) or tid).toByte(),
)

class HevcRtpPacketizer(
    private val payloadType: Int,
    private val ssrc: Long,
    initialSequence: Int,
    maxRtpPacketSize: Int = 1200,
    private val aggregate: Boolean = true,
) {
    private val maxPayload = maxRtpPacketSize - 12
    private var nextSequence = initialSequence

    init {
        require(payloadType in 96..127) { "payloadType must be dynamic (96..127)" }
        require(ssrc in 1..0xffff_ffffL) { "SSRC must be non-zero" }
        require(initialSequence in 0..0xffff)
        require(maxRtpPacketSize in 64..65_535)
    }

    @Synchronized
    fun packetize(nalUnits: List<ByteArray>, timestamp: Long): List<RtpPacket> {
        require(timestamp in 0..0xffff_ffffL)
        if (nalUnits.size !in 1..MAX_NALS_PER_ACCESS_UNIT) {
            fail("HEVC_RESOURCE_LIMIT", "access-unit NAL count out of range")
        }
        var totalBytes = 0L
        nalUnits.forEach { nal ->
            if (nal.size > MAX_HEVC_NAL_BYTES) fail("HEVC_RESOURCE_LIMIT", "NAL exceeds 16 MiB")
            parseNalHeader(nal)
            totalBytes += nal.size
            if (totalBytes > MAX_HEVC_ACCESS_UNIT_BYTES) fail("HEVC_RESOURCE_LIMIT", "access unit exceeds 64 MiB")
        }

        val payloads = mutableListOf<ByteArray>()
        var index = 0
        while (index < nalUnits.size) {
            val aggregated = if (aggregate) aggregate(nalUnits, index) else null
            if (aggregated != null) {
                payloads += aggregated.first
                index = aggregated.second
            } else {
                val nal = nalUnits[index++]
                if (nal.size <= maxPayload) payloads += nal else payloads += fragment(nal)
            }
            if (payloads.size > MAX_RTP_PACKETS_PER_ACCESS_UNIT) {
                fail("HEVC_RESOURCE_LIMIT", "access unit needs too many RTP packets")
            }
        }
        return payloads.mapIndexed { payloadIndex, payload ->
            RtpPacket(
                payloadType = payloadType,
                sequenceNumber = allocateSequence(),
                timestamp = timestamp,
                ssrc = ssrc,
                marker = payloadIndex == payloads.lastIndex,
                payload = payload,
            )
        }
    }

    private fun aggregate(nals: List<ByteArray>, start: Int): Pair<ByteArray, Int>? {
        val group = mutableListOf<ByteArray>()
        var size = 2
        var index = start
        while (index < nals.size && group.size < MAX_AGGREGATED_NALS) {
            val nal = nals[index]
            if (nal.size > 0xffff || size + 2 + nal.size > maxPayload) break
            group += nal
            size += 2 + nal.size
            index++
        }
        if (group.size < 2) return null
        val headers = group.map(::parseNalHeader)
        val buffer = ByteBuffer.allocate(size)
        buffer.put(makeNalHeader(48, headers.minOf { it.layerId }, headers.minOf { it.temporalIdPlusOne }))
        group.forEach { nal ->
            buffer.putShort(nal.size.toShort())
            buffer.put(nal)
        }
        return buffer.array() to index
    }

    private fun fragment(nal: ByteArray): List<ByteArray> {
        val header = parseNalHeader(nal)
        val capacity = maxPayload - 3
        if (capacity < 1 || nal.size == 2) fail("MALFORMED_HEVC_NAL", "NAL cannot be fragmented")
        val indicator = makeNalHeader(49, header.layerId, header.temporalIdPlusOne)
        val result = mutableListOf<ByteArray>()
        var offset = 2
        while (offset < nal.size) {
            val count = min(capacity, nal.size - offset)
            val start = offset == 2
            val end = offset + count == nal.size
            result += ByteArray(count + 3).also { payload ->
                payload[0] = indicator[0]
                payload[1] = indicator[1]
                payload[2] = (header.type or (if (start) 0x80 else 0) or (if (end) 0x40 else 0)).toByte()
                nal.copyInto(payload, 3, offset, offset + count)
            }
            offset += count
        }
        return result
    }

    private fun allocateSequence(): Int = nextSequence.also { nextSequence = (nextSequence + 1) and 0xffff }
}

object HevcRtpDepacketizer {
    fun depacketize(
        packets: List<RtpPacket>,
        expectedPayloadType: Int? = null,
        maxNalBytes: Int = MAX_HEVC_NAL_BYTES,
        maxAccessUnitBytes: Int = MAX_HEVC_ACCESS_UNIT_BYTES,
    ): List<ByteArray> {
        if (packets.size !in 1..MAX_RTP_PACKETS_PER_ACCESS_UNIT) {
            fail("RTP_RESOURCE_LIMIT", "packet count out of range")
        }
        val first = packets.first()
        packets.forEach { packet ->
            if (packet.timestamp != first.timestamp || packet.ssrc != first.ssrc || packet.payloadType != first.payloadType) {
                fail("MIXED_RTP_ACCESS_UNIT", "packets mix stream identity or timestamp")
            }
            if (expectedPayloadType != null && packet.payloadType != expectedPayloadType) {
                fail("UNEXPECTED_PAYLOAD_TYPE", "payload type differs from negotiation")
            }
        }
        val markers = packets.filter { it.marker }
        if (markers.size != 1) fail("INCOMPLETE_ACCESS_UNIT", "access unit needs exactly one marker")
        val markerSequence = markers.single().sequenceNumber
        val distances = packets.map { (markerSequence - it.sequenceNumber) and 0xffff }.toSet()
        if (distances != (0 until packets.size).toSet()) {
            fail("RTP_SEQUENCE_GAP", "sequence numbers are duplicated or non-contiguous")
        }
        val ordered = packets.sortedByDescending { (markerSequence - it.sequenceNumber) and 0xffff }
        if (!ordered.last().marker || ordered.dropLast(1).any { it.marker }) {
            fail("INCOMPLETE_ACCESS_UNIT", "marker is not on the final packet")
        }

        val result = mutableListOf<ByteArray>()
        var totalBytes = 0L
        var activeFu: ByteArray? = null
        var activeSignature: Triple<Byte, Byte, Int>? = null

        fun appendNal(nal: ByteArray) {
            parseNalHeader(nal)
            if (nal.size > maxNalBytes) fail("HEVC_RESOURCE_LIMIT", "NAL exceeds limit")
            totalBytes += nal.size
            if (totalBytes > maxAccessUnitBytes || result.size >= MAX_NALS_PER_ACCESS_UNIT) {
                fail("HEVC_RESOURCE_LIMIT", "access unit exceeds limit")
            }
            result += nal
        }

        ordered.forEach { packet ->
            val payload = packet.payload
            val header = parseNalHeader(payload, allowPacketizationTypes = true)
            when (header.type) {
                in 0..47 -> {
                    if (activeFu != null) fail("MALFORMED_HEVC_FU", "single NAL interleaves FU")
                    appendNal(payload)
                }
                48 -> {
                    if (activeFu != null) fail("MALFORMED_HEVC_FU", "AP interleaves FU")
                    var offset = 2
                    var count = 0
                    val innerHeaders = mutableListOf<NalHeader>()
                    while (offset < payload.size) {
                        if (offset + 2 > payload.size) fail("MALFORMED_HEVC_AP", "truncated NAL length")
                        val size = ((payload[offset].toInt() and 0xff) shl 8) or (payload[offset + 1].toInt() and 0xff)
                        offset += 2
                        if (size < 2 || offset + size > payload.size) fail("MALFORMED_HEVC_AP", "invalid NAL length")
                        val nal = payload.copyOfRange(offset, offset + size)
                        innerHeaders += parseNalHeader(nal)
                        appendNal(nal)
                        offset += size
                        count++
                    }
                    if (count < 2) fail("MALFORMED_HEVC_AP", "AP needs at least two NALs")
                    if (
                        header.layerId != innerHeaders.minOf { it.layerId } ||
                        header.temporalIdPlusOne != innerHeaders.minOf { it.temporalIdPlusOne }
                    ) {
                        fail("MALFORMED_HEVC_AP", "AP header does not use the lowest inner LayerId/TID")
                    }
                }
                49 -> {
                    if (payload.size < 4) fail("MALFORMED_HEVC_FU", "FU is too short")
                    val fuHeader = payload[2].toInt() and 0xff
                    val start = (fuHeader and 0x80) != 0
                    val end = (fuHeader and 0x40) != 0
                    val originalType = fuHeader and 0x3f
                    if (originalType > 47 || (start && end)) fail("MALFORMED_HEVC_FU", "invalid FU flags")
                    val signature = Triple(payload[0], payload[1], originalType)
                    if (start) {
                        if (activeFu != null) fail("MALFORMED_HEVC_FU", "nested FU")
                        activeFu = makeNalHeader(originalType, header.layerId, header.temporalIdPlusOne) + payload.copyOfRange(3, payload.size)
                        activeSignature = signature
                    } else {
                        if (activeFu == null || activeSignature != signature) {
                            fail("MALFORMED_HEVC_FU", "FU continuation lacks matching start")
                        }
                        activeFu = activeFu!! + payload.copyOfRange(3, payload.size)
                    }
                    if (activeFu!!.size > maxNalBytes) fail("HEVC_RESOURCE_LIMIT", "reconstructed NAL exceeds limit")
                    if (end) {
                        appendNal(activeFu!!)
                        activeFu = null
                        activeSignature = null
                    }
                }
                50 -> fail("UNSUPPORTED_HEVC_PAYLOAD", "PACI is not negotiated")
            }
        }
        if (activeFu != null) fail("INCOMPLETE_ACCESS_UNIT", "final FU fragment is missing")
        if (result.isEmpty()) fail("INCOMPLETE_ACCESS_UNIT", "no NAL units reconstructed")
        return result
    }
}

data class DepacketizedFrame(val timestamp: Long, val annexB: ByteArray, val damaged: Boolean)

/** Bounded jitter staging. Call [drain] after the configured reorder deadline for a timestamp. */
class BoundedRtpFrameBuffer(
    private val payloadType: Int,
    private val maxFrames: Int = 4,
    private val maxPacketsPerFrame: Int = MAX_RTP_PACKETS_PER_ACCESS_UNIT,
) {
    private val frames = LinkedHashMap<Long, MutableList<RtpPacket>>()

    @Synchronized
    fun offer(packet: RtpPacket) {
        if (packet.payloadType != payloadType) return
        val frame = frames.getOrPut(packet.timestamp) {
            if (frames.size >= maxFrames) frames.remove(frames.keys.first())
            mutableListOf()
        }
        if (frame.size >= maxPacketsPerFrame) {
            frames.remove(packet.timestamp)
            return
        }
        frame += packet
    }

    @Synchronized
    fun drain(timestamp: Long): DepacketizedFrame? {
        val packets = frames.remove(timestamp) ?: return null
        return try {
            val nals = HevcRtpDepacketizer.depacketize(packets, payloadType)
            DepacketizedFrame(timestamp, AnnexB.join(nals), false)
        } catch (_: HevcRtpException) {
            DepacketizedFrame(timestamp, byteArrayOf(), true)
        }
    }
}

object AnnexB {
    fun split(data: ByteArray, maxNalBytes: Int = MAX_HEVC_NAL_BYTES): List<ByteArray> {
        if (data.size > MAX_HEVC_ACCESS_UNIT_BYTES) fail("HEVC_RESOURCE_LIMIT", "access unit exceeds limit")
        val starts = mutableListOf<Pair<Int, Int>>()
        var index = 0
        while (index + 3 <= data.size) {
            val prefix = when {
                index + 4 <= data.size && data[index] == 0.toByte() && data[index + 1] == 0.toByte() &&
                    data[index + 2] == 0.toByte() && data[index + 3] == 1.toByte() -> 4
                data[index] == 0.toByte() && data[index + 1] == 0.toByte() && data[index + 2] == 1.toByte() -> 3
                else -> 0
            }
            if (prefix > 0) {
                starts += index to prefix
                if (starts.size > MAX_NALS_PER_ACCESS_UNIT) fail("HEVC_RESOURCE_LIMIT", "too many NAL units")
                index += prefix
            } else index++
        }
        if (starts.isEmpty()) {
            if (data.size !in 2..maxNalBytes) fail("MALFORMED_HEVC_NAL", "invalid NAL length")
            parseNalHeader(data)
            return listOf(data)
        }
        return starts.mapIndexed { i, (start, prefix) ->
            val end = if (i == starts.lastIndex) data.size else starts[i + 1].first
            val nal = data.copyOfRange(start + prefix, end)
            if (nal.size !in 2..maxNalBytes) fail("MALFORMED_HEVC_NAL", "invalid NAL length")
            parseNalHeader(nal)
            nal
        }
    }

    fun join(nals: List<ByteArray>): ByteArray {
        if (nals.size !in 1..MAX_NALS_PER_ACCESS_UNIT) fail("HEVC_RESOURCE_LIMIT", "invalid NAL count")
        val total = nals.sumOf { it.size.toLong() + 4 }
        if (total > MAX_HEVC_ACCESS_UNIT_BYTES) fail("HEVC_RESOURCE_LIMIT", "access unit exceeds limit")
        return ByteBuffer.allocate(total.toInt()).apply {
            nals.forEach { nal ->
                parseNalHeader(nal)
                put(byteArrayOf(0, 0, 0, 1))
                put(nal)
            }
        }.array()
    }
}

class RtpTimestampClock(private val base: Long) {
    fun fromPresentationTimeUs(presentationTimeUs: Long): Long =
        (base + (presentationTimeUs * RTP_CLOCK_RATE) / 1_000_000L) and 0xffff_ffffL
}

object Rtcp {
    sealed interface ParsedPacket {
        data class ReceiverReport(val senderSsrc: Long, val blocks: List<ReportBlock>) : ParsedPacket
        data class PictureLossIndication(val senderSsrc: Long, val mediaSsrc: Long) : ParsedPacket
    }

    data class ReportBlock(
        val sourceSsrc: Long,
        val fractionLost: Int,
        val cumulativeLost: Int,
        val extendedHighestSequence: Long,
        val interarrivalJitter: Long,
        val lastSenderReport: Long,
        val delaySinceLastSenderReport: Long,
    )

    fun pictureLossIndication(senderSsrc: Long, mediaSsrc: Long): ByteArray {
        require(senderSsrc in 1..0xffff_ffffL && mediaSsrc in 1..0xffff_ffffL)
        return ByteBuffer.allocate(12).apply {
            put(0x81.toByte())
            put(206.toByte())
            putShort(2.toShort())
            putInt(senderSsrc.toInt())
            putInt(mediaSsrc.toInt())
        }.array()
    }

    /** RFC 3550 receiver report with one report block. */
    fun receiverReport(
        senderSsrc: Long,
        mediaSsrc: Long,
        fractionLost: Int,
        cumulativeLost: Int,
        highestSequence: Long,
        jitter: Long,
        lastSenderReport: Long = 0,
        delaySinceLastSenderReport: Long = 0,
    ): ByteArray {
        require(senderSsrc in 1..0xffff_ffffL && mediaSsrc in 1..0xffff_ffffL)
        require(fractionLost in 0..255)
        require(cumulativeLost in -0x800000..0x7fffff)
        val lost = cumulativeLost and 0xffffff
        return ByteBuffer.allocate(32).apply {
            put(0x81.toByte())
            put(201.toByte())
            putShort(7.toShort())
            putInt(senderSsrc.toInt())
            putInt(mediaSsrc.toInt())
            put(fractionLost.toByte())
            put(((lost ushr 16) and 0xff).toByte())
            put(((lost ushr 8) and 0xff).toByte())
            put((lost and 0xff).toByte())
            putInt(highestSequence.toInt())
            putInt(jitter.toInt())
            putInt(lastSenderReport.toInt())
            putInt(delaySinceLastSenderReport.toInt())
        }.array()
    }

    fun parseDatagram(bytes: ByteArray, expectedMediaSsrc: Long? = null): List<ParsedPacket> {
        if (bytes.size !in 8..1500) fail("MALFORMED_RTCP", "RTCP datagram length out of range")
        val result = mutableListOf<ParsedPacket>()
        var offset = 0
        while (offset < bytes.size) {
            if (offset + 4 > bytes.size) fail("MALFORMED_RTCP", "truncated RTCP header")
            val first = bytes[offset].toInt() and 0xff
            if (first ushr 6 != 2 || (first and 0x20) != 0) fail("MALFORMED_RTCP", "invalid RTCP header")
            val count = first and 0x1f
            val packetType = bytes[offset + 1].toInt() and 0xff
            val words = ((bytes[offset + 2].toInt() and 0xff) shl 8) or (bytes[offset + 3].toInt() and 0xff)
            val packetSize = (words + 1) * 4
            if (packetSize < 8 || offset + packetSize > bytes.size) fail("MALFORMED_RTCP", "invalid RTCP length")
            val packet = bytes.copyOfRange(offset, offset + packetSize)
            result += when (packetType) {
                201 -> parseReceiverReport(packet, count)
                206 -> parsePli(packet, count, expectedMediaSsrc)
                else -> fail("UNSUPPORTED_RTCP", "RTCP packet type $packetType is not negotiated")
            }
            offset += packetSize
        }
        return result
    }

    private fun parseReceiverReport(packet: ByteArray, count: Int): ParsedPacket.ReceiverReport {
        if (packet.size != 8 + count * 24) fail("MALFORMED_RTCP", "RR length does not match report count")
        val sender = u32(packet, 4)
        if (sender == 0L) fail("MALFORMED_RTCP", "RR sender SSRC is zero")
        val blocks = (0 until count).map { index ->
            val offset = 8 + index * 24
            val source = u32(packet, offset)
            if (source == 0L) fail("MALFORMED_RTCP", "RR source SSRC is zero")
            val rawLost = ((packet[offset + 5].toInt() and 0xff) shl 16) or
                ((packet[offset + 6].toInt() and 0xff) shl 8) or (packet[offset + 7].toInt() and 0xff)
            val signedLost = if ((rawLost and 0x800000) != 0) rawLost or -0x1000000 else rawLost
            ReportBlock(
                source,
                packet[offset + 4].toInt() and 0xff,
                signedLost,
                u32(packet, offset + 8),
                u32(packet, offset + 12),
                u32(packet, offset + 16),
                u32(packet, offset + 20),
            )
        }
        return ParsedPacket.ReceiverReport(sender, blocks)
    }

    private fun parsePli(packet: ByteArray, format: Int, expectedMediaSsrc: Long?): ParsedPacket.PictureLossIndication {
        if (format != 1 || packet.size != 12) fail("MALFORMED_RTCP", "invalid PLI")
        val sender = u32(packet, 4)
        val media = u32(packet, 8)
        if (sender == 0L || media == 0L) fail("MALFORMED_RTCP", "PLI SSRC is zero")
        if (expectedMediaSsrc != null && media != expectedMediaSsrc) {
            fail("UNEXPECTED_RTCP_SSRC", "PLI media SSRC differs from negotiation")
        }
        return ParsedPacket.PictureLossIndication(sender, media)
    }

    private fun u32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)
}

private fun fail(code: String, message: String): Nothing = throw HevcRtpException(code, message)
