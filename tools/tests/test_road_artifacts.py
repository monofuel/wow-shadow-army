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
    # Boundary bands, not route anchors. The detector owns the exact crossing
    # point and must discover it from minimap ribbon evidence.
    TERMINAL_BANDS = {
        "feralas": lambda x, y, z: -4500 <= x <= -4200 and -1250 <= y <= -650 and -100 <= z <= -15,
        "great_lift": lambda x, y, z: -4780 <= x <= -4550 and -1950 <= y <= -1780 and -100 <= z <= -15,
        "tanaris": lambda x, y, z: -6900 <= x <= -6500 and -3900 <= y <= -3100 and 25 <= z <= 110,
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
        hits = {name: self._band_hit(predicate) for name, predicate in self.TERMINAL_BANDS.items()}
        shared: set[int] | None = None
        for _nearest, _pt, comps in hits.values():
            if shared is None:
                shared = set(comps)
            else:
                shared &= comps
        if shared:
            return
        lines = [
            "Thousand Needles floor must share one component with all "
            f"neighbor boundary terminals (stitch={STITCH_YD} yd)."
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
                    f" at ({pt[0]:.1f}, {pt[1]:.1f}, {pt[2]:.1f})"
                )
            lines.append(
                f"  {name}: nearest={nearest:.1f} yd{at} component={found}"
            )
        self.fail("\n".join(lines))

    def test_visual_segments_are_source_honest(self) -> None:
        visual = []
        with ARTIFACT.open() as handle:
            next(handle)
            for raw in handle:
                obj = json.loads(raw)
                if obj.get("source") in {"minimap_ribbon", "visual_gap_bridge"}:
                    visual.append(obj)
        self.assertTrue(visual)
        for obj in visual:
            source = obj["source"]
            self.assertEqual(
                obj.get("confidence"), 1.0 if source == "minimap_ribbon" else 0.0
            )
            if source == "visual_gap_bridge":
                length = sum(
                    math.hypot(b[0] - a[0], b[1] - a[1])
                    for a, b in zip(obj["pts"], obj["pts"][1:])
                )
                self.assertLessEqual(length, 24.1)

    def _band_hit(self, predicate):
        comps = set()
        first = None
        for si, pts in enumerate(self.segments):
            for pt in pts:
                if predicate(*pt):
                    comps.add(self.seg_to_comp[si])
                    if first is None:
                        first = pt
        return (0.0 if first else float("inf"), first, comps)

if __name__ == "__main__":
    unittest.main()
