#!/usr/bin/env python3
"""Run all protocol reference tests using only the Python standard library."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))


def main() -> int:
    suite = unittest.defaultTestLoader.discover(
        str(Path(__file__).resolve().parent / "tests"),
        top_level_dir=str(REPOSITORY_ROOT),
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())

