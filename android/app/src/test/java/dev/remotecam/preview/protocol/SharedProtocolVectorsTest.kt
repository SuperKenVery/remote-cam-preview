package dev.remotecam.preview.protocol

import dev.remotecam.preview.photo.PhotoDescriptor
import dev.remotecam.preview.photo.PhotoIntegrity
import dev.remotecam.preview.session.InvalidSessionTransition
import dev.remotecam.preview.session.SessionState
import dev.remotecam.preview.session.SessionStateMachine
import dev.remotecam.preview.session.UnknownSessionEvent
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedProtocolVectorsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `all shared control message vectors match`() {
        val root = resourceJson("control-messages.json")
        root["valid"]!!.jsonArray.forEach { vector ->
            val message = vector.jsonObject["message"]!!.toString().encodeToByteArray()
            val decoded = ControlMessageCodec.decode(message)
            assertArrayEquals(messageType(vector).encodeToByteArray(), decoded.type.encodeToByteArray())
            assertEquals(decoded, ControlMessageCodec.decode(ControlMessageCodec.encode(decoded)))
        }
        root["invalid"]!!.jsonArray.forEach { vectorElement ->
            val vector = vectorElement.jsonObject
            val wire = vector["wireText"]?.jsonPrimitive?.content
                ?: vector["message"]!!.toString()
            val expected = vector["expectedError"]!!.jsonPrimitive.content
            val error = runCatching { ControlMessageCodec.decode(wire.encodeToByteArray()) }.exceptionOrNull()
            assertTrue("${vector["name"]}: expected $expected, got $error", error is ControlProtocolException)
            assertEquals(vector["name"]!!.jsonPrimitive.content, expected, (error as ControlProtocolException).code)
        }
    }

    @Test
    fun `all shared HEVC RTP vectors packetize and depacketize`() {
        val root = resourceJson("hevc-rtp.json")
        root["valid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val config = vector["config"]!!.jsonObject
            val packetizer = HevcRtpPacketizer(
                payloadType = config.int("payloadType"),
                ssrc = config.long("ssrc"),
                initialSequence = config.int("initialSequence"),
                maxRtpPacketSize = config.int("maxRtpPacketSize"),
                aggregate = config["aggregate"]!!.jsonPrimitive.boolean,
            )
            val nals = vector["nalUnitsHex"]!!.jsonArray.map { it.jsonPrimitive.content.hexBytes() }
            val packets = packetizer.packetize(nals, config.long("timestamp"))
            assertEquals(
                vector["name"]!!.jsonPrimitive.content,
                vector["packetsHex"]!!.jsonArray.map { it.jsonPrimitive.content },
                packets.map { it.encode().hex() },
            )
            val arrivalOrder = vector["arrivalOrder"]!!.jsonArray.map { it.jsonPrimitive.int }
            val received = arrivalOrder.map { packets[it] }
            val reconstructed = HevcRtpDepacketizer.depacketize(received, config.int("payloadType"))
            assertEquals(nals.map { it.hex() }, reconstructed.map { it.hex() })
        }

        root["invalid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val packets = vector["packetsHex"]!!.jsonArray.map {
                RtpPacket.decode(it.jsonPrimitive.content.hexBytes(), vector.int("maxRtpPacketSize"))
            }
            val error = runCatching { HevcRtpDepacketizer.depacketize(packets) }.exceptionOrNull()
            assertTrue("${vector["name"]}: $error", error is HevcRtpException)
            assertEquals(vector["expectedError"]!!.jsonPrimitive.content, (error as HevcRtpException).code)
        }
    }

    @Test
    fun `all shared RTCP vectors match byte for byte`() {
        val root = resourceJson("rtcp.json")
        root["validReceiverReports"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val block = vector["blocks"]!!.jsonArray.single().jsonObject
            val encoded = Rtcp.receiverReport(
                vector.long("senderSsrc"),
                block.long("sourceSsrc"),
                block.int("fractionLost"),
                block.int("cumulativeLost"),
                block.long("extendedHighestSequence"),
                block.long("interarrivalJitter"),
                block.long("lastSenderReport"),
                block.long("delaySinceLastSenderReport"),
            )
            assertEquals(vector["packetHex"]!!.jsonPrimitive.content, encoded.hex())
            val parsed = Rtcp.parseDatagram(encoded).single() as Rtcp.ParsedPacket.ReceiverReport
            assertEquals(vector.long("senderSsrc"), parsed.senderSsrc)
            assertEquals(block.int("cumulativeLost"), parsed.blocks.single().cumulativeLost)
        }
        root["validPli"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val encoded = Rtcp.pictureLossIndication(vector.long("senderSsrc"), vector.long("mediaSsrc"))
            assertEquals(vector["packetHex"]!!.jsonPrimitive.content, encoded.hex())
            val parsed = Rtcp.parseDatagram(encoded, vector.long("mediaSsrc")).single()
            assertTrue(parsed is Rtcp.ParsedPacket.PictureLossIndication)
        }
        root["validDatagrams"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            assertEquals(vector["packetKinds"]!!.jsonArray.size, Rtcp.parseDatagram(vector["datagramHex"]!!.jsonPrimitive.content.hexBytes()).size)
        }
        root["invalid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val expectedMedia = vector["expectedMediaSsrc"]?.jsonPrimitive?.long
            val error = runCatching {
                Rtcp.parseDatagram(vector["packetHex"]!!.jsonPrimitive.content.hexBytes(), expectedMedia)
            }.exceptionOrNull()
            assertTrue("${vector["name"]}: $error", error is HevcRtpException)
            assertEquals(vector["expectedError"]!!.jsonPrimitive.content, (error as HevcRtpException).code)
        }
    }

    @Test
    fun `all shared photo metadata and integrity vectors match`() {
        val root = resourceJson("photo-integrity.json")
        root["validMetadata"]!!.jsonArray.forEach { element ->
            val descriptor = json.decodeFromJsonElement(
                PhotoDescriptor.serializer(),
                element.jsonObject["metadata"]!!,
            )
            descriptor.validate()
        }
        root["invalidMetadata"]!!.jsonArray.forEach { element ->
            val error = runCatching {
                json.decodeFromJsonElement(PhotoDescriptor.serializer(), element.jsonObject["metadata"]!!).validate()
            }.exceptionOrNull()
            assertTrue("${element.jsonObject["name"]}: expected invalid metadata", error is IllegalArgumentException)
        }
        root["integrity"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val bytes = vector["contentHex"]!!.jsonPrimitive.content.hexBytes()
            val output = ByteArrayOutputStream()
            val result = runCatching {
                PhotoIntegrity.verifyAndCopy(
                    ByteArrayInputStream(bytes),
                    output,
                    vector.long("expectedSize"),
                    vector["expectedSha256"]!!.jsonPrimitive.content,
                )
            }
            if (vector["valid"]!!.jsonPrimitive.boolean) {
                assertTrue(result.isSuccess)
                assertArrayEquals(bytes, output.toByteArray())
            } else {
                assertTrue(result.isFailure)
            }
        }
    }

    @Test
    fun `all shared state machine vectors match`() {
        val root = resourceJson("session-state.json")
        root["valid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val machine = SessionStateMachine(SessionState.fromWireName(vector["initial"]!!.jsonPrimitive.content))
            val actual = vector["events"]!!.jsonArray.map { machine.apply(it.jsonPrimitive.content).wireName }
            val expected = vector["expectedStates"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(vector["name"]!!.jsonPrimitive.content, expected, actual)
        }
        root["invalid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val initial = SessionState.fromWireName(vector["initial"]!!.jsonPrimitive.content)
            val machine = SessionStateMachine(initial)
            val event = vector["events"]!!.jsonArray.first().jsonPrimitive.content
            val error = runCatching { machine.apply(event) }.exceptionOrNull()
            assertTrue(error is InvalidSessionTransition || error is UnknownSessionEvent)
            assertEquals(vector["expectedFinalState"]!!.jsonPrimitive.content, machine.state.wireName)
        }
    }

    private fun resourceJson(name: String): JsonObject =
        javaClass.classLoader!!.getResourceAsStream(name).use { input ->
            requireNotNull(input) { "Missing shared protocol vector $name" }
            json.parseToJsonElement(input.reader().readText()).jsonObject
        }

    private fun messageType(vector: kotlinx.serialization.json.JsonElement): String =
        vector.jsonObject["message"]!!.jsonObject["type"]!!.jsonPrimitive.content

    private fun JsonObject.int(name: String) = this[name]!!.jsonPrimitive.int
    private fun JsonObject.long(name: String) = this[name]!!.jsonPrimitive.long
    private fun String.hexBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
}
