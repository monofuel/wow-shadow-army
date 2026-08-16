#!/usr/bin/env python3
"""Generate lua/data/bot_roads.lua from the baked road waypoints.

The bots live in WORLD coordinates: the Observation mirror hands them a flat
WorldPoint ({map_id,x,y,z}) for every unit and roster row, and `navigate`
intents are world points too. So unlike the addon generator
(tools/gen_road_data.py, which projects the same artifacts into the
zone-normalized percent an in-game addon is stuck with), this one does NOT
convert anything: it replays the baked polylines straight through, decimates
them to a routing-friendly spacing, and emits one Lua table per continent map.

No DBCs, no terrain grids, no realm, no DB, no network — the two JSONL
artifacts are the whole input. That is the point: the zone-assignment work
(which WorldMapArea box owns a point) is the addon's problem, not ours, so
none of its known gaps can reach this file.

Reads (read-only, never writes):
  * tools/data/road_waypoints_azeroth.jsonl  -> map 0
  * tools/data/road_waypoints_kalimdor.jsonl -> map 1

Writes lua/data/bot_roads.lua:

    return {
    [0] = {
    {x1,y1,z1,x2,y2,z2,...},   -- one flat polyline, world coords, yards
    ...
    },
    [1] = { ... },
    }

Deterministic: input order is preserved, floats are rounded to one decimal,
there is no timestamp, so a re-run against unchanged inputs produces a
byte-identical file.

  python3 tools/gen_bot_road_data.py        # or: make bot-road-data
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List, Optional, Sequence, Tuple

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DATA_DIR = os.path.join(_REPO, "tools", "data")
DEFAULT_OUT = os.path.join(_REPO, "lua", "data", "bot_roads.lua")

# Continent artifacts in emit order. The map id comes from each file's meta
# line (azeroth 0, kalimdor 1); these are only the filenames.
ROAD_FILES = ("road_waypoints_azeroth.jsonl", "road_waypoints_kalimdor.jsonl")

# Decimation in world units (yards). The bake already thinned to ~10 yd, which
# is denser than a router needs and doubles every Dijkstra it feeds. 20 yd is
# about one and a half player body lengths: still finer than the ~28 yd the
# bake allows a road to be wide, so the shape of every curve survives.
MIN_POINT_GAP = 20.0

# A polyline needs two points to be an edge; anything shorter is dropped.
MIN_SEGMENT_POINTS = 2

# lua/tools/road_route.lua welds points from DIFFERENT polylines that land
# within this many yards of each other. Mirrored here so the generator's
# connectivity numbers ARE the router's connectivity numbers, not an optimistic
# model of its own. Keep in sync with road_route.M.junctionDist.
JUNCTION_DIST = 25.0

# The baker cuts a road wherever the mask breaks: bridges, tunnels, town
# cobblestone, a wide crossing, a zone border. Those cuts are far bigger than
# junctionDist, so the raw artifacts are a pile of sticks -- measured on this
# bake, 100 components on Azeroth with the largest holding 13% of the points,
# which means essentially every cross-zone route bails "disconnected". We
# reconnect them here, in the data, rather than by loosening the router's
# junction distance (which would also glue roads that merely pass near each
# other). Only segment ENDPOINTS are bridged: an endpoint is where the baker
# stopped seeing road, an interior point is road it did see.
#
# The evidence that two stubs are one road is the heading they end on. Longer
# bridges are a bigger claim, so they have to be straighter -- the cone closes
# as the gap grows. Same shape as tools/gen_road_data.py's BRIDGE_TIERS,
# restated in yards (its percentages were of a ~3500 x 2333 yd zone, so 2.5%
# was ~60-90 yd, 6% ~140-210, 12% ~280-420):
#
#   gap <=  60 yd : no test at all. Too short to be anything but the same road;
#                   this tier is T-junctions, hairpins and town cobblestone.
#   gap <= 150 yd : within 40 deg of ONE of the two endpoint headings. A
#                   bridge, a ford, a wide crossing -- the road bends a little.
#   gap <= 350 yd : within 20 deg. Only a road that visibly points at the other
#                   stub earns a span this long.
BRIDGE_TIERS = ((60.0, 180.0), (150.0, 40.0), (350.0, 20.0))
BRIDGE_MAX_GAP = BRIDGE_TIERS[-1][0]
# Per-map cap. A continent that wants more than this is not suffering from
# baker cuts, it is missing road, and inventing bridges would only hide that.
BRIDGE_BUDGET = 300

# After bridging, an island smaller than this is dropped. The router routes
# inside one component only, so an unreachable stub can never produce a route --
# it can only win the nearest-node lookup away from the road that could, and
# turn that route into a "disconnected" bail.
ORPHAN_MIN_NODES = 4

Point = Tuple[float, float, float]
# map id, artifact, in segs, in pts, out segs, out pts, road yards, bounds,
# bridges added, islands dropped, (components, largest, points) before/after
MapStats = Tuple[int, str, int, int, int, int, float, str, int, int,
                 Tuple[int, int, int], Tuple[int, int, int]]


def load_segments(path: str) -> Tuple[int, List[List[Point]]]:
    """(map_id, [ [(x, y, z), ...], ... ]) from one JSONL artifact.

    Same contract as tools/gen_road_data.load_segments and
    src/map_browser/roads.nim: a meta line first (`meta`, `map_id`, default 1),
    then one segment object per line with `pts` as world [x, y, z]. A missing
    file is an empty result rather than an error.
    """
    if not os.path.isfile(path):
        return 1, []
    map_id = 1
    out: List[List[Point]] = []
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
            world: List[Point] = []
            for pt in pts:
                if isinstance(pt, list) and len(pt) >= 2:
                    z = float(pt[2]) if len(pt) >= 3 else 0.0
                    world.append((float(pt[0]), float(pt[1]), z))
            if len(world) >= MIN_SEGMENT_POINTS:
                out.append(world)
    return map_id, out


def decimate(points: Sequence[Point], min_gap: float) -> List[Point]:
    """Thin a polyline to >= min_gap horizontal spacing, endpoints kept.

    Horizontal (x,y) distance only: a switchback up a mountain is still a
    road, and dropping its points because the climb is steep would straighten
    the very corner the router needs to round.
    """
    if len(points) < MIN_SEGMENT_POINTS:
        return list(points)
    kept: List[Point] = [points[0]]
    for pt in points[1:-1]:
        lx, ly, _ = kept[-1]
        if math.hypot(pt[0] - lx, pt[1] - ly) >= min_gap:
            kept.append(pt)
    last = points[-1]
    lx, ly, _ = kept[-1]
    if math.hypot(last[0] - lx, last[1] - ly) > 0.0 or len(kept) < MIN_SEGMENT_POINTS:
        kept.append(last)
    return kept


class _DSU:
    def __init__(self, n: int) -> None:
        self.parent = list(range(n))

    def find(self, a: int) -> int:
        root = a
        while self.parent[root] != root:
            root = self.parent[root]
        while self.parent[a] != root:
            self.parent[a], a = root, self.parent[a]
        return root

    def union(self, a: int, b: int) -> bool:
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return False
        if rb < ra:
            ra, rb = rb, ra
        self.parent[rb] = ra
        return True


def connect(segments: Sequence[Sequence[Point]],
            join: float = JUNCTION_DIST) -> Tuple[_DSU, List[int]]:
    """Replay road_route.build's graph connectivity over one map.

    Nodes are points; a polyline chains its own points; points from different
    polylines within `join` are one junction. Returns the union-find plus the
    index of each segment's first node.
    """
    offsets: List[int] = []
    flat: List[Point] = []
    owner: List[int] = []
    for si, seg in enumerate(segments):
        offsets.append(len(flat))
        for pt in seg:
            flat.append(pt)
            owner.append(si)
    dsu = _DSU(len(flat))
    for si, seg in enumerate(segments):
        base = offsets[si]
        for k in range(1, len(seg)):
            dsu.union(base + k - 1, base + k)
    grid: Dict[Tuple[int, int], List[int]] = {}
    for idx, pt in enumerate(flat):
        grid.setdefault((int(math.floor(pt[0] / join)),
                         int(math.floor(pt[1] / join))), []).append(idx)
    for idx, pt in enumerate(flat):
        cx = int(math.floor(pt[0] / join))
        cy = int(math.floor(pt[1] / join))
        for ox in (-1, 0, 1):
            for oy in (-1, 0, 1):
                for jdx in grid.get((cx + ox, cy + oy), ()):
                    if jdx <= idx or owner[jdx] == owner[idx]:
                        continue
                    if math.hypot(pt[0] - flat[jdx][0],
                                  pt[1] - flat[jdx][1]) <= join:
                        dsu.union(idx, jdx)
    return dsu, offsets


def components(segments: Sequence[Sequence[Point]],
               join: float = JUNCTION_DIST) -> Tuple[int, int, int]:
    """(component count, largest component size, distinct point count)."""
    dsu, _ = connect(segments, join)
    if not dsu.parent:
        return 0, 0, 0
    flat = [pt for seg in segments for pt in seg]
    groups: Dict[int, set] = {}
    for i, pt in enumerate(flat):
        groups.setdefault(dsu.find(i), set()).add(pt)
    return len(groups), max(len(g) for g in groups.values()), len(set(flat))


def _heading(seg: Sequence[Point], at_start: bool) -> Optional[Tuple[float, float]]:
    """Unit vector pointing OUT of the polyline at one of its endpoints."""
    if at_start:
        tip, rest = seg[0], seg[1:]
    else:
        tip, rest = seg[-1], list(reversed(seg[:-1]))
    for pt in rest:
        dx, dy = tip[0] - pt[0], tip[1] - pt[1]
        d = math.hypot(dx, dy)
        if d > 1e-9:
            return dx / d, dy / d
    return None


def bridge(segments: List[List[Point]],
           tiers: Sequence[Tuple[float, float]] = BRIDGE_TIERS,
           budget: int = BRIDGE_BUDGET,
           join: float = JUNCTION_DIST) -> List[List[Point]]:
    """Reconnect baker-cut roads. Returns the bridge segments to append.

    A bridge is a plain two-point polyline whose ends sit exactly on two
    existing segment endpoints (z included), so the router's own junction pass
    welds it in with no router change: same flat triple format, no marker.

    Candidates are taken greedily shortest-first, which is order-independent
    and therefore deterministic. A pair is only a candidate while its two
    endpoints are in different components, so merging one gap can only remove
    candidates, never add them -- the loop settles.
    """
    if len(segments) < 2 or budget <= 0 or not tiers:
        return []
    cones = [(g, math.cos(math.radians(min(a, 180.0)))) for g, a in tiers]
    max_gap = max(g for g, _ in cones)
    ends: List[Tuple[int, bool, Point, Optional[Tuple[float, float]]]] = []
    for si, seg in enumerate(segments):
        if len(seg) < MIN_SEGMENT_POINTS:
            continue
        ends.append((si, True, seg[0], _heading(seg, True)))
        ends.append((si, False, seg[-1], _heading(seg, False)))

    candidates: List[Tuple[float, int, int]] = []
    for ai in range(len(ends)):
        si, _, a, ha = ends[ai]
        for bi in range(ai + 1, len(ends)):
            sj, _, b, hb = ends[bi]
            if si == sj:
                continue
            gap = math.hypot(a[0] - b[0], a[1] - b[1])
            # <= join is already a junction to the router; > max_gap is a guess.
            if gap <= join or gap > max_gap:
                continue
            cos_limit = None
            for ceiling, cone in cones:
                if gap <= ceiling:
                    cos_limit = cone
                    break
            if cos_limit is not None and cos_limit > -1.0:
                ux, uy = (b[0] - a[0]) / gap, (b[1] - a[1]) / gap
                ok = False
                if ha and ux * ha[0] + uy * ha[1] >= cos_limit:
                    ok = True
                if hb and -ux * hb[0] + -uy * hb[1] >= cos_limit:
                    ok = True
                if not ok:
                    continue
            candidates.append((round(gap, 6), ai, bi))
    candidates.sort()

    bridges: List[List[Point]] = []
    while len(bridges) < budget:
        dsu, offsets = connect(list(segments) + bridges, join)
        added = False
        for _gap, ai, bi in candidates:
            si, a_start, a, _ = ends[ai]
            sj, b_start, b, _ = ends[bi]
            na = offsets[si] + (0 if a_start else len(segments[si]) - 1)
            nb = offsets[sj] + (0 if b_start else len(segments[sj]) - 1)
            if dsu.find(na) == dsu.find(nb):
                continue
            bridges.append([a, b])
            added = True
            break
        if not added:
            break
    return bridges


def prune_orphans(segments: Sequence[Sequence[Point]], min_nodes: int,
                  join: float = JUNCTION_DIST) -> List[List[Point]]:
    """Drop segments left in a tiny island after bridging.

    The router routes inside one component only, so a stub the rest of the
    network cannot reach never produces a route -- it only steals the
    nearest-node lookup from the road that could, turning that route into a
    "disconnected" bail. Deleting it strictly increases coverage. The map's
    main network is never an orphan, however thin it is.
    """
    if min_nodes <= 0 or not segments:
        return [list(seg) for seg in segments]
    dsu, offsets = connect(segments, join)
    sizes: Dict[int, int] = {}
    for i in range(len(dsu.parent)):
        root = dsu.find(i)
        sizes[root] = sizes.get(root, 0) + 1
    main = min(sizes, key=lambda r: (-sizes[r], r))
    keep = []
    for si, seg in enumerate(segments):
        root = dsu.find(offsets[si])
        if root == main or sizes[root] >= min_nodes:
            keep.append(list(seg))
    return keep


def fmt(value: float) -> str:
    return "%.1f" % value


def emit(by_map: Dict[int, List[List[Point]]], header: Sequence[str]) -> str:
    lines = ["-- generated by tools/gen_bot_road_data.py; do not edit by hand"]
    lines += [("-- " + line).rstrip() for line in header]
    lines.append("")
    lines.append("return {")
    for map_id in sorted(by_map):
        lines.append("[%d] = {" % map_id)
        for seg in by_map[map_id]:
            flat: List[str] = []
            for x, y, z in seg:
                flat.append(fmt(x))
                flat.append(fmt(y))
                flat.append(fmt(z))
            lines.append("{" + ",".join(flat) + "},")
        lines.append("},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def span(segments: Sequence[Sequence[Point]]) -> str:
    """Bounding box of a map's road points, as a coverage sanity line."""
    xs = [p[0] for seg in segments for p in seg]
    ys = [p[1] for seg in segments for p in seg]
    if not xs:
        return "empty"
    return "x %.0f..%.0f  y %.0f..%.0f" % (min(xs), max(xs), min(ys), max(ys))


def length_yd(segments: Sequence[Sequence[Point]]) -> float:
    total = 0.0
    for seg in segments:
        for a, b in zip(seg, seg[1:]):
            total += math.hypot(b[0] - a[0], b[1] - a[1])
    return total


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data-dir", default=DEFAULT_DATA_DIR)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--min-gap", type=float, default=MIN_POINT_GAP,
                    help="decimation spacing in world yards (default %.0f)"
                         % MIN_POINT_GAP)
    ap.add_argument("--junction", type=float, default=JUNCTION_DIST,
                    help="router junction distance in yards; must match "
                         "road_route.junctionDist (default %.0f)"
                         % JUNCTION_DIST)
    ap.add_argument("--bridge-budget", type=int, default=BRIDGE_BUDGET,
                    help="max bridges per map (0 disables bridging)")
    ap.add_argument("--bridge-tiers", default=None,
                    help="bridge gap:angle tiers in yards, e.g. 60:180,150:40")
    ap.add_argument("--orphan-min", type=int, default=ORPHAN_MIN_NODES,
                    help="drop islands smaller than this (0 disables)")
    args = ap.parse_args(argv)

    tiers = BRIDGE_TIERS
    if args.bridge_tiers:
        tiers = tuple(sorted(
            (float(part.split(":")[0]), float(part.split(":")[1]))
            for part in args.bridge_tiers.split(",") if part.strip()))

    by_map: Dict[int, List[List[Point]]] = {}
    stats: List[MapStats] = []
    for name in ROAD_FILES:
        map_id, segments = load_segments(os.path.join(args.data_dir, name))
        in_points = sum(len(s) for s in segments)
        thinned = [decimate(s, args.min_gap) for s in segments]
        thinned = [s for s in thinned if len(s) >= MIN_SEGMENT_POINTS]
        comp0, big0, nodes0 = components(thinned, args.junction)
        bridges = bridge(thinned, tiers=tiers,
                         budget=max(0, args.bridge_budget), join=args.junction)
        joined = thinned + bridges
        kept = prune_orphans(joined, max(0, args.orphan_min), args.junction)
        dropped = len(joined) - len(kept)
        comp1, big1, nodes1 = components(kept, args.junction)
        out_points = sum(len(s) for s in kept)
        bucket = by_map.setdefault(map_id, [])
        bucket.extend(kept)
        stats.append((map_id, name, len(segments), in_points,
                      len(kept), out_points, length_yd(kept), span(kept),
                      len(bridges), dropped,
                      (comp0, big0, nodes0), (comp1, big1, nodes1)))

    header = [
        "source: tools/data/road_waypoints_{azeroth,kalimdor}.jsonl"
        " (world coords, no conversion)",
        "coords are WORLD units (yards), flat x,y,z triples per polyline,"
        " keyed by map id",
        "points thinned to >= %.0f yd apart; endpoints always kept"
        % args.min_gap,
        "baker-cut gaps between segment ENDPOINTS are bridged -- the longer"
        " the bridge the straighter it must be,",
        "max gap yd : max deg = %s (router junctionDist %.0f yd)"
        % (", ".join("%g : %g" % (g, a) for g, a in tiers), args.junction),
        "islands under %d nodes are then dropped: unreachable road can only"
        % max(0, args.orphan_min),
        "steal the nearest-node lookup and turn a route into a disconnected"
        " bail",
    ]
    for (map_id, name, in_segs, in_pts, out_segs, out_pts, road_yd, box,
         nbridges, dropped, before, after) in stats:
        short = name.replace("road_waypoints_", "").replace(".jsonl", "")
        header.append(
            "map %d (%s): %d segs / %d pts -> %d segs / %d pts,"
            " %.0f yd of road" % (map_id, short, in_segs, in_pts,
                                  out_segs, out_pts, road_yd))
        header.append("  bounds: %s" % box)
        header.append(
            "  connectivity: %d components (largest %.0f%% of %d pts)"
            " -> %d bridges, %d islands dropped -> %d components"
            " (largest %.0f%% of %d pts)"
            % (before[0], 100.0 * before[1] / max(before[2], 1), before[2],
               nbridges, dropped,
               after[0], 100.0 * after[1] / max(after[2], 1), after[2]))
    header += [
        "",
        "the bake only ever saw painted road and minimap ribbon, so this is a",
        "partial network (docs/road-data.md 'Known gaps') and the largest",
        "component is NOT the whole continent. A hole is not an error:",
        "lua/tools/road_route.lua answers straight=true (reason disconnected /",
        "short-hop) and the caller walks the crow line it would have walked",
        "anyway.",
        "regenerate: make bot-road-data",
    ]

    text = emit(by_map, header)
    out_dir = os.path.dirname(args.out)
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    with open(args.out, "w") as fh:
        fh.write(text)

    print("wrote %s" % args.out)
    for (map_id, name, in_segs, in_pts, out_segs, out_pts, road_yd, box,
         nbridges, dropped, before, after) in stats:
        short = name.replace("road_waypoints_", "").replace(".jsonl", "")
        print("  map %d %-9s in %4d/%6d  out %4d/%6d  %8.0f yd  %s"
              % (map_id, short, in_segs, in_pts, out_segs, out_pts,
                 road_yd, box))
        print("    components %d (largest %.0f%%) -> %d (largest %.0f%%)"
              "   bridges %d, islands dropped %d"
              % (before[0], 100.0 * before[1] / max(before[2], 1),
                 after[0], 100.0 * after[1] / max(after[2], 1),
                 nbridges, dropped))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
