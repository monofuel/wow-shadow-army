#!/usr/bin/env python3
"""Unit tests for tools/traverse_route_lint.py (no live navmesh helper)."""
from __future__ import annotations

import json
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
        zs_src = {s.z for s, _ in cands}
        zs_tgt = {t.z for _, t in cands}
        for dz in trl.Z_OFFSETS:
            self.assertIn(100.0 + dz, zs_src)
            self.assertIn(200.0 + dz, zs_tgt)
        self.assertEqual(cands[0][0].z, 100.0)
        self.assertEqual(cands[0][1].z, 200.0)

    def test_source_offsets_step_below_helper_vertical_limit(self) -> None:
        """Step must be < 4 yd or the +-2 yd admissible band can be skipped."""
        self.assertLess(trl.SOURCE_Z_STEP, 4.0)
        offs = trl.source_z_offsets()
        self.assertEqual(offs[0], 0.0)
        self.assertAlmostEqual(max(offs), trl.SOURCE_Z_MAX)
        self.assertAlmostEqual(min(offs), -trl.SOURCE_Z_MAX)
        # Ordered by |dz| so the common (already on-mesh) case costs one call.
        self.assertEqual([abs(v) for v in offs], sorted(abs(v) for v in offs))
        # Every z in range is within half a step of some probe.
        ordered = sorted(offs)
        gaps = [b - a for a, b in zip(ordered, ordered[1:])]
        self.assertLessEqual(max(gaps), 2.0 * 2.0)

    def test_source_sweep_finds_narrow_band_at_minus_nine(self) -> None:
        """Ashenvale climb_dodge shape: only z in [-9,-5] off the beat works."""
        src = trl.Point(2560.0, -1830.0, 163.0)
        tgt = trl.Point(2687.0, -1792.0, 197.0)
        calls: list[tuple[float, float]] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            calls.append((source.z, target.z))
            if not (154.0 <= source.z <= 158.0):
                return {
                    "status": "no_path",
                    "message": (
                        "no physically admissible source triangle was found "
                        "near the client pose"
                    ),
                    "waypoints": [],
                    "continuation_required": False,
                    "max_segment_slope": 0.0,
                }
            return {
                "status": "ok",
                "message": "route planned with VMaNGOS Detour mmaps",
                "waypoints": [
                    {"x": source.x, "y": source.y, "z": source.z},
                    {"x": target.x, "y": target.y, "z": target.z},
                ],
                "continuation_required": False,
                "max_segment_slope": 0.3,
            }

        with mock.patch.object(trl, "call_helper_once", side_effect=fake_call):
            resp = trl.single_hop_with_z_retry(
                Path("/fake/helper"),
                Path("/fake/mmaps"),
                src,
                tgt,
                trl.INCLUDE_GROUND,
            )
        self.assertEqual(resp.get("status"), "ok")
        self.assertTrue(154.0 <= calls[-1][0] <= 158.0)
        self.assertEqual(resp["z_sweep"]["target_dz"], 0.0)

    def test_source_sweep_requires_ninety_yard_reach(self) -> None:
        """A band only reachable at -90 yd must still be found."""
        src = trl.Point(0.0, 0.0, 300.0)
        tgt = trl.Point(100.0, 0.0, 300.0)
        band = (300.0 - 91.0, 300.0 - 89.0)

        def fake_call(helper, mmaps, source, target, include_flags):
            if not (band[0] <= source.z <= band[1]):
                return {
                    "status": "no_path",
                    "message": "no physically admissible source triangle",
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
        self.assertEqual(resp.get("status"), "ok")
        self.assertAlmostEqual(resp["z_sweep"]["source_dz"], -90.0)

    def test_target_sweep_runs_after_source_sweep(self) -> None:
        """Target height is varied only once source candidates are exhausted."""
        src = trl.Point(0.0, 0.0, 10.0)
        tgt = trl.Point(50.0, 0.0, 10.0)
        calls: list[tuple[float, float]] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            calls.append((source.z, target.z))
            if abs(target.z - 40.0) > 1e-9:
                return {
                    "status": "no_path",
                    "message": "could not project source or target",
                    "source_poly_ref": "123",
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
        self.assertEqual(resp.get("status"), "ok")
        self.assertAlmostEqual(calls[-1][1], 40.0)
        self.assertAlmostEqual(resp["z_sweep"]["target_dz"], 30.0)
        # Source height stayed at the one that already projected fine.
        self.assertAlmostEqual(calls[-1][0], 10.0)

    def test_source_projection_failure_classification(self) -> None:
        self.assertTrue(
            trl._is_source_projection_failure(
                {"message": "no physically admissible source triangle"}
            )
        )
        self.assertTrue(
            trl._is_source_projection_failure(
                {"message": "could not project source or target onto loaded tiles"}
            )
        )
        self.assertFalse(
            trl._is_source_projection_failure(
                {
                    "message": "could not project source or target onto loaded tiles",
                    "source_poly_ref": "42",
                }
            )
        )
        self.assertFalse(trl._is_source_projection_failure({"message": "no path"}))

    def test_continuation_hop_reuses_target_offset(self) -> None:
        """Hop 2 must start from the target dz hop 1 proved, not from zero."""
        src = trl.Point(0.0, 0.0, 100.0)
        tgt = trl.Point(200.0, 0.0, 100.0)
        calls: list[tuple[float, float, float]] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            calls.append((source.x, source.z, target.z))
            if abs(target.z - 130.0) > 1e-9:
                return {
                    "status": "no_path",
                    "message": "could not project source or target",
                    "source_poly_ref": "9",
                    "waypoints": [],
                    "continuation_required": False,
                    "max_segment_slope": 0.0,
                }
            if source.x < 100.0:
                return {
                    "status": "ok",
                    "message": "partial",
                    "waypoints": [{"x": 100.0, "y": 0.0, "z": 100.0}],
                    "continuation_required": True,
                    "partial_path_end": {"x": 100.0, "y": 0.0, "z": 100.0},
                    "max_segment_slope": 0.1,
                }
            return {
                "status": "ok",
                "message": "ok",
                "waypoints": [{"x": 200.0, "y": 0.0, "z": 100.0}],
                "continuation_required": False,
                "max_segment_slope": 0.1,
            }

        with mock.patch.object(trl, "call_helper_once", side_effect=fake_call):
            result = trl.chain_route(
                Path("/fake/helper"),
                Path("/fake/mmaps"),
                src,
                tgt,
                trl.INCLUDE_GROUND,
            )
        self.assertTrue(result.complete)
        hop2 = [c for c in calls if c[0] == 100.0]
        self.assertTrue(hop2)
        # Hop 2 hits the working target height on its very first attempt.
        self.assertAlmostEqual(hop2[0][2], 130.0)
        self.assertEqual(len(hop2), 1)

    def test_verbose_observer_traces_every_attempt(self) -> None:
        src = trl.Point(0.0, 0.0, 10.0)
        tgt = trl.Point(50.0, 0.0, 10.0)
        seen: list[str] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            if abs(source.z - 13.0) > 1e-9:
                return {
                    "status": "no_path",
                    "message": "no physically admissible source triangle",
                    "waypoints": [],
                    "continuation_required": False,
                    "max_segment_slope": 0.0,
                }
            return {
                "status": "ok",
                "message": "ok",
                "waypoints": [{"x": 50.0, "y": 0.0, "z": 13.0}],
                "continuation_required": False,
                "max_segment_slope": 0.1,
            }

        def observer(source, target, flags, resp):
            seen.append(trl.format_attempt(source, target, flags, resp))

        with mock.patch.object(trl, "call_helper_once", side_effect=fake_call):
            trl.single_hop_with_z_retry(
                Path("/fake/helper"),
                Path("/fake/mmaps"),
                src,
                tgt,
                trl.INCLUDE_GROUND,
                observer=observer,
            )
        self.assertEqual(len(seen), 3)
        self.assertIn("dz=+0.0", seen[0])
        self.assertIn("dz=-3.0", seen[1])
        self.assertIn("dz=+3.0", seen[2])
        self.assertIn("status=ok", seen[-1])

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

    def test_source_sweep_recovers_from_bare_admissible_message(self) -> None:
        """Helper wording without 'could not project' still must z-sweep."""
        src = trl.Point(0.0, 0.0, 50.0)
        tgt = trl.Point(100.0, 0.0, 50.0)
        calls: list[tuple[float, float]] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            calls.append((source.z, target.z))
            if abs(source.z - 50.0) < 1e-9:
                return {
                    "status": "error",
                    "message": (
                        "no physically admissible source triangle was found "
                        "near the client pose"
                    ),
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
        self.assertEqual(resp.get("status"), "ok")
        self.assertTrue(any(abs(sz - 50.0) > 1e-9 for sz, _ in calls))
        self.assertNotAlmostEqual(calls[-1][0], 50.0)

    def test_source_sweep_retries_any_empty_waypoint_failure(self) -> None:
        """Any no-path/failed probe (empty waypoints) retries with source z."""
        src = trl.Point(0.0, 0.0, 100.0)
        tgt = trl.Point(50.0, 0.0, 100.0)
        calls: list[tuple[float, float]] = []

        def fake_call(helper, mmaps, source, target, include_flags):
            calls.append((source.z, target.z))
            # Fail until source z is offset by +30 (first non-zero Z_OFFSETS).
            if abs(source.z - 130.0) > 1e-9:
                return {
                    "status": "ok",
                    "message": "no path",
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
                "max_segment_slope": 0.05,
            }

        with mock.patch.object(trl, "call_helper_once", side_effect=fake_call):
            resp = trl.single_hop_with_z_retry(
                Path("/fake/helper"),
                Path("/fake/mmaps"),
                src,
                tgt,
                trl.INCLUDE_GROUND,
            )
        self.assertEqual(resp.get("status"), "ok")
        self.assertTrue(resp.get("waypoints"))
        self.assertAlmostEqual(calls[-1][0], 130.0)
        self.assertGreater(len(calls), 1)

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


class TestProbeLegCli(unittest.TestCase):
    def _run(self, extra: list[str]) -> tuple[int, str]:
        import io
        import contextlib

        buf = io.StringIO()
        with mock.patch.object(trl, "resources_ready", return_value=True), mock.patch.object(
            trl, "make_helper_probe", return_value=self.probe
        ), contextlib.redirect_stdout(buf):
            rc = trl.main(
                [
                    "--helper", "/tmp/x", "--mmaps", "/tmp",
                    "--beats", str(self.beats), "--spawns", str(self.spawns),
                    *extra,
                ]
            )
        return rc, buf.getvalue()

    def setUp(self) -> None:
        # The real land-beat route is local-only data; a three-beat synthetic
        # route keeps the CLI leg selection deterministic.
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.beats = Path(td.name) / "beats.json"
        self.beats.write_text(
            json.dumps(
                {
                    "beats": [
                        {"id": "ashenvale_pass_1", "x": 2000.0, "y": -1500.0, "z": 100.0},
                        {"id": "ashenvale_pass_2", "x": 2100.0, "y": -1450.0, "z": 105.0},
                        {"id": "ashenvale_pass_3", "x": 2200.0, "y": -1400.0, "z": 110.0},
                    ]
                }
            ),
            encoding="utf-8",
        )
        self.spawns = Path(td.name) / "no_spawns.tsv"

        def probe(source, target, flags):
            return trl.ProbeResult(
                complete=True,
                max_segment_slope=0.2,
                used_water=False,
                message="ok",
                waypoints=[source, target],
            )

        self.probe = probe

    def test_probe_leg_lints_only_named_pair(self) -> None:
        rc, out = self._run(
            ["--probe-leg", "ashenvale_pass_1", "ashenvale_pass_2"]
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip().splitlines()[0].split()[0], "OK")
        self.assertIn("ashenvale_pass_1->ashenvale_pass_2", out)
        self.assertEqual(len(out.strip().splitlines()), 1)

    def test_probe_leg_unknown_id_fails(self) -> None:
        rc, _ = self._run(["--probe-leg", "nope_a", "ashenvale_pass_2"])
        self.assertEqual(rc, 1)


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
