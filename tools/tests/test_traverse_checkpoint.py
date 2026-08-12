#!/usr/bin/env python3
"""Unit tests for tools/traverse_checkpoint.py (shipped SOAP tele path)."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import traverse_checkpoint as tc  # noqa: E402


class TestTraverseCheckpoint(unittest.TestCase):
    def test_resolve_water_entry_from_table(self) -> None:
        pose = tc.resolve_checkpoint("water_entry")
        self.assertEqual(pose["x"], -6784.5)
        self.assertEqual(pose["y"], -4833.9)
        self.assertEqual(pose["z"], 0.7)
        self.assertEqual(pose["map_id"], 1)
        self.assertEqual(pose["tele_name"], "petrel_water_entry")

    def test_primary_course_checkpoints(self) -> None:
        expected = {
            "water_entry": (-6784.5, -4833.9, 0.7),
            "duskwallow_coast": (-4627.01, -4869.45, -2.37),
            "merchant_coast": (-1816.8, -3899.5, -1.0),
            "top_barrens": (1071.6, -2303.4, 91.7),
            "felwood_cave_entrance": (6502.937, -2063.74, 576.017),
            "everlook": (6687.333052, -4647.667, 721.678),
        }
        for name, coordinates in expected.items():
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
        import subprocess

        out = subprocess.check_output(
            [
                sys.executable,
                str(ROOT / "tools" / "traverse_checkpoint.py"),
                "tele-cmd",
                "water_entry",
            ],
            text=True,
        ).strip()
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


if __name__ == "__main__":
    unittest.main()
