#!/usr/bin/env bash
# Dashboard/local entry for a full desert-checkpoint traverse bot run.
# Env (optional): TRAVERSE_POL_* overrides (see tools/traverse_pol.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Tear down *-traverse-coworld-game-1 when army_host exits (checkpoint/timeout/error).
export TRAVERSE_POL_CLEANUP="${TRAVERSE_POL_CLEANUP:-1}"
export TRAVERSE_POL_MIN_YARDS="${TRAVERSE_POL_MIN_YARDS:-0}"
export TRAVERSE_POL_MAX_SECONDS="${TRAVERSE_POL_MAX_SECONDS:-1200}"
export TRAVERSE_POL_GOAL_RADIUS="${TRAVERSE_POL_GOAL_RADIUS:-50}"
export TRAVERSE_POL_GOAL_X="${TRAVERSE_POL_GOAL_X:--6784.5}"
export TRAVERSE_POL_GOAL_Y="${TRAVERSE_POL_GOAL_Y:--4833.9}"
export TRAVERSE_POL_LOG="${TRAVERSE_POL_LOG:-$ROOT/local_data/brain-logs/traverse-pol.log}"
# Local debug admin (HTTP+WS) — see docs/traverse/army-debug.md
export ARMY_DEBUG_PORT="${ARMY_DEBUG_PORT:-7788}"
cd "$ROOT"
exec make traverse-pol
