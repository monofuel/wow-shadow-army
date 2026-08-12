#!/usr/bin/env python3
"""Unit tests for resample_trace_beats.py — synthetic fixture traces."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from resample_trace_beats import (  # noqa: E402
    beats_payload,
    decimate,
    emit_lua,
    read_track,
    stitch,
)


def step_row(x, y, z):
    return json.dumps(
        {
            "type": "human_step",
            "observation": {"player": {"position": {"x": x, "y": y, "z": z}}},
        }
    )


class ReadTrackTest(unittest.TestCase):
    def test_reads_positions_and_drops_near_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "walk.jsonl"
            rows = [
                json.dumps({"type": "log_started"}),
                step_row(0.0, 0.0, 5.0),
                step_row(0.2, 0.1, 5.0),  # < 1 yd from previous: dropped
                step_row(10.0, 0.0, 5.0),
                "not json at all",
                json.dumps({"type": "log_stopped"}),
            ]
            log.write_text("\n".join(rows) + "\n")
            track = read_track(log)
        self.assertEqual(len(track), 2)
        self.assertEqual(track[0], (0.0, 0.0, 5.0))
        self.assertEqual(track[1], (10.0, 0.0, 5.0))


class StitchTest(unittest.TestCase):
    def test_second_leg_joins_at_closest_point_to_tail(self):
        leg1 = [(0.0, 0.0, 0.0), (50.0, 0.0, 0.0)]
        # leg2 re-walks 30..50 then continues; stitch must skip the overlap.
        leg2 = [(30.0, 0.0, 0.0), (50.0, 1.0, 0.0), (80.0, 0.0, 0.0)]
        chain = stitch([leg1, leg2])
        self.assertEqual(chain[0], (0.0, 0.0, 0.0))
        self.assertNotIn((30.0, 0.0, 0.0), chain)
        self.assertEqual(chain[-1], (80.0, 0.0, 0.0))


class SeedTest(unittest.TestCase):
    def test_seed_drops_recording_preamble_before_the_seed_pose(self):
        # Leg recorded: hold preamble, teleport artifact, then the walk we
        # want. Seeding at the walk start must drop everything before it.
        leg = [
            (800.0, 0.0, 0.0),  # preamble far away
            (805.0, 0.0, 0.0),
            (0.0, 0.0, 0.0),  # post-teleport walk start (the seed pose)
            (10.0, 0.0, 0.0),
            (20.0, 0.0, 0.0),
        ]
        chain = stitch([leg], seed=(0.0, 0.0, 0.0))
        self.assertEqual(chain[0], (0.0, 0.0, 0.0))
        self.assertNotIn((800.0, 0.0, 0.0), chain)
        self.assertEqual(chain[-1], (20.0, 0.0, 0.0))


class DecimateTest(unittest.TestCase):
    def test_spacing_and_endpoint_retention(self):
        chain = [(float(x), 0.0, 0.0) for x in range(0, 101, 5)]
        points = decimate(chain, 20.0)
        self.assertEqual(points[0], (0.0, 0.0, 0.0))
        self.assertEqual(points[-1], (100.0, 0.0, 0.0))
        for a, b in zip(points, points[1:]):
            self.assertLessEqual(abs(b[0] - a[0]), 25.0)


class EmitTest(unittest.TestCase):
    def test_payload_all_hook_and_lua_parses_shape(self):
        payload = beats_payload(
            [(1.0, 2.0, 3.0), (21.0, 2.0, 3.0)], "cave", 8.0, 1, None
        )
        self.assertEqual(payload["goal_id"], "cave_02")
        self.assertTrue(all(b["hook"] for b in payload["beats"]))
        lua = emit_lua(payload)
        self.assertIn('id = "cave_01"', lua)
        self.assertIn("hook = true", lua)
        self.assertIn('goal_id = "cave_02"', lua)


if __name__ == "__main__":
    unittest.main(verbosity=1)
