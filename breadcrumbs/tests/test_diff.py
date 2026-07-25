"""Stdlib-only unit tests for breadcrumb diff + TSV parsing (no DB)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from breadcrumbs.poller import (  # noqa: E402
    POSITION_EPSILON,
    QUEST_STATUS_COMPLETE,
    QUEST_STATUS_INCOMPLETE,
    append_events,
    build_snapshot,
    character_row_from_tsv,
    default_session_dir,
    diff_snapshots,
    inventory_from_tsv,
    parse_tsv,
    quests_from_tsv,
    skills_from_tsv,
    spells_from_tsv,
    sql_quote_name,
    write_manifest,
)


def _char(**overrides):
    base = {
        "guid": 1000007,
        "name": "Murist",
        "level": 1,
        "xp": 0,
        "map": 0,
        "x": 100.0,
        "y": 200.0,
        "z": 50.0,
        "orientation": 1.5,
        "health": 100,
        "power1": 0,
        "death_expire_time": 0,
        "online": 1,
    }
    base.update(overrides)
    return base


def _snap(character=None, quests=None, inventory=None, skills=None, spells=None):
    return build_snapshot(
        character or _char(),
        quests or {},
        inventory or {},
        skills or {},
        spells or set(),
    )


class TestParseTsv(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(parse_tsv(""), [])
        self.assertEqual(parse_tsv("\n\n"), [])

    def test_rows(self):
        tsv = "a\tb\tc\n1\t2\t3\n"
        self.assertEqual(parse_tsv(tsv), [["a", "b", "c"], ["1", "2", "3"]])


class TestRowBuilders(unittest.TestCase):
    def test_character_row(self):
        row = [
            "1000007",
            "Murist",
            "5",
            "1200",
            "0",
            "1.5",
            "2.5",
            "3.5",
            "0.1",
            "80",
            "40",
            "0",
            "1",
        ]
        ch = character_row_from_tsv(row)
        self.assertEqual(ch["guid"], 1000007)
        self.assertEqual(ch["name"], "Murist")
        self.assertEqual(ch["level"], 5)
        self.assertEqual(ch["xp"], 1200)
        self.assertAlmostEqual(ch["x"], 1.5)
        self.assertEqual(ch["online"], 1)

    def test_quests_inventory_skills_spells(self):
        quests = quests_from_tsv(
            [["33", "3", "0", "0", "1", "0", "0", "0", "2", "0", "0", "0"]]
        )
        self.assertEqual(quests[33]["status"], QUEST_STATUS_INCOMPLETE)
        self.assertEqual(quests[33]["mob_counts"], [1, 0, 0, 0])
        self.assertEqual(quests[33]["item_counts"], [2, 0, 0, 0])

        inv = inventory_from_tsv([["6948", "1"], ["6948", "2"], ["117", "5"]])
        self.assertEqual(inv[6948], 3)
        self.assertEqual(inv[117], 5)

        skills = skills_from_tsv([["95", "50"], ["162", "10"]])
        self.assertEqual(skills[95], 50)

        spells = spells_from_tsv([["78", "1", "0"], ["99", "1", "1"]])
        self.assertEqual(spells, {78})  # disabled skipped


class TestSqlQuoteName(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(sql_quote_name("Murist"), "Murist")
        self.assertEqual(sql_quote_name("Bot_1"), "Bot_1")

    def test_rejects_injection(self):
        with self.assertRaises(ValueError):
            sql_quote_name("x'; DROP TABLE")
        with self.assertRaises(ValueError):
            sql_quote_name("O'Brien")


class TestDiffSnapshots(unittest.TestCase):
    def test_session_start_only_when_no_prev(self):
        events = diff_snapshots(None, _snap(), ts="T0")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "session_start")
        self.assertEqual(events[0]["character"], "Murist")
        self.assertEqual(events[0]["ts"], "T0")

    def test_level_up(self):
        prev = _snap(_char(level=1, xp=400))
        curr = _snap(_char(level=2, xp=10))
        kinds = [e["kind"] for e in diff_snapshots(prev, curr, ts="T1")]
        self.assertIn("level_up", kinds)
        self.assertNotIn("xp_gain", kinds)  # level change supersedes xp noise
        lu = next(e for e in diff_snapshots(prev, curr, ts="T1") if e["kind"] == "level_up")
        self.assertEqual(lu["from_level"], 1)
        self.assertEqual(lu["to_level"], 2)

    def test_xp_gain(self):
        prev = _snap(_char(level=3, xp=100))
        curr = _snap(_char(level=3, xp=250))
        events = diff_snapshots(prev, curr, ts="T2")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "xp_gain")
        self.assertEqual(events[0]["delta"], 150)

    def test_no_hp_mana_events(self):
        prev = _snap(_char(health=100, power1=50))
        curr = _snap(_char(health=10, power1=0))
        events = diff_snapshots(prev, curr, ts="T3")
        kinds = {e["kind"] for e in events}
        self.assertNotIn("hp", kinds)
        self.assertNotIn("mana", kinds)
        self.assertEqual(events, [])  # health/power alone → nothing

    def test_position_move_and_epsilon(self):
        prev = _snap(_char(x=0.0, y=0.0, z=0.0))
        tiny = _snap(_char(x=0.1, y=0.0, z=0.0))
        big = _snap(_char(x=10.0, y=0.0, z=0.0))
        self.assertEqual(diff_snapshots(prev, tiny, ts="T4"), [])
        events = diff_snapshots(prev, big, ts="T5")
        self.assertEqual(events[0]["kind"], "position")
        self.assertAlmostEqual(events[0]["x"], 10.0)

        # map change always counts
        other_map = _snap(_char(map=1, x=0.0, y=0.0, z=0.0))
        events = diff_snapshots(prev, other_map, ts="T6")
        self.assertEqual(events[0]["kind"], "position")
        self.assertEqual(events[0]["map"], 1)

        # custom epsilon
        mid = _snap(_char(x=0.4, y=0.0, z=0.0))
        self.assertEqual(
            diff_snapshots(prev, mid, ts="T7", position_epsilon=POSITION_EPSILON),
            [],
        )
        self.assertEqual(
            len(diff_snapshots(prev, mid, ts="T8", position_epsilon=0.1)),
            1,
        )

    def test_death_via_expire_time(self):
        prev = _snap(_char(death_expire_time=0, health=100))
        curr = _snap(_char(death_expire_time=1700000000, health=0))
        events = diff_snapshots(prev, curr, ts="Td")
        self.assertEqual(events[0]["kind"], "death")

    def test_death_via_health_zero(self):
        prev = _snap(_char(health=40, death_expire_time=0))
        curr = _snap(_char(health=0, death_expire_time=0))
        events = diff_snapshots(prev, curr, ts="Td2")
        self.assertEqual([e["kind"] for e in events], ["death"])

    def test_quest_accepted_objective_completed_rewarded(self):
        prev = _snap(quests={})
        accepted = _snap(
            quests={
                33: {
                    "status": QUEST_STATUS_INCOMPLETE,
                    "rewarded": 0,
                    "explored": 0,
                    "mob_counts": [0, 0, 0, 0],
                    "item_counts": [0, 0, 0, 0],
                }
            }
        )
        e1 = diff_snapshots(prev, accepted, ts="Q1")
        self.assertEqual(e1[0]["kind"], "quest_accepted")
        self.assertEqual(e1[0]["quest"], 33)

        progressed = _snap(
            quests={
                33: {
                    "status": QUEST_STATUS_INCOMPLETE,
                    "rewarded": 0,
                    "explored": 0,
                    "mob_counts": [2, 0, 0, 0],
                    "item_counts": [0, 0, 0, 0],
                }
            }
        )
        e2 = diff_snapshots(accepted, progressed, ts="Q2")
        self.assertEqual(e2[0]["kind"], "quest_objective")
        self.assertEqual(e2[0]["mob_counts"], [2, 0, 0, 0])

        done = _snap(
            quests={
                33: {
                    "status": QUEST_STATUS_COMPLETE,
                    "rewarded": 0,
                    "explored": 0,
                    "mob_counts": [2, 0, 0, 0],
                    "item_counts": [0, 0, 0, 0],
                }
            }
        )
        e3 = diff_snapshots(progressed, done, ts="Q3")
        self.assertEqual(e3[0]["kind"], "quest_completed")

        rewarded = _snap(
            quests={
                33: {
                    "status": QUEST_STATUS_COMPLETE,
                    "rewarded": 1,
                    "explored": 0,
                    "mob_counts": [2, 0, 0, 0],
                    "item_counts": [0, 0, 0, 0],
                }
            }
        )
        e4 = diff_snapshots(done, rewarded, ts="Q4")
        self.assertEqual(e4[0]["kind"], "quest_rewarded")

    def test_item_gained_and_lost(self):
        prev = _snap(inventory={6948: 1, 117: 5})
        curr = _snap(inventory={6948: 1, 117: 2, 2589: 3})
        events = diff_snapshots(prev, curr, ts="I1")
        by_kind = {(e["kind"], e["item_id"]): e for e in events}
        self.assertEqual(by_kind[("item_lost", 117)]["count"], 3)
        self.assertEqual(by_kind[("item_gained", 2589)]["count"], 3)
        self.assertNotIn(("item_gained", 6948), by_kind)

    def test_skill_up_and_spell_learned(self):
        prev = _snap(skills={95: 10}, spells={78})
        curr = _snap(skills={95: 25, 162: 1}, spells={78, 6603})
        events = diff_snapshots(prev, curr, ts="S1")
        kinds = [e["kind"] for e in events]
        self.assertEqual(kinds.count("skill_up"), 2)
        self.assertIn("spell_learned", kinds)
        spell = next(e for e in events if e["kind"] == "spell_learned")
        self.assertEqual(spell["spell"], 6603)

    def test_no_event_when_identical(self):
        snap = _snap(
            inventory={1: 2},
            skills={95: 5},
            spells={78},
            quests={
                1: {
                    "status": 3,
                    "rewarded": 0,
                    "explored": 0,
                    "mob_counts": [0, 0, 0, 0],
                    "item_counts": [0, 0, 0, 0],
                }
            },
        )
        self.assertEqual(diff_snapshots(snap, snap, ts="Z"), [])


class TestSessionIo(unittest.TestCase):
    def test_manifest_and_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdir = Path(tmp) / "sess"
            path = write_manifest(
                sdir,
                character="Murist",
                started_at="2026-07-25T00:00:00.000Z",
                realm="local-vmangos",
            )
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(data["character"], "Murist")
            self.assertEqual(data["realm"], "local-vmangos")
            self.assertIn("started_at", data)

            events_path = sdir / "events.jsonl"
            append_events(
                events_path,
                [
                    {"ts": "T0", "kind": "session_start", "character": "Murist"},
                    {"ts": "T1", "kind": "xp_gain", "delta": 10},
                ],
            )
            lines = events_path.read_text(encoding="utf-8").strip().splitlines()
            self.assertEqual(len(lines), 2)
            self.assertEqual(json.loads(lines[0])["kind"], "session_start")

    def test_default_session_dir_shape(self):
        p = default_session_dir(Path("/repo"), "Murist")
        self.assertEqual(p.parent, Path("/repo/sessions"))
        self.assertTrue(p.name.endswith("-Murist"))


if __name__ == "__main__":
    unittest.main()
