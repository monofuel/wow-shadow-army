"""Smoke test: real lua5.3 subprocess for follow_leader (skipped if no lua)."""

from __future__ import annotations

import shutil
import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from brain import lua_runner  # noqa: E402


def _have_lua() -> bool:
    if shutil.which("lua5.3") or shutil.which("lua"):
        return True
    try:
        lua_runner.find_lua()
        return True
    except FileNotFoundError:
        return False


@unittest.skipUnless(_have_lua(), "lua5.3/lua not available (PATH or nix)")
class TestLuaRunner(unittest.TestCase):
    def test_hold_when_leader_not_visible(self):
        intent = lua_runner.decide(
            "follow_leader",
            {
                "self_unit": {"x": 0.0, "y": 0.0},
                "party": {
                    "leader_unit": {
                        "id": 7,
                        "x": 5.0,
                        "y": 0.0,
                        "visible": False,
                    }
                },
            },
        )
        self.assertIsNotNone(intent)
        self.assertEqual(intent["kind"], "hold")
        self.assertEqual(intent["reason"], "leader_not_visible")

    def test_move_when_far(self):
        intent = lua_runner.decide(
            "follow_leader",
            {
                "self_unit": {"x": 0.0, "y": 0.0},
                "party": {
                    "leader_unit": {
                        "id": 7,
                        "x": 50.0,
                        "y": 0.0,
                        "visible": True,
                    }
                },
            },
        )
        self.assertIsNotNone(intent)
        self.assertEqual(intent["kind"], "move_to_unit")
        self.assertEqual(intent["unit_id"], 7)
        self.assertTrue(intent["urgent"])


if __name__ == "__main__":
    unittest.main()
