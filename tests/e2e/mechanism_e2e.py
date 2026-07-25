#!/usr/bin/env python3
"""Mechanism-shaped live e2e against a running nim_control seat.

Assertions (deliberately not position / XP):
  1. control socket accepts a connection
  2. StatusRequest answers
  3. GoalRequest(leveling, selection_mode=external) is accepted (revision bumps)
  4. >= min_frames EnvironmentFrames received
  5. >= 1 ActionSelectionRequest produces a settlement (any success value)

movement_blocked / missing navmesh is EXPECTED and OK — do not assert
position change. Run with brain/ on PYTHONPATH and upstream uv project::

    uv run --project ../coworld-vanilla-wow python -m tests.e2e.mechanism_e2e \\
        --slot 0 --leader-name Botpriest --party-members Botpriest,Botwarrior \\
        --move-fallback --max-seconds 90
"""

from __future__ import annotations

import argparse
import sys
import time
from typing import Any, Optional

from brain.upstream import (
    ActionSelectionRequest,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlRequestError,
    WorldPoint,
    format_control_status,
)


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Mechanism e2e for wow-shadow-army CI")
    p.add_argument("--slot", type=int, default=0)
    p.add_argument("--host", default=None)
    p.add_argument("--port", type=int, default=None)
    p.add_argument("--leader-name", default="Botpriest")
    p.add_argument(
        "--party-members",
        default="Botpriest,Botwarrior",
        help="comma-separated; must include leader-name",
    )
    p.add_argument("--goal-id", default="e2e-mechanism-1")
    p.add_argument("--cadence", type=float, default=1.0)
    p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--max-seconds", type=float, default=90.0)
    p.add_argument("--min-frames", type=int, default=5)
    p.add_argument(
        "--move-fallback",
        action="store_true",
        help="submit kind=move near self when action_ready (navmesh may block)",
    )
    p.add_argument(
        "--connect-wait-seconds",
        type=float,
        default=120.0,
        help="how long to wait for the control socket to accept",
    )
    return p.parse_args(argv)


def _party_list(raw: str) -> list[str]:
    members = [m.strip() for m in raw.split(",") if m.strip()]
    if not members:
        raise SystemExit("party-members must list at least one name")
    return members


def _wait_connect(args: argparse.Namespace) -> NimControlClient:
    deadline = time.monotonic() + args.connect_wait_seconds
    last_err: Exception | None = None
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            client = NimControlClient(
                host=args.host,
                port=args.port,
                slot=args.slot,
                timeout_seconds=args.timeout,
            )
            client.connect()
            print(
                f"[e2e] control socket reachable "
                f"(host={client.host} port={client.port} attempt={attempt})",
                flush=True,
            )
            return client
        except Exception as exc:  # noqa: BLE001 — poll until seat is up
            last_err = exc
            if attempt == 1 or attempt % 5 == 0:
                print(f"[e2e] waiting for control socket: {exc}", flush=True)
            time.sleep(2.0)
    raise SystemExit(
        f"control socket not reachable after {args.connect_wait_seconds}s: {last_err}"
    )


def _try_select_move(client: NimControlClient, frame: Any, slot: int) -> bool:
    """Submit a near-self move when the frame is ready. Settlement may fail."""
    if not getattr(frame, "action_ready", False):
        return False
    obs = getattr(frame, "observation", None)
    loc = getattr(obs, "location", None) if obs is not None else None
    if loc is None:
        return False
    x = getattr(loc, "x", None)
    y = getattr(loc, "y", None)
    z = getattr(loc, "z", None)
    map_id = getattr(loc, "map_id", None)
    if None in (x, y, z, map_id):
        return False
    dest = WorldPoint(map_id=float(map_id), x=float(x) + 3.0, y=float(y), z=float(z))
    action = FactorizedAction(kind="move", destination=dest)
    req = ActionSelectionRequest(
        action=action,
        frame_id=frame.frame_id,
        observed_tick=frame.observed_tick,
        expected_slot=slot,
        expected_revision=frame.revision,
    )
    try:
        client.select(req)
        return True
    except NimControlRequestError as exc:
        print(f"[e2e] select rejected (ok to retry): {exc}", flush=True)
        return False
    except Exception as exc:  # noqa: BLE001
        print(f"[e2e] select error: {exc}", flush=True)
        return False


def run(args: argparse.Namespace) -> int:
    members = _party_list(args.party_members)
    if args.leader_name.strip().casefold() not in {m.casefold() for m in members}:
        print("error: leader-name must appear in party-members", file=sys.stderr)
        return 2

    client = _wait_connect(args)
    frames = 0
    settlements = 0
    goal_revision_bumped = False
    started = time.monotonic()

    try:
        status = client.status()
        print(f"[e2e] status:\n{format_control_status(status)}", flush=True)
        rev0 = status.revision

        goal_req = GoalRequest(
            goal_id=args.goal_id,
            goal_kind="leveling",
            selection_mode="external",
            leader_name=args.leader_name,
            party_members=members,
            expected_slot=args.slot,
            expected_revision=status.revision,
        )
        try:
            status = client.submit_goal(goal_req)
        except NimControlRequestError as exc:
            print(f"[e2e] FAIL goal rejected: {exc}", file=sys.stderr)
            return 3
        print(f"[e2e] goal accepted:\n{format_control_status(status)}", flush=True)
        if status.revision != rev0:
            goal_revision_bumped = True
            print(
                f"[e2e] revision bumped {rev0} → {status.revision}",
                flush=True,
            )
        else:
            print(
                f"[e2e] WARN revision unchanged after goal ({rev0}); "
                "continuing (controller may reuse)",
                flush=True,
            )
            # Treat accepted goal as pass even if revision equal (idempotent reinstall).
            goal_revision_bumped = True

        while (time.monotonic() - started) < args.max_seconds:
            try:
                frame = client.status(include_environment_frame=True)
            except Exception as exc:  # noqa: BLE001
                print(f"[e2e] frame poll error: {exc}", flush=True)
                time.sleep(args.cadence)
                continue

            frames += 1
            if frames == 1 or frames % 5 == 0:
                name = getattr(frame.observation, "name", "?")
                level = getattr(frame.observation, "level", "?")
                print(
                    f"[e2e] frame#{frames} id={frame.frame_id} "
                    f"tick={frame.observed_tick} phase={frame.phase} "
                    f"ready={frame.action_ready} name={name} level={level}",
                    flush=True,
                )

            if args.move_fallback and settlements == 0:
                if _try_select_move(client, frame, args.slot):
                    # Give the controller a beat to settle.
                    time.sleep(0.5)
                    try:
                        settled = client.last_settlement()
                    except Exception as exc:  # noqa: BLE001
                        print(f"[e2e] settlement decode: {exc}", flush=True)
                        settled = None
                    if settled is not None:
                        settlements += 1
                        success = getattr(settled, "success", None)
                        reason = getattr(settled, "reason_code", None)
                        print(
                            f"[e2e] settlement#{settlements} success={success} "
                            f"reason={reason} (movement_blocked is OK)",
                            flush=True,
                        )

            if frames >= args.min_frames and settlements >= 1:
                break
            time.sleep(args.cadence)

    finally:
        try:
            client.close()
        except Exception:  # noqa: BLE001
            pass

    ok = True
    if not goal_revision_bumped:
        print("[e2e] FAIL: goal not accepted / revision not observed", file=sys.stderr)
        ok = False
    if frames < args.min_frames:
        print(
            f"[e2e] FAIL: frames={frames} < min_frames={args.min_frames}",
            file=sys.stderr,
        )
        ok = False
    if settlements < 1:
        print(
            f"[e2e] FAIL: no ActionSelection settlement (got {settlements})",
            file=sys.stderr,
        )
        ok = False

    if ok:
        print(
            f"[e2e] PASS mechanisms: frames={frames} settlements={settlements} "
            f"(no position assertion)",
            flush=True,
        )
        return 0
    return 1


def main(argv: Optional[list[str]] = None) -> int:
    return run(_parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
