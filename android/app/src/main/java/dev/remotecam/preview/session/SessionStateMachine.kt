package dev.remotecam.preview.session

enum class SessionState(val wireName: String) {
    UNPAIRED("unpaired"),
    DISCOVERING("discovering"),
    PAIRING("pairing"),
    CONNECTING("connecting"),
    CONNECTED("connected"),
    INTERRUPTED("interrupted"),
    UNAVAILABLE("unavailable"),
    ENDED("ended");

    companion object {
        fun fromWireName(value: String): SessionState = entries.firstOrNull { it.wireName == value }
            ?: throw IllegalArgumentException("Unknown session state $value")
    }
}

enum class SessionEvent(val wireName: String) {
    START_DISCOVERY("startDiscovery"),
    PEER_SELECTED("peerSelected"),
    PAIRING_SUCCEEDED("pairingSucceeded"),
    PAIRING_FAILED("pairingFailed"),
    TRANSPORT_CONNECTED("transportConnected"),
    TRANSPORT_FAILED("transportFailed"),
    CONTROL_LOST("controlLost"),
    RETRY("retry"),
    CAPABILITY_LOST("capabilityLost"),
    CAPABILITY_RESTORED("capabilityRestored"),
    END("end");

    companion object {
        fun fromWireName(value: String): SessionEvent = entries.firstOrNull { it.wireName == value }
            ?: throw UnknownSessionEvent(value)
    }
}

class UnknownSessionEvent(value: String) : IllegalArgumentException("UNKNOWN_STATE_EVENT: $value")

class InvalidSessionTransition(
    val from: SessionState,
    val event: SessionEvent,
) : IllegalStateException("INVALID_STATE_TRANSITION: $from + $event")

class SessionStateMachine(initial: SessionState = SessionState.UNPAIRED) {
    var state: SessionState = initial
        private set

    fun apply(wireEvent: String): SessionState = apply(SessionEvent.fromWireName(wireEvent))

    fun apply(event: SessionEvent): SessionState {
        val target = when (state to event) {
            SessionState.UNPAIRED to SessionEvent.START_DISCOVERY -> SessionState.DISCOVERING
            SessionState.DISCOVERING to SessionEvent.PEER_SELECTED -> SessionState.PAIRING
            SessionState.PAIRING to SessionEvent.PAIRING_SUCCEEDED -> SessionState.CONNECTING
            SessionState.PAIRING to SessionEvent.PAIRING_FAILED -> SessionState.INTERRUPTED
            SessionState.CONNECTING to SessionEvent.TRANSPORT_CONNECTED -> SessionState.CONNECTED
            SessionState.CONNECTING to SessionEvent.TRANSPORT_FAILED -> SessionState.INTERRUPTED
            SessionState.CONNECTED to SessionEvent.CONTROL_LOST -> SessionState.INTERRUPTED
            SessionState.INTERRUPTED to SessionEvent.RETRY -> SessionState.DISCOVERING
            SessionState.UNAVAILABLE to SessionEvent.CAPABILITY_RESTORED -> SessionState.UNPAIRED
            else -> when {
                event == SessionEvent.CAPABILITY_LOST && state !in setOf(SessionState.UNAVAILABLE, SessionState.ENDED) ->
                    SessionState.UNAVAILABLE
                event == SessionEvent.END && state != SessionState.ENDED -> SessionState.ENDED
                else -> throw InvalidSessionTransition(state, event)
            }
        }
        state = target
        return target
    }
}
