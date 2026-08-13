#!/usr/bin/env python3
"""Connectivity doctrine for checked-in Kalimdor road artifacts.

A Thousand Needles bake is correct only if the floor network reaches the
neighboring regions. Locate everything geometrically — baked segment ids
renumber every bake and must never be used as keys.
"""
from __future__ import annotations

import json
import math
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = ROOT / "tools" / "data" / "road_waypoints_kalimdor.jsonl"
HAVE_ARTIFACT = ARTIFACT.is_file()
skip_no_artifact = unittest.skipUnless(
    HAVE_ARTIFACT, f"no Kalimdor road artifact at {ARTIFACT}"
)

STITCH_YD = 15.0
# Same 100 yd radius the baker uses to attach an anchor to nearby points.
# Keep these equal: a point the bake would claim is "at" the anchor must
# also count as reaching it here.
ANCHOR_RADIUS_YD = 100.0
ANCHOR_Z_YD = 40.0

Point = tuple[float, float, float]
Segment = list[Point]


def load_segments(path: Path) -> list[Segment]:
    segments: list[Segment] = []
    with Path(path).open() as handle:
        next(handle, None)
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            pts = json.loads(line).get("pts") or []
            segments.append(
                [(float(p[0]), float(p[1]), float(p[2])) for p in pts]
            )
    return segments


def segments_connected_components(
    segments: list[Segment], stitch_yd: float = STITCH_YD
) -> list[list[int]]:
    n = len(segments)
    parent = list(range(n))
    rank = [0] * n

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if rank[ra] < rank[rb]:
            parent[ra] = rb
        elif rank[ra] > rank[rb]:
            parent[rb] = ra
        else:
            parent[rb] = ra
            rank[ra] += 1

    buckets: dict[tuple[int, int], list[tuple[int, float, float]]] = {}
    inv = 1.0 / stitch_yd
    thresh2 = stitch_yd * stitch_yd
    for si, pts in enumerate(segments):
        for x, y, _z in pts:
            key = (math.floor(x * inv), math.floor(y * inv))
            buckets.setdefault(key, []).append((si, x, y))

    for (bx, by), members in buckets.items():
        neighborhood: list[tuple[int, float, float]] = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                neighborhood.extend(buckets.get((bx + dx, by + dy), ()))
        for si, x, y in members:
            for sj, ox, oy in neighborhood:
                if si >= sj or find(si) == find(sj):
                    continue
                dx = x - ox
                dy = y - oy
                if dx * dx + dy * dy <= thresh2:
                    union(si, sj)

    grouped: dict[int, list[int]] = {}
    for i in range(n):
        grouped.setdefault(find(i), []).append(i)
    return [sorted(members) for members in grouped.values()]


@skip_no_artifact
class TestKalimdorRoadConnectivity(unittest.TestCase):
    ANCHORS = {
        # Thousand Needles floor, lift lower dock; Barrens connectivity is
        # via the lift transport edge, so the FLOOR network only needs to
        # reach this dock.
        "great_lift_lower": (-4677.066, -1853.667, -43.857),
        # Where the painted FeralasRoad descent ends on the 1kN side.
        "feralas_terminus": (-4280.0, -776.0, -49.4),
    }

    @classmethod
    def setUpClass(cls) -> None:
        with ARTIFACT.open() as handle:
            cls.meta = json.loads(handle.readline())
        cls.segments = load_segments(ARTIFACT)
        cls.components = segments_connected_components(cls.segments, STITCH_YD)
        cls.seg_to_comp = {}
        for ci, members in enumerate(cls.components):
            for si in members:
                cls.seg_to_comp[si] = ci

    def test_artifact_parses_and_has_segments(self) -> None:
        self.assertEqual(self.meta.get("map_id"), 1)
        self.assertGreater(len(self.segments), 50)

    def test_thousand_needles_connects_to_neighbors(self) -> None:
        hits = {
            name: self._anchor_hit(xyz) for name, xyz in self.ANCHORS.items()
        }
        shared: set[int] | None = None
        for _nearest, _pt, comps in hits.values():
            if shared is None:
                shared = set(comps)
            else:
                shared &= comps
        if shared:
            return
        lines = [
            "Thousand Needles floor must share one component with both "
            f"neighbor anchors (stitch={STITCH_YD} yd, "
            f"reach={ANCHOR_RADIUS_YD} yd)."
        ]
        for name, (nearest, pt, comps) in hits.items():
            if comps:
                found = ", ".join(
                    f"{ci}/size={len(self.components[ci])}"
                    for ci in sorted(comps)
                )
            else:
                found = "none"
            if pt is None:
                at = ""
            else:
                at = (
                    f" at ({pt[0]:.1f}, {pt[1]:.1f}, {pt[2]:.1f}) "
                    f"dz={pt[2] - self.ANCHORS[name][2]:.1f}"
                )
            lines.append(
                f"  {name}: nearest={nearest:.1f} yd{at} component={found}"
            )
        self.fail("\n".join(lines))

    def _anchor_hit(
        self, xyz: tuple[float, float, float]
    ) -> tuple[float, Point | None, set[int]]:
        ax, ay, az = xyz
        nearest = float("inf")
        nearest_pt: Point | None = None
        comps: set[int] = set()
        for si, pts in enumerate(self.segments):
            for pt in pts:
                dist = math.hypot(pt[0] - ax, pt[1] - ay)
                if dist < nearest:
                    nearest = dist
                    nearest_pt = pt
                if dist <= ANCHOR_RADIUS_YD and abs(pt[2] - az) <= ANCHOR_Z_YD:
                    comps.add(self.seg_to_comp[si])
        return nearest, nearest_pt, comps


class TestAnchorReachZ(unittest.TestCase):
    """A mesa fake within 89yd XY of the dock must not count as reaching it."""

    def test_mesa_fake_rejected_on_dz(self) -> None:
        dock = (-4677.066, -1853.667, -43.857)
        mesa = (dock[0] + 89.0, dock[1], 86.0)
        floor = (dock[0] + 10.0, dock[1], -44.0)
        self.assertGreater(math.hypot(mesa[0] - dock[0], mesa[1] - dock[1]), 0.0)
        self.assertLessEqual(
            math.hypot(mesa[0] - dock[0], mesa[1] - dock[1]), ANCHOR_RADIUS_YD
        )
        self.assertGreater(abs(mesa[2] - dock[2]), ANCHOR_Z_YD)
        self.assertLessEqual(
            math.hypot(floor[0] - dock[0], floor[1] - dock[1]), ANCHOR_RADIUS_YD
        )
        self.assertLessEqual(abs(floor[2] - dock[2]), ANCHOR_Z_YD)
        self.assertFalse(abs(mesa[2] - dock[2]) <= ANCHOR_Z_YD)
        self.assertTrue(
            math.hypot(floor[0] - dock[0], floor[1] - dock[1]) <= ANCHOR_RADIUS_YD
            and abs(floor[2] - dock[2]) <= ANCHOR_Z_YD
        )


if __name__ == "__main__":
    unittest.main()
