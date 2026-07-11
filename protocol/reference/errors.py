"""Errors shared by the reference protocol modules."""

from __future__ import annotations


class ProtocolViolation(ValueError):
    """A deterministic, wire-friendly rejection of untrusted input."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    def __str__(self) -> str:
        return f"{self.code}: {self.message}"

