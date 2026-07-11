package dev.remotecam.preview.photo

import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import kotlinx.serialization.Serializable

@Serializable
data class PhotoDescriptor(
    val photoId: String,
    val fileName: String,
    val mimeType: String,
    val byteSize: Long,
    val widthPx: Int,
    val heightPx: Int,
    val sha256: String,
    val downloadPath: String,
) {
    fun validate(maxBytes: Long = 512L * 1024 * 1024) {
        require(photoId.matches(Regex("[A-Za-z0-9_-]{16,128}"))) { "Invalid photoId" }
        require(
            fileName.length in 1..255 && fileName !in setOf(".", "..") &&
                '/' !in fileName && '\\' !in fileName && fileName.none { it.code < 32 || it.code == 127 },
        ) { "Invalid fileName" }
        require(
            mimeType in setOf("image/jpeg", "image/heic", "image/heif", "image/dng", "image/x-adobe-dng"),
        ) { "Unsupported photo MIME type" }
        require(byteSize in 1..maxBytes) { "Invalid photo byte count" }
        require(widthPx in 1..65_535 && heightPx in 1..65_535) { "Invalid photo dimensions" }
        require(sha256.matches(Regex("[0-9a-f]{64}"))) { "Invalid SHA-256" }
        require(downloadPath == "/v1/photos/$photoId") { "Invalid photo download path" }
    }
}

data class IntegrityResult(val bytesCopied: Long, val sha256: String)

object PhotoIntegrity {
    fun verifyAndCopy(
        input: InputStream,
        output: OutputStream,
        expectedBytes: Long,
        expectedSha256: String,
        maxBytes: Long = 512L * 1024 * 1024,
    ): IntegrityResult {
        require(expectedBytes in 1..maxBytes) { "Invalid expected size" }
        require(expectedSha256.matches(Regex("[0-9a-fA-F]{64}"))) { "Invalid expected digest" }
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var copied = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            copied += count
            require(copied <= maxBytes && copied <= expectedBytes) { "Photo exceeds declared or allowed size" }
            digest.update(buffer, 0, count)
            output.write(buffer, 0, count)
        }
        require(copied == expectedBytes) { "Photo length mismatch: expected $expectedBytes, got $copied" }
        val actualBytes = digest.digest()
        val expectedBytesDigest = expectedSha256.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        require(MessageDigest.isEqual(actualBytes, expectedBytesDigest)) { "Photo SHA-256 mismatch" }
        return IntegrityResult(copied, actualBytes.toHex())
    }

    fun digest(input: InputStream, maxBytes: Long = 512L * 1024 * 1024): IntegrityResult {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var bytes = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            bytes += count
            require(bytes <= maxBytes) { "Photo exceeds allowed size" }
            digest.update(buffer, 0, count)
        }
        return IntegrityResult(bytes, digest.digest().toHex())
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
