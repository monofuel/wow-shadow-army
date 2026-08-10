#!/usr/bin/env python3
"""Resample the manual F9 swim track into the traverse beat carpet.

The sparse cheese carpet (42 beats) is a centerline sample of the human
run; following it beat-to-beat cuts off the track's shoreward weave, and
that weave is load-bearing: fatigue refills (instantly) only when the body
crosses into the playable coastal water band, and the human's line touches
that band repeatedly. A dense resample keeps the weave, so fatigue behaves
for the bot the way it behaved for the human — no boundary heuristics.

The one place the human line is not followable is the -5675,-4770 wall
spur: the human dove under it, and z-following at 10x tunnels through
world collision at random (wet-lab runs 9-15). Samples in the wall span
are pushed seaward onto the surface bypass proven by run 16.

Usage: python3 tools/resample_human_ribbon.py [--spacing 25] [--write]
Reads the authoritative manual log; with --write regenerates
lua/config/traverse_beats.json and .lua (version 8).
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANUAL_LOG = (
    ROOT / "local_data" / "traverse-runs" / "20260807T041622Z-4035488"
    / "manual" / "real-playerbot-log-1786076362279-4043754-2.jsonl"
)
JSON_PATH = ROOT / "lua" / "config" / "traverse_beats.json"
LUA_PATH = ROOT / "lua" / "config" / "traverse_beats.lua"

# Segment bounds (map 1): water entry to just short of the duskwallow goal.
X_START = -6784.5
X_END = -4660.0
# Wall spur span: surface path is blocked at the human line; force the
# proven seaward bypass (run 16 crossed at full health on this line).
WALL_X_MIN = -5710.0
WALL_X_MAX = -5590.0
WALL_BYPASS_Y = -4875.0
# Spit hole span: at 10x the seat falls through world collision crossing
# the shallow spit at ~(-4845,-4841) (run 21: z -0.5 -> -270, double
# fall-through, far-graveyard teleport). Route seaward of it.
HOLE_X_MIN = -4870.0
HOLE_X_MAX = -4790.0
HOLE_BYPASS_Y = -4872.0

LAND_BEATS = [
    {"id": "land_approach", "x": -7100.0, "y": -4600.0, "z": 10.0,
     "radius": 80.0, "mode": "land", "require_wet": False},
    {"id": "water_entry", "x": -6784.5, "y": -4833.9, "z": 0.7,
     "radius": 50.0, "mode": "land", "require_wet": False},
]
GOAL_BEAT = {
    "id": "duskwallow_coast", "x": -4627.01, "y": -4869.45, "z": -2.37,
    "radius": 25.0, "mode": "liquid_prefer", "require_wet": True,
}


def read_track() -> list[tuple[float, float, float]]:
    track: list[tuple[float, float, float]] = []
    with open(MANUAL_LOG, encoding="utf-8") as fh:
        for line in fh:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("type") != "human_step":
                continue
            player = row.get("view", {}).get("player", {})
            pos = player.get("position")
            if not pos or pos.get("map_id") != 1:
                continue
            safe = not player.get("fatigue_timer_active", False)
            track.append((pos["x"], pos["y"], pos["z"], safe))
    return track


def resample(track, spacing: float):
    # Keep the monotone-northing wet portion of the track — and only the
    # steps where the human's fatigue timer was INACTIVE: those positions
    # are measured safe water (the timer is the game's own boundary
    # sensor). Smoothed centerlines skirt the safe band and never refill
    # (wet-lab run 23 drained 1.0 -> 0.03 without a single touch); a
    # carpet built from safe samples lives inside it, and the unavoidable
    # drain bouts become straight crossings between safe endpoints, which
    # is exactly what the human swam.
    # Safe-flagged samples plus the wall-span dive line: the descent-
    # evidence physics fix makes the human's under-wall dive followable,
    # so the wall span keeps its true (drain-flagged) samples instead of
    # a seaward surface bypass.
    wet = [p for p in track if X_START <= p[0] <= X_END and
           (p[3] or WALL_X_MIN <= p[0] <= WALL_X_MAX)]
    out: list[tuple[float, float, float]] = []
    acc = 0.0
    prev = None
    for p in wet:
        if prev is None:
            out.append(p)
            prev = p
            continue
        acc += math.hypot(p[0] - prev[0], p[1] - prev[1])
        prev = p
        if acc >= spacing:
            out.append(p)
            acc = 0.0
    if wet and (not out or out[-1] is not wet[-1]):
        out.append(wet[-1])
    # Monotone by northing with hysteresis: the raw track pauses and jogs;
    # the carpet must never point the run south.
    mono = []
    for p in out:
        if not mono or p[0] > mono[-1][0] - 5.0:
            mono.append(p)
    return [(x, y, z) for (x, y, z, _safe) in mono]


def build_beats(samples) -> list[dict]:
    beats = list(LAND_BEATS)
    for i, (x, y, z) in enumerate(samples, 1):
        if HOLE_X_MIN <= x <= HOLE_X_MAX:
            y = min(y, HOLE_BYPASS_Y)
        beats.append({
            "id": f"ribbon_{i:03d}",
            "x": round(x, 2), "y": round(y, 2), "z": round(z, 2),
            "radius": 35.0, "mode": "liquid_prefer", "require_wet": True,
        })
    beats.append(GOAL_BEAT)
    return beats


def write_configs(beats: list[dict]) -> None:
    doc = {
        "version": 12,
        "map_id": 1,
        "goal_id": "duskwallow_coast",
        "cheese": True,
        "source": "resample_human_ribbon.py over the manual F9 swim log",
        "beats": beats,
    }
    JSON_PATH.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    lines = [
        "-- Petrel route beats: land approach to the Tanaris coast, then the",
        "-- manual-run ribbon to the Dustwallow coast, densely resampled from",
        "-- the F9 swim log by tools/resample_human_ribbon.py (v12). The JSON",
        "-- is the source of record (map browser overlay reads it); keep both",
        "-- in sync by regenerating, not editing.",
        "return {",
        "  version = 12,",
        "  map_id = 1,",
        '  goal_id = "duskwallow_coast",',
        "  beats = {",
    ]
    for b in beats:
        lines.append(
            f'    {{ id = "{b["id"]}", x = {b["x"]}, y = {b["y"]}, '
            f'z = {b["z"]}, radius = {b["radius"]},'
        )
        lines.append(
            f'      wet = {"true" if b["require_wet"] else "false"} }},'
        )
    lines += ["  },", "}", ""]
    LUA_PATH.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spacing", type=float, default=25.0)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    track = read_track()
    samples = resample(track, args.spacing)
    beats = build_beats(samples)
    wet = [b for b in beats if b["require_wet"]]
    print(f"track steps: {len(track)}; resampled: {len(samples)}; "
          f"beats total {len(beats)} (wet {len(wet)})")
    bypass = [b for b in beats if b["id"].startswith("ribbon_")
              and WALL_X_MIN <= b["x"] <= WALL_X_MAX]
    print(f"wall-span beats on bypass: {len(bypass)}")
    if args.write:
        write_configs(beats)
        print(f"wrote {JSON_PATH.name} and {LUA_PATH.name} (v8)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
