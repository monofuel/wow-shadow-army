"""Stdlib-only unit tests for intent_mapping."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from brain.intent_mapping import map_intent, mapped_to_factorized_kwargs  # noqa: E402


class TestMapIntent(unittest.TestCase):
    def test_nil_skips(self):
        m = map_intent(None)
        self.assertTrue(m.skip)
        self.assertIsNone(mapped_to_factorized_kwargs(m))

    def test_hold_skips(self):
        m = map_intent({"kind": "hold", "reason": "in_formation"})
        self.assertTrue(m.skip)
        self.assertEqual(m.reason, "in_formation")
        self.assertIsNone(mapped_to_factorized_kwargs(m))

    def test_move_to_unit_becomes_follow(self):
        m = map_intent({"kind": "move_to_unit", "unit_id": 7, "stop_range": 8.0})
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "follow")
        self.assertEqual(m.target, 7)
        kwargs = mapped_to_factorized_kwargs(m)
        self.assertEqual(kwargs, {"kind": "follow", "target": 7})

    def test_move_to_unit_invalid_id_skips(self):
        m = map_intent({"kind": "move_to_unit", "unit_id": 0})
        self.assertTrue(m.skip)

    def test_move_fallback_destination(self):
        dest = {"map_id": 0, "x": 1.0, "y": 2.0, "z": 3.0}
        m = map_intent(
            {"kind": "move_to_unit", "unit_id": 7},
            prefer_move_destination=dest,
        )
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "move")
        self.assertEqual(m.target, 0)
        kwargs = mapped_to_factorized_kwargs(m)
        self.assertEqual(kwargs["kind"], "move")
        self.assertEqual(kwargs["destination"]["x"], 1.0)
        self.assertEqual(kwargs["destination"]["map_id"], 0)

    def test_unknown_kind_skips(self):
        m = map_intent({"kind": "dance"})
        self.assertTrue(m.skip)
        self.assertIn("unknown_intent", m.reason)


if __name__ == "__main__":
    unittest.main()
