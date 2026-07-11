package dev.remotecam.preview.photo

import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class StagedPhoto(val file: File, val descriptor: PhotoDescriptor)
data class ReceivedPhoto(val file: File, val descriptor: PhotoDescriptor)

class PhotoStager(private val context: Context) {
    suspend fun stage(uri: Uri): StagedPhoto = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val details = resolver.query(
            uri,
            arrayOf(MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) null else {
                cursor.getString(0) to (cursor.getString(1) ?: "image/jpeg")
            }
        } ?: ("IMG_${System.currentTimeMillis()}.jpg" to "image/jpeg")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unable to read captured photo dimensions" }

        val directory = File(context.cacheDir, "outgoing-photos").apply { mkdirs() }
        val file = File.createTempFile("photo-", ".bin", directory)
        val digest = MessageDigest.getInstance("SHA-256")
        var bytes = 0L
        try {
            resolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Unable to open captured photo" }
                file.outputStream().buffered().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        bytes += count
                        require(bytes <= 512L * 1024 * 1024) { "Captured photo exceeds transfer limit" }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            }
            val photoId = "photo_${UUID.randomUUID().toString().replace("-", "")}"
            StagedPhoto(
                file,
                PhotoDescriptor(
                    photoId = photoId,
                    fileName = details.first.substringAfterLast('/').substringAfterLast('\\'),
                    mimeType = details.second,
                    byteSize = bytes,
                    widthPx = bounds.outWidth,
                    heightPx = bounds.outHeight,
                    sha256 = digest.digest().joinToString("") { "%02x".format(it) },
                    downloadPath = "/v1/photos/$photoId",
                ).also { it.validate() },
            )
        } catch (error: Throwable) {
            file.delete()
            throw error
        }
    }
}

class PhotoResourceRegistry(
    private val lifetimeMillis: Long = 120_000,
    private val maxEntries: Int = 4,
    private val now: () -> Long = System::currentTimeMillis,
) : AutoCloseable {
    private data class Entry(val photo: StagedPhoto, val expiresAt: Long)
    private val entries = ConcurrentHashMap<String, Entry>()

    fun publish(photo: StagedPhoto): PhotoDescriptor {
        reap()
        if (entries.size >= maxEntries) {
            val oldest = entries.entries.minByOrNull { it.value.expiresAt }
            oldest?.let { entries.remove(it.key)?.photo?.file?.delete() }
        }
        entries[photo.descriptor.photoId] = Entry(photo, now() + lifetimeMillis)
        return photo.descriptor
    }

    fun open(photoId: String): Pair<PhotoDescriptor, InputStream>? {
        reap()
        val photo = entries[photoId]?.photo ?: return null
        return photo.descriptor to FileInputStream(photo.file)
    }

    fun acknowledge(photoId: String) {
        entries.remove(photoId)?.photo?.file?.delete()
    }

    private fun reap() {
        val current = now()
        entries.entries.filter { it.value.expiresAt <= current }.forEach {
            entries.remove(it.key)?.photo?.file?.delete()
        }
    }

    override fun close() {
        entries.values.forEach { it.photo.file.delete() }
        entries.clear()
    }
}

class PhotoReceiver(private val context: Context) {
    private val incomingDirectory = File(context.cacheDir, "incoming-photos").apply {
        mkdirs()
        listFiles()?.forEach(File::delete)
    }

    /** Verifies into a private cache file. Nothing reaches MediaStore until the user saves it. */
    suspend fun receive(input: InputStream, descriptor: PhotoDescriptor): ReceivedPhoto = withContext(Dispatchers.IO) {
        descriptor.validate()
        val suffix = when (descriptor.mimeType) {
            "image/png" -> ".png"
            "image/webp" -> ".webp"
            else -> ".jpg"
        }
        val temp = File.createTempFile("incoming-photo-", suffix, incomingDirectory)
        try {
            temp.outputStream().buffered().use { output ->
                PhotoIntegrity.verifyAndCopy(input, output, descriptor.byteSize, descriptor.sha256)
            }
            ReceivedPhoto(temp, descriptor)
        } catch (error: Throwable) {
            temp.delete()
            throw error
        }
    }

    /** Copies an already verified private photo into the public system photo library. */
    suspend fun saveToGallery(photo: ReceivedPhoto): Uri = withContext(Dispatchers.IO) {
        require(photo.file.isFile) { "Received photo cache is unavailable" }
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, photo.descriptor.fileName)
                put(MediaStore.Images.Media.MIME_TYPE, photo.descriptor.mimeType)
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Remote Cam Preview")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)) {
                "Unable to create MediaStore photo"
            }
            try {
                resolver.openOutputStream(uri, "w").use { output ->
                    requireNotNull(output) { "Unable to open MediaStore destination" }
                    photo.file.inputStream().buffered().use { it.copyTo(output, 64 * 1024) }
                }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
                uri
            } catch (error: Throwable) {
                resolver.delete(uri, null, null)
                throw error
            }
    }

    fun delete(photo: ReceivedPhoto) {
        photo.file.delete()
    }
}
