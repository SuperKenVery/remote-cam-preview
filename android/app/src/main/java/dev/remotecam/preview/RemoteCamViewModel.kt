package dev.remotecam.preview

import android.app.Application
import android.net.ConnectivityManager
import android.net.Uri
import android.net.wifi.aware.WifiAwareManager
import android.view.Surface
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.remotecam.preview.aware.AwareDataPath
import dev.remotecam.preview.aware.AwareFailure
import dev.remotecam.preview.aware.EphemeralCredentials
import dev.remotecam.preview.aware.SecureDataPathCredential
import dev.remotecam.preview.aware.WifiAwareController
import dev.remotecam.preview.aware.WifiAwareListener
import dev.remotecam.preview.capability.DeviceCapabilityChecker
import dev.remotecam.preview.media.CodecParameterSets
import dev.remotecam.preview.media.DecoderAccessUnit
import dev.remotecam.preview.media.EncodedAccessUnit
import dev.remotecam.preview.media.HevcDecoder
import dev.remotecam.preview.media.HevcDecoderListener
import dev.remotecam.preview.media.HevcEncoder
import dev.remotecam.preview.media.HevcEncoderListener
import dev.remotecam.preview.media.HevcVideoOutput
import dev.remotecam.preview.model.DeviceCapabilityReport
import dev.remotecam.preview.model.DeviceRole
import dev.remotecam.preview.model.DiscoveredPeer
import dev.remotecam.preview.model.DisplayCapability
import dev.remotecam.preview.model.DisplayOrientation
import dev.remotecam.preview.model.HevcCapability
import dev.remotecam.preview.model.PixelSize
import dev.remotecam.preview.model.StreamProfile
import dev.remotecam.preview.network.ControlServerConnection
import dev.remotecam.preview.network.SessionClient
import dev.remotecam.preview.network.SessionClientListener
import dev.remotecam.preview.network.SessionServer
import dev.remotecam.preview.network.SessionServerListener
import dev.remotecam.preview.network.UdpPreviewReceiver
import dev.remotecam.preview.network.UdpPreviewReceiverListener
import dev.remotecam.preview.network.UdpPreviewSender
import dev.remotecam.preview.network.UdpRtcpReceiver
import dev.remotecam.preview.network.UdpRtcpReporter
import dev.remotecam.preview.network.RtcpReceiverListener
import dev.remotecam.preview.photo.PhotoDescriptor
import dev.remotecam.preview.photo.PhotoReceiver
import dev.remotecam.preview.photo.PhotoResourceRegistry
import dev.remotecam.preview.photo.PhotoStager
import dev.remotecam.preview.protocol.AnnexB
import dev.remotecam.preview.protocol.ControlEnvelope
import dev.remotecam.preview.protocol.ControlTypes
import dev.remotecam.preview.protocol.DepacketizedFrame
import dev.remotecam.preview.protocol.RequestReplayCache
import dev.remotecam.preview.session.InvalidSessionTransition
import dev.remotecam.preview.session.SessionEvent
import dev.remotecam.preview.session.SessionState
import dev.remotecam.preview.session.SessionStateMachine
import dev.remotecam.preview.session.StreamNegotiator
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

private const val CONTROL_AND_PHOTO_PORT = 49_154
private const val RTP_PORT = 49_152
private const val RTCP_PORT = 49_153
private const val RTP_PAYLOAD_TYPE = 98
private const val MAX_RTP_PACKET_SIZE = 1200

data class RemoteCamUiState(
    val capabilities: DeviceCapabilityReport,
    val role: DeviceRole? = null,
    val sessionState: SessionState = SessionState.UNPAIRED,
    val peers: List<DiscoveredPeer> = emptyList(),
    val status: String = "请选择本次会话角色",
    val receivePhotos: Boolean = true,
    val lastPhotoStatus: String? = null,
    val dataPath: AwareDataPath? = null,
    val sessionPassphrase: String = "",
    val monitorViewport: PixelSize? = null,
    val cameraVideoOutput: HevcVideoOutput? = null,
    val negotiatedProfile: StreamProfile? = null,
    val receivedFrames: Long = 0,
)

class RemoteCamViewModel(application: Application) : AndroidViewModel(application), WifiAwareListener {
    private val checker = DeviceCapabilityChecker(application)
    private var machine = SessionStateMachine()
    private val photoStager = PhotoStager(application)
    private val photoReceiver = PhotoReceiver(application)
    val photoResources = PhotoResourceRegistry()
    private val json = Json { ignoreUnknownKeys = true }
    private val random = SecureRandom()
    private val requestIds = AtomicInteger(1)
    private val previewStreaming = AtomicBoolean(false)
    private val lastHeartbeatPong = AtomicLong(0)
    private val mediaLock = Any()
    private val photoLock = Any()

    private var awareController: WifiAwareController? = null
    private var selectedPeerId: String? = null
    private var sessionServer: SessionServer? = null
    private var sessionClient: SessionClient? = null
    private var serverControl: ControlServerConnection? = null
    private var udpSender: UdpPreviewSender? = null
    private var udpReceiver: UdpPreviewReceiver? = null
    private var rtcpReceiver: UdpRtcpReceiver? = null
    private var rtcpReporter: UdpRtcpReporter? = null
    private var encoderOutput: HevcVideoOutput? = null
    private var decoder: HevcDecoder? = null
    private var monitorSurface: Surface? = null
    private var monitorProfile: StreamProfile? = null
    private var monitorParameterSets: CodecParameterSets? = null
    private val monitorParameterNals = linkedMapOf<Int, ByteArray>()
    private var encoderParameterSets: CodecParameterSets? = null
    private var activeConfigId: String? = null
    private var monitorSessionId: String? = null
    private var cameraSessionId: String? = null
    private var monitorSsrc: Long = 1
    private var accessToken: String? = null
    private var remoteReceivePhotos = true
    private var closingTransport = false
    private var heartbeatJob: Job? = null
    private var replayCache = RequestReplayCache()
    private val requestFingerprints = linkedMapOf<String, String>()

    private val _uiState = MutableStateFlow(RemoteCamUiState(checker.inspect()))
    val uiState: StateFlow<RemoteCamUiState> = _uiState.asStateFlow()

    fun requiredPermissions(): Array<String> {
        val role = _uiState.value.role
        return checker.requiredRuntimePermissions().filter { permission ->
            role == DeviceRole.CAMERA || permission != android.Manifest.permission.CAMERA
        }.toTypedArray()
    }

    fun refreshCapabilities() {
        val report = checker.inspect()
        updateUi { it.copy(capabilities = report) }
        if (!report.awareHardware || !report.awareAvailable) {
            safeApply(SessionEvent.CAPABILITY_LOST)
            updateUi {
                it.copy(status = if (!report.awareHardware) {
                    "此设备不支持 Wi‑Fi Aware"
                } else {
                    "Wi‑Fi Aware 当前不可用，请开启 Wi‑Fi 后重试"
                })
            }
        } else if (machine.state == SessionState.UNAVAILABLE) {
            safeApply(SessionEvent.CAPABILITY_RESTORED)
            updateUi { it.copy(status = "能力已恢复，可重新开始") }
        }
    }

    fun selectRole(role: DeviceRole) {
        if (machine.state !in setOf(SessionState.UNPAIRED, SessionState.UNAVAILABLE)) return
        if (role == DeviceRole.CAMERA && !_uiState.value.capabilities.cameraAvailable) {
            updateUi { it.copy(status = "此设备没有可用相机，不能作为拍摄端") }
            return
        }
        updateUi {
            it.copy(
                role = role,
                status = if (role == DeviceRole.CAMERA) "拍摄端：本机拍照并发送实时预览" else "监看端：显示远端预览",
            )
        }
    }

    fun setSessionPassphrase(value: String) {
        val normalized = value.filter { !it.isISOControl() }.take(63)
        updateUi { it.copy(sessionPassphrase = normalized) }
        if (normalized.length in 8..63 && machine.state == SessionState.CONNECTING) requestSecureDataPathIfReady()
    }

    fun updateMonitorViewport(width: Int, height: Int) {
        if (width > 0 && height > 0) updateUi { it.copy(monitorViewport = PixelSize(width, height)) }
    }

    fun setMonitorSurface(surface: Surface?) = synchronized(mediaLock) {
        if (monitorSurface === surface) return@synchronized
        decoder?.close()
        decoder = null
        monitorSurface = surface
        maybeStartDecoderLocked()
    }

    fun onPermissionsResult() = refreshCapabilities()

    fun startDiscovery() {
        val state = _uiState.value
        val role = state.role ?: return
        val missingRelevant = state.capabilities.missingPermissions.intersect(requiredPermissions().toSet())
        if (missingRelevant.isNotEmpty()) {
            updateUi { it.copy(status = "请先授予相机/附近设备权限") }
            return
        }
        if (!state.capabilities.awareHardware || !state.capabilities.awareAvailable) {
            refreshCapabilities()
            return
        }
        closeTransport()
        awareController?.close()
        selectedPeerId = null
        safeApply(SessionEvent.START_DISCOVERY)
        updateUi { it.copy(peers = emptyList(), status = "正在通过 Wi‑Fi Aware 查找互补角色设备…") }
        val application = getApplication<Application>()
        awareController = WifiAwareController(
            awareManager = application.getSystemService(WifiAwareManager::class.java),
            connectivityManager = application.getSystemService(ConnectivityManager::class.java),
            localRole = role,
            listener = this,
        ).also { it.attachAndDiscover() }
    }

    fun confirmPeer(peerId: String) {
        selectedPeerId = peerId
        if (machine.state == SessionState.DISCOVERING) safeApply(SessionEvent.PEER_SELECTED)
        updateUi { it.copy(status = "正在与所选设备完成系统 Wi‑Fi Aware 配对…") }
        awareController?.confirmPeer(peerId)
    }

    fun retry() {
        closeTransport()
        awareController?.close()
        awareController = null
        if (machine.state == SessionState.INTERRUPTED) safeApply(SessionEvent.RETRY)
        // retry already transitions to DISCOVERING, so recreate discovery directly.
        val role = _uiState.value.role ?: return
        val application = getApplication<Application>()
        updateUi { it.copy(peers = emptyList(), status = "正在重试发现…") }
        awareController = WifiAwareController(
            application.getSystemService(WifiAwareManager::class.java),
            application.getSystemService(ConnectivityManager::class.java),
            role,
            this,
        ).also { it.attachAndDiscover() }
    }

    fun endSession() {
        closingTransport = true
        safeApply(SessionEvent.END)
        closeTransport()
        awareController?.close()
        awareController = null
        closingTransport = false
        machine = SessionStateMachine()
        selectedPeerId = null
        updateUi {
            it.copy(
                role = null,
                sessionState = SessionState.UNPAIRED,
                peers = emptyList(),
                sessionPassphrase = "",
                status = "旧会话资源已撤销，请重新选择角色",
                dataPath = null,
            )
        }
    }

    fun setReceivePhotos(enabled: Boolean) {
        updateUi {
            it.copy(
                receivePhotos = enabled,
                status = if (enabled) "接收成片已开启；连接后会立即同步给拍摄端" else "接收成片已关闭",
            )
        }
        if (_uiState.value.role == DeviceRole.MONITOR) {
            sessionClient?.send(
                ControlEnvelope(
                    ControlTypes.PHOTO_RECEIVE_PREFERENCE,
                    nextRequestId("photo-pref"),
                    payload = buildJsonObject { put("enabled", enabled) },
                ),
            )
        }
    }

    fun onPhotoSaved(uri: Uri) {
        updateUi { it.copy(lastPhotoStatus = "照片已保存到本机相册") }
        serverControl?.send(
            ControlEnvelope(
                ControlTypes.PHOTO_CAPTURED,
                nextRequestId("capture-event"),
                payload = buildJsonObject {
                    put("captureId", nextRequestId("capture"))
                    put("savedLocally", true)
                },
            ),
        )
        if (!remoteReceivePhotos || serverControl == null) {
            updateUi { it.copy(lastPhotoStatus = "照片已保存；监看端未开启成片接收") }
            return
        }
        viewModelScope.launch {
            runCatching { photoStager.stage(uri) }
                .onSuccess { staged ->
                    val descriptor = synchronized(photoLock) {
                        if (serverControl == null || !remoteReceivePhotos || machine.state != SessionState.CONNECTED) {
                            staged.file.delete()
                            null
                        } else {
                            photoResources.publish(staged)
                        }
                    } ?: return@onSuccess
                    val metadata = json.encodeToJsonElement(PhotoDescriptor.serializer(), descriptor)
                    serverControl?.send(
                        ControlEnvelope(
                            ControlTypes.PHOTO_AVAILABLE,
                            nextRequestId("photo-available"),
                            payload = buildJsonObject {
                                put("metadata", metadata)
                                put("expiresInSeconds", 120)
                            },
                        ),
                    )
                    updateUi { it.copy(lastPhotoStatus = "照片已保存；成片资源已发布给监看端") }
                }
                .onFailure { error ->
                    updateUi { it.copy(lastPhotoStatus = "照片已保存，但成片暂存失败：${error.message}") }
                }
        }
    }

    fun onCameraError(error: Throwable) = updateUi {
        it.copy(status = "相机错误：${error.message ?: "未知错误"}")
    }

    override fun onAttached() = updateUi {
        it.copy(status = "Wi‑Fi Aware 已就绪，正在同时发布与订阅服务")
    }

    override fun onPeerDiscovered(peer: DiscoveredPeer) {
        val localRole = _uiState.value.role
        if (peer.role == localRole) return
        updateUi { current ->
            val peers = (current.peers.filterNot { it.id == peer.id } + peer).sortedBy { it.alias ?: it.id }
            current.copy(peers = peers, status = "发现 ${peers.size} 台可配对设备，请明确选择")
        }
    }

    override fun onPeerConfirmationRequired(peer: DiscoveredPeer) = onPeerDiscovered(peer)

    override fun onPairingStarted(peerId: String) = updateUi {
        it.copy(status = "正在配对 ${peerId.take(12)}…")
    }

    override fun onPairingVerified(peerId: String, alias: String?) {
        selectedPeerId = peerId
        if (machine.state == SessionState.PAIRING) safeApply(SessionEvent.PAIRING_SUCCEEDED)
        updateUi {
            it.copy(
                status = if (it.sessionPassphrase.length in 8..63) {
                    "配对已验证，正在请求加密数据路径…"
                } else {
                    "配对已验证；请在两端输入相同的本次会话临时口令（8–63 字符）"
                },
                peers = it.peers.map { item ->
                    if (item.id == peerId) item.copy(alias = alias, pairingVerified = true) else item
                },
            )
        }
        requestSecureDataPathIfReady()
    }

    private fun requestSecureDataPathIfReady() {
        val peerId = selectedPeerId ?: return
        val passphrase = _uiState.value.sessionPassphrase
        if (passphrase.length !in 8..63 || machine.state != SessionState.CONNECTING) return
        val serverPort = if (_uiState.value.role == DeviceRole.CAMERA) CONTROL_AND_PHOTO_PORT else null
        awareController?.requestSecureDataPath(peerId, SecureDataPathCredential(passphrase), serverPort)
        updateUi { it.copy(status = "正在建立仅绑定 Wi‑Fi Aware 的加密 IP 数据路径…") }
    }

    override fun onDataPathAvailable(peerId: String, dataPath: AwareDataPath) {
        if (_uiState.value.dataPath?.network == dataPath.network) return
        val local = dataPath.localAddress
        if (local == null) {
            onFailure(AwareFailure.DataPathFailed("Aware link-local IPv6 address unavailable"))
            return
        }
        if (machine.state == SessionState.CONNECTING) safeApply(SessionEvent.TRANSPORT_CONNECTED)
        updateUi { it.copy(dataPath = dataPath, status = "安全数据路径已建立，正在启动会话通道…") }
        when (_uiState.value.role) {
            DeviceRole.CAMERA -> startCaptureServer(dataPath)
            DeviceRole.MONITOR -> {
                monitorSessionId = EphemeralCredentials.newSessionId()
                viewModelScope.launch {
                    delay(300)
                    startMonitorClient(dataPath)
                }
            }
            null -> Unit
        }
    }

    private fun startCaptureServer(dataPath: AwareDataPath) {
        val local = dataPath.localAddress ?: return
        accessToken = EphemeralCredentials.newAccessToken()
        sessionServer?.close()
        lateinit var createdServer: SessionServer
        createdServer = SessionServer(
            localAddress = local,
            port = CONTROL_AND_PHOTO_PORT,
            accessToken = requireNotNull(accessToken),
            photos = photoResources,
            listener = object : SessionServerListener {
                override fun onControlConnected(connection: ControlServerConnection) {
                    serverControl = connection
                    updateUi { it.copy(status = "监看端已连接控制 WebSocket，等待 session.hello") }
                }

                override fun onControlMessage(connection: ControlServerConnection, message: ControlEnvelope) {
                    handleCaptureControl(connection, message, dataPath)
                }

                override fun onControlClosed(connection: ControlServerConnection) {
                    if (serverControl !== connection) return
                    serverControl = null
                    stopPreviewMedia()
                    // Invalidate the HTTP listener, token, and every staged resource promptly. Run
                    // outside the server's client thread to avoid self-join/deadlock.
                    val oldServer = createdServer
                    if (sessionServer === oldServer) {
                        sessionServer = null
                        accessToken = null
                        synchronized(photoLock) { photoResources.close() }
                    }
                    viewModelScope.launch(Dispatchers.IO) { oldServer?.close() }
                    if (!closingTransport && machine.state == SessionState.CONNECTED) safeApply(SessionEvent.CONTROL_LOST)
                    if (!closingTransport) updateUi { it.copy(status = "控制 WebSocket 已断开；预览和成片发布已停止") }
                }

                override fun onServerError(error: Throwable) = updateUi {
                    it.copy(status = "会话服务错误：${error.message ?: "未知错误"}")
                }
            },
        )
        sessionServer = createdServer
        replayCache = RequestReplayCache()
        synchronized(requestFingerprints) { requestFingerprints.clear() }
        createdServer.start()
    }

    private fun startMonitorClient(dataPath: AwareDataPath) {
        val controlPort = dataPath.advertisedPeerPort.takeIf { it in 1..65_535 }
        if (controlPort == null) {
            onFailure(
                AwareFailure.DataPathFailed(
                    "peer did not advertise a secure publisher/server port; app role is not silently remapped to Aware publish",
                ),
            )
            return
        }
        sessionClient?.close()
        sessionClient = SessionClient(dataPath.network, dataPath.peerAddress, controlPort).also { client ->
            client.connect(object : SessionClientListener {
                override fun onOpen() {
                    client.send(buildSessionHello())
                    updateUi { it.copy(status = "控制 WebSocket 已连接，正在协商显示与 HEVC 能力…") }
                }

                override fun onMessage(message: ControlEnvelope) = handleMonitorControl(message, dataPath)

                override fun onClosed() {
                    if (sessionClient !== client) return
                    handleMonitorControlLoss("控制 WebSocket 已断开；媒体接收已停止")
                }

                override fun onError(error: Throwable) {
                    client.close()
                    if (sessionClient !== client) return
                    handleMonitorControlLoss("控制连接失败：${error.message ?: "未知错误"}")
                }
            })
        }
    }

    private fun handleMonitorControlLoss(message: String) {
        if (closingTransport) return
        closingTransport = true
        closeTransport()
        if (machine.state == SessionState.CONNECTED) safeApply(SessionEvent.CONTROL_LOST)
        closingTransport = false
        updateUi { it.copy(status = message) }
    }

    private fun buildSessionHello(): ControlEnvelope {
        val metrics = getApplication<Application>().resources.displayMetrics
        val native = PixelSize(metrics.widthPixels.coerceAtLeast(1), metrics.heightPixels.coerceAtLeast(1))
        val viewport = _uiState.value.monitorViewport ?: native
        val decoderCapability = _uiState.value.capabilities.hevcDecoder
        val max = decoderCapability.maxSize ?: PixelSize(1920, 1080)
        return ControlEnvelope(
            ControlTypes.SESSION_HELLO,
            nextRequestId("hello"),
            payload = buildJsonObject {
                put("role", "monitor")
                put("sessionId", requireNotNull(monitorSessionId))
                put("supportedProtocolVersions", buildJsonArray { add("1.0") })
                put("display", buildJsonObject {
                    put("nativeWidthPx", native.width)
                    put("nativeHeightPx", native.height)
                    put("viewportWidthPx", viewport.width)
                    put("viewportHeightPx", viewport.height)
                    put("orientation", if (viewport.height >= viewport.width) "portrait" else "landscapeLeft")
                })
                put("hevc", buildJsonObject {
                    put("profiles", buildJsonArray { add("main") })
                    put("maxWidthPx", max.width.coerceAtMost(16_384))
                    put("maxHeightPx", max.height.coerceAtMost(16_384))
                    put("maxFps", decoderCapability.maxFps.coerceIn(1, 240))
                    put("maxLevelIdc", 153)
                })
                put("photoReceiveEnabled", _uiState.value.receivePhotos)
            },
        )
    }

    private fun handleCaptureControl(
        connection: ControlServerConnection,
        message: ControlEnvelope,
        dataPath: AwareDataPath,
    ) {
        when (message.type) {
            ControlTypes.SESSION_HELLO -> {
                val fingerprint = message.type + "\n" + message.protocolVersion + "\n" + message.payload.toString()
                val conflict = synchronized(requestFingerprints) {
                    val previous = requestFingerprints[message.requestId]
                    if (previous == null) {
                        if (requestFingerprints.size >= 256) requestFingerprints.remove(requestFingerprints.keys.first())
                        requestFingerprints[message.requestId] = fingerprint
                    }
                    previous != null && previous != fingerprint
                }
                if (conflict) {
                    connection.send(
                        ControlEnvelope(
                            ControlTypes.ERROR,
                            message.requestId,
                            payload = buildJsonObject {
                                put("code", "DUPLICATE_REQUEST_CONFLICT")
                                put("message", "requestId was reused with different content")
                                put("retryable", false)
                                put("relatedRequestId", message.requestId)
                            },
                        ),
                    )
                } else {
                    val cached = replayCache.get(message.requestId)
                    if (cached != null) {
                        connection.send(cached)
                    } else {
                        val accepted = acceptMonitor(message, dataPath)
                        replayCache.put(message.requestId, accepted)
                        connection.send(accepted)
                    }
                }
            }
            ControlTypes.PREVIEW_START -> {
                if (message.payload["configId"]?.jsonPrimitive?.content == activeConfigId) {
                    previewStreaming.set(true)
                    encoderOutput?.requestKeyFrame()
                    updateUi { it.copy(status = "实时 HEVC/RTP 预览已开始") }
                }
            }
            ControlTypes.PREVIEW_STOP -> {
                previewStreaming.set(false)
                updateUi { it.copy(status = "监看端已停止预览") }
            }
            ControlTypes.KEYFRAME_REQUEST -> encoderOutput?.requestKeyFrame()
            ControlTypes.PHOTO_RECEIVE_PREFERENCE -> {
                remoteReceivePhotos = message.payload["enabled"]!!.jsonPrimitive.boolean
                updateUi { it.copy(status = if (remoteReceivePhotos) "监看端已开启成片接收" else "监看端已关闭成片接收") }
            }
            ControlTypes.PHOTO_TRANSFER_RESULT -> {
                val photoId = message.payload["photoId"]!!.jsonPrimitive.content
                photoResources.acknowledge(photoId)
                updateUi { it.copy(lastPhotoStatus = "监看端已报告成片${message.payload["status"]!!.jsonPrimitive.content}") }
            }
            ControlTypes.HEARTBEAT_PING -> connection.send(
                ControlEnvelope(
                    ControlTypes.HEARTBEAT_PONG,
                    message.requestId,
                    payload = message.payload,
                ),
            )
            ControlTypes.SESSION_END -> connection.close()
        }
    }

    private fun acceptMonitor(
        hello: ControlEnvelope,
        dataPath: AwareDataPath,
    ): ControlEnvelope {
        cameraSessionId = hello.payload["sessionId"]!!.jsonPrimitive.content
        remoteReceivePhotos = hello.payload["photoReceiveEnabled"]!!.jsonPrimitive.boolean
        val display = hello.payload["display"]!!.jsonObject
        val hevc = hello.payload["hevc"]!!.jsonObject
        val orientation = when (display["orientation"]!!.jsonPrimitive.content) {
            "portrait", "portraitUpsideDown" -> DisplayOrientation.PORTRAIT
            else -> DisplayOrientation.LANDSCAPE
        }
        val monitor = DisplayCapability(
            nativePixels = PixelSize(display.int("nativeWidthPx"), display.int("nativeHeightPx")),
            viewport = PixelSize(display.int("viewportWidthPx"), display.int("viewportHeightPx")),
            orientation = orientation,
            hevcDecoder = HevcCapability(
                true,
                PixelSize(hevc.int("maxWidthPx"), hevc.int("maxHeightPx")),
                hevc.int("maxFps"),
                setOf("Main"),
            ),
        )
        val camera = checker.cameraStreamCapability()
        val profile = runCatching { StreamNegotiator.negotiate(camera, monitor) }.getOrElse { error ->
            return ControlEnvelope(
                ControlTypes.ERROR,
                hello.requestId,
                payload = buildJsonObject {
                    put("code", "NO_COMMON_MEDIA_CONFIGURATION")
                    put("message", error.message ?: "No camera/HEVC resolution is mutually supported")
                    put("retryable", false)
                    put("relatedRequestId", hello.requestId)
                },
            )
        }
        val configId = nextRequestId("config")
        activeConfigId = configId
        val ssrc = randomUnsignedNonZero()
        val local = requireNotNull(dataPath.localAddress)
        udpSender?.close()
        udpSender = UdpPreviewSender(
            dataPath.network,
            local,
            RTP_PORT,
            dataPath.peerAddress,
            RTP_PAYLOAD_TYPE,
            ssrc,
            random.nextInt(65_536),
            randomUnsignedNonZero(),
            MAX_RTP_PACKET_SIZE,
        )
        rtcpReceiver?.close()
        rtcpReceiver = UdpRtcpReceiver(
            dataPath.network,
            local,
            RTCP_PORT,
            dataPath.peerAddress,
            ssrc,
            object : RtcpReceiverListener {
                override fun onPictureLossIndication() = encoderOutput?.requestKeyFrame() ?: Unit
                override fun onReceiverReport(bytes: ByteArray) = updateUi {
                    it.copy(status = "实时预览中（已收到 RTCP RR）")
                }
                override fun onRtcpError(error: Throwable) = updateUi {
                    it.copy(status = "RTCP 接收错误：${error.message}")
                }
            },
        )
        createCameraEncoder(profile)
        val accepted = ControlEnvelope(
                ControlTypes.SESSION_ACCEPTED,
                hello.requestId,
                payload = buildJsonObject {
                    put("role", "capture")
                    put("sessionId", requireNotNull(cameraSessionId))
                    put("accessToken", requireNotNull(accessToken))
                    put("preview", profileJson(profile, configId))
                    put("rtp", buildJsonObject {
                        put("destinationAddress", local.hostAddress)
                        put("rtpPort", RTP_PORT)
                        put("rtcpPort", RTCP_PORT)
                        put("payloadType", RTP_PAYLOAD_TYPE)
                        put("ssrc", ssrc)
                        put("maxRtpPacketSize", MAX_RTP_PACKET_SIZE)
                    })
                    put("photoEndpoint", buildJsonObject { put("port", CONTROL_AND_PHOTO_PORT) })
                },
            )
        updateUi { it.copy(status = "能力协商完成，等待监看端 preview.start") }
        return accepted
    }

    private fun createCameraEncoder(profile: StreamProfile) {
        encoderOutput?.close()
        encoderParameterSets = null
        val output = HevcVideoOutput(
            HevcEncoder(profile, object : HevcEncoderListener {
                override fun onEncoderReady(actualSize: PixelSize) {
                    if (actualSize != profile.size) {
                        previewStreaming.set(false)
                        val detail = "CameraX 输出 ${actualSize.width}×${actualSize.height}，与已协商的 ${profile.size.width}×${profile.size.height} 不一致"
                        serverControl?.send(
                            ControlEnvelope(
                                ControlTypes.ERROR,
                                nextRequestId("media-config"),
                                payload = buildJsonObject {
                                    put("code", "MEDIA_CONFIGURATION_MISMATCH")
                                    put("message", detail)
                                    put("retryable", false)
                                },
                            ),
                        )
                        updateUi { it.copy(status = "$detail；已停止本次媒体会话，避免黑屏或错误解码") }
                        viewModelScope.launch {
                            delay(50)
                            serverControl?.close()
                        }
                    }
                }

                override fun onParameterSets(parameters: CodecParameterSets) {
                    encoderParameterSets = parameters
                }

                override fun onAccessUnit(accessUnit: EncodedAccessUnit) {
                    if (accessUnit.codecConfig) {
                        encoderParameterSets = CodecParameterSets(listOf(accessUnit.data))
                        return
                    }
                    if (!previewStreaming.get()) return
                    // Parameter sets and the following IDR are one RTP access unit. Sending them
                    // through separate packetizer calls would create two marker bits for the same
                    // timestamp and make a conforming receiver discard the entire frame.
                    val parameterSets = encoderParameterSets.takeIf { accessUnit.keyFrame }
                    runCatching { udpSender?.send(accessUnit, parameterSets) }.onFailure(::onCameraError)
                }

                override fun onEncoderError(error: Throwable) = onCameraError(error)
            }),
            preferredSize = profile.size,
        )
        encoderOutput = output
        updateUi { it.copy(cameraVideoOutput = output) }
    }

    private fun handleMonitorControl(message: ControlEnvelope, dataPath: AwareDataPath) {
        when (message.type) {
            ControlTypes.SESSION_ACCEPTED -> configureMonitorPreview(message, dataPath)
            ControlTypes.PHOTO_AVAILABLE -> receiveAvailablePhoto(message)
            ControlTypes.HEARTBEAT_PING -> sessionClient?.send(
                ControlEnvelope(ControlTypes.HEARTBEAT_PONG, message.requestId, payload = message.payload),
            )
            ControlTypes.HEARTBEAT_PONG -> lastHeartbeatPong.set(System.currentTimeMillis())
            ControlTypes.ERROR -> updateUi { it.copy(status = "对端错误：${message.payload["message"]?.jsonPrimitive?.content}") }
            ControlTypes.SESSION_END -> sessionClient?.close()
        }
    }

    private fun configureMonitorPreview(accepted: ControlEnvelope, dataPath: AwareDataPath) {
        if (accepted.payload["sessionId"]!!.jsonPrimitive.content != monitorSessionId) {
            updateUi { it.copy(status = "对端回显的 session ID 不匹配，已拒绝") }
            sessionClient?.close()
            return
        }
        val preview = accepted.payload["preview"]!!.jsonObject
        val rtp = accepted.payload["rtp"]!!.jsonObject
        val profile = StreamProfile(
            size = PixelSize(preview.int("widthPx"), preview.int("heightPx")),
            sampleAspectRatio = PixelSize(
                preview["sampleAspectRatio"]!!.jsonObject.int("width"),
                preview["sampleAspectRatio"]!!.jsonObject.int("height"),
            ),
            frameRate = preview.int("fps"),
            bitRate = preview.int("bitrateBps"),
            profile = preview["profile"]!!.jsonPrimitive.content,
            level = preview.int("levelIdc").toString(),
            rotationDegrees = preview.int("rotationDegrees"),
        )
        monitorProfile = profile
        updateUi { it.copy(negotiatedProfile = profile) }
        activeConfigId = preview["configId"]!!.jsonPrimitive.content
        val local = dataPath.localAddress ?: return
        udpReceiver?.close()
        udpReceiver = UdpPreviewReceiver(
            dataPath.network,
            local,
            dataPath.peerAddress,
            rtp.int("rtpPort"),
            rtp.int("payloadType"),
            rtp["ssrc"]!!.jsonPrimitive.long.also { monitorSsrc = it },
            rtp.int("maxRtpPacketSize"),
            object : UdpPreviewReceiverListener {
                override fun onFrame(frame: DepacketizedFrame) = handleReceivedFrame(frame)
                override fun onMalformedPacket() = requestKeyFrame("loss")
                override fun onReceiverError(error: Throwable) = updateUi {
                    it.copy(status = "RTP 接收错误：${error.message ?: "未知错误"}")
                }
            },
        )
        rtcpReporter?.close()
        rtcpReporter = UdpRtcpReporter(
            dataPath.network,
            local,
            dataPath.peerAddress,
            rtp.int("rtcpPort"),
            randomUnsignedNonZero(),
            monitorSsrc,
            stats = { udpReceiver?.stats() ?: dev.remotecam.preview.network.RtpReceiveStats(0, 0, 0, 0, 0) },
        )
        synchronized(mediaLock) { maybeStartDecoderLocked() }
        sessionClient?.send(
            ControlEnvelope(
                ControlTypes.PREVIEW_START,
                nextRequestId("preview-start"),
                payload = buildJsonObject { put("configId", requireNotNull(activeConfigId)) },
            ),
        )
        startHeartbeat()
        updateUi { it.copy(status = "已建立 RTP 接收通道，等待参数集和 IDR") }
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        lastHeartbeatPong.set(System.currentTimeMillis())
        heartbeatJob = viewModelScope.launch {
            while (sessionClient != null && !closingTransport) {
                delay(3_000)
                val now = System.currentTimeMillis()
                if (now - lastHeartbeatPong.get() > 10_000) {
                    updateUi { it.copy(status = "应用层心跳超时；正在关闭失去控制的媒体会话") }
                    sessionClient?.close()
                    break
                }
                sessionClient?.send(
                    ControlEnvelope(
                        ControlTypes.HEARTBEAT_PING,
                        nextRequestId("ping"),
                        payload = buildJsonObject { put("sentAtMs", now) },
                    ),
                )
            }
        }
    }

    private fun handleReceivedFrame(frame: DepacketizedFrame) {
        if (frame.damaged) {
            requestKeyFrame("loss")
            return
        }
        val nals = runCatching { AnnexB.split(frame.annexB) }.getOrElse {
            requestKeyFrame("decoderReset")
            return
        }
        val typedNals = nals.map { nal -> ((nal[0].toInt() ushr 1) and 0x3f) to nal }
        val mediaNals = typedNals.filterNot { (type, _) -> type in 32..34 }.map { it.second }
        synchronized(mediaLock) {
            typedNals.filter { (type, _) -> type in 32..34 }.forEach { (type, nal) ->
                monitorParameterNals[type] = nal
            }
            if ((32..34).all(monitorParameterNals::containsKey)) {
                // CSD contains only VPS/SPS/PPS. The IDR remains in the queued access unit;
                // putting an IDR into csd-0 breaks strict MediaCodec implementations.
                monitorParameterSets = CodecParameterSets(
                    listOf(AnnexB.join((32..34).map { requireNotNull(monitorParameterNals[it]) })),
                )
                maybeStartDecoderLocked()
            }
            if (mediaNals.isNotEmpty()) {
                decoder?.queue(DecoderAccessUnit(AnnexB.join(mediaNals), System.nanoTime() / 1_000))
            }
        }
        if (mediaNals.isNotEmpty()) updateUi { it.copy(receivedFrames = it.receivedFrames + 1) }
    }

    private fun maybeStartDecoderLocked() {
        if (decoder != null) return
        val profile = monitorProfile ?: return
        val surface = monitorSurface ?: return
        val parameters = monitorParameterSets ?: return
        decoder = runCatching {
            HevcDecoder(profile, surface, parameters, object : HevcDecoderListener {
                override fun onDecoderError(error: Throwable) = updateUi {
                    it.copy(status = "HEVC 解码错误：${error.message ?: "未知错误"}")
                }
            })
        }.onFailure { error ->
            updateUi { it.copy(status = "无法启动 HEVC 解码器：${error.message}") }
        }.getOrNull()
    }

    private fun requestKeyFrame(reason: String) {
        rtcpReporter?.requestKeyFrame()
        sessionClient?.send(
            ControlEnvelope(
                ControlTypes.KEYFRAME_REQUEST,
                nextRequestId("keyframe"),
                payload = buildJsonObject {
                    put("mediaSsrc", monitorSsrc)
                    put("reason", reason.take(64))
                },
            ),
        )
    }

    private fun receiveAvailablePhoto(message: ControlEnvelope) {
        if (!_uiState.value.receivePhotos) return
        val descriptor = runCatching {
            json.decodeFromJsonElement(PhotoDescriptor.serializer(), message.payload["metadata"]!!).also { it.validate() }
        }.getOrElse {
            updateUi { state -> state.copy(lastPhotoStatus = "收到的成片元数据无效") }
            return
        }
        viewModelScope.launch {
            val result = runCatching { requireNotNull(sessionClient).pullPhoto(descriptor, photoReceiver) }
            if (result.isSuccess) {
                updateUi { it.copy(lastPhotoStatus = "成片校验一致并已保存到本机相册") }
                sessionClient?.send(photoTransferResult(descriptor.photoId, "saved", null))
            } else {
                updateUi { it.copy(lastPhotoStatus = "成片接收失败：${result.exceptionOrNull()?.message}") }
                sessionClient?.send(photoTransferResult(descriptor.photoId, "failed", "PHOTO_TRANSFER_FAILED"))
            }
        }
    }

    private fun photoTransferResult(photoId: String, status: String, errorCode: String?) = ControlEnvelope(
        ControlTypes.PHOTO_TRANSFER_RESULT,
        nextRequestId("photo-result"),
        payload = buildJsonObject {
            put("photoId", photoId)
            put("status", status)
            errorCode?.let { put("errorCode", it) }
        },
    )

    private fun profileJson(profile: StreamProfile, configId: String) = buildJsonObject {
        put("configId", configId)
        put("widthPx", profile.size.width)
        put("heightPx", profile.size.height)
        put("sampleAspectRatio", buildJsonObject {
            put("width", profile.sampleAspectRatio.width)
            put("height", profile.sampleAspectRatio.height)
        })
        put("fps", profile.frameRate)
        put("bitrateBps", profile.bitRate)
        put("profile", "main")
        put("levelIdc", 120)
        put("rotationDegrees", profile.rotationDegrees)
        put("clockRate", 90_000)
        put("noBFrames", true)
    }

    override fun onDataPathLost(peerId: String) {
        closeTransport()
        if (machine.state == SessionState.CONNECTED) safeApply(SessionEvent.CONTROL_LOST)
        updateUi { it.copy(dataPath = null, status = "连接中断，可重试或结束") }
    }

    override fun onFailure(failure: AwareFailure) {
        when {
            failure is AwareFailure.PairingFailed && machine.state == SessionState.PAIRING -> safeApply(SessionEvent.PAIRING_FAILED)
            failure is AwareFailure.DataPathFailed && machine.state == SessionState.CONNECTING -> safeApply(SessionEvent.TRANSPORT_FAILED)
            failure is AwareFailure.CurrentlyUnavailable -> safeApply(SessionEvent.CAPABILITY_LOST)
        }
        updateUi { it.copy(status = failure.toUserMessage()) }
    }

    private fun stopPreviewMedia() {
        previewStreaming.set(false)
        heartbeatJob?.cancel()
        heartbeatJob = null
        encoderOutput?.close()
        encoderOutput = null
        udpSender?.close()
        udpSender = null
        udpReceiver?.close()
        udpReceiver = null
        rtcpReceiver?.close()
        rtcpReceiver = null
        rtcpReporter?.close()
        rtcpReporter = null
        synchronized(mediaLock) {
            decoder?.close()
            decoder = null
            monitorProfile = null
            monitorParameterSets = null
            monitorParameterNals.clear()
        }
        encoderParameterSets = null
        updateUi { it.copy(cameraVideoOutput = null, negotiatedProfile = null) }
    }

    private fun closeTransport() {
        val previouslyClosing = closingTransport
        closingTransport = true
        stopPreviewMedia()
        serverControl?.close()
        serverControl = null
        sessionClient?.close()
        sessionClient = null
        sessionServer?.close()
        sessionServer = null
        accessToken = null
        cameraSessionId = null
        monitorSessionId = null
        activeConfigId = null
        updateUi { it.copy(dataPath = null) }
        closingTransport = previouslyClosing
    }

    @Synchronized
    private fun safeApply(event: SessionEvent) {
        try {
            machine.apply(event)
            updateUi { it.copy(sessionState = machine.state) }
        } catch (_: InvalidSessionTransition) {
            Unit
        }
    }

    private fun nextRequestId(prefix: String): String = "$prefix-${requestIds.getAndIncrement()}"

    private fun randomUnsignedNonZero(): Long = (random.nextInt().toLong() and 0xffff_ffffL).coerceAtLeast(1)

    private fun JsonObject.int(name: String): Int = this[name]!!.jsonPrimitive.int

    private fun updateUi(transform: (RemoteCamUiState) -> RemoteCamUiState) = synchronized(_uiState) {
        _uiState.value = transform(_uiState.value)
    }

    override fun onCleared() {
        closingTransport = true
        closeTransport()
        awareController?.close()
        synchronized(photoLock) { photoResources.close() }
        super.onCleared()
    }
}

private fun AwareFailure.toUserMessage(): String = when (this) {
    AwareFailure.Unsupported -> "此设备不支持 Wi‑Fi Aware"
    AwareFailure.CurrentlyUnavailable -> "Wi‑Fi Aware 当前不可用，请确认 Wi‑Fi 已开启"
    AwareFailure.PermissionDenied -> "附近设备权限被拒绝，请在系统设置中允许后重试"
    AwareFailure.AttachFailed -> "无法启动 Wi‑Fi Aware，请稍后重试"
    AwareFailure.DiscoveryFailed -> "服务发现失败；可能没有可用的 Aware 会话资源"
    AwareFailure.PairingFailed -> "配对失败，请确认对端后重试"
    is AwareFailure.DataPathFailed -> "安全数据路径失败：$detail"
}
