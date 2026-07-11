from __future__ import annotations

import io
import tempfile
import unittest
from pathlib import Path

from protocol.reference.errors import ProtocolViolation
from protocol.reference.photo import (
    commit_verified_temp,
    stream_to_verified_temp,
    validate_photo_metadata,
    verify_file,
    verify_stream,
)

from ._vectors import load_vector


class PhotoVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = load_vector("photo-integrity.json")

    def test_valid_metadata_vectors(self) -> None:
        for vector in self.vectors["validMetadata"]:
            with self.subTest(vector=vector["name"]):
                self.assertEqual(validate_photo_metadata(vector["metadata"]), vector["metadata"])

    def test_invalid_metadata_vectors(self) -> None:
        for vector in self.vectors["invalidMetadata"]:
            with self.subTest(vector=vector["name"]):
                with self.assertRaises(ProtocolViolation) as raised:
                    validate_photo_metadata(vector["metadata"])
                self.assertEqual(raised.exception.code, vector["expectedError"])

    def test_integrity_vectors(self) -> None:
        for vector in self.vectors["integrity"]:
            with self.subTest(vector=vector["name"]):
                content = bytes.fromhex(vector["contentHex"])
                if vector["valid"]:
                    result = verify_stream(
                        io.BytesIO(content),
                        expected_size=vector["expectedSize"],
                        expected_sha256=vector["expectedSha256"],
                        chunk_size=3,
                    )
                    self.assertEqual(result.byte_size, vector["expectedSize"])
                    self.assertEqual(result.sha256, vector["expectedSha256"])
                else:
                    with self.assertRaises(ProtocolViolation) as raised:
                        verify_stream(
                            io.BytesIO(content),
                            expected_size=vector["expectedSize"],
                            expected_sha256=vector["expectedSha256"],
                            chunk_size=3,
                        )
                    self.assertEqual(raised.exception.code, vector["expectedError"])


class RecordingStream(io.BytesIO):
    def __init__(self, data: bytes) -> None:
        super().__init__(data)
        self.requests: list[int] = []

    def read(self, size: int = -1) -> bytes:
        self.requests.append(size)
        return super().read(size)


class PhotoStreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        vectors = load_vector("photo-integrity.json")
        cls.metadata = vectors["validMetadata"][0]["metadata"]
        cls.content = bytes.fromhex(vectors["integrity"][0]["contentHex"])

    def test_verifier_uses_bounded_reads(self) -> None:
        stream = RecordingStream(self.content)
        verify_stream(
            stream,
            expected_size=len(self.content),
            expected_sha256=self.metadata["sha256"],
            chunk_size=4,
        )
        self.assertTrue(all(0 < request <= 4 for request in stream.requests))

    def test_stream_to_temp_then_atomic_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory) / "incoming.tmp"
            final = Path(directory) / self.metadata["fileName"]
            stream_to_verified_temp(io.BytesIO(self.content), temporary, self.metadata, chunk_size=5)
            self.assertEqual(verify_file(temporary, self.metadata).sha256, self.metadata["sha256"])
            commit_verified_temp(temporary, final)
            self.assertFalse(temporary.exists())
            self.assertEqual(final.read_bytes(), self.content)

    def test_failed_integrity_removes_temp_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory) / "incoming.tmp"
            with self.assertRaises(ProtocolViolation) as raised:
                stream_to_verified_temp(io.BytesIO(self.content[:-1]), temporary, self.metadata)
            self.assertEqual(raised.exception.code, "PHOTO_LENGTH_MISMATCH")
            self.assertFalse(temporary.exists())

    def test_exclusive_temp_creation_does_not_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory) / "incoming.tmp"
            temporary.write_bytes(b"owned by another transfer")
            with self.assertRaises(FileExistsError):
                stream_to_verified_temp(io.BytesIO(self.content), temporary, self.metadata)
            # The cleanup path must not delete a pre-existing file it did not create.
            self.assertTrue(temporary.exists())


if __name__ == "__main__":
    unittest.main()

