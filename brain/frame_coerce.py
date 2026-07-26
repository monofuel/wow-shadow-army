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

    # (b) Standalone JSON ActionSettled from last_settlement().
    original_request = nc.NimControlClient._request

    def _wrapped_request(self, frame_type, request, response_type, response_model):  # type: ignore[no-untyped-def]
        if response_model is not nc.ActionSettled:
            return original_request(self, frame_type, request, response_type, response_model)
        # Re-run upstream's own framing, but coerce before validation by
        # temporarily validating through a lenient shim.
        original_validate = response_model.model_validate_json

        def _lenient(payload, *args, **kwargs):  # type: ignore[no-untyped-def]
            try:
                return original_validate(payload, *args, **kwargs)
            except Exception:  # noqa: BLE001 — pydantic ValidationError surface
                return original_validate(coerce_json_payload(payload), *args, **kwargs)

        response_model.model_validate_json = _lenient  # type: ignore[assignment]
        try:
            return original_request(self, frame_type, request, response_type, response_model)
        finally:
            response_model.model_validate_json = original_validate  # type: ignore[assignment]

    nc.NimControlClient._request = _wrapped_request  # type: ignore[assignment]
    nc._shadow_coerce_patched = True  # type: ignore[attr-defined]
