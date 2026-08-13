#!/usr/bin/env python3
"""Bake painted-road masks into a curated-forever JSONL waypoint artifact.

Centerlines are extracted from a global world-aligned lattice over ADT road
paint, then merged with any existing hand-curated lines. Output is
deterministic: no timestamps, stable ids assigned after sort.
"""
from __future__ import annotations

import argparse
import heapq
import json
import math
import sys
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

import minimap_mask as mmask
import road_mask as rmask

Cell = tuple[int, int]
Point = tuple[float, float, float]

MAP_IDS = {"kalimdor": 1, "azeroth": 0}
GENERATOR = "tools/bake_road_waypoints.py"
ERASE_YD = 6.0
MAX_SNAP_YD = 20.0
CORRIDOR_OUTSIDE_MAX_PCT = 5.0
NEIGH8 = tuple(
    (di, dj)
    for di in (-1, 0, 1)
    for dj in (-1, 0, 1)
    if not (di == 0 and dj == 0)
)
# Zones whose painted ADT signature is useless: route least-cost paths
# between known anchors over minimap local brightness + walkability.
# Constants are session-calibrated; do not "improve" them.
MINIMAP_ROUTE_ZONES = {
    "kalimdor": [
        {
            "name": "thousand_needles",
            # bbox ALIGNED to STEP multiples (lattice keys are global
            # integer indices; a misaligned bbox once caused
            # banker's-rounding key collisions in a prototype)
            "bbox": (-7000.0, -4400.0, -4200.0, -600.0),
            "z_band": (-120.0, 100.0),
            "max_grade_wall": 1.8,
            "slope_penalty": 2.0,
            "contrast_c0": 25.0,
            "contrast_k": 22.0,
            "block_yd": 64.0,
            "max_water_depth": 0.5,
            "legs": [
                ["feralas_junction", (-4280.0, -776.0),      "lift_lower",      (-4677.066, -1853.667), {"z_corridor": (-120.0, -20.0, 10.0)}],
                ["lift_lower",       (-4677.066, -1853.667), "freewind_base",   (-5320.0, -2170.0),     {"z_corridor": (-120.0, -20.0, 10.0)}],
                ["freewind_base",    (-5320.0, -2170.0),     "canyon_se",       (-5560.0, -2050.0),     {"z_corridor": (-120.0, -20.0, 10.0)}],
                # canyon -> basin descent through the verified low-grade gap (seed (-5700,-3130) heading SSW,
                # measured max grade 1.01, z stays within [-55,-20]); corridor hi -10 gives lip margin
                ["canyon_se",        (-5560.0, -2050.0),     "basin_entry",     (-5848.0, -3424.0),     {"z_corridor": (-120.0, -10.0, 10.0)}],
                ["basin_entry",      (-5848.0, -3424.0),     "racetrack_north", (-6100.0, -3500.0),     {"z_corridor": (-120.0, -20.0, 10.0)}],
                ["racetrack_north",  (-6100.0, -3500.0),     "racetrack_mid",   (-6230.0, -3700.0),     {"z_corridor": (-120.0, -20.0, 10.0)}],
                ["racetrack_mid",    (-6230.0, -3700.0),     "racetrack_south", (-6350.0, -3900.0),     {"z_corridor": (-120.0, -20.0, 10.0)}],
                # basin -> Tanaris shelf: measured ramp pinch grade 1.78-1.79 sits AT the 1.8 global wall,
                # so this leg gets its own wall with margin; climbs lawfully to z~86 -> no z corridor
                ["racetrack_south",  (-6350.0, -3900.0),     "tanaris_road",    (-6720.0, -3456.0),     {"max_grade_wall": 2.2}],
            ],
        },
    ],
}

# Frozen clockwise Zhang-Suen ring P2..P9. Orientation-agnostic; do not
# "fix" for world-axis direction.
_ZS_RING = (
    (0, 1),
    (1, 1),
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, -1),
    (-1, 0),
    (-1, 1),
)


def decimate(chain: Sequence[Point], spacing: float) -> list[Point]:
    """Keep points every ``spacing`` yards of planar arclength; always the ends."""
    if len(chain) < 2:
        return list(chain)
    kept: list[Point] = [chain[0]]
    since = 0.0
    for prev, cur in zip(chain, chain[1:]):
        since += math.hypot(cur[0] - prev[0], cur[1] - prev[1])
        if since >= spacing:
            kept.append(cur)
            since = 0.0
    if kept[-1] != chain[-1]:
        kept.append(chain[-1])
    return kept


def connected_components(cell_set: set[Cell]) -> list[set[Cell]]:
    unseen = set(cell_set)
    comps: list[set[Cell]] = []
    while unseen:
        seed = min(unseen)
        comp: set[Cell] = set()
        q: deque[Cell] = deque([seed])
        unseen.remove(seed)
        while q:
            cur = q.popleft()
            comp.add(cur)
            i, j = cur
            for di, dj in NEIGH8:
                nxt = (i + di, j + dj)
                if nxt in unseen:
                    unseen.remove(nxt)
                    q.append(nxt)
        comps.append(comp)
    return comps


def _bfs_farthest(
    start: Cell, cell_set: set[Cell]
) -> tuple[Cell, dict[Cell, Cell | None]]:
    parents: dict[Cell, Cell | None] = {start: None}
    dist = {start: 0}
    q: deque[Cell] = deque([start])
    while q:
        cur = q.popleft()
        i, j = cur
        d = dist[cur]
        for di, dj in NEIGH8:
            nxt = (i + di, j + dj)
            if nxt not in cell_set or nxt in parents:
                continue
            parents[nxt] = cur
            dist[nxt] = d + 1
            q.append(nxt)
    best = start
    best_d = 0
    for cell, d in dist.items():
        if d > best_d or (d == best_d and cell < best):
            best = cell
            best_d = d
    return best, parents


def diameter_path(cell_set: set[Cell]) -> list[Cell]:
    seed = min(cell_set)
    a, _ = _bfs_farthest(seed, cell_set)
    b, parents = _bfs_farthest(a, cell_set)
    path = [b]
    while path[-1] != a:
        parent = parents[path[-1]]
        if parent is None:
            break
        path.append(parent)
    path.reverse()
    return path


def erase_near_path(
    cell_set: set[Cell],
    path: Sequence[Cell],
    step: float,
    radius: float = ERASE_YD,
) -> set[Cell]:
    path_xy = [(i * step, j * step) for i, j in path]
    r2 = radius * radius
    remaining: set[Cell] = set()
    for i, j in cell_set:
        x, y = i * step, j * step
        near = False
        for px, py in path_xy:
            dx = x - px
            dy = y - py
            if dx * dx + dy * dy <= r2:
                near = True
                break
        if not near:
            remaining.add((i, j))
    return remaining


def _zs_deletable(p: Cell, working: set[Cell], phase: int) -> bool:
    i, j = p
    neigh = tuple(1 if (i + di, j + dj) in working else 0 for di, dj in _ZS_RING)
    b = sum(neigh)
    if b < 2 or b > 6:
        return False
    circled = neigh + (neigh[0],)
    a = sum(1 for k in range(8) if circled[k] == 0 and circled[k + 1] == 1)
    if a != 1:
        return False
    p2, _p3, p4, _p5, p6, _p7, p8, _p9 = neigh
    if phase == 1:
        return p2 * p4 * p6 == 0 and p4 * p6 * p8 == 0
    return p2 * p4 * p8 == 0 and p2 * p6 * p8 == 0


def thin_cells(comp: set[Cell]) -> set[Cell]:
    """Zhang-Suen morphological thinning.

    Snapshot semantics: each sub-iteration computes ``to_delete`` against the
    unmodified working set, then subtracts. Never delete mid-scan.

    Clockwise ring P2..P9 is frozen and orientation-agnostic (do not "fix"
    for world-axis direction): P2=(i,j+1), P3=(i+1,j+1), P4=(i+1,j),
    P5=(i+1,j-1), P6=(i,j-1), P7=(i-1,j-1), P8=(i-1,j), P9=(i-1,j+1).
    """
    working = set(comp)
    while True:
        deleted = 0
        for phase in (1, 2):
            to_delete = {p for p in working if _zs_deletable(p, working, phase)}
            working -= to_delete
            deleted += len(to_delete)
        if deleted == 0:
            break
    return working


def _cell_path_length(path: Sequence[Cell], step: float) -> float:
    return step * sum(
        math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(path, path[1:])
    )


def extract_centerlines(
    cell_set: set[Cell],
    step: float,
    min_cells: int,
    erase_radius: float = ERASE_YD,
    max_width: float = 0.0,
    min_component_length: float = 0.0,
) -> tuple[list[list[Cell]], list[set[Cell]], int, int]:
    # Width gate only kills isolated pockets. A pocket 8-connected to a real
    # road dilutes into the network mean and survives.
    paths: list[list[Cell]] = []
    discarded: list[set[Cell]] = []
    dropped_wide = 0
    dropped_short = 0
    for comp in sorted(connected_components(cell_set), key=min):
        if len(comp) < min_cells:
            continue  # silent raw-size skip, as today
        skeleton = thin_cells(comp)
        if not skeleton:
            continue  # annihilated-2x2 guard, unchanged
        comp_paths: list[list[Cell]] = []
        comp_discarded: list[set[Cell]] = []
        pending = [skeleton]
        while pending:
            pending.sort(key=min)
            piece = pending.pop(0)
            if len(piece) < min_cells:
                comp_discarded.append(piece)
                continue
            path = diameter_path(piece)
            comp_paths.append(path)
            for rem in connected_components(
                erase_near_path(piece, path, step, erase_radius)
            ):
                (pending if len(rem) >= min_cells else comp_discarded).append(rem)
        total_len = sum(_cell_path_length(p, step) for p in comp_paths)
        if (
            max_width > 0
            and comp_paths
            and total_len > 0
            and len(comp) * step * step / total_len > max_width
        ):
            dropped_wide += 1
            continue  # whole component is a blob, not a road
        if min_component_length > 0 and comp_paths and total_len < min_component_length:
            dropped_short += 1
            continue
        paths.extend(comp_paths)
        discarded.extend(comp_discarded)
    return paths, discarded, dropped_wide, dropped_short


def cells_to_world(
    path: Sequence[Cell], z_of: dict[Cell, float], step: float
) -> list[Point]:
    return [(i * step, j * step, z_of[(i, j)]) for i, j in path]


def _round_pt(p: Sequence[float]) -> list[float]:
    return [round(p[0], 1), round(p[1], 1), round(p[2], 1)]


def canonicalize_segments(polylines: Iterable[Sequence[Point]]) -> list[dict]:
    oriented: list[list[list[float]]] = []
    for pts in polylines:
        rounded = [_round_pt(p) for p in pts]
        if len(rounded) < 2:
            continue
        first = (rounded[0][0], rounded[0][1])
        last = (rounded[-1][0], rounded[-1][1])
        if first > last:
            rounded.reverse()
        oriented.append(rounded)
    oriented.sort(key=lambda pts: (pts[0][0], pts[0][1], pts[1][0], pts[1][1]))
    segs: list[dict] = []
    for n, pts in enumerate(oriented, start=1):
        segs.append({"id": f"b{n:04d}", "source": "baked", "pts": pts})
    return segs


def _planar_arclength(chain: Sequence[Point]) -> float:
    total = 0.0
    for prev, cur in zip(chain, chain[1:]):
        total += math.hypot(cur[0] - prev[0], cur[1] - prev[1])
    return total


def _paths_to_segments(
    paths: Sequence[Sequence[Cell]],
    cells: dict[Cell, float],
    step: float,
    decimate_yd: float,
    min_length: float,
) -> list[list[Point]]:
    # Filter on full-resolution planar arclength. Measuring after decimation
    # would couple segment survival to the smoothing knob.
    polylines: list[list[Point]] = []
    for path in paths:
        world = cells_to_world(path, cells, step)
        if min_length > 0 and _planar_arclength(world) < min_length:
            continue
        pts = decimate(world, decimate_yd)
        if len(pts) >= 2:
            polylines.append(pts)
    return polylines


def bake_from_cells(
    cells: dict[Cell, float],
    *,
    step: float = 4.0,
    decimate_yd: float = 10.0,
    min_cells: int = 6,
    min_length: float = 30.0,
    max_width: float = 28.0,
    min_component_length: float = 150.0,
) -> list[dict]:
    paths, _discarded, _dropped_wide, _dropped_short = extract_centerlines(
        set(cells),
        step,
        min_cells,
        max_width=max_width,
        min_component_length=min_component_length,
    )
    return canonicalize_segments(
        _paths_to_segments(paths, cells, step, decimate_yd, min_length)
    )


def make_meta(
    map_name: str,
    step: float,
    decimate_yd: float,
    min_cells: int,
    min_length: float = 30.0,
    max_water_depth: float = 0.5,
    max_width: float = 28.0,
    max_grade: float = 0.55,
    min_component_length: float = 150.0,
    minimap_route_zones: Sequence[dict] | None = None,
) -> dict:
    return {
        "meta": 1,
        "map": map_name,
        "map_id": MAP_IDS[map_name],
        "generator": GENERATOR,
        "alpha_threshold": rmask.ROAD_ALPHA_THRESHOLD,
        "step": step,
        "decimate_yd": decimate_yd,
        "min_cells": min_cells,
        "min_length_yd": min_length,
        "max_water_depth": max_water_depth,
        "max_width_yd": max_width,
        "max_grade": max_grade,
        "min_component_length_yd": min_component_length,
        "markers": list(rmask.ROAD_TEXTURE_MARKERS),
        "overlay_only_markers": list(rmask.OVERLAY_ONLY_MARKERS),
        "minimap_route_zones": list(minimap_route_zones or []),
    }


def read_hand_lines(text: str) -> list[str]:
    hands: list[str] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        src = obj.get("source")
        if src is not None and src != "baked":
            hands.append(line)
    return hands


def render_artifact(meta: dict, hand_lines: Sequence[str], baked: Sequence[dict]) -> str:
    parts = [json.dumps(meta)]
    parts.extend(hand_lines)
    parts.extend(json.dumps(seg) for seg in baked)
    return "\n".join(parts) + "\n"


def _bbox_overlap(
    min_x: float,
    min_y: float,
    max_x: float,
    max_y: float,
    bbox: tuple[float, float, float, float] | None,
) -> tuple[float, float, float, float] | None:
    sx0, sy0, sx1, sy1 = min_x, min_y, max_x, max_y
    if bbox is not None:
        bx0, by0, bx1, by1 = bbox
        blo_x, bhi_x = (bx0, bx1) if bx0 <= bx1 else (bx1, bx0)
        blo_y, bhi_y = (by0, by1) if by0 <= by1 else (by1, by0)
        sx0 = max(sx0, blo_x)
        sx1 = min(sx1, bhi_x)
        sy0 = max(sy0, blo_y)
        sy1 = min(sy1, bhi_y)
        if sx0 > sx1 or sy0 > sy1:
            return None
    return (sx0, sy0, sx1, sy1)


def _lattice_range(lo: float, hi: float, step: float) -> range:
    i_lo = math.ceil(lo / step - 1e-9)
    i_hi = math.floor(hi / step + 1e-9)
    if i_hi < i_lo:
        return range(0)
    return range(i_lo, i_hi + 1)


def _world_to_cell(x: float, y: float, step: float) -> Cell:
    # floor(x/step + 0.5), not round(): Python round() is banker's and
    # once collided lattice keys on a half-step prototype.
    return (
        int(math.floor(x / step + 0.5)),
        int(math.floor(y / step + 0.5)),
    )


def _central_diff_grade(
    mask: rmask.RoadMask, x: float, y: float
) -> tuple[float | None, float | None]:
    zc = mask.ground_z(x, y)
    zxp = mask.ground_z(x + 4.0, y)
    zxm = mask.ground_z(x - 4.0, y)
    zyp = mask.ground_z(x, y + 4.0)
    zym = mask.ground_z(x, y - 4.0)
    if zc is None:
        return None, None
    if None in (zxp, zxm, zyp, zym):
        return zc, None
    return zc, max(abs(zxp - zxm), abs(zyp - zym)) / 8.0


def _water_too_deep(
    mask: rmask.RoadMask, x: float, y: float, max_water_depth: float
) -> bool:
    return max_water_depth > 0 and mask.is_water(x, y).depth > max_water_depth


def parse_route_leg(
    raw: Sequence,
) -> tuple[str, tuple[float, float], str, tuple[float, float], dict]:
    a_name, a_xy, b_name, b_xy = raw[0], tuple(raw[1]), raw[2], tuple(raw[3])
    opts = dict(raw[4]) if len(raw) > 4 and raw[4] is not None else {}
    return a_name, a_xy, b_name, b_xy, opts


def zone_collect_grade_wall(zone: dict) -> float:
    wall = float(zone["max_grade_wall"])
    for raw in zone.get("legs") or ():
        opts = parse_route_leg(raw)[4]
        if "max_grade_wall" in opts:
            wall = max(wall, float(opts["max_grade_wall"]))
    return wall


def corridor_path_stats(
    world: Sequence[Point], z_lo: float, z_hi: float
) -> tuple[float, float]:
    if len(world) < 2:
        return 0.0, 0.0
    total = 0.0
    outside = 0.0
    max_run = 0.0
    run = 0.0
    for prev, cur in zip(world, world[1:]):
        length = math.hypot(cur[0] - prev[0], cur[1] - prev[1])
        total += length
        if cur[2] < z_lo or cur[2] > z_hi:
            outside += length
            run += length
            if run > max_run:
                max_run = run
        else:
            run = 0.0
    pct = 0.0 if total <= 0.0 else 100.0 * outside / total
    return pct, max_run


def assert_corridor_gate(pct_outside: float, leg_name: str) -> None:
    if pct_outside > CORRIDOR_OUTSIDE_MAX_PCT:
        raise SystemExit(
            f"minimap route FAILED: corridor gate {leg_name} "
            f"pct_outside={pct_outside:.1f}% exceeds "
            f"{CORRIDOR_OUTSIDE_MAX_PCT:.1f}%"
        )


def assert_snap_gate(
    snap_a: float, snap_b: float, leg_name: str, a_name: str, b_name: str
) -> None:
    if snap_a > MAX_SNAP_YD or snap_b > MAX_SNAP_YD:
        raise SystemExit(
            f"minimap route FAILED: snap exceeds {MAX_SNAP_YD:.0f}yd "
            f"for leg {leg_name}: {a_name}={snap_a:.2f}yd "
            f"{b_name}={snap_b:.2f}yd"
        )


def route_enter_cost(
    contrast: float,
    grade: float,
    contrast_c0: float,
    contrast_k: float,
    slope_penalty: float,
    z: float = 0.0,
    z_corridor: tuple[float, float, float] | None = None,
) -> float:
    extra = max(0.0, contrast_c0 - contrast) / contrast_k
    slope = slope_penalty * (grade - 0.5) if grade > 0.5 else 0.0
    corridor = 0.0
    if z_corridor is not None:
        lo, hi, pen = z_corridor
        if z < lo or z > hi:
            corridor = pen
    return 1.0 + extra + slope + corridor


def route_edge_cost(
    contrast: float,
    grade: float,
    di: int,
    dj: int,
    step: float,
    contrast_c0: float,
    contrast_k: float,
    slope_penalty: float,
    z: float = 0.0,
    z_corridor: tuple[float, float, float] | None = None,
) -> float:
    return route_enter_cost(
        contrast, grade, contrast_c0, contrast_k, slope_penalty, z, z_corridor
    ) * step * math.hypot(di, dj)


@dataclass(slots=True)
class RouteCell:
    x: float
    y: float
    z: float
    g: int
    grade: float
    contrast: float = 0.0


def _block_index(i: int, j: int, step: float, block_yd: float) -> Cell:
    return (
        int(math.floor(i * step / block_yd)),
        int(math.floor(j * step / block_yd)),
    )


def _median_int(values: Sequence[int]) -> int:
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def collect_route_cells(
    mask: rmask.RoadMask,
    sampler: mmask.MinimapSampler,
    zone: dict,
    step: float,
) -> tuple[dict[Cell, RouteCell], dict[str, int]]:
    x0, y0, x1, y1 = zone["bbox"]
    lo_x, hi_x = (x0, x1) if x0 <= x1 else (x1, x0)
    lo_y, hi_y = (y0, y1) if y0 <= y1 else (y1, y0)
    z_lo, z_hi = zone["z_band"]
    max_grade_wall = zone_collect_grade_wall(zone)
    zone_grade_wall = float(zone["max_grade_wall"])
    max_water_depth = float(zone["max_water_depth"])
    block_yd = float(zone["block_yd"])
    usable: dict[Cell, RouteCell] = {}
    blocked = 0
    scanned = 0
    z_cache: dict[tuple[float, float], float | None] = {}

    def _gz(px: float, py: float) -> float | None:
        key = (px, py)
        if key not in z_cache:
            z_cache[key] = mask.ground_z(px, py)
        return z_cache[key]

    for i in _lattice_range(lo_x, hi_x, step):
        x = i * step
        for j in _lattice_range(lo_y, hi_y, step):
            y = j * step
            scanned += 1
            zc = _gz(x, y)
            zxp = _gz(x + 4.0, y)
            zxm = _gz(x - 4.0, y)
            zyp = _gz(x, y + 4.0)
            zym = _gz(x, y - 4.0)
            if zc is None:
                grade = None
            elif None in (zxp, zxm, zyp, zym):
                grade = None
            else:
                grade = max(abs(zxp - zxm), abs(zyp - zym)) / 8.0
            if zc is None or zc < z_lo or zc > z_hi:
                blocked += 1
                continue
            if _water_too_deep(mask, x, y, max_water_depth):
                blocked += 1
                continue
            cell_grade = 0.0 if grade is None else grade
            if grade is not None and cell_grade > max_grade_wall:
                blocked += 1
                continue
            pixel = sampler.rgb(x, y)
            if pixel is None:
                blocked += 1
                continue
            usable[(i, j)] = RouteCell(
                x=x, y=y, z=zc, g=pixel[1], grade=cell_grade
            )
            if scanned % 100000 == 0:
                print(
                    f"  route scan scanned={scanned} usable={len(usable)} "
                    f"blocked={blocked}",
                    file=sys.stderr,
                    flush=True,
                )
    blocks: dict[Cell, list[int]] = {}
    for key, rec in usable.items():
        if rec.grade > zone_grade_wall:
            continue
        blocks.setdefault(_block_index(key[0], key[1], step, block_yd), []).append(
            rec.g
        )
    medians = {bk: _median_int(gs) for bk, gs in blocks.items()}
    for key, rec in usable.items():
        bk = _block_index(key[0], key[1], step, block_yd)
        rec.contrast = rec.g - medians[bk] if bk in medians else 0
    stats = {
        "cells": len(usable),
        "blocked": blocked,
        "scanned": scanned,
    }
    return usable, stats


def _snap_anchor(
    usable: dict[Cell, RouteCell], x: float, y: float, step: float
) -> tuple[Cell, float]:
    exact = _world_to_cell(x, y, step)
    if exact in usable:
        return exact, 0.0
    if not usable:
        raise SystemExit(
            f"minimap route FAILED: no usable cells to snap anchor ({x}, {y})"
        )
    best: Cell | None = None
    best_d2 = 0.0
    for key, rec in usable.items():
        dx = rec.x - x
        dy = rec.y - y
        d2 = dx * dx + dy * dy
        if best is None or d2 < best_d2 or (d2 == best_d2 and key < best):
            best = key
            best_d2 = d2
    assert best is not None
    return best, math.sqrt(best_d2)


def dijkstra_route(
    usable: dict[Cell, RouteCell],
    start: Cell,
    goal: Cell,
    step: float,
    contrast_c0: float,
    contrast_k: float,
    slope_penalty: float,
    max_grade_wall: float | None = None,
    z_corridor: tuple[float, float, float] | None = None,
) -> list[Cell] | None:
    if start not in usable or goal not in usable:
        return None
    if start == goal:
        return [start]
    dist: dict[Cell, float] = {start: 0.0}
    parent: dict[Cell, Cell | None] = {start: None}
    heap: list[tuple[float, Cell]] = [(0.0, start)]
    while heap:
        cost, u = heapq.heappop(heap)
        if cost != dist[u]:
            continue
        if u == goal:
            break
        ui, uj = u
        for di, dj in NEIGH8:
            v = (ui + di, uj + dj)
            rec = usable.get(v)
            if rec is None:
                continue
            if max_grade_wall is not None and rec.grade > max_grade_wall:
                continue
            nc = cost + route_edge_cost(
                rec.contrast,
                rec.grade,
                di,
                dj,
                step,
                contrast_c0,
                contrast_k,
                slope_penalty,
                rec.z,
                z_corridor,
            )
            prev = dist.get(v)
            if prev is None or nc < prev:
                dist[v] = nc
                parent[v] = u
                heapq.heappush(heap, (nc, v))
    if goal not in parent:
        return None
    path = [goal]
    while path[-1] != start:
        prev = parent[path[-1]]
        if prev is None:
            return None
        path.append(prev)
    path.reverse()
    return path


def route_minimap_legs(
    mask: rmask.RoadMask,
    sampler: mmask.MinimapSampler,
    zone: dict,
    step: float,
    decimate_yd: float = 10.0,
) -> tuple[list[tuple[str, list[Point]]], list[dict]]:
    usable, build_stats = collect_route_cells(mask, sampler, zone, step)
    contrast_c0 = float(zone["contrast_c0"])
    contrast_k = float(zone["contrast_k"])
    slope_penalty = float(zone["slope_penalty"])
    zone_name = zone["name"]
    print(
        f"minimap zone {zone_name}: cells={build_stats['cells']} "
        f"blocked={build_stats['blocked']} scanned={build_stats['scanned']}",
        file=sys.stderr,
        flush=True,
    )
    legs_out: list[tuple[str, list[Point]]] = []
    leg_stats: list[dict] = []
    zone_wall = float(zone["max_grade_wall"])
    for raw in zone["legs"]:
        a_name, a_xy, b_name, b_xy, opts = parse_route_leg(raw)
        leg_name = f"{a_name}->{b_name}"
        ax, ay = a_xy
        bx, by = b_xy
        z_corridor = opts.get("z_corridor")
        if z_corridor is not None:
            z_corridor = (float(z_corridor[0]), float(z_corridor[1]), float(z_corridor[2]))
        leg_wall = float(opts["max_grade_wall"]) if "max_grade_wall" in opts else zone_wall
        start, snap_a = _snap_anchor(usable, ax, ay, step)
        goal, snap_b = _snap_anchor(usable, bx, by, step)
        if snap_a > 0.0 or snap_b > 0.0:
            print(
                f"minimap snap {leg_name}: {a_name}={snap_a:.2f}yd "
                f"{b_name}={snap_b:.2f}yd",
                file=sys.stderr,
                flush=True,
            )
        assert_snap_gate(snap_a, snap_b, leg_name, a_name, b_name)
        path = dijkstra_route(
            usable,
            start,
            goal,
            step,
            contrast_c0,
            contrast_k,
            slope_penalty,
            max_grade_wall=leg_wall,
            z_corridor=z_corridor,
        )
        if path is None:
            raise SystemExit(
                f"minimap route FAILED: no path for leg {leg_name} "
                f"({ax}, {ay}) -> ({bx}, {by}) in zone {zone_name}"
            )
        world = [(usable[c].x, usable[c].y, usable[c].z) for c in path]
        pts = decimate(world, decimate_yd)
        if len(pts) < 2:
            raise SystemExit(
                f"minimap route FAILED: decimated leg {leg_name} "
                f"in zone {zone_name} has {len(pts)} point(s)"
            )
        path_yd = _planar_arclength(world)
        zs = [p[2] for p in world]
        if z_corridor is None:
            pct_outside, max_run = 0.0, 0.0
        else:
            pct_outside, max_run = corridor_path_stats(
                world, z_corridor[0], z_corridor[1]
            )
        print(
            f"minimap leg {leg_name}: path_cells={len(path)} "
            f"path_yd={path_yd:.1f} min_z={min(zs):.2f} max_z={max(zs):.2f} "
            f"pct_outside={pct_outside:.1f}% max_run={max_run:.0f}yd "
            f"snap={snap_a:.2f},{snap_b:.2f}",
            file=sys.stderr,
            flush=True,
        )
        if z_corridor is not None:
            assert_corridor_gate(pct_outside, leg_name)
        legs_out.append((leg_name, pts))
        leg_stats.append(
            {
                "leg": leg_name,
                "cells": build_stats["cells"],
                "blocked": build_stats["blocked"],
                "path_cells": len(path),
                "path_yd": path_yd,
                "min_z": min(zs),
                "max_z": max(zs),
                "pct_outside": pct_outside,
                "max_run": max_run,
                "snap": [snap_a, snap_b],
            }
        )
    return legs_out, leg_stats


def _bboxes_overlap(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
) -> bool:
    return _bbox_overlap(a[0], a[1], a[2], a[3], b) is not None


def _road_chunk_indices(tile: rmask.Tile) -> frozenset[int]:
    ids = tile.road_texture_ids
    return frozenset(
        idx
        for idx, chunk in enumerate(tile.chunks)
        if any(layer.texture_id in ids for layer in chunk.layers)
    )


def sample_road_cells(
    mask: rmask.RoadMask,
    step: float,
    bbox: tuple[float, float, float, float] | None = None,
    max_water_depth: float = 0.5,
    max_grade: float = 0.55,
) -> tuple[dict[Cell, float], dict[str, int]]:
    cells: dict[Cell, float] = {}
    fallbacks = 0
    water_skipped = 0
    grade_skipped = 0
    tiles_scanned = 0
    tiles_with_roads = 0
    t0 = time.monotonic()
    coords = mask.tile_coords()
    for n, (a, b) in enumerate(coords, start=1):
        max_x, max_y = rmask.tile_origin(a, b)
        min_x = max_x - rmask.TILE_YD
        min_y = max_y - rmask.TILE_YD
        region = _bbox_overlap(min_x, min_y, max_x, max_y, bbox)
        if region is None:
            continue
        tile = mask.tile(a, b)
        tiles_scanned += 1
        if tile is None or not tile.road_texture_ids:
            continue
        road_chunks = _road_chunk_indices(tile)
        if not road_chunks:
            continue
        tiles_with_roads += 1
        sx0, sy0, sx1, sy1 = region
        for i in _lattice_range(sx0, sx1, step):
            x = i * step
            for j in _lattice_range(sy0, sy1, step):
                key = (i, j)
                if key in cells:
                    continue
                y = j * step
                ix, iy = rmask.chunk_indices(x, y)
                if rmask.chunk_array_index(ix, iy) not in road_chunks:
                    continue
                if not mask.is_road(x, y).is_road:
                    continue
                if max_water_depth > 0 and mask.is_water(x, y).depth > max_water_depth:
                    water_skipped += 1
                    continue
                zc = None
                if max_grade > 0:
                    zc = mask.ground_z(x, y)
                    zxp = mask.ground_z(x + 4.0, y)
                    zxm = mask.ground_z(x - 4.0, y)
                    zyp = mask.ground_z(x, y + 4.0)
                    zym = mask.ground_z(x, y - 4.0)
                    if zc is not None and None not in (zxp, zxm, zyp, zym):
                        grade = max(abs(zxp - zxm), abs(zyp - zym)) / 8.0
                        if grade > max_grade:
                            grade_skipped += 1
                            continue
                    # any missing neighbor z -> keep the cell (don't punish tile edges)
                z = zc if zc is not None else mask.ground_z(x, y)
                if z is None:
                    z = 0.0
                    fallbacks += 1
                cells[key] = z
        if tiles_with_roads % 25 == 0:
            print(
                f"  sampled {tiles_with_roads} road tiles "
                f"({tiles_scanned} opened / {n} listed) "
                f"cells={len(cells)} water_skipped={water_skipped} "
                f"elapsed={time.monotonic() - t0:.1f}s",
                file=sys.stderr,
                flush=True,
            )
    stats = {
        "tiles_listed": len(coords),
        "tiles_scanned": tiles_scanned,
        "tiles_with_roads": tiles_with_roads,
        "cells": len(cells),
        "fallback_z": fallbacks,
        "water_skipped": water_skipped,
        "grade_skipped": grade_skipped,
    }
    return cells, stats


def bake_map(
    map_name: str,
    adt_dir: Path,
    step: float,
    decimate_yd: float,
    min_cells: int,
    out_path: Path,
    bbox: tuple[float, float, float, float] | None = None,
    min_length: float = 30.0,
    max_water_depth: float = 0.5,
    max_width: float = 28.0,
    max_grade: float = 0.55,
    min_component_length: float = 150.0,
    no_minimap: bool = False,
) -> dict:
    t0 = time.monotonic()
    configured_zones = list(MINIMAP_ROUTE_ZONES.get(map_name, []))
    if no_minimap:
        print("skipping minimap route pass (--no-minimap)", file=sys.stderr, flush=True)
        meta_zones: list[dict] = []
    else:
        meta_zones = configured_zones
        if configured_zones and not mmask.HAVE_PILLOW:
            print(mmask.PILLOW_REQUIRED, file=sys.stderr, flush=True)
            raise SystemExit(2)
    print(
        f"bake {map_name} adt={adt_dir} step={step} decimate={decimate_yd} "
        f"min_cells={min_cells} min_length={min_length} "
        f"max_water_depth={max_water_depth} out={out_path}",
        file=sys.stderr,
        flush=True,
    )
    mask = rmask.RoadMask(adt_dir, map_name=map_name)
    cells, stats = sample_road_cells(
        mask, step, bbox, max_water_depth=max_water_depth, max_grade=max_grade
    )
    print(
        f"sample done tiles_scanned={stats['tiles_scanned']} "
        f"road_tiles={stats['tiles_with_roads']} cells={stats['cells']} "
        f"fallback_z={stats['fallback_z']} water_skipped={stats['water_skipped']} "
        f"grade_skipped={stats['grade_skipped']} "
        f"elapsed={time.monotonic() - t0:.1f}s",
        file=sys.stderr,
        flush=True,
    )
    paths, discarded, dropped_wide, dropped_short = extract_centerlines(
        set(cells),
        step,
        min_cells,
        max_width=max_width,
        min_component_length=min_component_length,
    )
    n_components = len(connected_components(set(cells))) if cells else 0
    print(
        f"components={n_components} centerlines={len(paths)} "
        f"discarded_remnants={len(discarded)} dropped_wide={dropped_wide} "
        f"dropped_short={dropped_short} "
        f"elapsed={time.monotonic() - t0:.1f}s",
        file=sys.stderr,
        flush=True,
    )
    polylines = _paths_to_segments(paths, cells, step, decimate_yd, min_length)
    route_stats: list[dict] = []
    if not no_minimap and configured_zones:
        sampler = mmask.MinimapSampler(mmask.DEFAULT_ASSETS_DIR, map_name)
        for zone in configured_zones:
            zone_bbox = tuple(zone["bbox"])
            if bbox is not None and not _bboxes_overlap(zone_bbox, bbox):
                print(
                    f"skipping minimap zone {zone['name']} (outside bbox)",
                    file=sys.stderr,
                    flush=True,
                )
                continue
            routed, zstats = route_minimap_legs(
                mask, sampler, zone, step, decimate_yd=decimate_yd
            )
            for _leg_name, pts in routed:
                polylines.append(pts)
            route_stats.extend(zstats)
    baked = canonicalize_segments(polylines)
    meta = make_meta(
        map_name,
        step,
        decimate_yd,
        min_cells,
        min_length=min_length,
        max_water_depth=max_water_depth,
        max_width=max_width,
        max_grade=max_grade,
        min_component_length=min_component_length,
        minimap_route_zones=meta_zones,
    )
    existing = out_path.read_text(encoding="utf-8") if out_path.is_file() else ""
    hand = read_hand_lines(existing)
    text = render_artifact(meta, hand, baked)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text, encoding="utf-8")
    elapsed = time.monotonic() - t0
    print(
        f"wrote {out_path} segments={len(baked)} hand={len(hand)} "
        f"bytes={len(text.encode('utf-8'))} elapsed={elapsed:.1f}s",
        file=sys.stderr,
        flush=True,
    )
    stats.update(
        {
            "components": n_components,
            "segments": len(baked),
            "hand": len(hand),
            "dropped_wide": dropped_wide,
            "dropped_short": dropped_short,
            "elapsed_s": elapsed,
            "minimap_route": route_stats,
        }
    )
    return stats


def default_adt_dir(map_name: str) -> Path:
    return rmask.DEFAULT_ADT_DIR.parent / map_name


def default_out_path(map_name: str) -> Path:
    return Path("tools/data") / f"road_waypoints_{map_name}.jsonl"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--map", required=True, choices=sorted(MAP_IDS))
    parser.add_argument("--adt-dir", type=Path, default=None)
    parser.add_argument("--step", type=float, default=4.0)
    parser.add_argument("--decimate", type=float, default=10.0)
    parser.add_argument("--min-cells", type=int, default=6)
    parser.add_argument(
        "--min-length",
        type=float,
        default=30.0,
        help="Drop segments shorter than this planar yards; <=0 disables",
    )
    parser.add_argument(
        "--max-water-depth",
        type=float,
        default=0.5,
        help="Skip road cells with MCLQ depth above this; <=0 disables",
    )
    parser.add_argument(
        "--max-width",
        type=float,
        default=28.0,
        help="Drop components whose mean paint width exceeds this (yd); <=0 disables",
    )
    parser.add_argument(
        "--max-grade",
        type=float,
        default=0.55,
        help="Skip cells whose local terrain grade exceeds this (dz/yd); <=0 disables",
    )
    parser.add_argument(
        "--min-component-length",
        type=float,
        default=150.0,
        help="Drop components whose total centerline length is shorter than this (yd); <=0 disables",
    )
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument(
        "--bbox",
        nargs=4,
        type=float,
        metavar=("X0", "Y0", "X1", "Y1"),
        default=None,
        help="Optional world-bbox subset for sampling",
    )
    parser.add_argument(
        "--no-minimap",
        action="store_true",
        help="Skip minimap-routed zone legs",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    adt_dir = args.adt_dir if args.adt_dir is not None else default_adt_dir(args.map)
    out_path = args.out if args.out is not None else default_out_path(args.map)
    if not adt_dir.is_dir():
        print(f"error: ADT dir not found: {adt_dir}", file=sys.stderr)
        return 1
    bbox = tuple(args.bbox) if args.bbox is not None else None
    bake_map(
        args.map,
        adt_dir,
        args.step,
        args.decimate,
        args.min_cells,
        out_path,
        bbox=bbox,
        min_length=args.min_length,
        max_water_depth=args.max_water_depth,
        max_width=args.max_width,
        max_grade=args.max_grade,
        min_component_length=args.min_component_length,
        no_minimap=args.no_minimap,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
