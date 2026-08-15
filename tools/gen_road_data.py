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

# --- bridging pass ---------------------------------------------------------
# RouteModel.build (ShadowArmy.lua) joins points from DIFFERENT polylines that
# land within this many percent of each other. Mirrored here so the generator's
# connectivity numbers are the addon's connectivity numbers, not an optimistic
# model of its own. Keep in sync with RouteModel.junctionDist.
JUNCTION_DIST = 1.5

# The baker cuts a road wherever the mask breaks: bridges, tunnels, town
# cobblestone, a wide crossing. Those cuts are bigger than junctionDist, so the
# addon sees a pile of sticks. We reconnect them here, in the data, rather than
# by loosening junctionDist in the addon (which also glues roads that merely
# pass near each other). Only segment ENDPOINTS are bridged: an endpoint is
# where the baker stopped seeing road, an interior point is road it did see.
#
# The evidence that two stubs are one road is the heading they end on: the z
# coordinate is gone by this stage, so heading is all that separates "the road
# continues" from "there is a lake here". Longer bridges are a bigger claim, so
# they have to be straighter — the cone closes as the gap grows:
#
#   gap <= 2.5%  : no test at all. Too short to be anything but the same road;
#                  this tier is T-junctions, hairpins and town cobblestone.
#   gap <= 6.0%  : within 40 deg of ONE of the two endpoint headings. A bridge,
#                  a ford, a wide crossing — the road bends a little across it.
#   gap <= 12.0% : within 20 deg. Only a road that visibly points at the other
#                  stub gets a span this long, and 12% is where the honest
#                  ceiling is: past that, "aimed at each other" stops being
#                  evidence in a 100x100 space.
#
# (max gap, max angle in degrees), shortest tier first.
BRIDGE_TIERS = ((2.5, 180.0), (6.0, 40.0), (12.0, 20.0))
BRIDGE_MAX_GAP = BRIDGE_TIERS[-1][0]
# Per-zone cap. A zone that wants more than this is not suffering from baker
# cuts, it is missing road, and inventing 100 bridges would only hide that.
BRIDGE_BUDGET = 30

# After bridging, an island smaller than this is dropped. RouteModel routes
# inside one component only, so an unreachable stub can never produce a route —
# it can only win the nearest-node lookup away from the road that could, and
# turn that route into a "disconnected" bail. Four nodes is about 2% of map:
# below that a stub is a bake artifact, above it we keep the road and admit the
# gap in the coverage stats instead of hiding it.
ORPHAN_MIN_NODES = 4


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


def emitted(points: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    """The coordinates the addon will actually read (one decimal)."""
    return [(float(fmt(x)), float(fmt(y))) for x, y in points]


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


def connect(segments: Sequence[Sequence[Tuple[float, float]]],
            join: float = JUNCTION_DIST) -> Tuple[_DSU, List[int]]:
    """Replay RouteModel.build's graph connectivity over one zone.

    Nodes are points; a polyline chains its own points; points from different
    polylines within `join` are one junction. Returns the union-find plus the
    per-segment index of each segment's first node.
    """
    offsets: List[int] = []
    flat: List[Tuple[float, float]] = []
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
    for idx, (x, y) in enumerate(flat):
        grid.setdefault((int(math.floor(x / join)), int(math.floor(y / join))),
                        []).append(idx)
    for idx, (x, y) in enumerate(flat):
        cx = int(math.floor(x / join))
        cy = int(math.floor(y / join))
        for ox in (-1, 0, 1):
            for oy in (-1, 0, 1):
                for jdx in grid.get((cx + ox, cy + oy), ()):
                    if jdx <= idx or owner[jdx] == owner[idx]:
                        continue
                    jx, jy = flat[jdx]
                    if math.hypot(x - jx, y - jy) <= join:
                        dsu.union(idx, jdx)
    return dsu, offsets


def stats(segments: Sequence[Sequence[Tuple[float, float]]],
          join: float = JUNCTION_DIST) -> Tuple[int, int, int]:
    """(component count, largest component size, node count) for one zone."""
    dsu, _ = connect(segments, join)
    if not dsu.parent:
        return 0, 0, 0
    # Distinct COORDINATES, not node slots: a bridge's two endpoints sit exactly
    # on points that already exist, and counting them twice would make the
    # largest-component share fall on a zone that just got better connected.
    flat = [pt for seg in segments for pt in seg]
    groups: Dict[int, set] = {}
    for i, pt in enumerate(flat):
        groups.setdefault(dsu.find(i), set()).add(pt)
    total = len(set(flat))
    return len(groups), max(len(g) for g in groups.values()), total


def _heading(seg: Sequence[Tuple[float, float]],
             at_start: bool) -> Optional[Tuple[float, float]]:
    """Unit vector pointing OUT of the polyline at one of its endpoints."""
    if at_start:
        tip = seg[0]
        rest = seg[1:]
    else:
        tip = seg[-1]
        rest = list(reversed(seg[:-1]))
    for pt in rest:
        dx, dy = tip[0] - pt[0], tip[1] - pt[1]
        d = math.hypot(dx, dy)
        if d > 1e-9:
            return dx / d, dy / d
    return None


def bridge(segments: List[List[Tuple[float, float]]],
           max_gap: float = BRIDGE_MAX_GAP,
           tiers: Sequence[Tuple[float, float]] = BRIDGE_TIERS,
           budget: int = BRIDGE_BUDGET,
           join: float = JUNCTION_DIST) -> List[List[Tuple[float, float]]]:
    """Reconnect baker-cut roads inside one zone. Returns the bridge segments.

    A bridge is a plain two-point polyline whose ends sit exactly on two
    existing segment endpoints, so RouteModel's own junction pass welds it in
    with no addon change: same flat pair format, no marker field.

    Candidates are scored by gap and taken greedily shortest-first, which is
    order-independent and therefore deterministic. A pair is only a candidate
    while its two endpoints are in different components, so merging one gap can
    only ever remove candidates, never add them — the loop settles fast.
    """
    if len(segments) < 2 or budget <= 0 or not tiers:
        return []
    # (gap ceiling, cosine of the cone) shortest-first, so the first tier a gap
    # fits is the tier that judges it.
    cones = [(g, math.cos(math.radians(min(a, 180.0)))) for g, a in tiers]
    max_gap = max(g for g, _ in cones)
    # (segment index, endpoint at start?) -> point, outgoing heading
    ends: List[Tuple[int, bool, Tuple[float, float], Optional[Tuple[float, float]]]] = []
    for si, seg in enumerate(segments):
        if len(seg) < MIN_SEGMENT_POINTS:
            continue
        ends.append((si, True, seg[0], _heading(seg, True)))
        ends.append((si, False, seg[-1], _heading(seg, False)))

    candidates = []
    for ai in range(len(ends)):
        si, _, a, ha = ends[ai]
        for bi in range(ai + 1, len(ends)):
            sj, _, b, hb = ends[bi]
            if si == sj:
                continue
            gap = math.hypot(a[0] - b[0], a[1] - b[1])
            # <= join is already a junction to the addon; > max_gap is a guess.
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
            candidates.append((round(gap, 6), a, b, ai, bi))
    candidates.sort()

    bridges: List[List[Tuple[float, float]]] = []
    while len(bridges) < budget:
        dsu, offsets = connect(list(segments) + bridges, join)
        added = False
        for _gap, a, b, ai, bi in candidates:
            si, a_start, _, _ = ends[ai]
            sj, b_start, _, _ = ends[bi]
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


def prune_orphans(segments: Sequence[Sequence[Tuple[float, float]]],
                  min_nodes: int,
                  join: float = JUNCTION_DIST
                  ) -> List[List[Tuple[float, float]]]:
    """Drop segments left in a tiny island after bridging.

    RouteModel can only route inside one component, so a stub the rest of the
    network cannot reach never produces a route — it only steals the
    nearest-node lookup from the road that could, and turns that route into a
    "disconnected" bail and a straight line. Deleting it strictly increases
    coverage: nothing that routed before stops routing, and the endpoints it
    used to capture now find the real network. Bridging runs first, so only
    stubs no plausible bridge could reach are dropped.
    """
    if min_nodes <= 0 or not segments:
        return [list(seg) for seg in segments]
    dsu, offsets = connect(segments, join)
    sizes: Dict[int, int] = {}
    for i in range(len(dsu.parent)):
        root = dsu.find(i)
        sizes[root] = sizes.get(root, 0) + 1
    # The zone's main network is never an orphan, however thin it is: a zone
    # whose only road is a 3-node stub keeps that stub and short-hops, which is
    # honest, where deleting it would silently erase the zone.
    main = min(sizes, key=lambda r: (-sizes[r], r))
    keep = []
    for si, seg in enumerate(segments):
        root = dsu.find(offsets[si])
        if root == main or sizes[root] >= min_nodes:
            keep.append(list(seg))
    return keep


def emit(by_zone: Dict[int, List[List[Tuple[float, float]]]],
         header: Sequence[str]) -> str:
    lines = ["-- generated by tools/gen_road_data.py; do not edit by hand"]
    lines += [("-- " + line).rstrip() for line in header]
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
    ap.add_argument("--bridge-tiers", default=None,
                    help="bridge gap:angle tiers, e.g. 2.5:180,6:40,12:20")
    ap.add_argument("--bridge-budget", type=int, default=BRIDGE_BUDGET,
                    help="max bridges per zone (0 disables bridging)")
    ap.add_argument("--orphan-min", type=int, default=ORPHAN_MIN_NODES,
                    help="drop islands smaller than this many nodes (0 keeps)")
    args = ap.parse_args(argv)

    tiers = BRIDGE_TIERS
    if args.bridge_tiers:
        tiers = tuple(sorted(
            (float(part.split(":")[0]), float(part.split(":")[1]))
            for part in args.bridge_tiers.split(",") if part.strip()))

    if not os.path.isdir(args.dbc_dir):
        print("error: dbc dir missing: %s" % args.dbc_dir, file=sys.stderr)
        return 1

    areas = MapAreas(args.dbc_dir)

    by_zone: Dict[int, List[List[Tuple[float, float]]]] = {}
    in_segments = in_points = 0
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

    # Sort inside every zone so segment order never depends on file order, and
    # snap to the precision the addon will read so connectivity is measured on
    # the shipped numbers rather than on floats nobody sees.
    for zone in by_zone:
        by_zone[zone] = sorted(emitted(seg) for seg in by_zone[zone])

    # Bridging pass: reconnect roads the baker cut, then report the coverage
    # metric ticket 0046 asks for. Sorted by zone id, so a diff shows exactly
    # which zone's connectivity moved.
    cover: List[str] = []
    bridges_total = 0
    orphan_nodes = 0
    frag_before = frag_after = 0
    share_before_sum = share_after_sum = 0.0
    for zone in sorted(by_zone):
        segs = by_zone[zone]
        comp0, big0, nodes0 = stats(segs)
        new = bridge(segs, tiers=tiers, budget=max(0, args.bridge_budget))
        if new:
            segs = sorted(segs + new)
            bridges_total += len(new)
        pruned = prune_orphans(segs, max(0, args.orphan_min))
        orphan_nodes += sum(len(sg) for sg in segs) - sum(len(sg) for sg in pruned)
        segs = sorted(pruned)
        by_zone[zone] = segs
        comp1, big1, nodes1 = stats(segs)  # empty zones are dropped below
        s0 = (100.0 * big0 / nodes0) if nodes0 else 0.0
        s1 = (100.0 * big1 / nodes1) if nodes1 else 0.0
        share_before_sum += s0
        share_after_sum += s1
        if comp0 >= 3:
            frag_before += 1
        if comp1 >= 3:
            frag_after += 1
        cover.append(
            "zone %5d: components %3d -> %3d, largest %5.1f%% -> %5.1f%%,"
            " bridges %2d" % (zone, comp0, comp1, s0, s1, len(new)))

    for zone in [z for z, segs in by_zone.items() if not segs]:
        del by_zone[zone]

    out_segments = sum(len(segs) for segs in by_zone.values())
    out_points = sum(len(seg) for segs in by_zone.values() for seg in segs)
    nz = len(by_zone) or 1
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
        "bridged %d baker-cut gaps between segment endpoints; the longer the"
        % bridges_total,
        "bridge the straighter it must be -- max gap%% : max deg = %s"
        % ", ".join("%g : %g" % (g, a) for g, a in tiers),
        "(budget %d per zone), then dropped %d points left on islands under %d"
        % (max(0, args.bridge_budget), orphan_nodes, max(0, args.orphan_min)),
        "nodes -- unreachable road is a disconnected bail, not a route",
        "see docs/road-data.md for why those numbers",
        "regenerate: make road-data   (see docs/road-data.md)",
        "",
        "coverage (RouteModel junctionDist %.1f%%): zones with 3+ components"
        % JUNCTION_DIST,
        "%d -> %d of %d; mean largest-component share %.1f%% -> %.1f%%"
        % (frag_before, frag_after, len(by_zone),
           share_before_sum / nz, share_after_sum / nz),
    ] + cover

    text = emit(by_zone, header)
    with open(args.out, "w") as fh:
        fh.write(text)

    print("wrote %s" % args.out)
    print("  in  segments/points : %d / %d" % (in_segments, in_points))
    print("  out segments/points : %d / %d" % (out_segments, out_points))
    print("  zones               : %d" % len(by_zone))
    print("  runs too short      : %d" % dropped)
    print("  bridges added       : %d" % bridges_total)
    print("  orphan points cut   : %d" % orphan_nodes)
    print("  zones 3+ components : %d -> %d" % (frag_before, frag_after))
    print("  mean largest share  : %.1f%% -> %.1f%%"
          % (share_before_sum / nz, share_after_sum / nz))
    print("  size                : %.2f KiB" % (len(text) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
