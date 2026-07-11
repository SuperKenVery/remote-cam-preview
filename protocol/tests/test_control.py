from __future__ import annotations

import copy
import json
import unittest

from protocol.reference.control import (
    MAX_ARRAY_ITEMS,
    MAX_CONTROL_MESSAGE_BYTES,
    MAX_JSON_DEPTH,
    MAX_STRING_BYTES,
    RequestLedger,
    decode_control_message,
    encode_control_message,
    validate_control_message,
)
from protocol.reference.errors import ProtocolViolation

from ._vectors import load_vector


def heartbeat(request_id: str = "request-1", sent_at: int = 42) -> dict:
    return {
        "type": "heartbeat.ping",
        "requestId": request_id,
        "protocolVersion": "1.0",
        "payload": {"sentAtMs": sent_at},
    }


class ControlVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = load_vector("control-messages.json")

    def test_valid_vectors_round_trip_canonical_json(self) -> None:
        for vector in self.vectors["valid"]:
            with self.subTest(vector=vector["name"]):
                validated = validate_control_message(copy.deepcopy(vector["message"]))
                encoded = encode_control_message(validated)
                self.assertLessEqual(len(encoded), MAX_CONTROL_MESSAGE_BYTES)
                self.assertEqual(decode_control_message(encoded), vector["message"])

    def test_invalid_vectors_have_stable_error_codes(self) -> None:
        for vector in self.vectors["invalid"]:
            with self.subTest(vector=vector["name"]):
                with self.assertRaises(ProtocolViolation) as raised:
                    if "wireText" in vector:
                        decode_control_message(vector["wireText"])
                    else:
                        validate_control_message(vector["message"])
                self.assertEqual(raised.exception.code, vector["expectedError"])

    def test_unknown_optional_fields_are_preserved(self) -> None:
        message = heartbeat()
        message["future"] = {"optional": True}
        message["payload"]["futureCounter"] = 7
        self.assertEqual(decode_control_message(encode_control_message(message)), message)


class ControlResourceLimitTests(unittest.TestCase):
    def assert_error(self, code: str, callable_) -> None:
        with self.assertRaises(ProtocolViolation) as raised:
            callable_()
        self.assertEqual(raised.exception.code, code)

    def test_rejects_message_before_parsing_when_wire_size_exceeds_limit(self) -> None:
        self.assert_error(
            "MESSAGE_TOO_LARGE",
            lambda: decode_control_message(b" " * (MAX_CONTROL_MESSAGE_BYTES + 1)),
        )

    def test_rejects_invalid_utf8(self) -> None:
        self.assert_error("INVALID_UTF8", lambda: decode_control_message(b"\xff"))

    def test_rejects_excessive_nesting(self) -> None:
        message = heartbeat()
        nested: object = "leaf"
        for _ in range(MAX_JSON_DEPTH + 1):
            nested = {"n": nested}
        message["payload"]["future"] = nested
        self.assert_error("JSON_RESOURCE_LIMIT", lambda: validate_control_message(message))

    def test_rejects_oversized_array(self) -> None:
        message = heartbeat()
        message["payload"]["future"] = [0] * (MAX_ARRAY_ITEMS + 1)
        self.assert_error("JSON_RESOURCE_LIMIT", lambda: validate_control_message(message))

    def test_rejects_oversized_string_even_when_optional(self) -> None:
        message = heartbeat()
        message["payload"]["future"] = "x" * (MAX_STRING_BYTES + 1)
        self.assert_error("JSON_RESOURCE_LIMIT", lambda: validate_control_message(message))

    def test_rejects_bool_where_integer_is_required(self) -> None:
        self.assert_error("INVALID_FIELD", lambda: validate_control_message(heartbeat(sent_at=True)))

    def test_rejects_unpaired_surrogate(self) -> None:
        message = heartbeat()
        message["payload"]["future"] = "\ud800"
        self.assert_error("INVALID_UNICODE", lambda: validate_control_message(message))

    def test_rejects_integer_with_excessive_digits(self) -> None:
        wire = json.dumps(heartbeat()).replace("42", "9" * 65)
        self.assert_error("JSON_RESOURCE_LIMIT", lambda: decode_control_message(wire))

    def test_future_v1_minor_is_accepted_but_future_major_is_not(self) -> None:
        message = heartbeat()
        message["protocolVersion"] = "1.99"
        validate_control_message(message)
        message["protocolVersion"] = "3.0"
        self.assert_error("UNSUPPORTED_PROTOCOL_VERSION", lambda: validate_control_message(message))


class RequestLedgerTests(unittest.TestCase):
    def test_identical_duplicate_replays_cached_response(self) -> None:
        now = [100.0]
        ledger = RequestLedger(capacity=2, ttl_seconds=10, clock=lambda: now[0])
        message = heartbeat()
        self.assertFalse(ledger.observe(message).is_duplicate)
        ledger.complete("request-1", {"ok": True})
        duplicate = ledger.observe(copy.deepcopy(message))
        self.assertTrue(duplicate.is_duplicate)
        self.assertEqual(duplicate.cached_response, {"ok": True})

    def test_conflicting_request_id_is_rejected(self) -> None:
        ledger = RequestLedger()
        ledger.observe(heartbeat(sent_at=1))
        with self.assertRaises(ProtocolViolation) as raised:
            ledger.observe(heartbeat(sent_at=2))
        self.assertEqual(raised.exception.code, "DUPLICATE_REQUEST_CONFLICT")

    def test_expired_request_id_can_be_reused(self) -> None:
        now = [100.0]
        ledger = RequestLedger(ttl_seconds=2, clock=lambda: now[0])
        ledger.observe(heartbeat(sent_at=1))
        now[0] = 102.0
        self.assertFalse(ledger.observe(heartbeat(sent_at=2)).is_duplicate)

    def test_capacity_is_bounded_and_evicts_oldest(self) -> None:
        ledger = RequestLedger(capacity=1)
        ledger.observe(heartbeat("first", 1))
        ledger.observe(heartbeat("second", 2))
        self.assertFalse(ledger.observe(heartbeat("first", 3)).is_duplicate)

    def test_unknown_completion_id_is_rejected(self) -> None:
        ledger = RequestLedger()
        with self.assertRaises(ProtocolViolation) as raised:
            ledger.complete("never-seen", {"ok": True})
        self.assertEqual(raised.exception.code, "UNKNOWN_REQUEST_ID")


if __name__ == "__main__":
    unittest.main()
