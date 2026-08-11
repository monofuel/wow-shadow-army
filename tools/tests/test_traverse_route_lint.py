#!/usr/bin/env python3
"""Unit tests for tools/traverse_route_lint.py (no live navmesh helper)."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import traverse_route_lint as trl  # noqa: E402


class TestGeometry(unittest.TestCase):
    def test_point_to_segment_endpoint(self) -> None:
        d = trl.point_to_segment_distance(0.0, 0.0, 0.0, 0.0, 10.0, 0.0)
        self.assertAlmostEqual(d, 0.0)

    def test_point_to_segment_midline(self) -> None:
        d = trl.point_to_segment_distance(5.0, 3.0, 0.0, 0.0, 10.0, 0.0)
        self.assertAlmostEqual(d, 3.0)

    def test_point_to_segment_beyond_end(self) -> None:
        d = trl.point_to_segment_distance(15.0, 0.0, 0.0, 0.0, 10.0, 0.0)
        self.assertAlmostEqual(d, 5.0)

    def test_point_to_segment_degenerate(self) -> None:
        d = trl.point_to_segment_distance(3.0, 4.0, 0.0, 0.0, 0.0, 0.0)
        self.assertAlmostEqual(d, 5.0)


class TestDirectionalSlopes(unittest.TestCase):
    def test_ascending_steep(self) -> None:
        wps = [trl.Point(0.0, 0.0, 0.0), trl.Point(10.0, 0.0, 20.0)]
        asc, desc = trl.directional_slopes(wps)
        self.assertAlmostEqual(asc, 2.0)
        self.assertAlmostEqual(desc, 0.0)

    def test_descending_steep(self) -> None:
        wps = [trl.Point(0.0, 0.0, 20.0), trl.Point(10.0, 0.0, 0.0)]
        asc, desc = trl.directional_slopes(wps)
        self.assertAlmostEqual(asc, 0.0)
        self.assertAlmostEqual(desc, 2.0)

    def test_short_segment_ignored(self) -> None:
        wps = [trl.Point(0.0, 0.0, 0.0), trl.Point(1.0, 0.0, 5.0)]
        asc, desc = trl.directional_slopes(wps)
        self.assertAlmostEqual(asc, 0.0)
        self.assertAlmostEqual(desc, 0.0)


class TestSpawnFilter(unittest.TestCase):
    def test_tsv_filter_level_and_friendly(self) -> None:
        tsv = "\n".join(
            [
                "100.0\t200.0\t10.0\t40\t41\tTooYoung",
                "110.0\t210.0\t11.0\t45\t46\tHostileA",
                "120.0\t220.0\t12.0\t50\t50\tGrazle",
                "130.0\t230.0\t13.0\t55\t56\tTenell Leafrunner",
                "140.0\t240.0\t14.0\t60\t60\tHostileB",
            ]
        )
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "spawns.tsv"
            path.write_text(tsv)
            spawns = trl.load_spawns(path)
            hostiles = trl.filter_hostile_spawns(spawns)
        names = {s.name for s in hostiles}
        self.assertEqual(names, {"HostileA", "HostileB"})
        self.assertTrue(all(s.level_min >= 45 for s in hostiles))


class TestRuleLogic(unittest.TestCase):
    def setUp(self) -> None:
        self.a = trl.Beat(id="beat_a", x=0.0, y=0.0, z=0.0, radius=25.0)
        self.b = trl.Beat(id="beat_b", x=100.0, y=0.0, z=0.0, radius=25.0)

    def test_complete_ground_ok(self) -> None:
        def probe(src, tgt, flags):
            self.assertEqual(flags, trl.INCLUDE_GROUND)
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=0.2,
                used_water=False,
                message="ok",
                waypoints=[src, tgt],
            )

        sev, details = trl.lint_leg(self.a, self.b, probe, [])
        self.assertEqual(sev, "OK")
        self.assertIn("slope", details)

    def test_water_only_complete_fails(self) -> None:
        def probe(src, tgt, flags):
            if flags == trl.INCLUDE_GROUND:
                return trl.ProbeResult(
                    complete=False,
                    max_segment_slope=0.0,
                    used_water=False,
                    message="no ground",
                    waypoints=[],
                )
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=0.1,
                used_water=True,
                message="swim",
                waypoints=[src, tgt],
            )

        sev, details = trl.lint_leg(self.a, self.b, probe, [])
        self.assertEqual(sev, "FAIL")
        self.assertIn("water-crossing", details)

    def test_ascending_steep_fails(self) -> None:
        def probe(src, tgt, flags):
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=0.0,
                used_water=False,
                message="steep climb",
                waypoints=[
                    trl.Point(0.0, 0.0, 0.0),
                    trl.Point(10.0, 0.0, 20.0),
                ],
            )

        sev, details = trl.lint_leg(self.a, self.b, probe, [])
        self.assertEqual(sev, "FAIL")
        self.assertIn("cannot climb", details)
        self.assertIn("ascending_slope", details)
        self.assertIn("2.000", details)

    def test_descending_steep_warns_only(self) -> None:
        def probe(src, tgt, flags):
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=2.0,
                used_water=False,
                message="steep drop",
                waypoints=[
                    trl.Point(0.0, 0.0, 20.0),
                    trl.Point(10.0, 0.0, 0.0),
                ],
            )

        sev, details = trl.lint_leg(self.a, self.b, probe, [])
        self.assertEqual(sev, "WARN")
        self.assertIn("steep descent", details)
        self.assertIn("2.000", details)

    def test_unsigned_helper_slope_ignored_when_waypoints_flat(self) -> None:
        def probe(src, tgt, flags):
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=2.0,
                used_water=False,
                message="helper says steep",
                waypoints=[src, tgt],
            )

        sev, details = trl.lint_leg(self.a, self.b, probe, [])
        self.assertEqual(sev, "OK")

    def test_spawn_nearby_warns(self) -> None:
        def probe(src, tgt, flags):
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=0.1,
                used_water=False,
                message="ok",
                waypoints=[src, tgt],
            )

        # Midpoint of chord is (50, 0); spawn 8 yd north of it.
        spawn = trl.Spawn(
            x=50.0, y=8.0, z=0.0, level_min=50, level_max=50, name="AngryBear"
        )
        sev, details = trl.lint_leg(self.a, self.b, probe, [spawn])
        self.assertEqual(sev, "WARN")
        self.assertIn("AngryBear", details)
        self.assertIn("8.0", details)

    def test_no_corridor_fails(self) -> None:
        def probe(src, tgt, flags):
            return trl.ProbeResult(
                complete=False,
                max_segment_slope=0.0,
                used_water=flags == trl.INCLUDE_GROUND_WATER,
                message="blocked",
                waypoints=[],
            )

        sev, details = trl.lint_leg(self.a, self.b, probe, [])
        self.assertEqual(sev, "FAIL")
        self.assertIn("no corridor", details)


class TestSourceZSweep(unittest.TestCase):
    def test_z_sweep_includes_source_and_target_offsets(self) -> None:
        src = trl.Point(1.0, 2.0, 100.0)
        tgt = trl.Point(3.0, 4.0, 200.0)
        cands = trl.z_sweep_candidates(src, tgt)
        self.assertEqual(len(cands), len(trl.Z_OFFSETS) ** 2)
        zs_src = {s.z for s, _ in cands}
        zs_tgt = {t.z for _, t in cands}
        for dz in trl.Z_OFFSETS:
            self.assertIn(100.0 + dz, zs_src)
            self.assertIn(200.0 + dz, zs_tgt)
        self.assertEqual(cands[0][0].z, 100.0)
        self.assertEqual(cands[0][1].z, 200.0)

    def test_source_sweep_recovers_from_source_projection_failure(self) -> None:
        src = trl.Point(0.0, 0.0, 50.0)
        tgt = trl.Point(100.0, 0.0, 50.0)
        calls: list[tuple[float, float]] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            calls.append((source.z, target.z))
            if abs(source.z - 50.0) < 1e-9:
                return {
                    "status": "error",
                    "message": "could not project: no physically admissible source triangle",
                    "waypoints": [],
                    "continuation_required": False,
                    "max_segment_slope": 0.0,
                }
            return {
                "status": "ok",
                "message": "ok",
                "waypoints": [
                    {"x": source.x, "y": source.y, "z": source.z},
                    {"x": target.x, "y": target.y, "z": target.z},
                ],
                "continuation_required": False,
                "max_segment_slope": 0.1,
            }

        with mock.patch.object(trl, "call_helper_once", side_effect=fake_call):
            resp = trl.single_hop_with_z_retry(
                Path("/fake/helper"),
                Path("/fake/mmaps"),
                src,
                tgt,
                trl.INCLUDE_GROUND,
            )
        self.assertNotIn("could not project", str(resp.get("message") or "").lower())
        self.assertTrue(any(abs(sz - 50.0) > 1e-9 for sz, _ in calls))
        recovered_src_z = calls[-1][0]
        self.assertNotAlmostEqual(recovered_src_z, 50.0)

    def test_all_projection_failures_returns_last(self) -> None:
        def fake_call(helper, mmaps, source, target, include_flags):
            return {
                "status": "error",
                "message": "could not project target",
                "waypoints": [],
                "continuation_required": False,
                "max_segment_slope": 0.0,
            }

        with mock.patch.object(trl, "call_helper_once", side_effect=fake_call):
            resp = trl.single_hop_with_z_retry(
                Path("/fake/helper"),
                Path("/fake/mmaps"),
                trl.Point(0.0, 0.0, 0.0),
                trl.Point(1.0, 0.0, 0.0),
                trl.INCLUDE_GROUND,
            )
        self.assertIn("could not project", str(resp.get("message") or "").lower())


class TestWarnOnly(unittest.TestCase):
    def test_warn_only_exits_zero_on_fail(self) -> None:
        missing = Path("/tmp/definitely-not-a-navmesh-helper-xyz")
        rc = trl.main(
            [
                "--helper",
                str(missing),
                "--mmaps",
                "/tmp",
                "--beats",
                str(trl.DEFAULT_BEATS),
                "--warn-only",
            ]
        )
        self.assertEqual(rc, 0)


class TestSkip(unittest.TestCase):
    def test_missing_helper_exits_zero(self) -> None:
        missing = Path("/tmp/definitely-not-a-navmesh-helper-xyz")
        rc = trl.main(
            [
                "--helper",
                str(missing),
                "--mmaps",
                "/tmp",
                "--beats",
                str(trl.DEFAULT_BEATS),
            ]
        )
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
