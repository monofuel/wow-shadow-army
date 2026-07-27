"""Fair-play corpse run: follow a multi-leg corridor around terrain into reclaim.

Strategy (explicitly NOT gap-to-corpse thrash):
1. Plan Detour corridor source→corpse (east valley, then north approach).
2. Fall back to hand anchors if Detour fails.
3. Walk waypoint-by-waypoint; on stall, replan from current pose.
4. Reclaim when in range and masked.
"""

from __future__ import annotations

import argparse
import sys
import time
from typing import Any, Callable, Optional

from brain.corpse_recovery_path import (
    Point,
    anchor_corridor_to_corpse,
    gap_2d,
    next_corridor_index,
    should_reclaim,
)
from brain.navmesh_route import plan_corridor
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


def build_corridor(
    sx: float,
    sy: float,
    sz: float,
    cx: float,
    cy: float,
    cz: float,
    log: Callable[[str], None],
) -> list[Point]:
    """Detour corridor first; anchor fallback. Never a single direct hop."""
    corridor, note = plan_corridor(sx, sy, sz, cx, cy, cz, min_spacing=7.0)
    if len(corridor) >= 3:
        log(f"[recov] detour corridor n={len(corridor)} ({note[:120]})")
        return corridor
    corridor = anchor_corridor_to_corpse(sx, sy, sz, cx, cy, cz, min_spacing=8.0)
    log(f"[recov] anchor corridor n={len(corridor)} (detour failed: {note[:80]})")
    return corridor


# Post-reclaim flee path: leave the elevated Deathknell NE death pocket
# (where reclaim often lands in combat) down the approach toward the valley.
POST_RECLAIM_FLEE: list[Point] = [
    (2048.0, 1795.0, 99.0),
    (2040.0, 1760.0, 90.0),
    (2025.0, 1740.0, 88.0),
    (2005.0, 1720.0, 85.0),
    (1985.0, 1700.0, 82.0),
]


def _install_recovery_goal(
    client: NimControlClient,
    slot: int,
    character: str,
    revision: int,
    log: Callable[[str], None],
) -> None:
    """Install a unique external goal so the control plane emits a fresh frame.

    Reusing a stable goal_id can leave a frozen offered environment frame
    (stale alive pose while the character is dead/ghost in the world).
    """
    goal_id = f"corpse-corridor-{slot}-{int(time.time() * 1000)}"
    try:
        client.submit_goal(
            GoalRequest(
                goal_id=goal_id,
                goal_kind="leveling",
                selection_mode="external",
                leader_name=character,
                party_members=[character],
                expected_slot=slot,
                expected_revision=revision,
            )
        )
        log(f"[recov] goal installed id={goal_id} rev={revision}")
    except NimControlRequestError as exc:
        log(f"[recov] goal: {exc}")


def run_seat(
    slot: int,
    character: str,
    *,
    max_seconds: float,
    log: Callable[[str], None],
) -> int:
    started = time.monotonic()
    corridor: list[Point] = []
    leg_i = 0
    stalls = 0
    best_leg_dist: Optional[float] = None
    last_plan_at = 0.0
    last_frame_id: Optional[int] = None
    last_tick: Optional[int] = None
    stuck_frame_polls = 0
    alive_confirm = 0
    flee_i = 0
    did_reclaim = False
    # Safe-enough south of elevated pocket (y < 1760) before declaring done.
    flee_done_y = 1765.0

    with NimControlClient(slot=slot, timeout_seconds=12.0) as client:
        status = client.status()
        log(f"[recov] slot={slot} {character} phase={status.phase} rev={status.revision}")
        log(
            "[recov] strategy=multi-leg corridor (around mountain / elevated approach) "
            "NOT direct-line gap thrash"
        )
        _install_recovery_goal(client, slot, character, status.revision, log)

        while time.monotonic() - started < max_seconds:
            frame: Any = client.status(include_environment_frame=True)
            obs = frame.observation
            loc = obs.location
            sx, sy, sz = float(loc.x), float(loc.y), float(loc.z)
            is_ghost = bool(getattr(obs, "is_ghost", False))
            is_dead = bool(getattr(obs, "is_dead", False))
            fid = int(getattr(frame, "frame_id", 0) or 0)
            tick = int(getattr(frame, "observed_tick", 0) or 0)

            # Frozen offered frames look "alive" forever while MySQL/state show ghost.
            if last_frame_id is not None and fid == last_frame_id and tick == last_tick:
                stuck_frame_polls += 1
            else:
                stuck_frame_polls = 0
            last_frame_id, last_tick = fid, tick

            if stuck_frame_polls >= 4:
                log(
                    f"[recov] frozen frame id={fid} tick={tick}; reinstall goal "
                    f"(polls={stuck_frame_polls})"
                )
                _install_recovery_goal(client, slot, character, frame.revision, log)
                stuck_frame_polls = 0
                alive_confirm = 0
                time.sleep(0.8)
                continue

            if not is_ghost and not is_dead:
                if abs(sx) + abs(sy) < 1e-2:
                    time.sleep(0.4)
                    continue
                hp = getattr(obs, "health", None)
                try:
                    hp_n = float(hp) if hp is not None else 0.0
                except (TypeError, ValueError):
                    hp_n = 0.0
                if hp_n <= 1.0:
                    alive_confirm = 0
                    time.sleep(0.4)
                    continue

                # After reclaim, flee the elevated combat pocket before exit.
                # Declaring ALIVE at the corpse has been dying to re-aggro.
                in_combat = bool(getattr(obs, "in_combat", False))
                need_flee = did_reclaim or sy > flee_done_y or in_combat
                if need_flee and sy > flee_done_y:
                    if flee_i >= len(POST_RECLAIM_FLEE):
                        flee_i = len(POST_RECLAIM_FLEE) - 1
                    wx, wy, wz = POST_RECLAIM_FLEE[flee_i]
                    dist = gap_2d(sx, sy, wx, wy)
                    log(
                        f"[recov] post-reclaim flee leg={flee_i} dist={dist:.1f} "
                        f"hp={hp} combat={in_combat} "
                        f"pos=({sx:.1f},{sy:.1f}) -> ({wx:.0f},{wy:.0f})"
                    )
                    if dist <= 8.0 and flee_i < len(POST_RECLAIM_FLEE) - 1:
                        flee_i += 1
                        continue
                    if frame.action_ready:
                        action = FactorizedAction(
                            kind="move",
                            destination=WorldPoint(
                                map_id=0, x=float(wx), y=float(wy), z=float(wz)
                            ),
                        )
                        if frame.allows_action(action):
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
                                log(f"[recov] flee select err: {exc}")
                    time.sleep(1.2)
                    continue

                alive_confirm += 1
                if alive_confirm >= 2 and hp_n > 1.0:
                    log(
                        f"[recov] ALIVE pos=({sx:.1f},{sy:.1f},{sz:.1f}) "
                        f"hp={hp} combat={in_combat} frame={fid} tick={tick}"
                    )
                    return 0
                log(
                    f"[recov] alive candidate pos=({sx:.1f},{sy:.1f}) hp={hp} "
                    f"confirm={alive_confirm}/2 frame={fid}"
                )
                time.sleep(0.5)
                continue

            alive_confirm = 0
            flee_i = 0

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
                        log("[recov] release_spirit")
                    except NimControlRequestError as exc:
                        log(f"[recov] release err: {exc}")
                time.sleep(0.5)
                continue

            corpse = getattr(obs, "corpse_location", None)
            # Prefer corpse_known, but some frames expose a usable corpse
            # location while the boolean stays false after a stale release.
            if corpse is None:
                log("[recov] no corpse point")
                time.sleep(1.0)
                continue
            cx, cy, cz = float(corpse.x), float(corpse.y), float(corpse.z)
            if abs(cx) + abs(cy) < 1e-2:
                log("[recov] no corpse point (zero loc)")
                time.sleep(1.0)
                continue
            if not getattr(obs, "corpse_known", False):
                log(
                    f"[recov] corpse_known=false; using corpse loc "
                    f"({cx:.1f},{cy:.1f},{cz:.1f})"
                )
            corpse_gap = gap_2d(sx, sy, cx, cy)
            can_reclaim = bool(getattr(obs, "can_reclaim_corpse", False))

            if should_reclaim(can_reclaim=can_reclaim, gap=corpse_gap, reclaim_range=10.0):
                if not frame.action_ready:
                    time.sleep(0.3)
                    continue
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
                    log(f"[recov] reclaim_corpse gap={corpse_gap:.1f}")
                    did_reclaim = True
                    flee_i = 0
                    alive_confirm = 0
                except NimControlRequestError as exc:
                    log(f"[recov] reclaim err: {exc}")
                # Do not sleep long here — next loop must flee immediately.
                time.sleep(0.35)
                continue

            now = time.monotonic()
            if (
                not corridor
                or leg_i >= len(corridor)
                or stalls >= 3
                or (now - last_plan_at) > 90.0
            ):
                corridor = build_corridor(sx, sy, sz, cx, cy, cz, log)
                leg_i = next_corridor_index(sx, sy, corridor, 0, arrive=6.0)
                stalls = 0
                best_leg_dist = None
                last_plan_at = now
                if corridor:
                    log(
                        f"[recov] route legs={len(corridor)} start_leg={leg_i} "
                        f"first=({corridor[min(leg_i, len(corridor)-1)][0]:.0f},"
                        f"{corridor[min(leg_i, len(corridor)-1)][1]:.0f},"
                        f"{corridor[min(leg_i, len(corridor)-1)][2]:.0f}) "
                        f"corpse_gap={corpse_gap:.1f}"
                    )

            if not corridor:
                log("[recov] empty corridor")
                time.sleep(1.0)
                continue

            leg_i = next_corridor_index(sx, sy, corridor, leg_i, arrive=6.0)
            if leg_i >= len(corridor):
                # on last point — nudge to exact corpse
                wx, wy, wz = cx, cy, cz
                leg_label = "corpse"
            else:
                wx, wy, wz = corridor[leg_i]
                leg_label = f"leg{leg_i}/{len(corridor)}"

            leg_dist = gap_2d(sx, sy, wx, wy)
            if best_leg_dist is None or leg_dist < best_leg_dist - 0.5:
                best_leg_dist = leg_dist
                stalls = 0

            log(
                f"[recov] {leg_label} leg_dist={leg_dist:.1f} best_leg={best_leg_dist:.1f} "
                f"corpse_gap={corpse_gap:.1f} stalls={stalls} "
                f"pos=({sx:.1f},{sy:.1f},{sz:.1f}) -> ({wx:.1f},{wy:.1f},{wz:.1f})"
            )

            if not frame.action_ready:
                time.sleep(0.35)
                continue

            action = FactorizedAction(
                kind="move",
                destination=WorldPoint(map_id=0, x=float(wx), y=float(wy), z=float(wz)),
            )
            if not frame.allows_action(action):
                log("[recov] move masked")
                stalls += 1
                time.sleep(0.5)
                continue

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
                log(f"[recov] select err: {exc}")
                stalls += 1
                time.sleep(0.5)
                continue

            time.sleep(2.0)
            try:
                frame2: Any = client.status(include_environment_frame=True)
                o2 = frame2.observation
                nx, ny = float(o2.location.x), float(o2.location.y)
                new_leg = gap_2d(nx, ny, wx, wy)
            except Exception as exc:  # noqa: BLE001
                log(f"[recov] reread err: {exc}")
                stalls += 1
                continue

            if new_leg < 6.0:
                log(f"[recov] arrived {leg_label}")
                leg_i += 1
                best_leg_dist = None
                stalls = 0
            elif best_leg_dist is not None and new_leg < best_leg_dist - 0.8:
                best_leg_dist = new_leg
                stalls = 0
                log(f"[recov] progress on {leg_label} -> {new_leg:.1f}")
            else:
                stalls += 1
                if stalls >= 3:
                    log(f"[recov] stall on {leg_label}; will replan corridor")

        log("[recov] TIMEOUT still ghost")
        return 2


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--character", required=True)
    p.add_argument("--max-seconds", type=float, default=900.0)
    args = p.parse_args(argv)

    def log(msg: str) -> None:
        print(msg, flush=True)

    return run_seat(args.slot, args.character, max_seconds=args.max_seconds, log=log)


if __name__ == "__main__":
    sys.exit(main())
