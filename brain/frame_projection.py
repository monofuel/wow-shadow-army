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
    return {"x": float(x), "y": float(y)}


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


def _follow_mask_allows(frame: Any, entity_index: int) -> bool:
    """True when action_mask.target[follow][entity_index] is admitted."""
    mask = _get(frame, "action_mask")
    if mask is None:
        return False
    kind_i = _kind_index(_get(frame, "action_space"), FOLLOW_KIND)
    if kind_i is None:
        return False
    kind_row = _get(mask, "kind")
    if kind_row is not None and kind_i < len(kind_row) and not kind_row[kind_i]:
        return False
    target = _get(mask, "target")
    if target is None or kind_i >= len(target):
        return False
    row = target[kind_i]
    if entity_index < 0 or entity_index >= len(row):
        return False
    return bool(row[entity_index])


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
    """Prefer binding location, then party member location / last_visible."""
    xy = _xy(_get(entity, "location")) if entity is not None else None
    if xy is not None:
        return xy
    members = _get(party, "members") or []
    leader_guid = _get(party, "leader_guid")
    leader_name = _get(party, "leader_name")
    for m in members:
        if _get(m, "leader") or (
            leader_guid and str(_get(m, "guid", default="")) == str(leader_guid)
        ) or (
            leader_name
            and str(_get(m, "name", default="") or "").strip().casefold()
            == str(leader_name).strip().casefold()
        ):
            if _get(m, "location_known"):
                xy = _xy(_get(m, "location"))
                if xy is not None:
                    return xy
            if _get(m, "last_visible_location_known"):
                xy = _xy(_get(m, "last_visible_location"))
                if xy is not None:
                    return xy
    # Last resort: observation.location is self, not leader — skip.
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
        elif leader_name or leader_guid:
            # In party but leader not in bindings → remembered only → not visible.
            pos = _leader_position(party, None, observation) or {"x": 0.0, "y": 0.0}
            leader_unit = {
                "id": 0,
                "x": pos["x"],
                "y": pos["y"],
                "visible": False,
            }

    return {
        "self_unit": self_unit,
        "party": {"leader_unit": leader_unit},
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
