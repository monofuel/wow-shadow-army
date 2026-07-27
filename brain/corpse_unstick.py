#!/usr/bin/env python3
"""Hop a ghost seat toward its corpse with lateral detours on stall.

Fair-play only: plain `move` actions. Used when escort thrashing or long
direct moves report movement_blocked / no goal-relative progress.

Usage:
    uv run --project ../coworld-vanilla-wow-fork \\
      env WOW_SHADOW_UPSTREAM=... python -m brain.corpse_unstick --slot 2
"""

from __future__ import annotations

import argparse
import math
import sys
import time
from typing import Any

from brain.upstream import ensure_upstream_on_path

ensure_upstream_on_path()

from player.sdk.nim_control import (  # noqa: E402
    ActionSelectionRequest,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlRequestError,
    WorldPoint,
)


def _dist2d(ax: float, ay: float, bx: float, by: float) -> float:
    return math.hypot(ax - bx, ay - by)


def _hop_point(
    sx: float,
    sy: float,
    sz: float,
    cx: float,
    cy: float,
    cz: float,
    *,
    hop: float,
    phase: int,
    side: float,
) -> tuple[float, float, float]:
    dx, dy = cx - sx, cy - sy
    d = math.hypot(dx, dy)
    if d < 1.0:
        return cx, cy, cz
    ux, uy = dx / d, dy / d
    lx, ly = -uy, ux
    step = min(hop, d)
    p = phase % 4
    if p == 0:
        ox, oy = 0.0, 0.0
    elif p == 1:
        ox, oy = lx * side, ly * side
    elif p == 2:
        ox, oy = -lx * side, -ly * side
    else:
        ox, oy = lx * side * 0.5, ly * side * 0.5
        step = min(hop * 0.6, d)
    tx = sx + ux * step + ox
    ty = sy + uy * step + oy
    tz = sz + (cz - sz) * (step / d)
    return tx, ty, tz


def run(slot: int, character: str, max_seconds: float, hop: float) -> int:
    started = time.monotonic()
    phase = 0
    stalls = 0
    with NimControlClient(slot=slot, timeout_seconds=10.0) as client:
        status = client.status()
        print(f"[unstick] slot={slot} phase={status.phase} rev={status.revision}", flush=True)
        try:
            client.submit_goal(
                GoalRequest(
                    goal_id=f"corpse-unstick-{slot}",
                    goal_kind="leveling",
                    selection_mode="external",
                    leader_name=character,
                    party_members=[character],
                    expected_slot=slot,
                    expected_revision=status.revision,
                )
            )
        except NimControlRequestError as exc:
            print(f"[unstick] goal: {exc}", flush=True)

        last_gap: float | None = None
        best_gap: float | None = None
        while time.monotonic() - started < max_seconds:
            frame: Any = client.status(include_environment_frame=True)
            obs = frame.observation
            loc = getattr(obs, "location", None)
            lx = float(getattr(loc, "x", 0.0) or 0.0) if loc is not None else 0.0
            ly = float(getattr(loc, "y", 0.0) or 0.0) if loc is not None else 0.0
            lz = float(getattr(loc, "z", 0.0) or 0.0) if loc is not None else 0.0
            is_ghost = bool(getattr(obs, "is_ghost", False))
            is_dead = bool(getattr(obs, "is_dead", False))
            # Goal install / phase=offered can flash empty observation (0,0,0)
            # with both flags false — wait, do not claim victory.
            if not is_ghost and not is_dead:
                if abs(lx) < 1e-3 and abs(ly) < 1e-3:
                    print(
                        f"[unstick] waiting valid frame phase={frame.phase} "
                        f"ready={frame.action_ready}",
                        flush=True,
                    )
                    time.sleep(0.5)
                    continue
                print(
                    f"[unstick] ALIVE pos=({lx:.1f},{ly:.1f},{lz:.1f})",
                    flush=True,
                )
                return 0
            if is_dead and not is_ghost:
                if frame.action_ready:
                    try:
                        client.select(
                            ActionSelectionRequest(
                                action=FactorizedAction(kind="release_spirit"),
                                frame_id=frame.frame_id,
                                observed_tick=frame.observed_tick,
                                expected_slot=slot,
                                expected_revision=frame.revision,
                            )
                        )
                        print("[unstick] release_spirit", flush=True)
                    except NimControlRequestError as exc:
                        print(f"[unstick] release err: {exc}", flush=True)
                time.sleep(0.5)
                continue

            corpse = getattr(obs, "corpse_location", None)
            if not getattr(obs, "corpse_known", False) or corpse is None:
                print("[unstick] no corpse point", flush=True)
                time.sleep(1.0)
                continue

            sx, sy, sz = obs.location.x, obs.location.y, obs.location.z
            cx, cy, cz = corpse.x, corpse.y, corpse.z
            gap = _dist2d(sx, sy, cx, cy)
            can_reclaim = bool(getattr(obs, "can_reclaim_corpse", False))
            print(
                f"[unstick] ghost gap={gap:.1f} reclaim={can_reclaim} "
                f"pos=({sx:.1f},{sy:.1f},{sz:.1f}) phase={phase} stalls={stalls}",
                flush=True,
            )

            if can_reclaim and gap <= 8.0 and frame.action_ready:
                try:
                    client.select(
                        ActionSelectionRequest(
                            action=FactorizedAction(kind="reclaim_corpse"),
                            frame_id=frame.frame_id,
                            observed_tick=frame.observed_tick,
                            expected_slot=slot,
                            expected_revision=frame.revision,
                        )
                    )
                    print("[unstick] reclaim_corpse selected", flush=True)
                except NimControlRequestError as exc:
                    print(f"[unstick] reclaim err: {exc}", flush=True)
                time.sleep(1.0)
                continue

            if not frame.action_ready:
                time.sleep(0.35)
                continue

            # Axis-aligned detour when direct line thrashing: close Y first,
            # then X (avoids diagonal cliff walls common near Tirisfal GY).
            if gap > 25.0 and phase in (1, 2):
                if abs(cy - sy) > abs(cx - sx):
                    tx, ty, tz = sx, sy + max(-hop, min(hop, cy - sy)), sz + 2.0
                else:
                    tx, ty, tz = sx + max(-hop, min(hop, cx - sx)), sy, sz + 2.0
                # phase 2 flips to the other axis.
                if phase == 2:
                    if abs(cy - sy) > abs(cx - sx):
                        tx, ty, tz = sx + max(-hop, min(hop, cx - sx)), sy, sz + 2.0
                    else:
                        tx, ty, tz = sx, sy + max(-hop, min(hop, cy - sy)), sz + 2.0
                reason = f"axis_p{phase}"
            else:
                tx, ty, tz = _hop_point(
                    sx, sy, sz, cx, cy, cz, hop=hop, phase=phase, side=14.0
                )
                reason = f"hop_p{phase}"

            action = FactorizedAction(
                kind="move",
                destination=WorldPoint(map_id=0, x=float(tx), y=float(ty), z=float(tz)),
            )
            if not frame.allows_action(action):
                print("[unstick] move masked", flush=True)
                time.sleep(0.5)
                continue

            print(
                f"[unstick] {reason} -> ({tx:.1f},{ty:.1f},{tz:.1f})",
                flush=True,
            )
            try:
                client.select(
                    ActionSelectionRequest(
                        action=action,
                        frame_id=frame.frame_id,
                        observed_tick=frame.observed_tick,
                        expected_slot=slot,
                        expected_revision=frame.revision,
                    )
                )
            except NimControlRequestError as exc:
                print(f"[unstick] select err: {exc}", flush=True)
                phase = (phase + 1) % 4
                time.sleep(0.5)
                continue

            time.sleep(1.8)
            try:
                frame2: Any = client.status(include_environment_frame=True)
                o2 = frame2.observation
                nx, ny = o2.location.x, o2.location.y
                if getattr(o2, "corpse_known", False) and o2.corpse_location is not None:
                    new_gap = _dist2d(nx, ny, o2.corpse_location.x, o2.corpse_location.y)
                else:
                    new_gap = _dist2d(nx, ny, cx, cy)
            except Exception as exc:  # noqa: BLE001
                print(f"[unstick] re-read err: {exc}", flush=True)
                continue

            if best_gap is None or new_gap < best_gap - 0.5:
                best_gap = new_gap
                stalls = 0
            elif last_gap is not None and new_gap > last_gap - 0.8:
                stalls += 1
                if stalls >= 2:
                    phase = (phase + 1) % 4
                    stalls = 0
                    print(
                        f"[unstick] no gap progress ({new_gap:.1f}) detour phase={phase}",
                        flush=True,
                    )
            else:
                stalls = 0
            last_gap = new_gap

        print("[unstick] TIMEOUT still ghost", flush=True)
        return 2


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--character", required=True)
    p.add_argument("--max-seconds", type=float, default=240.0)
    p.add_argument("--hop", type=float, default=18.0)
    args = p.parse_args(argv)
    return run(args.slot, args.character, args.max_seconds, args.hop)


if __name__ == "__main__":
    sys.exit(main())
