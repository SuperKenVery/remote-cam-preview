package dev.remotecam.preview.aware

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.AwarePairingConfig
import android.net.wifi.aware.Characteristics
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.ServiceDiscoveryInfo
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareSession
import android.net.wifi.ScanResult
import android.os.Build
import android.os.Handler
import android.os.Looper
import dev.remotecam.preview.model.DeviceRole
import dev.remotecam.preview.model.DiscoveredPeer
import java.net.Inet6Address
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

const val WIFI_AWARE_SERVICE_NAME = "_remote-cam._tcp"

sealed interface AwareFailure {
    data object Unsupported : AwareFailure
    data object CurrentlyUnavailable : AwareFailure
    data object PermissionDenied : AwareFailure
    data object AttachFailed : AwareFailure
    data object DiscoveryFailed : AwareFailure
    data object PairingFailed : AwareFailure
    data class DataPathFailed(val detail: String) : AwareFailure
}

data class SecureDataPathCredential(val passphrase: String) {
    init {
        require(passphrase.length in 8..63) { "Wi-Fi Aware PSK passphrase must contain 8..63 characters" }
    }
}

data class AwareDataPath(
    val network: Network,
    val localAddress: Inet6Address?,
    val peerAddress: Inet6Address,
    val advertisedPeerPort: Int,
)

interface WifiAwareListener {
    fun onAttached() = Unit
    fun onPeerDiscovered(peer: DiscoveredPeer) = Unit
    fun onPeerConfirmationRequired(peer: DiscoveredPeer) = Unit
    fun onPairingStarted(peerId: String) = Unit
    fun onPairingVerified(peerId: String, alias: String?) = Unit
    fun onDataPathAvailable(peerId: String, dataPath: AwareDataPath) = Unit
    fun onDataPathLost(peerId: String) = Unit
    fun onFailure(failure: AwareFailure) = Unit
}

/**
 * Starts publish and subscribe concurrently. App role is carried as discovery metadata and is never
 * mapped to the Wi-Fi Aware publish/subscribe role.
 */
class WifiAwareController(
    private val awareManager: WifiAwareManager?,
    private val connectivityManager: ConnectivityManager,
    private val localRole: DeviceRole,
    private val listener: WifiAwareListener,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : AutoCloseable {
    private data class PeerRef(
        val id: String,
        val role: DeviceRole?,
        val handle: PeerHandle,
        val session: DiscoverySession,
        val pairingConfig: Any?,
        var alias: String?,
        var confirmed: Boolean = false,
        var incomingPairingRequest: Int? = null,
    )

    val localNodeId: String = UUID.randomUUID().toString()
    private val messageIds = AtomicInteger(1)
    private val peers = ConcurrentHashMap<String, PeerRef>()
    private val networkCallbacks = ConcurrentHashMap<String, ConnectivityManager.NetworkCallback>()
    private var awareSession: WifiAwareSession? = null
    private var publishSession: PublishDiscoverySession? = null
    private var subscribeSession: SubscribeDiscoverySession? = null

    fun attachAndDiscover() {
        val manager = awareManager ?: return listener.onFailure(AwareFailure.Unsupported)
        if (!manager.isAvailable) return listener.onFailure(AwareFailure.CurrentlyUnavailable)
        try {
            manager.attach(object : AttachCallback() {
                override fun onAttached(session: WifiAwareSession) {
                    awareSession = session
                    listener.onAttached()
                    startPublishAndSubscribe(session)
                }

                override fun onAttachFailed() = listener.onFailure(AwareFailure.AttachFailed)
            }, handler)
        } catch (_: SecurityException) {
            listener.onFailure(AwareFailure.PermissionDenied)
        }
    }

    fun confirmPeer(peerId: String) {
        val peer = peers[peerId] ?: return
        peer.confirmed = true
        listener.onPairingStarted(peerId)
        if (Build.VERSION.SDK_INT >= 34 && supportsPairing()) {
            val cipher = Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128
            val alias = peer.alias ?: "remote-cam-${peer.id.take(8)}"
            val requestId = peer.incomingPairingRequest
            try {
                if (requestId != null) {
                    peer.session.acceptPairingRequest(requestId, peer.handle, alias, cipher, "")
                } else if (peer.pairingConfig != null) {
                    peer.session.initiatePairingRequest(peer.handle, alias, cipher, "")
                } else {
                    // The elected publisher learns the subscriber through a follow-up message and
                    // has no ServiceDiscoveryInfo. It waits for that subscriber's pairing request.
                    return
                }
            } catch (_: RuntimeException) {
                listener.onFailure(AwareFailure.PairingFailed)
            }
        } else {
            // Android 31-33 can still make a PSK-secured NDP after explicit in-app confirmation.
            listener.onPairingVerified(peerId, peer.alias)
        }
    }

    /**
     * Requests an encrypted NDP. credential is mandatory: this implementation never creates an open
     * Wi-Fi Aware data path. Port metadata is attached only for a publisher acting as TCP server.
     */
    fun requestSecureDataPath(
        peerId: String,
        credential: SecureDataPathCredential,
        serverPort: Int? = null,
        transportProtocol: Int = 6,
    ) {
        val peer = peers[peerId] ?: return listener.onFailure(AwareFailure.DataPathFailed("Unknown peer"))
        if (!peer.confirmed) return listener.onFailure(AwareFailure.DataPathFailed("Peer has not been confirmed"))
        val specifierBuilder = WifiAwareNetworkSpecifier.Builder(peer.session, peer.handle)
            .setPskPassphrase(credential.passphrase)
        if (serverPort != null && peer.session is PublishDiscoverySession) {
            require(serverPort in 1..65535)
            specifierBuilder.setPort(serverPort).setTransportProtocol(transportProtocol)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifierBuilder.build())
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            private val stateLock = Any()
            private var currentNetwork: Network? = null
            private var localAddress: Inet6Address? = null
            private var peerAddress: Inet6Address? = null
            private var peerPort: Int? = null
            private var emitted = false

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val info = capabilities.transportInfo as? WifiAwareNetworkInfo ?: return
                val ready = synchronized(stateLock) {
                    selectNetworkLocked(network)
                    info.peerIpv6Addr?.let { peerAddress = it }
                    peerPort = info.port
                    updateLocalAddressLocked(connectivityManager.getLinkProperties(network))
                    readyDataPathLocked()
                }
                ready?.let { listener.onDataPathAvailable(peerId, it) }
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                val ready = synchronized(stateLock) {
                    selectNetworkLocked(network)
                    updateLocalAddressLocked(linkProperties)
                    readyDataPathLocked()
                }
                ready?.let { listener.onDataPathAvailable(peerId, it) }
            }

            override fun onLost(network: Network) {
                val wasEmitted = synchronized(stateLock) {
                    if (currentNetwork != network) return@synchronized false
                    val result = emitted
                    currentNetwork = null
                    localAddress = null
                    peerAddress = null
                    peerPort = null
                    emitted = false
                    result
                }
                if (wasEmitted) listener.onDataPathLost(peerId)
            }

            override fun onUnavailable() {
                listener.onFailure(AwareFailure.DataPathFailed("Secure Wi-Fi Aware network request unavailable"))
            }

            private fun selectNetworkLocked(network: Network) {
                if (currentNetwork == network) return
                currentNetwork = network
                localAddress = null
                peerAddress = null
                peerPort = null
                emitted = false
            }

            private fun updateLocalAddressLocked(linkProperties: LinkProperties?) {
                localAddress = linkProperties?.linkAddresses
                    ?.asSequence()
                    ?.map { it.address }
                    ?.filterIsInstance<Inet6Address>()
                    ?.firstOrNull { it.isLinkLocalAddress }
            }

            private fun readyDataPathLocked(): AwareDataPath? {
                if (emitted) return null
                val network = currentNetwork ?: return null
                val local = localAddress ?: return null
                val peer = peerAddress ?: return null
                val port = peerPort ?: return null
                if (localRole == DeviceRole.MONITOR && port !in 1..65_535) return null
                emitted = true
                return AwareDataPath(network, local, peer, port)
            }
        }
        networkCallbacks.remove(peerId)?.let { runCatching { connectivityManager.unregisterNetworkCallback(it) } }
        networkCallbacks[peerId] = callback
        try {
            connectivityManager.requestNetwork(request, callback, 15_000)
        } catch (error: RuntimeException) {
            networkCallbacks.remove(peerId)
            listener.onFailure(AwareFailure.DataPathFailed(error.message ?: "Network request failed"))
        }
    }

    private fun startPublishAndSubscribe(session: WifiAwareSession) {
        val serviceInfo = "v=1;id=$localNodeId;role=${localRole.name}".encodeToByteArray()
        val publish = PublishConfig.Builder()
            .setServiceName(WIFI_AWARE_SERVICE_NAME)
            .setServiceSpecificInfo(serviceInfo)
            .setTerminateNotificationEnabled(true)
        val subscribe = SubscribeConfig.Builder()
            .setServiceName(WIFI_AWARE_SERVICE_NAME)
            .setServiceSpecificInfo(serviceInfo)
            .setTerminateNotificationEnabled(true)
        if (Build.VERSION.SDK_INT >= 33 && awareManager?.characteristics?.isInstantCommunicationModeSupported == true) {
            publish.setInstantCommunicationModeEnabled(true, ScanResult.WIFI_BAND_5_GHZ)
            subscribe.setInstantCommunicationModeEnabled(true, ScanResult.WIFI_BAND_5_GHZ)
        }
        if (Build.VERSION.SDK_INT >= 34 && supportsPairing()) {
            val pairing = AwarePairingConfig.Builder()
                .setPairingSetupEnabled(true)
                .setPairingVerificationEnabled(true)
                .setPairingCacheEnabled(true)
                .setBootstrappingMethods(AwarePairingConfig.PAIRING_BOOTSTRAPPING_OPPORTUNISTIC)
                .build()
            publish.setPairingConfig(pairing)
            subscribe.setPairingConfig(pairing)
        }
        try {
            session.publish(publish.build(), callback(isPublisher = true, localInfo = serviceInfo), handler)
            session.subscribe(subscribe.build(), callback(isPublisher = false, localInfo = serviceInfo), handler)
        } catch (_: SecurityException) {
            listener.onFailure(AwareFailure.PermissionDenied)
        } catch (_: RuntimeException) {
            listener.onFailure(AwareFailure.DiscoveryFailed)
        }
    }

    private fun callback(isPublisher: Boolean, localInfo: ByteArray) = object : DiscoverySessionCallback() {
        private var discoverySession: DiscoverySession? = null

        override fun onPublishStarted(session: PublishDiscoverySession) {
            publishSession = session
            discoverySession = session
        }

        override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
            subscribeSession = session
            discoverySession = session
        }

        override fun onServiceDiscovered(info: ServiceDiscoveryInfo) {
            val session = discoverySession ?: return
            val hello = DiscoveryHello.parse(info.serviceSpecificInfo ?: byteArrayOf())
            if (hello?.nodeId == localNodeId) return
            val peerId = hello?.nodeId ?: fallbackPeerId(info.peerHandle)
            val peer = PeerRef(
                id = peerId,
                role = hello?.role,
                handle = info.peerHandle,
                session = session,
                pairingConfig = if (Build.VERSION.SDK_INT >= 34) info.pairingConfig else null,
                alias = if (Build.VERSION.SDK_INT >= 34) info.pairedAlias else null,
            )
            recordPeer(peer)
            session.sendMessage(info.peerHandle, messageIds.getAndIncrement(), localInfo)
        }

        @Suppress("DEPRECATION")
        override fun onServiceDiscovered(
            peerHandle: PeerHandle,
            serviceSpecificInfo: ByteArray,
            matchFilter: MutableList<ByteArray>,
        ) {
            val session = discoverySession ?: return
            val hello = DiscoveryHello.parse(serviceSpecificInfo)
            if (hello?.nodeId == localNodeId) return
            val peerId = hello?.nodeId ?: fallbackPeerId(peerHandle)
            val peer = PeerRef(peerId, hello?.role, peerHandle, session, null, null)
            recordPeer(peer)
            session.sendMessage(peerHandle, messageIds.getAndIncrement(), localInfo)
        }

        override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
            val session = discoverySession ?: return
            val hello = DiscoveryHello.parse(message)
            if (hello?.nodeId == localNodeId) return
            val peerId = hello?.nodeId ?: fallbackPeerId(peerHandle)
            recordPeer(PeerRef(peerId, hello?.role, peerHandle, session, null, null))
        }

        override fun onPairingSetupRequestReceived(peerHandle: PeerHandle, requestId: Int) {
            if (Build.VERSION.SDK_INT < 34) return
            val peer = findPeer(peerHandle) ?: return
            peer.incomingPairingRequest = requestId
            if (peer.confirmed) {
                val alias = peer.alias ?: "remote-cam-${peer.id.take(8)}"
                peer.session.acceptPairingRequest(
                    requestId,
                    peer.handle,
                    alias,
                    Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128,
                    "",
                )
            } else {
                listener.onPeerConfirmationRequired(peer.toPublic())
            }
        }

        override fun onPairingSetupSucceeded(peerHandle: PeerHandle, alias: String) {
            if (Build.VERSION.SDK_INT < 34) return
            val peer = findPeer(peerHandle) ?: return
            peer.alias = alias
            peer.confirmed = true
            listener.onPairingVerified(peer.id, alias)
        }

        override fun onPairingVerificationSucceed(peerHandle: PeerHandle, alias: String) {
            if (Build.VERSION.SDK_INT < 34) return
            val peer = findPeer(peerHandle) ?: return
            peer.alias = alias
            peer.confirmed = true
            listener.onPairingVerified(peer.id, alias)
        }

        override fun onPairingSetupFailed(peerHandle: PeerHandle) = listener.onFailure(AwareFailure.PairingFailed)
        override fun onPairingVerificationFailed(peerHandle: PeerHandle) = listener.onFailure(AwareFailure.PairingFailed)
        override fun onSessionConfigFailed() = listener.onFailure(AwareFailure.DiscoveryFailed)
        override fun onSessionTerminated() = Unit
    }

    private fun recordPeer(candidate: PeerRef) {
        // Both discovery modes are always active. Only the data-path candidate is selected this way
        // because Android can advertise the secure TCP server port solely from a publisher session.
        val candidateIsElected = when (localRole) {
            DeviceRole.CAMERA -> candidate.session is PublishDiscoverySession
            DeviceRole.MONITOR -> candidate.session is SubscribeDiscoverySession
        }
        if (!candidateIsElected) return
        val peer = peers.compute(candidate.id) { _, existing -> existing ?: candidate } ?: candidate
        emitPeer(peer)
    }

    private fun emitPeer(peer: PeerRef) {
        val public = peer.toPublic()
        listener.onPeerDiscovered(public)
        if (!peer.confirmed) listener.onPeerConfirmationRequired(public)
    }

    private fun PeerRef.toPublic() = DiscoveredPeer(id, role, alias, confirmed && alias != null)

    private fun findPeer(handle: PeerHandle): PeerRef? = peers.values.firstOrNull { it.handle == handle }

    private fun fallbackPeerId(peerHandle: PeerHandle): String = "peer-${peerHandle.hashCode().toUInt().toString(16)}"

    private fun supportsPairing(): Boolean =
        Build.VERSION.SDK_INT >= 34 && awareManager?.characteristics?.isAwarePairingSupported == true

    override fun close() {
        networkCallbacks.values.forEach { runCatching { connectivityManager.unregisterNetworkCallback(it) } }
        networkCallbacks.clear()
        publishSession?.close()
        subscribeSession?.close()
        awareSession?.close()
        publishSession = null
        subscribeSession = null
        awareSession = null
        peers.clear()
    }
}

private data class DiscoveryHello(val nodeId: String, val role: DeviceRole?) {
    companion object {
        fun parse(bytes: ByteArray): DiscoveryHello? {
            if (bytes.size !in 1..1024) return null
            val values = bytes.decodeToString().split(';').mapNotNull { entry ->
                val separator = entry.indexOf('=')
                if (separator <= 0) null else entry.substring(0, separator) to entry.substring(separator + 1)
            }.toMap()
            if (values["v"] != "1") return null
            val id = values["id"]?.takeIf { it.matches(Regex("[A-Za-z0-9-]{8,64}")) } ?: return null
            return DiscoveryHello(id, values["role"]?.let { runCatching { DeviceRole.valueOf(it) }.getOrNull() })
        }
    }
}

object EphemeralCredentials {
    private val random = SecureRandom()

    fun newSessionId(): String = UUID.randomUUID().toString()

    fun newAccessToken(): String = randomBytes(32)

    fun newDataPathCredential(): SecureDataPathCredential = SecureDataPathCredential(randomBytes(24))

    private fun randomBytes(count: Int): String = ByteArray(count).also(random::nextBytes).let {
        Base64.getUrlEncoder().withoutPadding().encodeToString(it)
    }
}
