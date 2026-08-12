#!/usr/bin/env python3
"""Bake painted-road masks into a curated-forever JSONL waypoint artifact.

Centerlines are extracted from a global world-aligned lattice over ADT road
paint, then merged with any existing hand-curated lines. Output is
deterministic: no timestamps, stable ids assigned after sort.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from collections import deque
from pathlib import Path
from typing import Iterable, Sequence

import road_mask as rmask

Cell = tuple[int, int]
Point = tuple[float, float, float]

MAP_IDS = {"kalimdor": 1, "azeroth": 0}
GENERATOR = "tools/bake_road_waypoints.py"
ERASE_YD = 6.0
NEIGH8 = tuple(
    (di, dj)
    for di in (-1, 0, 1)
    for dj in (-1, 0, 1)
    if not (di == 0 and dj == 0)
)
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
) -> dict:
    t0 = time.monotonic()
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
    baked = canonicalize_segments(
        _paths_to_segments(paths, cells, step, decimate_yd, min_length)
    )
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
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
