"""Stdlib-only unit tests for frame_projection (plain dicts, no pydantic)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Allow `python -m unittest` from repo root without install.
_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from brain.frame_projection import (  # noqa: E402
    find_unit_by_name,
    project_for_follow_leader,
    project_self_location,
)

# follow is index 19 in POLICY_ACTION_KINDS (0-based).
FOLLOW_KIND_I = 19
MAX_ENTITIES = 65  # 0..64 inclusive slots in mask rows


def _empty_target_row() -> list[bool]:
    return [False] * MAX_ENTITIES


def _mask_with_follow(entity_index: int, *, follow_kind_enabled: bool = True) -> dict:
    kind_count = 50  # enough room past follow index 19
    kind = [False] * kind_count
    if follow_kind_enabled:
        kind[FOLLOW_KIND_I] = True
    target = [_empty_target_row() for _ in range(kind_count)]
    if follow_kind_enabled and 0 <= entity_index < MAX_ENTITIES:
        target[FOLLOW_KIND_I][entity_index] = True
    return {"kind": kind, "target": target}


def _frame(
    *,
    self_xy=(10.0, 20.0),
    in_group=True,
    leader_guid="100",
    leader_name="Leader",
    party_entity=None,
    party_members=None,
    follow_index=None,
    follow_enabled=True,
):
    entities = []
    if party_entity is not None:
        entities.append(party_entity)
    mask = _mask_with_follow(
        follow_index if follow_index is not None else 0,
        follow_kind_enabled=follow_enabled and follow_index is not None,
    )
    return {
        "observation": {
            "name": "Bot",
            "location": {"map_id": 0, "x": self_xy[0], "y": self_xy[1], "z": 30.0},
            "party": {
                "in_group": in_group,
                "leader_guid": leader_guid,
                "leader_name": leader_name,
                "invite_pending": False,
                "invite_from": "",
                "members": party_members or [],
            },
        },
        "bindings": {"entities": entities},
        "action_mask": mask,
        "action_space": None,  # force fallback kind index list
    }


class TestProjectForFollowLeader(unittest.TestCase):
    def test_no_observation(self):
        out = project_for_follow_leader({})
        self.assertIsNone(out["self_unit"])
        self.assertIsNone(out["party"]["leader_unit"])

    def test_self_unit_xy(self):
        out = project_for_follow_leader(_frame(in_group=False))
        self.assertEqual(out["self_unit"], {"x": 10.0, "y": 20.0})
        self.assertIsNone(out["party"]["leader_unit"])

    def test_leader_visible_when_party_binding_and_mask(self):
        entity = {
            "index": 2,
            "kind": "party",
            "guid": "100",
            "name": "Leader",
            "location": {"map_id": 0, "x": 40.0, "y": 50.0, "z": 30.0},
            "alive": True,
        }
        out = project_for_follow_leader(
            _frame(party_entity=entity, follow_index=2)
        )
        leader = out["party"]["leader_unit"]
        self.assertIsNotNone(leader)
        self.assertEqual(leader["id"], 2)
        self.assertEqual(leader["x"], 40.0)
        self.assertEqual(leader["y"], 50.0)
        self.assertTrue(leader["visible"])

    def test_leader_not_visible_when_mask_denies_follow(self):
        entity = {
            "index": 2,
            "kind": "party",
            "guid": "100",
            "name": "Leader",
            "location": {"map_id": 0, "x": 40.0, "y": 50.0, "z": 30.0},
            "alive": True,
        }
        out = project_for_follow_leader(
            _frame(party_entity=entity, follow_index=2, follow_enabled=False)
        )
        leader = out["party"]["leader_unit"]
        self.assertIsNotNone(leader)
        self.assertFalse(leader["visible"])

    def test_leader_not_visible_when_missing_binding(self):
        out = project_for_follow_leader(_frame(party_entity=None, follow_index=None))
        leader = out["party"]["leader_unit"]
        self.assertIsNotNone(leader)
        self.assertFalse(leader["visible"])
        self.assertEqual(leader["id"], 0)

    def test_match_leader_by_name_when_guid_differs(self):
        entity = {
            "index": 3,
            "kind": "party",
            "guid": "999",
            "name": "Leader",
            "location": {"map_id": 0, "x": 1.0, "y": 2.0, "z": 3.0},
            "alive": True,
        }
        # leader_guid won't match; name will.
        out = project_for_follow_leader(
            _frame(
                leader_guid="1",
                leader_name="Leader",
                party_entity=entity,
                follow_index=3,
            )
        )
        self.assertEqual(out["party"]["leader_unit"]["id"], 3)
        self.assertTrue(out["party"]["leader_unit"]["visible"])

    def test_project_self_location(self):
        loc = project_self_location(_frame())
        self.assertEqual(loc["x"], 10.0)
        self.assertEqual(loc["z"], 30.0)
        self.assertEqual(loc["map_id"], 0.0)

    def test_find_unit_by_name(self):
        frame = _frame(
            party_entity={
                "index": 2,
                "kind": "party",
                "guid": "100",
                "name": "Leader",
                "location": {"map_id": 0, "x": 7.0, "y": 8.0, "z": 9.0},
                "alive": True,
            },
            follow_index=2,
        )
        found = find_unit_by_name(frame, "leader")
        self.assertIsNotNone(found)
        self.assertEqual(found["index"], 2)
        self.assertEqual(found["x"], 7.0)


if __name__ == "__main__":
    unittest.main()
