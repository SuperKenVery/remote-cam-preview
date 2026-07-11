package dev.remotecam.preview.network

import dev.remotecam.preview.photo.PhotoResourceRegistry
import dev.remotecam.preview.protocol.ControlEnvelope
import dev.remotecam.preview.protocol.ControlMessageCodec
import dev.remotecam.preview.protocol.MAX_CONTROL_MESSAGE_BYTES
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.InputStream
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.jsonPrimitive

interface SessionServerListener {
    fun onControlConnected(connection: ControlServerConnection)
    fun onControlMessage(connection: ControlServerConnection, message: ControlEnvelope)
    fun onControlClosed(connection: ControlServerConnection)
    fun onServerError(error: Throwable)
}

interface ControlServerConnection : Closeable {
    fun send(message: ControlEnvelope): Boolean
}

/** HTTP/1.1 + RFC 6455 endpoint bound only to the current Aware link-local address. */
class SessionServer(
    private val localAddress: Inet6Address,
    private val port: Int,
    private val accessToken: String,
    private val photos: PhotoResourceRegistry,
    private val listener: SessionServerListener,
) : AutoCloseable {
    private val running = AtomicBoolean(false)
    private val clients = Executors.newFixedThreadPool(4)
    private val currentControl = AtomicReference<WebSocketConnection?>()
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        try {
            val socket = ServerSocket().apply {
                reuseAddress = false
                bind(InetSocketAddress(localAddress, port), 8)
            }
            serverSocket = socket
            acceptThread = Thread({ acceptLoop(socket) }, "aware-http-server").apply { start() }
        } catch (error: Throwable) {
            running.set(false)
            listener.onServerError(error)
        }
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running.get()) {
            try {
                val socket = server.accept().apply { soTimeout = 15_000 }
                clients.execute { handle(socket) }
            } catch (error: Throwable) {
                if (running.get()) listener.onServerError(error)
            }
        }
    }

    private fun handle(socket: Socket) = socket.use { client ->
        val input = BufferedInputStream(client.getInputStream(), 64 * 1024)
        val output = BufferedOutputStream(client.getOutputStream(), 64 * 1024)
        try {
            val request = HttpRequest.read(input)
            when {
                request.method == "GET" && request.path in setOf("/v1/events", "/") ->
                    upgradeWebSocket(client, input, output, request)
                request.method == "GET" && request.path == "/v1/health" && authorized(request) -> respond(output, 200, "OK")
                request.method == "GET" && request.path.startsWith("/v1/photos/") && authorized(request) ->
                    servePhoto(output, request.path)
                request.path == "/v1/health" || request.path.startsWith("/v1/photos/") -> respond(output, 401, "Unauthorized")
                else -> respond(output, 404, "Not Found")
            }
        } catch (_: EOFException) {
            Unit
        } catch (error: Throwable) {
            runCatching { respond(output, 400, "Bad Request") }
            listener.onServerError(error)
        }
    }

    private fun upgradeWebSocket(
        socket: Socket,
        input: BufferedInputStream,
        output: BufferedOutputStream,
        request: HttpRequest,
    ) {
        val upgrade = request.headers["upgrade"]?.lowercase(Locale.US)
        val connection = request.headers["connection"]?.lowercase(Locale.US)
        val key = request.headers["sec-websocket-key"]
        if (upgrade != "websocket" || connection?.split(',')?.map { it.trim() }?.contains("upgrade") != true || key == null) {
            respond(output, 426, "Upgrade Required")
            return
        }
        val accept = Base64.getEncoder().encodeToString(
            MessageDigest.getInstance("SHA-1").digest((key + WEB_SOCKET_GUID).toByteArray(StandardCharsets.US_ASCII)),
        )
        output.writeAscii(
            "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: $accept\r\n\r\n",
        )
        output.flush()
        // The initial upgrade is intentionally tokenless. The Aware-bound peer must identify the
        // negotiated session within five seconds; session.accepted then delivers the Bearer token.
        socket.soTimeout = 5_000
        val webSocket = WebSocketConnection(socket, input, output)
        if (!currentControl.compareAndSet(null, webSocket)) {
            webSocket.close()
            return
        }
        listener.onControlConnected(webSocket)
        try {
            webSocket.readLoop { listener.onControlMessage(webSocket, it) }
        } finally {
            currentControl.compareAndSet(webSocket, null)
            listener.onControlClosed(webSocket)
        }
    }

    private fun authorized(request: HttpRequest): Boolean {
        val supplied = request.headers["authorization"] ?: return false
        return MessageDigest.isEqual(supplied.encodeToByteArray(), "Bearer $accessToken".encodeToByteArray())
    }

    private fun servePhoto(output: BufferedOutputStream, path: String) {
        val photoId = path.removePrefix("/v1/photos/")
        if (!photoId.matches(Regex("[A-Za-z0-9_-]{16,128}"))) {
            respond(output, 400, "Bad photo ID")
            return
        }
        val resource = photos.open(photoId) ?: return respond(output, 404, "Photo not found")
        val (descriptor, input) = resource
        output.writeAscii(
            "HTTP/1.1 200 OK\r\n" +
                "Content-Type: ${descriptor.mimeType}\r\n" +
                "Content-Length: ${descriptor.byteSize}\r\n" +
                "X-Content-SHA256: ${descriptor.sha256}\r\n" +
                "Cache-Control: no-store\r\n" +
                "Connection: close\r\n\r\n",
        )
        input.use { source ->
            val buffer = ByteArray(64 * 1024)
            var remaining = descriptor.byteSize
            while (remaining > 0) {
                val count = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (count < 0) throw EOFException("Published photo was truncated")
                output.write(buffer, 0, count)
                remaining -= count
            }
        }
        output.flush()
    }

    private fun respond(output: BufferedOutputStream, status: Int, text: String) {
        val bytes = text.encodeToByteArray()
        output.writeAscii(
            "HTTP/1.1 $status $text\r\n" +
                "Content-Type: text/plain; charset=utf-8\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Cache-Control: no-store\r\n" +
                "Connection: close\r\n\r\n",
        )
        output.write(bytes)
        output.flush()
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        currentControl.getAndSet(null)?.close()
        runCatching { serverSocket?.close() }
        runCatching { acceptThread?.join(500) }
        clients.shutdownNow()
        serverSocket = null
    }
}

private data class HttpRequest(val method: String, val path: String, val headers: Map<String, String>) {
    companion object {
        fun read(input: InputStream): HttpRequest {
            val requestLine = input.readHttpLine(8 * 1024)
            val parts = requestLine.split(' ')
            require(parts.size == 3 && parts[2] == "HTTP/1.1") { "Invalid HTTP request line" }
            require(parts[0] in setOf("GET", "HEAD")) { "Unsupported HTTP method" }
            require(parts[1].startsWith('/') && parts[1].length <= 2048) { "Invalid HTTP path" }
            val headers = linkedMapOf<String, String>()
            repeat(64) {
                val line = input.readHttpLine(8 * 1024)
                if (line.isEmpty()) return HttpRequest(parts[0], parts[1].substringBefore('?'), headers)
                val separator = line.indexOf(':')
                require(separator > 0) { "Malformed HTTP header" }
                val name = line.substring(0, separator).trim().lowercase(Locale.US)
                require(name.matches(Regex("[a-z0-9-]{1,64}")) && name !in headers) { "Invalid or duplicate header" }
                headers[name] = line.substring(separator + 1).trim()
            }
            throw IllegalArgumentException("Too many HTTP headers")
        }
    }
}

private class WebSocketConnection(
    private val socket: Socket,
    private val input: InputStream,
    private val output: BufferedOutputStream,
) : ControlServerConnection {
    private val open = AtomicBoolean(true)
    private val writeLock = Any()

    fun readLoop(onMessage: (ControlEnvelope) -> Unit) {
        var identified = false
        while (open.get()) {
            val first = input.read()
            if (first < 0) break
            val second = input.read()
            if (second < 0) throw EOFException()
            if ((first and 0x70) != 0 || (first and 0x80) == 0) throw IllegalArgumentException("Fragmented/RSV WebSocket frame")
            val opcode = first and 0x0f
            if ((second and 0x80) == 0) throw IllegalArgumentException("Client WebSocket frame is not masked")
            val length = when (val shortLength = second and 0x7f) {
                126 -> input.readU16().toLong()
                127 -> input.readU64()
                else -> shortLength.toLong()
            }
            if (length > MAX_CONTROL_MESSAGE_BYTES) throw IllegalArgumentException("WebSocket frame exceeds 64 KiB")
            val mask = input.readExactly(4)
            val payload = input.readExactly(length.toInt()).also { bytes ->
                bytes.indices.forEach { index -> bytes[index] = (bytes[index].toInt() xor mask[index and 3].toInt()).toByte() }
            }
            when (opcode) {
                0x1 -> {
                    val message = ControlMessageCodec.decode(payload)
                    if (!identified) {
                        if (message.type != "session.hello") {
                            throw IllegalArgumentException("First WebSocket message must identify a new session")
                        }
                        identified = true
                        socket.soTimeout = 0
                    }
                    onMessage(message)
                }
                0x8 -> {
                    sendFrame(0x8, payload.take(125).toByteArray())
                    break
                }
                0x9 -> sendFrame(0xA, payload)
                0xA -> Unit
                else -> throw IllegalArgumentException("Unsupported WebSocket opcode")
            }
        }
        close()
    }

    override fun send(message: ControlEnvelope): Boolean =
        if (!open.get()) false else runCatching { sendFrame(0x1, ControlMessageCodec.encode(message)); true }.getOrDefault(false)

    private fun sendFrame(opcode: Int, payload: ByteArray) = synchronized(writeLock) {
        if (!open.get()) return@synchronized
        output.write(0x80 or opcode)
        when {
            payload.size < 126 -> output.write(payload.size)
            payload.size <= 0xffff -> {
                output.write(126)
                output.write((payload.size ushr 8) and 0xff)
                output.write(payload.size and 0xff)
            }
            else -> {
                output.write(127)
                output.write(ByteBuffer.allocate(8).putLong(payload.size.toLong()).array())
            }
        }
        output.write(payload)
        output.flush()
    }

    override fun close() {
        if (!open.compareAndSet(true, false)) return
        runCatching { socket.close() }
    }
}

private fun InputStream.readHttpLine(maxBytes: Int): String {
    val buffer = ArrayList<Byte>()
    while (buffer.size <= maxBytes) {
        val value = read()
        if (value < 0) throw EOFException()
        if (value == '\n'.code) {
            if (buffer.lastOrNull() == '\r'.code.toByte()) buffer.removeAt(buffer.lastIndex)
            return buffer.toByteArray().toString(StandardCharsets.US_ASCII)
        }
        buffer += value.toByte()
    }
    throw IllegalArgumentException("HTTP line too long")
}

private fun InputStream.readExactly(count: Int): ByteArray = ByteArray(count).also { bytes ->
    var offset = 0
    while (offset < bytes.size) {
        val read = read(bytes, offset, bytes.size - offset)
        if (read < 0) throw EOFException()
        offset += read
    }
}

private fun InputStream.readU16(): Int {
    val bytes = readExactly(2)
    return ((bytes[0].toInt() and 0xff) shl 8) or (bytes[1].toInt() and 0xff)
}

private fun InputStream.readU64(): Long {
    val value = ByteBuffer.wrap(readExactly(8)).long
    if (value < 0) throw IllegalArgumentException("Invalid WebSocket length")
    return value
}

private fun BufferedOutputStream.writeAscii(text: String) = write(text.toByteArray(StandardCharsets.US_ASCII))

private const val WEB_SOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
