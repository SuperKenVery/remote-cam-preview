package dev.remotecam.preview.protocol

import dev.remotecam.preview.photo.PhotoDescriptor
import java.time.Clock
import java.util.LinkedHashMap
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

const val PROTOCOL_VERSION = "1.0"
const val MAX_CONTROL_MESSAGE_BYTES = 64 * 1024
const val MAX_JSON_DEPTH = 16
const val MAX_JSON_NODES = 4_096
const val MAX_JSON_OBJECT_MEMBERS = 128
const val MAX_JSON_ARRAY_ITEMS = 256
const val MAX_JSON_STRING_BYTES = 4_096
const val MAX_JSON_KEY_BYTES = 128
const val MAX_JSON_NUMBER_CHARACTERS = 64

@Serializable
data class ControlEnvelope(
    val type: String,
    val requestId: String,
    val protocolVersion: String = PROTOCOL_VERSION,
    val payload: JsonObject = buildJsonObject {},
)

@Serializable
data class ProtocolError(
    val code: String,
    val message: String,
    val retryable: Boolean = false,
)

class ControlProtocolException(
    val code: String,
    message: String,
) : IllegalArgumentException("$code: $message")

object ControlMessageCodec {
    private val requestIdPattern = Regex("[A-Za-z0-9._~-]{1,64}")
    private val versionPattern = Regex("1\\.(0|[1-9][0-9]*)")
    private val anyVersionPattern = Regex("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")
    private val errorCodePattern = Regex("[A-Z][A-Z0-9_]{1,63}")
    private val awareServicePattern = Regex("_[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?\\._tcp")
    private val allowedTypes = setOf(
        "session.hello",
        "session.accepted",
        "preview.start",
        "preview.stop",
        "preview.reconfigure",
        "preview.tierRequest",
        "preview.poseGuide",
        "photo.receivePreference",
        "photo.captured",
        "photo.available",
        "photo.transferResult",
        "heartbeat.ping",
        "heartbeat.pong",
        "keyframe.request",
        "error",
        "session.end",
    )
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
        isLenient = false
        allowSpecialFloatingPointValues = false
    }

    fun encode(message: ControlEnvelope): ByteArray {
        validate(message)
        return json.encodeToString(ControlEnvelope.serializer(), message).encodeToByteArray().also {
            if (it.size > MAX_CONTROL_MESSAGE_BYTES) fail("MESSAGE_TOO_LARGE", "control message exceeds 64 KiB")
        }
    }

    fun decode(bytes: ByteArray): ControlEnvelope {
        if (bytes.size > MAX_CONTROL_MESSAGE_BYTES) fail("MESSAGE_TOO_LARGE", "control message exceeds 64 KiB")
        val text = runCatching { bytes.decodeToString(throwOnInvalidSequence = true) }
            .getOrElse { fail("INVALID_JSON", "control message is not valid UTF-8") }
        DuplicateKeyDetector.check(text)
        val root = try {
            json.parseToJsonElement(text) as? JsonObject ?: fail("INVALID_JSON", "control message must be an object")
        } catch (error: ControlProtocolException) {
            throw error
        } catch (_: Exception) {
            fail("INVALID_JSON", "malformed JSON")
        }
        for (field in listOf("type", "requestId", "protocolVersion", "payload")) {
            if (field !in root) fail("MISSING_FIELD", "missing $field")
        }
        if (root["payload"] !is JsonObject) fail("INVALID_FIELD", "payload must be an object")
        val message = try {
            json.decodeFromJsonElement(ControlEnvelope.serializer(), root)
        } catch (_: Exception) {
            fail("INVALID_FIELD", "invalid envelope field type")
        }
        validate(message)
        return message
    }

    private fun validate(message: ControlEnvelope) {
        if (message.type !in allowedTypes) fail("UNSUPPORTED_MESSAGE_TYPE", "unsupported message type")
        if (!requestIdPattern.matches(message.requestId)) fail("INVALID_FIELD", "invalid requestId")
        if (!versionPattern.matches(message.protocolVersion)) {
            if (message.protocolVersion.substringBefore('.').toIntOrNull() != 1) {
                fail("UNSUPPORTED_PROTOCOL_VERSION", "unsupported protocol major")
            }
            fail("INVALID_FIELD", "invalid protocolVersion")
        }
        validatePayload(message.type, message.payload)
    }

    private fun validatePayload(type: String, payload: JsonObject) {
        when (type) {
            "session.hello" -> {
                payload.string("role").requireValue("monitor")
                payload.token("sessionId")
                payload.array("supportedProtocolVersions", 1..8).map { element ->
                    element.strictString("supportedProtocolVersions entry", 1..16).also {
                        if (!anyVersionPattern.matches(it)) fail("INVALID_FIELD", "invalid supported protocol version")
                    }
                }.also { versions ->
                    if (versions.distinct().size != versions.size) {
                        fail("INVALID_FIELD", "duplicate supported protocol version")
                    }
                }
                payload.obj("display").apply {
                    int("nativeWidthPx", 1..16_384)
                    int("nativeHeightPx", 1..16_384)
                    int("viewportWidthPx", 1..16_384)
                    int("viewportHeightPx", 1..16_384)
                    string("orientation").requireOneOf(
                        "portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight",
                    )
                }
                payload.obj("hevc").apply {
                    array("profiles", 1..2).map { it.strictString("HEVC profile", 1..16) }.also { profiles ->
                        if (profiles.any { it !in setOf("main", "main10") } || profiles.distinct().size != profiles.size) {
                            fail("INVALID_FIELD", "invalid HEVC profiles")
                        }
                    }
                    int("maxWidthPx", 16..16_384)
                    int("maxHeightPx", 16..16_384)
                    int("maxFps", 1..240)
                    int("maxLevelIdc", 30..186)
                }
                payload.bool("photoReceiveEnabled")
            }
            "session.accepted" -> {
                payload.string("role").requireValue("capture")
                payload.token("sessionId")
                payload.token("accessToken")
                validatePreview(payload.obj("preview"))
                payload.obj("photoEndpoint").apply {
                    val hasPort = "port" in this
                    val hasServiceName = "serviceName" in this
                    if (hasPort == hasServiceName) fail("INVALID_FIELD", "photoEndpoint needs exactly one endpoint")
                    if (hasPort) int("port", 1..65_535)
                    if (hasServiceName) string("serviceName", 1..22).also {
                        if (!awareServicePattern.matches(it)) fail("INVALID_FIELD", "invalid Wi-Fi Aware service name")
                    }
                }
                payload.obj("rtp").apply {
                    string("destinationAddress", 1..255)
                    int("rtpPort", 1..65_535)
                    int("rtcpPort", 1..65_535)
                    int("payloadType", 96..127)
                    long("ssrc", 1..0xffff_ffffL)
                    int("maxRtpPacketSize", 256..65_507)
                }
            }
            "preview.start" -> payload.id("configId")
            "preview.stop" -> payload.string("reason").requireOneOf(
                "user", "reconfigure", "controlLost", "sessionEnd", "error",
            )
            "preview.reconfigure" -> {
                validatePreview(payload.obj("preview"))
                payload.string("reason").requireOneOf(
                    "orientation", "viewport", "decoderLimit", "linkTier", "manual",
                )
            }
            "preview.tierRequest" -> {
                payload.int("maxBitrateBps", 100_000..200_000_000)
                payload.optionalInt("maxWidthPx", 16..16_384)
                payload.optionalInt("maxHeightPx", 16..16_384)
            }
            "preview.poseGuide" -> payload.int("guideId", 0..5)
            "photo.receivePreference" -> payload.bool("enabled")
            "photo.captured" -> {
                payload.id("captureId")
                payload.bool("savedLocally")
            }
            "photo.available" -> {
                val descriptor = try {
                    json.decodeFromJsonElement(PhotoDescriptor.serializer(), payload.required("metadata"))
                } catch (_: Exception) {
                    fail("INVALID_PHOTO_METADATA", "invalid photo metadata")
                }
                try {
                    descriptor.validate()
                } catch (_: Exception) {
                    fail("INVALID_PHOTO_METADATA", "invalid photo metadata")
                }
                payload.int("expiresInSeconds", 1..3600)
            }
            "photo.transferResult" -> {
                payload.token("photoId")
                val status = payload.string("status").also { it.requireOneOf("saved", "failed", "cancelled") }
                if (status != "saved") payload.string("errorCode").also {
                    if (!Regex("[A-Z][A-Z0-9_]{1,63}").matches(it)) fail("INVALID_FIELD", "invalid errorCode")
                }
            }
            "heartbeat.ping", "heartbeat.pong" -> payload.long("sentAtMs", 0..Long.MAX_VALUE)
            "keyframe.request" -> {
                payload.long("mediaSsrc", 1..0xffff_ffffL)
                payload.string("reason").requireOneOf("startup", "loss", "decoderReset", "reconfigure")
            }
            "error" -> {
                payload.string("code", 2..64).also {
                    if (!errorCodePattern.matches(it)) fail("INVALID_FIELD", "invalid error code")
                }
                payload.string("message", 1..1024)
                payload.bool("retryable")
                if ("relatedRequestId" in payload) payload.id("relatedRequestId")
            }
            "session.end" -> payload.string("reason").requireOneOf("user", "controlLost", "unavailable", "error")
        }
    }

    private fun validatePreview(payload: JsonObject) {
        payload.id("configId")
        payload.int("widthPx", 16..16_384)
        payload.int("heightPx", 16..16_384)
        payload.obj("sampleAspectRatio").apply {
            int("width", 1..65_535)
            int("height", 1..65_535)
        }
        payload.int("fps", 1..240)
        payload.int("bitrateBps", 100_000..200_000_000)
        payload.string("profile").requireOneOf("main", "main10")
        payload.int("levelIdc", 30..186)
        payload.int("rotationDegrees").also { if (it !in setOf(0, 90, 180, 270)) fail("INVALID_FIELD", "rotation") }
        if (payload.int("clockRate") != 90_000) fail("INVALID_FIELD", "clockRate")
        if (!payload.bool("noBFrames")) fail("INVALID_FIELD", "B frames are not allowed")
    }

    private fun fail(code: String, message: String): Nothing = throw ControlProtocolException(code, message)

    private fun JsonObject.required(name: String): JsonElement = this[name] ?: fail("MISSING_FIELD", "missing $name")
    private fun JsonObject.obj(name: String): JsonObject = required(name) as? JsonObject
        ?: fail("INVALID_FIELD", "$name must be an object")
    private fun JsonObject.array(name: String, size: IntRange): JsonArray = (required(name) as? JsonArray
        ?: fail("INVALID_FIELD", "$name must be an array")).also {
        if (it.size !in size) fail("INVALID_FIELD", "$name array size out of range")
    }
    private fun JsonObject.string(name: String, length: IntRange = 1..Int.MAX_VALUE): String =
        required(name).strictString(name, length)
    private fun JsonElement.strictString(name: String, length: IntRange): String =
        (this as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?.also { if (strictUtf8Length(it) !in length) fail("INVALID_FIELD", "$name length out of range") }
            ?: fail("INVALID_FIELD", "$name must be a string")
    private fun JsonObject.int(name: String, range: IntRange = Int.MIN_VALUE..Int.MAX_VALUE): Int =
        (required(name) as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull?.takeIf { it in range }
            ?: fail("INVALID_FIELD", "$name out of range")
    private fun JsonObject.optionalInt(name: String, range: IntRange) {
        if (name in this) int(name, range)
    }
    private fun JsonObject.long(name: String, range: LongRange): Long =
        (required(name) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull?.takeIf { it in range }
            ?: fail("INVALID_FIELD", "$name out of range")
    private fun JsonObject.bool(name: String): Boolean =
        (required(name) as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
            ?: fail("INVALID_FIELD", "$name must be boolean")
    private fun JsonObject.id(name: String): String = string(name).also {
        if (!requestIdPattern.matches(it)) fail("INVALID_FIELD", "invalid $name")
    }
    private fun JsonObject.token(name: String): String = string(name).also {
        if (!Regex("[A-Za-z0-9_-]{16,128}").matches(it)) fail("INVALID_FIELD", "invalid $name")
    }
    private fun String.requireValue(expected: String) {
        if (this != expected) fail("INVALID_FIELD", "expected $expected")
    }
    private fun String.requireOneOf(vararg choices: String) {
        if (this !in choices) fail("INVALID_FIELD", "unexpected enum value")
    }
}

/** Small JSON lexical pass because kotlinx.serialization intentionally keeps the last duplicate key. */
private object DuplicateKeyDetector {
    private val numberPattern = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

    fun check(text: String) {
        try {
            Parser(text).parse()
        } catch (error: ControlProtocolException) {
            throw error
        } catch (_: Exception) {
            throw ControlProtocolException("INVALID_JSON", "malformed JSON")
        }
    }

    private class Parser(private val text: String) {
        private var index = 0
        private var nodes = 0

        fun parse() {
            value(0)
            whitespace()
            if (index != text.length) error("trailing data")
        }

        private fun value(depth: Int) {
            if (depth > MAX_JSON_DEPTH) resource("JSON nesting too deep")
            nodes++
            if (nodes > MAX_JSON_NODES) resource("too many JSON nodes")
            whitespace()
            when (peek()) {
                '{' -> obj(depth + 1)
                '[' -> array(depth + 1)
                '"' -> string()
                null -> error("unexpected end")
                else -> primitive()
            }
        }

        private fun obj(depth: Int) {
            consume('{')
            whitespace()
            if (peek() == '}') return consume('}')
            val keys = hashSetOf<String>()
            var members = 0
            while (true) {
                whitespace()
                val key = string(MAX_JSON_KEY_BYTES)
                members++
                if (members > MAX_JSON_OBJECT_MEMBERS) resource("too many JSON object members")
                if (!keys.add(key)) throw ControlProtocolException("DUPLICATE_JSON_KEY", "duplicate key $key")
                whitespace()
                consume(':')
                value(depth)
                whitespace()
                when (peek()) {
                    ',' -> consume(',')
                    '}' -> return consume('}')
                    else -> error("expected object separator")
                }
            }
        }

        private fun array(depth: Int) {
            consume('[')
            whitespace()
            if (peek() == ']') return consume(']')
            var items = 0
            while (true) {
                items++
                if (items > MAX_JSON_ARRAY_ITEMS) resource("too many JSON array items")
                value(depth)
                whitespace()
                when (peek()) {
                    ',' -> consume(',')
                    ']' -> return consume(']')
                    else -> error("expected array separator")
                }
            }
        }

        private fun string(maxBytes: Int = MAX_JSON_STRING_BYTES): String {
            consume('"')
            val result = StringBuilder()
            while (true) {
                val char = peek() ?: error("unterminated string")
                index++
                when (char) {
                    '"' -> return result.toString().also { value ->
                        if (strictUtf8Length(value) > maxBytes) resource("JSON string is too long")
                    }
                    '\\' -> {
                        val escaped = peek() ?: error("unterminated escape")
                        index++
                        when (escaped) {
                            '"', '\\', '/' -> result.append(escaped)
                            'b' -> result.append('\b')
                            'f' -> result.append('\u000c')
                            'n' -> result.append('\n')
                            'r' -> result.append('\r')
                            't' -> result.append('\t')
                            'u' -> {
                                if (index + 4 > text.length) error("truncated unicode escape")
                                result.append(text.substring(index, index + 4).toInt(16).toChar())
                                index += 4
                            }
                            else -> error("invalid escape")
                        }
                    }
                    else -> {
                        if (char.code < 32) error("control character in string")
                        result.append(char)
                    }
                }
            }
        }

        private fun primitive() {
            val start = index
            while (peek()?.let { it !in setOf(',', '}', ']', ' ', '\t', '\r', '\n') } == true) index++
            if (start == index) error("expected value")
            val token = text.substring(start, index)
            if (token !in setOf("true", "false", "null") && !numberPattern.matches(token)) {
                throw ControlProtocolException("INVALID_JSON", "invalid JSON primitive")
            }
            if (numberPattern.matches(token) && token.length > MAX_JSON_NUMBER_CHARACTERS) {
                resource("JSON number representation is too long")
            }
        }

        private fun whitespace() {
            while (peek() in setOf(' ', '\t', '\r', '\n')) index++
        }

        private fun consume(expected: Char) {
            if (peek() != expected) error("expected $expected")
            index++
        }

        private fun peek(): Char? = text.getOrNull(index)

        private fun resource(message: String): Nothing =
            throw ControlProtocolException("JSON_RESOURCE_LIMIT", message)
    }
}

private fun strictUtf8Length(value: String): Int {
    var index = 0
    while (index < value.length) {
        val char = value[index]
        when {
            char.isHighSurrogate() -> {
                if (index + 1 >= value.length || !value[index + 1].isLowSurrogate()) {
                    throw ControlProtocolException("INVALID_UNICODE", "unpaired high surrogate")
                }
                index += 2
            }
            char.isLowSurrogate() -> throw ControlProtocolException("INVALID_UNICODE", "unpaired low surrogate")
            else -> index++
        }
    }
    return value.encodeToByteArray().size
}

/** Bounded replay cache used to make request handling idempotent. */
class RequestReplayCache(
    private val maxEntries: Int = 1_024,
    private val ttlMillis: Long = 120_000,
    private val clock: Clock = Clock.systemUTC(),
) {
    private data class Entry(val insertedAt: Long, val response: ControlEnvelope)
    private val entries = object : LinkedHashMap<String, Entry>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?): Boolean = size > maxEntries
    }

    @Synchronized
    fun get(requestId: String): ControlEnvelope? {
        purgeExpired()
        return entries[requestId]?.response
    }

    @Synchronized
    fun put(requestId: String, response: ControlEnvelope) {
        purgeExpired()
        entries[requestId] = Entry(clock.millis(), response)
    }

    private fun purgeExpired() {
        val cutoff = clock.millis() - ttlMillis
        entries.entries.removeAll { it.value.insertedAt < cutoff }
    }
}

object ControlTypes {
    const val SESSION_HELLO = "session.hello"
    const val SESSION_ACCEPTED = "session.accepted"
    const val PREVIEW_START = "preview.start"
    const val PREVIEW_STOP = "preview.stop"
    const val PREVIEW_RECONFIGURE = "preview.reconfigure"
    const val PREVIEW_TIER_REQUEST = "preview.tierRequest"
    const val PREVIEW_POSE_GUIDE = "preview.poseGuide"
    const val PHOTO_RECEIVE_PREFERENCE = "photo.receivePreference"
    const val PHOTO_CAPTURED = "photo.captured"
    const val PHOTO_AVAILABLE = "photo.available"
    const val PHOTO_TRANSFER_RESULT = "photo.transferResult"
    const val HEARTBEAT_PING = "heartbeat.ping"
    const val HEARTBEAT_PONG = "heartbeat.pong"
    const val KEYFRAME_REQUEST = "keyframe.request"
    const val ERROR = "error"
    const val SESSION_END = "session.end"
}
