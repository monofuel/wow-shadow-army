"""Project an EnvironmentFrame into the plain-table shape lua/tools expect.

Coupling isolation: every field name the Lua tools read is decided here.
Unit tests use plain dicts so they stay stdlib-only (no pydantic/msgpack).

Expected Lua shape (follow_leader.lua + test_follow_leader.lua)::

    {
      self_unit = { x, y },
      party = {
        leader_unit = { id, x, y, visible } | nil
      }
    }

``leader_unit.id`` is the policy entity index (bindings.entities) used as
``FactorizedAction(kind="follow", target=id)``. ``visible`` is true only when
that binding exists, is kind=="party", and action_mask allows follow at that
index.
"""

from __future__ import annotations

from typing import Any, Mapping, MutableMapping, Optional


FOLLOW_KIND = "follow"
ASSIST_KIND = "assist"
ATTACK_KIND = "attack"
CAST_KIND = "cast"


def _get(obj: Any, *names: str, default: Any = None) -> Any:
    """Read attr or dict key; support both pydantic models and plain dicts."""
    for name in names:
        if obj is None:
            return default
        if isinstance(obj, Mapping):
            if name in obj:
                return obj[name]
        else:
            if hasattr(obj, name):
                return getattr(obj, name)
    return default


def _xy(location: Any) -> Optional[dict[str, float]]:
    if location is None:
        return None
    x = _get(location, "x")
    y = _get(location, "y")
    if x is None or y is None:
        return None
    out: dict[str, float] = {"x": float(x), "y": float(y)}
    z = _get(location, "z")
    if z is not None:
        out["z"] = float(z)
    map_id = _get(location, "map_id")
    if map_id is not None:
        out["map_id"] = float(map_id)
    return out


def _kind_index(action_space: Any, kind: str) -> Optional[int]:
    kinds = _get(action_space, "kinds")
    if not kinds:
        # Fall back to the known v1 order when only a mask is present in tests.
        from_list = (
            "noop", "move", "face", "target", "attack", "interact", "loot", "cast",
            "train_spell", "use_item", "release_spirit", "reclaim_corpse", "area_trigger",
            "sell_junk", "buy_vendor_item", "accept_quest", "turn_in_quest",
            "invite_party", "accept_party", "follow", "assist",
        )
        try:
            return from_list.index(kind)
        except ValueError:
            return None
    try:
        return list(kinds).index(kind)
    except ValueError:
        return None


def _kind_mask_allows(frame: Any, kind: str) -> bool:
    """True when action_mask.kind admits this kind (no target index)."""
    mask = _get(frame, "action_mask")
    if mask is None:
        return False
    kind_i = _kind_index(_get(frame, "action_space"), kind)
    if kind_i is None:
        return False
    kind_row = _get(mask, "kind")
    if kind_row is None or kind_i >= len(kind_row):
        return False
    return bool(kind_row[kind_i])


def _mask_allows(frame: Any, kind: str, entity_index: int) -> bool:
    """True when action_mask.target[kind][entity_index] is admitted."""
    if not _kind_mask_allows(frame, kind):
        return False
    mask = _get(frame, "action_mask")
    kind_i = _kind_index(_get(frame, "action_space"), kind)
    if kind_i is None:
        return False
    target = _get(mask, "target")
    if target is None or kind_i >= len(target):
        return False
    row = target[kind_i]
    if entity_index < 0 or entity_index >= len(row):
        return False
    return bool(row[entity_index])


def _follow_mask_allows(frame: Any, entity_index: int) -> bool:
    """True when action_mask.target[follow][entity_index] is admitted."""
    return _mask_allows(frame, FOLLOW_KIND, entity_index)


def _party_entities(bindings: Any) -> list[Any]:
    entities = _get(bindings, "entities") or []
    return [e for e in entities if _get(e, "kind") == "party"]


def _match_leader_entity(
    bindings: Any,
    leader_guid: Optional[str],
    leader_name: Optional[str],
) -> Optional[Any]:
    """Find the party binding for the leader by guid, else name."""
    parties = _party_entities(bindings)
    if leader_guid:
        for e in parties:
            if str(_get(e, "guid", default="")) == str(leader_guid):
                return e
    if leader_name:
        needle = leader_name.strip().casefold()
        for e in parties:
            name = str(_get(e, "name", default="") or "")
            if name.strip().casefold() == needle:
                return e
    return None


def _leader_position(
    party: Any,
    entity: Any,
    observation: Any,
) -> Optional[dict[str, float]]:
    """Prefer binding location, then party member location / last_visible.

    Party frames often set ``location_known`` with ``z=0`` and
    ``elevation_known=false`` while ``last_visible_location`` still has a real
    floor (crypt multi-floor). Prefer last_visible z when elevation is unknown.
    """
    if entity is not None:
        xy = _xy(_get(entity, "location"))
        if xy is not None and "z" in xy and xy["z"] != 0.0:
            return xy
    members = _get(party, "members") or []
    leader_guid = _get(party, "leader_guid")
    leader_name = _get(party, "leader_name")
    for m in members:
        if not (
            _get(m, "leader")
            or (
                leader_guid
                and str(_get(m, "guid", default="")) == str(leader_guid)
            )
            or (
                leader_name
                and str(_get(m, "name", default="") or "").strip().casefold()
                == str(leader_name).strip().casefold()
            )
        ):
            continue
        live = _xy(_get(m, "location")) if _get(m, "location_known") else None
        last = (
            _xy(_get(m, "last_visible_location"))
            if _get(m, "last_visible_location_known")
            else None
        )
        elev_ok = bool(_get(m, "elevation_known"))
        if live is not None:
            live_z = live.get("z")
            live_has_floor = live_z is not None and float(live_z) != 0.0
            # Prefer full live when elevation is known, or live already has a floor.
            # Never overwrite a good live z with last_visible — that freezes the
            # leader on an old floor and destination moves chase a ghost.
            if elev_ok or live_has_floor:
                return live
            # Party unit xy is often low-res/stale while last_visible tracks the
            # human better (live z=0, elev unknown). Prefer last_visible whole.
            if last is not None and "z" in last and float(last["z"]) != 0.0:
                return last
            return live
        if last is not None:
            return last
    if entity is not None:
        return _xy(_get(entity, "location"))
    return None


def project_for_follow_leader(frame: Any) -> dict[str, Any]:
    """Map EnvironmentFrame (model or dict) -> follow_leader plain table.

    Returns a plain dict safe to serialize / hand to the Lua runner.
    """
    observation = _get(frame, "observation")
    if observation is None:
        return {"self_unit": None, "party": {"leader_unit": None}}

    loc = _get(observation, "location")
    self_xy = _xy(loc)
    self_unit = self_xy  # {x, y} or None

    party = _get(observation, "party")
    leader_unit: Optional[MutableMapping[str, Any]] = None
    if party is not None and _get(party, "in_group"):
        leader_guid = _get(party, "leader_guid")
        leader_name = _get(party, "leader_name")
        bindings = _get(frame, "bindings")
        entity = _match_leader_entity(bindings, leader_guid, leader_name)
        if entity is not None:
            idx = int(_get(entity, "index"))
            visible = bool(_get(entity, "alive", default=True)) and _follow_mask_allows(
                frame, idx
            )
            pos = _leader_position(party, entity, observation) or {"x": 0.0, "y": 0.0}
            leader_unit = {
                "id": idx,
                "x": pos["x"],
                "y": pos["y"],
                "visible": visible,
            }
            if "z" in pos:
                leader_unit["z"] = pos["z"]
            if "map_id" in pos:
                leader_unit["map_id"] = pos["map_id"]
        elif leader_name or leader_guid:
            # In party but leader not in bindings → remembered only → not visible.
            pos = _leader_position(party, None, observation) or {"x": 0.0, "y": 0.0}
            leader_unit = {
                "id": 0,
                "x": pos["x"],
                "y": pos["y"],
                "visible": False,
            }
            if "z" in pos:
                leader_unit["z"] = pos["z"]
            if "map_id" in pos:
                leader_unit["map_id"] = pos["map_id"]

    # Self gets z/map when available (destination rejoin / multi-floor).
    if self_unit is not None and loc is not None:
        z = _get(loc, "z")
        if z is not None:
            self_unit = dict(self_unit)
            self_unit["z"] = float(z)
            mid = _get(loc, "map_id")
            if mid is not None:
                self_unit["map_id"] = float(mid)

    # Class id for role-aware escort (warrior tank / priest healer / warlock dps).
    if self_unit is not None and observation is not None:
        cid = _get(observation, "class_id")
        if cid is None:
            cid = _get(observation, "class")
        if cid is not None:
            try:
                self_unit = dict(self_unit)
                self_unit["class_id"] = int(cid)
            except (TypeError, ValueError):
                pass

    return {
        "self_unit": self_unit,
        "party": {"leader_unit": leader_unit},
    }


def _mana_percent(observation: Any) -> float:
    """Mana fraction 0–100; prefer power pool 0 (mana) over active_power latch."""
    if observation is None:
        return 100.0
    powers = _get(observation, "powers")
    max_powers = _get(observation, "max_powers")
    if (
        isinstance(powers, (list, tuple))
        and isinstance(max_powers, (list, tuple))
        and len(max_powers) > 0
        and float(max_powers[0] or 0) > 0
    ):
        return 100.0 * float(powers[0] or 0) / float(max_powers[0])
    if bool(_get(observation, "active_power_type_known")) and int(
        _get(observation, "active_power_type", -1) or -1
    ) == 0 and _get(observation, "active_power_known"):
        return 100.0 * float(_get(observation, "active_power", 0) or 0) / max(
            float(_get(observation, "active_max_power", 1) or 1), 1.0
        )
    return 100.0


def _health_percent(observation: Any) -> float:
    if observation is None or not _get(observation, "health_known"):
        return 100.0
    mx = float(_get(observation, "max_health", 0) or 0)
    if mx <= 0:
        return 100.0
    return 100.0 * float(_get(observation, "health", 0) or 0) / mx


def _cast_options(frame: Any) -> list[dict[str, Any]]:
    """List masked cast options as plain tables for Lua.

    Each entry: ``{ target, spell, name, spell_id }`` where ``spell`` is the
    policy spell index (1-based binding index used by FactorizedAction).
    """
    mask = _get(frame, "action_mask")
    if mask is None:
        return []
    kind_i = _kind_index(_get(frame, "action_space"), CAST_KIND)
    if kind_i is None:
        return []
    kind_row = _get(mask, "kind")
    if kind_row is not None and kind_i < len(kind_row) and not kind_row[kind_i]:
        return []
    spell_mask = _get(mask, "spell") or []
    spells = _get(_get(frame, "bindings"), "spells") or []
    out: list[dict[str, Any]] = []
    # spell_mask is target_index → list[bool] over spell indices.
    for target_index, row in enumerate(spell_mask):
        if not isinstance(row, (list, tuple)):
            continue
        for spell_index, allowed in enumerate(row):
            if not allowed or spell_index <= 0:
                continue
            name = ""
            spell_id = 0
            if 0 <= spell_index - 1 < len(spells):
                sp = spells[spell_index - 1]
                name = str(_get(sp, "name", default="") or "")
                spell_id = int(_get(sp, "spell_id", default=0) or 0)
            out.append(
                {
                    "target": int(target_index),
                    "spell": int(spell_index),
                    "name": name,
                    "spell_id": spell_id,
                }
            )
    return out


def project_for_escort_leader(frame: Any) -> dict[str, Any]:
    """Map EnvironmentFrame → escort_leader table (follow + assist + cast + death).

    Shape::

        {
          self_unit = { x, y, z?, map_id? } | nil,
          party = {
            leader_unit = { id, x, y, visible, assistable } | nil
          },
          combat = { ... },
          death = {
            is_dead, is_ghost, can_reclaim_corpse,
            can_release_spirit, can_reclaim_action, can_move,
            corpse_known, corpse = { map_id, x, y, z } | nil
          }
        }
    """
    base = project_for_follow_leader(frame)
    observation = _get(frame, "observation")
    leader = (base.get("party") or {}).get("leader_unit")
    if leader is not None and leader.get("id"):
        idx = int(leader["id"])
        leader["assistable"] = bool(leader.get("visible")) and _mask_allows(
            frame, ASSIST_KIND, idx
        )
    elif leader is not None:
        leader["assistable"] = False

    focus_guid = (
        str(_get(observation, "combat_focus_guid", default="") or "")
        if observation is not None
        else ""
    )
    auto_guid = (
        str(_get(observation, "auto_attack_guid", default="") or "")
        if observation is not None
        else ""
    )
    self_guid = (
        str(_get(observation, "player_guid", default="") or "")
        if observation is not None
        else ""
    )
    # Self/party as combat_focus freezes escorts in assist loops (live bug:
    # focus_guid == player_guid while OOC). Only hostiles matter for escort.
    if self_guid and focus_guid == self_guid:
        focus_guid = ""
    if self_guid and auto_guid == self_guid:
        auto_guid = ""
    combat: dict[str, Any] = {
        "in_combat": bool(_get(observation, "in_combat", default=False))
        if observation is not None
        else False,
        "mana_pct": _mana_percent(observation),
        "health_pct": _health_percent(observation),
        "focus_guid": focus_guid,
        "auto_attack_guid": auto_guid,
        "focus_id": 0,
        "attackable": [],
        "casts": _cast_options(frame),
    }
    bindings = _get(frame, "bindings")
    entities = _get(bindings, "entities") or []
    party_guids: set[str] = set()
    for e in entities:
        kind = str(_get(e, "kind", default="") or "").lower()
        eg = str(_get(e, "guid", default="") or "")
        if eg and kind in ("self", "party", "player"):
            party_guids.add(eg)
    if focus_guid in party_guids:
        focus_guid = ""
        combat["focus_guid"] = ""
    if auto_guid in party_guids:
        auto_guid = ""
        combat["auto_attack_guid"] = ""
    prefer_guids = {g for g in (focus_guid, auto_guid) if g and g != "0"}
    for e in entities:
        idx = int(_get(e, "index", default=0) or 0)
        if idx <= 0:
            continue
        eg = str(_get(e, "guid", default="") or "")
        if eg in prefer_guids and eg not in party_guids:
            combat["focus_id"] = idx
        if not _mask_allows(frame, ATTACK_KIND, idx):
            continue
        if eg in party_guids:
            continue
        loc = _get(e, "location")
        xy = _xy(loc)
        entry: dict[str, Any] = {
            "id": idx,
            "guid": eg,
        }
        if xy is not None:
            entry["x"] = xy["x"]
            entry["y"] = xy["y"]
            # z/map for approach-cast-range destination moves (casters OOR).
            if "z" in xy:
                entry["z"] = xy["z"]
            if "map_id" in xy:
                entry["map_id"] = xy["map_id"]
        combat["attackable"].append(entry)

    base["combat"] = combat
    base["death"] = _project_death(frame, observation)
    return base


def _project_death(frame: Any, observation: Any) -> dict[str, Any]:
    """Death/ghost recovery fields for escort_leader (fair-play actions only)."""
    is_dead = bool(_get(observation, "is_dead", default=False)) if observation else False
    is_ghost = bool(_get(observation, "is_ghost", default=False)) if observation else False
    can_reclaim_corpse = (
        bool(_get(observation, "can_reclaim_corpse", default=False))
        if observation
        else False
    )
    corpse_known = (
        bool(_get(observation, "corpse_known", default=False)) if observation else False
    )
    corpse: Optional[dict[str, float]] = None
    if observation is not None and corpse_known:
        cl = _xy(_get(observation, "corpse_location"))
        if cl is not None and "z" in cl and float(cl.get("z", 0) or 0) != 0.0:
            corpse = {
                "map_id": float(cl.get("map_id", 0) or 0),
                "x": float(cl["x"]),
                "y": float(cl["y"]),
                "z": float(cl["z"]),
            }
        elif cl is not None and (cl.get("x") or cl.get("y")):
            # Some frames know xy only; still useful for graph move.
            corpse = {
                "map_id": float(cl.get("map_id", 0) or 0),
                "x": float(cl["x"]),
                "y": float(cl["y"]),
                "z": float(cl.get("z", 0) or 0),
            }
            if corpse["x"] == 0.0 and corpse["y"] == 0.0:
                corpse = None
    return {
        "is_dead": is_dead,
        "is_ghost": is_ghost,
        "can_reclaim_corpse": can_reclaim_corpse,
        "can_release_spirit": _kind_mask_allows(frame, "release_spirit"),
        "can_reclaim_action": _kind_mask_allows(frame, "reclaim_corpse"),
        "can_move": _kind_mask_allows(frame, "move"),
        "corpse_known": corpse_known and corpse is not None,
        "corpse": corpse,
    }


def project_self_location(frame: Any) -> Optional[dict[str, float]]:
    """Convenience: self {x,y,z,map_id} for move fallback / logging."""
    observation = _get(frame, "observation")
    loc = _get(observation, "location") if observation is not None else None
    if loc is None:
        return None
    xy = _xy(loc)
    if xy is None:
        return None
    z = _get(loc, "z")
    map_id = _get(loc, "map_id")
    out: dict[str, float] = {"x": xy["x"], "y": xy["y"]}
    if z is not None:
        out["z"] = float(z)
    if map_id is not None:
        out["map_id"] = float(map_id)
    return out


def find_unit_by_name(frame: Any, name: str) -> Optional[dict[str, Any]]:
    """Locate a visible unit/party entity by name (for move-near fallback)."""
    needle = name.strip().casefold()
    bindings = _get(frame, "bindings")
    entities = _get(bindings, "entities") or []
    for e in entities:
        ename = str(_get(e, "name", default="") or "")
        if ename.strip().casefold() != needle:
            continue
        loc = _get(e, "location")
        xy = _xy(loc)
        return {
            "index": int(_get(e, "index")),
            "kind": _get(e, "kind"),
            "guid": _get(e, "guid"),
            "name": ename,
            "location": loc,
            "x": xy["x"] if xy else None,
            "y": xy["y"] if xy else None,
            "z": float(_get(loc, "z")) if loc is not None and _get(loc, "z") is not None else None,
            "map_id": int(_get(loc, "map_id")) if loc is not None and _get(loc, "map_id") is not None else None,
            "alive": bool(_get(e, "alive", default=True)),
        }
    return None
