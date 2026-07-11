package dev.remotecam.preview.network

import android.net.Network
import android.net.Uri
import dev.remotecam.preview.photo.PhotoDescriptor
import dev.remotecam.preview.photo.PhotoReceiver
import dev.remotecam.preview.protocol.ControlEnvelope
import dev.remotecam.preview.protocol.ControlMessageCodec
import java.net.Inet6Address
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.intOrNull

interface SessionClientListener {
    fun onOpen()
    fun onMessage(message: ControlEnvelope)
    fun onClosed()
    fun onError(error: Throwable)
}

/** OkHttp is pinned to the Wi-Fi Aware Network via its SocketFactory and a fixed peer DNS mapping. */
class SessionClient(
    network: Network,
    private val peerAddress: Inet6Address,
    private val port: Int,
) : AutoCloseable {
    private val host = "aware-peer.invalid"
    private val client = OkHttpClient.Builder()
        .socketFactory(network.socketFactory)
        .dns(object : Dns {
            override fun lookup(hostname: String) = if (hostname == host) {
                listOf(peerAddress)
            } else {
                throw UnknownHostException("Only the negotiated Wi-Fi Aware peer can be resolved")
            }
        })
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(5, TimeUnit.SECONDS)
        .build()
    private var webSocket: WebSocket? = null
    private val accessToken = AtomicReference<String?>(null)
    private val photoPort = AtomicInteger(0)
    private val closed = AtomicBoolean(false)

    fun connect(listener: SessionClientListener) {
        val request = Request.Builder()
            .url("http://$host:$port/v1/events")
            .build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen()

            override fun onMessage(webSocket: WebSocket, text: String) {
                runCatching { ControlMessageCodec.decode(text.encodeToByteArray()) }
                    .onSuccess { message ->
                        if (message.type == "session.accepted") {
                            message.payload["accessToken"]?.jsonPrimitive?.content?.let(accessToken::set)
                            message.payload["photoEndpoint"]?.jsonObject?.get("port")
                                ?.jsonPrimitive?.intOrNull?.takeIf { it in 1..65_535 }?.let(photoPort::set)
                        }
                        listener.onMessage(message)
                    }
                    .onFailure(listener::onError)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                listener.onError(IllegalArgumentException("Binary control messages are not negotiated"))
                webSocket.close(1003, "text only")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = listener.onClosed()
            override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) = listener.onError(error)
        })
    }

    fun send(message: ControlEnvelope): Boolean =
        webSocket?.send(ControlMessageCodec.encode(message).decodeToString()) == true

    suspend fun pullPhoto(descriptor: PhotoDescriptor, receiver: PhotoReceiver): Uri = withContext(Dispatchers.IO) {
        descriptor.validate()
        val token = requireNotNull(accessToken.get()) { "session.accepted has not supplied an access token" }
        val endpointPort = photoPort.get().takeIf { it in 1..65_535 }
            ?: error("Android cannot resolve the negotiated photoEndpoint serviceName without a numeric port")
        val request = Request.Builder()
            .url("http://$host:$endpointPort${descriptor.downloadPath}")
            .header("Authorization", "Bearer $token")
            .build()
        client.newCall(request).execute().use { response ->
            require(response.isSuccessful) { "Photo HTTP request failed with ${response.code}" }
            val body = requireNotNull(response.body) { "Photo response has no body" }
            val contentType = response.header("Content-Type")?.substringBefore(';')?.trim()
            require(contentType == descriptor.mimeType) { "Photo Content-Type differs from announced metadata" }
            val contentLength = response.header("Content-Length")?.toLongOrNull()
            require(contentLength == descriptor.byteSize && body.contentLength() == descriptor.byteSize) {
                "Photo Content-Length differs from announced metadata"
            }
            response.header("X-Content-SHA256")?.let { require(it == descriptor.sha256) { "Photo digest header mismatch" } }
            body.byteStream().use { receiver.receive(it, descriptor) }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        webSocket?.cancel()
        webSocket = null
        accessToken.set(null)
        photoPort.set(0)
        client.dispatcher.cancelAll()
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}
