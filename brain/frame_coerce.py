"""Coerce live wire quirks that strict upstream pydantic rejects.

Adapter-only normalization so we can consume live frames without forking
upstream. Everything here is a documented divergence between what the Nim
client actually puts on the wire at pin ``98220fead`` and what the Python
contract models will accept.

Three families, all observed live:

1. **Empty enum strings.** ``observation.movement_mode`` /
   ``observation.liquid_kind`` arrive as ``""`` where the model requires the
   literal ``"unknown"`` (milestone-1 bring-up).

2. **Empty ``min_length=1`` strings in ``leveling_context``.** An undead
   warlock resolves ``profile_id=unsupported_profile``; the strategy reducer
   then never picks a farm area, so ``farm_area_id`` / ``farm_area_label``
   (and, defensively, the sibling profile/strategy labels) go out as ``""``
   against ``Field(min_length=1)``. This blocked EVERY frame read on the
   Shadowfel seat — see ``docs/warlock-seat.md``.

3. **``ActionSettled`` success/reason_code disagreement.** The model asserts
   ``success == (reason_code == "ok")``. The noop settlement produced by the
   unsupported-profile path violates it. Reconciliation here is deliberately
   **failure-preserving**: a disagreement never becomes a success, so no
   coercion can make the brain believe an action worked when it did not.

4. **``leveling_context.service`` with kind != "none" but empty destination.**
   Live frames after a train/vendor proximity flash can emit
   ``{"kind":"train","destination_id":"","destination_label":""}``, which the
   pydantic model rejects. Coerce empty destinations to ``kind="none"``.

``ActionSettled`` reaches us on two different paths — embedded in the
MessagePack environment frame as ``previous_transition``, and standalone as
JSON from ``last_settlement()``. Both are patched.
"""

from __future__ import annotations

from typing import Any


# Empty string -> contract default, matched by key name anywhere in the tree.
_EMPTY_TO_UNKNOWN = {
    "movement_mode": "unknown",
    "liquid_kind": "unknown",
    # leveling_context Field(min_length=1) slots, empty when no strategy ran.
    "profile_id": "unknown",
    "profile_label": "unknown",
    "strategy_id": "unknown",
    "strategy_label": "unknown",
    "farm_area_id": "unknown",
    "farm_area_label": "unknown",
}

# ActionSettled.reason_code Literal set (player/sdk/nim_control.py:934-941).
_REASON_CODES = {
    "ok",
    "movement_blocked",
    "unsafe_route",
    "spell_rejected",
    "unsupported_action",
    "action_rejected",
}


def coerce_action_settled(obj: dict[str, Any]) -> dict[str, Any]:
    """Make ``success`` and ``reason_code`` agree, never inventing a success.

    Rules, in order:

    * ``reason_code`` missing/empty/unknown -> ``"ok"`` when ``success`` is
      true, else ``"action_rejected"``.
    * ``success`` true but ``reason_code != "ok"`` -> ``success = False``
      (trust the specific failure code).
    * ``success`` false but ``reason_code == "ok"`` -> ``"action_rejected"``
      (trust the boolean).

    Both disagreement branches settle on failure by design.
    """
    out = dict(obj)
    success = bool(out.get("success", False))
    reason = out.get("reason_code")

    if not isinstance(reason, str) or reason not in _REASON_CODES:
        reason = "ok" if success else "action_rejected"

    if success and reason != "ok":
        success = False
    elif not success and reason == "ok":
        reason = "action_rejected"

    out["success"] = success
    out["reason_code"] = reason
    return out


def coerce_service_context(obj: dict[str, Any]) -> dict[str, Any]:
    """Normalize leveling_context.service so empty destinations never validate.

    Empty strings may already have been rewritten to ``"unknown"`` by the
    generic empty-string map — treat that placeholder as missing too, so we
    demote to ``kind="none"`` rather than invent a trainer name.
    """
    out = dict(obj)
    kind = out.get("kind") or "none"
    dest_id = out.get("destination_id") or ""
    dest_label = out.get("destination_label") or ""
    missing = (
        not dest_id
        or not dest_label
        or dest_id == "unknown"
        or dest_label == "unknown"
    )
    if kind != "none" and missing:
        out["kind"] = "none"
        out["destination_id"] = ""
        out["destination_label"] = ""
    elif kind == "none":
        # none must not carry destination names (including "unknown" fillers).
        out["destination_id"] = ""
        out["destination_label"] = ""
    return out


# ControlStatus.leveling_lifecycle / EnvironmentFrame diverge between the
# stock upstream SDK pin and monofuel's fork (quest_discovery_* fields).
_LEVELING_LIFECYCLE_KEEP = frozenset(
    {"active_strategy_key", "no_progress_seconds", "attention"}
)
_FORK_LIFECYCLE_DEFAULTS: dict[str, Any] = {
    "quest_discovery_state": "unstarted",
    "quest_discovery_terminal_reason": "none",
    "quest_discovery_target_guid": "0",
    "quest_discovery_frames": 0,
    "quest_discovery_attempts": 0,
    "strategy_failures": [],
}


def sdk_has_quest_discovery_lifecycle() -> bool:
    """True when the imported player.sdk models the fork's lifecycle shape."""
    try:
        import player.sdk.nim_control as nc

        fields = getattr(nc.LevelingControlLifecycle, "model_fields", None) or {}
        return "quest_discovery_state" in fields
    except Exception:  # noqa: BLE001 — import-time / bare hosts
        return False


def coerce_leveling_lifecycle(obj: dict[str, Any]) -> dict[str, Any]:
    """Normalize leveling_lifecycle for whichever SDK is on sys.path.

    * Upstream pin: only ``active_strategy_key`` / ``no_progress_seconds`` /
      ``attention`` (extra keys are forbidden).
    * Fork: those three plus quest_discovery_* (required); keep extras.
    """
    base = {
        "active_strategy_key": str(
            obj.get("active_strategy_key") or "unknown"
        ),
        "no_progress_seconds": float(obj.get("no_progress_seconds") or 0.0),
    }
    attention = obj.get("attention")
    if not isinstance(attention, dict):
        base["attention"] = {"kind": "none", "message": ""}
    else:
        base["attention"] = {
            "kind": attention.get("kind") or "none",
            "message": attention.get("message") or "",
        }

    if sdk_has_quest_discovery_lifecycle():
        out = dict(obj)
        out.update(base)
        for key, default in _FORK_LIFECYCLE_DEFAULTS.items():
            if key not in out or out[key] is None:
                out[key] = default
        return out

    return base


def coerce_navigation(obj: dict[str, Any]) -> dict[str, Any]:
    """Force the fixed VMaNGOS player navigation profile the *loaded* SDK wants.

    Upstream requires ``exclude_flags == ["steep"]``.
    Fork requires ``exclude_flags`` empty (validator: ``or self.exclude_flags``).
    Wire often sends ``[]``; coercing the wrong way breaks the other SDK.
    """
    out = dict(obj)
    out["owner"] = "vmangos_detour"
    out["profile"] = "vmangos_player_ground_water"
    out["include_flags"] = ["ground", "water"]
    out["action_contract"] = "semantic_destination"
    if sdk_has_quest_discovery_lifecycle():
        # Fork NavigationContract: non-empty exclude_flags is a hard error.
        out["exclude_flags"] = []
    else:
        out["exclude_flags"] = ["steep"]
    return out


def coerce_frame_payload(obj: Any) -> Any:
    """Recursively normalize a decoded wire payload in place-of-copy."""
    if isinstance(obj, dict):
        out: dict[str, Any] = {}
        for key, value in obj.items():
            if key in _EMPTY_TO_UNKNOWN and value == "":
                out[key] = _EMPTY_TO_UNKNOWN[key]
            else:
                out[key] = coerce_frame_payload(value)
        if out.get("type") == "action_settled":
            out = coerce_action_settled(out)
        # leveling_context.service shape: kind + destination_id + destination_label.
        if (
            "kind" in out
            and "destination_id" in out
            and "destination_label" in out
            and out.get("kind")
            in {"none", "train", "sell", "repair"}
        ):
            out = coerce_service_context(out)
        # Named top-level / nested contract objects.
        if "owner" in out and "profile" in out and "include_flags" in out:
            out = coerce_navigation(out)
        if "active_strategy_key" in out and "attention" in out:
            # Heuristic: lifecycle-shaped dict (ControlStatus.leveling_lifecycle).
            if "no_progress_seconds" in out or "quest_discovery_state" in out:
                out = coerce_leveling_lifecycle(out)
        if "leveling_lifecycle" in out and isinstance(out["leveling_lifecycle"], dict):
            out["leveling_lifecycle"] = coerce_leveling_lifecycle(out["leveling_lifecycle"])
        if "navigation" in out and isinstance(out["navigation"], dict):
            out["navigation"] = coerce_navigation(out["navigation"])
        return out
    if isinstance(obj, list):
        return [coerce_frame_payload(item) for item in obj]
    return obj


def coerce_json_payload(payload: bytes) -> bytes:
    """Normalize a JSON wire payload; returns the original bytes on any doubt."""
    import json

    try:
        decoded = json.loads(payload)
    except ValueError:
        return payload
    if not isinstance(decoded, dict):
        return payload
    return json.dumps(coerce_frame_payload(decoded)).encode()


def patch_upstream_decode() -> None:
    """Monkey-patch upstream decode paths once (import-time safe)."""
    import player.sdk.nim_control as nc

    if getattr(nc, "_shadow_coerce_patched", False):
        return

    # (a) MessagePack environment frames (includes previous_transition).
    original_decode = nc._decode_environment_frame_payload

    def _wrapped_decode(payload: bytes) -> object:
        return coerce_frame_payload(original_decode(payload))

    nc._decode_environment_frame_payload = _wrapped_decode  # type: ignore[assignment]

    # (b) JSON responses (ControlStatus, ActionSettled, …): coerce on validate
    # failure so fork lifecycle / nav drift cannot kill the accept/escort loops.
    original_request = nc.NimControlClient._request

    def _wrapped_request(self, frame_type, request, response_type, response_model):  # type: ignore[no-untyped-def]
        original_validate_json = getattr(response_model, "model_validate_json", None)
        original_validate = getattr(response_model, "model_validate", None)

        def _lenient_json(payload, *args, **kwargs):  # type: ignore[no-untyped-def]
            try:
                return original_validate_json(payload, *args, **kwargs)
            except Exception:  # noqa: BLE001 — pydantic ValidationError surface
                return original_validate_json(
                    coerce_json_payload(payload), *args, **kwargs
                )

        def _lenient_obj(obj, *args, **kwargs):  # type: ignore[no-untyped-def]
            try:
                return original_validate(obj, *args, **kwargs)
            except Exception:  # noqa: BLE001
                if isinstance(obj, dict):
                    return original_validate(coerce_frame_payload(obj), *args, **kwargs)
                raise

        if original_validate_json is not None:
            response_model.model_validate_json = _lenient_json  # type: ignore[assignment]
        if original_validate is not None:
            response_model.model_validate = _lenient_obj  # type: ignore[assignment]
        try:
            return original_request(self, frame_type, request, response_type, response_model)
        finally:
            if original_validate_json is not None:
                response_model.model_validate_json = original_validate_json  # type: ignore[assignment]
            if original_validate is not None:
                response_model.model_validate = original_validate  # type: ignore[assignment]

    nc.NimControlClient._request = _wrapped_request  # type: ignore[assignment]
    nc._shadow_coerce_patched = True  # type: ignore[attr-defined]
