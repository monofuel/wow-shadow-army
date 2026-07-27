"""Query the VMaNGOS Detour navmesh helper for multi-leg corridors.

Protocol: vanilla_wow.navmesh_helper.v2 (see docs/navmesh.md).
"""

from __future__ import annotations

import json
import math
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

from brain.corpse_recovery_path import Point, subsample_corridor


def _default_helper() -> Optional[str]:
    env = os.environ.get("VANILLA_WOW_NAVMESH_HELPER", "").strip()
    if env and Path(env).is_file():
        return env
    # Makefile default relative to repo
    repo = Path(__file__).resolve().parents[1]
    cand = repo.parent / "coworld-vanilla-wow" / "tmp" / "vmangos-navmesh-helper"
    if cand.is_file():
        return str(cand)
    return None


def _default_mmaps() -> Optional[str]:
    env = os.environ.get("VANILLA_WOW_EXTRACTED_DATA_DIR", "").strip()
    if env:
        p = Path(env) / "mmaps"
        if p.is_dir():
            return str(p)
    repo = Path(__file__).resolve().parents[1]
    cand = (
        repo.parent
        / "coworld-vanilla-wow"
        / "local_data"
        / "vmangos-5875-data"
        / "mmaps"
    )
    if cand.is_dir():
        return str(cand)
    return None


def query_route_chunk(
    sx: float,
    sy: float,
    sz: float,
    tx: float,
    ty: float,
    tz: float,
    *,
    map_id: int = 0,
    helper: Optional[str] = None,
    mmaps_dir: Optional[str] = None,
) -> dict[str, Any]:
    """One Detour ``route`` request; returns parsed JSON (may be partial)."""
    helper = helper or _default_helper()
    mmaps_dir = mmaps_dir or _default_mmaps()
    if not helper or not mmaps_dir:
        return {"status": "unavailable", "message": "helper or mmaps missing", "waypoints": []}
    req = {
        "op": "route",
        "mmaps_dir": mmaps_dir,
        "request": {
            "map_id": map_id,
            "source": {"map_id": map_id, "x": float(sx), "y": float(sy), "z": float(sz)},
            "target": {"map_id": map_id, "x": float(tx), "y": float(ty), "z": float(tz)},
        },
    }
    try:
        proc = subprocess.run(
            [helper],
            input=json.dumps(req) + "\n",
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
        line = (proc.stdout or "").strip().splitlines()
        if not line:
            return {
                "status": "error",
                "message": proc.stderr.strip() or "empty helper output",
                "waypoints": [],
            }
        return json.loads(line[-1])
    except Exception as exc:  # noqa: BLE001
        return {"status": "error", "message": str(exc), "waypoints": []}


def plan_corridor(
    sx: float,
    sy: float,
    sz: float,
    tx: float,
    ty: float,
    tz: float,
    *,
    map_id: int = 0,
    max_continuations: int = 12,
    min_spacing: float = 6.0,
    helper: Optional[str] = None,
    mmaps_dir: Optional[str] = None,
) -> tuple[list[Point], str]:
    """Plan a full multi-chunk Detour corridor from source to target.

    Returns (waypoints, note). Empty waypoints means Detour failed.
    """
    all_wps: list[Point] = []
    cur = (float(sx), float(sy), float(sz))
    note_parts: list[str] = []
    for leg in range(max_continuations):
        d = query_route_chunk(
            *cur, tx, ty, tz, map_id=map_id, helper=helper, mmaps_dir=mmaps_dir
        )
        status = str(d.get("status") or "")
        msg = str(d.get("message") or "")
        wps = d.get("waypoints") or []
        note_parts.append(f"leg{leg}:{status}:{msg[:60]}")
        if not wps:
            break
        for w in wps:
            pt = (float(w["x"]), float(w["y"]), float(w["z"]))
            if not all_wps or math.hypot(pt[0] - all_wps[-1][0], pt[1] - all_wps[-1][1]) > 0.4:
                all_wps.append(pt)
        last = d.get("last_waypoint") or wps[-1]
        cur = (float(last["x"]), float(last["y"]), float(last["z"]))
        dist_left = math.hypot(cur[0] - tx, cur[1] - ty)
        cont = bool(d.get("continuation_required"))
        if dist_left < 5.0:
            break
        if not cont and status == "ok" and "continue" not in msg.lower():
            if dist_left < 12.0 or "route planned with" in msg:
                break
        if not cont and dist_left > 15.0 and status == "ok":
            # partial chunk without flag — keep walking from end
            continue
        if not cont:
            break
    # ensure corpse is the final point
    if all_wps:
        if math.hypot(all_wps[-1][0] - tx, all_wps[-1][1] - ty) > 2.0:
            all_wps.append((float(tx), float(ty), float(tz)))
        else:
            all_wps[-1] = (float(tx), float(ty), float(tz))
    corridor = subsample_corridor(all_wps, min_spacing=min_spacing)
    return corridor, "; ".join(note_parts)
