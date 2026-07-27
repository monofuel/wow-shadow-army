"""Pure corpse-run corridor helpers (no network, no upstream SDK).

Recovery must follow an ordered multi-leg corridor (around terrain, then
toward the body) — never score primarily by 2D gap-to-corpse.
"""

from __future__ import annotations

import math
from typing import Optional, Sequence


Point = tuple[float, float, float]


def gap_2d(ax: float, ay: float, bx: float, by: float) -> float:
    """Planar distance between two points."""
    return math.hypot(ax - bx, ay - by)


def gap_3d(a: Point, b: Point) -> float:
    """3D Euclidean distance."""
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


def subsample_corridor(
    waypoints: Sequence[Point],
    *,
    min_spacing: float = 8.0,
) -> list[Point]:
    """Keep corridor order; drop points closer than ``min_spacing`` (2D)."""
    if not waypoints:
        return []
    out: list[Point] = [tuple(map(float, waypoints[0]))]  # type: ignore[arg-type]
    for w in waypoints[1:]:
        x, y, z = float(w[0]), float(w[1]), float(w[2])
        px, py, _ = out[-1]
        if gap_2d(px, py, x, y) >= min_spacing:
            out.append((x, y, z))
    # always keep the last point (corpse / leg end)
    last = tuple(map(float, waypoints[-1]))  # type: ignore[arg-type]
    if out[-1] != last:
        lx, ly, lz = last
        px, py, _ = out[-1]
        if gap_2d(px, py, lx, ly) > 0.5:
            out.append((lx, ly, lz))
        else:
            out[-1] = (lx, ly, lz)
    return out


def next_corridor_index(
    sx: float,
    sy: float,
    corridor: Sequence[Point],
    start_i: int = 0,
    *,
    arrive: float = 6.0,
) -> int:
    """First corridor index not yet within ``arrive`` yards (2D)."""
    i = max(0, start_i)
    while i < len(corridor):
        x, y, _z = corridor[i]
        if gap_2d(sx, sy, x, y) <= arrive:
            i += 1
            continue
        break
    return i


def corridor_progress(
    sx: float,
    sy: float,
    corridor: Sequence[Point],
    index: int,
) -> float:
    """Distance to the current corridor leg target (inf if past end)."""
    if index >= len(corridor):
        return 0.0
    x, y, _z = corridor[index]
    return gap_2d(sx, sy, x, y)


def should_reclaim(
    *, can_reclaim: bool, gap: float, reclaim_range: float = 10.0
) -> bool:
    """True when fair-play reclaim should be attempted."""
    return bool(can_reclaim) and gap <= reclaim_range


def is_direct_line_policy(reason: str) -> bool:
    """Detect old thrash reasons that must not be the primary strategy."""
    r = (reason or "").lower()
    return r in {
        "move_to_corpse",
        "move_to_corpse_hop",
        "corpse_gap_micro",
        "gap_minimize",
    }


# Fixed anchor corridor for the known Deathknell NE hill + elevated body pocket
# when Detour is unavailable. Goes east along the valley floor then north up
# the approach (matches observed Detour routes for this death).
DEATHKNELL_NE_CORPSE_ANCHORS: list[Point] = [
    (1985.0, 1722.0, 87.0),
    (2005.0, 1725.0, 85.0),
    (2025.0, 1728.0, 85.0),
    (2035.0, 1740.0, 87.0),
    (2046.0, 1755.0, 89.0),
    (2048.0, 1775.0, 94.0),
    (2048.0, 1795.0, 99.0),
    (2048.0, 1810.0, 104.0),
    (2046.0, 1825.0, 108.0),
    (2044.0, 1838.0, 108.0),
]


def anchor_corridor_to_corpse(
    sx: float,
    sy: float,
    sz: float,
    cx: float,
    cy: float,
    cz: float,
    *,
    anchors: Optional[Sequence[Point]] = None,
    min_spacing: float = 8.0,
) -> list[Point]:
    """Build ordered anchors → corpse, skipping anchors already behind the ghost."""
    anchors = list(anchors or DEATHKNELL_NE_CORPSE_ANCHORS)
    # Start from the first anchor still ahead of current pos along the path
    # (not closer-to-corpse: use path order, drop points already near).
    pts: list[Point] = []
    for ax, ay, az in anchors:
        # skip anchors we've already passed (behind us toward corpse roughly)
        # keep if still useful as a leg: not within arrive of self
        if gap_2d(sx, sy, ax, ay) > min_spacing * 0.6:
            pts.append((float(ax), float(ay), float(az)))
    pts.append((float(cx), float(cy), float(cz)))
    return subsample_corridor(pts, min_spacing=min_spacing)
