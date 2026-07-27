#!/usr/bin/env python3
"""Shadow supervisor CLI — first live brain for wow-shadow-army.

Installs a leveling goal with selection_mode=external, polls environment
frames, projects them for follow_leader, runs the Lua tool, and submits
FactorizedAction selections.

Usage (runtime deps via upstream uv project)::

    uv run --project ../coworld-vanilla-wow python -m brain.shadow \\
        --slot 0 --leader-name Botpriest --party-members Botpriest,Botwarrior

Fallback when not in a party (no follow mask): ``--move-fallback`` walks
toward the leader unit with kind=move destinations so the settle loop is
still demonstrable before party formation works.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from brain import frame_projection, intent_mapping, lua_runner
from brain.accept_invite import should_accept_invite
from brain.upstream import (
    ActionSelectionRequest,
    ActionSettled,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlRequestError,
    WorldPoint,
    format_control_status,
    format_environment_frame,
)


def _safe_last_settlement(client: NimControlClient) -> Any:
    """Fetch ActionSettled; tolerate rare success/reason_code disagreements."""
    try:
        return client.last_settlement()
    except Exception as exc:  # noqa: BLE001 — upstream ValidationError surface
        return {"error": f"settlement_decode: {exc}"}


def _corpse_detour_destination(
    self_loc: dict[str, float],
    dest: dict[str, float],
    *,
    phase: int,
    hop: float = 18.0,
    side: float = 14.0,
) -> Optional[dict[str, float]]:
    """Nudge a stuck ghost off a blocked line toward the corpse.

    phase 0/2: left/right of the toward-corpse vector
    phase 1/3: reverse-ish backstep then side, to unstick wall hugging
    """
    import math

    sx = float(self_loc["x"])
    sy = float(self_loc["y"])
    sz = float(self_loc.get("z") or dest.get("z") or 0.0)
    dx = float(dest["x"]) - sx
    dy = float(dest["y"]) - sy
    d = math.hypot(dx, dy)
    if d < 1.0:
        return None
    ux, uy = dx / d, dy / d
    # Perpendicular (left = (-uy, ux)).
    lx, ly = -uy, ux
    p = int(phase) % 4
    if p == 0:
        ox, oy = lx * side, ly * side
        fx, fy = ux * hop, uy * hop
    elif p == 1:
        ox, oy = -lx * side, -ly * side
        fx, fy = ux * hop, uy * hop
    elif p == 2:
        ox, oy = lx * side, ly * side
        fx, fy = -ux * (hop * 0.5), -uy * (hop * 0.5)
    else:
        ox, oy = -lx * side, -ly * side
        fx, fy = -ux * (hop * 0.5), -uy * (hop * 0.5)
    return {
        "map_id": float(dest.get("map_id") or self_loc.get("map_id") or 0),
        "x": sx + fx + ox,
        "y": sy + fy + oy,
        "z": float(dest.get("z") or sz),
    }


_REPO_ROOT = Path(__file__).resolve().parents[1]
_DEFAULT_LOG_DIR = _REPO_ROOT / "local_data" / "brain-logs"


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Shadow brain supervisor (follow_leader)")
    p.add_argument("--slot", type=int, default=0, help="nim_control runtime slot")
    p.add_argument("--host", default=None, help="control host (default env/127.0.0.1)")
    p.add_argument("--port", type=int, default=None, help="control port (default 41114+slot)")
    p.add_argument("--leader-name", required=True, help="party leader character name")
    p.add_argument(
        "--party-members",
        required=True,
        help="comma-separated party roster; must include leader-name",
    )
    p.add_argument("--goal-id", default="shadow-follow-1")
    p.add_argument("--cadence", type=float, default=1.0, help="loop seconds (~1s)")
    p.add_argument("--timeout", type=float, default=5.0, help="socket timeout seconds")
    p.add_argument(
        "--move-fallback",
        action="store_true",
        help="when follow is unavailable, map move_to_unit → move near leader unit",
    )
    p.add_argument(
        "--log-dir",
        type=Path,
        default=_DEFAULT_LOG_DIR,
        help="JSONL log directory (gitignored under local_data/)",
    )
    p.add_argument(
        "--capture-frames",
        type=int,
        default=0,
        help="save first N raw EnvironmentFrame msgpack payloads under tests/fixtures/frames/",
    )
    p.add_argument(
        "--max-seconds",
        type=float,
        default=0.0,
        help="optional run budget (0 = until Ctrl-C)",
    )
    p.add_argument(
        "--tool",
        default="follow_leader",
        help="Lua tool name (default follow_leader; use escort_leader for follow+assist)",
    )
    p.add_argument(
        "--accept-from",
        default="",
        help="comma-separated inviter allowlist; when set, accept_party from "
        "those names is preferred over escort intents (default empty; "
        "make escort sets Murist)",
    )
    p.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="log every loop tick. Default is quiet: startup + failures only. "
        "JSONL is always full.",
    )
    return p.parse_args(argv)


def _say(verbose: bool, msg: str, *, force: bool = False) -> None:
    """Stdout logger. Quiet by default; force for failures / lifecycle."""
    if force or verbose:
        print(msg, flush=True)


def _party_list(raw: str) -> list[str]:
    members = [m.strip() for m in raw.split(",") if m.strip()]
    if not members:
        raise SystemExit("party-members must list at least one name")
    return members


def _accept_allowlist(raw: str) -> list[str]:
    return [n.strip() for n in raw.split(",") if n.strip()]


class _JsonlLogger:
    def __init__(self, log_dir: Path) -> None:
        log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.path = log_dir / f"shadow-{stamp}.jsonl"
        self._fp = self.path.open("a", encoding="utf-8")

    def write(self, row: dict[str, Any]) -> None:
        self._fp.write(json.dumps(row, default=str) + "\n")
        self._fp.flush()

    def close(self) -> None:
        self._fp.close()


def _save_raw_frame_msgpack(client: NimControlClient, path: Path) -> None:
    """Capture one EnvironmentFrame as raw msgpack bytes via private wire read.

    We re-request status(include_environment_frame=True) and serialize the
    model back with msgpack for fixtures (upstream already decoded). Prefer
    model_dump for stable offline fixtures.
    """
    import msgpack

    frame = client.status(include_environment_frame=True)
    payload = frame.model_dump(mode="python")
    path.parent.mkdir(parents=True, exist_ok=True)
    # Also write JSON for human inspection; .bin is msgpack of the dumped dict.
    path.write_bytes(msgpack.packb(payload, use_bin_type=True))
    path.with_suffix(".json").write_text(
        json.dumps(payload, indent=2, default=str)[:200_000],
        encoding="utf-8",
    )


def _destination_near(unit: dict[str, Any], offset: float = 3.0) -> Optional[dict[str, float]]:
    if unit.get("x") is None or unit.get("y") is None:
        return None
    z = unit.get("z")
    map_id = unit.get("map_id")
    if z is None or map_id is None:
        return None
    return {
        "map_id": float(map_id),
        "x": float(unit["x"]) + offset,
        "y": float(unit["y"]),
        "z": float(z),
    }


def run(args: argparse.Namespace) -> int:
    members = _party_list(args.party_members)
    if args.leader_name.strip().casefold() not in {m.casefold() for m in members}:
        raise SystemExit("leader-name must appear in party-members")

    logger = _JsonlLogger(args.log_dir)
    verbose = bool(args.verbose)
    stop = {"flag": False}
    # Throttle: only re-print SELECT lines when kind/reason changes.
    last_select_sig = {"s": ""}

    def _handle_sig(_signum: int, _frame: Any) -> None:
        stop["flag"] = True
        print("\n[shadow] Ctrl-C — shutting down cleanly", flush=True)

    signal.signal(signal.SIGINT, _handle_sig)
    signal.signal(signal.SIGTERM, _handle_sig)
    fixtures_dir = _REPO_ROOT / "tests" / "fixtures" / "frames"
    frames_captured = 0
    started = time.monotonic()
    last_pos: Optional[dict[str, float]] = None
    # Throttle identical failure lines (assist-reject spam was drowning logs).
    last_fail_sig = {"s": "", "n": 0}

    _say(
        verbose,
        f"[shadow] slot={args.slot} leader={args.leader_name} tool={args.tool} "
        f"jsonl={logger.path.name}",
        force=True,
    )

    try:
        with NimControlClient(
            host=args.host,
            port=args.port,
            slot=args.slot,
            timeout_seconds=args.timeout,
        ) as client:
            status = client.status()
            _say(verbose, f"[shadow] status:\n{format_control_status(status)}")
            logger.write(
                {
                    "ts": _utc_iso(),
                    "event": "status",
                    "revision": status.revision,
                    "phase": status.phase,
                    "goal": status.goal.model_dump() if status.goal else None,
                }
            )

            # Install external leveling goal (no follow goal exists).
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
                _say(
                    verbose,
                    f"[shadow] goal accepted rev={status.revision} phase={status.phase}",
                    force=True,
                )
                logger.write(
                    {
                        "ts": _utc_iso(),
                        "event": "goal_accepted",
                        "goal_id": args.goal_id,
                        "revision": status.revision,
                        "phase": status.phase,
                    }
                )
            except NimControlRequestError as exc:
                _say(verbose, f"[shadow] goal rejected: {exc}", force=True)
                logger.write(
                    {
                        "ts": _utc_iso(),
                        "event": "goal_rejected",
                        "error": str(exc),
                    }
                )
                return 2

            loop_i = 0
            # Ghost corpse-run stuck recovery: after repeated movement_blocked,
            # apply lateral detours around the hop line (WMO/terrain walls).
            # Also skip stock recommended full-corpse moves when they settle ok
            # but leave the ghost parked (false-success graph advances).
            death_nav: dict[str, Any] = {
                "fails": 0,
                "phase": 0,
                "skip_stock_rec": 0,
                "last_xy": None,
                "best_gap": None,
            }
            while not stop["flag"]:
                if args.max_seconds > 0 and (time.monotonic() - started) >= args.max_seconds:
                    _say(verbose, "[shadow] max-seconds reached", force=True)
                    break

                loop_i += 1
                row: dict[str, Any] = {"ts": _utc_iso(), "event": "tick", "i": loop_i}

                try:
                    frame = client.status(include_environment_frame=True)
                except Exception as exc:  # noqa: BLE001 — log and keep looping
                    _say(verbose, f"[shadow] frame error: {exc}", force=True)
                    row["error"] = str(exc)
                    logger.write(row)
                    time.sleep(args.cadence)
                    continue

                if args.capture_frames > 0 and frames_captured < args.capture_frames:
                    try:
                        out = fixtures_dir / f"frame_{frames_captured:02d}.bin"
                        # Re-use the already-decoded frame: pack model_dump.
                        import msgpack

                        payload = frame.model_dump(mode="python")
                        out.parent.mkdir(parents=True, exist_ok=True)
                        out.write_bytes(msgpack.packb(payload, use_bin_type=True))
                        # Trimmed JSON companion for humans (first level keys + obs summary).
                        summary = {
                            "frame_id": frame.frame_id,
                            "observed_tick": frame.observed_tick,
                            "revision": frame.revision,
                            "phase": frame.phase,
                            "goal_id": frame.goal_id,
                            "action_ready": frame.action_ready,
                            "player": {
                                "name": frame.observation.name,
                                "level": frame.observation.level,
                                "location": frame.observation.location.model_dump(),
                            },
                            "party": frame.observation.party.model_dump(),
                            "entity_count": len(frame.bindings.entities),
                            "entities": [
                                {
                                    "index": e.index,
                                    "kind": e.kind,
                                    "name": e.name,
                                    "alive": e.alive,
                                }
                                for e in frame.bindings.entities[:16]
                            ],
                        }
                        out.with_suffix(".summary.json").write_text(
                            json.dumps(summary, indent=2, default=str),
                            encoding="utf-8",
                        )
                        frames_captured += 1
                        _say(verbose, f"[shadow] captured fixture {out}", force=True)
                    except Exception as exc:  # noqa: BLE001
                        _say(verbose, f"[shadow] fixture capture failed: {exc}", force=True)

                if args.tool == "escort_leader":
                    projection = frame_projection.project_for_escort_leader(frame)
                else:
                    projection = frame_projection.project_for_follow_leader(frame)
                self_loc = frame_projection.project_self_location(frame)
                row["frame_id"] = frame.frame_id
                row["observed_tick"] = frame.observed_tick
                row["revision"] = frame.revision
                row["phase"] = frame.phase
                row["action_ready"] = frame.action_ready
                row["projection"] = projection
                row["self"] = self_loc
                row["party_in_group"] = frame.observation.party.in_group

                if last_pos and self_loc:
                    row["delta_xy"] = {
                        "dx": self_loc["x"] - last_pos["x"],
                        "dy": self_loc["y"] - last_pos["y"],
                    }
                if self_loc:
                    last_pos = dict(self_loc)

                # Fair-play corpse run: while dead/ghost, prefer the stock
                # recommended recovery action (release / move:corpse / reclaim /
                # spirit healer). Selecting the exact recommended action inherits
                # private nav lowering (step limits, overhead) that bare
                # destination moves lack — needed when ghosts path WMO terrain.
                obs = frame.observation
                is_casualty = bool(getattr(obs, "is_dead", False) or getattr(obs, "is_ghost", False))
                if is_casualty:
                    row["casualty"] = {
                        "is_dead": bool(getattr(obs, "is_dead", False)),
                        "is_ghost": bool(getattr(obs, "is_ghost", False)),
                        "can_reclaim": bool(getattr(obs, "can_reclaim_corpse", False)),
                    }
                    rec = frame.recommended_action
                    death_kinds = {
                        "release_spirit",
                        "reclaim_corpse",
                        "move",
                        "spirit_healer_resurrect",
                        "accept_resurrect",
                    }
                    skip_stock = int(death_nav.get("skip_stock_rec") or 0) > 0
                    if skip_stock:
                        death_nav["skip_stock_rec"] = max(
                            0, int(death_nav.get("skip_stock_rec") or 0) - 1
                        )
                    use_stock = (
                        not skip_stock
                        and frame.action_ready
                        and rec is not None
                        and rec.kind in death_kinds
                        and frame.allows_action(rec)
                    )
                    # Stock death "move" aims straight at the corpse (false
                    # success on mountain). Skip stock *move*; fall through to
                    # corridor-rewritten move_to_corpse. Keep stock reclaim/release.
                    if use_stock and rec is not None and rec.kind == "move":
                        use_stock = False
                    if use_stock:
                        try:
                            client.select(
                                ActionSelectionRequest(
                                    action=rec,
                                    frame_id=frame.frame_id,
                                    observed_tick=frame.observed_tick,
                                    expected_slot=args.slot,
                                    expected_revision=frame.revision,
                                )
                            )
                            settlement = _safe_last_settlement(client)
                            row["intent"] = {
                                "kind": rec.kind,
                                "reason": "stock_death_recovery_recommended",
                            }
                            row["settlement"] = (
                                settlement.model_dump()
                                if isinstance(settlement, ActionSettled)
                                else settlement
                            )
                            _say(
                                verbose,
                                f"[shadow] #{loop_i} DEATH-REC {rec.kind} "
                                f"settlement={row.get('settlement')} pos={self_loc}",
                                force=True,
                            )
                            if isinstance(settlement, ActionSettled) and rec.kind == "move":
                                import math

                                ok = bool(settlement.success)
                                msg = str(settlement.message or "")
                                code = str(settlement.reason_code or "")
                                stuck_msg = (
                                    "no adjacent route" in msg.lower()
                                    or "no goal-relative" in msg.lower()
                                    or "blocked" in code.lower()
                                )
                                # Gap-to-corpse is the truth — tiny oscillates look
                                # like "moved" on xy deltas but never close the run.
                                try:
                                    frame2 = client.status(include_environment_frame=True)
                                    loc2 = frame2.observation.location
                                    cur_xy = (float(loc2.x), float(loc2.y))
                                    cl = getattr(frame2.observation, "corpse_location", None)
                                    if cl is not None and getattr(
                                        frame2.observation, "corpse_known", False
                                    ):
                                        gap = math.hypot(
                                            float(loc2.x) - float(cl.x),
                                            float(loc2.y) - float(cl.y),
                                        )
                                    else:
                                        gap = None
                                except Exception:  # noqa: BLE001
                                    cur_xy = (
                                        (float(self_loc["x"]), float(self_loc["y"]))
                                        if self_loc
                                        else None
                                    )
                                    gap = None
                                best = death_nav.get("best_gap")
                                gap_improved = (
                                    gap is not None
                                    and (best is None or gap < float(best) - 2.0)
                                )
                                if gap_improved and gap is not None:
                                    death_nav["best_gap"] = gap
                                    death_nav["fails"] = 0
                                elif (not ok) or stuck_msg or not gap_improved:
                                    death_nav["fails"] = int(death_nav.get("fails") or 0) + 1
                                    death_nav["phase"] = (
                                        int(death_nav.get("phase") or 0) + 1
                                    ) % 4
                                    # Next ticks: skip stock, force hop/detour path.
                                    death_nav["skip_stock_rec"] = 12
                                    _say(
                                        verbose,
                                        f"[shadow] #{loop_i} death-rec stuck "
                                        f"fails={death_nav['fails']} "
                                        f"phase={death_nav['phase']} "
                                        f"gap={gap} best={best} ok={ok}",
                                        force=True,
                                    )
                                if cur_xy is not None:
                                    death_nav["last_xy"] = cur_xy
                            elif rec.kind != "move":
                                death_nav["fails"] = 0
                        except NimControlRequestError as exc:
                            row["select_error"] = str(exc)
                            _say(verbose, f"[shadow] #{loop_i} death-rec error: {exc}", force=True)
                            death_nav["skip_stock_rec"] = 4
                        logger.write(row)
                        time.sleep(args.cadence)
                        continue
                    # Fall through to Lua death intents (release / hop / reclaim).

                # Invite accept beats escort: one standing process per seat
                # (no separate party_butler fighting the same socket).
                allowlist = _accept_allowlist(args.accept_from)
                party_obs = frame.observation.party
                if should_accept_invite(
                    bool(party_obs.invite_pending),
                    str(party_obs.invite_from or ""),
                    allowlist,
                ):
                    intent = {
                        "kind": "accept_party",
                        "reason": f"invite_from:{party_obs.invite_from}",
                    }
                    row["intent"] = intent
                    row["auto_accept"] = True
                    prefer_dest = None
                    mapped = intent_mapping.map_intent(intent)
                    row["mapped"] = {
                        "kind": mapped.kind,
                        "target": mapped.target,
                        "destination": mapped.destination,
                        "skip": mapped.skip,
                        "reason": mapped.reason,
                    }
                    settlement = None
                    if (
                        not mapped.skip
                        and mapped.kind is not None
                        and frame.action_ready
                    ):
                        kwargs = intent_mapping.mapped_to_factorized_kwargs(mapped)
                        assert kwargs is not None
                        action = FactorizedAction(**kwargs)
                        if not frame.allows_action(action):
                            row["select_skipped"] = "mask_rejects"
                            _say(
                                verbose,
                                f"[shadow] #{loop_i} accept_party mask rejects",
                                force=True,
                            )
                        else:
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
                                settlement = _safe_last_settlement(client)
                                if isinstance(settlement, ActionSettled):
                                    row["settlement"] = settlement.model_dump()
                                    _say(
                                        verbose,
                                        f"[shadow] #{loop_i} ACCEPT "
                                        f"ok={settlement.success} "
                                        f"msg={settlement.message!r}",
                                        force=True,
                                    )
                                else:
                                    row["settlement"] = settlement
                                    _say(
                                        verbose,
                                        f"[shadow] #{loop_i} ACCEPT settled={settlement}",
                                        force=True,
                                    )
                            except NimControlRequestError as exc:
                                row["select_error"] = str(exc)
                                _say(verbose, f"[shadow] accept error: {exc}", force=True)
                    logger.write(row)
                    time.sleep(args.cadence)
                    continue

                try:
                    intent = lua_runner.decide(args.tool, projection)
                except Exception as exc:  # noqa: BLE001
                    _say(verbose, f"[shadow] lua error: {exc}", force=True)
                    row["lua_error"] = str(exc)
                    logger.write(row)
                    time.sleep(args.cadence)
                    continue

                row["intent"] = intent

                prefer_dest = None
                follow_legal = False
                if intent and intent.get("kind") == "move_to_unit":
                    unit_id = intent.get("unit_id")
                    if unit_id and frame.allows_action(
                        FactorizedAction(kind="follow", target=int(unit_id))
                    ):
                        follow_legal = True
                    if args.move_fallback and not follow_legal:
                        unit = frame_projection.find_unit_by_name(frame, args.leader_name)
                        prefer_dest = _destination_near(unit) if unit else None
                # Demo loop without party/leader in sight: still exercise select
                # by walking a few yards from self when --move-fallback is set
                # and the tool held (leader not visible).
                if (
                    args.move_fallback
                    and prefer_dest is None
                    and intent
                    and intent.get("kind") == "hold"
                    and self_loc
                    and "z" in self_loc
                    and "map_id" in self_loc
                ):
                    # Orbit a fixed offset so each run tries a real move.
                    prefer_dest = {
                        "map_id": float(self_loc["map_id"]),
                        "x": float(self_loc["x"]) + 8.0,
                        "y": float(self_loc["y"]) + 2.0,
                        "z": float(self_loc["z"]),
                    }
                    intent = {
                        "kind": "move_to_unit",
                        "unit_id": 0,
                        "reason": "move_fallback_self_offset",
                    }
                    row["intent_overridden"] = intent

                mapped = intent_mapping.map_intent(
                    intent, prefer_move_destination=prefer_dest
                )
                # Ghost moves: rewrite destination onto multi-leg Detour/anchor
                # corridor (around mountain → elevated approach → corpse). Never
                # leave a bare long direct-to-corpse dest as the only plan.
                if (
                    is_casualty
                    and mapped.kind == "move"
                    and mapped.destination is not None
                    and self_loc is not None
                    and intent
                    and str(intent.get("kind") or "")
                    in ("move_to_corpse", "move_to_corpse_hop")
                ):
                    try:
                        from brain.corpse_recovery_path import next_corridor_index
                        from brain.navmesh_route import plan_corridor

                        dest = mapped.destination
                        corridor, cnote = plan_corridor(
                            float(self_loc["x"]),
                            float(self_loc["y"]),
                            float(self_loc.get("z") or dest.get("z") or 0),
                            float(dest["x"]),
                            float(dest["y"]),
                            float(dest["z"]),
                            min_spacing=7.0,
                        )
                        if len(corridor) < 3:
                            from brain.corpse_recovery_path import (
                                anchor_corridor_to_corpse,
                            )

                            corridor = anchor_corridor_to_corpse(
                                float(self_loc["x"]),
                                float(self_loc["y"]),
                                float(self_loc.get("z") or 0),
                                float(dest["x"]),
                                float(dest["y"]),
                                float(dest["z"]),
                            )
                            cnote = "anchor_fallback"
                        leg = next_corridor_index(
                            float(self_loc["x"]),
                            float(self_loc["y"]),
                            corridor,
                            0,
                            arrive=6.0,
                        )
                        if leg >= len(corridor):
                            leg = len(corridor) - 1
                        wx, wy, wz = corridor[leg]
                        mapped = intent_mapping.MappedAction(
                            kind="move",
                            target=0,
                            destination={
                                "map_id": float(dest.get("map_id") or 0),
                                "x": float(wx),
                                "y": float(wy),
                                "z": float(wz),
                            },
                            skip=False,
                            reason=f"corridor_leg_{leg}/{len(corridor)}",
                        )
                        row["corridor"] = {
                            "leg": leg,
                            "n": len(corridor),
                            "note": cnote[:160],
                            "dest": mapped.destination,
                        }
                    except Exception as exc:  # noqa: BLE001
                        row["corridor_error"] = str(exc)
                row["mapped"] = {
                    "kind": mapped.kind,
                    "target": mapped.target,
                    "spell": mapped.spell,
                    "destination": mapped.destination,
                    "skip": mapped.skip,
                    "reason": mapped.reason,
                }

                settlement = None
                if not mapped.skip and mapped.kind is not None and frame.action_ready:
                    kwargs = intent_mapping.mapped_to_factorized_kwargs(mapped)
                    assert kwargs is not None
                    if "destination" in kwargs and kwargs["destination"] is not None:
                        kwargs["destination"] = WorldPoint(**kwargs["destination"])
                    action = FactorizedAction(**kwargs)
                    if not frame.allows_action(action):
                        row["select_skipped"] = "mask_rejects"
                        _say(
                            verbose,
                            f"[shadow] #{loop_i} intent={intent} mapped={mapped.kind} "
                            f"mask rejects action",
                        )
                    else:
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
                            settlement = _safe_last_settlement(client)
                            if isinstance(settlement, ActionSettled):
                                row["settlement"] = settlement.model_dump()
                                sig = (
                                    f"{mapped.kind}:{settlement.success}:"
                                    f"{settlement.reason_code}"
                                )
                                last_select_sig["s"] = sig
                                # Quiet default: only failures, and throttle
                                # identical reject spam (assist no-target).
                                if not settlement.success:
                                    fail_sig = (
                                        f"{mapped.kind}:{settlement.reason_code}:"
                                        f"{settlement.message}"
                                    )
                                    if fail_sig == last_fail_sig["s"]:
                                        last_fail_sig["n"] += 1
                                        if last_fail_sig["n"] in (1, 10, 50) or (
                                            last_fail_sig["n"] % 100 == 0
                                        ):
                                            _say(
                                                verbose,
                                                f"[shadow] #{loop_i} SELECT "
                                                f"{mapped.kind} FAIL "
                                                f"x{last_fail_sig['n']} "
                                                f"reason={settlement.reason_code} "
                                                f"msg={settlement.message!r}",
                                                force=True,
                                            )
                                    else:
                                        last_fail_sig["s"] = fail_sig
                                        last_fail_sig["n"] = 1
                                        _say(
                                            verbose,
                                            f"[shadow] #{loop_i} SELECT "
                                            f"{mapped.kind} FAIL "
                                            f"reason={settlement.reason_code} "
                                            f"msg={settlement.message!r}",
                                            force=True,
                                        )
                                else:
                                    last_fail_sig["s"] = ""
                                    last_fail_sig["n"] = 0
                                    _say(
                                        verbose,
                                        f"[shadow] #{loop_i} SELECT {mapped.kind} "
                                        f"ok reason={settlement.reason_code} "
                                        f"msg={settlement.message!r}",
                                    )
                                if is_casualty and mapped.kind == "move":
                                    import math

                                    code = str(settlement.reason_code or "")
                                    msg = str(settlement.message or "")
                                    gap_now = None
                                    if self_loc is not None:
                                        corpse = getattr(obs, "corpse_location", None)
                                        if corpse is not None:
                                            gap_now = math.hypot(
                                                float(self_loc["x"]) - float(corpse.x),
                                                float(self_loc["y"]) - float(corpse.y),
                                            )
                                    best = death_nav.get("best_gap")
                                    improved = (
                                        gap_now is not None
                                        and (
                                            best is None
                                            or gap_now < float(best) - 2.0
                                        )
                                    )
                                    if improved and gap_now is not None:
                                        death_nav["best_gap"] = gap_now
                                        death_nav["fails"] = 0
                                    elif (
                                        not settlement.success
                                        or "blocked" in code.lower()
                                        or "no goal-relative" in msg.lower()
                                        or "no adjacent" in msg.lower()
                                        or not improved
                                    ):
                                        death_nav["fails"] = (
                                            int(death_nav.get("fails") or 0) + 1
                                        )
                                        death_nav["phase"] = (
                                            int(death_nav.get("phase") or 0) + 1
                                        ) % 4
                                        death_nav["skip_stock_rec"] = 12
                                        _say(
                                            verbose,
                                            f"[shadow] #{loop_i} corpse-nav "
                                            f"fails={death_nav['fails']} "
                                            f"phase={death_nav['phase']} "
                                            f"gap={gap_now}",
                                            force=True,
                                        )
                            elif isinstance(settlement, dict):
                                row["settlement"] = settlement
                                _say(
                                    verbose,
                                    f"[shadow] #{loop_i} SELECT {mapped.kind} "
                                    f"settlement={settlement}",
                                )
                            else:
                                _say(
                                    verbose,
                                    f"[shadow] #{loop_i} SELECT {mapped.kind} "
                                    f"(no settlement yet)",
                                )
                        except NimControlRequestError as exc:
                            row["select_error"] = str(exc)
                            _say(verbose, f"[shadow] #{loop_i} select error: {exc}", force=True)
                else:
                    why = mapped.reason if mapped.skip else "action_not_ready"
                    # Quiet: drop routine skip/action_not_ready spam entirely.
                    _say(
                        verbose,
                        f"[shadow] #{loop_i} skip select ({why}) intent={intent} "
                        f"ready={frame.action_ready} pos={self_loc} "
                        f"party={frame.observation.party.in_group}",
                    )

                # Optional settled poll (does not request env frame in same call).
                if "settlement" not in row:
                    settled = _safe_last_settlement(client)
                    if isinstance(settled, ActionSettled):
                        row["last_settlement"] = settled.model_dump()
                    elif isinstance(settled, dict) and "error" not in settled:
                        row["last_settlement"] = settled

                logger.write(row)
                time.sleep(args.cadence)

    except KeyboardInterrupt:
        _say(verbose, "[shadow] interrupted", force=True)
    except Exception as exc:  # noqa: BLE001
        _say(True, f"[shadow] fatal: {exc}", force=True)
        traceback.print_exc()
        logger.write({"ts": _utc_iso(), "event": "fatal", "error": str(exc)})
        logger.close()
        return 1
    finally:
        logger.close()

    _say(verbose, f"[shadow] done; log at {logger.path}", force=True)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    return run(_parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
