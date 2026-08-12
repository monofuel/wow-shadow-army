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


def extract_centerlines(
    cell_set: set[Cell],
    step: float,
    min_cells: int,
    erase_radius: float = ERASE_YD,
) -> tuple[list[list[Cell]], list[set[Cell]]]:
    pending = [c for c in connected_components(cell_set) if len(c) >= min_cells]
    paths: list[list[Cell]] = []
    discarded: list[set[Cell]] = []
    while pending:
        pending.sort(key=min)
        comp = pending.pop(0)
        if len(comp) < min_cells:
            discarded.append(comp)
            continue
        path = diameter_path(comp)
        paths.append(path)
        remaining = erase_near_path(comp, path, step, erase_radius)
        for rem in connected_components(remaining):
            if len(rem) >= min_cells:
                pending.append(rem)
            else:
                discarded.append(rem)
    return paths, discarded


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


def bake_from_cells(
    cells: dict[Cell, float],
    *,
    step: float = 4.0,
    decimate_yd: float = 10.0,
    min_cells: int = 6,
) -> list[dict]:
    paths, _discarded = extract_centerlines(set(cells), step, min_cells)
    polylines: list[list[Point]] = []
    for path in paths:
        pts = decimate(cells_to_world(path, cells, step), decimate_yd)
        if len(pts) >= 2:
            polylines.append(pts)
    return canonicalize_segments(polylines)


def make_meta(
    map_name: str,
    step: float,
    decimate_yd: float,
    min_cells: int,
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
) -> tuple[dict[Cell, float], dict[str, int]]:
    cells: dict[Cell, float] = {}
    fallbacks = 0
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
                z = mask.ground_z(x, y)
                if z is None:
                    z = 0.0
                    fallbacks += 1
                cells[key] = z
        if tiles_with_roads % 25 == 0:
            print(
                f"  sampled {tiles_with_roads} road tiles "
                f"({tiles_scanned} opened / {n} listed) "
                f"cells={len(cells)} elapsed={time.monotonic() - t0:.1f}s",
                file=sys.stderr,
                flush=True,
            )
    stats = {
        "tiles_listed": len(coords),
        "tiles_scanned": tiles_scanned,
        "tiles_with_roads": tiles_with_roads,
        "cells": len(cells),
        "fallback_z": fallbacks,
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
) -> dict:
    t0 = time.monotonic()
    print(
        f"bake {map_name} adt={adt_dir} step={step} decimate={decimate_yd} "
        f"min_cells={min_cells} out={out_path}",
        file=sys.stderr,
        flush=True,
    )
    mask = rmask.RoadMask(adt_dir, map_name=map_name)
    cells, stats = sample_road_cells(mask, step, bbox)
    print(
        f"sample done tiles_scanned={stats['tiles_scanned']} "
        f"road_tiles={stats['tiles_with_roads']} cells={stats['cells']} "
        f"fallback_z={stats['fallback_z']} elapsed={time.monotonic() - t0:.1f}s",
        file=sys.stderr,
        flush=True,
    )
    paths, discarded = extract_centerlines(set(cells), step, min_cells)
    n_components = len(connected_components(set(cells))) if cells else 0
    print(
        f"components={n_components} centerlines={len(paths)} "
        f"discarded_remnants={len(discarded)} elapsed={time.monotonic() - t0:.1f}s",
        file=sys.stderr,
        flush=True,
    )
    polylines: list[list[Point]] = []
    for path in paths:
        pts = decimate(cells_to_world(path, cells, step), decimate_yd)
        if len(pts) >= 2:
            polylines.append(pts)
    baked = canonicalize_segments(polylines)
    meta = make_meta(map_name, step, decimate_yd, min_cells)
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
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
