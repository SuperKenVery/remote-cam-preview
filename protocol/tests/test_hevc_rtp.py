from __future__ import annotations

import unittest

from protocol.reference.errors import ProtocolViolation
from protocol.reference.hevc_rtp import HevcRtpPacketizer, RtpPacket, depacketize_access_unit

from ._vectors import load_vector


class HevcRtpVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = load_vector("hevc-rtp.json")

    def test_packetizer_matches_shared_vectors_byte_for_byte(self) -> None:
        for vector in self.vectors["valid"]:
            with self.subTest(vector=vector["name"]):
                config = vector["config"]
                packetizer = HevcRtpPacketizer(
                    payload_type=config["payloadType"],
                    ssrc=config["ssrc"],
                    initial_sequence=config["initialSequence"],
                    max_packet_size=config["maxRtpPacketSize"],
                    aggregate=config["aggregate"],
                )
                packets = packetizer.packetize_access_unit(
                    [bytes.fromhex(item) for item in vector["nalUnitsHex"]],
                    timestamp=config["timestamp"],
                )
                self.assertEqual([packet.hex() for packet in packets], vector["packetsHex"])
                self.assertEqual(packetizer.sequence_number, vector["nextSequence"])

    def test_depacketizer_reorders_and_matches_shared_vectors(self) -> None:
        for vector in self.vectors["valid"]:
            with self.subTest(vector=vector["name"]):
                packets = [bytes.fromhex(item) for item in vector["packetsHex"]]
                arrival = [packets[index] for index in vector["arrivalOrder"]]
                nal_units = depacketize_access_unit(
                    arrival,
                    expected_payload_type=vector["config"]["payloadType"],
                    max_packet_size=vector["config"]["maxRtpPacketSize"],
                )
                self.assertEqual([item.hex() for item in nal_units], vector["nalUnitsHex"])

    def test_invalid_vectors_have_stable_error_codes(self) -> None:
        for vector in self.vectors["invalid"]:
            with self.subTest(vector=vector["name"]):
                with self.assertRaises(ProtocolViolation) as raised:
                    depacketize_access_unit(
                        [bytes.fromhex(item) for item in vector["packetsHex"]],
                        max_packet_size=vector["maxRtpPacketSize"],
                    )
                self.assertEqual(raised.exception.code, vector["expectedError"])


class HevcRtpDefensiveTests(unittest.TestCase):
    def test_marker_only_appears_on_last_packet_of_access_unit(self) -> None:
        packetizer = HevcRtpPacketizer(
            payload_type=96,
            ssrc=1,
            initial_sequence=10,
            max_packet_size=64,
            aggregate=False,
        )
        packets = packetizer.packetize_access_unit([b"\x26\x01" + b"x" * 120], timestamp=3)
        parsed = [RtpPacket.from_bytes(packet) for packet in packets]
        self.assertGreater(len(parsed), 1)
        self.assertTrue(all(not packet.marker for packet in parsed[:-1]))
        self.assertTrue(parsed[-1].marker)

    def test_packetizer_advances_sequence_across_access_units(self) -> None:
        packetizer = HevcRtpPacketizer(payload_type=96, ssrc=1, initial_sequence=9)
        first = RtpPacket.from_bytes(packetizer.packetize_access_unit([b"\x26\x01x"], timestamp=1)[0])
        second = RtpPacket.from_bytes(packetizer.packetize_access_unit([b"\x26\x01y"], timestamp=2)[0])
        self.assertEqual((first.sequence_number, second.sequence_number), (9, 10))

    def test_rejects_wrong_payload_type(self) -> None:
        packetizer = HevcRtpPacketizer(payload_type=96, ssrc=1, initial_sequence=0)
        packets = packetizer.packetize_access_unit([b"\x26\x01x"], timestamp=1)
        with self.assertRaises(ProtocolViolation) as raised:
            depacketize_access_unit(packets, expected_payload_type=97)
        self.assertEqual(raised.exception.code, "UNEXPECTED_PAYLOAD_TYPE")

    def test_rejects_multiple_markers(self) -> None:
        first = RtpPacket(96, 1, 1, 1, True, b"\x26\x01a")
        second = RtpPacket(96, 2, 1, 1, True, b"\x26\x01b")
        with self.assertRaises(ProtocolViolation) as raised:
            depacketize_access_unit([first, second])
        self.assertEqual(raised.exception.code, "INCOMPLETE_ACCESS_UNIT")

    def test_rejects_mixed_ssrc(self) -> None:
        first = RtpPacket(96, 1, 1, 1, False, b"\x26\x01a")
        second = RtpPacket(96, 2, 1, 2, True, b"\x26\x01b")
        with self.assertRaises(ProtocolViolation) as raised:
            depacketize_access_unit([first, second])
        self.assertEqual(raised.exception.code, "MIXED_RTP_ACCESS_UNIT")

    def test_rejects_rtp_extensions_not_negotiated_by_v1(self) -> None:
        raw = bytes.fromhex("90e0000100000001000000012601aa")
        with self.assertRaises(ProtocolViolation) as raised:
            RtpPacket.from_bytes(raw)
        self.assertEqual(raised.exception.code, "UNSUPPORTED_RTP_HEADER")

    def test_rejects_invalid_hevc_temporal_id(self) -> None:
        packetizer = HevcRtpPacketizer(payload_type=96, ssrc=1, initial_sequence=1)
        with self.assertRaises(ProtocolViolation) as raised:
            packetizer.packetize_access_unit([b"\x26\x00x"], timestamp=1)
        self.assertEqual(raised.exception.code, "MALFORMED_HEVC_NAL")


if __name__ == "__main__":
    unittest.main()

