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
    return p.parse_args(argv)


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
        print(f"[shadow] jsonl -> {self.path}", flush=True)

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
    stop = {"flag": False}

    def _handle_sig(_signum: int, _frame: Any) -> None:
        stop["flag"] = True
        print("\n[shadow] Ctrl-C — shutting down cleanly", flush=True)

    signal.signal(signal.SIGINT, _handle_sig)
    signal.signal(signal.SIGTERM, _handle_sig)

    fixtures_dir = _REPO_ROOT / "tests" / "fixtures" / "frames"
    frames_captured = 0
    started = time.monotonic()
    last_pos: Optional[dict[str, float]] = None

    print(
        f"[shadow] connect slot={args.slot} host={args.host} port={args.port} "
        f"leader={args.leader_name} party={members}",
        flush=True,
    )

    try:
        with NimControlClient(
            host=args.host,
            port=args.port,
            slot=args.slot,
            timeout_seconds=args.timeout,
        ) as client:
            status = client.status()
            print(f"[shadow] status:\n{format_control_status(status)}", flush=True)
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
                print(f"[shadow] goal accepted:\n{format_control_status(status)}", flush=True)
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
                print(f"[shadow] goal rejected: {exc}", flush=True)
                logger.write(
                    {
                        "ts": _utc_iso(),
                        "event": "goal_rejected",
                        "error": str(exc),
                    }
                )
                return 2

            loop_i = 0
            while not stop["flag"]:
                if args.max_seconds > 0 and (time.monotonic() - started) >= args.max_seconds:
                    print("[shadow] max-seconds reached", flush=True)
                    break

                loop_i += 1
                row: dict[str, Any] = {"ts": _utc_iso(), "event": "tick", "i": loop_i}

                try:
                    frame = client.status(include_environment_frame=True)
                except Exception as exc:  # noqa: BLE001 — log and keep looping
                    print(f"[shadow] frame error: {exc}", flush=True)
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
                        print(f"[shadow] captured fixture {out}", flush=True)
                    except Exception as exc:  # noqa: BLE001
                        print(f"[shadow] fixture capture failed: {exc}", flush=True)

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
                            print(
                                f"[shadow] #{loop_i} accept_party mask rejects",
                                flush=True,
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
                                    print(
                                        f"[shadow] #{loop_i} ACCEPT "
                                        f"ok={settlement.success} "
                                        f"msg={settlement.message!r}",
                                        flush=True,
                                    )
                                else:
                                    row["settlement"] = settlement
                                    print(
                                        f"[shadow] #{loop_i} ACCEPT settled={settlement}",
                                        flush=True,
                                    )
                            except NimControlRequestError as exc:
                                row["select_error"] = str(exc)
                                print(f"[shadow] accept error: {exc}", flush=True)
                    logger.write(row)
                    time.sleep(args.cadence)
                    continue

                try:
                    intent = lua_runner.decide(args.tool, projection)
                except Exception as exc:  # noqa: BLE001
                    print(f"[shadow] lua error: {exc}", flush=True)
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
                        print(
                            f"[shadow] #{loop_i} intent={intent} mapped={mapped.kind} "
                            f"mask rejects action",
                            flush=True,
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
                                print(
                                    f"[shadow] #{loop_i} SELECT {mapped.kind} "
                                    f"ok={settlement.success} reason={settlement.reason_code} "
                                    f"msg={settlement.message!r} pos={self_loc}",
                                    flush=True,
                                )
                            elif isinstance(settlement, dict):
                                row["settlement"] = settlement
                                print(
                                    f"[shadow] #{loop_i} SELECT {mapped.kind} "
                                    f"settlement={settlement} pos={self_loc}",
                                    flush=True,
                                )
                            else:
                                print(
                                    f"[shadow] #{loop_i} SELECT {mapped.kind} "
                                    f"(no settlement yet) pos={self_loc}",
                                    flush=True,
                                )
                        except NimControlRequestError as exc:
                            row["select_error"] = str(exc)
                            print(f"[shadow] #{loop_i} select error: {exc}", flush=True)
                else:
                    why = mapped.reason if mapped.skip else "action_not_ready"
                    print(
                        f"[shadow] #{loop_i} skip select ({why}) intent={intent} "
                        f"ready={frame.action_ready} pos={self_loc} "
                        f"party={frame.observation.party.in_group}",
                        flush=True,
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
        print("[shadow] interrupted", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[shadow] fatal: {exc}", flush=True)
        traceback.print_exc()
        logger.write({"ts": _utc_iso(), "event": "fatal", "error": str(exc)})
        logger.close()
        return 1
    finally:
        logger.close()

    print(f"[shadow] done; log at {logger.path}", flush=True)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    return run(_parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
