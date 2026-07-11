package dev.remotecam.preview.model

import kotlinx.serialization.Serializable

@Serializable
enum class DeviceRole {
    CAMERA,
    MONITOR,
}

@Serializable
enum class DisplayOrientation {
    PORTRAIT,
    LANDSCAPE,
    PORTRAIT_UPSIDE_DOWN,
    LANDSCAPE_REVERSED,
}

@Serializable
data class PixelSize(
    val width: Int,
    val height: Int,
) {
    init {
        require(width > 0 && height > 0) { "Pixel dimensions must be positive" }
    }

    val pixels: Long get() = width.toLong() * height
    val aspectRatio: Double get() = width.toDouble() / height

    fun rotated(): PixelSize = PixelSize(height, width)
}

@Serializable
data class HevcCapability(
    val supported: Boolean,
    val maxSize: PixelSize?,
    val maxFps: Int,
    val profiles: Set<String> = emptySet(),
)

@Serializable
data class DisplayCapability(
    val nativePixels: PixelSize,
    val viewport: PixelSize,
    val orientation: DisplayOrientation,
    val hevcDecoder: HevcCapability,
)

@Serializable
data class CameraStreamCapability(
    val captureSizes: List<PixelSize>,
    val hevcEncoder: HevcCapability,
)

@Serializable
data class StreamProfile(
    val size: PixelSize,
    val sampleAspectRatio: PixelSize = PixelSize(1, 1),
    val frameRate: Int = 30,
    val bitRate: Int = 10_000_000,
    val profile: String = "Main",
    val level: String? = null,
    val rotationDegrees: Int = 0,
)

data class DeviceCapabilityReport(
    val awareHardware: Boolean,
    val awareAvailable: Boolean,
    val awarePairing: Boolean,
    val publishSlots: Int?,
    val subscribeSlots: Int?,
    val dataPathSlots: Int?,
    val cameraAvailable: Boolean,
    val hevcEncoder: HevcCapability,
    val hevcDecoder: HevcCapability,
    val missingPermissions: Set<String>,
) {
    val canDiscover: Boolean
        get() = awareHardware && awareAvailable && missingPermissions.none { it.contains("WIFI") || it.contains("LOCATION") }
}

data class DiscoveredPeer(
    val id: String,
    val role: DeviceRole?,
    val alias: String?,
    val pairingVerified: Boolean,
)
