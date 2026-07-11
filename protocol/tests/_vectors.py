from __future__ import annotations

import json
from pathlib import Path
from typing import Any

VECTOR_ROOT = Path(__file__).resolve().parents[1] / "vectors" / "v1"


def load_vector(name: str) -> dict[str, Any]:
    with (VECTOR_ROOT / name).open("r", encoding="utf-8") as stream:
        return json.load(stream)

