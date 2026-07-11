package dev.remotecam.preview.capability

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.wifi.aware.WifiAwareManager
import android.os.Build
import androidx.core.content.ContextCompat
import dev.remotecam.preview.model.DeviceCapabilityReport
import dev.remotecam.preview.model.CameraStreamCapability
import dev.remotecam.preview.model.HevcCapability
import dev.remotecam.preview.model.PixelSize

class DeviceCapabilityChecker(private val context: Context) {
    fun inspect(): DeviceCapabilityReport {
        val packageManager = context.packageManager
        val awareHardware = packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
        val aware = context.getSystemService(WifiAwareManager::class.java)
        val resources = if (awareHardware) runCatching { aware?.availableAwareResources }.getOrNull() else null
        val characteristics = if (awareHardware) runCatching { aware?.characteristics }.getOrNull() else null
        val permissions = requiredRuntimePermissions().filterTo(mutableSetOf()) {
            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
        }
        return DeviceCapabilityReport(
            awareHardware = awareHardware,
            awareAvailable = awareHardware && aware?.isAvailable == true,
            awarePairing = Build.VERSION.SDK_INT >= 34 && characteristics?.isAwarePairingSupported == true,
            publishSlots = resources?.availablePublishSessionsCount,
            subscribeSlots = resources?.availableSubscribeSessionsCount,
            dataPathSlots = resources?.availableDataPathsCount,
            cameraAvailable = packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY),
            hevcEncoder = codecCapability(encoder = true),
            hevcDecoder = codecCapability(encoder = false),
            missingPermissions = permissions,
        )
    }

    fun requiredRuntimePermissions(): List<String> = buildList {
        add(Manifest.permission.CAMERA)
        if (Build.VERSION.SDK_INT >= 33) {
            add(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    fun cameraStreamCapability(): CameraStreamCapability {
        val manager = context.getSystemService(CameraManager::class.java)
        val cameraId = manager.cameraIdList.firstOrNull { id ->
            manager.getCameraCharacteristics(id)[CameraCharacteristics.LENS_FACING] == CameraCharacteristics.LENS_FACING_BACK
        } ?: manager.cameraIdList.firstOrNull()
        val sizes = cameraId?.let { id ->
            manager.getCameraCharacteristics(id)[CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP]
                ?.getOutputSizes(SurfaceTexture::class.java)
                ?.map { PixelSize(it.width, it.height) }
                ?.distinct()
                ?.filter(::supportsHevcEncoding)
                ?.sortedByDescending { it.pixels }
        }.orEmpty()
        return CameraStreamCapability(sizes, codecCapability(encoder = true))
    }

    private fun supportsHevcEncoding(size: PixelSize): Boolean =
        runCatching {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
                info.isEncoder &&
                    info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) } &&
                    runCatching {
                        info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                            .videoCapabilities
                            ?.areSizeAndRateSupported(size.width, size.height, 30.0) == true
                    }.getOrDefault(false)
            }
        }.getOrDefault(false)

    private fun codecCapability(encoder: Boolean): HevcCapability {
        val codecs = runCatching { MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.asList() }.getOrDefault(emptyList())
        val candidates = codecs.filter { info ->
            info.isEncoder == encoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) }
        }
        if (candidates.isEmpty()) return HevcCapability(false, null, 0)

        var maxWidth = 0
        var maxHeight = 0
        var maxFps = 0
        val profiles = linkedSetOf<String>()
        candidates.forEach { info ->
            runCatching { info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC) }.getOrNull()?.let { capabilities ->
                capabilities.videoCapabilities?.let { video ->
                    maxWidth = maxOf(maxWidth, video.supportedWidths.upper)
                    maxHeight = maxOf(maxHeight, video.supportedHeights.upper)
                    maxFps = maxOf(maxFps, video.supportedFrameRates.upper.toInt())
                }
                capabilities.profileLevels.forEach { profile ->
                    profiles += when (profile.profile) {
                        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain -> "Main"
                        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 -> "Main10"
                        else -> "profile-${profile.profile}"
                    }
                }
            }
        }
        return HevcCapability(
            supported = true,
            maxSize = PixelSize(maxWidth.coerceAtLeast(1), maxHeight.coerceAtLeast(1)),
            maxFps = maxFps.coerceAtLeast(1),
            profiles = profiles,
        )
    }
}
