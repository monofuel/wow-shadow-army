#!/usr/bin/env python3
"""Shadowfel's mob-grinding brain — external policy, no upstream planner.

Why this exists
---------------
The built-in leveling planner cannot drive an undead warlock: profile
selection is a compiled ``(race, class)`` table with no Undead row, so the
seat resolves ``profile_id=unsupported_profile`` and the reducer answers
``noop / "unsupported leveling profile"`` forever. There is no external
override — not a ``GoalRequest`` field, not an env var, not a ``local_data``
file (see ``docs/warlock-seat.md``).

What makes this work anyway: the *generic* action masks in
``player/contract/environment_frame.nim:1144-1221`` are goal-independent.
Once ANY goal is installed the controller offers frames, and
``move``/``face``/``target``/``attack``/``interact``/``loot``/``cast`` are
masked purely from what the bot can see — not from what the planner
recommends. The unsupported profile only means ``recommended_action`` is
``None``. We supply the policy instead.

The loop (one action per tick) is owned by ``brain.grind_policy.decide_action``:

    dead? -> release/reclaim
    loot pending? -> loot
    hurt & out of combat? -> eat/drink, then hold
    quest phases when surface allows (accept / skulls / turn-in)
    pick nearest eligible hostile (entry allowlist — no critters)
      cast masked (Shadow Bolt first)
      out of cast range? -> destination-step move (unit-target move is flaky)
      target / attack fallback

Safety rails
------------
* Only hostiles on the Deathknell XP entry list are engaged (critters filtered).
* ``--avoid-names`` (default ``Murist``) is a hard exclusion at every site.
* ``--leash`` keeps the bot inside a radius of its anchor.

Usage::

    make grind SLOT=2 EXTRA='--max-seconds 600'
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from brain.grind_policy import (
    PolicyConfig,
    PolicyState,
    action_to_factorized,
    decide_action,
    has_spell,
    inventory_count,
    masked_kinds,
    quest_in_log,
    quest_rewarded,
    quest_turnin_ready,
    SUMMON_IMP_SPELL,
)
from brain.upstream import (
    ActionSelectionRequest,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlRequestError,
)
from player.sdk.nim_control import POLICY_ACTION_KINDS

_REPO_ROOT = Path(__file__).resolve().parents[1]
_DEFAULT_LOG_DIR = _REPO_ROOT / "local_data" / "brain-logs"


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class _Jsonl:
    def __init__(self, log_dir: Path, tag: str) -> None:
        log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.path = log_dir / f"{tag}-{stamp}.jsonl"
        self._fp = self.path.open("a", encoding="utf-8")
        print(f"[grind] jsonl -> {self.path}", flush=True)

    def write(self, row: dict[str, Any]) -> None:
        self._fp.write(json.dumps(row, default=str) + "\n")
        self._fp.flush()

    def close(self) -> None:
        self._fp.close()


class GrindBrain:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        avoid = frozenset(
            n.strip().casefold() for n in args.avoid_names.split(",") if n.strip()
        )
        self.cfg = PolicyConfig(
            rest_hp=args.rest_hp,
            rest_mana=args.rest_mana,
            engage_hp=args.engage_hp,
            leash=args.leash,
            max_level_above=args.max_level_above,
            spell_priority=tuple(
                w.strip() for w in args.spell_priority.split(",") if w.strip()
            ),
            self_buffs=args.self_buffs,
            avoid_names=avoid,
            seek_quest=not args.no_quest,
        )
        self.state = PolicyState(max_attempts=args.max_attempts)
        self.kills = 0
        self.loots = 0
        self.start_xp: Optional[int] = None
        self.start_level: Optional[int] = None

    def decide(self, frame: Any) -> tuple[Optional[FactorizedAction], str]:
        # Pydantic EnvironmentFrame forbids extra attrs; wrap for kind names.
        class _FrameView:
            def __init__(self, inner: Any) -> None:
                object.__setattr__(self, "_inner", inner)
                object.__setattr__(self, "policy_kind_names", POLICY_ACTION_KINDS)

            def __getattr__(self, name: str) -> Any:
                return getattr(object.__getattribute__(self, "_inner"), name)

        raw, why = decide_action(_FrameView(frame), self.cfg, self.state)
        if raw is None:
            return None, why
        try:
            return action_to_factorized(raw), why
        except Exception as exc:  # noqa: BLE001
            return None, f"factorize_error:{exc}:{why}"
    def select(
        self, client: Any, frame: Any, action: FactorizedAction, note: str
    ) -> Optional[Any]:
        if not frame.allows_action(action):
            return {"masked_out": note}
        try:
            client.select(
                ActionSelectionRequest(
                    action=action,
                    frame_id=frame.frame_id,
                    observed_tick=frame.observed_tick,
                    expected_slot=self.args.slot,
                    expected_revision=frame.revision,
                )
            )
        except NimControlRequestError as exc:
            return {"select_error": str(exc)}
        # Destination moves often need longer than a cast settle.
        wait = self.args.settle_wait
        if action.kind == "move":
            wait = max(wait, 1.8)
        elif action.kind in ("cast", "accept_quest", "turn_in_quest", "interact"):
            wait = max(wait, 1.0)
        time.sleep(wait)
        try:
            settled = client.last_settlement()
        except Exception as exc:  # noqa: BLE001
            return {"settle_error": str(exc)}
        return settled

    def run(self) -> int:
        args = self.args
        log = _Jsonl(args.log_dir, "grind")
        stop = {"flag": False}

        def _sig(_s: int, _f: Any) -> None:
            stop["flag"] = True
            print("\n[grind] stopping cleanly", flush=True)

        signal.signal(signal.SIGINT, _sig)
        signal.signal(signal.SIGTERM, _sig)

        started = time.monotonic()
        try:
            with NimControlClient(
                host=args.host,
                port=args.port,
                slot=args.slot,
                timeout_seconds=args.timeout,
            ) as client:
                status = client.status()
                print(
                    f"[grind] slot={args.slot} phase={status.phase} rev={status.revision} "
                    f"goal={status.goal.id if status.goal else None}",
                    flush=True,
                )

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
                    print(f"[grind] goal installed rev={status.revision}", flush=True)
                except NimControlRequestError as exc:
                    print(f"[grind] goal rejected: {exc}", flush=True)
                    return 2

                tick = 0
                last_report = 0.0
                while not stop["flag"]:
                    if args.max_seconds > 0 and time.monotonic() - started >= args.max_seconds:
                        print("[grind] max-seconds reached", flush=True)
                        break
                    if args.stop_level and self.start_level is not None:
                        # checked after frame read below
                        pass
                    tick += 1
                    row: dict[str, Any] = {"ts": _utc_iso(), "tick": tick}
                    try:
                        frame = client.status(include_environment_frame=True)
                    except Exception as exc:  # noqa: BLE001
                        row["frame_error"] = str(exc)
                        log.write(row)
                        time.sleep(args.cadence)
                        continue

                    obs = frame.observation
                    if self.state.anchor is None and obs.location.x:
                        self.state.anchor = (
                            obs.location.x,
                            obs.location.y,
                            obs.location.z,
                        )
                        print(
                            f"[grind] anchor {obs.location.x:.1f},{obs.location.y:.1f} "
                            f"leash={args.leash}yd",
                            flush=True,
                        )
                    if self.start_xp is None and obs.xp_known:
                        self.start_xp, self.start_level = obs.xp, obs.level

                    if args.stop_level and obs.level >= args.stop_level:
                        print(
                            f"[grind] stop-level {args.stop_level} reached "
                            f"(lvl={obs.level})",
                            flush=True,
                        )
                        row["event"] = "stop_level"
                        log.write(row)
                        break

                    if not frame.action_ready:
                        row["skip"] = f"not_ready phase={frame.phase}"
                        log.write(row)
                        time.sleep(args.cadence)
                        continue

                    action, why = self.decide(frame)
                    row.update(
                        {
                            "frame_id": frame.frame_id,
                            "observed_tick": frame.observed_tick,
                            "level": obs.level,
                            "xp": obs.xp,
                            "next_level_xp": obs.next_level_xp,
                            "hp": obs.health,
                            "max_hp": obs.max_health,
                            "mana": obs.active_power,
                            "in_combat": obs.in_combat,
                            "pos": [obs.location.x, obs.location.y, obs.location.z],
                            "why": why,
                            "mask": masked_kinds(frame)
                            if hasattr(frame, "action_mask")
                            else [],
                            "quest_log": list(obs.quest_log_quest_ids or []),
                            "skulls": inventory_count(frame, self.cfg.quest_item_id),
                            "accept_blocked": self.state.quest_accept_blocked,
                            "turnin_blocked": self.state.quest_turnin_blocked,
                        }
                    )

                    if action is None:
                        log.write(row)
                        if time.monotonic() - last_report > 5:
                            print(
                                f"[grind] t{tick} lvl{obs.level} xp={obs.xp}/{obs.next_level_xp} "
                                f"hp={obs.health}/{obs.max_health} :: {why}",
                                flush=True,
                            )
                            last_report = time.monotonic()
                        time.sleep(args.cadence)
                        continue

                    settled = self.select(client, frame, action, why)
                    row["action"] = action.model_dump(exclude_none=True)
                    if hasattr(settled, "model_dump"):
                        row["settlement"] = settled.model_dump()
                        ok = settled.success
                        reason = settled.reason_code
                        msg = settled.message
                        if action.kind == "loot" and ok:
                            self.loots += 1
                        if ok and (
                            "finished attack" in (msg or "")
                            or "target gone" in (msg or "")
                            or "(landed)" in (msg or "")
                        ):
                            if action.kind in ("cast", "attack"):
                                self.kills += 1
                        print(
                            f"[grind] t{tick} lvl{obs.level} xp={obs.xp}/{obs.next_level_xp} "
                            f"hp={obs.health}/{obs.max_health} :: {why} -> "
                            f"{action.kind} ok={ok} {reason} {msg!r}",
                            flush=True,
                        )
                        if action.kind == "move":
                            if ok:
                                self.state.approach_fails = 0
                            else:
                                self.state.approach_fails += 1
                        if not ok and action.target:
                            try:
                                guid = frame.bindings.entities[action.target - 1].guid
                                self.state.attempts[guid] = (
                                    self.state.attempts.get(guid, 0) + 1
                                )
                                if self.state.attempts[guid] >= args.max_attempts:
                                    self.state.blacklist.add(guid)
                                    row["blacklisted"] = guid
                                    print(f"[grind]   blacklist {guid}", flush=True)
                            except Exception:  # noqa: BLE001
                                pass
                        # Destination-form moves have no target index — still
                        # rotate if we thrash the same approach guid.
                        if (
                            not ok
                            and action.kind == "move"
                            and self.state.last_approach_guid
                            and self.state.approach_fails >= args.max_attempts
                        ):
                            self.state.blacklist.add(self.state.last_approach_guid)
                            row["blacklisted"] = self.state.last_approach_guid
                            self.state.approach_fails = 0
                            print(
                                f"[grind]   blacklist approach "
                                f"{self.state.last_approach_guid}",
                                flush=True,
                            )
                    else:
                        row["settlement"] = settled
                        print(
                            f"[grind] t{tick} :: {why} -> {action.kind} {settled}",
                            flush=True,
                        )

                    last_report = time.monotonic()
                    log.write(row)
                    time.sleep(args.cadence)

                try:
                    final = client.status(include_environment_frame=True)
                    fobs = final.observation
                    print(
                        f"[grind] DONE level {self.start_level}->{fobs.level} "
                        f"xp {self.start_xp}->{fobs.xp} loots={self.loots} "
                        f"kills~{self.kills} "
                        f"quest_in_log={quest_in_log(final, self.cfg.quest_id)} "
                        f"turnin_ready={quest_turnin_ready(final, self.cfg.quest_id)} "
                        f"rewarded={quest_rewarded(final, self.cfg.quest_id)} "
                        f"imp={has_spell(final, SUMMON_IMP_SPELL)} "
                        f"accept_blocked={self.state.quest_accept_blocked} "
                        f"turnin_blocked={self.state.quest_turnin_blocked}",
                        flush=True,
                    )
                    log.write(
                        {
                            "ts": _utc_iso(),
                            "event": "summary",
                            "start_level": self.start_level,
                            "end_level": fobs.level,
                            "start_xp": self.start_xp,
                            "end_xp": fobs.xp,
                            "loots": self.loots,
                            "kills": self.kills,
                            "quest_in_log": quest_in_log(final, self.cfg.quest_id),
                            "imp_known": has_spell(final, SUMMON_IMP_SPELL),
                            "accept_blocked": self.state.quest_accept_blocked,
                            "turnin_blocked": self.state.quest_turnin_blocked,
                        }
                    )
                except Exception:  # noqa: BLE001
                    pass
        finally:
            log.close()
        print(f"[grind] log at {log.path}", flush=True)
        return 0


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Shadowfel mob-grinding brain")
    p.add_argument("--slot", type=int, default=2)
    p.add_argument("--host", default=None)
    p.add_argument("--port", type=int, default=None)
    p.add_argument("--character", default="Shadowfel")
    p.add_argument("--goal-id", default="shadow-grind")
    p.add_argument("--cadence", type=float, default=0.55, help="loop seconds")
    p.add_argument("--settle-wait", type=float, default=0.5)
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--max-seconds", type=float, default=300.0)
    p.add_argument(
        "--stop-level",
        type=int,
        default=0,
        help="stop when observation.level >= N (0=disabled)",
    )
    p.add_argument("--log-dir", type=Path, default=_DEFAULT_LOG_DIR)
    p.add_argument("--leash", type=float, default=220.0, help="yards from anchor")
    p.add_argument("--anchor-x", type=float, default=None)
    p.add_argument("--anchor-y", type=float, default=None)
    p.add_argument("--anchor-z", type=float, default=None)
    p.add_argument("--max-level-above", type=int, default=3)
    p.add_argument("--max-attempts", type=int, default=5)
    p.add_argument("--rest-hp", type=float, default=40.0)
    p.add_argument("--rest-mana", type=float, default=20.0)
    p.add_argument("--engage-hp", type=float, default=55.0)
    p.add_argument("--spell-priority", default="Shadow Bolt")
    p.add_argument("--self-buffs", action="store_true")
    p.add_argument(
        "--no-quest",
        action="store_true",
        help="skip Venya seek / quest phases (pure XP grind)",
    )
    p.add_argument(
        "--avoid-names",
        default="Murist",
        help="NEVER target these characters (human on realm)",
    )
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    brain = GrindBrain(args)
    if args.anchor_x is not None and args.anchor_y is not None:
        brain.state.anchor = (
            args.anchor_x,
            args.anchor_y,
            args.anchor_z or 0.0,
        )
    return brain.run()


if __name__ == "__main__":
    sys.exit(main())
