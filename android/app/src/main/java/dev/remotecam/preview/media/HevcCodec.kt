package dev.remotecam.preview.media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.camera.core.SurfaceRequest
import androidx.camera.video.VideoOutput
import dev.remotecam.preview.model.PixelSize
import dev.remotecam.preview.model.StreamProfile
import dev.remotecam.preview.protocol.MAX_HEVC_ACCESS_UNIT_BYTES
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class EncodedAccessUnit(
    val data: ByteArray,
    val presentationTimeUs: Long,
    val keyFrame: Boolean,
    val codecConfig: Boolean,
)

data class CodecParameterSets(
    val buffers: List<ByteArray>,
)

interface HevcEncoderListener {
    fun onEncoderReady(actualSize: PixelSize) = Unit
    fun onParameterSets(parameters: CodecParameterSets) = Unit
    fun onAccessUnit(accessUnit: EncodedAccessUnit)
    fun onEncoderError(error: Throwable)
}

/** MediaCodec surface-input HEVC encoder suitable for CameraX VideoOutput. */
class HevcEncoder(
    private val profile: StreamProfile,
    private val listener: HevcEncoderListener,
) : AutoCloseable {
    private val callbackThread = HandlerThread("remote-cam-hevc-encoder").apply { start() }
    private val callbackHandler = Handler(callbackThread.looper)
    private val surfaceExecutor = Executors.newSingleThreadExecutor()
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var surfaceRequest: SurfaceRequest? = null
    private val closed = AtomicBoolean(false)

    @Synchronized
    fun fulfill(request: SurfaceRequest) {
        if (closed.get()) {
            request.willNotProvideSurface()
            return
        }
        if (codec != null) {
            surfaceRequest?.invalidate()
            stopCodec()
        }
        val actualSize = PixelSize(request.resolution.width, request.resolution.height)
        val mediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        mediaCodec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    if (info.size !in 0..MAX_HEVC_ACCESS_UNIT_BYTES) {
                        throw IllegalStateException("Encoder output exceeds access-unit limit")
                    }
                    val data = codec.getOutputBuffer(index)?.copyRange(info.offset, info.size) ?: byteArrayOf()
                    if (data.isNotEmpty()) {
                        listener.onAccessUnit(
                            EncodedAccessUnit(
                                data = data,
                                presentationTimeUs = info.presentationTimeUs,
                                keyFrame = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0,
                                codecConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0,
                            ),
                        )
                    }
                } catch (error: Throwable) {
                    listener.onEncoderError(error)
                } finally {
                    runCatching { codec.releaseOutputBuffer(index, false) }
                }
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                val csd = (0..2).mapNotNull { index ->
                    format.getByteBuffer("csd-$index")?.let { buffer -> buffer.copyRange(buffer.position(), buffer.remaining()) }
                }
                if (csd.isNotEmpty()) listener.onParameterSets(CodecParameterSets(csd))
            }

            override fun onError(codec: MediaCodec, exception: MediaCodec.CodecException) {
                listener.onEncoderError(exception)
            }
        }, callbackHandler)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, actualSize.width, actualSize.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, profile.bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, profile.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, profile.frameRate.toFloat())
        }
        try {
            mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = mediaCodec.createInputSurface()
            codec = mediaCodec
            inputSurface = surface
            surfaceRequest = request
            mediaCodec.start()
            request.provideSurface(surface, surfaceExecutor) {
                synchronized(this@HevcEncoder) {
                    if (surfaceRequest === request) {
                        surfaceRequest = null
                        stopCodec()
                    }
                }
            }
            listener.onEncoderReady(actualSize)
        } catch (error: Throwable) {
            runCatching { mediaCodec.release() }
            codec = null
            inputSurface = null
            request.willNotProvideSurface()
            listener.onEncoderError(error)
        }
    }

    fun requestKeyFrame() {
        runCatching {
            codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        }.onFailure(listener::onEncoderError)
    }

    @Synchronized
    private fun stopCodec() {
        val current = codec ?: return
        codec = null
        runCatching { current.stop() }
        runCatching { current.release() }
        runCatching { inputSurface?.release() }
        inputSurface = null
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        surfaceRequest?.invalidate()
        synchronized(this) { stopCodec() }
        surfaceExecutor.shutdown()
        callbackThread.quitSafely()
    }
}

class HevcVideoOutput(
    private val encoder: HevcEncoder,
    val preferredSize: PixelSize,
) : VideoOutput, AutoCloseable {
    override fun onSurfaceRequested(request: SurfaceRequest) = encoder.fulfill(request)
    fun requestKeyFrame() = encoder.requestKeyFrame()
    override fun close() = encoder.close()
}

data class DecoderAccessUnit(val data: ByteArray, val presentationTimeUs: Long)

interface HevcDecoderListener {
    fun onDecoderError(error: Throwable)
}

/** Low-latency decoder with a three-frame input bound; oldest queued frames are dropped. */
class HevcDecoder(
    profile: StreamProfile,
    surface: Surface,
    parameterSets: CodecParameterSets,
    private val listener: HevcDecoderListener,
) : AutoCloseable {
    private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
    private val queue = ArrayBlockingQueue<DecoderAccessUnit>(3)
    private val running = AtomicBoolean(true)
    private val worker: Thread

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, profile.size.width, profile.size.height).apply {
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_OPERATING_RATE, profile.frameRate)
            parameterSets.buffers.take(3).forEachIndexed { index, bytes -> setByteBuffer("csd-$index", ByteBuffer.wrap(bytes)) }
        }
        codec.configure(format, surface, null, 0)
        codec.start()
        worker = Thread(::decodeLoop, "remote-cam-hevc-decoder").apply { start() }
    }

    fun queue(accessUnit: DecoderAccessUnit) {
        if (accessUnit.data.size !in 1..MAX_HEVC_ACCESS_UNIT_BYTES || !running.get()) return
        if (!queue.offer(accessUnit)) {
            queue.poll()
            queue.offer(accessUnit)
        }
    }

    private fun decodeLoop() {
        val info = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                val accessUnit = queue.poll()
                if (accessUnit != null) {
                    val index = codec.dequeueInputBuffer(2_000)
                    if (index >= 0) {
                        codec.getInputBuffer(index)?.apply {
                            clear()
                            if (capacity() < accessUnit.data.size) throw IllegalStateException("Decoder buffer too small")
                            put(accessUnit.data)
                        }
                        codec.queueInputBuffer(index, 0, accessUnit.data.size, accessUnit.presentationTimeUs, 0)
                    } else {
                        queue.offer(accessUnit)
                    }
                }
                while (true) {
                    val output = codec.dequeueOutputBuffer(info, 0)
                    if (output < 0) break
                    codec.releaseOutputBuffer(output, true)
                }
                if (accessUnit == null) Thread.yield()
            }
        } catch (error: Throwable) {
            if (running.get()) listener.onDecoderError(error)
        }
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        worker.interrupt()
        runCatching { worker.join(500) }
        runCatching { codec.stop() }
        runCatching { codec.release() }
        queue.clear()
    }
}

private fun ByteBuffer.copyRange(offset: Int, size: Int): ByteArray {
    val copy = duplicate()
    copy.position(offset)
    copy.limit(offset + size)
    return ByteArray(size).also(copy::get)
}
