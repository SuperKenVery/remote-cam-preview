"""Bounded photo metadata and streaming SHA-256 integrity verification."""

from __future__ import annotations

import hashlib
import hmac
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Callable, Mapping

from .errors import ProtocolViolation

MAX_PHOTO_BYTES = 512 * 1024 * 1024
DEFAULT_CHUNK_BYTES = 64 * 1024
PHOTO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
UNSAFE_FILENAME_RE = re.compile(r"[\x00-\x1f\x7f/\\]")
MIME_TYPES = frozenset({"image/jpeg", "image/heic", "image/heif", "image/dng", "image/x-adobe-dng"})


def _fail(code: str, message: str) -> None:
    raise ProtocolViolation(code, message)


def _required(metadata: Mapping[str, Any], field: str) -> Any:
    if field not in metadata:
        _fail("MISSING_FIELD", f"photo metadata field {field!r} is required")
    return metadata[field]


def _integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        _fail("INVALID_PHOTO_METADATA", f"{field} must be an integer in [{minimum}, {maximum}]")
    return value


def _string(value: Any, field: str, maximum_utf8_bytes: int) -> str:
    if not isinstance(value, str):
        _fail("INVALID_PHOTO_METADATA", f"{field} must be a string")
    try:
        size = len(value.encode("utf-8", errors="strict"))
    except UnicodeEncodeError:
        _fail("INVALID_PHOTO_METADATA", f"{field} contains invalid Unicode")
    if not 1 <= size <= maximum_utf8_bytes:
        _fail("INVALID_PHOTO_METADATA", f"{field} UTF-8 length is out of range")
    return value


def validate_photo_metadata(value: Any) -> dict[str, Any]:
    """Validate untrusted metadata while preserving unknown optional fields."""

    if not isinstance(value, dict):
        _fail("INVALID_PHOTO_METADATA", "photo metadata must be an object")
    if len(value) > 32:
        _fail("PHOTO_RESOURCE_LIMIT", "photo metadata has too many fields")
    metadata = value
    photo_id = _string(_required(metadata, "photoId"), "photoId", 128)
    if PHOTO_ID_RE.fullmatch(photo_id) is None:
        _fail("INVALID_PHOTO_METADATA", "photoId must be 16..128 base64url characters")
    filename = _string(_required(metadata, "fileName"), "fileName", 255)
    if filename in {".", ".."} or UNSAFE_FILENAME_RE.search(filename):
        _fail("INVALID_PHOTO_METADATA", "fileName must be a single safe path component")
    mime_type = _string(_required(metadata, "mimeType"), "mimeType", 64)
    if mime_type not in MIME_TYPES:
        _fail("UNSUPPORTED_PHOTO_MIME", f"unsupported photo MIME type {mime_type!r}")
    _integer(_required(metadata, "byteSize"), "byteSize", 1, MAX_PHOTO_BYTES)
    _integer(_required(metadata, "widthPx"), "widthPx", 1, 65_535)
    _integer(_required(metadata, "heightPx"), "heightPx", 1, 65_535)
    expected_hash = _string(_required(metadata, "sha256"), "sha256", 64)
    if SHA256_RE.fullmatch(expected_hash) is None:
        _fail("INVALID_PHOTO_METADATA", "sha256 must be 64 lowercase hexadecimal characters")
    path = _string(_required(metadata, "downloadPath"), "downloadPath", 255)
    if path != f"/v1/photos/{photo_id}":
        _fail("INVALID_PHOTO_METADATA", "downloadPath must match photoId under /v1/photos/")
    return metadata


@dataclass(frozen=True)
class VerificationResult:
    byte_size: int
    sha256: str


def _consume_stream(
    stream: BinaryIO,
    *,
    expected_size: int,
    expected_sha256: str,
    chunk_size: int,
    sink: Callable[[bytes], Any] | None = None,
) -> VerificationResult:
    _integer(expected_size, "expected_size", 1, MAX_PHOTO_BYTES)
    if not isinstance(expected_sha256, str) or SHA256_RE.fullmatch(expected_sha256) is None:
        _fail("INVALID_PHOTO_METADATA", "expected_sha256 must be lowercase hexadecimal SHA-256")
    if isinstance(chunk_size, bool) or not isinstance(chunk_size, int) or not 1 <= chunk_size <= 1024 * 1024:
        raise ValueError("chunk_size must be in [1, 1048576]")
    if not callable(getattr(stream, "read", None)):
        raise ValueError("stream must expose read(size)")

    digest = hashlib.sha256()
    total = 0
    while total < expected_size:
        requested = min(chunk_size, expected_size - total)
        chunk = stream.read(requested)
        if not isinstance(chunk, (bytes, bytearray, memoryview)):
            _fail("PHOTO_READ_ERROR", "photo stream returned non-bytes data")
        chunk = bytes(chunk)
        if len(chunk) > requested:
            _fail("PHOTO_READ_ERROR", "photo stream violated bounded read(size)")
        if not chunk:
            _fail("PHOTO_LENGTH_MISMATCH", f"photo ended at {total} bytes, expected {expected_size}")
        digest.update(chunk)
        if sink is not None:
            sink(chunk)
        total += len(chunk)

    trailing = stream.read(1)
    if not isinstance(trailing, (bytes, bytearray, memoryview)):
        _fail("PHOTO_READ_ERROR", "photo stream returned non-bytes data")
    if trailing:
        _fail("PHOTO_LENGTH_MISMATCH", f"photo exceeds declared size {expected_size}")

    actual_hash = digest.hexdigest()
    if not hmac.compare_digest(actual_hash, expected_sha256):
        _fail("PHOTO_SHA256_MISMATCH", f"photo SHA-256 was {actual_hash}, expected {expected_sha256}")
    return VerificationResult(total, actual_hash)


def verify_stream(
    stream: BinaryIO,
    *,
    expected_size: int,
    expected_sha256: str,
    chunk_size: int = DEFAULT_CHUNK_BYTES,
) -> VerificationResult:
    """Stream and verify exactly one photo without buffering it in memory."""

    return _consume_stream(
        stream,
        expected_size=expected_size,
        expected_sha256=expected_sha256,
        chunk_size=chunk_size,
    )


def verify_file(path: str | os.PathLike[str], metadata: Mapping[str, Any]) -> VerificationResult:
    """Verify an already-written file against validated photo metadata."""

    validated = validate_photo_metadata(dict(metadata))
    candidate = Path(path)
    try:
        size = candidate.stat().st_size
    except OSError as exc:
        _fail("PHOTO_READ_ERROR", f"cannot stat photo: {exc}")
    if size != validated["byteSize"]:
        _fail("PHOTO_LENGTH_MISMATCH", f"file has {size} bytes, expected {validated['byteSize']}")
    try:
        with candidate.open("rb") as stream:
            return verify_stream(
                stream,
                expected_size=validated["byteSize"],
                expected_sha256=validated["sha256"],
            )
    except ProtocolViolation:
        raise
    except OSError as exc:
        _fail("PHOTO_READ_ERROR", f"cannot read photo: {exc}")


def stream_to_verified_temp(
    stream: BinaryIO,
    temp_path: str | os.PathLike[str],
    metadata: Mapping[str, Any],
    *,
    chunk_size: int = DEFAULT_CHUNK_BYTES,
) -> VerificationResult:
    """Write with exclusive creation, verify, fsync, and delete on any failure."""

    validated = validate_photo_metadata(dict(metadata))
    candidate = Path(temp_path)
    created = False
    try:
        output = candidate.open("xb")
        created = True
        with output:
            result = _consume_stream(
                stream,
                expected_size=validated["byteSize"],
                expected_sha256=validated["sha256"],
                chunk_size=chunk_size,
                sink=output.write,
            )
            output.flush()
            os.fsync(output.fileno())
        return result
    except Exception:
        if created:
            try:
                candidate.unlink(missing_ok=True)
            except OSError:
                pass
        raise


def commit_verified_temp(
    temp_path: str | os.PathLike[str], final_path: str | os.PathLike[str]
) -> None:
    """Atomically publish a temp file after ``stream_to_verified_temp`` succeeds."""

    os.replace(temp_path, final_path)
