"""Coerce live EnvironmentFrame quirks that strict upstream pydantic rejects.

At pin 98220fead, headless frames can emit empty strings for
``observation.movement_mode`` and ``observation.liquid_kind`` where the
Python model requires the literal ``"unknown"``. This is an adapter-only
normalization so we can consume live frames without forking upstream.

Also softens ActionSettled validation when success/reason_code disagree
(seen once on the wire during milestone-1 bring-up).
"""

from __future__ import annotations

from typing import Any


_EMPTY_TO_UNKNOWN = {
    "movement_mode": "unknown",
    "liquid_kind": "unknown",
}


def coerce_frame_payload(obj: Any) -> Any:
    """Recursively replace known empty-string enums with contract defaults."""
    if isinstance(obj, dict):
        out: dict[str, Any] = {}
        for key, value in obj.items():
            if key in _EMPTY_TO_UNKNOWN and value == "":
                out[key] = _EMPTY_TO_UNKNOWN[key]
            else:
                out[key] = coerce_frame_payload(value)
        return out
    if isinstance(obj, list):
        return [coerce_frame_payload(item) for item in obj]
    return obj


def patch_upstream_decode() -> None:
    """Monkey-patch upstream msgpack decode once (import-time safe)."""
    import player.sdk.nim_control as nc

    if getattr(nc, "_shadow_coerce_patched", False):
        return

    original = nc._decode_environment_frame_payload

    def _wrapped(payload: bytes) -> object:
        return coerce_frame_payload(original(payload))

    nc._decode_environment_frame_payload = _wrapped  # type: ignore[assignment]
    nc._shadow_coerce_patched = True  # type: ignore[attr-defined]
