package dev.remotecam.preview

import android.os.Bundle
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.view.TextureView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.viewinterop.AndroidView
import dev.remotecam.preview.camera.CameraController
import dev.remotecam.preview.camera.CameraControllerListener
import dev.remotecam.preview.model.DeviceRole
import dev.remotecam.preview.photo.ReceivedPhoto
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
    if (state.sessionState == SessionState.CONNECTED && state.role != null) {
        BackHandler(onBack = viewModel::endSession)
        when (state.role) {
            DeviceRole.CAMERA -> CameraScreen(
                viewModel = viewModel,
                photoStatus = state.lastPhotoStatus,
                videoOutput = state.cameraVideoOutput,
                status = state.status,
                onClose = viewModel::endSession,
            )
            DeviceRole.MONITOR -> MonitorScreen(
                receivePhotos = state.receivePhotos,
                receivedFrames = state.receivedFrames,
                profile = state.negotiatedProfile,
                status = state.status,
                photoStatus = state.lastPhotoStatus,
                receivedPhotos = state.receivedPhotos,
                savedPhotoIds = state.savedPhotoIds,
                savingPhotos = state.savingReceivedPhotos,
                setReceivePhotos = viewModel::setReceivePhotos,
                updateViewport = viewModel::updateMonitorViewport,
                setSurface = viewModel::setMonitorSurface,
                saveAllPhotos = viewModel::saveAllReceivedPhotos,
                onClose = viewModel::endSession,
            )
            null -> Unit
        }
        return
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
private fun CameraScreen(
    viewModel: RemoteCamViewModel,
    photoStatus: String?,
    videoOutput: dev.remotecam.preview.media.HevcVideoOutput?,
    status: String,
    onClose: () -> Unit,
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
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxWidth().weight(1f)) {
            AndroidView(
                factory = { PreviewView(it).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } },
                    modifier = Modifier.fillMaxSize(),
                update = { controller.bind(it, videoOutput) },
            )
                Row(
                    Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onClose, modifier = Modifier.background(Color.Black.copy(alpha = .35f), CircleShape)) {
                        Text("×", color = Color.White, fontSize = 32.sp, fontWeight = FontWeight.Light)
                    }
                    Text(
                        "拍摄端 · 已连接",
                        color = Color.White,
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.background(Color.Black.copy(alpha = .35f), RoundedCornerShape(20.dp)).padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }
                photoStatus?.let {
                    Text(
                        it,
                        color = Color.White,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(12.dp).background(Color.Black.copy(alpha = .55f), RoundedCornerShape(16.dp)).padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }
            }
            CameraControls(ready = ready, status = status, onShutter = controller::takePhoto)
        }
    }
}

@Composable
private fun CameraControls(ready: Boolean, status: String, onShutter: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().background(Color(0xff0d0d0f)).navigationBarsPadding().padding(top = 12.dp, bottom = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("拍照姿势推荐", color = Color.White.copy(alpha = .72f), style = MaterialTheme.typography.labelMedium)
        Spacer(Modifier.height(9.dp))
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            PoseSuggestion("🧍", "自然站姿", Color(0xff7258e8))
            PoseSuggestion("✌️", "俏皮比耶", Color(0xffe15e85))
            PoseSuggestion("🪑", "侧坐回眸", Color(0xff327d8c))
            PoseSuggestion("🙆", "举手伸展", Color(0xffb36a2e))
            PoseSuggestion("🚶", "抓拍走动", Color(0xff3f6fb5))
        }
        Spacer(Modifier.height(16.dp))
        Box(Modifier.fillMaxWidth().height(82.dp)) {
            Column(
                Modifier.align(Alignment.CenterStart).width(96.dp).clickable { }.padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    Modifier.size(42.dp).border(1.dp, Color.White.copy(alpha = .65f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Text("✦", color = Color.White, fontSize = 20.sp) }
                Spacer(Modifier.height(4.dp))
                Text("美颜", color = Color.White.copy(alpha = .86f), style = MaterialTheme.typography.labelMedium)
            }
            Box(
                Modifier.align(Alignment.Center).size(78.dp).border(4.dp, Color.White, CircleShape).padding(6.dp)
                    .background(if (ready) Color.White else Color.Gray, CircleShape).clickable(enabled = ready, onClick = onShutter),
            )
            Text(
                "照片",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.CenterEnd).width(96.dp),
                textAlign = TextAlign.Center,
            )
        }
        Text(status, color = Color.White.copy(alpha = .48f), style = MaterialTheme.typography.labelSmall, maxLines = 1)
    }
}

@Composable
private fun PoseSuggestion(emoji: String, title: String, color: Color) {
    Column(
        Modifier.width(92.dp).background(color.copy(alpha = .3f), RoundedCornerShape(16.dp)).clickable { }.padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(emoji, fontSize = 25.sp)
        Spacer(Modifier.height(4.dp))
        Text(title, color = Color.White, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun MonitorScreen(
    receivePhotos: Boolean,
    receivedFrames: Long,
    profile: dev.remotecam.preview.model.StreamProfile?,
    status: String,
    photoStatus: String?,
    receivedPhotos: List<ReceivedPhoto>,
    savedPhotoIds: Set<String>,
    savingPhotos: Boolean,
    setReceivePhotos: (Boolean) -> Unit,
    updateViewport: (Int, Int) -> Unit,
    setSurface: (android.view.Surface?) -> Unit,
    saveAllPhotos: () -> Unit,
    onClose: () -> Unit,
) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Box(
            Modifier
                    .fillMaxSize()
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
                            val bufferWidth = configured.size.width.toFloat()
                            val bufferHeight = configured.size.height.toFloat()
                            val displayWidth = if (rotated) bufferHeight else bufferWidth
                            val displayHeight = if (rotated) bufferWidth else bufferHeight
                            if (texture.width > 0 && texture.height > 0) {
                                // TextureView initially stretches the unrotated codec buffer to its bounds.
                                // Undo that non-uniform stretch with the original buffer dimensions, while
                                // choosing the fill scale from the post-rotation dimensions.
                                val uniformScale = maxOf(texture.width / displayWidth, texture.height / displayHeight)
                                texture.pivotX = texture.width / 2f
                                texture.pivotY = texture.height / 2f
                                texture.scaleX = uniformScale / (texture.width / bufferWidth)
                                texture.scaleY = uniformScale / (texture.height / bufferHeight)
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
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onClose, modifier = Modifier.background(Color.Black.copy(alpha = .38f), CircleShape)) {
                Text("×", color = Color.White, fontSize = 32.sp, fontWeight = FontWeight.Light)
            }
            Text(
                "监看端 · ${if (receivedFrames > 0) "实时画面" else "正在连接"}",
                color = Color.White,
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.background(Color.Black.copy(alpha = .38f), RoundedCornerShape(20.dp)).padding(horizontal = 12.dp, vertical = 7.dp),
            )
        }
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = .62f))
                .navigationBarsPadding().padding(horizontal = 18.dp, vertical = 12.dp),
        ) {
            if (receivedPhotos.isEmpty()) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column {
                        Text("自动接收成片", color = Color.White, fontWeight = FontWeight.SemiBold)
                        Text("收到后先显示在这里", color = Color.White.copy(alpha = .65f), style = MaterialTheme.typography.bodySmall)
                    }
                    Switch(checked = receivePhotos, onCheckedChange = setReceivePhotos)
                }
            } else {
                ReceivedPhotoStrip(
                    photos = receivedPhotos,
                    savedPhotoIds = savedPhotoIds,
                    saving = savingPhotos,
                    onSaveAll = saveAllPhotos,
                )
            }
            Spacer(Modifier.height(5.dp))
            Text(photoStatus ?: status, color = Color.White.copy(alpha = .62f), style = MaterialTheme.typography.labelSmall, maxLines = 1)
        }
    }
}

@Composable
private fun ReceivedPhotoStrip(
    photos: List<ReceivedPhoto>,
    savedPhotoIds: Set<String>,
    saving: Boolean,
    onSaveAll: () -> Unit,
) {
    val allSaved = photos.all { it.descriptor.photoId in savedPhotoIds }
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        photos.forEachIndexed { index, photo ->
            val bitmap = remember(photo.file.absolutePath) { decodeThumbnail(photo) }
            Box(
                Modifier.width(72.dp).height(88.dp).clip(RoundedCornerShape(12.dp)).background(Color.DarkGray),
            ) {
                bitmap?.let {
                    Image(
                        bitmap = it.asImageBitmap(),
                        contentDescription = "已接收照片 ${index + 1}",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                Text(
                    "${index + 1}",
                    color = Color.White,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.align(Alignment.TopStart).background(Color.Black.copy(alpha = .5f), RoundedCornerShape(bottomEnd = 8.dp)).padding(horizontal = 6.dp, vertical = 3.dp),
                )
                if (photo.descriptor.photoId in savedPhotoIds) {
                    Text(
                        "✓",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.align(Alignment.BottomEnd).padding(5.dp).background(Color(0xff35a96b), CircleShape).padding(horizontal = 5.dp, vertical = 2.dp),
                    )
                }
            }
        }
        Column(
            Modifier.width(84.dp).height(88.dp).clip(RoundedCornerShape(12.dp))
                .background(if (allSaved) Color.White.copy(alpha = .12f) else MaterialTheme.colorScheme.primary)
                .clickable(enabled = !saving && !allSaved, onClick = onSaveAll),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(if (allSaved) "✓" else "↓", color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Text(
                when {
                    saving -> "保存中"
                    allSaved -> "已保存"
                    else -> "全部保存"
                },
                color = Color.White,
                style = MaterialTheme.typography.labelMedium,
            )
        }
    }
}

private fun decodeThumbnail(photo: ReceivedPhoto): android.graphics.Bitmap? {
    val path = photo.file.absolutePath
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (bounds.outWidth / sample > 360 || bounds.outHeight / sample > 360) sample *= 2
    return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
}
