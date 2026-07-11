package dev.remotecam.preview.camera

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
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
    private var bound = false
    private var binding = false
    private var boundVideoOutput: VideoOutput? = null
    private var requestedVideoOutput: VideoOutput? = null
    private var boundRotation: Int? = null
    private var requestedRotation: Int = android.view.Surface.ROTATION_0

    fun bind(previewView: PreviewView, videoOutput: VideoOutput? = null) {
        val rotation = previewView.display?.rotation ?: android.view.Surface.ROTATION_0
        requestedVideoOutput = videoOutput
        requestedRotation = rotation
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
                val useCases = mutableListOf<UseCase>(preview, capture)
                targetOutput?.let { output ->
                    val builder = VideoCapture.Builder(output).setTargetRotation(targetRotation)
                    if (output is HevcVideoOutput) {
                        builder.setTargetResolution(Size(output.preferredSize.width, output.preferredSize.height))
                    }
                    useCases += builder.build()
                }
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    lifecycleOwner,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    *useCases.toTypedArray(),
                )
                provider = cameraProvider
                imageCapture = capture
                bound = true
                boundVideoOutput = targetOutput
                boundRotation = targetRotation
                binding = false
                listener.onCameraReady()
                if (requestedVideoOutput !== targetOutput || requestedRotation != targetRotation) {
                    bind(previewView, requestedVideoOutput)
                }
            } catch (error: Throwable) {
                binding = false
                listener.onCameraError(error)
            }
        }, callbackExecutor)
    }

    fun takePhoto() {
        val capture = imageCapture ?: return listener.onCameraError(IllegalStateException("Camera is not ready"))
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
                output.savedUri?.let(listener::onPhotoSaved)
                    ?: listener.onCameraError(IllegalStateException("MediaStore did not return the photo URI"))
            }

            override fun onError(exception: ImageCaptureException) = listener.onCameraError(exception)
        })
    }

    override fun close() {
        provider?.unbindAll()
        provider = null
        imageCapture = null
        bound = false
        binding = false
        boundVideoOutput = null
        requestedVideoOutput = null
        boundRotation = null
        requestedRotation = android.view.Surface.ROTATION_0
    }
}
