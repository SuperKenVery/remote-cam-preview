"""Bounded JSON control-message parsing and idempotency for protocol v1."""

from __future__ import annotations

import hashlib
import json
import math
import re
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from .errors import ProtocolViolation

PROTOCOL_VERSION = "1.0"
SUPPORTED_MAJOR_VERSION = 1

# These limits apply after WebSocket reassembly. Implementations should reject a
# frame/message before allocation whenever their networking API exposes its size.
MAX_CONTROL_MESSAGE_BYTES = 65_536
MAX_JSON_DEPTH = 16
MAX_JSON_NODES = 4_096
MAX_OBJECT_MEMBERS = 128
MAX_ARRAY_ITEMS = 256
MAX_STRING_BYTES = 4_096
MAX_KEY_BYTES = 128
MAX_NUMBER_CHARACTERS = 64

REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._~-]{1,64}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
CONFIG_ID_RE = re.compile(r"^[A-Za-z0-9._~-]{1,64}$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
ERROR_CODE_RE = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
WIFI_AWARE_TCP_SERVICE_RE = re.compile(r"^_[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?\._tcp$")

KNOWN_MESSAGE_TYPES = frozenset(
    {
        "session.hello",
        "session.accepted",
        "preview.start",
        "preview.stop",
        "preview.reconfigure",
        "preview.tierRequest",
        "preview.poseGuide",
        "photo.receivePreference",
        "photo.captured",
        "photo.available",
        "photo.transferResult",
        "heartbeat.ping",
        "heartbeat.pong",
        "keyframe.request",
        "error",
        "session.end",
    }
)


def _fail(code: str, message: str) -> None:
    raise ProtocolViolation(code, message)


def _utf8_len(value: str, field: str) -> int:
    try:
        return len(value.encode("utf-8", errors="strict"))
    except UnicodeEncodeError:
        _fail("INVALID_UNICODE", f"{field} contains an unpaired surrogate")


def _reject_constant(value: str) -> None:
    _fail("INVALID_JSON", f"non-finite JSON number {value!r} is forbidden")


def _bounded_int(value: str) -> int:
    if len(value.lstrip("-")) > MAX_NUMBER_CHARACTERS:
        _fail("JSON_RESOURCE_LIMIT", "JSON integer has too many digits")
    return int(value)


def _bounded_float(value: str) -> float:
    if len(value) > MAX_NUMBER_CHARACTERS:
        _fail("JSON_RESOURCE_LIMIT", "JSON number representation is too long")
    return float(value)


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("DUPLICATE_JSON_KEY", f"duplicate object key {key!r}")
        result[key] = value
    return result


def _walk_json_limits(value: Any) -> None:
    nodes = 0

    def walk(item: Any, depth: int, path: str) -> None:
        nonlocal nodes
        nodes += 1
        if nodes > MAX_JSON_NODES:
            _fail("JSON_RESOURCE_LIMIT", f"JSON exceeds {MAX_JSON_NODES} nodes")
        if depth > MAX_JSON_DEPTH:
            _fail("JSON_RESOURCE_LIMIT", f"JSON nesting exceeds {MAX_JSON_DEPTH}")

        if isinstance(item, dict):
            if len(item) > MAX_OBJECT_MEMBERS:
                _fail(
                    "JSON_RESOURCE_LIMIT",
                    f"{path} exceeds {MAX_OBJECT_MEMBERS} object members",
                )
            for key, child in item.items():
                if not isinstance(key, str):
                    _fail("INVALID_JSON", f"{path} contains a non-string key")
                if _utf8_len(key, f"{path} key") > MAX_KEY_BYTES:
                    _fail("JSON_RESOURCE_LIMIT", f"{path} contains an oversized key")
                walk(child, depth + 1, f"{path}.{key}")
        elif isinstance(item, list):
            if len(item) > MAX_ARRAY_ITEMS:
                _fail(
                    "JSON_RESOURCE_LIMIT",
                    f"{path} exceeds {MAX_ARRAY_ITEMS} array items",
                )
            for index, child in enumerate(item):
                walk(child, depth + 1, f"{path}[{index}]")
        elif isinstance(item, str):
            if _utf8_len(item, path) > MAX_STRING_BYTES:
                _fail("JSON_RESOURCE_LIMIT", f"{path} string is too long")
        elif isinstance(item, float):
            if not math.isfinite(item):
                _fail("INVALID_JSON", f"{path} is non-finite")
        elif isinstance(item, int) and not isinstance(item, bool):
            if len(str(abs(item))) > MAX_NUMBER_CHARACTERS:
                _fail("JSON_RESOURCE_LIMIT", f"{path} integer has too many digits")
        elif item is None or isinstance(item, bool):
            return
        else:
            _fail("INVALID_JSON", f"{path} has unsupported JSON value")

    walk(value, 0, "$")


def decode_control_message(data: bytes | str) -> dict[str, Any]:
    """Decode and validate one complete UTF-8 JSON WebSocket message."""

    if isinstance(data, bytes):
        if len(data) > MAX_CONTROL_MESSAGE_BYTES:
            _fail("MESSAGE_TOO_LARGE", "control message exceeds 65536 bytes")
        try:
            text = data.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            _fail("INVALID_UTF8", "control message is not strict UTF-8")
    elif isinstance(data, str):
        if _utf8_len(data, "control message") > MAX_CONTROL_MESSAGE_BYTES:
            _fail("MESSAGE_TOO_LARGE", "control message exceeds 65536 bytes")
        text = data
    else:
        _fail("INVALID_MESSAGE", "control input must be bytes or str")

    try:
        parsed = json.loads(
            text,
            object_pairs_hook=_object_without_duplicate_keys,
            parse_constant=_reject_constant,
            parse_int=_bounded_int,
            parse_float=_bounded_float,
        )
    except ProtocolViolation:
        raise
    except (json.JSONDecodeError, RecursionError, ValueError) as exc:
        _fail("INVALID_JSON", f"malformed JSON: {exc}")

    _walk_json_limits(parsed)
    return validate_control_message(parsed)


def encode_control_message(message: Mapping[str, Any]) -> bytes:
    """Validate and canonically encode a control message for testability."""

    validated = validate_control_message(dict(message))
    try:
        encoded = json.dumps(
            validated,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8", errors="strict")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        _fail("INVALID_MESSAGE", f"message is not encodable JSON: {exc}")
    if len(encoded) > MAX_CONTROL_MESSAGE_BYTES:
        _fail("MESSAGE_TOO_LARGE", "control message exceeds 65536 bytes")
    return encoded


def _object(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail("INVALID_FIELD", f"{path} must be an object")
    return value


def _required(obj: Mapping[str, Any], field: str, path: str) -> Any:
    if field not in obj:
        _fail("MISSING_FIELD", f"{path}.{field} is required")
    return obj[field]


def _string(
    value: Any,
    path: str,
    *,
    min_bytes: int = 1,
    max_bytes: int = MAX_STRING_BYTES,
    pattern: re.Pattern[str] | None = None,
) -> str:
    if not isinstance(value, str):
        _fail("INVALID_FIELD", f"{path} must be a string")
    size = _utf8_len(value, path)
    if not min_bytes <= size <= max_bytes:
        _fail("INVALID_FIELD", f"{path} UTF-8 length is out of range")
    if pattern is not None and pattern.fullmatch(value) is None:
        _fail("INVALID_FIELD", f"{path} has an invalid format")
    return value


def _integer(value: Any, path: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail("INVALID_FIELD", f"{path} must be an integer")
    if not minimum <= value <= maximum:
        _fail("INVALID_FIELD", f"{path} is out of range [{minimum}, {maximum}]")
    return value


def _boolean(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        _fail("INVALID_FIELD", f"{path} must be a boolean")
    return value


def _enum(value: Any, path: str, allowed: set[str]) -> str:
    if not isinstance(value, str) or value not in allowed:
        _fail("INVALID_FIELD", f"{path} must be one of {sorted(allowed)}")
    return value


def _const(value: Any, path: str, expected: Any) -> None:
    if value != expected or type(value) is not type(expected):
        _fail("INVALID_FIELD", f"{path} must equal {expected!r}")


def _validate_preview_configuration(value: Any, path: str = "$.payload.preview") -> None:
    preview = _object(value, path)
    _string(_required(preview, "configId", path), f"{path}.configId", pattern=CONFIG_ID_RE)
    _integer(_required(preview, "widthPx", path), f"{path}.widthPx", 16, 16_384)
    _integer(_required(preview, "heightPx", path), f"{path}.heightPx", 16, 16_384)
    aspect = _object(_required(preview, "sampleAspectRatio", path), f"{path}.sampleAspectRatio")
    _integer(
        _required(aspect, "width", f"{path}.sampleAspectRatio"),
        f"{path}.sampleAspectRatio.width",
        1,
        65_535,
    )
    _integer(
        _required(aspect, "height", f"{path}.sampleAspectRatio"),
        f"{path}.sampleAspectRatio.height",
        1,
        65_535,
    )
    _integer(_required(preview, "fps", path), f"{path}.fps", 1, 240)
    _integer(
        _required(preview, "bitrateBps", path),
        f"{path}.bitrateBps",
        100_000,
        200_000_000,
    )
    _enum(_required(preview, "profile", path), f"{path}.profile", {"main", "main10"})
    _integer(_required(preview, "levelIdc", path), f"{path}.levelIdc", 30, 186)
    rotation = _integer(
        _required(preview, "rotationDegrees", path),
        f"{path}.rotationDegrees",
        0,
        270,
    )
    if rotation not in {0, 90, 180, 270}:
        _fail("INVALID_FIELD", f"{path}.rotationDegrees must be 0, 90, 180, or 270")
    _const(_required(preview, "clockRate", path), f"{path}.clockRate", 90_000)
    _const(_required(preview, "noBFrames", path), f"{path}.noBFrames", True)


def _validate_rtp(value: Any, path: str = "$.payload.rtp") -> None:
    rtp = _object(value, path)
    _string(_required(rtp, "destinationAddress", path), f"{path}.destinationAddress", max_bytes=255)
    _integer(_required(rtp, "rtpPort", path), f"{path}.rtpPort", 1, 65_535)
    _integer(_required(rtp, "rtcpPort", path), f"{path}.rtcpPort", 1, 65_535)
    _integer(_required(rtp, "payloadType", path), f"{path}.payloadType", 96, 127)
    _integer(_required(rtp, "ssrc", path), f"{path}.ssrc", 1, 0xFFFFFFFF)
    _integer(
        _required(rtp, "maxRtpPacketSize", path),
        f"{path}.maxRtpPacketSize",
        256,
        65_507,
    )


def _validate_session_hello(payload: dict[str, Any]) -> None:
    path = "$.payload"
    _const(_required(payload, "role", path), f"{path}.role", "monitor")
    _string(_required(payload, "sessionId", path), f"{path}.sessionId", pattern=TOKEN_RE)
    versions = _required(payload, "supportedProtocolVersions", path)
    if not isinstance(versions, list) or not 1 <= len(versions) <= 8:
        _fail("INVALID_FIELD", f"{path}.supportedProtocolVersions must contain 1..8 versions")
    seen: set[str] = set()
    for index, version in enumerate(versions):
        parsed = _string(version, f"{path}.supportedProtocolVersions[{index}]", max_bytes=16)
        if VERSION_RE.fullmatch(parsed) is None or parsed in seen:
            _fail("INVALID_FIELD", f"{path}.supportedProtocolVersions contains an invalid/duplicate version")
        seen.add(parsed)

    display = _object(_required(payload, "display", path), f"{path}.display")
    for field in ("nativeWidthPx", "nativeHeightPx", "viewportWidthPx", "viewportHeightPx"):
        _integer(_required(display, field, f"{path}.display"), f"{path}.display.{field}", 1, 16_384)
    _enum(
        _required(display, "orientation", f"{path}.display"),
        f"{path}.display.orientation",
        {"portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"},
    )

    hevc = _object(_required(payload, "hevc", path), f"{path}.hevc")
    profiles = _required(hevc, "profiles", f"{path}.hevc")
    if not isinstance(profiles, list) or not 1 <= len(profiles) <= 2:
        _fail("INVALID_FIELD", f"{path}.hevc.profiles must contain 1..2 profiles")
    if any(profile not in {"main", "main10"} for profile in profiles) or len(set(profiles)) != len(profiles):
        _fail("INVALID_FIELD", f"{path}.hevc.profiles is invalid")
    _integer(_required(hevc, "maxWidthPx", f"{path}.hevc"), f"{path}.hevc.maxWidthPx", 16, 16_384)
    _integer(_required(hevc, "maxHeightPx", f"{path}.hevc"), f"{path}.hevc.maxHeightPx", 16, 16_384)
    _integer(_required(hevc, "maxFps", f"{path}.hevc"), f"{path}.hevc.maxFps", 1, 240)
    _integer(_required(hevc, "maxLevelIdc", f"{path}.hevc"), f"{path}.hevc.maxLevelIdc", 30, 186)
    _boolean(_required(payload, "photoReceiveEnabled", path), f"{path}.photoReceiveEnabled")


def _validate_session_accepted(payload: dict[str, Any]) -> None:
    path = "$.payload"
    _const(_required(payload, "role", path), f"{path}.role", "capture")
    _string(_required(payload, "sessionId", path), f"{path}.sessionId", pattern=TOKEN_RE)
    _string(_required(payload, "accessToken", path), f"{path}.accessToken", pattern=TOKEN_RE)
    _validate_preview_configuration(_required(payload, "preview", path))
    _validate_rtp(_required(payload, "rtp", path))
    photo_endpoint = _object(_required(payload, "photoEndpoint", path), f"{path}.photoEndpoint")
    has_port = "port" in photo_endpoint
    has_service = "serviceName" in photo_endpoint
    if has_port == has_service:
        _fail(
            "INVALID_FIELD",
            f"{path}.photoEndpoint must contain exactly one of port or serviceName",
        )
    if has_port:
        _integer(photo_endpoint["port"], f"{path}.photoEndpoint.port", 1, 65_535)
    else:
        _string(
            photo_endpoint["serviceName"],
            f"{path}.photoEndpoint.serviceName",
            max_bytes=22,
            pattern=WIFI_AWARE_TCP_SERVICE_RE,
        )


def _validate_payload(message_type: str, payload: dict[str, Any]) -> None:
    path = "$.payload"
    if message_type == "session.hello":
        _validate_session_hello(payload)
    elif message_type == "session.accepted":
        _validate_session_accepted(payload)
    elif message_type == "preview.start":
        _string(_required(payload, "configId", path), f"{path}.configId", pattern=CONFIG_ID_RE)
    elif message_type == "preview.stop":
        _enum(_required(payload, "reason", path), f"{path}.reason", {"user", "reconfigure", "controlLost", "sessionEnd", "error"})
    elif message_type == "preview.reconfigure":
        _validate_preview_configuration(_required(payload, "preview", path))
        _enum(_required(payload, "reason", path), f"{path}.reason", {"orientation", "viewport", "decoderLimit", "linkTier", "manual"})
    elif message_type == "preview.tierRequest":
        _integer(_required(payload, "maxBitrateBps", path), f"{path}.maxBitrateBps", 100_000, 200_000_000)
        if "maxWidthPx" in payload:
            _integer(payload["maxWidthPx"], f"{path}.maxWidthPx", 16, 16_384)
        if "maxHeightPx" in payload:
            _integer(payload["maxHeightPx"], f"{path}.maxHeightPx", 16, 16_384)
    elif message_type == "preview.poseGuide":
        _integer(_required(payload, "guideId", path), f"{path}.guideId", 0, 5)
    elif message_type == "photo.receivePreference":
        _boolean(_required(payload, "enabled", path), f"{path}.enabled")
    elif message_type == "photo.captured":
        _string(_required(payload, "captureId", path), f"{path}.captureId", pattern=CONFIG_ID_RE)
        _boolean(_required(payload, "savedLocally", path), f"{path}.savedLocally")
    elif message_type == "photo.available":
        from .photo import validate_photo_metadata

        validate_photo_metadata(_required(payload, "metadata", path))
        _integer(_required(payload, "expiresInSeconds", path), f"{path}.expiresInSeconds", 1, 3_600)
    elif message_type == "photo.transferResult":
        _string(_required(payload, "photoId", path), f"{path}.photoId", pattern=TOKEN_RE)
        status = _enum(_required(payload, "status", path), f"{path}.status", {"saved", "failed", "cancelled"})
        if status != "saved":
            _string(_required(payload, "errorCode", path), f"{path}.errorCode", max_bytes=64, pattern=ERROR_CODE_RE)
    elif message_type in {"heartbeat.ping", "heartbeat.pong"}:
        _integer(_required(payload, "sentAtMs", path), f"{path}.sentAtMs", 0, (1 << 63) - 1)
    elif message_type == "keyframe.request":
        _integer(_required(payload, "mediaSsrc", path), f"{path}.mediaSsrc", 1, 0xFFFFFFFF)
        _enum(_required(payload, "reason", path), f"{path}.reason", {"startup", "loss", "decoderReset", "reconfigure"})
    elif message_type == "error":
        _string(_required(payload, "code", path), f"{path}.code", max_bytes=64, pattern=ERROR_CODE_RE)
        _string(_required(payload, "message", path), f"{path}.message", max_bytes=1_024)
        _boolean(_required(payload, "retryable", path), f"{path}.retryable")
        if "relatedRequestId" in payload:
            _string(payload["relatedRequestId"], f"{path}.relatedRequestId", max_bytes=64, pattern=REQUEST_ID_RE)
    elif message_type == "session.end":
        _enum(_required(payload, "reason", path), f"{path}.reason", {"user", "controlLost", "unavailable", "error"})


def validate_control_message(message: Any) -> dict[str, Any]:
    """Validate v1 envelope and message-specific required fields.

    Unknown fields are deliberately preserved and ignored so v1 minor additions are
    forward-compatible. Unknown message types are not optional fields and are rejected.
    """

    _walk_json_limits(message)
    obj = _object(message, "$")
    message_type = _string(_required(obj, "type", "$"), "$.type", max_bytes=64)
    if message_type not in KNOWN_MESSAGE_TYPES:
        _fail("UNSUPPORTED_MESSAGE_TYPE", f"unknown control message type {message_type!r}")
    _string(_required(obj, "requestId", "$"), "$.requestId", max_bytes=64, pattern=REQUEST_ID_RE)
    version = _string(_required(obj, "protocolVersion", "$"), "$.protocolVersion", max_bytes=16)
    match = VERSION_RE.fullmatch(version)
    if match is None:
        _fail("INVALID_PROTOCOL_VERSION", "protocolVersion must be MAJOR.MINOR")
    if int(match.group(1)) != SUPPORTED_MAJOR_VERSION:
        _fail("UNSUPPORTED_PROTOCOL_VERSION", f"unsupported protocol major version {match.group(1)}")
    payload = _object(_required(obj, "payload", "$"), "$.payload")
    _validate_payload(message_type, payload)
    return obj


@dataclass(frozen=True)
class DuplicateResult:
    """Result of observing a request ID in the bounded idempotency ledger."""

    is_duplicate: bool
    cached_response: Any | None = None


@dataclass
class _LedgerEntry:
    digest: bytes
    expires_at: float
    response: Any | None = None


class RequestLedger:
    """Bounded TTL ledger used to reject conflicting request-ID reuse.

    A duplicate with identical canonical JSON receives the cached response once the
    first request completes. A reused ID with different content is a protocol error.
    """

    def __init__(
        self,
        *,
        capacity: int = 1_024,
        ttl_seconds: float = 120.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if not 1 <= capacity <= 65_536:
            raise ValueError("capacity must be in [1, 65536]")
        if not 1.0 <= ttl_seconds <= 3_600.0:
            raise ValueError("ttl_seconds must be in [1, 3600]")
        self._capacity = capacity
        self._ttl = ttl_seconds
        self._clock = clock
        self._entries: OrderedDict[str, _LedgerEntry] = OrderedDict()

    @staticmethod
    def _digest(message: Mapping[str, Any]) -> bytes:
        canonical = encode_control_message(message)
        return hashlib.sha256(canonical).digest()

    def _prune(self, now: float) -> None:
        expired = [key for key, entry in self._entries.items() if entry.expires_at <= now]
        for key in expired:
            del self._entries[key]

    def observe(self, message: Mapping[str, Any]) -> DuplicateResult:
        validated = validate_control_message(dict(message))
        request_id = validated["requestId"]
        digest = self._digest(validated)
        now = self._clock()
        self._prune(now)

        existing = self._entries.get(request_id)
        if existing is not None:
            self._entries.move_to_end(request_id)
            if existing.digest != digest:
                _fail(
                    "DUPLICATE_REQUEST_CONFLICT",
                    f"requestId {request_id!r} was reused with different content",
                )
            replay = (
                None
                if existing.response is None
                else json.loads(json.dumps(existing.response, allow_nan=False))
            )
            return DuplicateResult(True, replay)

        while len(self._entries) >= self._capacity:
            self._entries.popitem(last=False)
        self._entries[request_id] = _LedgerEntry(digest, now + self._ttl)
        return DuplicateResult(False, None)

    def complete(self, request_id: str, response: Any) -> None:
        entry = self._entries.get(request_id)
        if entry is None:
            _fail("UNKNOWN_REQUEST_ID", f"requestId {request_id!r} is not pending")
        # Responses are trusted locally but copied through JSON to prevent later
        # mutation of the caller's object from changing the replayed result.
        try:
            entry.response = json.loads(json.dumps(response, allow_nan=False))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"response is not JSON-compatible: {exc}") from exc
