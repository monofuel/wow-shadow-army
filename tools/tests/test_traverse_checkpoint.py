#!/usr/bin/env python3
"""Unit tests for tools/traverse_checkpoint.py (shipped SOAP tele path)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import traverse_checkpoint as tc  # noqa: E402

# The real checkpoint table is local-only (copyright hygiene). These tests run
# the shipped resolver/CLI against a small table holding the course poses the
# tests exercise.
PRIMARY_COURSE = {
    "water_entry": (-6784.5, -4833.9, 0.7),
    "duskwallow_coast": (-4627.01, -4869.45, -2.37),
    "merchant_coast": (-1816.8, -3899.5, -1.0),
    "top_barrens": (1071.6, -2303.4, 91.7),
    "felwood_cave_entrance": (6502.937, -2063.74, 576.017),
    "everlook": (6687.333052, -4647.667, 721.678),
}
# Local-only inputs live under $WSA_PRIVATE_INPUTS (default the repo root).
PRIVATE_ROOT = Path(os.environ.get("WSA_PRIVATE_INPUTS") or ROOT)
LOCAL_TABLE = PRIVATE_ROOT / "tools" / "traverse_checkpoints.json"
SHIPPED_CLI = ROOT / "tools" / "traverse_checkpoint.py"
_table_dir: tempfile.TemporaryDirectory | None = None
_table_patch = None
_table_path: Path | None = None


def run_shipped_cli(table: Path, *args: str) -> str:
    """Run the shipped CLI as a separate process against `table`.

    The CLI reads ROOT/tools/traverse_checkpoints.json, with ROOT taken from
    its own file path, and has no table flag. For the canonical table it runs
    in place; otherwise a byte-identical copy of the shipped script runs from
    a temp tree with `table` beside it.
    """
    env = dict(os.environ)
    env.pop("TRAVERSE_CHARACTER", None)
    canonical = ROOT / "tools" / "traverse_checkpoints.json"
    if table.resolve() == canonical.resolve():
        cmd = [sys.executable, str(SHIPPED_CLI), *args]
        return subprocess.check_output(cmd, text=True, env=env).strip()
    with tempfile.TemporaryDirectory() as td:
        tools = Path(td) / "tools"
        tools.mkdir()
        script = tools / SHIPPED_CLI.name
        shutil.copyfile(SHIPPED_CLI, script)
        shutil.copyfile(table, tools / canonical.name)
        cmd = [sys.executable, str(script), *args]
        return subprocess.check_output(cmd, text=True, env=env).strip()


def setUpModule() -> None:
    global _table_dir, _table_patch, _table_path
    table = {"spawn": {"map_id": 1, "x": -9187.0, "y": -2530.25, "z": 14.0}}
    for name, (x, y, z) in PRIMARY_COURSE.items():
        table[name] = {
            "map_id": 1, "x": x, "y": y, "z": z, "o": 0.0,
            "tele_name": f"petrel_{name}",
        }
    _table_dir = tempfile.TemporaryDirectory()
    path = Path(_table_dir.name) / "traverse_checkpoints.json"
    path.write_text(json.dumps(table), encoding="utf-8")
    _table_path = path
    _table_patch = mock.patch.object(tc, "DEFAULT_TABLE", path)
    _table_patch.start()


def tearDownModule() -> None:
    if _table_patch is not None:
        _table_patch.stop()
    if _table_dir is not None:
        _table_dir.cleanup()


class TestTraverseCheckpoint(unittest.TestCase):
    def test_resolve_water_entry_from_table(self) -> None:
        pose = tc.resolve_checkpoint("water_entry")
        self.assertEqual(pose["x"], -6784.5)
        self.assertEqual(pose["y"], -4833.9)
        self.assertEqual(pose["z"], 0.7)
        self.assertEqual(pose["map_id"], 1)
        self.assertEqual(pose["tele_name"], "petrel_water_entry")
        self.assertEqual(pose["name"], "water_entry")

    def test_primary_course_checkpoints(self) -> None:
        for name, coordinates in PRIMARY_COURSE.items():
            with self.subTest(checkpoint=name):
                pose = tc.resolve_checkpoint(name)
                self.assertEqual(
                    (pose["x"], pose["y"], pose["z"]), coordinates
                )
                self.assertEqual(pose["map_id"], 1)
                self.assertTrue(pose["tele_name"])

    def test_spawn_has_no_tele(self) -> None:
        pose = tc.resolve_checkpoint("spawn")
        self.assertIsNone(pose.get("tele_name"))

    def test_unknown_checkpoint_raises(self) -> None:
        with self.assertRaises(KeyError):
            tc.resolve_checkpoint("not_a_real_checkpoint")

    def test_tele_command_format(self) -> None:
        cmd = tc.tele_command("Northbound", "petrel_water_entry")
        self.assertEqual(cmd, "tele name Northbound petrel_water_entry")

    def test_tele_command_rejects_spaces(self) -> None:
        with self.assertRaises(ValueError):
            tc.tele_command("North bound", "petrel_water_entry")

    def test_cli_tele_cmd_uses_shipped_resolver(self) -> None:
        assert _table_path is not None
        out = run_shipped_cli(_table_path, "tele-cmd", "water_entry")
        self.assertEqual(out, "tele name Northbound petrel_water_entry")

    def test_soap_execute_posts_real_command(self) -> None:
        """Drive soap_execute; mock only the network layer, not command build."""
        captured: dict = {}

        class FakeResp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return (
                    b'<?xml version="1.0"?>'
                    b"<SOAP-ENV:Envelope>"
                    b"<SOAP-ENV:Body>"
                    b"<ns1:executeCommandResponse>"
                    b"<result>You are teleporting Northbound (offline) to petrel_water_entry.</result>"
                    b"</ns1:executeCommandResponse>"
                    b"</SOAP-ENV:Body></SOAP-ENV:Envelope>"
                )

        def fake_urlopen(req, timeout=8.0):
            captured["url"] = req.full_url
            captured["data"] = req.data.decode()
            captured["auth"] = req.headers.get("Authorization") or req.get_header(
                "Authorization"
            )
            return FakeResp()

        pose = tc.resolve_checkpoint("water_entry")
        cmd = tc.tele_command("Northbound", str(pose["tele_name"]))
        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = tc.soap_execute(cmd, url="http://127.0.0.1:7878/")
        self.assertIn("petrel_water_entry", result)
        self.assertIn("tele name Northbound petrel_water_entry", captured["data"])
        self.assertIn("127.0.0.1:7878", captured["url"])

    def test_apply_spawn_skips_tele(self) -> None:
        out = tc.apply_checkpoint("spawn", skip_wait=True)
        self.assertTrue(out["ok"])
        self.assertTrue(out.get("skipped"))

    def test_apply_no_wait_is_one_shot(self) -> None:
        """--no-wait fires exactly one accepted tele and never reads status.

        The status file belongs to the bot seat; the old shared verify loop
        read it after a manual tele and re-fired every cycle, repeatedly
        yanking a logged-in human back to the checkpoint (2026-08-10).
        """
        calls = {"soap": 0}

        def fake_soap(cmd, **_kw):
            calls["soap"] += 1
            return "You are teleporting Cowcam to petrel_merchant_coast."

        with (
            mock.patch.object(tc, "wait_for_soap", return_value="up"),
            mock.patch.object(tc, "ensure_gm_account"),
            mock.patch.object(
                tc, "ensure_game_tele", return_value="petrel_merchant_coast"
            ),
            mock.patch.object(tc, "soap_execute", side_effect=fake_soap),
            mock.patch.object(
                tc,
                "read_status",
                side_effect=AssertionError(
                    "--no-wait must never read the bot status file"
                ),
            ),
            mock.patch.object(tc.time, "sleep"),
        ):
            out = tc.apply_checkpoint(
                "merchant_coast", character="Cowcam", skip_wait=True
            )
        self.assertTrue(out["ok"])
        self.assertTrue(out.get("one_shot"))
        self.assertEqual(out["attempts"], 1)
        self.assertEqual(calls["soap"], 1)

    def test_apply_no_wait_retries_unloaded_tele_location(self) -> None:
        """A 'location not found' reply re-ensures game_tele, then re-fires."""
        replies = iter(
            [
                "Teleport location not found!",
                "You are teleporting Cowcam to petrel_merchant_coast.",
            ]
        )
        ensured = {"count": 0}

        def fake_ensure(_pose):
            ensured["count"] += 1
            return "petrel_merchant_coast"

        with (
            mock.patch.object(tc, "wait_for_soap", return_value="up"),
            mock.patch.object(tc, "ensure_gm_account"),
            mock.patch.object(tc, "ensure_game_tele", side_effect=fake_ensure),
            mock.patch.object(
                tc, "soap_execute", side_effect=lambda *_a, **_k: next(replies)
            ),
            mock.patch.object(tc, "read_status"),
            mock.patch.object(tc.time, "sleep"),
        ):
            out = tc.apply_checkpoint(
                "merchant_coast", character="Cowcam", skip_wait=True
            )
        self.assertTrue(out["ok"])
        self.assertEqual(out["attempts"], 2)
        self.assertGreaterEqual(ensured["count"], 2)

    def test_segment_wait_starts_at_checkpoint_and_reaches_endpoint(self) -> None:
        statuses = [
            {"x": 1071.6, "y": -2303.4, "swimming": False},
            {"x": 6502.937, "y": -2063.74, "swimming": False, "nav_error": ""},
        ]
        clock = iter(range(20))
        with (
            mock.patch.object(tc, "read_status", side_effect=statuses),
            mock.patch.object(tc.time, "sleep"),
            mock.patch.object(tc.time, "monotonic", side_effect=lambda: float(next(clock))),
        ):
            out = tc.wait_for_segment_endpoint(
                "top_barrens", "felwood_cave_entrance", timeout=15
            )
        self.assertTrue(out["ok"])
        self.assertEqual(out["swimming_samples"], 0)
        self.assertEqual(out["deaths"], 0)
        self.assertLessEqual(out["endpoint_distance_yards"], 50)
        self.assertIn("best_endpoint_distance_yards", out)
        self.assertLessEqual(
            out["best_endpoint_distance_yards"], out["endpoint_distance_yards"]
        )

    def test_segment_wait_reports_death(self) -> None:
        statuses = [
            {"x": 1071.6, "y": -2303.4, "swimming": False},
            {
                "x": 1100.0,
                "y": -2290.0,
                "swimming": False,
                "intent_reason": "run_over",
                "nav_error": "",
            },
        ]
        clock = iter(range(20))
        with (
            mock.patch.object(tc, "read_status", side_effect=statuses),
            mock.patch.object(tc.time, "sleep"),
            mock.patch.object(tc.time, "monotonic", side_effect=lambda: float(next(clock))),
        ):
            out = tc.wait_for_segment_endpoint(
                "top_barrens", "felwood_cave_entrance", timeout=15
            )
        self.assertFalse(out["ok"])
        self.assertEqual(out["deaths"], 1)
        self.assertIn("best_endpoint_distance_yards", out)
        self.assertGreater(out["best_endpoint_distance_yards"], 0)

    def test_segment_wait_tracks_best_endpoint_distance(self) -> None:
        """Closest approach is kept even when the final sample backs off."""
        end = tc.resolve_checkpoint("felwood_cave_entrance")
        near = {"x": end["x"] + 30.0, "y": end["y"], "swimming": False}
        far = {"x": end["x"] + 200.0, "y": end["y"], "swimming": False, "nav_error": ""}
        seq = iter(
            [
                {"x": 1071.6, "y": -2303.4, "swimming": False},
                near,
            ]
        )

        def statuses() -> dict:
            try:
                return next(seq)
            except StopIteration:
                return far

        t = [0.0]

        def mono() -> float:
            cur = t[0]
            t[0] += 0.1
            return cur

        with (
            mock.patch.object(tc, "read_status", side_effect=lambda *_a, **_k: statuses()),
            mock.patch.object(tc.time, "sleep"),
            mock.patch.object(tc.time, "monotonic", side_effect=mono),
        ):
            out = tc.wait_for_segment_endpoint(
                "top_barrens", "felwood_cave_entrance", timeout=2.0, near_yards=20.0
            )
        self.assertFalse(out["ok"])
        self.assertEqual(out["reason"], "segment endpoint timeout")
        self.assertAlmostEqual(out["best_endpoint_distance_yards"], 30.0, places=1)
        self.assertGreater(out["endpoint_distance_yards"], out["best_endpoint_distance_yards"])

    def test_cmd_wait_embeds_scorecard_when_run_log_exists(self) -> None:
        import argparse
        import io
        import tempfile

        statuses = [
            {"x": 1071.6, "y": -2303.4, "swimming": False},
            {"x": 6502.937, "y": -2063.74, "swimming": False, "nav_error": ""},
        ]
        clock = iter(range(20))
        flight = (
            'lua-bot[traverse]: FLIGHT {"t":0.0,"x":0.0,"y":0.0,"z":0,'
            '"hp":1000,"form":0,"swim":false,"combat":false,'
            '"nav":"following","beat":"desert","xt":1.0}\n'
            'lua-bot[traverse]: FLIGHT {"t":5.0,"x":40.0,"y":0.0,"z":0,'
            '"hp":1000,"form":0,"swim":false,"combat":false,'
            '"nav":"following","beat":"desert","xt":2.0}\n'
        )
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            run_dir = tmp / "local_data" / "traverse-status"
            run_dir.mkdir(parents=True)
            (run_dir / "run.log").write_text(flight, encoding="utf-8")
            result_path = tmp / "segment.json"
            args = argparse.Namespace(
                start="top_barrens",
                end="felwood_cave_entrance",
                status=None,
                timeout=15.0,
                near=50.0,
                start_near=120.0,
                poll=0.5,
                result=str(result_path),
            )
            buf = io.StringIO()
            with (
                mock.patch.object(tc, "ROOT", tmp),
                mock.patch.object(tc, "read_status", side_effect=statuses),
                mock.patch.object(tc.time, "sleep"),
                mock.patch.object(
                    tc.time, "monotonic", side_effect=lambda: float(next(clock))
                ),
                mock.patch("sys.stdout", buf),
            ):
                rc = tc.cmd_wait(args)
            self.assertEqual(rc, 0)
            data = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertIn("scorecard", data)
            self.assertIn("duration_s", data["scorecard"])
            self.assertAlmostEqual(data["scorecard"]["duration_s"], 5.0, places=2)
            self.assertIn("traverse scorecard", buf.getvalue())



@unittest.skipUnless(
    LOCAL_TABLE.is_file(), f"local checkpoint table not present: {LOCAL_TABLE}"
)
class TestLocalCheckpointTable(unittest.TestCase):
    """The same course contract against the local recorded checkpoint table."""

    def setUp(self) -> None:
        self.table = tc.load_table(LOCAL_TABLE)

    def test_primary_course_checkpoints(self) -> None:
        for name, coordinates in PRIMARY_COURSE.items():
            with self.subTest(checkpoint=name):
                pose = tc.resolve_checkpoint(name, self.table)
                self.assertEqual(
                    (pose["x"], pose["y"], pose["z"]), coordinates
                )
                self.assertEqual(pose["map_id"], 1)
                self.assertTrue(pose["tele_name"])

    def test_water_entry_tele_name(self) -> None:
        pose = tc.resolve_checkpoint("water_entry", self.table)
        self.assertEqual(pose["tele_name"], "petrel_water_entry")

    def test_spawn_has_no_tele(self) -> None:
        pose = tc.resolve_checkpoint("spawn", self.table)
        self.assertIsNone(pose.get("tele_name"))

    def test_cli_tele_cmd_uses_shipped_resolver(self) -> None:
        out = run_shipped_cli(LOCAL_TABLE, "tele-cmd", "water_entry")
        self.assertEqual(out, "tele name Northbound petrel_water_entry")


if __name__ == "__main__":
    unittest.main()
