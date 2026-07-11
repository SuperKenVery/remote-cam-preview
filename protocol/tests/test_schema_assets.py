from __future__ import annotations

import json
import unittest
from pathlib import Path


class SchemaAssetTests(unittest.TestCase):
    def test_schemas_and_vectors_are_strict_json(self) -> None:
        protocol_root = Path(__file__).resolve().parents[1]
        paths = sorted((protocol_root / "schemas" / "v1").glob("*.json"))
        paths += sorted((protocol_root / "vectors" / "v1").glob("*.json"))
        self.assertGreaterEqual(len(paths), 6)
        for path in paths:
            with self.subTest(path=path.name):
                with path.open("r", encoding="utf-8") as stream:
                    json.load(stream)

    def test_versioned_schema_identity_and_local_reference(self) -> None:
        root = Path(__file__).resolve().parents[1] / "schemas" / "v1"
        control = json.loads((root / "control-message.schema.json").read_text(encoding="utf-8"))
        photo = json.loads((root / "photo-metadata.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(control["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(photo["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertIn("/v1/", control["$id"])
        self.assertIn("/v1/", photo["$id"])
        self.assertTrue((root / "photo-metadata.schema.json").is_file())

    def test_access_token_is_required_by_accepted_schema(self) -> None:
        root = Path(__file__).resolve().parents[1] / "schemas" / "v1"
        control = json.loads((root / "control-message.schema.json").read_text(encoding="utf-8"))
        accepted = control["$defs"]["sessionAccepted"]
        self.assertIn("accessToken", accepted["required"])
        self.assertIn("accessToken", accepted["properties"])
        self.assertIn("photoEndpoint", accepted["required"])
        self.assertIn("photoEndpoint", accepted["properties"])


if __name__ == "__main__":
    unittest.main()
