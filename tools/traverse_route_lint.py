#!/usr/bin/env python3
"""Offline lint for traverse land-beat corridors (Detour + spawn snapshot)."""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Sequence

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BEATS = ROOT / "lua" / "config" / "traverse_land_beats.json"
DEFAULT_SPAWNS = ROOT / "tools" / "data" / "spawns_kalimdor_40plus.tsv"
DEFAULT_HELPER = Path(
    os.environ.get(
        "VANILLA_WOW_NAVMESH_HELPER",
        "/home/monofuel/src/wow-coworld/monofuel-vanilla-wow/tmp/vmangos-navmesh-helper",
    )
)
_extracted = os.environ.get("VANILLA_WOW_EXTRACTED_DATA_DIR")
DEFAULT_MMAPS = Path(
    os.path.join(_extracted, "mmaps")
    if _extracted
    else "/home/monofuel/src/wow-coworld/coworld-vanilla-wow/local_data/vmangos-5875-data/mmaps"
)

MAP_ID = 1
ARRIVAL_RADIUS = 6.0
MAX_WAYPOINTS = 4096
COMPLETE_PLANAR_YD = 12.0
SPAWN_WARN_YD = 12.0
MAX_SLOPE = 1.5
MIN_SLOPE_SEGMENT_YD = 2.0
MAX_CONTINUATION_HOPS = 6
INCLUDE_GROUND = 1
INCLUDE_GROUND_WATER = 9
SPAWN_LEVEL_MIN = 45
FRIENDLY_NAMES = frozenset(
    {
        "Grazle",
        "Tenell Leafrunner",
        "Taronn Redfeather",
        "Nafien",
        "Timbermaw Warder",
    }
)
Z_OFFSETS = (0.0, 30.0, -30.0, 60.0, -60.0)


@dataclass(frozen=True)
class Point:
    x: float
    y: float
    z: float

    def as_dict(self, map_id: int = MAP_ID) -> dict[str, Any]:
        return {"map_id": map_id, "x": self.x, "y": self.y, "z": self.z}


@dataclass(frozen=True)
class Beat:
    id: str
    x: float
    y: float
    z: float
    radius: float

    @property
    def point(self) -> Point:
        return Point(self.x, self.y, self.z)


@dataclass(frozen=True)
class Spawn:
    x: float
    y: float
    z: float
    level_min: int
    level_max: int
    name: str


@dataclass
class ProbeResult:
    complete: bool
    max_segment_slope: float
    used_water: bool
    message: str
    waypoints: list[Point]


ProbeFn = Callable[[Point, Point, int], ProbeResult]


def planar_distance(ax: float, ay: float, bx: float, by: float) -> float:
    return math.hypot(ax - bx, ay - by)


def point_to_segment_distance(
    px: float, py: float, ax: float, ay: float, bx: float, by: float
) -> float:
    """Planar distance from point P to segment AB (yards)."""
    abx = bx - ax
    aby = by - ay
    apx = px - ax
    apy = py - ay
    ab2 = abx * abx + aby * aby
    if ab2 <= 0.0:
        return math.hypot(apx, apy)
    t = (apx * abx + apy * aby) / ab2
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    cx = ax + t * abx
    cy = ay + t * aby
    return math.hypot(px - cx, py - cy)


def load_beats(path: Path) -> list[Beat]:
    data = json.loads(path.read_text())
    beats_raw = data["beats"]
    out: list[Beat] = []
    for row in beats_raw:
        out.append(
            Beat(
                id=str(row["id"]),
                x=float(row["x"]),
                y=float(row["y"]),
                z=float(row["z"]),
                radius=float(row.get("radius", 0.0)),
            )
        )
    return out


def load_spawns(path: Path) -> list[Spawn]:
    out: list[Spawn] = []
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        out.append(
            Spawn(
                x=float(parts[0]),
                y=float(parts[1]),
                z=float(parts[2]),
                level_min=int(float(parts[3])),
                level_max=int(float(parts[4])),
                name=parts[5].strip(),
            )
        )
    return out


def filter_hostile_spawns(spawns: Sequence[Spawn]) -> list[Spawn]:
    return [
        s
        for s in spawns
        if s.level_min >= SPAWN_LEVEL_MIN and s.name not in FRIENDLY_NAMES
    ]


def spawn_warnings_for_leg(
    a: Beat, b: Beat, hostiles: Sequence[Spawn]
) -> list[str]:
    warns: list[str] = []
    for s in hostiles:
        dist = point_to_segment_distance(s.x, s.y, a.x, a.y, b.x, b.y)
        if dist < SPAWN_WARN_YD:
            warns.append(
                f"{s.name} @({s.x:.1f},{s.y:.1f},{s.z:.1f}) dist={dist:.1f}yd"
            )
    return warns


def _is_projection_failure(message: str) -> bool:
    """True when the helper message indicates a failed / no-path probe.

    Any no-path or failed probe should trigger source/target z-sweep: recorded
    beat z is often 10-40 yd off the mesh surface, and the helper's wording
    varies ("could not project", "no physically admissible …", bare "no path").
    """
    m = (message or "").lower()
    if not m:
        return False
    return (
        "could not project" in m
        or "no physically admissible" in m
        or "no path" in m
        or "failed" in m
        or "error" in m
        or "unable" in m
    )


def _should_retry_with_z_sweep(resp: dict[str, Any]) -> bool:
    """Retry z-sweep on any failed/incomplete hop, not only projection wording."""
    status = str(resp.get("status") or "").lower()
    if status in ("error", "failed", "fail"):
        return True
    wps = resp.get("waypoints") or []
    if not wps:
        return True
    msg = str(resp.get("message") or "")
    return _is_projection_failure(msg)


def _parse_point(obj: Any) -> Point | None:
    if not isinstance(obj, dict):
        return None
    try:
        return Point(float(obj["x"]), float(obj["y"]), float(obj["z"]))
    except (KeyError, TypeError, ValueError):
        return None


def call_helper_once(
    helper: Path,
    mmaps: Path,
    source: Point,
    target: Point,
    include_flags: int,
) -> dict[str, Any]:
    request = {
        "op": "route",
        "mmaps_dir": str(mmaps),
        "request": {
            "map_id": MAP_ID,
            "source": source.as_dict(),
            "target": target.as_dict(),
            "arrival_radius": ARRIVAL_RADIUS,
            "max_waypoints": MAX_WAYPOINTS,
            "include_flags": include_flags,
            "exclude_flags": 0,
            "tile_load_mode": "auto",
        },
    }
    proc = subprocess.run(
        [str(helper)],
        input=json.dumps(request),
        text=True,
        capture_output=True,
        check=False,
    )
    raw = (proc.stdout or "").strip()
    if not raw:
        return {
            "status": "error",
            "message": (proc.stderr or "empty helper stdout").strip(),
            "waypoints": [],
            "continuation_required": False,
            "max_segment_slope": 0.0,
        }
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        return {
            "status": "error",
            "message": f"bad helper json: {exc}",
            "waypoints": [],
            "continuation_required": False,
            "max_segment_slope": 0.0,
        }


def z_sweep_candidates(source: Point, target: Point) -> list[tuple[Point, Point]]:
    """Source and target z offsets (0, +-30, +-60) for projection recovery."""
    out: list[tuple[Point, Point]] = []
    for src_dz in Z_OFFSETS:
        s = Point(source.x, source.y, source.z + src_dz)
        for tgt_dz in Z_OFFSETS:
            t = Point(target.x, target.y, target.z + tgt_dz)
            out.append((s, t))
    return out


def single_hop_with_z_retry(
    helper: Path,
    mmaps: Path,
    source: Point,
    target: Point,
    include_flags: int,
) -> dict[str, Any]:
    last: dict[str, Any] = {}
    for s, t in z_sweep_candidates(source, target):
        last = call_helper_once(helper, mmaps, s, t, include_flags)
        if not _should_retry_with_z_sweep(last):
            return last
    return last


def is_complete_response(resp: dict[str, Any], target: Point) -> bool:
    wps = resp.get("waypoints") or []
    if not wps:
        return False
    if bool(resp.get("continuation_required")):
        return False
    last = _parse_point(wps[-1])
    if last is None:
        return False
    return planar_distance(last.x, last.y, target.x, target.y) <= COMPLETE_PLANAR_YD


def chain_route(
    helper: Path,
    mmaps: Path,
    source: Point,
    target: Point,
    include_flags: int,
) -> ProbeResult:
    """Query helper, chain partials (max hops), return completeness + worst slope."""
    all_wps: list[Point] = []
    worst_slope = 0.0
    cursor = source
    last_msg = ""
    for _hop in range(MAX_CONTINUATION_HOPS):
        resp = single_hop_with_z_retry(
            helper, mmaps, cursor, target, include_flags
        )
        last_msg = str(resp.get("message") or "")
        slope = float(resp.get("max_segment_slope") or 0.0)
        if slope > worst_slope:
            worst_slope = slope
        raw_wps = resp.get("waypoints") or []
        hop_wps: list[Point] = []
        for w in raw_wps:
            p = _parse_point(w)
            if p is not None:
                hop_wps.append(p)
        if hop_wps:
            if all_wps and hop_wps[0] == all_wps[-1]:
                all_wps.extend(hop_wps[1:])
            else:
                all_wps.extend(hop_wps)
        if is_complete_response(resp, target):
            return ProbeResult(
                complete=True,
                max_segment_slope=worst_slope,
                used_water=include_flags == INCLUDE_GROUND_WATER,
                message=last_msg,
                waypoints=all_wps,
            )
        if not bool(resp.get("continuation_required")):
            break
        end = _parse_point(resp.get("partial_path_end"))
        if end is None and hop_wps:
            end = hop_wps[-1]
        if end is None:
            break
        if planar_distance(end.x, end.y, cursor.x, cursor.y) < 0.5:
            break
        cursor = end
    complete = False
    if all_wps:
        last = all_wps[-1]
        complete = (
            planar_distance(last.x, last.y, target.x, target.y) <= COMPLETE_PLANAR_YD
        )
    return ProbeResult(
        complete=complete,
        max_segment_slope=worst_slope,
        used_water=include_flags == INCLUDE_GROUND_WATER,
        message=last_msg,
        waypoints=all_wps,
    )


def make_helper_probe(helper: Path, mmaps: Path) -> ProbeFn:
    def probe(source: Point, target: Point, include_flags: int) -> ProbeResult:
        return chain_route(helper, mmaps, source, target, include_flags)

    return probe


def directional_slopes(waypoints: Sequence[Point]) -> tuple[float, float]:
    """Max ascending and max descending magnitude along travel order.

    Slope is (z2-z1)/planar_distance. Segments shorter than MIN_SLOPE_SEGMENT_YD
    are ignored (noise / vertical snaps).
    """
    max_asc = 0.0
    max_desc = 0.0
    for i in range(len(waypoints) - 1):
        p0, p1 = waypoints[i], waypoints[i + 1]
        planar = planar_distance(p0.x, p0.y, p1.x, p1.y)
        if planar <= MIN_SLOPE_SEGMENT_YD:
            continue
        slope = (p1.z - p0.z) / planar
        if slope > max_asc:
            max_asc = slope
        elif slope < 0.0 and (-slope) > max_desc:
            max_desc = -slope
    return max_asc, max_desc


def lint_leg(
    a: Beat,
    b: Beat,
    probe: ProbeFn,
    hostiles: Sequence[Spawn],
) -> tuple[str, str]:
    """Return (severity, details) severity in OK|WARN|FAIL."""
    ground = probe(a.point, b.point, INCLUDE_GROUND)
    if not ground.complete:
        water = probe(a.point, b.point, INCLUDE_GROUND_WATER)
        if water.complete:
            return (
                "FAIL",
                f"water-crossing land leg (slope={water.max_segment_slope:.3f})",
            )
        detail = water.message or ground.message or "incomplete"
        return "FAIL", f"no corridor ({detail})"

    max_asc, max_desc = directional_slopes(ground.waypoints)
    if max_asc > MAX_SLOPE:
        return (
            "FAIL",
            f"client cannot climb (ascending_slope={max_asc:.3f})",
        )

    warn_parts: list[str] = []
    if max_desc > MAX_SLOPE:
        warn_parts.append(f"steep descent (slope={max_desc:.3f})")
    spawn_warns = spawn_warnings_for_leg(a, b, hostiles)
    if spawn_warns:
        warn_parts.append(f"spawn proximity: {'; '.join(spawn_warns)}")
    if warn_parts:
        return "WARN", "; ".join(warn_parts)
    return "OK", f"ground ascending_slope={max_asc:.3f}"


def lint_route(
    beats: Sequence[Beat],
    probe: ProbeFn,
    hostiles: Sequence[Spawn],
) -> list[tuple[str, str, str]]:
    """List of (severity, pair_label, details) for each consecutive pair."""
    rows: list[tuple[str, str, str]] = []
    for i in range(len(beats) - 1):
        a, b = beats[i], beats[i + 1]
        label = f"{a.id}->{b.id}"
        sev, details = lint_leg(a, b, probe, hostiles)
        rows.append((sev, label, details))
    return rows


def format_line(severity: str, label: str, details: str) -> str:
    return f"{severity} {label}: {details}"


def summarize(rows: Sequence[tuple[str, str, str]]) -> str:
    n_ok = sum(1 for s, _, _ in rows if s == "OK")
    n_warn = sum(1 for s, _, _ in rows if s == "WARN")
    n_fail = sum(1 for s, _, _ in rows if s == "FAIL")
    return f"summary: {len(rows)} legs, {n_ok} OK, {n_warn} WARN, {n_fail} FAIL"


def resources_ready(helper: Path, mmaps: Path) -> bool:
    return helper.is_file() and os.access(helper, os.X_OK) and mmaps.is_dir()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--beats", type=Path, default=DEFAULT_BEATS)
    parser.add_argument("--spawns", type=Path, default=DEFAULT_SPAWNS)
    parser.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    parser.add_argument("--mmaps", type=Path, default=DEFAULT_MMAPS)
    parser.add_argument(
        "--warn-only",
        action="store_true",
        help="Print FAILs as LINT-FAIL but exit 0 (test suite mode)",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if not resources_ready(args.helper, args.mmaps):
        print(
            f"SKIP navmesh helper or mmaps missing "
            f"(helper={args.helper}, mmaps={args.mmaps})",
            file=sys.stderr,
        )
        print("SKIP: no helper/mmaps — route lint not run")
        return 0

    if not args.beats.is_file():
        print(f"FAIL missing beats file: {args.beats}", file=sys.stderr)
        return 1

    beats = load_beats(args.beats)
    if len(beats) < 2:
        print("FAIL need at least two beats", file=sys.stderr)
        return 1

    hostiles = filter_hostile_spawns(load_spawns(args.spawns))
    probe = make_helper_probe(args.helper, args.mmaps)
    rows = lint_route(beats, probe, hostiles)
    for sev, label, details in rows:
        print_sev = "LINT-FAIL" if (args.warn_only and sev == "FAIL") else sev
        print(format_line(print_sev, label, details))
    print(summarize(rows))
    if args.warn_only:
        return 0
    return 1 if any(s == "FAIL" for s, _, _ in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
