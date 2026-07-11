from __future__ import annotations

import unittest

from protocol.reference.errors import ProtocolViolation
from protocol.reference.rtcp import (
    ReceiverReportBlock,
    build_picture_loss_indication,
    build_receiver_report,
    parse_picture_loss_indication,
    parse_receiver_report,
    parse_rtcp_datagram,
    round_trip_time_seconds,
)

from ._vectors import load_vector


class RtcpVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = load_vector("rtcp.json")

    def test_receiver_report_vectors_and_metrics(self) -> None:
        for vector in self.vectors["validReceiverReports"]:
            with self.subTest(vector=vector["name"]):
                packet = bytes.fromhex(vector["packetHex"])
                report = parse_receiver_report(packet, expected_sender_ssrc=vector["senderSsrc"])
                self.assertEqual(report.sender_ssrc, vector["senderSsrc"])
                self.assertEqual(len(report.report_blocks), len(vector["blocks"]))
                for block, expected in zip(report.report_blocks, vector["blocks"]):
                    self.assertEqual(block.source_ssrc, expected["sourceSsrc"])
                    self.assertEqual(block.fraction_lost, expected["fractionLost"])
                    self.assertAlmostEqual(block.fraction_lost_ratio, expected["fractionLostRatio"])
                    self.assertEqual(block.cumulative_lost, expected["cumulativeLost"])
                    self.assertEqual(block.extended_highest_sequence, expected["extendedHighestSequence"])
                    self.assertEqual(block.interarrival_jitter, expected["interarrivalJitter"])
                    self.assertAlmostEqual(block.jitter_seconds(), expected["jitterSecondsAt90kHz"])
                    self.assertEqual(block.last_sender_report, expected["lastSenderReport"])
                    self.assertEqual(block.delay_since_last_sender_report, expected["delaySinceLastSenderReport"])
                    self.assertAlmostEqual(block.delay_since_last_sender_report_seconds, expected["delaySeconds"])
                self.assertEqual(build_receiver_report(report.sender_ssrc, report.report_blocks), packet)

    def test_pli_vectors_round_trip(self) -> None:
        for vector in self.vectors["validPli"]:
            with self.subTest(vector=vector["name"]):
                packet = bytes.fromhex(vector["packetHex"])
                pli = parse_picture_loss_indication(
                    packet,
                    expected_sender_ssrc=vector["senderSsrc"],
                    expected_media_ssrc=vector["mediaSsrc"],
                )
                self.assertEqual(pli.sender_ssrc, vector["senderSsrc"])
                self.assertEqual(pli.media_ssrc, vector["mediaSsrc"])
                self.assertEqual(build_picture_loss_indication(pli.sender_ssrc, pli.media_ssrc), packet)

    def test_compound_vector(self) -> None:
        for vector in self.vectors["validDatagrams"]:
            with self.subTest(vector=vector["name"]):
                parsed = parse_rtcp_datagram(bytes.fromhex(vector["datagramHex"]))
                self.assertEqual([type(item).__name__ for item in parsed], vector["packetKinds"])

    def test_invalid_vectors_have_stable_errors(self) -> None:
        for vector in self.vectors["invalid"]:
            with self.subTest(vector=vector["name"]):
                packet = bytes.fromhex(vector["packetHex"])
                with self.assertRaises(ProtocolViolation) as raised:
                    if vector["kind"] == "rr":
                        parse_receiver_report(packet)
                    elif vector["kind"] == "pli":
                        parse_picture_loss_indication(
                            packet,
                            expected_media_ssrc=vector.get("expectedMediaSsrc"),
                        )
                    else:
                        parse_rtcp_datagram(packet)
                self.assertEqual(raised.exception.code, vector["expectedError"])


class RtcpMetricTests(unittest.TestCase):
    def test_rtt_from_compact_ntp(self) -> None:
        block = ReceiverReportBlock(
            source_ssrc=1,
            fraction_lost=0,
            cumulative_lost=0,
            extended_highest_sequence=0,
            interarrival_jitter=0,
            last_sender_report=0x00010000,
            delay_since_last_sender_report=0x00008000,
        )
        self.assertAlmostEqual(round_trip_time_seconds(0x00020000, block), 0.5)

    def test_rtt_is_unknown_without_sender_report(self) -> None:
        block = ReceiverReportBlock(1, 0, 0, 0, 0, 0, 0)
        self.assertIsNone(round_trip_time_seconds(0x00020000, block))


if __name__ == "__main__":
    unittest.main()
