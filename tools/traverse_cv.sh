#!/usr/bin/env bash
# Kalimdor Traverse via ClientView Lua pilot (not /env, not stock RPB decide).
#
#   tools/traverse_cv.sh headed|headless
#   make traverse          → headless (xvfb-run via launch_nim_player)
#   make traverse-headed   → headed window
#   make traverse CHECKPOINT=water_entry  → SOAP tele after in-world (local debug)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-headless}"
UPSTREAM="${UPSTREAM:-$ROOT/../coworld-vanilla-wow}"
FORK="${TRAVERSE_FORK:-$ROOT/../coworld-vanilla-wow-fork}"
PLAYER_SRC="${TRAVERSE_PLAYER_SRC:-}"
if [[ -z "$PLAYER_SRC" ]]; then
  for cand in "$UPSTREAM" "$FORK"; do
    if [[ -f "$cand/player/runtime/visual_adapter.nim" ]] &&
       grep -q 'TRAVERSE_LUA_BRIDGE' "$cand/player/runtime/visual_adapter.nim" 2>/dev/null; then
      PLAYER_SRC="$cand"
      break
    fi
  done
fi
if [[ -z "${PLAYER_SRC:-}" || ! -d "$PLAYER_SRC" ]]; then
  echo "error: no player tree with TRAVERSE_LUA_BRIDGE in visual_adapter.nim" >&2
  exit 1
fi
WOW_ENV="${WOW_ENV:-$ROOT/tools/wow_env.sh}"
OWNER="${TRAVERSE_OWNER:-${USER:-monofuel}}"
LOG="${TRAVERSE_CV_LOG:-$ROOT/local_data/brain-logs/traverse-cv-${MODE}.log}"
BRIDGE="${TRAVERSE_LUA_BRIDGE:-$ROOT/tools/traverse_lua_bridge}"
MAX_SECONDS="${TRAVERSE_CV_MAX_SECONDS:-1200}"

if [[ ! -f "$WOW_ENV" ]]; then
  echo "error: missing $WOW_ENV" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG")"

need_bridge=0
if [[ ! -x "$BRIDGE" ]]; then
  need_bridge=1
else
  for src in \
    "$ROOT/tools/traverse_lua_bridge.nim" \
    "$ROOT/src/traverse_cv/project.nim" \
    "$ROOT/src/traverse_cv/lower.nim" \
    "$ROOT/src/traverse_cv/decide.nim"
  do
    if [[ -f "$src" && "$src" -nt "$BRIDGE" ]]; then
      need_bridge=1
      break
    fi
  done
fi
if [[ "$need_bridge" == "1" ]]; then
  echo "[traverse-cv] building traverse_lua_bridge…"
  ( cd "$ROOT" && nim c --hints:off -d:release -o:"$BRIDGE" tools/traverse_lua_bridge.nim )
fi

case "$MODE" in
  headed) PRES=headed ;;
  headless) PRES=headless ;;
  *)
    echo "usage: $0 headed|headless" >&2
    echo "  optional: CHECKPOINT / TRAVERSE_CHECKPOINT=water_entry (SOAP tele after login)" >&2
    exit 2
    ;;
esac

export TRAVERSE_LUA_BRIDGE="$BRIDGE"
export TRAVERSE_LUA_REPO="$ROOT"
# Prefer pinned ~/.nimby/pkgs over Softmax sibling deps when those are off-pin
# (sibling windy often breaks launch_nim_player pin check).
export NIMBY_PKGS_DIR="${NIMBY_PKGS_DIR:-$HOME/.nimby/pkgs}"
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

# Local debug: SOAP on for traverse backends (tele/admin). Container
# configure_vmangos merges VMANGOS_MANGOSD_CONFIG_OVERRIDES on start/recreate.
# Fair-play prove does not depend on this; see docs/traverse/checkpointing.md.
if [[ -z "${VMANGOS_MANGOSD_CONFIG_OVERRIDES:-}" && -f "$ROOT/tools/traverse_soap.py" ]]; then
  VMANGOS_MANGOSD_CONFIG_OVERRIDES="$(python3 "$ROOT/tools/traverse_soap.py" env)"
  export VMANGOS_MANGOSD_CONFIG_OVERRIDES
fi
if [[ -n "${VMANGOS_MANGOSD_CONFIG_OVERRIDES:-}" ]]; then
  echo "[traverse-cv] SOAP overrides: $VMANGOS_MANGOSD_CONFIG_OVERRIDES"
  # Best-effort: keep league config.json in sync when prepare has already written it.
  python3 "$ROOT/tools/traverse_soap.py" patch >/dev/null 2>&1 || true
fi

# Local-debug CHECKPOINT: post-login SOAP tele (not fixture start — prepare stomps that).
CHECKPOINT_NAME="${TRAVERSE_CHECKPOINT:-${CHECKPOINT:-}}"
CHECKPOINT_PID=""
cleanup_checkpoint_watch() {
  if [[ -n "${CHECKPOINT_PID:-}" ]] && kill -0 "$CHECKPOINT_PID" 2>/dev/null; then
    kill "$CHECKPOINT_PID" 2>/dev/null || true
    wait "$CHECKPOINT_PID" 2>/dev/null || true
  fi
}
trap cleanup_checkpoint_watch EXIT

echo "[traverse-cv] mode=$MODE presentation=$PRES player_src=$PLAYER_SRC"
echo "[traverse-cv] bridge=$BRIDGE repo=$ROOT"
echo "[traverse-cv] ClientView Lua pilot — not /env army_host"
echo "[traverse-cv] log=$LOG"
if [[ -n "$CHECKPOINT_NAME" ]]; then
  echo "[traverse-cv] CHECKPOINT=$CHECKPOINT_NAME (SOAP tele after in-world)"
fi

cd "$PLAYER_SRC"
set +u
# shellcheck source=/dev/null
. "$WOW_ENV"
set -u

# Ensure bridge + pin env survive into the player child (and bridge grandchildren).
export TRAVERSE_LUA_BRIDGE TRAVERSE_LUA_REPO NIMBY_PKGS_DIR
export TRAVERSE_GOAL_X="${TRAVERSE_GOAL_X:--1533.7}"
export TRAVERSE_GOAL_Y="${TRAVERSE_GOAL_Y:--4056.5}"
export TRAVERSE_GOAL_RADIUS="${TRAVERSE_GOAL_RADIUS:-100}"

: >"$LOG"
echo "[traverse-cv] launching…" | tee -a "$LOG"
if [[ -n "$CHECKPOINT_NAME" && -f "$ROOT/tools/traverse_checkpoint.py" ]]; then
  # Background: wait for SOAP + fresh in-world status, then tele until near pose.
  # Do not tele on a fixed sleep — prepare recreates the realm and SOAP is down
  # early; offline tele does not move an already-logged-in body.
  (
    export PYTHONUNBUFFERED=1
    python3 -u "$ROOT/tools/traverse_checkpoint.py" apply "$CHECKPOINT_NAME" \
      --timeout "${TRAVERSE_CHECKPOINT_TIMEOUT:-480}" \
      --near "${TRAVERSE_CHECKPOINT_NEAR:-150}" \
      >>"$LOG" 2>&1 || echo "[traverse-cv] CHECKPOINT apply failed (see log)" >>"$LOG"
  ) &
  CHECKPOINT_PID=$!
  echo "[traverse-cv] checkpoint watcher pid=$CHECKPOINT_PID" | tee -a "$LOG"
fi

set +e
if command -v timeout >/dev/null 2>&1 && [[ "${TRAVERSE_CV_NO_TIMEOUT:-0}" != "1" ]]; then
  nix shell nixpkgs#nginx nixpkgs#xvfb-run nixpkgs#xorg.xorgserver --command \
    timeout --signal=TERM "$MAX_SECONDS" \
    env TRAVERSE_LUA_BRIDGE="$BRIDGE" TRAVERSE_LUA_REPO="$ROOT" \
      NIMBY_PKGS_DIR="$NIMBY_PKGS_DIR" \
      TRAVERSE_GOAL_X="$TRAVERSE_GOAL_X" TRAVERSE_GOAL_Y="$TRAVERSE_GOAL_Y" \
      TRAVERSE_GOAL_RADIUS="$TRAVERSE_GOAL_RADIUS" \
      VMANGOS_MANGOSD_CONFIG_OVERRIDES="${VMANGOS_MANGOSD_CONFIG_OVERRIDES:-}" \
      nim r tools/launch_nim_player.nim -- \
        --league=traverse \
        --controller=embedded \
        --presentation="$PRES" \
        --bot=real-playerbot \
        --owner="$OWNER" \
    >>"$LOG" 2>&1
  code=$?
else
  nix shell nixpkgs#nginx nixpkgs#xvfb-run nixpkgs#xorg.xorgserver --command \
    env TRAVERSE_LUA_BRIDGE="$BRIDGE" TRAVERSE_LUA_REPO="$ROOT" \
      NIMBY_PKGS_DIR="$NIMBY_PKGS_DIR" \
      TRAVERSE_GOAL_X="$TRAVERSE_GOAL_X" TRAVERSE_GOAL_Y="$TRAVERSE_GOAL_Y" \
      TRAVERSE_GOAL_RADIUS="$TRAVERSE_GOAL_RADIUS" \
      VMANGOS_MANGOSD_CONFIG_OVERRIDES="${VMANGOS_MANGOSD_CONFIG_OVERRIDES:-}" \
      nim r tools/launch_nim_player.nim -- \
        --league=traverse \
        --controller=embedded \
        --presentation="$PRES" \
        --bot=real-playerbot \
        --owner="$OWNER" \
    >>"$LOG" 2>&1
  code=$?
fi
set -e
# Let checkpoint watcher finish if still running (tele may land late).
if [[ -n "${CHECKPOINT_PID:-}" ]]; then
  wait "$CHECKPOINT_PID" 2>/dev/null || true
  CHECKPOINT_PID=""
fi
cleanup_checkpoint_watch
trap - EXIT
echo "[traverse-cv] exit=$code (see $LOG)"
if grep -qE 'traverse-lua|Northbound|TRAVERSE_LUA' "$LOG" 2>/dev/null; then
  echo "[traverse-cv] bridge/player activity found in log"
fi
exit "$code"
