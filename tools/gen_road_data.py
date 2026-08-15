#!/usr/bin/env python3
"""Generate addons/ShadowArmy/RoadData.lua from the baked road waypoints.

The map-browser experiment already baked every visible road on both continents
into world-coordinate polylines (tools/data/road_waypoints_*.jsonl, loader
reference src/map_browser/roads.nim). The advisor cannot use world coordinates:
1.12 gives an addon nothing but zone-normalized percent
(GetPlayerMapPosition), the same space QuestData already speaks. So this tool
does exactly one job — replay those polylines through the VERIFIED
world->zone converter from tools/gen_quest_data.py and re-emit them per zone.

Reads (read-only, never writes):
  * tools/data/road_waypoints_azeroth.jsonl, road_waypoints_kalimdor.jsonl
  * WorldMapArea.dbc + AreaTable.dbc, via gen_quest_data.MapAreas

No DB, no realm, no network — the artifacts and the DBCs are the whole input.

The axis convention is NOT re-derived here. gen_quest_data.MapAreas is imported
verbatim precisely because the transposition trap (docs/quest-data.md) is easy
to walk back into: taking locTop/locBottom for the map's x produces coordinates
that are individually in range and therefore look fine, and every road would
land somewhere plausible but wrong.

Deterministic: sorted by zone, no timestamps, so a re-run against unchanged
inputs produces a byte-identical file.

  python3 tools/gen_road_data.py            # or: make road-data
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from typing import Dict, List, Optional, Sequence, Tuple

# Same directory as this file, so a plain `python3 tools/gen_road_data.py`
# resolves the sibling generator without any package plumbing.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_quest_data import DEFAULT_DBC_DIR, MapAreas  # noqa: E402

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(_REPO, "addons", "ShadowArmy", "RoadData.lua")
DEFAULT_DATA_DIR = os.path.join(_REPO, "tools", "data")

# Continent artifacts in emit order. map_id comes from each file's meta line
# (roads.nim defaults it to 1), these are only the filenames.
ROAD_FILES = ("road_waypoints_azeroth.jsonl", "road_waypoints_kalimdor.jsonl")

# Decimation in zone-normalized percent. The bake already thinned to ~10 yd
# spacing in WORLD units, which is far denser than a routing graph needs: a
# vanilla zone is roughly 3500 x 2333 yards, so 0.7% is ~20 yards and the graph
# keeps its shape at a third of the points. Endpoints are always kept, so a
# short segment never collapses to nothing.
MIN_POINT_GAP = 0.7

# A polyline needs two points to be an edge; anything shorter is dropped.
MIN_SEGMENT_POINTS = 2


def load_segments(path: str) -> Tuple[int, List[List[Tuple[float, float]]]]:
    """(map_id, [ [(worldX, worldY), ...], ... ]) from one JSONL artifact.

    Same contract as src/map_browser/roads.nim: a meta line first (`meta`,
    `map_id`, default 1), then one segment object per line with `pts` as world
    [x, y, z]. A missing file is an empty result rather than an error.
    """
    if not os.path.isfile(path):
        return 1, []
    map_id = 1
    out: List[List[Tuple[float, float]]] = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            if "meta" in obj:
                map_id = int(obj.get("map_id", 1))
                continue
            pts = obj.get("pts")
            if not isinstance(pts, list):
                continue
            world: List[Tuple[float, float]] = []
            for pt in pts:
                if isinstance(pt, list) and len(pt) >= 2:
                    world.append((float(pt[0]), float(pt[1])))
            if len(world) >= MIN_SEGMENT_POINTS:
                out.append(world)
    return map_id, out


def split_by_zone(world: Sequence[Tuple[float, float]], map_id: int,
                  areas: MapAreas) -> List[Tuple[int, List[Tuple[float, float]]]]:
    """Cut one world polyline into runs of consecutive same-zone points.

    A continent road crosses zone boundaries constantly and the addon's map
    space is per-zone, so a crossing is a segment split, not a long edge into
    another coordinate system. Points with no zone map at all (open sea, the
    handful of unmapped strips between zones) end the current run.
    """
    runs: List[Tuple[int, List[Tuple[float, float]]]] = []
    zone = 0
    current: List[Tuple[float, float]] = []
    for wx, wy in world:
        hit = areas.locate(map_id, wx, wy)
        if hit is None:
            if len(current) >= MIN_SEGMENT_POINTS:
                runs.append((zone, current))
            zone, current = 0, []
            continue
        area, mx, my = hit
        if area != zone:
            if len(current) >= MIN_SEGMENT_POINTS:
                runs.append((zone, current))
            zone, current = area, []
        current.append((mx, my))
    if len(current) >= MIN_SEGMENT_POINTS:
        runs.append((zone, current))
    return runs


def decimate(points: Sequence[Tuple[float, float]],
             min_gap: float) -> List[Tuple[float, float]]:
    """Keep points at least min_gap percent apart; endpoints always survive."""
    if len(points) <= MIN_SEGMENT_POINTS:
        return list(points)
    kept = [points[0]]
    for pt in points[1:-1]:
        lx, ly = kept[-1]
        if math.hypot(pt[0] - lx, pt[1] - ly) >= min_gap:
            kept.append(pt)
    last = points[-1]
    lx, ly = kept[-1]
    if math.hypot(last[0] - lx, last[1] - ly) >= min_gap or len(kept) < MIN_SEGMENT_POINTS:
        kept.append(last)
    return kept


def fmt(value: float) -> str:
    return "%.1f" % value


def emit(by_zone: Dict[int, List[List[Tuple[float, float]]]],
         header: Sequence[str]) -> str:
    lines = ["-- generated by tools/gen_road_data.py; do not edit by hand"]
    lines += ["-- " + line for line in header]
    lines.append("")
    lines.append("ShadowArmyRoadData = {")
    for zone in sorted(by_zone):
        lines.append("[%d] = {" % zone)
        for seg in by_zone[zone]:
            flat = []
            for x, y in seg:
                flat.append(fmt(x))
                flat.append(fmt(y))
            lines.append("{" + ",".join(flat) + "},")
        lines.append("},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dbc-dir", default=DEFAULT_DBC_DIR)
    ap.add_argument("--data-dir", default=DEFAULT_DATA_DIR)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--min-gap", type=float, default=MIN_POINT_GAP,
                    help="minimum spacing between emitted points, in percent")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.dbc_dir):
        print("error: dbc dir missing: %s" % args.dbc_dir, file=sys.stderr)
        return 1

    areas = MapAreas(args.dbc_dir)

    by_zone: Dict[int, List[List[Tuple[float, float]]]] = {}
    in_segments = in_points = 0
    out_points = 0
    dropped = 0
    for name in ROAD_FILES:
        map_id, segments = load_segments(os.path.join(args.data_dir, name))
        if not segments:
            print("warn: no segments in %s" % name, file=sys.stderr)
        for world in segments:
            in_segments += 1
            in_points += len(world)
            for zone, pts in split_by_zone(world, map_id, areas):
                kept = decimate(pts, args.min_gap)
                if len(kept) < MIN_SEGMENT_POINTS:
                    dropped += 1
                    continue
                by_zone.setdefault(zone, []).append(kept)
                out_points += len(kept)

    # Sort inside every zone so segment order never depends on file order.
    for segs in by_zone.values():
        segs.sort()

    out_segments = sum(len(segs) for segs in by_zone.values())
    header = [
        "source: tools/data/road_waypoints_{azeroth,kalimdor}.jsonl"
        " (world coords) + WorldMapArea.dbc",
        "in : %d segments / %d points" % (in_segments, in_points),
        "out: %d segments / %d points across %d zones"
        % (out_segments, out_points, len(by_zone)),
        "points thinned to >= %.1f%% apart; segments split at zone borders"
        % args.min_gap,
        "coords are zone-normalized percent (GetPlayerMapPosition * 100),"
        " flat x,y pairs",
        "regenerate: make road-data   (see docs/road-data.md)",
    ]

    text = emit(by_zone, header)
    with open(args.out, "w") as fh:
        fh.write(text)

    print("wrote %s" % args.out)
    print("  in  segments/points : %d / %d" % (in_segments, in_points))
    print("  out segments/points : %d / %d" % (out_segments, out_points))
    print("  zones               : %d" % len(by_zone))
    print("  runs too short      : %d" % dropped)
    print("  size                : %.2f KiB" % (len(text) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
