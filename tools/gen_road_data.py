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
  * the extracted terrain grids (maps/*.map), for the per-cell area ids that
    arbitrate which zone a point is really in -- see TerrainAreas

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
import struct
import sys
from typing import Dict, List, Optional, Sequence, Set, Tuple

# Same directory as this file, so a plain `python3 tools/gen_road_data.py`
# resolves the sibling generator without any package plumbing.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_quest_data import DEFAULT_DBC_DIR, MapAreas  # noqa: E402

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(_REPO, "addons", "ShadowArmy", "RoadData.lua")
DEFAULT_DATA_DIR = os.path.join(_REPO, "tools", "data")
# The terrain grids sit next to the DBCs in the same extracted-data tree, so
# the default tracks --dbc-dir instead of hardcoding a second path.
DEFAULT_MAP_DIR = os.path.join(os.path.dirname(DEFAULT_DBC_DIR), "maps")

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

# --- capital-box resurfacing (ticket 0050) ---------------------------------
# The five capital WorldMapArea boxes are axis-aligned rectangles laid over
# open ground: Undercity's box covers the Ruins of Lordaeron, Ironforge's the
# mountain road to its gates, Orgrimmar's a strip of Durotar, Darnassus' a
# corner of Teldrassil. The smallest-box rule then files that OUTDOOR road
# under the city, and a player standing in Tirisfal cannot see the road they
# are walking on (ticket 0050: Brill -> Undercity entrance bailed short-hop
# with all 57 points of the southern Tirisfal road hidden in zone 1497).
#
# The bake is the evidence that settles it. These polylines come from terrain
# and minimap art, so the baker only ever saw SURFACE road -- it cannot see
# Undercity's tunnels or Ironforge's halls. Whether a run of points inside a
# city box is the city's own street or the zone's road underneath the box is
# therefore answered by the polyline itself:
#
#   * a run that is CONTINUOUS with points outside the box (the same baked
#     polyline crosses the box edge at walkable terrain height) is one road
#     with the outdoor zone -> re-file it under that zone;
#   * a polyline that never leaves the box is the capital's own network
#     (Thunder Bluff's mesas, Darnassus' streets) -> leave it alone.
#
# Measured on this bake the split is total: every crossing run sits within
# 27.2 world units of the surface it crosses into, and every capital-only
# polyline is hundreds of units away in z from anything outside. The band
# below is the guard that keeps it that way if a re-bake ever walks a ramp
# from the parent zone up into a city (Thunder Bluff's lifts): the run stops
# being "the same surface" once it climbs out of the band, and the rest of the
# city keeps its roads. Negative disables the whole pass.
CAPITAL_Z_BAND = 60.0

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


def load_segments(path: str) -> Tuple[int, List[List[Tuple[float, float, float]]]]:
    """(map_id, [ [(worldX, worldY, worldZ), ...], ... ]) from one JSONL artifact.

    Same contract as src/map_browser/roads.nim: a meta line first (`meta`,
    `map_id`, default 1), then one segment object per line with `pts` as world
    [x, y, z]. A missing file is an empty result rather than an error.

    z is carried through the loader (it is dropped again the moment a point is
    converted to zone percent) because it is the only evidence that separates a
    capital's own streets from the outdoor road its map box overlays -- see
    CAPITAL_Z_BAND and resurface_capitals.
    """
    if not os.path.isfile(path):
        return 1, []
    map_id = 1
    out: List[List[Tuple[float, float, float]]] = []
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
            world: List[Tuple[float, float, float]] = []
            for pt in pts:
                if isinstance(pt, list) and len(pt) >= 2:
                    z = float(pt[2]) if len(pt) >= 3 else 0.0
                    world.append((float(pt[0]), float(pt[1]), z))
            if len(world) >= MIN_SEGMENT_POINTS:
                out.append(world)
    return map_id, out


# --- ground-truth zone footprints (ticket 0059) ----------------------------
# WorldMapArea boxes are axis-aligned rectangles over zones that are not
# rectangles, so outdoor boxes overlap outdoor boxes: Western Plaguelands' box
# reaches west past Tirisfal x~57.9 and swallows Brill, and the smallest-box
# rule then files the whole Brill corridor under zone 28. 0050 fixed the
# capital case with a containment rule; nothing about containment helps when
# two peer boxes simply overlap, and WorldMapOverlay.dbc was measured as an
# arbiter and rejected (its rects sprawl too, re-filing 1858-2854 points
# including obvious bulk mistakes).
#
# The client does not use boxes to answer "what zone am I in" -- it reads the
# terrain. vmangos' extractor bakes exactly that into maps/*.map: a per-cell
# AreaTable.exploreFlag grid, 16x16 cells over each 533.33-unit terrain grid,
# which is the zone footprint at its real shape rather than its bounding box.
# Walking that area id up AreaTable.parentAreaId gives the zone the client
# itself would name. That is ground truth, so it arbitrates; the box rule stays
# as the fallback for cells the grids do not answer for.
#
# File format, verified against this build's files and
# local_data/reference/vmangos-core/src/game/Maps/GridMapDefines.h:
#   header  : 'MAPS', 'z1.4', then 8 uint32 offset/size pairs (40 bytes)
#   at areaMapOffset: 'AREA', uint16 flags, uint16 gridArea
#     flags & MAP_AREA_NO_AREA -> the whole grid is gridArea, no table follows
#     otherwise                -> uint16[16*16] cell table
# Both magics are checked before any offset is trusted.
MAP_MAGIC = b"MAPS"
MAP_VERSION_MAGIC = b"z1.4"
MAP_AREA_MAGIC = b"AREA"
MAP_AREA_NO_AREA = 0x0001
# GridDefines.h SIZE_OF_GRIDS; 64x64 grids of 16x16 area cells per continent.
SIZE_OF_GRIDS = 533.33333
_MAP_HEADER = struct.Struct("<4s4s8I")
_AREA_HEADER = struct.Struct("<4sHH")
_AREA_CELLS = struct.Struct("<256H")


class TerrainAreas:
    """world (map, x, y) -> AreaTable id, from the extracted terrain grids.

    Indexing is vmangos' own, not a re-derivation (GridMap.cpp
    TerrainInfo::GetGrid + GridMap::getArea): the grid file for a point is
    `%03u%02u%02u.map` % (mapId, int(32 - worldX/SIZE), int(32 - worldY/SIZE)),
    and inside it the cell is `[lx * 16 + ly]` with lx from worldX and ly from
    worldY. Note the axis pairing is the same swap the addon's map percent
    uses, and for the same reason -- it is left alone here too.

    Grids are memoised on first touch, and a miss is cached too so a road along
    an unbuilt tile does not re-stat it per point. This bake's 10211 points
    touch 285 tiles, all of them readable, so the working set is ~145 KiB of
    uint16.
    """

    def __init__(self, map_dir: str) -> None:
        self.map_dir = map_dir
        # (map, tileA, tileB) -> (flat area, cell table or None); None == no file
        self._grids: Dict[Tuple[int, int, int], Optional[Tuple[int, Optional[Sequence[int]]]]] = {}
        self.bad_files: List[str] = []

    def available(self) -> bool:
        return os.path.isdir(self.map_dir)

    def _grid(self, map_id: int, ta: int, tb: int
              ) -> Optional[Tuple[int, Optional[Sequence[int]]]]:
        key = (map_id, ta, tb)
        if key in self._grids:
            return self._grids[key]
        path = os.path.join(self.map_dir, "%03u%02u%02u.map" % (map_id, ta, tb))
        grid: Optional[Tuple[int, Optional[Sequence[int]]]] = None
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except IOError:
            blob = b""  # ocean and unbuilt tiles simply have no file
        if len(blob) >= _MAP_HEADER.size:
            fields = _MAP_HEADER.unpack_from(blob, 0)
            if fields[0] != MAP_MAGIC or fields[1] != MAP_VERSION_MAGIC:
                self.bad_files.append(path)
            else:
                off = fields[2]  # areaMapOffset
                if off and len(blob) >= off + _AREA_HEADER.size:
                    fourcc, flags, grid_area = _AREA_HEADER.unpack_from(blob, off)
                    if fourcc != MAP_AREA_MAGIC:
                        self.bad_files.append(path)
                    elif flags & MAP_AREA_NO_AREA:
                        grid = (grid_area, None)
                    elif len(blob) >= off + _AREA_HEADER.size + _AREA_CELLS.size:
                        cells = _AREA_CELLS.unpack_from(
                            blob, off + _AREA_HEADER.size)
                        grid = (grid_area, cells)
                    else:
                        self.bad_files.append(path)
        self._grids[key] = grid
        return grid

    def explore_flag(self, map_id: int, wx: float, wy: float) -> int:
        """AreaTable.exploreFlag under this point, or 0 if the grid has none."""
        gx = 32.0 - wx / SIZE_OF_GRIDS
        gy = 32.0 - wy / SIZE_OF_GRIDS
        if not (0.0 <= gx < 64.0 and 0.0 <= gy < 64.0):
            return 0
        grid = self._grid(map_id, int(gx), int(gy))
        if grid is None:
            return 0
        flat, cells = grid
        if cells is None:
            return flat
        return cells[(int(16.0 * gx) & 15) * 16 + (int(16.0 * gy) & 15)]

    def zone(self, map_id: int, wx: float, wy: float, areas: MapAreas) -> int:
        """The mappable zone the terrain says owns this point, or 0."""
        flag = self.explore_flag(map_id, wx, wy)
        if not flag:
            return 0  # cell never assigned an area; the box rule still gets a say
        area = areas.area_by_flag.get((map_id, flag), 0)
        if not area:
            return 0
        return areas.zone_of_area(area)


Hit = Optional[Tuple[int, float, float]]


def locate_points(world: Sequence[Tuple[float, float, float]], map_id: int,
                  areas: MapAreas, terrain: Optional[TerrainAreas],
                  moves: Optional[Dict[Tuple[int, int], int]] = None
                  ) -> Tuple[List[Hit], int, int]:
    """Zone-locate every point of one polyline, terrain first, boxes second.

    The box rule runs for every point regardless, because the answer still has
    to be expressed in some zone's map percent and only a box can do that. What
    the terrain decides is WHICH zone gets to do the projecting:

      * terrain names a zone and that zone's box covers the point -> terrain
        wins, and the point is projected into that zone's percent space;
      * terrain names a zone whose box does NOT reach the point -> the box rule
        keeps it. This is the honest edge: a WorldMapArea box can be slightly
        tighter than the terrain it describes, and a percent outside 0..100 is
        not a coordinate the addon can draw. Counted as `stranded`.
      * terrain says nothing (unbuilt tile, unassigned cell) -> box rule.

    Returns (hits, points the terrain moved, points stranded off their box).
    `moves`, if given, tallies (box zone -> terrain zone) so the generator can
    show which overlaps the arbiter is actually correcting.
    """
    hits: List[Hit] = []
    moved = stranded = 0
    for wx, wy, _z in world:
        box_hit = areas.locate(map_id, wx, wy)
        if terrain is None:
            hits.append(box_hit)
            continue
        gz = terrain.zone(map_id, wx, wy, areas)
        if not gz or (box_hit is not None and box_hit[0] == gz):
            hits.append(box_hit)
            continue
        pct = areas.project(gz, wx, wy)
        if pct is None:
            if box_hit is not None:
                stranded += 1
            hits.append(box_hit)
            continue
        hits.append((gz, pct[0], pct[1]))
        moved += 1
        if moves is not None:
            key = (box_hit[0] if box_hit else 0, gz)
            moves[key] = moves.get(key, 0) + 1
    return hits, moved, stranded


def resurface_capitals(world: Sequence[Tuple[float, float, float]],
                       hits: List[Hit], map_id: int, areas: MapAreas,
                       capitals: Set[int], z_band: float) -> int:
    """Re-file outdoor road out of the capital boxes that overlay it.

    Walks the maximal runs of consecutive points that landed in one capital
    box. A run whose neighbour on the polyline is an outdoor point at
    compatible height is the same road as that neighbour -- the baker followed
    one continuous surface across the box edge -- so every point of the run is
    located again with the capital boxes excluded, which drops it into the
    outdoor zone the box sits in. A polyline that never leaves the box has no
    such neighbour and keeps its city zone.

    Mutates `hits` in place; returns how many points moved.
    """
    if not capitals or z_band < 0.0:
        return 0
    moved = 0
    i, n = 0, len(hits)
    while i < n:
        here = hits[i]
        if here is None or here[0] not in capitals:
            i += 1
            continue
        city = here[0]
        j = i
        while j < n and hits[j] is not None and hits[j][0] == city:
            j += 1
        # Heights of the outdoor points the run is attached to, if any.
        anchors: List[float] = []
        for k in (i - 1, j):
            if 0 <= k < n and hits[k] is not None and hits[k][0] not in capitals:
                anchors.append(world[k][2])
        if anchors and all(
                min(abs(world[k][2] - az) for az in anchors) <= z_band
                for k in range(i, j)):
            parent = areas.capital_parent.get(city, 0)
            for k in range(i, j):
                wx, wy = world[k][0], world[k][1]
                # The zone the city sits in gets first refusal, so the road
                # stays one road instead of being sliced up by whichever
                # neighbour's box happens to clip which end of it.
                pct = areas.project(parent, wx, wy) if parent else None
                if pct is not None:
                    hits[k] = (parent, pct[0], pct[1])
                else:
                    hits[k] = areas.locate(map_id, wx, wy, exclude=capitals)
                moved += 1
        i = j
    return moved


def split_by_zone(world: Sequence[Tuple[float, float, float]], map_id: int,
                  areas: MapAreas, capitals: Optional[Set[int]] = None,
                  z_band: float = CAPITAL_Z_BAND,
                  terrain: Optional[TerrainAreas] = None,
                  moves: Optional[Dict[Tuple[int, int], int]] = None
                  ) -> Tuple[List[Tuple[int, List[Tuple[float, float]]]], int,
                             int, int]:
    """Cut one world polyline into runs of consecutive same-zone points.

    A continent road crosses zone boundaries constantly and the addon's map
    space is per-zone, so a crossing is a segment split, not a long edge into
    another coordinate system. Points with no zone map at all (open sea, the
    handful of unmapped strips between zones) end the current run.

    The capital pass still runs after the terrain arbiter, because it answers a
    question the terrain cannot: it is driven by the polyline's own continuity
    and so it also covers points the grids have no area for.

    Returns (runs, capital re-files, terrain re-files, terrain strandings).
    """
    hits, arbitrated, stranded = locate_points(world, map_id, areas, terrain,
                                               moves)
    moved = resurface_capitals(world, hits, map_id, areas, capitals or set(),
                               z_band)
    runs: List[Tuple[int, List[Tuple[float, float]]]] = []
    zone = 0
    current: List[Tuple[float, float]] = []
    for hit in hits:
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
    return runs, moved, arbitrated, stranded


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
    ap.add_argument("--map-dir", default=None,
                    help="extracted terrain grids (maps/*.map) used to arbitrate"
                         " overlapping zone boxes; defaults to the maps/ dir"
                         " beside --dbc-dir")
    ap.add_argument("--no-terrain", action="store_true",
                    help="skip the terrain arbiter and file points by the"
                         " smallest containing WorldMapArea box alone")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--min-gap", type=float, default=MIN_POINT_GAP,
                    help="minimum spacing between emitted points, in percent")
    ap.add_argument("--bridge-tiers", default=None,
                    help="bridge gap:angle tiers, e.g. 2.5:180,6:40,12:20")
    ap.add_argument("--bridge-budget", type=int, default=BRIDGE_BUDGET,
                    help="max bridges per zone (0 disables bridging)")
    ap.add_argument("--orphan-min", type=int, default=ORPHAN_MIN_NODES,
                    help="drop islands smaller than this many nodes (0 keeps)")
    ap.add_argument("--capital-z-band", type=float, default=CAPITAL_Z_BAND,
                    help="height band, in world units, within which a road run"
                         " inside a capital's map box counts as the outdoor"
                         " road that box overlays (negative disables)")
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
    capitals = areas.capital_zones

    map_dir = args.map_dir
    if map_dir is None:
        map_dir = os.path.join(os.path.dirname(os.path.abspath(args.dbc_dir)),
                               "maps")
    terrain: Optional[TerrainAreas] = None
    if not args.no_terrain:
        terrain = TerrainAreas(map_dir)
        if not terrain.available():
            # Loud, not fatal: the box rule alone still produces a usable file,
            # and the header records that the arbiter did not run.
            print("warn: no terrain grids at %s; falling back to the"
                  " smallest-box rule alone" % map_dir, file=sys.stderr)
            terrain = None

    by_zone: Dict[int, List[List[Tuple[float, float]]]] = {}
    in_segments = in_points = 0
    dropped = 0
    resurfaced = 0
    arbitrated = stranded = 0
    moves: Dict[Tuple[int, int], int] = {}
    for name in ROAD_FILES:
        map_id, segments = load_segments(os.path.join(args.data_dir, name))
        if not segments:
            print("warn: no segments in %s" % name, file=sys.stderr)
        for world in segments:
            in_segments += 1
            in_points += len(world)
            runs, moved, arb, strand = split_by_zone(
                world, map_id, areas, capitals, args.capital_z_band, terrain,
                moves)
            resurfaced += moved
            arbitrated += arb
            stranded += strand
            for zone, pts in runs:
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
    # Which overlaps the arbiter actually corrected, biggest first. Ties break
    # on the zone ids so the header stays byte-identical across runs.
    top_moves = sorted(moves.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    if terrain is None:
        arbiter_lines = [
            "terrain arbiter OFF: zone per point is the smallest containing"
            " WorldMapArea box,",
            "which overlaps its neighbours -- see docs/road-data.md",
        ]
    else:
        arbiter_lines = [
            "zone per point is the terrain's own area id (maps/*.map per-cell"
            " exploreFlag,",
            "walked up the AreaTable parent chain), because outdoor"
            " WorldMapArea boxes",
            "overlap and terrain does not. The arbiter re-filed %d points."
            % arbitrated,
            "Biggest moves (box zone -> terrain zone): %s"
            % (", ".join("%d->%d x%d" % (a, b, n) for (a, b), n in top_moves)
               or "none"),
            "%d points kept the box answer because the terrain's zone has a"
            % stranded,
            "map box that does not reach them; boxes still do every projection",
        ]
    header = [
        "source: tools/data/road_waypoints_{azeroth,kalimdor}.jsonl"
        " (world coords) + WorldMapArea.dbc + maps/*.map area grids",
        "in : %d segments / %d points" % (in_segments, in_points),
        "out: %d segments / %d points across %d zones"
        % (out_segments, out_points, len(by_zone)),
        "points thinned to >= %.1f%% apart; segments split at zone borders"
        % args.min_gap,
        "coords are zone-normalized percent (GetPlayerMapPosition * 100),"
        " flat x,y pairs",
    ] + arbiter_lines + [
        "re-filed %d points out of the %d capital map boxes and into the"
        % (resurfaced, len(capitals)),
        "outdoor zone each box overlays: a baked run that stays within %s"
        % ("%.0f world units" % args.capital_z_band
           if args.capital_z_band >= 0 else "(pass disabled)"),
        "of the surface it crosses into is that surface's road, not the city's",
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
    print("  terrain arbiter     : %s"
          % ("off" if terrain is None else "%d points re-filed, %d stranded"
             % (arbitrated, stranded)))
    if terrain is not None and terrain.bad_files:
        print("  UNREADABLE grids    : %d (e.g. %s)"
              % (len(terrain.bad_files), os.path.basename(terrain.bad_files[0])))
    print("  capital -> outdoors : %d points" % resurfaced)
    print("  bridges added       : %d" % bridges_total)
    print("  orphan points cut   : %d" % orphan_nodes)
    print("  zones 3+ components : %d -> %d" % (frag_before, frag_after))
    print("  mean largest share  : %.1f%% -> %.1f%%"
          % (share_before_sum / nz, share_after_sum / nz))
    print("  size                : %.2f KiB" % (len(text) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
