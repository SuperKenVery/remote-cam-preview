package dev.remotecam.preview

import android.os.Bundle
import android.graphics.SurfaceTexture
import android.view.TextureView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.viewinterop.AndroidView
import dev.remotecam.preview.camera.CameraController
import dev.remotecam.preview.camera.CameraControllerListener
import dev.remotecam.preview.model.DeviceRole
import dev.remotecam.preview.session.SessionState

class MainActivity : ComponentActivity() {
    private val viewModel: RemoteCamViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                RemoteCamApp(viewModel)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshCapabilities()
    }
}

@Composable
private fun RemoteCamApp(viewModel: RemoteCamViewModel) {
    val state by viewModel.uiState.collectAsState()
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.onPermissionsResult()
    }
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Remote Cam Preview", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            CapabilityCard(state)

            if (state.sessionState != SessionState.ENDED) {
                RolePicker(state.role, viewModel::selectRole)
            }

            if (state.role != null) {
                OutlinedTextField(
                    value = state.sessionPassphrase,
                    onValueChange = viewModel::setSessionPassphrase,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("本次会话临时 NDP 口令") },
                    supportingText = { Text("两台 Android 手动输入相同的 8–63 字符口令；不会保存") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    isError = state.sessionPassphrase.isNotEmpty() && state.sessionPassphrase.length < 8,
                )
                val missing = state.capabilities.missingPermissions.intersect(viewModel.requiredPermissions().toSet())
                if (missing.isNotEmpty()) {
                    Button(onClick = { permissionLauncher.launch(viewModel.requiredPermissions()) }, modifier = Modifier.fillMaxWidth()) {
                        Text("授予必要权限")
                    }
                } else if (state.sessionState in setOf(SessionState.UNPAIRED, SessionState.UNAVAILABLE)) {
                    Button(
                        onClick = viewModel::startDiscovery,
                        enabled = state.capabilities.awareHardware && state.capabilities.awareAvailable,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("开始查找设备") }
                }
            }

            StatusCard(state.status, state.sessionState)

            if (state.sessionState in setOf(SessionState.DISCOVERING, SessionState.PAIRING)) {
                PeerList(state, viewModel::confirmPeer)
            }

            when (state.role) {
                DeviceRole.CAMERA -> CameraPane(viewModel, state.lastPhotoStatus, state.cameraVideoOutput)
                DeviceRole.MONITOR -> MonitorPane(
                    state.receivePhotos,
                    state.receivedFrames,
                    state.negotiatedProfile,
                    viewModel::setReceivePhotos,
                    viewModel::updateMonitorViewport,
                    viewModel::setMonitorSurface,
                )
                null -> Unit
            }

            if (state.sessionState == SessionState.INTERRUPTED) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = viewModel::retry, modifier = Modifier.weight(1f)) { Text("重试") }
                    OutlinedButton(onClick = viewModel::endSession, modifier = Modifier.weight(1f)) { Text("结束") }
                }
            } else if (state.sessionState !in setOf(SessionState.UNPAIRED, SessionState.UNAVAILABLE, SessionState.ENDED)) {
                OutlinedButton(onClick = viewModel::endSession, modifier = Modifier.fillMaxWidth()) { Text("结束会话") }
            }
        }
    }
}

@Composable
private fun CapabilityCard(state: RemoteCamUiState) {
    val capability = state.capabilities
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("设备能力", fontWeight = FontWeight.SemiBold)
            CapabilityLine("Wi‑Fi Aware 硬件", capability.awareHardware)
            CapabilityLine("Wi‑Fi Aware 当前可用", capability.awareAvailable)
            CapabilityLine("Aware Pairing（API 34+）", capability.awarePairing)
            CapabilityLine("HEVC 编码 / 解码", capability.hevcEncoder.supported && capability.hevcDecoder.supported)
        }
    }
}

@Composable
private fun CapabilityLine(label: String, available: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(8.dp).background(if (available) Color(0xff50d890) else Color(0xffff6b6b), CircleShape))
        Text("$label：${if (available) "可用" else "不可用"}", style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun RolePicker(selected: DeviceRole?, select: (DeviceRole) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RoleButton("拍摄端 A", DeviceRole.CAMERA, selected, select, Modifier.weight(1f))
        RoleButton("监看端 B", DeviceRole.MONITOR, selected, select, Modifier.weight(1f))
    }
}

@Composable
private fun RoleButton(
    label: String,
    role: DeviceRole,
    selected: DeviceRole?,
    select: (DeviceRole) -> Unit,
    modifier: Modifier,
) {
    if (selected == role) {
        Button(onClick = { select(role) }, modifier = modifier) { Text(label) }
    } else {
        OutlinedButton(onClick = { select(role) }, modifier = modifier) { Text(label) }
    }
}

@Composable
private fun StatusCard(status: String, sessionState: SessionState) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                sessionState.wireName,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
                fontWeight = FontWeight.SemiBold,
            )
            Text(status, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun PeerList(state: RemoteCamUiState, confirm: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        state.peers.forEach { peer ->
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
                Row(
                    Modifier.fillMaxWidth().padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(peer.alias ?: peer.id.take(16), fontWeight = FontWeight.Medium)
                        Text(peer.role?.name ?: "未知角色", style = MaterialTheme.typography.bodySmall)
                    }
                    Button(onClick = { confirm(peer.id) }, enabled = !peer.pairingVerified) {
                        Text(if (peer.pairingVerified) "已验证" else "选择并确认")
                    }
                }
            }
        }
    }
}

@Composable
private fun CameraPane(
    viewModel: RemoteCamViewModel,
    photoStatus: String?,
    videoOutput: dev.remotecam.preview.media.HevcVideoOutput?,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var ready by remember { mutableStateOf(false) }
    val controller = remember {
        CameraController(context, lifecycleOwner, object : CameraControllerListener {
            override fun onCameraReady() { ready = true }
            override fun onPhotoSaved(uri: android.net.Uri) = viewModel.onPhotoSaved(uri)
            override fun onCameraError(error: Throwable) = viewModel.onCameraError(error)
        })
    }
    DisposableEffect(controller) { onDispose(controller::close) }
    Card(shape = RoundedCornerShape(18.dp)) {
        Column {
            AndroidView(
                factory = { PreviewView(it).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } },
                modifier = Modifier.fillMaxWidth().height(420.dp),
                update = { controller.bind(it, videoOutput) },
            )
            Button(
                onClick = controller::takePhoto,
                enabled = ready,
                modifier = Modifier.fillMaxWidth().padding(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black),
            ) { Text("拍照（静态 ImageCapture）") }
            photoStatus?.let { Text(it, Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) }
        }
    }
}

@Composable
private fun MonitorPane(
    receivePhotos: Boolean,
    receivedFrames: Long,
    profile: dev.remotecam.preview.model.StreamProfile?,
    setReceivePhotos: (Boolean) -> Unit,
    updateViewport: (Int, Int) -> Unit,
    setSurface: (android.view.Surface?) -> Unit,
) {
    Card(shape = RoundedCornerShape(18.dp)) {
        Column {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(420.dp)
                    .background(Color.Black)
                    .clipToBounds()
                    .onSizeChanged { updateViewport(it.width, it.height) },
                contentAlignment = Alignment.Center,
            ) {
                AndroidView(
                    factory = { context ->
                        TextureView(context).apply {
                            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                                private var outputSurface: android.view.Surface? = null
                                override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
                                    outputSurface = android.view.Surface(texture).also(setSurface)
                                }
                                override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) = Unit
                                override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                                    setSurface(null)
                                    outputSurface?.release()
                                    outputSurface = null
                                    return true
                                }
                                override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                            }
                        }
                    },
                    update = { texture ->
                        profile?.let { configured ->
                            texture.surfaceTexture?.setDefaultBufferSize(configured.size.width, configured.size.height)
                            val rotated = configured.rotationDegrees % 180 != 0
                            val sourceWidth = if (rotated) configured.size.height.toFloat() else configured.size.width.toFloat()
                            val sourceHeight = if (rotated) configured.size.width.toFloat() else configured.size.height.toFloat()
                            if (texture.width > 0 && texture.height > 0) {
                                val uniformScale = maxOf(texture.width / sourceWidth, texture.height / sourceHeight)
                                texture.scaleX = uniformScale / (texture.width / sourceWidth)
                                texture.scaleY = uniformScale / (texture.height / sourceHeight)
                                texture.rotation = configured.rotationDegrees.toFloat()
                            }
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
                if (receivedFrames == 0L) {
                    Text("等待 HEVC/RTP 预览", color = Color.White.copy(alpha = 0.7f))
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text("接收成片", fontWeight = FontWeight.SemiBold)
                    Text("默认开启；校验 SHA‑256 后保存", style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = receivePhotos, onCheckedChange = setReceivePhotos)
            }
        }
    }
}
