"""Normative session lifecycle state machine for both app roles."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

from .errors import ProtocolViolation


class SessionState(str, Enum):
    UNPAIRED = "unpaired"
    DISCOVERING = "discovering"
    PAIRING = "pairing"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    INTERRUPTED = "interrupted"
    UNAVAILABLE = "unavailable"
    ENDED = "ended"


class SessionEvent(str, Enum):
    START_DISCOVERY = "startDiscovery"
    PEER_SELECTED = "peerSelected"
    PAIRING_SUCCEEDED = "pairingSucceeded"
    PAIRING_FAILED = "pairingFailed"
    TRANSPORT_CONNECTED = "transportConnected"
    TRANSPORT_FAILED = "transportFailed"
    CONTROL_LOST = "controlLost"
    RETRY = "retry"
    CAPABILITY_LOST = "capabilityLost"
    CAPABILITY_RESTORED = "capabilityRestored"
    END = "end"


TRANSITIONS: dict[tuple[SessionState, SessionEvent], SessionState] = {
    (SessionState.UNPAIRED, SessionEvent.START_DISCOVERY): SessionState.DISCOVERING,
    (SessionState.DISCOVERING, SessionEvent.PEER_SELECTED): SessionState.PAIRING,
    (SessionState.PAIRING, SessionEvent.PAIRING_SUCCEEDED): SessionState.CONNECTING,
    (SessionState.PAIRING, SessionEvent.PAIRING_FAILED): SessionState.INTERRUPTED,
    (SessionState.CONNECTING, SessionEvent.TRANSPORT_CONNECTED): SessionState.CONNECTED,
    (SessionState.CONNECTING, SessionEvent.TRANSPORT_FAILED): SessionState.INTERRUPTED,
    (SessionState.CONNECTED, SessionEvent.CONTROL_LOST): SessionState.INTERRUPTED,
    (SessionState.INTERRUPTED, SessionEvent.RETRY): SessionState.DISCOVERING,
    (SessionState.UNAVAILABLE, SessionEvent.CAPABILITY_RESTORED): SessionState.UNPAIRED,
}

for _state in SessionState:
    if _state not in {SessionState.UNAVAILABLE, SessionState.ENDED}:
        TRANSITIONS[(_state, SessionEvent.CAPABILITY_LOST)] = SessionState.UNAVAILABLE
    if _state is not SessionState.ENDED:
        TRANSITIONS[(_state, SessionEvent.END)] = SessionState.ENDED


@dataclass
class SessionStateMachine:
    """Small deterministic machine; invalid transitions never mutate state."""

    state: SessionState = SessionState.UNPAIRED
    history: list[tuple[SessionState, SessionEvent, SessionState]] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not isinstance(self.state, SessionState):
            self.state = SessionState(self.state)

    def apply(self, event: SessionEvent | str) -> SessionState:
        try:
            normalized = event if isinstance(event, SessionEvent) else SessionEvent(event)
        except ValueError:
            raise ProtocolViolation("UNKNOWN_STATE_EVENT", f"unknown session event {event!r}") from None
        target = TRANSITIONS.get((self.state, normalized))
        if target is None:
            raise ProtocolViolation(
                "INVALID_STATE_TRANSITION",
                f"event {normalized.value!r} is invalid in state {self.state.value!r}",
            )
        previous = self.state
        self.state = target
        self.history.append((previous, normalized, target))
        return target

