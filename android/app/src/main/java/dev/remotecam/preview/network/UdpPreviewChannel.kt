package dev.remotecam.preview.network

import android.net.Network
import dev.remotecam.preview.media.CodecParameterSets
import dev.remotecam.preview.media.EncodedAccessUnit
import dev.remotecam.preview.protocol.AnnexB
import dev.remotecam.preview.protocol.BoundedRtpFrameBuffer
import dev.remotecam.preview.protocol.DepacketizedFrame
import dev.remotecam.preview.protocol.HevcRtpPacketizer
import dev.remotecam.preview.protocol.Rtcp
import dev.remotecam.preview.protocol.RtpPacket
import dev.remotecam.preview.protocol.RtpTimestampClock
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

private val RTP_PROBE = "RCP1".encodeToByteArray()

internal fun rtpNalsForAccessUnit(
    accessUnit: EncodedAccessUnit,
    parameterSets: CodecParameterSets?,
): List<ByteArray> = buildList {
    parameterSets?.buffers?.forEach { addAll(AnnexB.split(it)) }
    addAll(AnnexB.split(accessUnit.data))
}

/** A-side RTP listener. B's probe supplies the return UDP 5-tuple used by every RTP packet. */
class UdpPreviewSender(
    network: Network,
    localAddress: Inet6Address,
    localPort: Int,
    private val expectedPeerAddress: Inet6Address,
    payloadType: Int,
    ssrc: Long,
    initialSequence: Int,
    initialTimestamp: Long,
    maxRtpPacketSize: Int,
) : AutoCloseable {
    private val socket = DatagramSocket(null).apply {
        network.bindSocket(this)
        bind(InetSocketAddress(localAddress, localPort))
        trafficClass = 0xb8
        receiveBufferSize = 64 * 1024
    }
    private val destination = AtomicReference<InetSocketAddress?>(null)
    private val running = AtomicBoolean(true)
    private val packetizer = HevcRtpPacketizer(payloadType, ssrc, initialSequence, maxRtpPacketSize)
    private val clock = RtpTimestampClock(initialTimestamp)
    private val probeThread = Thread(::probeLoop, "aware-rtp-probe-listener").apply { start() }

    private fun probeLoop() {
        val buffer = ByteArray(64)
        while (running.get()) {
            try {
                val datagram = DatagramPacket(buffer, buffer.size)
                socket.receive(datagram)
                if (datagram.address.address.contentEquals(expectedPeerAddress.address) &&
                    datagram.length == RTP_PROBE.size &&
                    datagram.data.copyOfRange(datagram.offset, datagram.offset + datagram.length).contentEquals(RTP_PROBE)
                ) {
                    destination.set(InetSocketAddress(datagram.address, datagram.port))
                }
            } catch (_: Throwable) {
                if (!running.get()) return
            }
        }
    }

    @Synchronized
    fun send(accessUnit: EncodedAccessUnit, parameterSets: CodecParameterSets? = null) {
        if (accessUnit.codecConfig || socket.isClosed) return
        sendNals(rtpNalsForAccessUnit(accessUnit, parameterSets), accessUnit.presentationTimeUs)
    }

    @Synchronized
    fun sendParameterSets(parameters: CodecParameterSets, presentationTimeUs: Long) {
        if (socket.isClosed) return
        val nals = parameters.buffers.flatMap { AnnexB.split(it) }
        if (nals.isNotEmpty()) sendNals(nals, presentationTimeUs)
    }

    private fun sendNals(nals: List<ByteArray>, presentationTimeUs: Long) {
        val target = destination.get() ?: return
        packetizer.packetize(nals, clock.fromPresentationTimeUs(presentationTimeUs)).forEach { packet ->
            val bytes = packet.encode()
            socket.send(DatagramPacket(bytes, bytes.size, target))
        }
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        socket.close()
        probeThread.interrupt()
        runCatching { probeThread.join(500) }
    }
}

data class RtpReceiveStats(
    val receivedPackets: Long,
    val highestSequence: Long,
    val cumulativeLost: Int,
    val fractionLost: Int,
    val jitter: Long,
)

interface UdpPreviewReceiverListener {
    fun onFrame(frame: DepacketizedFrame)
    fun onMalformedPacket() = Unit
    fun onReceiverError(error: Throwable)
}

/** B-side RTP socket: connects to A's accepted listener port and sends RCP1 from the receive socket. */
class UdpPreviewReceiver(
    network: Network,
    localAddress: Inet6Address,
    peerAddress: Inet6Address,
    peerPort: Int,
    private val expectedPayloadType: Int,
    private val expectedSsrc: Long,
    private val maxRtpPacketSize: Int,
    private val listener: UdpPreviewReceiverListener,
    reorderDeadlineMs: Long = 20,
) : AutoCloseable {
    private val socket = DatagramSocket(null).apply {
        network.bindSocket(this)
        receiveBufferSize = 2 * 1024 * 1024
        bind(InetSocketAddress(localAddress, 0))
        connect(peerAddress, peerPort)
    }
    private val running = AtomicBoolean(true)
    private val frames = BoundedRtpFrameBuffer(expectedPayloadType)
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val receivedPackets = AtomicLong(0)
    private val highestSequence = AtomicLong(-1)
    private val firstSequence = AtomicLong(-1)
    private val receiverThread = Thread(::receiveLoop, "aware-rtp-receiver").apply { start() }
    private val deadline = reorderDeadlineMs.coerceIn(5, 50)

    init {
        sendProbe()
    }

    private fun sendProbe() = runCatching { socket.send(DatagramPacket(RTP_PROBE, RTP_PROBE.size)) }

    private fun receiveLoop() {
        val buffer = ByteArray(maxRtpPacketSize)
        try {
            while (running.get()) {
                val datagram = DatagramPacket(buffer, buffer.size)
                socket.receive(datagram)
                val packet = try {
                    RtpPacket.decode(datagram.data.copyOfRange(datagram.offset, datagram.offset + datagram.length), maxRtpPacketSize)
                } catch (_: IllegalArgumentException) {
                    listener.onMalformedPacket()
                    continue
                }
                if (packet.payloadType != expectedPayloadType || packet.ssrc != expectedSsrc) continue
                receivedPackets.incrementAndGet()
                firstSequence.compareAndSet(-1, packet.sequenceNumber.toLong())
                highestSequence.accumulateAndGet(packet.sequenceNumber.toLong(), ::maxOf)
                frames.offer(packet)
                if (packet.marker) {
                    scheduler.schedule({ frames.drain(packet.timestamp)?.let(listener::onFrame) }, deadline, TimeUnit.MILLISECONDS)
                }
            }
        } catch (error: Throwable) {
            if (running.get()) listener.onReceiverError(error)
        }
    }

    fun stats(): RtpReceiveStats {
        val received = receivedPackets.get()
        val first = firstSequence.get()
        val highest = highestSequence.get()
        val expected = if (first < 0 || highest < first) received else highest - first + 1
        val lost = (expected - received).coerceAtLeast(0).coerceAtMost(0x7fffff).toInt()
        val fraction = if (expected == 0L) 0 else ((lost * 256L) / expected).toInt().coerceIn(0, 255)
        return RtpReceiveStats(received, highest.coerceAtLeast(0), lost, fraction, 0)
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        socket.close()
        scheduler.shutdownNow()
        receiverThread.interrupt()
        runCatching { receiverThread.join(500) }
    }
}

interface RtcpReceiverListener {
    fun onPictureLossIndication()
    fun onReceiverReport(bytes: ByteArray) = Unit
    fun onRtcpError(error: Throwable) = Unit
}

/** A-side RTCP listener advertised in session.accepted. */
class UdpRtcpReceiver(
    network: Network,
    localAddress: Inet6Address,
    localPort: Int,
    private val expectedPeerAddress: Inet6Address,
    private val expectedMediaSsrc: Long,
    private val listener: RtcpReceiverListener,
) : AutoCloseable {
    private val socket = DatagramSocket(null).apply {
        network.bindSocket(this)
        bind(InetSocketAddress(localAddress, localPort))
    }
    private val running = AtomicBoolean(true)
    private val thread = Thread(::loop, "aware-rtcp-receiver").apply { start() }

    private fun loop() {
        val buffer = ByteArray(1500)
        try {
            while (running.get()) {
                val datagram = DatagramPacket(buffer, buffer.size)
                socket.receive(datagram)
                if (!datagram.address.address.contentEquals(expectedPeerAddress.address) || datagram.length < 8) continue
                val bytes = datagram.data.copyOfRange(datagram.offset, datagram.offset + datagram.length)
                val parsed = try {
                    Rtcp.parseDatagram(bytes, expectedMediaSsrc)
                } catch (error: IllegalArgumentException) {
                    listener.onRtcpError(error)
                    continue
                }
                parsed.forEach { packet ->
                    when (packet) {
                        is Rtcp.ParsedPacket.ReceiverReport -> listener.onReceiverReport(bytes)
                        is Rtcp.ParsedPacket.PictureLossIndication -> listener.onPictureLossIndication()
                    }
                }
            }
        } catch (error: Throwable) {
            if (running.get()) listener.onRtcpError(error)
        }
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        socket.close()
        thread.interrupt()
        runCatching { thread.join(500) }
    }
}

/** B-side RTCP socket sends the first RR immediately, periodic RR, and PLI on damage. */
class UdpRtcpReporter(
    network: Network,
    localAddress: Inet6Address,
    peerAddress: Inet6Address,
    peerPort: Int,
    private val senderSsrc: Long,
    private val mediaSsrc: Long,
    private val stats: () -> RtpReceiveStats,
) : AutoCloseable {
    private val socket = DatagramSocket(null).apply {
        network.bindSocket(this)
        bind(InetSocketAddress(localAddress, 0))
        connect(peerAddress, peerPort)
    }
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val pliLock = Any()
    private var lastPliAtNanos: Long? = null

    init {
        sendReceiverReport()
        scheduler.scheduleAtFixedRate(::sendReceiverReport, 1, 1, TimeUnit.SECONDS)
    }

    fun requestKeyFrame() {
        val now = System.nanoTime()
        synchronized(pliLock) {
            val previous = lastPliAtNanos
            if (previous != null && now - previous < 500_000_000L) return
            lastPliAtNanos = now
        }
        send(Rtcp.pictureLossIndication(senderSsrc, mediaSsrc))
    }

    private fun sendReceiverReport() {
        val current = stats()
        send(
            Rtcp.receiverReport(
                senderSsrc,
                mediaSsrc,
                current.fractionLost,
                current.cumulativeLost,
                current.highestSequence,
                current.jitter,
            ),
        )
    }

    private fun send(bytes: ByteArray) = runCatching { socket.send(DatagramPacket(bytes, bytes.size)) }

    override fun close() {
        scheduler.shutdownNow()
        socket.close()
    }
}
