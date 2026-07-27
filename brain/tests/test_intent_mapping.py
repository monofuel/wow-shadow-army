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

    def test_assist_unit(self):
        m = map_intent({"kind": "assist_unit", "unit_id": 2, "reason": "mirror_leader_target"})
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "assist")
        self.assertEqual(m.target, 2)
        self.assertEqual(
            mapped_to_factorized_kwargs(m),
            {"kind": "assist", "target": 2},
        )

    def test_attack_unit(self):
        m = map_intent({"kind": "attack_unit", "unit_id": 5})
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "attack")
        self.assertEqual(m.target, 5)
        self.assertEqual(
            mapped_to_factorized_kwargs(m),
            {"kind": "attack", "target": 5},
        )

    def test_assist_invalid_id_skips(self):
        m = map_intent({"kind": "assist_unit", "unit_id": 0})
        self.assertTrue(m.skip)

    def test_accept_party(self):
        m = map_intent({"kind": "accept_party", "reason": "invite_from:Murist"})
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "accept_party")
        self.assertEqual(mapped_to_factorized_kwargs(m), {"kind": "accept_party"})

    def test_cast_spell(self):
        m = map_intent(
            {
                "kind": "cast_spell",
                "unit_id": 5,
                "spell": 22,
                "reason": "shadow_bolt:shadow bolt",
            }
        )
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "cast")
        self.assertEqual(m.target, 5)
        self.assertEqual(m.spell, 22)
        self.assertEqual(
            mapped_to_factorized_kwargs(m),
            {"kind": "cast", "target": 5, "spell": 22},
        )

    def test_move_to_unit_with_xyz_is_destination(self):
        m = map_intent(
            {
                "kind": "move_to_unit",
                "unit_id": 2,
                "x": 1644.0,
                "y": 1662.0,
                "z": 132.0,
                "map_id": 0,
                "reason": "rejoin_formation_vertical",
            }
        )
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "move")
        self.assertEqual(m.destination["z"], 132.0)
        kwargs = mapped_to_factorized_kwargs(m)
        self.assertEqual(kwargs["kind"], "move")
        self.assertEqual(kwargs["destination"]["z"], 132.0)

    def test_release_spirit(self):
        m = map_intent({"kind": "release_spirit", "reason": "release_spirit"})
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "release_spirit")
        self.assertEqual(
            mapped_to_factorized_kwargs(m),
            {"kind": "release_spirit"},
        )

    def test_reclaim_corpse(self):
        m = map_intent({"kind": "reclaim_corpse"})
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "reclaim_corpse")
        self.assertEqual(mapped_to_factorized_kwargs(m), {"kind": "reclaim_corpse"})

    def test_move_to_corpse(self):
        m = map_intent(
            {
                "kind": "move_to_corpse",
                "map_id": 0,
                "x": 2040.0,
                "y": 1840.0,
                "z": 106.0,
                "reason": "move_to_corpse",
            }
        )
        self.assertFalse(m.skip)
        self.assertEqual(m.kind, "move")
        self.assertEqual(m.destination["x"], 2040.0)
        kwargs = mapped_to_factorized_kwargs(m)
        self.assertEqual(kwargs["kind"], "move")
        self.assertEqual(kwargs["destination"]["y"], 1840.0)


if __name__ == "__main__":
    unittest.main()
