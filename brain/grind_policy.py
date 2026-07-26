"""Pure grind/quest decision helpers for Shadowfel (no socket I/O).

``decide_action`` is the policy entry point used by ``brain.grind``.
It returns either a factorized action dict or ``None`` with a reason string.

Unit-testable with plain dict frames — no pydantic, no live realm.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping, Optional, Sequence

# Deathknell / Tirisfal early hostiles that award XP (exclude critters).
DEFAULT_GRIND_ENTRIES: frozenset[int] = frozenset(
    {
        1501,  # Mindless Zombie
        1502,  # Wretched Zombie
        1504,  # Young Night Web Spider
        1505,  # Night Web Spider
        1506,  # Scarlet Convert
        1507,  # Scarlet Initiate
        1508,  # Young Scavenger
        1509,  # Ragged Scavenger
        1512,  # Duskbat
        1513,  # Mangy Duskbat
        1520,  # Rattlecage Soldier
        1522,  # Darkeye Bonecaster
        1523,  # Cracked Skull Soldier
        1890,  # Rattlecage Skeleton (quest 1470)
        1916,
        1917,
        1918,
        1919,
    }
)

CRITTER_ENTRIES: frozenset[int] = frozenset({721, 883, 5951, 2620})

QUEST_1470 = 1470
ITEM_RATTLECAGE_SKULL = 6281
ENTRY_VENYA = 5667
ENTRY_RATTLECAGE = 1890
SUMMON_IMP_SPELL = 688

CAST_RANGE = 28.0
INTERACT_RANGE = 5.0
STEP_YARDS = 6.0
MELEE_RANGE = 4.5

# Stable kind order matching player/sdk/nim_control.POLICY_ACTION_KINDS so unit
# tests can build frames without importing upstream.
POLICY_KIND_NAMES: tuple[str, ...] = (
    "noop",
    "move",
    "face",
    "target",
    "attack",
    "stop_attack",
    "cast",
    "interact",
    "loot",
    "use_item",
    "equip_item",
    "unequip_item",
    "train_spell",
    "sell_junk",
    "buy_vendor_item",
    "accept_quest",
    "turn_in_quest",
    "invite_party",
    "accept_party",
    "follow",
    "assist",
    "pet_attack",
    "release_spirit",
    "reclaim_corpse",
    "accept_resurrect",
    "take_taxi",
    "bind_home",
    "buy_guild_charter",
    "sign_guild_charter",
    "offer_guild_charter",
    "turn_in_guild_charter",
    "spirit_healer_resurrect",
    "area_trigger",
)


@dataclass
class PolicyConfig:
    rest_hp: float = 45.0
    rest_mana: float = 25.0
    engage_hp: float = 60.0
    leash: float = 250.0
    max_level_above: int = 3
    spell_priority: tuple[str, ...] = ("shadow bolt",)
    self_buffs: bool = False
    grind_entries: frozenset[int] = DEFAULT_GRIND_ENTRIES
    quest_id: int = QUEST_1470
    quest_item_id: int = ITEM_RATTLECAGE_SKULL
    quest_item_need: int = 3
    questgiver_entry: int = ENTRY_VENYA
    skeleton_entry: int = ENTRY_RATTLECAGE
    avoid_names: frozenset[str] = field(
        default_factory=lambda: frozenset({"murist"})
    )
    venya_xy: tuple[float, float, float] = (1836.94, 1633.43, 97.02)
    skeleton_xy: tuple[float, float, float] = (1887.0, 1486.6, 87.8)
    # When True, path toward Venya even if not visible (quest setup).
    seek_quest: bool = True


@dataclass
class PolicyState:
    anchor: Optional[tuple[float, float, float]] = None
    blacklist: set[str] = field(default_factory=set)
    attempts: dict[str, int] = field(default_factory=dict)
    max_attempts: int = 6
    accept_done: bool = False
    turnin_done: bool = False
    # Set when accept_quest never appears in mask after proximity — brain-only wall.
    quest_accept_blocked: bool = False
    quest_turnin_blocked: bool = False
    venya_seen_ticks: int = 0
    # Approach jitter: alternate lateral offset after failed moves.
    approach_fails: int = 0
    last_approach_guid: str = ""
    last_approach_dist: float = -1.0
    rest_ticks: int = 0
    rest_mana_snapshot: float = -1.0
    # Auto-attack hold breakout: empty cast masks + latched AA can park a
    # caster forever at full mana (no wand melee damage at range).
    hold_ticks: int = 0
    hold_guid: str = ""


def _dist2(ax: float, ay: float, bx: float, by: float) -> float:
    return math.hypot(ax - bx, ay - by)


def _xy(loc: Any) -> tuple[float, float, float]:
    if loc is None:
        return (0.0, 0.0, 0.0)
    if isinstance(loc, Mapping):
        return (float(loc["x"]), float(loc["y"]), float(loc.get("z", 0.0)))
    return (float(loc.x), float(loc.y), float(getattr(loc, "z", 0.0)))


def _get(obj: Any, key: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, Mapping):
        return obj.get(key, default)
    return getattr(obj, key, default)


def masked_kinds(frame: Any) -> list[str]:
    mask = _get(frame, "action_mask")
    if mask is None:
        return []
    kind_row = _get(mask, "kind", []) or []
    names = _get(frame, "policy_kind_names") or POLICY_KIND_NAMES
    return [k for k, on in zip(names, kind_row) if on]


def inventory_count(frame: Any, item_id: int) -> int:
    obs = _get(frame, "observation")
    total = 0
    for item in _get(obs, "inventory_items", []) or []:
        if int(_get(item, "item_id", 0) or 0) == item_id:
            total += int(_get(item, "count", 0) or 0)
    return total


def has_spell(frame: Any, spell_id: int) -> bool:
    obs = _get(frame, "observation")
    known = _get(obs, "known_spells", []) or []
    return int(spell_id) in {int(s) for s in known}


def quest_in_log(frame: Any, quest_id: int) -> bool:
    obs = _get(frame, "observation")
    return int(quest_id) in {
        int(q) for q in (_get(obs, "quest_log_quest_ids", []) or [])
    }


def quest_turnin_ready(frame: Any, quest_id: int) -> bool:
    obs = _get(frame, "observation")
    return int(quest_id) in {
        int(q) for q in (_get(obs, "completed_quest_ids", []) or [])
    }


def quest_rewarded(frame: Any, quest_id: int) -> bool:
    obs = _get(frame, "observation")
    return int(quest_id) in {
        int(q) for q in (_get(obs, "rewarded_quest_ids", []) or [])
    }


def cast_options(frame: Any) -> list[tuple[int, int]]:
    mask = _get(frame, "action_mask")
    spell = _get(mask, "spell", []) or []
    out: list[tuple[int, int]] = []
    for target_index, row in enumerate(spell):
        for spell_index, allowed in enumerate(row):
            if allowed and spell_index > 0:
                out.append((target_index, spell_index))
    return out


def _mana_percent(obs: Any) -> float:
    """Best-effort mana fraction for rest/cast decisions.

    Prefer power pool index 0 (mana) when present — ``active_power_type`` can
    latch onto pet focus (2) mid-fight and hide real mana.
    """
    powers = _get(obs, "powers")
    max_powers = _get(obs, "max_powers")
    if (
        isinstance(powers, (list, tuple))
        and isinstance(max_powers, (list, tuple))
        and len(max_powers) > 0
        and float(max_powers[0] or 0) > 0
    ):
        return 100.0 * float(powers[0] or 0) / float(max_powers[0])
    if bool(_get(obs, "active_power_type_known")) and int(
        _get(obs, "active_power_type", -1) or -1
    ) == 0 and _get(obs, "active_power_known"):
        return 100.0 * float(_get(obs, "active_power", 0) or 0) / max(
            float(_get(obs, "active_max_power", 1) or 1), 1.0
        )
    return 100.0


def _step_toward(
    me: tuple[float, float, float],
    goal: tuple[float, float, float],
    step: float = STEP_YARDS,
) -> tuple[float, float, float]:
    dx, dy = goal[0] - me[0], goal[1] - me[1]
    dist = math.hypot(dx, dy) or 1.0
    if dist <= step:
        return (goal[0], goal[1], me[2])
    return (me[0] + dx / dist * step, me[1] + dy / dist * step, me[2])


def _move_destination(
    map_id: int, xyz: tuple[float, float, float]
) -> dict[str, Any]:
    return {
        "kind": "move",
        "destination": {
            "map_id": map_id,
            "x": xyz[0],
            "y": xyz[1],
            "z": xyz[2],
            "orientation": 0.0,
        },
    }


def _entity_list(frame: Any) -> Sequence[Any]:
    return _get(_get(frame, "bindings"), "entities", []) or []


def _units_by_guid(frame: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for u in _get(_get(frame, "observation"), "units", []) or []:
        out[str(_get(u, "guid"))] = u
    return out


def find_entity_by_entry(frame: Any, entry: int) -> Optional[Any]:
    units = _units_by_guid(frame)
    for e in _entity_list(frame):
        u = units.get(str(_get(e, "guid")))
        if u is not None and int(_get(u, "entry", 0) or 0) == entry:
            return e
    return None


def quest_index_for(frame: Any, quest_id: int) -> int:
    """1-based policy quest index, or 0 for dialog-default."""
    for i, q in enumerate(_get(_get(frame, "bindings"), "quests", []) or [], start=1):
        if isinstance(q, int):
            qid, idx = q, i
        else:
            qid = int(_get(q, "quest_id", 0) or 0)
            idx = int(_get(q, "index", i) or i)
        if qid == quest_id:
            return idx
    return 0


def preferred_spell(
    frame: Any, options: Iterable[tuple[int, int]], cfg: PolicyConfig
) -> Optional[tuple[int, int]]:
    spells = _get(_get(frame, "bindings"), "spells", []) or []
    opts = list(options)
    for want in cfg.spell_priority:
        for t_idx, s_idx in opts:
            if s_idx - 1 < 0 or s_idx - 1 >= len(spells):
                continue
            name = str(_get(spells[s_idx - 1], "name", "")).casefold()
            if name == want.casefold():
                return t_idx, s_idx
    offensive = [(t, s) for t, s in opts if t != 0]
    if offensive:
        return offensive[0]
    if cfg.self_buffs and opts:
        return opts[0]
    return None


def eligible_hostiles(
    frame: Any,
    cfg: PolicyConfig,
    state: PolicyState,
    *,
    prefer_entries: frozenset[int] = frozenset(),
) -> list[tuple[Any, Any, float]]:
    obs = _get(frame, "observation")
    me = _xy(_get(obs, "location"))
    units = _units_by_guid(frame)
    level = int(_get(obs, "level", 1) or 1)
    out: list[tuple[Any, Any, float]] = []
    for e in _entity_list(frame):
        if _get(e, "kind") != "unit":
            continue
        if _get(e, "reaction") != "hostile" or not _get(e, "alive", True):
            continue
        name = str(_get(e, "name", "") or "").strip().casefold()
        if name in cfg.avoid_names:
            continue
        guid = str(_get(e, "guid"))
        if guid in state.blacklist:
            continue
        u = units.get(guid)
        entry = int(_get(u, "entry", 0) or 0) if u is not None else 0
        if entry in CRITTER_ENTRIES:
            continue
        if entry and entry not in cfg.grind_entries:
            continue
        if u is not None:
            ulvl = int(_get(u, "level", level) or level)
            if ulvl > level + cfg.max_level_above:
                continue
        eloc = _xy(_get(e, "location"))
        dist = _dist2(me[0], me[1], eloc[0], eloc[1])
        if state.anchor is not None:
            if _dist2(eloc[0], eloc[1], state.anchor[0], state.anchor[1]) > cfg.leash:
                continue
        # Ignore far hostiles — chasing 50yd+ targets thrashs the navmesh.
        if dist > 40.0:
            continue
        out.append((e, u, dist))

    def sort_key(t: tuple[Any, Any, float]) -> tuple[int, float]:
        u = t[1]
        entry = int(_get(u, "entry", 0) or 0) if u is not None else 0
        pref = 0 if entry in prefer_entries else 1
        return (pref, t[2])

    out.sort(key=sort_key)
    return out


def current_phase(frame: Any, cfg: PolicyConfig, state: PolicyState) -> str:
    if (
        state.turnin_done
        or quest_rewarded(frame, cfg.quest_id)
        or has_spell(frame, SUMMON_IMP_SPELL)
    ):
        state.turnin_done = True
        return "grind"
    if quest_turnin_ready(frame, cfg.quest_id) or (
        quest_in_log(frame, cfg.quest_id)
        and inventory_count(frame, cfg.quest_item_id) >= cfg.quest_item_need
    ):
        state.accept_done = True
        return "turnin"
    if quest_in_log(frame, cfg.quest_id) or state.accept_done:
        state.accept_done = True
        return "objectives"
    if cfg.seek_quest and not state.quest_accept_blocked:
        venya = find_entity_by_entry(frame, cfg.questgiver_entry)
        if venya is not None:
            me = _xy(_get(_get(frame, "observation"), "location"))
            vloc = _xy(_get(venya, "location"))
            dist = _dist2(me[0], me[1], vloc[0], vloc[1])
            # Only pull off the grind when Venya is close enough that pathing
            # is a few steps — otherwise keep XP farming.
            if dist <= 25.0:
                return "accept"
        return "grind"
    return "grind"


def decide_action(
    frame: Any, cfg: PolicyConfig, state: PolicyState
) -> tuple[Optional[dict[str, Any]], str]:
    """Return (action_dict or None, reason)."""
    obs = _get(frame, "observation")
    kinds = set(masked_kinds(frame))
    me = _xy(_get(obs, "location"))
    map_id = int(_get(_get(obs, "location"), "map_id", 0) or 0)
    if state.anchor is None and (me[0] or me[1]):
        state.anchor = me

    if _get(obs, "is_ghost") and _get(obs, "can_reclaim_corpse") and "reclaim_corpse" in kinds:
        return {"kind": "reclaim_corpse"}, "reclaim_corpse"
    if _get(obs, "is_dead") and "release_spirit" in kinds:
        return {"kind": "release_spirit"}, "release_spirit"
    if _get(obs, "is_dead") or _get(obs, "is_ghost"):
        return None, "dead_waiting"

    for e in _entity_list(frame):
        if _get(e, "lootable") and "loot" in kinds:
            name = str(_get(e, "name", "") or "").strip().casefold()
            if name in cfg.avoid_names:
                continue
            guid = str(_get(e, "guid"))
            if guid in state.blacklist:
                continue
            return {"kind": "loot", "target": int(_get(e, "index"))}, "loot"

    hp = float(_get(obs, "health", 0) or 0)
    max_hp = float(_get(obs, "max_health", 1) or 1)
    hp_pct = 100.0 * hp / max(max_hp, 1.0)
    # Prefer power pool 0 (mana) for casters. `active_power_type` can stick on
    # pet focus (2) after a pet tick and then rest/cast logic goes blind.
    mana_pct = _mana_percent(obs)

    # Drop a useless auto-attack (OOM, target gone/far) so we can rest/reposition.
    auto = str(_get(obs, "auto_attack_guid", "") or "")
    if auto and auto not in ("0", "") and "stop_attack" in kinds:
        units = _units_by_guid(frame)
        u_auto = units.get(auto)
        auto_dist = float(_get(u_auto, "distance", 999) or 999) if u_auto else 999.0
        auto_alive = bool(_get(u_auto, "health", 0) or 0) > 0 if u_auto else False
        if (not auto_alive) or auto_dist > CAST_RANGE + 5 or (
            mana_pct < cfg.rest_mana and not cast_options(frame)
        ):
            return {"kind": "stop_attack"}, (
                f"stop_attack dist={auto_dist:.1f} mana={mana_pct:.0f}%"
            )

    # Flee combat toward anchor when nearly dead — multi-pulls wipe a L2 warlock.
    if _get(obs, "in_combat") and hp_pct < 30.0 and "move" in kinds and state.anchor:
        return (
            _move_destination(map_id, _step_toward(me, state.anchor, step=STEP_YARDS)),
            f"flee_low_hp {hp_pct:.0f}%",
        )
    if _get(obs, "in_combat") and hp_pct < 30.0 and "stop_attack" in kinds:
        return {"kind": "stop_attack"}, f"stop_low_hp {hp_pct:.0f}%"

    need_rest = (not _get(obs, "in_combat")) and (
        hp_pct < cfg.rest_hp or mana_pct < cfg.rest_mana
    )
    if need_rest:
        # Bail out of a stuck drink/eat (flag latched, mana not rising).
        if abs(state.rest_mana_snapshot - mana_pct) < 0.5:
            state.rest_ticks += 1
        else:
            state.rest_ticks = 0
            state.rest_mana_snapshot = mana_pct
        if state.rest_ticks > 25:
            state.rest_ticks = 0
            # Fall through to combat at low mana rather than park forever.
        else:
            if _get(obs, "eating") or _get(obs, "drinking"):
                return None, f"resting hp={hp_pct:.0f}% mana={mana_pct:.0f}%"
            want = "drink" if mana_pct < cfg.rest_mana else "food"
            for item in _get(_get(frame, "bindings"), "items", []) or []:
                if _get(item, "purpose") != want:
                    continue
                if "use_item" in kinds:
                    return {
                        "kind": "use_item",
                        "item": int(_get(item, "index")),
                    }, f"consume_{want}"
            # No food/drink — don't park; continue to combat with what we have.
            if mana_pct < 5 and hp_pct >= cfg.engage_hp:
                return None, f"oom_no_drink mana={mana_pct:.0f}%"
    else:
        state.rest_ticks = 0
    phase = current_phase(frame, cfg, state)

    # --- Quest accept (only when Venya is in frame) ---
    if phase == "accept":
        venya = find_entity_by_entry(frame, cfg.questgiver_entry)
        if venya is not None:
            state.venya_seen_ticks += 1
            vloc = _xy(_get(venya, "location"))
            dist = _dist2(me[0], me[1], vloc[0], vloc[1])
            idx = int(_get(venya, "index"))
            if dist > INTERACT_RANGE and "move" in kinds:
                return (
                    _move_destination(map_id, _step_toward(me, vloc)),
                    f"approach_venya @{dist:.1f}yd",
                )
            qidx = quest_index_for(frame, cfg.quest_id)
            if "accept_quest" in kinds:
                return {
                    "kind": "accept_quest",
                    "target": idx,
                    "quest": qidx,
                }, f"accept_quest_{cfg.quest_id}"
            if "interact" in kinds:
                # Try open dialog; next frames may expose offers/masks.
                return {"kind": "interact", "target": idx}, "interact_venya"
            if state.venya_seen_ticks >= 8:
                state.quest_accept_blocked = True
                return None, "quest_accept_blocked_no_mask"
            return None, "at_venya_waiting_mask"

    # --- Quest turn-in ---
    if phase == "turnin" and not state.quest_turnin_blocked:
        venya = find_entity_by_entry(frame, cfg.questgiver_entry)
        if venya is not None:
            vloc = _xy(_get(venya, "location"))
            dist = _dist2(me[0], me[1], vloc[0], vloc[1])
            idx = int(_get(venya, "index"))
            if dist > INTERACT_RANGE and "move" in kinds:
                return (
                    _move_destination(map_id, _step_toward(me, vloc)),
                    f"approach_turnin @{dist:.1f}yd",
                )
            qidx = quest_index_for(frame, cfg.quest_id)
            if "turn_in_quest" in kinds:
                return {
                    "kind": "turn_in_quest",
                    "target": idx,
                    "quest": qidx,
                }, f"turn_in_{cfg.quest_id}"
            if "interact" in kinds:
                return {"kind": "interact", "target": idx}, "interact_turnin"
            state.quest_turnin_blocked = True
            return None, "quest_turnin_blocked_no_mask"
        if "move" in kinds and cfg.seek_quest:
            return (
                _move_destination(map_id, _step_toward(me, cfg.venya_xy)),
                "navigate_to_turnin",
            )

    # --- Combat / objectives grind ---
    prefer: frozenset[int] = frozenset()
    if phase == "objectives":
        prefer = frozenset({cfg.skeleton_entry})

    if not _get(obs, "in_combat") and hp_pct < cfg.engage_hp:
        return None, f"regen_before_engage hp={hp_pct:.0f}%"

    targets = eligible_hostiles(frame, cfg, state, prefer_entries=prefer)
    if not targets:
        # Blacklist may have exhausted the local pack — clear and return to
        # the grind anchor rather than chase far blacklisted corpses.
        if state.blacklist:
            state.blacklist.clear()
            state.attempts.clear()
            state.approach_fails = 0
            targets = eligible_hostiles(frame, cfg, state, prefer_entries=prefer)
        if not targets:
            if phase == "objectives" and "move" in kinds:
                return (
                    _move_destination(map_id, _step_toward(me, cfg.skeleton_xy)),
                    "seek_skeletons",
                )
            if (
                cfg.seek_quest
                and not state.accept_done
                and not state.quest_accept_blocked
                and "move" in kinds
                and not _get(obs, "in_combat")
            ):
                return (
                    _move_destination(map_id, _step_toward(me, cfg.venya_xy)),
                    "seek_venya_no_mobs",
                )
            if "move" in kinds and state.anchor is not None:
                ad = _dist2(me[0], me[1], state.anchor[0], state.anchor[1])
                if ad > 8.0:
                    return (
                        _move_destination(
                            map_id, _step_toward(me, state.anchor, step=STEP_YARDS)
                        ),
                        f"return_anchor @{ad:.1f}yd",
                    )
                ang = (state.approach_fails % 8) * 0.785
                orbit = (
                    state.anchor[0] + 12.0 * math.cos(ang),
                    state.anchor[1] + 12.0 * math.sin(ang),
                    state.anchor[2],
                )
                return (
                    _move_destination(map_id, _step_toward(me, orbit)),
                    "wander_no_target",
                )
            return None, "no_eligible_target"

    entity, unit, dist = targets[0]
    eidx = int(_get(entity, "index"))
    eloc = _xy(_get(entity, "location"))
    guid = str(_get(entity, "guid"))

    # Prefer casts on the chosen target; fall back to any offensive cast so a
    # mismatched entity index does not strand us on empty options.
    all_casts = cast_options(frame)
    options = [(t, s) for t, s in all_casts if t in (eidx, 0)]
    if not options:
        options = [(t, s) for t, s in all_casts if t != 0]
    if options and "cast" in kinds:
        pref = preferred_spell(frame, options, cfg)
        if pref is not None:
            state.hold_ticks = 0
            state.hold_guid = ""
            t_idx, s_idx = pref
            spells = _get(_get(frame, "bindings"), "spells", []) or []
            sname = (
                _get(spells[s_idx - 1], "name", "?")
                if 0 <= s_idx - 1 < len(spells)
                else "?"
            )
            return {
                "kind": "cast",
                "target": t_idx,
                "spell": s_idx,
            }, f"cast {sname} -> e{t_idx} @{dist:.1f}yd"

    # Close the gap with destination steps only. Unit-target move often
    # reports success ("advanced graph route") while distance never drops
    # outdoors — that parks the loop at ~32-36yd forever.
    if dist > CAST_RANGE and "move" in kinds:
        state.hold_ticks = 0
        if state.last_approach_guid != guid:
            state.last_approach_guid = guid
            state.approach_fails = 0
            state.last_approach_dist = dist
        else:
            # Distance stagnation counts as a fail even when the settle is ok.
            if (
                state.last_approach_dist >= 0
                and dist >= state.last_approach_dist - 0.75
            ):
                state.approach_fails += 1
            elif dist < state.last_approach_dist - 1.5:
                state.approach_fails = max(0, state.approach_fails - 1)
            state.last_approach_dist = dist
        if state.approach_fails >= 8:
            state.blacklist.add(guid)
            state.approach_fails = 0
            state.last_approach_guid = ""
            state.last_approach_dist = -1.0
            return None, f"blacklist_stuck_approach e{eidx} @{dist:.1f}yd"
        dx, dy = eloc[0] - me[0], eloc[1] - me[1]
        d = math.hypot(dx, dy) or 1.0
        ux, uy = dx / d, dy / d
        step = STEP_YARDS + 4.0  # longer outdoor steps close 30yd gaps faster
        # Lateral jitter after consecutive failures (left/right of bearing).
        if state.approach_fails > 0:
            side = 1.0 if state.approach_fails % 2 else -1.0
            jx, jy = -uy * side * (5.0 + state.approach_fails), ux * side * (
                5.0 + state.approach_fails
            )
            goal = (me[0] + ux * step + jx, me[1] + uy * step + jy, me[2])
            why = f"approach_jitter e{eidx} @{dist:.1f}yd fails={state.approach_fails}"
        else:
            goal = (me[0] + ux * step, me[1] + uy * step, me[2])
            why = f"approach e{eidx} @{dist:.1f}yd"
        return _move_destination(map_id, goal), why

    # In nominal cast range but no cast options yet: step closer / attack.
    if dist > 18.0 and "move" in kinds:
        state.hold_ticks = 0
        return (
            _move_destination(map_id, _step_toward(me, eloc, step=STEP_YARDS + 2.0)),
            f"close_gap e{eidx} @{dist:.1f}yd",
        )
    if "attack" in kinds:
        if auto != guid:
            state.hold_ticks = 0
            return {"kind": "attack", "target": eidx}, f"attack e{eidx}"
        # Auto latched, no cast options. Casters often sit outside melee with
        # no wand swing — empty cast mask + hold parks the loop forever.
        if state.hold_guid != guid:
            state.hold_guid = guid
            state.hold_ticks = 0
        state.hold_ticks += 1
        if mana_pct < cfg.rest_mana and "stop_attack" in kinds:
            state.hold_ticks = 0
            return {"kind": "stop_attack"}, f"stop_for_mana {mana_pct:.0f}%"
        # After a few empty ticks at usable mana: drop AA so the next frame
        # can retarget/recast instead of noop-holding.
        if state.hold_ticks >= 4 and mana_pct >= cfg.rest_mana:
            if "stop_attack" in kinds:
                state.hold_ticks = 0
                return {"kind": "stop_attack"}, (
                    f"break_hold_cast e{eidx} mana={mana_pct:.0f}%"
                )
            if "move" in kinds:
                # Nudge sideways to refresh facing/LOS/mask.
                ang = (state.hold_ticks % 6) * 1.047
                nudge = (
                    me[0] + 3.0 * math.cos(ang),
                    me[1] + 3.0 * math.sin(ang),
                    me[2],
                )
                return (
                    _move_destination(map_id, nudge),
                    f"break_hold_nudge e{eidx}",
                )
        if state.hold_ticks >= 20:
            # Target is not dying under AA — drop it and pick another.
            state.blacklist.add(guid)
            state.hold_ticks = 0
            state.hold_guid = ""
            if "stop_attack" in kinds:
                return {"kind": "stop_attack"}, f"blacklist_hold e{eidx}"
            return None, f"blacklist_hold e{eidx}"
        return None, f"hold auto-attack on e{eidx} mana={mana_pct:.0f}% t={state.hold_ticks}"
    if "target" in kinds:
        return {"kind": "target", "target": eidx}, f"target e{eidx}"
    return None, f"stuck on e{eidx} @{dist:.1f}yd"


def action_to_factorized(action: Mapping[str, Any]) -> Any:
    """Build upstream FactorizedAction from a plain dict."""
    from brain.upstream import FactorizedAction, WorldPoint

    kwargs: dict[str, Any] = {"kind": action["kind"]}
    for key in (
        "target",
        "spell",
        "item",
        "equipment_slot",
        "quest",
        "choice",
        "recipient",
        "text",
        "trigger",
        "dialog",
    ):
        if key in action and action[key] is not None:
            kwargs[key] = action[key]
    dest = action.get("destination")
    if dest is not None:
        kwargs["destination"] = WorldPoint(
            map_id=int(dest.get("map_id", 0)),
            x=float(dest["x"]),
            y=float(dest["y"]),
            z=float(dest.get("z", 0.0)),
            orientation=float(dest.get("orientation", 0.0)),
        )
    return FactorizedAction(**kwargs)
