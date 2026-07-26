"""Stdlib unit tests for brain.grind_policy (no pydantic, no realm)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from brain.grind_policy import (  # noqa: E402
    CAST_RANGE,
    CRITTER_ENTRIES,
    DEFAULT_GRIND_ENTRIES,
    ENTRY_RATTLECAGE,
    ENTRY_VENYA,
    POLICY_KIND_NAMES,
    PolicyConfig,
    PolicyState,
    QUEST_1470,
    SUMMON_IMP_SPELL,
    current_phase,
    decide_action,
    eligible_hostiles,
    inventory_count,
    masked_kinds,
    quest_in_log,
)


def _kind_mask(*enabled: str) -> list[bool]:
    return [k in enabled for k in POLICY_KIND_NAMES]


def _frame(
    *,
    x: float = 1876.0,
    y: float = 1610.0,
    z: float = 94.0,
    level: int = 1,
    xp: int = 0,
    hp: int = 63,
    max_hp: int = 63,
    mana: int = 100,
    max_mana: int = 100,
    in_combat: bool = False,
    kinds: tuple[str, ...] = ("noop", "move", "target", "attack", "cast", "loot", "interact"),
    entities: list | None = None,
    units: list | None = None,
    spells: list | None = None,
    spell_mask: list | None = None,
    quest_log: list | None = None,
    completed: list | None = None,
    rewarded: list | None = None,
    known_spells: list | None = None,
    inventory: list | None = None,
    items: list | None = None,
) -> dict:
    ents = entities if entities is not None else []
    return {
        "policy_kind_names": POLICY_KIND_NAMES,
        "observation": {
            "location": {"map_id": 0, "x": x, "y": y, "z": z},
            "level": level,
            "xp": xp,
            "next_level_xp": 400,
            "health": hp,
            "max_health": max_hp,
            "active_power_type_known": True,
            "active_power_type": 0,
            "active_power_known": True,
            "active_power": mana,
            "active_max_power": max_mana,
            "in_combat": in_combat,
            "is_dead": False,
            "is_ghost": False,
            "can_reclaim_corpse": False,
            "eating": False,
            "drinking": False,
            "auto_attack_guid": "",
            "units": units or [],
            "quest_log_quest_ids": quest_log or [],
            "completed_quest_ids": completed or [],
            "rewarded_quest_ids": rewarded or [],
            "known_spells": known_spells or [],
            "inventory_items": inventory or [],
            "quest_offers": [],
            "quest_markers": [],
        },
        "bindings": {
            "entities": ents,
            "spells": spells
            or [
                {"index": 1, "spell_id": 686, "name": "Shadow Bolt"},
            ],
            "items": items or [],
            "quests": [],
        },
        "action_mask": {
            "kind": _kind_mask(*kinds),
            "spell": spell_mask
            if spell_mask is not None
            else [[False, False], [False, True]],
        },
    }


class TestMaskedKinds(unittest.TestCase):
    def test_reads_enabled_kinds(self):
        f = _frame(kinds=("move", "cast"))
        self.assertIn("move", masked_kinds(f))
        self.assertIn("cast", masked_kinds(f))
        self.assertNotIn("accept_quest", masked_kinds(f))


class TestEligibleHostiles(unittest.TestCase):
    def test_filters_critters_and_unknown_entries(self):
        f = _frame(
            entities=[
                {
                    "index": 2,
                    "kind": "unit",
                    "guid": "g-rabbit",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    "location": {"x": 1880.0, "y": 1610.0, "z": 94.0},
                },
                {
                    "index": 3,
                    "kind": "unit",
                    "guid": "g-zombie",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    "location": {"x": 1885.0, "y": 1610.0, "z": 94.0},
                },
            ],
            units=[
                {"guid": "g-rabbit", "entry": 721, "level": 1, "distance": 4.0},
                {"guid": "g-zombie", "entry": 1501, "level": 1, "distance": 9.0},
            ],
        )
        cfg = PolicyConfig()
        state = PolicyState(anchor=(1876.0, 1610.0, 94.0))
        got = eligible_hostiles(f, cfg, state)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0][0]["guid"], "g-zombie")
        self.assertIn(721, CRITTER_ENTRIES)
        self.assertIn(1501, DEFAULT_GRIND_ENTRIES)


class TestDecideCombat(unittest.TestCase):
    def test_casts_shadow_bolt_in_range(self):
        f = _frame(
            entities=[
                {
                    "index": 1,
                    "kind": "unit",
                    "guid": "g1",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    "location": {"x": 1890.0, "y": 1610.0, "z": 94.0},
                }
            ],
            units=[{"guid": "g1", "entry": 1501, "level": 1, "distance": 14.0}],
            spell_mask=[[False, False], [False, True]],
            kinds=("move", "cast", "target", "attack"),
        )
        act, why = decide_action(f, PolicyConfig(seek_quest=False), PolicyState())
        self.assertIsNotNone(act)
        assert act is not None
        self.assertEqual(act["kind"], "cast")
        self.assertEqual(act["target"], 1)
        self.assertEqual(act["spell"], 1)
        self.assertIn("Shadow Bolt", why)

    def test_destination_approach_when_out_of_cast_range(self):
        f = _frame(
            entities=[
                {
                    "index": 1,
                    "kind": "unit",
                    "guid": "g1",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    # ~36yd east — outside cast range but inside 40yd engage cut-off
                    "location": {"x": 1912.0, "y": 1610.0, "z": 94.0},
                }
            ],
            units=[{"guid": "g1", "entry": 1501, "level": 1, "distance": 36.0}],
            spell_mask=[[False, False], [False, False]],
            kinds=("move", "cast", "target", "attack"),
        )
        act, why = decide_action(f, PolicyConfig(seek_quest=False), PolicyState())
        self.assertIsNotNone(act)
        assert act is not None
        self.assertEqual(act["kind"], "move")
        self.assertIn("destination", act)
        self.assertIn("approach", why)
        # Destination steps only — unit-target move is not used outdoors.
        self.assertNotIn("target", act)
        # Step should move east toward target.
        self.assertGreater(act["destination"]["x"], 1876.0)

    def test_blacklist_after_stagnant_approach(self):
        f = _frame(
            entities=[
                {
                    "index": 1,
                    "kind": "unit",
                    "guid": "stuck-mob",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    "location": {"x": 1912.0, "y": 1610.0, "z": 94.0},
                }
            ],
            units=[{"guid": "stuck-mob", "entry": 1501, "level": 1, "distance": 36.0}],
            spell_mask=[[False, False], [False, False]],
            kinds=("move", "cast", "target", "attack"),
        )
        state = PolicyState(
            last_approach_guid="stuck-mob",
            last_approach_dist=36.0,
            approach_fails=8,
        )
        act, why = decide_action(f, PolicyConfig(seek_quest=False), state)
        self.assertIsNone(act)
        self.assertIn("blacklist_stuck_approach", why)
        self.assertIn("stuck-mob", state.blacklist)

    def test_loot_priority(self):
        f = _frame(
            entities=[
                {
                    "index": 2,
                    "kind": "unit",
                    "guid": "corpse",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": False,
                    "lootable": True,
                    "location": {"x": 1877.0, "y": 1610.0, "z": 94.0},
                }
            ],
            kinds=("loot", "move", "cast"),
        )
        act, why = decide_action(f, PolicyConfig(), PolicyState())
        self.assertEqual(act, {"kind": "loot", "target": 2})
        self.assertEqual(why, "loot")


class TestQuestPhases(unittest.TestCase):
    def test_accept_when_venya_close_and_mask_allows(self):
        f = _frame(
            x=1837.0,
            y=1633.0,
            z=97.0,
            entities=[
                {
                    "index": 5,
                    "kind": "unit",
                    "guid": "venya",
                    "name": "creature",
                    "reaction": "friendly",
                    "alive": True,
                    "lootable": False,
                    "services": ["questgiver"],
                    "location": {"x": 1836.94, "y": 1633.43, "z": 97.02},
                }
            ],
            units=[{"guid": "venya", "entry": ENTRY_VENYA, "level": 10, "distance": 1.0}],
            kinds=("move", "interact", "accept_quest"),
        )
        state = PolicyState()
        act, why = decide_action(f, PolicyConfig(seek_quest=True), state)
        self.assertIsNotNone(act)
        assert act is not None
        self.assertEqual(act["kind"], "accept_quest")
        self.assertEqual(act["target"], 5)
        self.assertIn(str(QUEST_1470), why)

    def test_interact_when_accept_not_masked(self):
        f = _frame(
            x=1837.0,
            y=1633.0,
            z=97.0,
            entities=[
                {
                    "index": 5,
                    "kind": "unit",
                    "guid": "venya",
                    "name": "creature",
                    "reaction": "friendly",
                    "alive": True,
                    "lootable": False,
                    "services": ["questgiver"],
                    "location": {"x": 1836.94, "y": 1633.43, "z": 97.02},
                }
            ],
            units=[{"guid": "venya", "entry": ENTRY_VENYA, "level": 10, "distance": 1.0}],
            kinds=("move", "interact"),  # no accept_quest — stock upstream
        )
        act, why = decide_action(f, PolicyConfig(seek_quest=True), PolicyState())
        self.assertEqual(act, {"kind": "interact", "target": 5})
        self.assertEqual(why, "interact_venya")

    def test_marks_accept_blocked_after_repeated_proximity(self):
        f = _frame(
            x=1837.0,
            y=1633.0,
            z=97.0,
            entities=[
                {
                    "index": 5,
                    "kind": "unit",
                    "guid": "venya",
                    "name": "creature",
                    "reaction": "friendly",
                    "alive": True,
                    "lootable": False,
                    "services": ["questgiver"],
                    "location": {"x": 1836.94, "y": 1633.43, "z": 97.02},
                }
            ],
            units=[{"guid": "venya", "entry": ENTRY_VENYA, "level": 10, "distance": 1.0}],
            kinds=("move",),  # no interact, no accept
        )
        state = PolicyState(venya_seen_ticks=8)
        act, why = decide_action(f, PolicyConfig(seek_quest=True), state)
        self.assertIsNone(act)
        self.assertTrue(state.quest_accept_blocked)
        self.assertIn("blocked", why)

    def test_objectives_prefer_skeletons_phase(self):
        f = _frame(quest_log=[QUEST_1470])
        self.assertTrue(quest_in_log(f, QUEST_1470))
        self.assertEqual(
            current_phase(f, PolicyConfig(), PolicyState()), "objectives"
        )

    def test_turnin_phase_when_completed(self):
        f = _frame(quest_log=[QUEST_1470], completed=[QUEST_1470])
        self.assertEqual(current_phase(f, PolicyConfig(), PolicyState()), "turnin")

    def test_imp_known_ends_quest_loop(self):
        f = _frame(known_spells=[SUMMON_IMP_SPELL])
        state = PolicyState()
        self.assertEqual(current_phase(f, PolicyConfig(), state), "grind")
        self.assertTrue(state.turnin_done)

    def test_inventory_skull_count(self):
        f = _frame(
            inventory=[
                {"item_id": 6281, "count": 2},
                {"item_id": 117, "count": 5},
            ]
        )
        self.assertEqual(inventory_count(f, 6281), 2)


class TestManaAndStopAttack(unittest.TestCase):
    def test_uses_power_pool_zero_for_mana(self):
        from brain.grind_policy import _mana_percent

        obs = {
            "powers": [22, 0, 100],
            "max_powers": [110, 0, 100],
            "active_power_type_known": True,
            "active_power_type": 2,  # pet focus latch
            "active_power_known": True,
            "active_power": 100,
            "active_max_power": 100,
        }
        self.assertAlmostEqual(_mana_percent(obs), 100.0 * 22 / 110, places=2)

    def test_stop_attack_when_auto_target_far(self):
        f = _frame(
            in_combat=True,
            kinds=("stop_attack", "move", "cast", "attack"),
            entities=[
                {
                    "index": 3,
                    "kind": "unit",
                    "guid": "far",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    "location": {"x": 2000.0, "y": 1610.0, "z": 94.0},
                }
            ],
            units=[
                {
                    "guid": "far",
                    "entry": 1501,
                    "level": 1,
                    "distance": 80.0,
                    "health": 50,
                    "max_health": 100,
                }
            ],
        )
        f["observation"]["auto_attack_guid"] = "far"
        f["observation"]["powers"] = [10, 0, 0]
        f["observation"]["max_powers"] = [110, 0, 0]
        act, why = decide_action(f, PolicyConfig(rest_mana=40), PolicyState())
        self.assertEqual(act, {"kind": "stop_attack"})
        self.assertIn("stop_attack", why)

    def test_break_hold_auto_attack_after_empty_cast_ticks(self):
        """Full mana + latched AA + no cast mask must not park forever."""
        f = _frame(
            in_combat=True,
            mana=100,
            max_mana=100,
            kinds=("stop_attack", "move", "cast", "attack"),
            entities=[
                {
                    "index": 10,
                    "kind": "unit",
                    "guid": "stuck",
                    "name": "creature",
                    "reaction": "hostile",
                    "alive": True,
                    "lootable": False,
                    "location": {"x": 1888.0, "y": 1610.0, "z": 94.0},
                }
            ],
            units=[
                {
                    "guid": "stuck",
                    "entry": 1501,
                    "level": 1,
                    "distance": 12.0,
                    "health": 40,
                    "max_health": 100,
                }
            ],
            # No cast row allows Shadow Bolt on target 10.
            spell_mask=[[False, False]] * 12,
        )
        f["observation"]["auto_attack_guid"] = "stuck"
        f["observation"]["powers"] = [100, 0, 0]
        f["observation"]["max_powers"] = [100, 0, 0]
        state = PolicyState(hold_ticks=3, hold_guid="stuck")
        act, why = decide_action(f, PolicyConfig(seek_quest=False, rest_mana=20), state)
        self.assertEqual(act, {"kind": "stop_attack"})
        self.assertIn("break_hold", why)


class TestCastRangeConstant(unittest.TestCase):
    def test_cast_range_exceeds_melee(self):
        self.assertGreater(CAST_RANGE, 10.0)
        self.assertIn(ENTRY_RATTLECAGE, DEFAULT_GRIND_ENTRIES)


if __name__ == "__main__":
    unittest.main()
