"""Single import adapter for the upstream nim_control Python client.

Pin moves are a one-file change: adjust UPSTREAM_ROOT (or env) here only.
Never copy the client into this repo.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Sibling checkout of coworld-vanilla-wow (see upstream.lock).
_REPO_ROOT = Path(__file__).resolve().parents[1]
_DEFAULT_UPSTREAM = (_REPO_ROOT.parent / "coworld-vanilla-wow").resolve()
UPSTREAM_ROOT = Path(
    os.environ.get("WOW_SHADOW_UPSTREAM", str(_DEFAULT_UPSTREAM))
).resolve()


def ensure_upstream_on_path() -> Path:
    """Insert upstream root on sys.path so `player.sdk.*` imports resolve."""
    root = str(UPSTREAM_ROOT)
    if not UPSTREAM_ROOT.is_dir():
        raise FileNotFoundError(
            f"upstream checkout missing: {UPSTREAM_ROOT} "
            f"(set WOW_SHADOW_UPSTREAM or place coworld-vanilla-wow as a sibling)"
        )
    if root not in sys.path:
        sys.path.insert(0, root)
    return UPSTREAM_ROOT


ensure_upstream_on_path()

# Re-export the wire models and client used by the brain. Import after path fix.
from player.sdk.nim_control import (  # noqa: E402
    ActionSelectionRequest,
    ActionSettled,
    ControlDirective,
    ControlStatus,
    EnvironmentFrame,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlError,
    NimControlProtocolError,
    NimControlRequestError,
    WorldPoint,
    format_control_status,
    format_environment_frame,
)

# Live-frame enum coercion (empty movement_mode/liquid_kind → "unknown").
# See brain/frame_coerce.py. Must run after nim_control is importable.
from brain.frame_coerce import patch_upstream_decode  # noqa: E402

patch_upstream_decode()

__all__ = [
    "UPSTREAM_ROOT",
    "ensure_upstream_on_path",
    "ActionSelectionRequest",
    "ActionSettled",
    "ControlDirective",
    "ControlStatus",
    "EnvironmentFrame",
    "FactorizedAction",
    "GoalRequest",
    "NimControlClient",
    "NimControlError",
    "NimControlProtocolError",
    "NimControlRequestError",
    "WorldPoint",
    "format_control_status",
    "format_environment_frame",
]
