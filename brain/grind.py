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

The loop (one action per tick, upstream's own control-loop shape):

    dead? -> release/reclaim
    loot pending? -> loot
    hurt & out of combat? -> eat/drink, then hold
    pick nearest eligible hostile
      cast masked (target, spell)?  -> cast it   (Shadow Bolt first)
      out of melee range?           -> move (target form, 4 yd arrival)
      not already auto-attacking?   -> attack ONCE
      otherwise                     -> hold the settled auto-attack

Auto-attack persists server-side; re-issuing ``attack`` every tick resends
``CMSG_ATTACK_SWING`` and burns a packet-wait window, so we latch on
``observation.auto_attack_guid`` (mask proxy: ``stop_attack`` enabled).

Safety rails
------------
* Only ``kind == "unit"`` entities with ``reaction == "hostile"`` are ever
  targeted. Player entities (``self``/``party``) are never action targets.
* ``--avoid-names`` (default ``Murist``) is a hard exclusion at every
  selection site. The human plays on this realm; a bot must never address
  his character. See ``docs/party-formation.md``.
* ``--leash`` keeps the bot inside a radius of its anchor so a chase cannot
  walk it across the zone into the human's play area.

Usage::

    make grind SLOT=2 EXTRA='--max-seconds 600'
"""

from __future__ import annotations

import argparse
import json
import math
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional

from brain.upstream import (
    ActionSelectionRequest,
    ControlDirective,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlRequestError,
)
from player.sdk.nim_control import POLICY_ACTION_KINDS

_KIND_INDEX = {k: i for i, k in enumerate(POLICY_ACTION_KINDS)}
_REPO_ROOT = Path(__file__).resolve().parents[1]
_DEFAULT_LOG_DIR = _REPO_ROOT / "local_data" / "brain-logs"

# Unit-target `move` settles on arrival within 4.0 yd
# (player/contract/environment_frame.nim:1331-1334). Ask for melee a touch
# tighter than the 5 yd swing range so we do not oscillate.
MELEE_RANGE = 4.5


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _dist(a: Any, b: Any) -> float:
    return math.dist((a.x, a.y, a.z), (b.x, b.y, b.z))


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


def masked_kinds(frame: Any) -> list[str]:
    return [k for k, on in zip(POLICY_ACTION_KINDS, frame.action_mask.kind) if on]


def cast_options(frame: Any) -> list[tuple[int, int]]:
    """All legal ``(target_index, spell_index)`` cast pairs in this frame.

    The spell mask is indexed ``[target][spell]``, not ``[kind][spell]``
    (``player/contract/actions.nim:207-211``), and only the class rotation
    tables ever set a cell — so this is the client telling us exactly which
    spells it considers in range, in line of sight and off cooldown.
    """
    out: list[tuple[int, int]] = []
    for target_index, row in enumerate(frame.action_mask.spell):
        for spell_index, allowed in enumerate(row):
            if allowed and spell_index > 0:
                out.append((target_index, spell_index))
    return out


class GrindBrain:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.avoid = {n.strip().casefold() for n in args.avoid_names.split(",") if n.strip()}
        self.anchor: Optional[Any] = None
        self.blacklist: set[str] = set()
        self.attempts: dict[str, int] = {}
        self.kills = 0
        self.loots = 0
        self.start_xp: Optional[int] = None
        self.start_level: Optional[int] = None

    # -- selection helpers -------------------------------------------------

    def eligible_targets(self, frame: Any) -> list[tuple[Any, Any, float]]:
        """(entity, unit_observation, distance) for hostiles we may engage."""
        me = frame.observation.location
        units = {u.guid: u for u in frame.observation.units}
        out: list[tuple[Any, Any, float]] = []
        attack_row = frame.action_mask.target[_KIND_INDEX["attack"]]
        for e in frame.bindings.entities:
            if e.kind != "unit" or e.reaction != "hostile" or not e.alive:
                continue
            if (e.name or "").strip().casefold() in self.avoid:
                continue
            if e.guid in self.blacklist:
                continue
            if e.index >= len(attack_row) or not attack_row[e.index]:
                continue
            unit = units.get(e.guid)
            if unit is not None:
                if unit.level > frame.observation.level + self.args.max_level_above:
                    continue
                if unit.line_of_sight_blocked and self.args.skip_los_blocked:
                    continue
            dist = _dist(e.location, me)
            if self.anchor is not None:
                if _dist(e.location, self.anchor) > self.args.leash:
                    continue
            out.append((e, unit, dist))
        out.sort(key=lambda t: t[2])
        return out

    def lootables(self, frame: Any) -> list[Any]:
        return [
            e
            for e in frame.bindings.entities
            if e.lootable and (e.name or "").strip().casefold() not in self.avoid
        ]

    # -- action plumbing ---------------------------------------------------

    def select(self, client: Any, frame: Any, action: FactorizedAction, note: str) -> Optional[Any]:
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
        time.sleep(self.args.settle_wait)
        try:
            settled = client.last_settlement()
        except Exception as exc:  # noqa: BLE001 — keep the loop alive
            return {"settle_error": str(exc)}
        return settled

    # -- the policy --------------------------------------------------------

    def decide(self, frame: Any) -> tuple[Optional[FactorizedAction], str]:
        obs = frame.observation
        kinds = set(masked_kinds(frame))

        # 1. Death recovery.
        if obs.is_ghost and obs.can_reclaim_corpse and "reclaim_corpse" in kinds:
            return FactorizedAction(kind="reclaim_corpse"), "reclaim_corpse"
        if obs.is_dead and "release_spirit" in kinds:
            return FactorizedAction(kind="release_spirit"), "release_spirit"
        if obs.is_dead or obs.is_ghost:
            return None, "dead_waiting"

        # 2. Loot anything the client says is lootable (it only flags corpses
        #    within 5.5 yd that we have not already looted).
        for corpse in self.lootables(frame):
            if "loot" in kinds:
                return FactorizedAction(kind="loot", target=corpse.index), "loot"

        hp_pct = 100.0 * obs.health / max(obs.max_health, 1)
        # Only MANA is worth resting for. Rage (1) and energy (3) regenerate in
        # combat and read 0 at rest, so treating them as "empty" parks a warrior
        # or rogue in a permanent drink loop.
        uses_mana = obs.active_power_type_known and obs.active_power_type == 0
        mana_pct = (
            100.0 * obs.active_power / max(obs.active_max_power, 1)
            if uses_mana and obs.active_power_known and obs.active_max_power
            else 100.0
        )

        # 3. Rest out of combat. Eating/drinking is a stock item use; while the
        #    buff ticks we simply hold so regen is not interrupted.
        if not obs.in_combat and (hp_pct < self.args.rest_hp or mana_pct < self.args.rest_mana):
            if obs.eating or obs.drinking:
                return None, f"resting hp={hp_pct:.0f}% mana={mana_pct:.0f}%"
            item_row = frame.action_mask.item[_KIND_INDEX["use_item"]]
            want = "drink" if mana_pct < self.args.rest_mana else "food"
            for item in frame.bindings.items:
                if item.purpose != want:
                    continue
                if item.index < len(item_row) and item_row[item.index]:
                    return (
                        FactorizedAction(kind="use_item", item=item.index),
                        f"consume_{want}",
                    )
            return None, f"rest_wait hp={hp_pct:.0f}% mana={mana_pct:.0f}%"

        # Do not open a NEW fight while badly hurt; hold and let regen work.
        targets = self.eligible_targets(frame)
        if not obs.in_combat and hp_pct < self.args.engage_hp:
            return None, f"regen_before_engage hp={hp_pct:.0f}%"
        if not targets:
            return None, "no_eligible_target"

        entity, unit, dist = targets[0]

        # 4. Cast whatever the rotation mask offers for this target. The client
        #    already checked range / LoS / cooldown / resource for us.
        options = [(t, s) for t, s in cast_options(frame) if t in (entity.index, 0)]
        if options and "cast" in kinds:
            preferred = self._preferred_spell(frame, options)
            if preferred is not None:
                t_idx, s_idx = preferred
                spell = frame.bindings.spells[s_idx - 1]
                return (
                    FactorizedAction(kind="cast", target=t_idx, spell=s_idx),
                    f"cast {spell.name} -> e{entity.index} @{dist:.1f}yd",
                )

        # 5. Close to melee. Unit-target move settles at 4 yd.
        if dist > MELEE_RANGE and "move" in kinds:
            move_row = frame.action_mask.target[_KIND_INDEX["move"]]
            if entity.index < len(move_row) and move_row[entity.index]:
                return (
                    FactorizedAction(kind="move", target=entity.index),
                    f"approach e{entity.index} @{dist:.1f}yd",
                )

        # 6. Start auto-attack exactly once per target.
        if obs.auto_attack_guid != entity.guid and "attack" in kinds:
            return (
                FactorizedAction(kind="attack", target=entity.index),
                f"attack e{entity.index} @{dist:.1f}yd",
            )

        return None, f"hold auto-attack on e{entity.index} @{dist:.1f}yd"

    def _preferred_spell(
        self, frame: Any, options: Iterable[tuple[int, int]]
    ) -> Optional[tuple[int, int]]:
        """Prefer explicitly named nukes, then any other offered spell.

        Self-buffs (target 0) are only taken when nothing else is offered and
        we are out of combat, so we never trade a nuke GCD for Demon Skin
        mid-fight.
        """
        wanted = [w.strip().casefold() for w in self.args.spell_priority.split(",") if w.strip()]
        opts = list(options)
        for want in wanted:
            for t_idx, s_idx in opts:
                if frame.bindings.spells[s_idx - 1].name.casefold() == want:
                    return t_idx, s_idx
        offensive = [(t, s) for t, s in opts if t != 0]
        if offensive:
            return offensive[0]
        if not frame.observation.in_combat and self.args.self_buffs:
            return opts[0] if opts else None
        return None

    # -- main loop ---------------------------------------------------------

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
                host=args.host, port=args.port, slot=args.slot, timeout_seconds=args.timeout
            ) as client:
                status = client.status()
                print(
                    f"[grind] slot={args.slot} phase={status.phase} rev={status.revision} "
                    f"goal={status.goal.id if status.goal else None}",
                    flush=True,
                )

                # Any goal unlocks frames; the leveling profile is unsupported
                # for this race/class, which only silences `recommended_action`.
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
                    if self.anchor is None and obs.location.x:
                        self.anchor = obs.location
                        print(
                            f"[grind] anchor {obs.location.x:.1f},{obs.location.y:.1f} "
                            f"leash={args.leash}yd",
                            flush=True,
                        )
                    if self.start_xp is None and obs.xp_known:
                        self.start_xp, self.start_level = obs.xp, obs.level

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
                            "mask": masked_kinds(frame),
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
                        ok, reason, msg = settled.success, settled.reason_code, settled.message
                        if action.kind == "loot" and ok:
                            self.loots += 1
                        if "finished attack" in (msg or ""):
                            self.kills += 1
                        print(
                            f"[grind] t{tick} lvl{obs.level} xp={obs.xp}/{obs.next_level_xp} "
                            f"hp={obs.health}/{obs.max_health} :: {why} -> "
                            f"{action.kind} ok={ok} {reason} {msg!r}",
                            flush=True,
                        )
                        # A target the client cannot reach or resolve gets one
                        # more chance, then a blacklist entry so we rotate on.
                        if not ok and action.target:
                            guid = frame.bindings.entities[action.target - 1].guid
                            self.attempts[guid] = self.attempts.get(guid, 0) + 1
                            if self.attempts[guid] >= args.max_attempts:
                                self.blacklist.add(guid)
                                row["blacklisted"] = guid
                                print(f"[grind]   blacklist {guid}", flush=True)
                    else:
                        row["settlement"] = settled
                        print(f"[grind] t{tick} :: {why} -> {action.kind} {settled}", flush=True)

                    last_report = time.monotonic()
                    log.write(row)
                    time.sleep(args.cadence)

                # Final read for the report.
                try:
                    final = client.status(include_environment_frame=True).observation
                    print(
                        f"[grind] DONE level {self.start_level}->{final.level} "
                        f"xp {self.start_xp}->{final.xp} loots={self.loots} kills~{self.kills}",
                        flush=True,
                    )
                    log.write(
                        {
                            "ts": _utc_iso(),
                            "event": "summary",
                            "start_level": self.start_level,
                            "end_level": final.level,
                            "start_xp": self.start_xp,
                            "end_xp": final.xp,
                            "loots": self.loots,
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
    p.add_argument("--cadence", type=float, default=0.6, help="loop seconds")
    p.add_argument("--settle-wait", type=float, default=0.35)
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--max-seconds", type=float, default=300.0)
    p.add_argument("--log-dir", type=Path, default=_DEFAULT_LOG_DIR)
    p.add_argument("--leash", type=float, default=150.0, help="yards from anchor")
    p.add_argument("--anchor-x", type=float, default=None)
    p.add_argument("--anchor-y", type=float, default=None)
    p.add_argument("--anchor-z", type=float, default=None)
    p.add_argument("--max-level-above", type=int, default=2)
    p.add_argument("--max-attempts", type=int, default=6)
    p.add_argument("--rest-hp", type=float, default=45.0)
    p.add_argument("--rest-mana", type=float, default=25.0)
    p.add_argument("--engage-hp", type=float, default=60.0)
    p.add_argument("--spell-priority", default="Shadow Bolt")
    p.add_argument("--self-buffs", action="store_true", help="allow out-of-combat self buffs")
    p.add_argument("--skip-los-blocked", action="store_true", default=True)
    p.add_argument(
        "--avoid-names",
        default="Murist",
        help="NEVER target or address these characters (the human plays here)",
    )
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    brain = GrindBrain(args)
    if args.anchor_x is not None and args.anchor_y is not None:
        from brain.upstream import WorldPoint

        brain.anchor = WorldPoint(
            map_id=0, x=args.anchor_x, y=args.anchor_y, z=args.anchor_z or 0.0
        )
    return brain.run()


if __name__ == "__main__":
    sys.exit(main())
