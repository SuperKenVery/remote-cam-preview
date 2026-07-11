"""Bounded RTCP v2 Receiver Report and PSFB PLI support for protocol v1."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Iterable

from .errors import ProtocolViolation

RTCP_VERSION = 2
RECEIVER_REPORT_PACKET_TYPE = 201
PAYLOAD_SPECIFIC_FEEDBACK_PACKET_TYPE = 206
PLI_FORMAT = 1
MAX_RTCP_DATAGRAM_BYTES = 1_500
MAX_RTCP_PACKETS_PER_DATAGRAM = 16


def _fail(code: str, message: str) -> None:
    raise ProtocolViolation(code, message)


def _uint32(value: int, name: str, *, nonzero: bool = False) -> int:
    minimum = 1 if nonzero else 0
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= 0xFFFFFFFF:
        raise ValueError(f"{name} must be in [{minimum}, 4294967295]")
    return value


def _common_header(packet: bytes) -> tuple[int, int, int]:
    if not isinstance(packet, bytes) or len(packet) < 4 or len(packet) % 4:
        _fail("MALFORMED_RTCP", "RTCP packet must be bytes with a 32-bit aligned header")
    first, packet_type, length_words_minus_one = struct.unpack("!BBH", packet[:4])
    if first >> 6 != RTCP_VERSION:
        _fail("MALFORMED_RTCP", "RTCP version must be 2")
    if first & 0x20:
        _fail("UNSUPPORTED_RTCP_PADDING", "RTCP padding is not negotiated in protocol v1")
    declared_bytes = (length_words_minus_one + 1) * 4
    if declared_bytes != len(packet):
        _fail("MALFORMED_RTCP", "RTCP length field does not match packet bytes")
    return first & 0x1F, packet_type, declared_bytes


@dataclass(frozen=True)
class ReceiverReportBlock:
    source_ssrc: int
    fraction_lost: int
    cumulative_lost: int
    extended_highest_sequence: int
    interarrival_jitter: int
    last_sender_report: int
    delay_since_last_sender_report: int

    def __post_init__(self) -> None:
        _uint32(self.source_ssrc, "source_ssrc", nonzero=True)
        if isinstance(self.fraction_lost, bool) or not isinstance(self.fraction_lost, int) or not 0 <= self.fraction_lost <= 255:
            raise ValueError("fraction_lost must be in [0, 255]")
        if isinstance(self.cumulative_lost, bool) or not isinstance(self.cumulative_lost, int) or not -(1 << 23) <= self.cumulative_lost < (1 << 23):
            raise ValueError("cumulative_lost must fit signed 24-bit")
        _uint32(self.extended_highest_sequence, "extended_highest_sequence")
        _uint32(self.interarrival_jitter, "interarrival_jitter")
        _uint32(self.last_sender_report, "last_sender_report")
        _uint32(self.delay_since_last_sender_report, "delay_since_last_sender_report")

    @property
    def fraction_lost_ratio(self) -> float:
        """Loss fraction as the RFC 3550 unsigned 8-bit fixed-point ratio."""

        return self.fraction_lost / 256.0

    @property
    def delay_since_last_sender_report_seconds(self) -> float:
        return self.delay_since_last_sender_report / 65_536.0

    def jitter_seconds(self, clock_rate: int = 90_000) -> float:
        if isinstance(clock_rate, bool) or not isinstance(clock_rate, int) or clock_rate <= 0:
            raise ValueError("clock_rate must be a positive integer")
        return self.interarrival_jitter / float(clock_rate)


@dataclass(frozen=True)
class ReceiverReport:
    sender_ssrc: int
    report_blocks: tuple[ReceiverReportBlock, ...]

    def __post_init__(self) -> None:
        _uint32(self.sender_ssrc, "sender_ssrc", nonzero=True)
        if len(self.report_blocks) > 31:
            raise ValueError("an RTCP RR may contain at most 31 report blocks")

    def block_for_ssrc(self, source_ssrc: int) -> ReceiverReportBlock | None:
        for block in self.report_blocks:
            if block.source_ssrc == source_ssrc:
                return block
        return None


@dataclass(frozen=True)
class PictureLossIndication:
    sender_ssrc: int
    media_ssrc: int

    def __post_init__(self) -> None:
        _uint32(self.sender_ssrc, "sender_ssrc", nonzero=True)
        _uint32(self.media_ssrc, "media_ssrc", nonzero=True)


def build_receiver_report(sender_ssrc: int, report_blocks: Iterable[ReceiverReportBlock]) -> bytes:
    """Build a standards-shaped RTCP v2 RR packet for the monitor."""

    _uint32(sender_ssrc, "sender_ssrc", nonzero=True)
    blocks = tuple(report_blocks)
    if len(blocks) > 31 or any(not isinstance(block, ReceiverReportBlock) for block in blocks):
        raise ValueError("report_blocks must contain at most 31 ReceiverReportBlock values")
    packet = bytearray(struct.pack("!BBHI", 0x80 | len(blocks), RECEIVER_REPORT_PACKET_TYPE, 1 + 6 * len(blocks), sender_ssrc))
    for block in blocks:
        cumulative = block.cumulative_lost & 0xFFFFFF
        packet.extend(struct.pack("!IB", block.source_ssrc, block.fraction_lost))
        packet.extend(cumulative.to_bytes(3, "big"))
        packet.extend(
            struct.pack(
                "!IIII",
                block.extended_highest_sequence,
                block.interarrival_jitter,
                block.last_sender_report,
                block.delay_since_last_sender_report,
            )
        )
    return bytes(packet)


def parse_receiver_report(
    packet: bytes,
    *,
    expected_sender_ssrc: int | None = None,
    expected_media_ssrc: int | None = None,
) -> ReceiverReport:
    report_count, packet_type, _ = _common_header(packet)
    if packet_type != RECEIVER_REPORT_PACKET_TYPE:
        _fail("UNSUPPORTED_RTCP_PACKET", "RTCP packet is not a Receiver Report")
    expected_length = 8 + report_count * 24
    if len(packet) != expected_length:
        _fail("MALFORMED_RTCP", "RR length does not match its report count")
    sender_ssrc = struct.unpack("!I", packet[4:8])[0]
    if sender_ssrc == 0:
        _fail("MALFORMED_RTCP", "RR sender SSRC must be non-zero")

    blocks: list[ReceiverReportBlock] = []
    offset = 8
    for _index in range(report_count):
        source_ssrc = struct.unpack("!I", packet[offset : offset + 4])[0]
        if source_ssrc == 0:
            _fail("MALFORMED_RTCP", "RR report-block source SSRC must be non-zero")
        fraction_lost = packet[offset + 4]
        cumulative_raw = int.from_bytes(packet[offset + 5 : offset + 8], "big")
        cumulative_lost = cumulative_raw - (1 << 24) if cumulative_raw & 0x800000 else cumulative_raw
        highest, jitter, last_sr, delay = struct.unpack("!IIII", packet[offset + 8 : offset + 24])
        blocks.append(
            ReceiverReportBlock(
                source_ssrc=source_ssrc,
                fraction_lost=fraction_lost,
                cumulative_lost=cumulative_lost,
                extended_highest_sequence=highest,
                interarrival_jitter=jitter,
                last_sender_report=last_sr,
                delay_since_last_sender_report=delay,
            )
        )
        offset += 24
    report = ReceiverReport(sender_ssrc, tuple(blocks))
    if expected_sender_ssrc is not None:
        _uint32(expected_sender_ssrc, "expected_sender_ssrc", nonzero=True)
        if report.sender_ssrc != expected_sender_ssrc:
            _fail("UNEXPECTED_RTCP_SSRC", "RR sender SSRC differs from the negotiated peer")
    if expected_media_ssrc is not None:
        _uint32(expected_media_ssrc, "expected_media_ssrc", nonzero=True)
        if report.block_for_ssrc(expected_media_ssrc) is None:
            _fail("UNEXPECTED_RTCP_SSRC", "RR has no block for the negotiated media SSRC")
    return report


def build_picture_loss_indication(sender_ssrc: int, media_ssrc: int) -> bytes:
    """Build a 12-byte RFC 4585 Payload-Specific Feedback PLI packet."""

    _uint32(sender_ssrc, "sender_ssrc", nonzero=True)
    _uint32(media_ssrc, "media_ssrc", nonzero=True)
    return struct.pack(
        "!BBHII",
        0x80 | PLI_FORMAT,
        PAYLOAD_SPECIFIC_FEEDBACK_PACKET_TYPE,
        2,
        sender_ssrc,
        media_ssrc,
    )


def parse_picture_loss_indication(
    packet: bytes,
    *,
    expected_sender_ssrc: int | None = None,
    expected_media_ssrc: int | None = None,
) -> PictureLossIndication:
    feedback_format, packet_type, _ = _common_header(packet)
    if packet_type != PAYLOAD_SPECIFIC_FEEDBACK_PACKET_TYPE or feedback_format != PLI_FORMAT:
        _fail("UNSUPPORTED_RTCP_PACKET", "RTCP packet is not PSFB PLI (FMT=1, PT=206)")
    if len(packet) != 12:
        _fail("MALFORMED_RTCP", "PLI must have no FCI and be exactly 12 bytes")
    sender_ssrc, media_ssrc = struct.unpack("!II", packet[4:12])
    if sender_ssrc == 0 or media_ssrc == 0:
        _fail("MALFORMED_RTCP", "PLI sender and media SSRCs must be non-zero")
    pli = PictureLossIndication(sender_ssrc, media_ssrc)
    if expected_sender_ssrc is not None:
        _uint32(expected_sender_ssrc, "expected_sender_ssrc", nonzero=True)
        if pli.sender_ssrc != expected_sender_ssrc:
            _fail("UNEXPECTED_RTCP_SSRC", "PLI sender SSRC differs from the negotiated peer")
    if expected_media_ssrc is not None:
        _uint32(expected_media_ssrc, "expected_media_ssrc", nonzero=True)
        if pli.media_ssrc != expected_media_ssrc:
            _fail("UNEXPECTED_RTCP_SSRC", "PLI media SSRC differs from the negotiated stream")
    return pli


def parse_rtcp_datagram(datagram: bytes) -> tuple[ReceiverReport | PictureLossIndication, ...]:
    """Parse a bounded reduced-size or compound v1 RR/PLI RTCP datagram."""

    if not isinstance(datagram, bytes) or not 4 <= len(datagram) <= MAX_RTCP_DATAGRAM_BYTES or len(datagram) % 4:
        _fail("RTCP_RESOURCE_LIMIT", "RTCP datagram length is out of bounds or unaligned")
    packets: list[ReceiverReport | PictureLossIndication] = []
    offset = 0
    while offset < len(datagram):
        if len(packets) >= MAX_RTCP_PACKETS_PER_DATAGRAM:
            _fail("RTCP_RESOURCE_LIMIT", "RTCP datagram contains too many packets")
        if offset + 4 > len(datagram):
            _fail("MALFORMED_RTCP", "truncated RTCP common header")
        length_words_minus_one = struct.unpack("!H", datagram[offset + 2 : offset + 4])[0]
        packet_size = (length_words_minus_one + 1) * 4
        if packet_size < 4 or offset + packet_size > len(datagram):
            _fail("MALFORMED_RTCP", "RTCP subpacket length exceeds datagram")
        packet = datagram[offset : offset + packet_size]
        packet_type = packet[1]
        if packet_type == RECEIVER_REPORT_PACKET_TYPE:
            packets.append(parse_receiver_report(packet))
        elif packet_type == PAYLOAD_SPECIFIC_FEEDBACK_PACKET_TYPE:
            packets.append(parse_picture_loss_indication(packet))
        else:
            _fail("UNSUPPORTED_RTCP_PACKET", f"RTCP packet type {packet_type} is not negotiated in v1")
        offset += packet_size
    return tuple(packets)


def round_trip_time_seconds(arrival_compact_ntp: int, block: ReceiverReportBlock) -> float | None:
    """Calculate RFC 3550 RTT from A - LSR - DLSR in compact-NTP units."""

    _uint32(arrival_compact_ntp, "arrival_compact_ntp")
    if not isinstance(block, ReceiverReportBlock):
        raise ValueError("block must be a ReceiverReportBlock")
    if block.last_sender_report == 0:
        return None
    delta = (
        arrival_compact_ntp
        - block.last_sender_report
        - block.delay_since_last_sender_report
    ) & 0xFFFFFFFF
    return delta / 65_536.0

