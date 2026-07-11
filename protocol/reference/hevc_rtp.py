"""RFC 7798 HEVC RTP packetization without interleaving or DONL fields.

The implementation intentionally supports the protocol's negotiated MVP subset:
single NAL units, Aggregation Packets (AP, type 48), and Fragmentation Units
(FU, type 49). PACI, interleaved mode, DONL/DOND, RTP extensions, padding, and
CSRC lists are rejected rather than guessed.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Iterable, Sequence

from .errors import ProtocolViolation

CLOCK_RATE = 90_000
RTP_HEADER_SIZE = 12
AP_NAL_TYPE = 48
FU_NAL_TYPE = 49
PACI_NAL_TYPE = 50

MAX_NAL_UNIT_BYTES = 16 * 1024 * 1024
MAX_ACCESS_UNIT_BYTES = 64 * 1024 * 1024
MAX_NAL_UNITS_PER_ACCESS_UNIT = 1_024
MAX_RTP_PACKETS_PER_ACCESS_UNIT = 4_096
MAX_AGGREGATED_NAL_UNITS = 64


def _fail(code: str, message: str) -> None:
    raise ProtocolViolation(code, message)


def _validate_uint(value: int, bits: int, name: str, *, nonzero: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{name} must be an integer")
    minimum = 1 if nonzero else 0
    maximum = (1 << bits) - 1
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be in [{minimum}, {maximum}]")
    return value


def _parse_nal_header(nal: bytes, *, allow_packetization_types: bool = False) -> tuple[int, int, int]:
    if len(nal) < 2:
        _fail("MALFORMED_HEVC_NAL", "HEVC NAL unit must include its two-byte header")
    if nal[0] & 0x80:
        _fail("MALFORMED_HEVC_NAL", "forbidden_zero_bit must be zero")
    nal_type = (nal[0] >> 1) & 0x3F
    layer_id = ((nal[0] & 0x01) << 5) | (nal[1] >> 3)
    temporal_id_plus1 = nal[1] & 0x07
    if temporal_id_plus1 == 0:
        _fail("MALFORMED_HEVC_NAL", "nuh_temporal_id_plus1 must not be zero")
    maximum_type = PACI_NAL_TYPE if allow_packetization_types else 47
    if nal_type > maximum_type:
        _fail("UNSUPPORTED_HEVC_NAL_TYPE", f"unsupported HEVC NAL type {nal_type}")
    return nal_type, layer_id, temporal_id_plus1


def _make_nal_header(nal_type: int, layer_id: int, temporal_id_plus1: int) -> bytes:
    if not 0 <= nal_type <= 63 or not 0 <= layer_id <= 63 or not 1 <= temporal_id_plus1 <= 7:
        raise ValueError("invalid HEVC NAL header field")
    return bytes(
        (
            (nal_type << 1) | (layer_id >> 5),
            ((layer_id & 0x1F) << 3) | temporal_id_plus1,
        )
    )


@dataclass(frozen=True)
class RtpPacket:
    payload_type: int
    sequence_number: int
    timestamp: int
    ssrc: int
    marker: bool
    payload: bytes

    def __post_init__(self) -> None:
        _validate_uint(self.payload_type, 7, "payload_type")
        _validate_uint(self.sequence_number, 16, "sequence_number")
        _validate_uint(self.timestamp, 32, "timestamp")
        _validate_uint(self.ssrc, 32, "ssrc", nonzero=True)
        if not isinstance(self.marker, bool):
            raise ValueError("marker must be a bool")
        if not isinstance(self.payload, bytes) or not self.payload:
            raise ValueError("payload must be non-empty bytes")

    def to_bytes(self) -> bytes:
        """Encode a minimal RTP v2 packet (no CSRC, extension, or padding)."""

        return struct.pack(
            "!BBHII",
            0x80,
            (0x80 if self.marker else 0) | self.payload_type,
            self.sequence_number,
            self.timestamp,
            self.ssrc,
        ) + self.payload

    @classmethod
    def from_bytes(cls, packet: bytes, *, max_packet_size: int = 65_535) -> "RtpPacket":
        if not isinstance(packet, bytes):
            _fail("MALFORMED_RTP", "RTP packet must be bytes")
        if not RTP_HEADER_SIZE < len(packet) <= max_packet_size:
            _fail("MALFORMED_RTP", "RTP packet length is out of range")
        first, second, sequence, timestamp, ssrc = struct.unpack("!BBHII", packet[:RTP_HEADER_SIZE])
        if first >> 6 != 2:
            _fail("MALFORMED_RTP", "RTP version must be 2")
        if first & 0x3F:
            _fail("UNSUPPORTED_RTP_HEADER", "RTP padding, extensions, and CSRCs are not negotiated in v1")
        if ssrc == 0:
            _fail("MALFORMED_RTP", "RTP SSRC must be non-zero")
        return cls(
            payload_type=second & 0x7F,
            sequence_number=sequence,
            timestamp=timestamp,
            ssrc=ssrc,
            marker=bool(second & 0x80),
            payload=packet[RTP_HEADER_SIZE:],
        )


class HevcRtpPacketizer:
    """Deterministically packetize one HEVC access unit at a time.

    ``max_packet_size`` is the complete RTP packet size, excluding UDP/IP
    headers. The caller derives it from the path MTU (for example, IPv6 path MTU
    minus 48 bytes for IPv6 and UDP).
    """

    def __init__(
        self,
        *,
        payload_type: int,
        ssrc: int,
        initial_sequence: int,
        max_packet_size: int = 1_200,
        aggregate: bool = True,
    ) -> None:
        _validate_uint(payload_type, 7, "payload_type")
        if not 96 <= payload_type <= 127:
            raise ValueError("payload_type must be a dynamic RTP payload type (96..127)")
        _validate_uint(ssrc, 32, "ssrc", nonzero=True)
        _validate_uint(initial_sequence, 16, "initial_sequence")
        if not 64 <= max_packet_size <= 65_535:
            raise ValueError("max_packet_size must be in [64, 65535]")
        if not isinstance(aggregate, bool):
            raise ValueError("aggregate must be a bool")
        self.payload_type = payload_type
        self.ssrc = ssrc
        self.sequence_number = initial_sequence
        self.max_packet_size = max_packet_size
        self.aggregate = aggregate

    @property
    def max_payload_size(self) -> int:
        return self.max_packet_size - RTP_HEADER_SIZE

    def _aggregation_payload(self, nalus: Sequence[bytes], start: int) -> tuple[bytes | None, int]:
        group: list[bytes] = []
        encoded_size = 2
        index = start
        while index < len(nalus) and len(group) < MAX_AGGREGATED_NAL_UNITS:
            nalu = nalus[index]
            if len(nalu) > 0xFFFF or encoded_size + 2 + len(nalu) > self.max_payload_size:
                break
            group.append(nalu)
            encoded_size += 2 + len(nalu)
            index += 1
        if len(group) < 2:
            return None, start

        parsed_headers = [_parse_nal_header(nalu) for nalu in group]
        layer_id = min(header[1] for header in parsed_headers)
        temporal_id_plus1 = min(header[2] for header in parsed_headers)
        payload = bytearray(_make_nal_header(AP_NAL_TYPE, layer_id, temporal_id_plus1))
        for nalu in group:
            payload.extend(struct.pack("!H", len(nalu)))
            payload.extend(nalu)
        return bytes(payload), index

    def _fragment_payloads(self, nalu: bytes) -> list[bytes]:
        nal_type, layer_id, temporal_id_plus1 = _parse_nal_header(nalu)
        fragment_capacity = self.max_payload_size - 3
        if fragment_capacity < 1:
            raise ValueError("max_packet_size leaves no room for FU payload")
        body = nalu[2:]
        if not body:
            _fail("MALFORMED_HEVC_NAL", "an empty NAL body cannot be fragmented")
        indicator = _make_nal_header(FU_NAL_TYPE, layer_id, temporal_id_plus1)
        fragments: list[bytes] = []
        for offset in range(0, len(body), fragment_capacity):
            chunk = body[offset : offset + fragment_capacity]
            start = offset == 0
            end = offset + len(chunk) == len(body)
            fu_header = (0x80 if start else 0) | (0x40 if end else 0) | nal_type
            fragments.append(indicator + bytes((fu_header,)) + chunk)
        return fragments

    def packetize_access_unit(self, nal_units: Sequence[bytes], *, timestamp: int) -> list[bytes]:
        _validate_uint(timestamp, 32, "timestamp")
        if not isinstance(nal_units, Sequence) or isinstance(nal_units, (bytes, bytearray)):
            raise ValueError("nal_units must be a sequence of bytes")
        if not 1 <= len(nal_units) <= MAX_NAL_UNITS_PER_ACCESS_UNIT:
            _fail("HEVC_RESOURCE_LIMIT", "access-unit NAL count is out of range")

        normalized: list[bytes] = []
        total_size = 0
        for nalu in nal_units:
            if not isinstance(nalu, bytes):
                raise ValueError("each NAL unit must be bytes")
            if len(nalu) > MAX_NAL_UNIT_BYTES:
                _fail("HEVC_RESOURCE_LIMIT", "NAL unit exceeds 16 MiB")
            _parse_nal_header(nalu)
            total_size += len(nalu)
            if total_size > MAX_ACCESS_UNIT_BYTES:
                _fail("HEVC_RESOURCE_LIMIT", "access unit exceeds 64 MiB")
            normalized.append(nalu)

        payloads: list[bytes] = []
        index = 0
        while index < len(normalized):
            if self.aggregate:
                aggregate_payload, next_index = self._aggregation_payload(normalized, index)
                if aggregate_payload is not None:
                    payloads.append(aggregate_payload)
                    index = next_index
                    continue
            nalu = normalized[index]
            if len(nalu) <= self.max_payload_size:
                payloads.append(nalu)
            else:
                payloads.extend(self._fragment_payloads(nalu))
            if len(payloads) > MAX_RTP_PACKETS_PER_ACCESS_UNIT:
                _fail("HEVC_RESOURCE_LIMIT", "access unit requires too many RTP packets")
            index += 1

        packets: list[bytes] = []
        sequence = self.sequence_number
        for index, payload in enumerate(payloads):
            packets.append(
                RtpPacket(
                    payload_type=self.payload_type,
                    sequence_number=sequence,
                    timestamp=timestamp,
                    ssrc=self.ssrc,
                    marker=index == len(payloads) - 1,
                    payload=payload,
                ).to_bytes()
            )
            sequence = (sequence + 1) & 0xFFFF
        self.sequence_number = sequence
        return packets


def depacketize_access_unit(
    packets: Iterable[bytes | RtpPacket],
    *,
    expected_payload_type: int | None = None,
    max_packet_size: int = 65_535,
    max_packets: int = MAX_RTP_PACKETS_PER_ACCESS_UNIT,
    max_nal_size: int = MAX_NAL_UNIT_BYTES,
    max_access_unit_size: int = MAX_ACCESS_UNIT_BYTES,
) -> list[bytes]:
    """Reorder and depacketize exactly one complete RTP access unit.

    Packet loss, duplicates, mixed streams/timestamps, or an absent final marker
    reject the entire access unit. This is deliberate: a damaged frame must be
    dropped and followed by a keyframe request rather than partially decoded.
    """

    parsed: list[RtpPacket] = []
    for packet in packets:
        if len(parsed) >= max_packets:
            _fail("RTP_RESOURCE_LIMIT", "access unit contains too many RTP packets")
        parsed.append(
            packet
            if isinstance(packet, RtpPacket)
            else RtpPacket.from_bytes(packet, max_packet_size=max_packet_size)
        )
    if not parsed:
        _fail("INCOMPLETE_ACCESS_UNIT", "no RTP packets supplied")
    if expected_payload_type is not None:
        _validate_uint(expected_payload_type, 7, "expected_payload_type")

    first = parsed[0]
    for packet in parsed:
        if packet.timestamp != first.timestamp or packet.ssrc != first.ssrc or packet.payload_type != first.payload_type:
            _fail("MIXED_RTP_ACCESS_UNIT", "RTP packets do not share timestamp, SSRC, and payload type")
        if expected_payload_type is not None and packet.payload_type != expected_payload_type:
            _fail("UNEXPECTED_PAYLOAD_TYPE", "RTP payload type differs from negotiation")

    markers = [packet for packet in parsed if packet.marker]
    if len(markers) != 1:
        _fail("INCOMPLETE_ACCESS_UNIT", "access unit must contain exactly one marker packet")
    marker_sequence = markers[0].sequence_number
    distances = {(marker_sequence - packet.sequence_number) & 0xFFFF for packet in parsed}
    expected_distances = set(range(len(parsed)))
    if distances != expected_distances:
        _fail("RTP_SEQUENCE_GAP", "RTP sequence numbers are duplicated or non-contiguous")
    ordered = sorted(parsed, key=lambda packet: (marker_sequence - packet.sequence_number) & 0xFFFF, reverse=True)
    if any(packet.marker for packet in ordered[:-1]) or not ordered[-1].marker:
        _fail("INCOMPLETE_ACCESS_UNIT", "marker bit is not on the final packet")

    nal_units: list[bytes] = []
    total_size = 0
    active_fu: bytearray | None = None
    active_signature: tuple[int, int, int] | None = None

    def append_nal(nalu: bytes) -> None:
        nonlocal total_size
        _parse_nal_header(nalu)
        if len(nalu) > max_nal_size:
            _fail("HEVC_RESOURCE_LIMIT", "reconstructed NAL unit is too large")
        total_size += len(nalu)
        if total_size > max_access_unit_size:
            _fail("HEVC_RESOURCE_LIMIT", "reconstructed access unit is too large")
        if len(nal_units) >= MAX_NAL_UNITS_PER_ACCESS_UNIT:
            _fail("HEVC_RESOURCE_LIMIT", "reconstructed access unit has too many NAL units")
        nal_units.append(nalu)

    for packet in ordered:
        payload = packet.payload
        nal_type, layer_id, temporal_id_plus1 = _parse_nal_header(payload, allow_packetization_types=True)
        if nal_type <= 47:
            if active_fu is not None:
                _fail("MALFORMED_HEVC_FU", "single NAL interleaves an unfinished FU")
            append_nal(payload)
        elif nal_type == AP_NAL_TYPE:
            if active_fu is not None:
                _fail("MALFORMED_HEVC_FU", "AP interleaves an unfinished FU")
            offset = 2
            ap_nalus: list[bytes] = []
            ap_headers: list[tuple[int, int, int]] = []
            while offset < len(payload):
                if offset + 2 > len(payload):
                    _fail("MALFORMED_HEVC_AP", "truncated AP NAL length")
                nalu_size = struct.unpack("!H", payload[offset : offset + 2])[0]
                offset += 2
                if nalu_size < 2 or offset + nalu_size > len(payload):
                    _fail("MALFORMED_HEVC_AP", "invalid or truncated AP NAL unit")
                ap_nalu = payload[offset : offset + nalu_size]
                ap_headers.append(_parse_nal_header(ap_nalu))
                ap_nalus.append(ap_nalu)
                offset += nalu_size
            if len(ap_nalus) < 2:
                _fail("MALFORMED_HEVC_AP", "AP must contain at least two NAL units")
            if layer_id != min(header[1] for header in ap_headers) or temporal_id_plus1 != min(
                header[2] for header in ap_headers
            ):
                _fail("MALFORMED_HEVC_AP", "AP LayerId/TID must be the lowest values of its NAL units")
            for ap_nalu in ap_nalus:
                append_nal(ap_nalu)
        elif nal_type == FU_NAL_TYPE:
            if len(payload) < 4:
                _fail("MALFORMED_HEVC_FU", "FU payload is too short")
            fu_header = payload[2]
            start = bool(fu_header & 0x80)
            end = bool(fu_header & 0x40)
            original_type = fu_header & 0x3F
            if original_type > 47 or (start and end):
                _fail("MALFORMED_HEVC_FU", "FU header has invalid type/start/end flags")
            signature = (payload[0], payload[1], original_type)
            fragment = payload[3:]
            if start:
                if active_fu is not None:
                    _fail("MALFORMED_HEVC_FU", "FU start interleaves an unfinished FU")
                active_fu = bytearray(_make_nal_header(original_type, layer_id, temporal_id_plus1))
                active_fu.extend(fragment)
                active_signature = signature
            else:
                if active_fu is None or active_signature != signature:
                    _fail("MALFORMED_HEVC_FU", "FU continuation has no matching start")
                active_fu.extend(fragment)
            if active_fu is not None and len(active_fu) > max_nal_size:
                _fail("HEVC_RESOURCE_LIMIT", "reconstructed FU NAL unit is too large")
            if end:
                if active_fu is None:
                    _fail("MALFORMED_HEVC_FU", "FU end has no matching start")
                append_nal(bytes(active_fu))
                active_fu = None
                active_signature = None
        elif nal_type == PACI_NAL_TYPE:
            _fail("UNSUPPORTED_HEVC_PAYLOAD", "PACI is not negotiated in protocol v1")

    if active_fu is not None:
        _fail("INCOMPLETE_ACCESS_UNIT", "final FU fragment is missing")
    if not nal_units:
        _fail("INCOMPLETE_ACCESS_UNIT", "access unit reconstructed no NAL units")
    return nal_units
