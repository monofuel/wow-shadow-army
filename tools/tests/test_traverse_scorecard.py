#!/usr/bin/env python3
"""Unit tests for tools/traverse_scorecard.py."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import traverse_scorecard as sc  # noqa: E402


def _flight(
    t: float,
    x: float,
    y: float,
    *,
    hp: int = 1000,
    swim: bool = False,
    nav: str = "following",
    beat: str = "desert",
    xt: float = 0.0,
) -> str:
    return (
        f'lua-bot[traverse]: FLIGHT {{"t":{t},"x":{x},"y":{y},"z":0,'
        f'"hp":{hp},"form":0,"swim":{"true" if swim else "false"},'
        f'"combat":false,"nav":"{nav}","beat":"{beat}","xt":{xt}}}'
    )


class TestTraverseScorecard(unittest.TestCase):
    def test_full_scorecard_and_warnings(self) -> None:
        # Movement 0->50 yd over 5s, then stopped 10s with SNAG, then more move.
        # xt values include p95 > 25. HP drop 900 in one bin. EV swim + clip.
        lines = [
            "noise from launcher",
            _flight(0.0, 0.0, 0.0, hp=1000, xt=0.0),
            _flight(5.0, 50.0, 0.0, hp=1000, xt=5.0),
            "lua-bot[traverse]: SNAG: pinned at (50.0, 0.0) — hopping left to (50.0, 18.0) (cluster 1 reach 1)",
            _flight(15.0, 50.2, 0.1, hp=1000, nav="planning", xt=10.0),
            "lua-bot[traverse]: EV unplanned_swim x=50.0 y=0.0",
            _flight(20.0, 100.0, 0.0, hp=1000, xt=30.0),
            "lua-bot[traverse]: EV clip dz=12.0 x=100.0 y=0.0 z=5.0",
            # hp 1000 -> 100 = loss 900 at x~150 -> bin 100
            _flight(25.0, 150.0, 0.0, hp=100, xt=40.0),
            _flight(30.0, 200.0, 0.0, hp=100, xt=50.0),
            "other garbage line without markers",
        ]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "run.log"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            out = sc.parse_run_log(path)

        self.assertGreater(out["duration_s"], 0)
        self.assertAlmostEqual(out["duration_s"], 30.0, places=2)
        self.assertGreater(out["distance_yd"], 100.0)
        self.assertGreater(out["avg_speed"], 0.0)

        self.assertGreater(out["stopped_s_total"], 0.0)
        self.assertIn("snag_hop", out["stopped_s_by_reason"])
        self.assertGreater(out["stopped_s_by_reason"]["snag_hop"], 0.0)

        self.assertIsNotNone(out["cross_track"]["p95"])
        self.assertGreater(out["cross_track"]["p95"], 25.0)
        self.assertGreaterEqual(out["cross_track"]["max"], 50.0)

        counts = out["events"]["counts"]
        self.assertEqual(counts.get("unplanned_swim"), 1)
        self.assertEqual(counts.get("clip"), 1)
        self.assertEqual(len(out["events"]["list"]), 2)

        worst = out["hp_map"]["worst5"]
        self.assertTrue(worst)
        self.assertGreater(worst[0][1], 800)

        self.assertEqual(out["snags"]["total"], 1)
        self.assertTrue(out["snags"]["clusters"])

        warns = " ".join(out["warnings"])
        self.assertIn("WARN idle:", warns)
        self.assertIn("WARN cross_track:", warns)
        self.assertIn("WARN unplanned_swim:", warns)
        self.assertIn("WARN clip:", warns)
        self.assertIn("WARN hp:", warns)
        self.assertEqual(len(out["warnings"]), 5)

    def test_garbage_lines_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "run.log"
            path.write_text(
                "hello\nnot a log\nFLIGHT not-json\n"
                "EV missing coords\nSNAG: broken\n{\n",
                encoding="utf-8",
            )
            out = sc.parse_run_log(path)
        self.assertEqual(out["duration_s"], 0.0)
        self.assertEqual(out["distance_yd"], 0.0)
        self.assertEqual(out["events"]["counts"], {})
        self.assertEqual(out["warnings"], [])

    def test_cli_json(self) -> None:
        import io
        from unittest import mock

        lines = [_flight(0.0, 0.0, 0.0), _flight(5.0, 10.0, 0.0, xt=1.0)]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "run.log"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            jpath = Path(td) / "out.json"
            with mock.patch("sys.stdout", io.StringIO()):
                rc = sc.main([str(path), "--json", str(jpath)])
            self.assertEqual(rc, 0)
            self.assertTrue(jpath.is_file())


if __name__ == "__main__":
    unittest.main()
