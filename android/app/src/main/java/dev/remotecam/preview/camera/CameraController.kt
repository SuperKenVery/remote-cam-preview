package dev.remotecam.preview.camera

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoOutput
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import dev.remotecam.preview.media.HevcVideoOutput
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executor

private const val DEBUG_ENCODER_ONLY = true

interface CameraControllerListener {
    fun onCameraReady() = Unit
    fun onPhotoSaved(uri: Uri)
    fun onCameraError(error: Throwable)
}

class CameraController(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val listener: CameraControllerListener,
    private val callbackExecutor: Executor = ContextCompat.getMainExecutor(context),
) : AutoCloseable {
    private val providerFuture = ProcessCameraProvider.getInstance(context)
    private var provider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var previewView: PreviewView? = null
    private var bound = false
    private var binding = false
    private var photoMode = false
    private var pendingPhoto = false
    private var takingPhoto = false
    private var boundVideoOutput: VideoOutput? = null
    private var requestedVideoOutput: VideoOutput? = null
    private var boundRotation: Int? = null
    private var requestedRotation: Int = android.view.Surface.ROTATION_0

    fun bind(previewView: PreviewView, videoOutput: VideoOutput? = null) {
        val rotation = previewView.display?.rotation ?: android.view.Surface.ROTATION_0
        this.previewView = previewView
        requestedVideoOutput = videoOutput
        requestedRotation = rotation
        bindCurrentPipeline()
    }

    private fun bindCurrentPipeline() {
        val previewView = previewView ?: return
        val videoOutput = if (photoMode) null else requestedVideoOutput
        val rotation = requestedRotation
        Log.i(
            "RemoteCamCamera",
            "bind requested video=${videoOutput != null} photoMode=$photoMode " +
                "boundVideo=${boundVideoOutput != null} bound=$bound binding=$binding rotation=$rotation",
        )
        if ((bound || binding) && boundVideoOutput === videoOutput && boundRotation == rotation) return
        if (binding) return
        binding = true
        val targetOutput = videoOutput
        val targetRotation = rotation
        providerFuture.addListener({
            try {
                val cameraProvider = providerFuture.get()
                val preview = Preview.Builder().setTargetRotation(targetRotation).build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val capture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                    .setTargetRotation(targetRotation)
                    .build()
                val useCases = mutableListOf<UseCase>(preview)
                if (!DEBUG_ENCODER_ONLY || targetOutput == null) useCases += capture
                targetOutput?.let { output ->
                    val builder = VideoCapture.Builder(output).setTargetRotation(targetRotation)
                    if (output is HevcVideoOutput) {
                        builder.setResolutionSelector(
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        Size(output.preferredSize.width, output.preferredSize.height),
                                        ResolutionStrategy.FALLBACK_RULE_NONE,
                                    ),
                                )
                                .build(),
                        )
                    }
                    useCases += builder.build()
                }
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    lifecycleOwner,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    *useCases.toTypedArray(),
                )
                Log.i("RemoteCamCamera", "bind completed video=${targetOutput != null} useCases=${useCases.map { it.javaClass.simpleName }}")
                provider = cameraProvider
                // Never retain an ImageCapture which was not included in bindToLifecycle.
                imageCapture = if (capture in useCases) capture else null
                bound = true
                boundVideoOutput = targetOutput
                boundRotation = targetRotation
                binding = false
                listener.onCameraReady()
                if (photoMode && pendingPhoto && imageCapture != null) {
                    pendingPhoto = false
                    capturePhoto(imageCapture!!)
                } else {
                    val nextOutput = if (photoMode) null else requestedVideoOutput
                    if (nextOutput !== targetOutput || requestedRotation != targetRotation) {
                        Log.i("RemoteCamCamera", "rebinding for changed video/rotation/mode")
                        bindCurrentPipeline()
                    }
                }
            } catch (error: Throwable) {
                Log.e("RemoteCamCamera", "camera bind failed", error)
                binding = false
                val shouldRestoreVideo = photoMode
                photoMode = false
                pendingPhoto = false
                takingPhoto = false
                listener.onCameraError(error)
                if (shouldRestoreVideo) bindCurrentPipeline()
            }
        }, callbackExecutor)
    }

    fun takePhoto() {
        if (takingPhoto || pendingPhoto) return
        imageCapture?.let {
            takingPhoto = true
            capturePhoto(it)
            return
        }
        if (previewView == null || (!bound && !binding)) {
            listener.onCameraError(IllegalStateException("Camera is not ready"))
            return
        }
        Log.i("RemoteCamCamera", "switching VideoCapture -> ImageCapture for still photo")
        photoMode = true
        pendingPhoto = true
        bindCurrentPipeline()
    }

    private fun capturePhoto(capture: ImageCapture) {
        takingPhoto = true
        val displayName = "IMG_${SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())}"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Remote Cam Preview")
        }
        val options = ImageCapture.OutputFileOptions.Builder(
            context.contentResolver,
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            values,
        ).build()
        capture.takePicture(options, callbackExecutor, object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                val uri = output.savedUri
                restoreVideoPipeline()
                uri?.let(listener::onPhotoSaved)
                    ?: listener.onCameraError(IllegalStateException("MediaStore did not return the photo URI"))
            }

            override fun onError(exception: ImageCaptureException) {
                restoreVideoPipeline()
                listener.onCameraError(exception)
            }
        })
    }

    private fun restoreVideoPipeline() {
        takingPhoto = false
        pendingPhoto = false
        if (!photoMode) return
        Log.i("RemoteCamCamera", "still photo finished; restoring VideoCapture")
        photoMode = false
        bindCurrentPipeline()
    }

    override fun close() {
        provider?.unbindAll()
        provider = null
        imageCapture = null
        previewView = null
        bound = false
        binding = false
        photoMode = false
        pendingPhoto = false
        takingPhoto = false
        boundVideoOutput = null
        requestedVideoOutput = null
        boundRotation = null
        requestedRotation = android.view.Surface.ROTATION_0
    }
}
