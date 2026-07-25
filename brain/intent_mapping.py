"""Map Lua tool intents to typed FactorizedAction (or skip this frame).

``move_to_unit`` → follow target index (default).
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

    return MappedAction(kind=None, skip=True, reason=f"unknown_intent:{kind}")


def mapped_to_factorized_kwargs(mapped: MappedAction) -> Optional[dict[str, Any]]:
    """Build kwargs for FactorizedAction(**kwargs), or None if skip."""
    if mapped.skip or mapped.kind is None:
        return None
    if mapped.kind == "follow":
        return {"kind": "follow", "target": mapped.target}
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
