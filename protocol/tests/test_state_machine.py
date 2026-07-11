from __future__ import annotations

import unittest

from protocol.reference.errors import ProtocolViolation
from protocol.reference.state_machine import SessionState, SessionStateMachine

from ._vectors import load_vector


class SessionStateVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = load_vector("session-state.json")

    def test_valid_state_sequences(self) -> None:
        for vector in self.vectors["valid"]:
            with self.subTest(vector=vector["name"]):
                machine = SessionStateMachine(SessionState(vector["initial"]))
                actual = [machine.apply(event).value for event in vector["events"]]
                self.assertEqual(actual, vector["expectedStates"])
                self.assertEqual(len(machine.history), len(vector["events"]))

    def test_invalid_transition_does_not_mutate_state(self) -> None:
        for vector in self.vectors["invalid"]:
            with self.subTest(vector=vector["name"]):
                machine = SessionStateMachine(SessionState(vector["initial"]))
                for index, event in enumerate(vector["events"]):
                    if index == vector["expectedErrorAt"]:
                        with self.assertRaises(ProtocolViolation) as raised:
                            machine.apply(event)
                        self.assertEqual(raised.exception.code, vector["expectedError"])
                        break
                    machine.apply(event)
                self.assertEqual(machine.state.value, vector["expectedFinalState"])

    def test_capability_loss_is_global_except_from_terminal_state(self) -> None:
        for state in SessionState:
            machine = SessionStateMachine(state)
            if state is SessionState.ENDED:
                with self.assertRaises(ProtocolViolation):
                    machine.apply("capabilityLost")
            elif state is SessionState.UNAVAILABLE:
                with self.assertRaises(ProtocolViolation):
                    machine.apply("capabilityLost")
            else:
                self.assertEqual(machine.apply("capabilityLost"), SessionState.UNAVAILABLE)


if __name__ == "__main__":
    unittest.main()

