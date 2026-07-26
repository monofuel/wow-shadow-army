"""Walk a seat to a destination and report every movement settlement.

Purpose-built for the indoor-navigation work (docs/indoor-navigation-plan.md):
drive one bot toward a fixed world point with plain external `move` actions and
log exactly how each move settles, so guard rejections (`terrain_divergence`,
`floor`, `no_progress`) are captured verbatim for the fork PR evidence package
— and so the same command proves the fix when the patched player walks the
route clean.

Usage (from wow-shadow-army):
    uv run --project ../coworld-vanilla-wow python -m brain.walkto \
        --slot 3 --character Igris --to venya --max-seconds 300

Presets cover the Deathknell acceptance matrix; --dest x,y,z takes raw
coordinates. Movement only: no combat, no quest actions, no items.
"""

from __future__ import annotations

import argparse
import functools
import math
import sys
import time
from typing import Any

# Settlement lines must land in nohup/redirect logs immediately.
print = functools.partial(print, flush=True)  # noqa: A001

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

# Deathknell acceptance-matrix waypoints (docs/indoor-navigation-plan.md).
PRESETS: dict[str, tuple[float, float, float]] = {
    # Just outside the Shadow Grave, on the zombie-field elevation.
    "outside": (1785.0, 1613.0, 96.0),
    # Venya Marthand (creature 5667), imp quest 1470, inside the church.
    "venya": (1836.94, 1633.43, 97.02),
    # Crypt spawn point, for walking back IN (hardest direction).
    "crypt": (1676.35, 1677.45, 121.67),
}


def _dist2d(ax: float, ay: float, bx: float, by: float) -> float:
    return math.hypot(ax - bx, ay - by)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slot", type=int, required=True)
    parser.add_argument("--character", required=True)
    parser.add_argument("--to", choices=sorted(PRESETS), default=None)
    parser.add_argument("--dest", default=None, help="x,y,z overrides --to")
    parser.add_argument("--arrive", type=float, default=5.0)
    # 0 disables the vertical check (2D-only). Multi-floor WMO targets (crypt
    # spawn chamber under the entrance hall) need a band or the walk declares
    # arrival one floor above the goal.
    parser.add_argument("--arrive-z", type=float, default=0.0)
    parser.add_argument("--max-seconds", type=float, default=300.0)
    parser.add_argument("--settle-wait", type=float, default=2.0)
    parser.add_argument("--goal-id", default="walkto")
    args = parser.parse_args()

    if args.dest:
        x, y, z = (float(part) for part in args.dest.split(","))
    elif args.to:
        x, y, z = PRESETS[args.to]
    else:
        parser.error("need --to or --dest")
    label = args.to or args.dest

    started = time.monotonic()
    with NimControlClient(slot=args.slot, timeout_seconds=10.0) as client:
        status = client.status()
        print(f"[walkto] slot={args.slot} phase={status.phase} rev={status.revision}")
        goal = GoalRequest(
            goal_id=args.goal_id,
            goal_kind="leveling",
            selection_mode="external",
            leader_name=args.character,
            party_members=[args.character],
            expected_slot=args.slot,
            expected_revision=status.revision,
        )
        try:
            status = client.submit_goal(goal)
            print(f"[walkto] goal installed rev={status.revision}")
        except NimControlRequestError as exc:
            # An identical goal may already be installed from a previous run.
            print(f"[walkto] goal submit: {exc}")

        moves = failures = 0
        last_pos: tuple[float, float] | None = None
        stall = 0
        while time.monotonic() - started < args.max_seconds:
            frame: Any = client.status(include_environment_frame=True)
            obs = frame.observation
            here = (obs.location.x, obs.location.y, obs.location.z)
            gap = _dist2d(here[0], here[1], x, y)
            z_ok = args.arrive_z <= 0 or abs(here[2] - z) <= args.arrive_z
            if gap <= args.arrive and z_ok:
                print(
                    f"[walkto] ARRIVED {label} gap={gap:.1f}yd "
                    f"pos=({here[0]:.1f},{here[1]:.1f},{here[2]:.1f}) "
                    f"moves={moves} failures={failures}"
                )
                return 0
            if not frame.action_ready:
                time.sleep(0.5)
                continue
            action = FactorizedAction(
                kind="move",
                destination=WorldPoint(map_id=0, x=x, y=y, z=z),
            )
            if not frame.allows_action(action):
                print(f"[walkto] move masked out at gap={gap:.1f}yd; mask closed")
                time.sleep(1.0)
                continue
            try:
                client.select(
                    ActionSelectionRequest(
                        action=action,
                        frame_id=frame.frame_id,
                        observed_tick=frame.observed_tick,
                        expected_slot=args.slot,
                        expected_revision=frame.revision,
                    )
                )
            except NimControlRequestError as exc:
                print(f"[walkto] select rejected: {exc}")
                failures += 1
                time.sleep(1.0)
                continue
            moves += 1
            time.sleep(args.settle_wait)
            try:
                settled = client.last_settlement()
            except Exception as exc:  # noqa: BLE001
                print(f"[walkto] settle read error: {exc}")
                continue
            ok = getattr(settled, "success", None)
            msg = getattr(settled, "message", "")
            reason = getattr(settled, "failure_reason", "")
            if not ok:
                failures += 1
                print(
                    f"[walkto] move FAILED at ({here[0]:.1f},{here[1]:.1f},{here[2]:.1f}) "
                    f"gap={gap:.1f}yd reason={reason!r} msg={msg!r}"
                )
            else:
                print(
                    f"[walkto] move ok gap={gap:.1f}yd "
                    f"pos=({here[0]:.1f},{here[1]:.1f},{here[2]:.1f})"
                )
            if last_pos is not None and _dist2d(*last_pos, here[0], here[1]) < 0.2:
                stall += 1
            else:
                stall = 0
            last_pos = (here[0], here[1])
            if stall >= 20:
                print("[walkto] STUCK: 20 settlements without movement; giving up")
                return 3
        print(f"[walkto] TIMEOUT gap={gap:.1f}yd moves={moves} failures={failures}")
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
