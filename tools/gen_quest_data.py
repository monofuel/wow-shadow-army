#!/usr/bin/env python3
"""Generate addons/ShadowArmy/QuestData.lua from the VMaNGOS world DB.

The unfair advantage of docs/advisor.md made concrete: vanilla 1.12 ships no
quest markers, but we own the realm, so "where do I go for this objective" is a
join, not crowdsourced guesswork.

Reads (read-only, never writes):
  * world DB via `docker exec <container> mariadb ...` (same shell-out path as
    breadcrumbs/poller.py and system/system_server.nim)
  * WorldMapArea.dbc / AreaTable.dbc from the extracted client data, for the
    world-coords -> zone-normalized-percent conversion the addon needs.

Emits a pure data file (no logic, Lua 5.0 loadable) keyed by quest *title*,
because 1.12's quest log exposes titles and not ids (GetQuestLogTitle).

Deterministic: no timestamps, every collection sorted before emit, so a re-run
against an unchanged DB produces a byte-identical file.

  python3 tools/gen_quest_data.py                       # whole game
  python3 tools/gen_quest_data.py --max-level 20        # scoped
  python3 tools/gen_quest_data.py --zones 85,130,12     # scoped
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import subprocess
import sys
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

# ---------------------------------------------------------------------------
# Coupling isolation: everything version/deployment specific lives here.
# ---------------------------------------------------------------------------

DEFAULT_CONTAINER = os.environ.get(
    "SYSTEM_MYSQL_CONTAINER", "coworld-vmangos-coworld-game-1"
)
DB_USER = "mangos"
DB_PASS = "mangos"
DB_NAME = "mangos"

# mangosd.conf `WowPatch = 10` == 1.12. VMaNGOS is a progression core: template,
# spawn, relation and loot rows all carry patch ranges, so every query filters.
WOW_PATCH = 10

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DBC_DIR = os.path.abspath(
    os.path.join(_REPO, "..", "coworld-vanilla-wow", "local_data",
                 "vmangos-5875-data", "dbc")
)
DEFAULT_OUT = os.path.join(_REPO, "addons", "ShadowArmy", "QuestData.lua")

# Objective spot budget: a cluster summary, not 400 raw spawn rows.
DEFAULT_MAX_SPOTS = 12
# Grid-bucket size in zone-normalized percent; grown until buckets fit budget.
SPOT_BIN_START = 3.0
SPOT_BIN_GROWTH = 1.5
SPOT_BIN_MAX_STEPS = 24
# Guard against pathological loot items dropped by half the game.
MAX_SPAWNS_PER_OBJECTIVE = 4000
MAX_MEDOID_SAMPLE = 256
# "who drops this" names on an item objective: the dominant droppers only.
MAX_SOURCE_NAMES = 4


# ---------------------------------------------------------------------------
# DBC reader (stdlib struct only). 20-byte header then fixed records then the
# string block: 'WDBC', recordCount, fieldCount, recordSize, stringBlockSize.
# ---------------------------------------------------------------------------


class Dbc:
    def __init__(self, path: str) -> None:
        with open(path, "rb") as fh:
            blob = fh.read()
        magic, self.count, self.fields, self.record_size, string_size = struct.unpack(
            "<4siiii", blob[:20]
        )
        if magic != b"WDBC":
            raise ValueError("%s: not a WDBC file" % path)
        body_end = 20 + self.count * self.record_size
        self._body = blob[20:body_end]
        self._strings = blob[body_end:body_end + string_size]
        n = self.record_size // 4
        self._ifmt = struct.Struct("<%di" % n)
        self._ffmt = struct.Struct("<%df" % n)

    def ints(self, i: int) -> Sequence[int]:
        off = i * self.record_size
        return self._ifmt.unpack_from(self._body, off)

    def floats(self, i: int) -> Sequence[float]:
        off = i * self.record_size
        return self._ffmt.unpack_from(self._body, off)

    def string(self, offset: int) -> str:
        if offset <= 0 or offset >= len(self._strings):
            return ""
        end = self._strings.find(b"\0", offset)
        return self._strings[offset:end].decode("utf-8", "replace")


# WorldMapArea.dbc, 8 fields / 32-byte records (verified against this build):
#   0 id  1 mapId  2 areaId  3 areaName(str)  4 locLeft  5 locRight
#   6 locTop  7 locBottom
WMA_ID, WMA_MAP, WMA_AREA, WMA_NAME = 0, 1, 2, 3
WMA_LEFT, WMA_RIGHT, WMA_TOP, WMA_BOTTOM = 4, 5, 6, 7

# AreaTable.dbc, 25 fields / 100-byte records:
#   0 id  1 mapId  2 parentAreaId  3 exploreFlag  4 flags  ...
#   11 areaName(str, enUS)
AT_ID, AT_MAP, AT_PARENT, AT_FLAGS, AT_NAME = 0, 1, 2, 4, 11
# exploreFlag is the id the extracted terrain grids actually store: vmangos'
# .map files hold AreaTable.exploreFlag per cell, and the core resolves it back
# with GetByAreaFlagAndMap(flag, mapId) (src/game/Maps/GridMap.cpp
# TerrainInfo::GetAreaFlag -> TerrainManager::GetAreaIdByAreaFlag). The pair is
# the key because exploreFlag is only unique within one map.
AT_EXPLORE = 3

# AreaTable flag bit that marks a capital city. In this build it partitions the
# 49 zone maps exactly: every outdoor zone is 0x40/0x41, the battlegrounds are
# 0x0, and only Undercity/Stormwind/Ironforge/Orgrimmar/Thunder Bluff/Darnassus
# carry 0x138 (0x100 | 0x20 | 0x10 | 0x8). That makes "is this box a capital?"
# a DBC lookup rather than a hardcoded id list -- see gen_road_data.py, which
# uses it to keep surface roads out of the city boxes that overlay them.
AREA_FLAG_CAPITAL = 0x100


class MapAreas:
    """world (map,x,y) -> (zoneAreaId, mapX%, mapY%).

    Axis convention verified empirically against WorldMapOverlay.dbc — see
    docs/quest-data.md. GetPlayerMapPosition's x runs west->east and its y runs
    north->south, while world X is north-positive and world Y is west-positive,
    so the map axes are the *swapped* pair:

        mapX = (locLeft - worldY) / (locLeft - locRight)
        mapY = (locTop  - worldX) / (locTop  - locBottom)
    """

    def __init__(self, dbc_dir: str) -> None:
        wma = Dbc(os.path.join(dbc_dir, "WorldMapArea.dbc"))
        at = Dbc(os.path.join(dbc_dir, "AreaTable.dbc"))

        self.area_name: Dict[int, str] = {}
        self.area_parent: Dict[int, int] = {}
        self.area_flags: Dict[int, int] = {}
        # (mapId, exploreFlag) -> area id, the lookup the extracted terrain
        # grids need; see AT_EXPLORE. First row wins a tie, which never comes
        # up on the two continents (0 collisions across maps 0 and 1 in this
        # build) -- flag 0 is the "no explore flag" filler and callers must
        # treat it as unknown rather than look it up.
        self.area_by_flag: Dict[Tuple[int, int], int] = {}
        for i in range(at.count):
            v = at.ints(i)
            self.area_name[v[AT_ID]] = at.string(v[AT_NAME])
            self.area_parent[v[AT_ID]] = v[AT_PARENT]
            self.area_flags[v[AT_ID]] = v[AT_FLAGS]
            self.area_by_flag.setdefault((v[AT_MAP], v[AT_EXPLORE]), v[AT_ID])

        # per continent map id -> list of zone boxes, smallest first so the
        # first containing box wins (city maps nest inside their zone's box).
        self.by_map: Dict[int, List[Tuple[float, int, float, float, float, float]]] = {}
        self.zone_ids: Set[int] = set()
        self.zone_map_name: Dict[int, str] = {}
        for i in range(wma.count):
            v, f = wma.ints(i), wma.floats(i)
            area = v[WMA_AREA]
            if area == 0:
                continue  # continent overview map; we always want a zone map
            left, right = f[WMA_LEFT], f[WMA_RIGHT]
            top, bottom = f[WMA_TOP], f[WMA_BOTTOM]
            if left == right or top == bottom:
                continue
            size = abs(top - bottom) * abs(left - right)
            self.by_map.setdefault(v[WMA_MAP], []).append(
                (size, area, left, right, top, bottom)
            )
            self.zone_ids.add(area)
            self.zone_map_name[area] = wma.string(v[WMA_NAME])
        for boxes in self.by_map.values():
            boxes.sort(key=lambda b: (b[0], b[1]))

        # The zone maps that are capital cities. Their boxes nest inside an
        # outdoor zone's box and overlay open ground, so the smallest-box rule
        # hands them roads that belong to the zone above/around them.
        self.capital_zones: Set[int] = set(
            z for z in self.zone_ids
            if self.area_flags.get(z, 0) & AREA_FLAG_CAPITAL
        )

        # The outdoor zone a capital sits in: the smallest non-capital box that
        # FULLY contains the capital's box. Full containment, not "contains the
        # point", is what makes this the zone a player walks out of the gates
        # into -- a neighbouring zone whose box merely clips the city corner
        # (Silverpine and Western Plaguelands both clip Undercity's) would win
        # a smallest-box contest over half the city's ground and cut the
        # surface road in three. Orgrimmar has no such parent: its box runs
        # north past Durotar's, so it falls back to the plain box rule.
        self.box: Dict[int, Tuple[float, float, float, float]] = {}
        self.capital_parent: Dict[int, int] = {}
        for boxes in self.by_map.values():
            for size, area, left, right, top, bottom in boxes:
                self.box[area] = (left, right, top, bottom)
        for boxes in self.by_map.values():
            for size, area, left, right, top, bottom in boxes:
                if area not in self.capital_zones:
                    continue
                lo_y, hi_y = min(left, right), max(left, right)
                lo_x, hi_x = min(top, bottom), max(top, bottom)
                for osize, oarea, oleft, oright, otop, obottom in boxes:
                    if oarea == area or oarea in self.capital_zones:
                        continue
                    if (min(oleft, oright) <= lo_y and hi_y <= max(oleft, oright)
                            and min(otop, obottom) <= lo_x
                            and hi_x <= max(otop, obottom)):
                        self.capital_parent[area] = oarea  # boxes are size-sorted
                        break

    def project(self, area: int, wx: float, wy: float
                ) -> Optional[Tuple[float, float]]:
        """world -> this zone map's percent, or None if the box misses it."""
        box = self.box.get(area)
        if box is None:
            return None
        left, right, top, bottom = box
        mx = (left - wy) / (left - right) * 100.0
        my = (top - wx) / (top - bottom) * 100.0
        if 0.0 <= mx <= 100.0 and 0.0 <= my <= 100.0:
            return mx, my
        return None

    def zone_of_area(self, area_id: int) -> int:
        """AreaTable id -> the zone above it that owns a world map, or 0.

        Sub-areas (154 Deathknell, 159 Brill) carry the parent zone in
        AreaTable.parentAreaId; a row whose parent is 0 already is a zone. Walk
        up until a mappable zone appears, because not every level of the chain
        has a WorldMapArea row.
        """
        area = area_id
        seen: Set[int] = set()
        while area > 0 and area not in seen:
            if area in self.zone_ids:
                return area
            seen.add(area)
            area = self.area_parent.get(area, 0)
        return 0

    def zone_of_sort(self, zone_or_sort: int) -> int:
        """quest_template.ZoneOrSort -> a zone that has a world map.

        Positive values are AreaTable ids, but they are sometimes sub-areas
        (quest 363 "Rude Awakening" sorts to 154 Deathknell, not 85 Tirisfal),
        so walk up parents. Negative values are sort buckets
        (class/profession/dungeon) and have no zone at all -- the walk rejects
        them because it only follows positive ids.
        """
        return self.zone_of_area(zone_or_sort)

    def locate(self, map_id: int, wx: float, wy: float,
               prefer_zone: int = 0,
               exclude: Optional[Set[int]] = None
               ) -> Optional[Tuple[int, float, float]]:
        """Smallest containing box wins. `exclude` drops boxes from the search
        entirely, which is how gen_road_data re-files a surface road out of the
        capital box that overlays it and into the outdoor zone underneath.
        """
        boxes = self.by_map.get(map_id)
        if not boxes:
            return None  # instanced maps have no WorldMapArea row in 1.12

        def norm(box) -> Tuple[int, float, float]:
            _, area, left, right, top, bottom = box
            mx = (left - wy) / (left - right) * 100.0
            my = (top - wx) / (top - bottom) * 100.0
            return area, mx, my

        hit = None
        for box in boxes:
            if exclude and box[1] in exclude:
                continue
            area, mx, my = norm(box)
            if 0.0 <= mx <= 100.0 and 0.0 <= my <= 100.0:
                # The bbox test cannot tell the Ruins of Lordaeron (surface,
                # Tirisfal) from Undercity (below it), so an explicit zone hint
                # from the quest wins whenever it also contains the point.
                if area == prefer_zone:
                    return area, mx, my
                if hit is None:
                    hit = (area, mx, my)
        return hit


# ---------------------------------------------------------------------------
# DB access (docker exec mariadb -N -B, TSV out)
# ---------------------------------------------------------------------------


_UNESCAPE = {"0": "\0", "b": "\b", "n": "\n", "r": "\r", "t": "\t",
             "Z": "\x1a", "\\": "\\"}


def _unescape(text: str) -> str:
    if "\\" not in text:
        return text
    out: List[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            out.append(_UNESCAPE.get(text[i + 1], text[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


class World:
    def __init__(self, container: str) -> None:
        self.container = container

    def query(self, sql: str) -> List[List[str]]:
        cmd = ["docker", "exec", self.container, "mariadb",
               "-u" + DB_USER, "-p" + DB_PASS, DB_NAME, "-N", "-B", "-e", sql]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError("query failed: %s\n%s" % (sql[:120], proc.stderr.strip()))
        rows = []
        for line in proc.stdout.split("\n"):
            if not line:
                continue
            rows.append([_unescape(c) for c in line.split("\t")])
        return rows


def _i(text: str) -> int:
    return 0 if text in ("", "NULL") else int(float(text))


def _f(text: str) -> float:
    return 0.0 if text in ("", "NULL") else float(text)


# ---------------------------------------------------------------------------
# Spawn indexes
# ---------------------------------------------------------------------------

Spawn = Tuple[int, float, float]  # (map, world x, world y)


def load_creature_spawns(db: World) -> Dict[int, List[Spawn]]:
    """entry -> spawns. `creature` rows may hold up to five ids (spawn pools:
    the server rolls one of id..id5 per respawn), so every id gets the point."""
    rows = db.query(
        "SELECT id,id2,id3,id4,id5,map,position_x,position_y FROM creature "
        "WHERE patch_min<=%d AND patch_max>=%d" % (WOW_PATCH, WOW_PATCH)
    )
    out: Dict[int, List[Spawn]] = {}
    for r in rows:
        if len(r) < 8:
            continue
        point = (_i(r[5]), _f(r[6]), _f(r[7]))
        for col in r[:5]:
            entry = _i(col)
            if entry > 0:
                out.setdefault(entry, []).append(point)
    return out


def load_gameobject_spawns(db: World) -> Dict[int, List[Spawn]]:
    rows = db.query(
        "SELECT id,map,position_x,position_y FROM gameobject "
        "WHERE patch_min<=%d AND patch_max>=%d" % (WOW_PATCH, WOW_PATCH)
    )
    out: Dict[int, List[Spawn]] = {}
    for r in rows:
        if len(r) < 4:
            continue
        entry = _i(r[0])
        if entry > 0:
            out.setdefault(entry, []).append((_i(r[1]), _f(r[2]), _f(r[3])))
    return out


def load_template(db: World, table: str, columns: str) -> Dict[int, List[str]]:
    """Templates carry one row per content patch; the highest patch <= 10 wins."""
    rows = db.query(
        "SELECT entry,%s FROM %s WHERE patch<=%d ORDER BY entry,patch"
        % (columns, table, WOW_PATCH)
    )
    out: Dict[int, List[str]] = {}
    for r in rows:
        if len(r) >= 2:
            out[_i(r[0])] = r[1:]
    return out


# gameobject_template.data1 is the loot id for these types (mangos GO defs).
GO_LOOT_TYPES = (3, 25)  # CHEST, FISHINGHOLE


def load_item_sources(db: World,
                      creature_loot_ids: Dict[int, List[str]],
                      go_templates: Dict[int, List[str]]
                      ) -> Dict[int, List[Tuple[str, int]]]:
    """item id -> [("mob"|"object", entry)] that can drop/contain it.

    Two indirections have to be honoured or the join silently returns almost
    nothing:

    * Loot templates are keyed by a *loot id*, not by the spawnable entry.
      For creatures that is creature_template.loot_id / skinning_loot_id /
      pickpocket_loot_id (usually == entry, but 0 for half the table and
      genuinely different for a few). For gameobjects it is
      gameobject_template.data1, which matches the object entry for only 14 of
      562 loot ids — joining on entry there loses every chest in the game.
    * Rows with mincountOrRef < 0 are references into reference_loot_template
      (entry = -mincountOrRef), which can nest, so those are flattened first.
    """
    patch = " WHERE patch_min<=%d AND patch_max>=%d" % (WOW_PATCH, WOW_PATCH)

    # loot id -> spawnable entries, per loot table
    creature_by_loot: Dict[str, Dict[int, List[int]]] = {
        "creature_loot_template": {},
        "skinning_loot_template": {},
        "pickpocketing_loot_template": {},
    }
    loot_columns = ("creature_loot_template", "skinning_loot_template",
                    "pickpocketing_loot_template")
    for entry, cols in creature_loot_ids.items():
        for table, cell in zip(loot_columns, cols):
            loot_id = _i(cell)
            if loot_id:
                creature_by_loot[table].setdefault(loot_id, []).append(entry)

    go_by_loot: Dict[int, List[int]] = {}
    for entry, cols in go_templates.items():
        if _i(cols[0]) in GO_LOOT_TYPES:
            loot_id = _i(cols[1])
            if loot_id:
                go_by_loot.setdefault(loot_id, []).append(entry)

    ref_direct: Dict[int, Set[int]] = {}
    ref_links: Dict[int, Set[int]] = {}
    for r in db.query("SELECT entry,item,mincountOrRef FROM reference_loot_template" + patch):
        entry, item, ref = _i(r[0]), _i(r[1]), _i(r[2])
        if ref < 0:
            ref_links.setdefault(entry, set()).add(-ref)
        elif item > 0:
            ref_direct.setdefault(entry, set()).add(item)

    resolved: Dict[int, Set[int]] = {}

    def expand(entry: int, stack: Set[int]) -> Set[int]:
        if entry in resolved:
            return resolved[entry]
        if entry in stack:
            return set()
        stack.add(entry)
        items = set(ref_direct.get(entry, ()))
        for child in ref_links.get(entry, ()):
            items |= expand(child, stack)
        stack.discard(entry)
        resolved[entry] = items
        return items

    for entry in list(ref_direct) + list(ref_links):
        expand(entry, set())

    out: Dict[int, Set[Tuple[str, int]]] = {}
    tables = [(t, "mob", creature_by_loot[t]) for t in loot_columns]
    tables.append(("gameobject_loot_template", "object", go_by_loot))
    for table, kind, owners in tables:
        for r in db.query("SELECT entry,item,mincountOrRef FROM %s%s" % (table, patch)):
            loot_id, item, ref = _i(r[0]), _i(r[1]), _i(r[2])
            entries = owners.get(loot_id)
            if not entries:
                continue
            items = resolved.get(-ref, ()) if ref < 0 else ((item,) if item > 0 else ())
            for got in items:
                bucket = out.setdefault(got, set())
                for entry in entries:
                    bucket.add((kind, entry))
    return {item: sorted(src) for item, src in out.items()}


def load_relation(db: World, table: str) -> Dict[int, List[int]]:
    """quest id -> [entry] for *_questrelation / *_involvedrelation."""
    rows = db.query(
        "SELECT DISTINCT id,quest FROM %s WHERE patch_min<=%d AND patch_max>=%d"
        % (table, WOW_PATCH, WOW_PATCH)
    )
    out: Dict[int, Set[int]] = {}
    for r in rows:
        if len(r) >= 2:
            out.setdefault(_i(r[1]), set()).add(_i(r[0]))
    return {q: sorted(v) for q, v in out.items()}


# ---------------------------------------------------------------------------
# Spot selection
# ---------------------------------------------------------------------------

Point = Tuple[int, float, float]  # (zone, mapX%, mapY%)


def to_points(spawns: Iterable[Spawn], areas: MapAreas, prefer_zone: int) -> List[Point]:
    pts: List[Point] = []
    for map_id, wx, wy in spawns:
        got = areas.locate(map_id, wx, wy, prefer_zone)
        if got is not None:
            pts.append(got)
    return pts


def dominant_zone(points: Sequence[Point], prefer_zone: int) -> List[Point]:
    """Keep one zone's worth of spots: the densest cluster, quest zone breaking
    ties. A HUD arrow wants one place to go, not a scatter across continents."""
    if not points:
        return []
    counts: Dict[int, int] = {}
    for zone, _, _ in points:
        counts[zone] = counts.get(zone, 0) + 1
    best = max(counts, key=lambda z: (counts[z], z == prefer_zone, -z))
    return [p for p in points if p[0] == best]


def _medoid(points: Sequence[Point]) -> Point:
    """A real spawn location near the middle of the cluster (never a centroid
    in the middle of a lake)."""
    sample = list(points)
    if len(sample) > MAX_MEDOID_SAMPLE:
        step = len(sample) / float(MAX_MEDOID_SAMPLE)
        sample = [sample[int(i * step)] for i in range(MAX_MEDOID_SAMPLE)]
    cx = sum(p[1] for p in sample) / len(sample)
    cy = sum(p[2] for p in sample) / len(sample)
    return min(sample, key=lambda p: ((p[1] - cx) ** 2 + (p[2] - cy) ** 2, p[1], p[2]))


def pick_spots(points: Sequence[Point], max_spots: int) -> List[Point]:
    """Grid-bucket in normalized percent, grow the bin until the bucket count
    fits the budget, then emit one real spawn per bucket."""
    if not points:
        return []
    pts = list(points)
    if len(pts) > MAX_SPAWNS_PER_OBJECTIVE:
        pts.sort()
        step = len(pts) / float(MAX_SPAWNS_PER_OBJECTIVE)
        pts = [pts[int(i * step)] for i in range(MAX_SPAWNS_PER_OBJECTIVE)]

    bin_size = SPOT_BIN_START
    buckets: Dict[Tuple[int, int, int], List[Point]] = {}
    for _ in range(SPOT_BIN_MAX_STEPS):
        buckets = {}
        for p in pts:
            key = (p[0], int(math.floor(p[1] / bin_size)), int(math.floor(p[2] / bin_size)))
            buckets.setdefault(key, []).append(p)
        if len(buckets) <= max_spots:
            break
        bin_size *= SPOT_BIN_GROWTH

    ranked = sorted(buckets.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:max_spots]
    spots = [_medoid(group) for _, group in ranked]
    return sorted(set(spots), key=lambda p: (p[0], round(p[2], 1), round(p[1], 1)))


def single_spot(points: Sequence[Point], prefer_zone: int) -> Optional[Point]:
    kept = dominant_zone(points, prefer_zone)
    return _medoid(kept) if kept else None


# ---------------------------------------------------------------------------
# Quest assembly
# ---------------------------------------------------------------------------

QUEST_COLUMNS = (
    ["entry", "Title", "QuestLevel", "MinLevel", "ZoneOrSort", "SrcItemId",
     "RequiredRaces", "RequiredClasses"]
    + ["ReqCreatureOrGOId%d" % i for i in (1, 2, 3, 4)]
    + ["ReqCreatureOrGOCount%d" % i for i in (1, 2, 3, 4)]
    + ["ReqItemId%d" % i for i in (1, 2, 3, 4)]
    + ["ReqItemCount%d" % i for i in (1, 2, 3, 4)]
)


class Generator:
    def __init__(self, db: World, areas: MapAreas, max_spots: int) -> None:
        self.db = db
        self.areas = areas
        self.max_spots = max_spots
        self.creature_spawns = load_creature_spawns(db)
        self.go_spawns = load_gameobject_spawns(db)
        creatures = load_template(
            db, "creature_template",
            "name,loot_id,skinning_loot_id,pickpocket_loot_id")
        gameobjects = load_template(db, "gameobject_template", "name,type,data1")
        self.creature_names = {e: c[0] for e, c in creatures.items()}
        self.go_names = {e: c[0] for e, c in gameobjects.items()}
        self.item_names = {e: c[0] for e, c
                           in load_template(db, "item_template", "name").items()}
        self.item_sources = load_item_sources(
            db,
            {e: c[1:] for e, c in creatures.items()},
            {e: c[1:] for e, c in gameobjects.items()},
        )
        self.starters_c = load_relation(db, "creature_questrelation")
        self.starters_g = load_relation(db, "gameobject_questrelation")
        self.enders_c = load_relation(db, "creature_involvedrelation")
        self.enders_g = load_relation(db, "gameobject_involvedrelation")

    # -- lookups ----------------------------------------------------------
    def spawns_of(self, kind: str, entry: int) -> List[Spawn]:
        table = self.creature_spawns if kind == "mob" else self.go_spawns
        return table.get(entry, [])

    def name_of(self, kind: str, entry: int) -> str:
        table = self.creature_names if kind == "mob" else self.go_names
        return table.get(entry, "")

    def npc_spot(self, kind: str, entries: Sequence[int],
                 zone: int) -> Optional[Dict[str, object]]:
        """Best locatable questgiver/turn-in among the relation's entries."""
        best = None
        for entry in entries:
            pts = to_points(self.spawns_of(kind, entry), self.areas, zone)
            if not pts:
                continue
            spot = single_spot(pts, zone)
            if spot is None:
                continue
            # prefer an NPC standing in the quest's own zone
            rank = (0 if spot[0] == zone else 1, entry)
            if best is None or rank < best[0]:
                best = (rank, {"label": self.name_of(kind, entry) or "#%d" % entry,
                               "zone": spot[0], "x": spot[1], "y": spot[2]})
        return best[1] if best else None

    # -- objectives -------------------------------------------------------
    def objectives(self, q: Dict[str, int], zone: int) -> List[Dict[str, object]]:
        out: List[Dict[str, object]] = []
        for i in (1, 2, 3, 4):
            raw = q["ReqCreatureOrGOId%d" % i]
            if raw:
                kind = "mob" if raw > 0 else "object"
                entry = abs(raw)
                pts = dominant_zone(
                    to_points(self.spawns_of(kind, entry), self.areas, zone), zone)
                spots = pick_spots(pts, self.max_spots)
                if spots:
                    out.append({"label": self.name_of(kind, entry) or "#%d" % entry,
                                "kind": kind,
                                "count": q["ReqCreatureOrGOCount%d" % i] or 1,
                                "spots": spots})
        for i in (1, 2, 3, 4):
            item = q["ReqItemId%d" % i]
            if not item or item == q["SrcItemId"]:
                continue  # SrcItem is handed over on accept — nothing to hunt
            sources = self.item_sources.get(item, [])
            if not sources:
                continue
            all_pts: List[Point] = []
            source_pts: Dict[str, List[Point]] = {}
            kinds: Set[str] = set()
            for kind, entry in sources:
                got = self.spawns_of(kind, entry)
                if not got:
                    continue
                kinds.add(kind)
                got_pts = to_points(got, self.areas, zone)
                all_pts.extend(got_pts)
                name = self.name_of(kind, entry)
                if name and got_pts:
                    source_pts.setdefault(name, []).extend(got_pts)
            pts = dominant_zone(all_pts, zone)
            spots = pick_spots(pts, self.max_spots)
            if spots:
                label = self.item_names.get(item, "#%d" % item)
                obj: Dict[str, object] = {
                    "label": label,
                    "kind": "object" if kinds == {"object"} else "item",
                    "count": q["ReqItemCount%d" % i] or 1,
                    "spots": spots,
                }
                names = self.source_names(source_pts, pts[0][0])
                # the label already names the source when there is only one;
                # no point repeating "Darkhound Blood" as its own hunting hint.
                if names and names != [label]:
                    obj["from"] = names
                out.append(obj)
        return out

    @staticmethod
    def source_names(source_pts: Dict[str, List[Point]], kept_zone: int) -> List[str]:
        """Who to hunt for an item objective: the templates that actually put
        spawns in the zone the spots came from, dominant droppers first, capped
        so a HUD line stays readable. Emitted alphabetically for a stable file."""
        counts: Dict[str, int] = {}
        for name, points in source_pts.items():
            hits = sum(1 for p in points if p[0] == kept_zone)
            if hits:
                counts[name] = hits
        top = sorted(counts, key=lambda n: (-counts[n], n))[:MAX_SOURCE_NAMES]
        return sorted(top)

    def build(self, q: Dict[str, int]) -> Optional[Dict[str, object]]:
        zone = self.areas.zone_of_sort(q["ZoneOrSort"])
        entry = q["entry"]
        turn_in = (self.npc_spot("mob", self.enders_c.get(entry, []), zone)
                   or self.npc_spot("object", self.enders_g.get(entry, []), zone))
        started_by = (self.npc_spot("mob", self.starters_c.get(entry, []), zone)
                      or self.npc_spot("object", self.starters_g.get(entry, []), zone))
        objectives = self.objectives(q, zone)
        if not objectives and not turn_in and not started_by:
            return None
        if not zone:
            # class/profession/dungeon sort buckets have no zone of their own;
            # borrow one from the turn-in, then the starter, then the first
            # objective, so the addon always has a map it can open.
            for anchor in (turn_in, started_by):
                if anchor:
                    zone = int(anchor["zone"])
                    break
            if not zone and objectives:
                zone = int(objectives[0]["spots"][0][0])
        # Who the game will even let hold this quest. The title is all the 1.12
        # quest log exposes, so a resolver that only reads objective labels
        # cannot tell eight identical capital-city donation quests apart -- but
        # the game already picked one for the player, and these two masks say
        # which (ticket 0045). 0 means "anyone" in the DB and is omitted rather
        # than emitted as a mask that matches nothing.
        return {"id": entry, "level": q["QuestLevel"], "minLevel": q["MinLevel"],
                "zone": zone, "objectives": objectives,
                "races": q["RequiredRaces"], "classes": q["RequiredClasses"],
                "turnIn": turn_in, "startedBy": started_by}


# ---------------------------------------------------------------------------
# Lua emit
# ---------------------------------------------------------------------------


def lua_string(text: str) -> str:
    out = ['"']
    for ch in text:
        if ch in ('"', "\\"):
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 32:
            out.append("\\%d" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def fmt(value: float) -> str:
    return "%.1f" % value


def emit(entries: List[Tuple[str, Dict[str, object]]], header: List[str],
         zone_names: Dict[int, str]) -> str:
    lines = ["-- generated by tools/gen_quest_data.py; do not edit by hand"]
    lines += ["-- " + line for line in header]
    lines.append("")
    # Zone-id -> zone NAME bridge. 1.12 gives addons zone names
    # (GetZoneText/GetRealZoneText) and world-map dropdown indices, never
    # AreaTable ids, and no API converts between them. These strings come
    # straight out of AreaTable.dbc in the same client build the player runs,
    # so they are exactly what GetRealZoneText() returns — no hand-written
    # table to drift.
    lines.append("ShadowArmyQuestZones = {")
    for zone in sorted(zone_names):
        lines.append("[%d] = %s," % (zone, lua_string(zone_names[zone])))
    lines.append("}")
    lines.append("")
    def quest_body(q: Dict[str, object]) -> None:
        lines.append("id = %d, level = %d, minLevel = %d, zone = %d,"
                     % (q["id"], q["level"], q["minLevel"], q["zone"]))
        # Identity gates, omitted when the quest has none (the common case).
        gates = ["%s = %d" % (key, q.get(key) or 0)
                 for key in ("races", "classes") if q.get(key)]
        if gates:
            lines.append(", ".join(gates) + ",")
        objectives = q["objectives"]
        if objectives:
            lines.append("objectives = {")
            for obj in objectives:
                spots = ", ".join(
                    "{zone = %d, x = %s, y = %s}" % (z, fmt(x), fmt(y))
                    for z, x, y in obj["spots"])
                # `from` is not a Lua keyword, so it is a safe table key.
                sources = obj.get("from")
                origin = ""
                if sources:
                    origin = "from = { %s }, " % ", ".join(
                        lua_string(name) for name in sources)
                lines.append(
                    "{ label = %s, kind = %s, count = %d, %sspots = { %s } },"
                    % (lua_string(obj["label"]), lua_string(obj["kind"]),
                       obj["count"], origin, spots))
            lines.append("},")
        for key in ("turnIn", "startedBy"):
            spot = q[key]
            if spot:
                lines.append("%s = { label = %s, zone = %d, x = %s, y = %s },"
                             % (key, lua_string(spot["label"]), spot["zone"],
                                fmt(spot["x"]), fmt(spot["y"])))
    lines.append("ShadowArmyQuestData = {")
    for title, q in entries:
        lines.append("[%s] = {" % lua_string(title))
        quest_body(q)
        alts = q.get("alts")
        if alts:
            lines.append("alts = {")
            for alt in alts:
                lines.append("{")
                quest_body(alt)
                lines.append("},")
            lines.append("},")
        lines.append("},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--container", default=DEFAULT_CONTAINER)
    ap.add_argument("--dbc-dir", default=DEFAULT_DBC_DIR)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--zones", default="",
                    help="comma-separated AreaTable zone ids to keep (default: all)")
    ap.add_argument("--max-level", type=int, default=0,
                    help="keep quests with QuestLevel <= N (default: all)")
    ap.add_argument("--max-spots", type=int, default=DEFAULT_MAX_SPOTS)
    args = ap.parse_args(argv)

    if not os.path.isdir(args.dbc_dir):
        print("error: dbc dir missing: %s" % args.dbc_dir, file=sys.stderr)
        return 1

    zone_filter = {int(z) for z in args.zones.replace(",", " ").split() if z.strip()}
    areas = MapAreas(args.dbc_dir)
    db = World(args.container)

    # quest_template is patched like every other template table: one row per
    # content patch, so 4433 quests arrive as 4727 rows. ORDER BY entry,patch
    # and keying on entry collapses each quest to its highest patch <= 10 --
    # the same rule (and the same reason) as load_template above. Without the
    # collapse a patched quest is two separate quests all the way through:
    # usually they share a Title, land in one title-collision group, and the
    # quest lists itself twice in its own `alts` (35 of 590 alts blocks). Worse
    # for the 12 entries whose Title CHANGES between patches, because VMaNGOS
    # reuses a retired quest's entry id -- 171 is "Four-legged Menaces" at
    # patch 0 and "A Warden of the Alliance" at patch 8, and only the latter
    # exists on a WowPatch 10 realm. Taking every row advertised both.
    rows = db.query(
        "SELECT %s FROM quest_template WHERE patch<=%d ORDER BY entry,patch"
        % (",".join(QUEST_COLUMNS), WOW_PATCH))
    by_entry: Dict[int, Dict[str, int]] = {}
    for r in rows:
        if len(r) < len(QUEST_COLUMNS):
            continue
        q: Dict[str, int] = {}
        for name, cell in zip(QUEST_COLUMNS, r):
            q[name] = cell if name == "Title" else _i(cell)
        by_entry[q["entry"]] = q
    # Sorted by entry so the emit order does not depend on dict insertion,
    # matching the ORDER BY the old query relied on.
    quests: List[Dict[str, int]] = [by_entry[e] for e in sorted(by_entry)]

    gen = Generator(db, areas, args.max_spots)

    built: Dict[str, List[Tuple[Tuple[int, int, int], Dict[str, object]]]] = {}
    total = len(quests)
    kept_scope = 0
    usable = 0
    collisions = 0
    for q in quests:
        if args.max_level and q["QuestLevel"] > args.max_level:
            continue  # QuestLevel <= 0 means "scales"; those always stay
        if zone_filter and areas.zone_of_sort(q["ZoneOrSort"]) not in zone_filter:
            continue
        kept_scope += 1
        data = gen.build(q)
        if data is None:
            continue
        usable += 1
        title = q["Title"]
        # 1.12's quest log gives titles, not ids: on a title collision the
        # lower-level quest (the one a fresh character meets first) is the
        # primary entry and every other variant rides along in `alts`, so the
        # addon can pick by live objective labels (chains like Fields of
        # Grief reuse one title for consecutive quests at the same level).
        rank = (q["QuestLevel"] if q["QuestLevel"] > 0 else 999,
                q["MinLevel"], q["entry"])
        if title in built:
            collisions += 1
        built.setdefault(title, []).append((rank, data))

    entries = []
    for title, variants in built.items():
        variants.sort(key=lambda rd: rd[0])
        primary = variants[0][1]
        if len(variants) > 1:
            primary["alts"] = [d for _, d in variants[1:]]
        entries.append((title, primary))
    entries.sort(key=lambda kv: kv[0])

    scope = "whole game"
    if zone_filter or args.max_level:
        bits = []
        if args.max_level:
            bits.append("QuestLevel <= %d" % args.max_level)
        if zone_filter:
            bits.append("zones " + ",".join(str(z) for z in sorted(zone_filter)))
        scope = " and ".join(bits)
    header = [
        "source: VMaNGOS world DB (%s) + WorldMapArea.dbc, WowPatch %d"
        % (DB_NAME, WOW_PATCH),
        "scope: %s" % scope,
        "quest_template rows %d, in scope %d, locatable %d, emitted %d"
        % (total, kept_scope, usable, len(entries)),
        "title collisions: %d (lower-level quest primary, other variants in alts)"
        % collisions,
        "coords are zone-normalized percent (GetPlayerMapPosition * 100)",
        "regenerate: make quest-data   (see docs/quest-data.md)",
    ]

    # Only zones actually referenced by emitted waypoints, named from
    # AreaTable.dbc (see emit's comment on why the addon needs this bridge).
    # Spots are (zone, x, y) Point tuples; turnIn/startedBy are dicts.
    zone_names: Dict[int, str] = {}

    def note_zone(z: int) -> None:
        if z and z in areas.area_name:
            zone_names[z] = areas.area_name[z]

    for _, data in entries:
        note_zone(int(data.get("zone", 0)))  # type: ignore[arg-type]
        for obj in data.get("objectives", ()):  # type: ignore[union-attr]
            for spot in obj["spots"]:
                note_zone(spot[0])
        for key in ("turnIn", "startedBy"):
            loc = data.get(key)
            if loc:
                note_zone(int(loc["zone"]))  # type: ignore[index]

    text = emit(entries, header, zone_names)
    with open(args.out, "w") as fh:
        fh.write(text)

    print("wrote %s" % args.out)
    print("  quest_template rows : %d" % total)
    print("  in scope            : %d" % kept_scope)
    print("  locatable           : %d" % usable)
    print("  emitted (unique)    : %d" % len(entries))
    print("  title collisions    : %d" % collisions)
    print("  size                : %.2f MiB" % (len(text) / 1048576.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
