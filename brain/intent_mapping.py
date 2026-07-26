"""Map Lua tool intents to typed FactorizedAction (or skip this frame).

``move_to_unit`` → follow target index (default).
``assist_unit`` → assist party index (select leader's target).
``attack_unit`` → attack entity index.
``cast_spell`` → cast spell index on target index.
``accept_party`` → accept pending group invite (no target).
``hold`` / nil → no action this frame (skip select()).

Move fallback (party not formed): when ``prefer_move_destination`` is set,
``move_to_unit`` becomes ``kind="move"`` with a WorldPoint near the unit
instead of follow. That keeps the goal install + external selection + Lua
decide + settle loop working before party invites land.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping, Optional


@dataclass(frozen=True)
class MappedAction:
    """Result of intent → wire action translation."""

    # None means skip select() this frame.
    kind: Optional[str]
    target: int = 0
    spell: int = 0
    # When kind == "move", destination is a plain dict {map_id, x, y, z}.
    destination: Optional[dict[str, float]] = None
    skip: bool = False
    reason: str = ""


def map_intent(
    intent: Optional[Mapping[str, Any]],
    *,
    prefer_move_destination: Optional[Mapping[str, float]] = None,
) -> MappedAction:
    """Translate a Lua decide() result into a FactorizedAction recipe.

    Args:
        intent: table from follow_leader (or None when decide returns nil).
        prefer_move_destination: if set and intent is move_to_unit, emit a
            move-to-point action with this destination instead of follow.
            Keys: map_id, x, y, z (orientation optional).

    Returns:
        MappedAction; ``skip=True`` means the brain should not call select().
    """
    if intent is None:
        return MappedAction(kind=None, skip=True, reason="nil_intent")

    kind = intent.get("kind")
    if kind is None:
        return MappedAction(kind=None, skip=True, reason="missing_kind")

    if kind == "hold":
        return MappedAction(
            kind=None,
            skip=True,
            reason=str(intent.get("reason") or "hold"),
        )

    if kind == "move_to_unit":
        if prefer_move_destination is not None:
            dest = {
                "map_id": float(prefer_move_destination["map_id"]),
                "x": float(prefer_move_destination["x"]),
                "y": float(prefer_move_destination["y"]),
                "z": float(prefer_move_destination["z"]),
            }
            return MappedAction(
                kind="move",
                target=0,
                destination=dest,
                skip=False,
                reason="move_fallback",
            )
        # Explicit world destination (multi-floor WMO / crypt): stock `follow`
        # dies with terrain-floor divergence; destination `move` uses navmesh
        # graph edges that set allowTerrainOverhead.
        if (
            intent.get("x") is not None
            and intent.get("y") is not None
            and intent.get("z") is not None
        ):
            dest = {
                "map_id": float(intent.get("map_id") or 0),
                "x": float(intent["x"]),
                "y": float(intent["y"]),
                "z": float(intent["z"]),
            }
            return MappedAction(
                kind="move",
                target=0,
                destination=dest,
                skip=False,
                reason=str(intent.get("reason") or "move_destination"),
            )
        unit_id = intent.get("unit_id")
        if unit_id is None:
            return MappedAction(kind=None, skip=True, reason="move_to_unit_missing_id")
        idx = int(unit_id)
        if idx <= 0:
            return MappedAction(kind=None, skip=True, reason="move_to_unit_invalid_id")
        return MappedAction(
            kind="follow",
            target=idx,
            skip=False,
            reason=str(intent.get("reason") or "follow"),
        )

    if kind == "assist_unit":
        unit_id = intent.get("unit_id")
        if unit_id is None:
            return MappedAction(kind=None, skip=True, reason="assist_unit_missing_id")
        idx = int(unit_id)
        if idx <= 0:
            return MappedAction(kind=None, skip=True, reason="assist_unit_invalid_id")
        return MappedAction(
            kind="assist",
            target=idx,
            skip=False,
            reason=str(intent.get("reason") or "assist"),
        )

    if kind == "attack_unit":
        unit_id = intent.get("unit_id")
        if unit_id is None:
            return MappedAction(kind=None, skip=True, reason="attack_unit_missing_id")
        idx = int(unit_id)
        if idx <= 0:
            return MappedAction(kind=None, skip=True, reason="attack_unit_invalid_id")
        return MappedAction(
            kind="attack",
            target=idx,
            skip=False,
            reason=str(intent.get("reason") or "attack"),
        )

    if kind == "cast_spell":
        unit_id = intent.get("unit_id", intent.get("target"))
        spell_id = intent.get("spell")
        if unit_id is None or spell_id is None:
            return MappedAction(kind=None, skip=True, reason="cast_spell_missing_ids")
        t_idx = int(unit_id)
        s_idx = int(spell_id)
        if t_idx < 0 or s_idx <= 0:
            return MappedAction(kind=None, skip=True, reason="cast_spell_invalid_ids")
        return MappedAction(
            kind="cast",
            target=t_idx,
            spell=s_idx,
            skip=False,
            reason=str(intent.get("reason") or "cast"),
        )

    if kind == "accept_party":
        return MappedAction(
            kind="accept_party",
            target=0,
            skip=False,
            reason=str(intent.get("reason") or "accept_party"),
        )

    return MappedAction(kind=None, skip=True, reason=f"unknown_intent:{kind}")


def mapped_to_factorized_kwargs(mapped: MappedAction) -> Optional[dict[str, Any]]:
    """Build kwargs for FactorizedAction(**kwargs), or None if skip."""
    if mapped.skip or mapped.kind is None:
        return None
    if mapped.kind in ("follow", "assist", "attack"):
        return {"kind": mapped.kind, "target": mapped.target}
    if mapped.kind == "cast":
        return {
            "kind": "cast",
            "target": mapped.target,
            "spell": mapped.spell,
        }
    if mapped.kind == "accept_party":
        return {"kind": "accept_party"}
    if mapped.kind == "move":
        assert mapped.destination is not None
        return {
            "kind": "move",
            "target": 0,
            "destination": {
                "map_id": int(mapped.destination["map_id"]),
                "x": mapped.destination["x"],
                "y": mapped.destination["y"],
                "z": mapped.destination["z"],
            },
        }
    return None
