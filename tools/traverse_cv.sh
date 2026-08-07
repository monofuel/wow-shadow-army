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
  for cand in "$FORK" "$UPSTREAM"; do
    # Prefer-upstream: petrel_pilot.nim; legacy: visual_adapter.nim Petrel hook.
    if { [[ -f "$cand/player/runtime/petrel_pilot.nim" ]] &&
         grep -qE 'petrelEnabled|TRAVERSE_LUA_REPO|libpetrel' \
           "$cand/player/runtime/petrel_pilot.nim" 2>/dev/null; } ||
       { [[ -f "$cand/player/runtime/visual_adapter.nim" ]] &&
         grep -qE 'petrelEnabled|libpetrel|TRAVERSE_LUA_REPO' \
           "$cand/player/runtime/visual_adapter.nim" 2>/dev/null; }; then
      PLAYER_SRC="$cand"
      break
    fi
  done
fi
if [[ -z "${PLAYER_SRC:-}" || ! -d "$PLAYER_SRC" ]]; then
  echo "error: no player tree with Petrel hook (petrel_pilot.nim or visual_adapter.nim)" >&2
  exit 1
fi
WOW_ENV="${WOW_ENV:-$ROOT/tools/wow_env.sh}"
OWNER="${TRAVERSE_OWNER:-${USER:-monofuel}}"
PETREL_LIB="${PETREL_LIB:-$ROOT/tools/libpetrel.so}"
MAX_SECONDS="${TRAVERSE_CV_MAX_SECONDS:-1200}"
RUN_ROOT="${PETREL_DEBUG_RUN_ROOT:-$ROOT/local_data/traverse-runs}"
RUN_ID="${PETREL_DEBUG_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_DIR="$RUN_ROOT/$RUN_ID"
LOG="${TRAVERSE_CV_LOG:-$RUN_DIR/player.log}"
ADMIN_LOG="$RUN_DIR/admin.log"
ADMIN_PORT="${ARMY_DEBUG_PORT:-7788}"
ADMIN_TOKEN="${ARMY_DEBUG_TOKEN:-}"
ADMIN_BIN="${PETREL_DEBUG_ADMIN_BIN:-/tmp/wow-shadow-army-petrel-debug-admin-${UID:-0}}"

if [[ ! -f "$WOW_ENV" ]]; then
  echo "error: missing $WOW_ENV" >&2
  exit 1
fi

mkdir -p "$RUN_DIR/anomalies" "$RUN_DIR/control/acks" "$(dirname "$LOG")"
ln -sfn "$RUN_ID" "$RUN_ROOT/latest"

need_petrel=0
if [[ ! -f "$PETREL_LIB" ]]; then
  need_petrel=1
else
  for src in \
    "$ROOT/src/petrel/c_api.nim" \
    "$ROOT/src/petrel/embed.nim" \
    "$ROOT/src/petrel/lua53.nim" \
    "$ROOT/src/traverse_cv/project.nim" \
    "$ROOT/src/traverse_cv/decide.nim" \
    "$ROOT/lua/entry/traverse.lua"
  do
    if [[ -f "$src" && "$src" -nt "$PETREL_LIB" ]]; then
      need_petrel=1
      break
    fi
  done
fi
if [[ "$need_petrel" == "1" ]]; then
  echo "[traverse-cv] building libpetrel.so (in-process Lua)…"
  "$ROOT/tools/build_libpetrel.sh" "$PETREL_LIB"
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

export TRAVERSE_LUA_REPO="$ROOT"
export PETREL_LIB
# Unset legacy bridge so we never exec a per-tick binary.
unset TRAVERSE_LUA_BRIDGE || true
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
PROGRESS_PID=""
ADMIN_PID=""
ADMIN_FINISHED=0
STATUS_JSON="${TRAVERSE_CV_STATUS:-$RUN_DIR/status.json}"
PROGRESS_INTERVAL="${TRAVERSE_PROGRESS_INTERVAL:-5}"
finish_admin() {
  if [[ "$ADMIN_FINISHED" == "0" && -n "${ADMIN_PID:-}" ]]; then
    curl -fsS -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
      "http://127.0.0.1:$ADMIN_PORT/finish?exit_code=${code:-1}" \
      >/dev/null 2>&1 || true
    ADMIN_FINISHED=1
  fi
}
cleanup_bg() {
  if [[ -n "${CHECKPOINT_PID:-}" ]] && kill -0 "$CHECKPOINT_PID" 2>/dev/null; then
    kill "$CHECKPOINT_PID" 2>/dev/null || true
    wait "$CHECKPOINT_PID" 2>/dev/null || true
  fi
  CHECKPOINT_PID=""
  if [[ -n "${PROGRESS_PID:-}" ]] && kill -0 "$PROGRESS_PID" 2>/dev/null; then
    kill "$PROGRESS_PID" 2>/dev/null || true
    wait "$PROGRESS_PID" 2>/dev/null || true
  fi
  PROGRESS_PID=""
  finish_admin
  if [[ -n "${ADMIN_PID:-}" ]] && kill -0 "$ADMIN_PID" 2>/dev/null; then
    kill "$ADMIN_PID" 2>/dev/null || true
    wait "$ADMIN_PID" 2>/dev/null || true
  fi
  ADMIN_PID=""
}
trap cleanup_bg EXIT

echo "[traverse-cv] mode=$MODE presentation=$PRES player_src=$PLAYER_SRC"
echo "[traverse-cv] petrel_lib=$PETREL_LIB repo=$ROOT"
echo "[traverse-cv] in-process Lua + RPB nav — not /env, not per-tick exec"
echo "[traverse-cv] log=$LOG"
echo "[traverse-cv] durable_run=$RUN_DIR"
echo "[traverse-cv] progress every ${PROGRESS_INTERVAL}s → console + log (status=$STATUS_JSON)"
if [[ -n "$CHECKPOINT_NAME" ]]; then
  echo "[traverse-cv] CHECKPOINT=$CHECKPOINT_NAME (SOAP tele after in-world)"
fi

cd "$PLAYER_SRC"
set +u
# shellcheck source=/dev/null
. "$WOW_ENV"
set -u

# Ensure petrel + pin env survive into the player child.
export TRAVERSE_LUA_REPO PETREL_LIB NIMBY_PKGS_DIR
export PETREL_DEBUG_RUN_DIR="$RUN_DIR"
export TRAVERSE_GOAL_X="${TRAVERSE_GOAL_X:--4627.01}"
export TRAVERSE_GOAL_Y="${TRAVERSE_GOAL_Y:--4869.45}"
export TRAVERSE_GOAL_RADIUS="${TRAVERSE_GOAL_RADIUS:-25}"
export TRAVERSE_START_X="${TRAVERSE_START_X:--9187.0}"
export TRAVERSE_SCORE_CAP_X="${TRAVERSE_SCORE_CAP_X:-6687.333052}"
# Prefer fork player (has petrel hook). Force TRAVERSE_PLAYER if needed.
export TRAVERSE_PLAYER_SRC="${TRAVERSE_PLAYER_SRC:-$PLAYER_SRC}"

: >"$LOG"
: >"$ADMIN_LOG"
if ! (
  cd "$ROOT"
  nim c --hints:off --threads:on \
    --nimcache:"/tmp/petrel-debug-admin-cache-${UID:-0}" \
    -o:"$ADMIN_BIN" tools/petrel_debug_admin.nim
) >>"$ADMIN_LOG" 2>&1; then
  echo "error: Petrel debug admin did not compile (see $ADMIN_LOG)" >&2
  exit 1
fi
(
  cd "$ROOT"
  admin_args=(
    --run-dir="$RUN_DIR"
    --repo="$ROOT"
    --fork="$PLAYER_SRC"
    --port="$ADMIN_PORT"
    --presentation="$PRES"
    --simulation-scale=10
  )
  if [[ -n "$ADMIN_TOKEN" ]]; then
    admin_args+=(--token="$ADMIN_TOKEN")
  fi
  if [[ -n "$CHECKPOINT_NAME" ]]; then
    admin_args+=(--checkpoint="$CHECKPOINT_NAME")
  fi
  exec "$ADMIN_BIN" "${admin_args[@]}"
) >>"$ADMIN_LOG" 2>&1 &
ADMIN_PID=$!
for _ in $(seq 1 120); do
  if curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
      "http://127.0.0.1:$ADMIN_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$ADMIN_PID" 2>/dev/null; then
    echo "error: Petrel debug admin exited during startup (see $ADMIN_LOG)" >&2
    exit 1
  fi
  sleep 0.25
done
if ! curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:$ADMIN_PORT/healthz" >/dev/null 2>&1; then
  echo "error: Petrel debug admin did not become healthy (see $ADMIN_LOG)" >&2
  exit 1
fi
echo "[traverse-cv] debug=http://127.0.0.1:$ADMIN_PORT run=$RUN_ID" | tee -a "$LOG"
echo "[traverse-cv] launching…" | tee -a "$LOG"
if [[ -n "$CHECKPOINT_NAME" && -f "$ROOT/tools/traverse_checkpoint.py" ]]; then
  # Background: wait for SOAP + fresh in-world status, then tele until near pose.
  # Do not tele on a fixed sleep — prepare recreates the realm and SOAP is down
  # early; offline tele does not move an already-logged-in body.
  (
    export PYTHONUNBUFFERED=1
    python3 -u "$ROOT/tools/traverse_checkpoint.py" apply "$CHECKPOINT_NAME" \
      --status "$STATUS_JSON" \
      --timeout "${TRAVERSE_CHECKPOINT_TIMEOUT:-480}" \
      --near "${TRAVERSE_CHECKPOINT_NEAR:-150}" \
      >>"$LOG" 2>&1 || echo "[traverse-cv] CHECKPOINT apply failed (see log)" >>"$LOG"
  ) &
  CHECKPOINT_PID=$!
  echo "[traverse-cv] checkpoint watcher pid=$CHECKPOINT_PID" | tee -a "$LOG"
fi

# Periodic position + northing score while the player is running (player stdout
# is redirected to the log only; this watcher speaks to the console).
if [[ "${TRAVERSE_PROGRESS:-1}" != "0" ]]; then
  (
    export PYTHONUNBUFFERED=1
    # shellcheck disable=SC2030
    status="$STATUS_JSON"
    interval="$PROGRESS_INTERVAL"
    log="$LOG"
    start_t=$SECONDS
    while true; do
      sleep "$interval"
      if [[ ! -f "$status" ]]; then
        echo "[traverse-cv] t=$((SECONDS - start_t))s waiting for status…" | tee -a "$log"
        continue
      fi
      line="$(
        python3 - "$status" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
x = d.get("x"); y = d.get("y"); z = d.get("z")
score = d.get("score")
if score is None and isinstance(x, (int, float)):
    start = float(d.get("start_x", -9187.0))
    cap = float(d.get("score_cap_x", 6687.333052))
    score = max(0.0, min(float(x), cap) - start)
dist = d.get("dist")
swim = d.get("swimming")
form = d.get("form_spell")
ghost = d.get("ghost")
reason = d.get("intent_reason") or ""
kind = d.get("intent_kind") or ""
if not reason and isinstance(d.get("intent"), dict):
    reason = d["intent"].get("reason") or ""
    kind = d["intent"].get("kind") or kind
at = d.get("at_goal")
bits = []
if isinstance(x, (int, float)) and isinstance(y, (int, float)):
    zz = f",{float(z):.1f}" if isinstance(z, (int, float)) else ""
    bits.append(f"pos=({float(x):.1f},{float(y):.1f}{zz})")
if isinstance(score, (int, float)):
    bits.append(f"score={float(score):.0f}yd")
if isinstance(dist, (int, float)):
    bits.append(f"merch={float(dist):.0f}yd")
if swim is not None:
    bits.append("swim" if swim else "land")
if form is not None:
    bits.append(f"form={form}")
if ghost:
    bits.append("ghost")
if kind or reason:
    bits.append(f"{kind}:{reason}" if kind else reason)
nav = d.get("nav_progress") or ""
nerr = d.get("nav_error") or ""
nsurf = d.get("nav_surface") or ""
nrec = d.get("nav_recover") or ""
td = d.get("target_dist")
st = d.get("stuck_ticks")
if nav:
    bits.append(f"nav={nav}")
if nsurf:
    bits.append(f"surf={nsurf}")
if nrec:
    bits.append(f"rec={nrec}")
if isinstance(td, (int, float)):
    bits.append(f"beat={float(td):.0f}yd")
if isinstance(st, (int, float)) and int(st) > 0:
    bits.append(f"stuck={int(st)}")
if nerr:
    bits.append(f"err={nerr[:48]}")
if at:
    bits.append("AT_GOAL")
print(" ".join(bits) if bits else "status empty")
PY
      )"
      if [[ -n "$line" ]]; then
        echo "[traverse-cv] t=$((SECONDS - start_t))s $line" | tee -a "$log"
      fi
    done
  ) &
  PROGRESS_PID=$!
  echo "[traverse-cv] progress watcher pid=$PROGRESS_PID (every ${PROGRESS_INTERVAL}s)" | tee -a "$LOG"
fi

set +e
if command -v timeout >/dev/null 2>&1 && [[ "${TRAVERSE_CV_NO_TIMEOUT:-0}" != "1" ]]; then
  nix shell nixpkgs#nginx nixpkgs#xvfb-run nixpkgs#xorg.xorgserver --command \
    timeout --signal=TERM "$MAX_SECONDS" \
    env TRAVERSE_LUA_REPO="$ROOT" PETREL_LIB="$PETREL_LIB" \
      NIMBY_PKGS_DIR="$NIMBY_PKGS_DIR" \
      PETREL_DEBUG_RUN_DIR="$RUN_DIR" \
      TRAVERSE_GOAL_X="$TRAVERSE_GOAL_X" TRAVERSE_GOAL_Y="$TRAVERSE_GOAL_Y" \
      TRAVERSE_GOAL_RADIUS="$TRAVERSE_GOAL_RADIUS" \
      TRAVERSE_START_X="$TRAVERSE_START_X" TRAVERSE_SCORE_CAP_X="$TRAVERSE_SCORE_CAP_X" \
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
    env TRAVERSE_LUA_REPO="$ROOT" PETREL_LIB="$PETREL_LIB" \
      NIMBY_PKGS_DIR="$NIMBY_PKGS_DIR" \
      PETREL_DEBUG_RUN_DIR="$RUN_DIR" \
      TRAVERSE_GOAL_X="$TRAVERSE_GOAL_X" TRAVERSE_GOAL_Y="$TRAVERSE_GOAL_Y" \
      TRAVERSE_GOAL_RADIUS="$TRAVERSE_GOAL_RADIUS" \
      TRAVERSE_START_X="$TRAVERSE_START_X" TRAVERSE_SCORE_CAP_X="$TRAVERSE_SCORE_CAP_X" \
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
cleanup_bg
trap - EXIT
echo "[traverse-cv] exit=$code (see $LOG)"
if [[ -f "$STATUS_JSON" ]]; then
  python3 - "$STATUS_JSON" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
x, y, z = d.get("x"), d.get("y"), d.get("z")
score = d.get("score")
dist = d.get("dist")
print(
    f"[traverse-cv] final pos=({x},{y},{z}) score={score} merch_dist={dist}"
    f" at_goal={d.get('at_goal')} reason={d.get('intent_reason') or ''}"
)
PY
fi
if grep -qE 'traverse-lua|Northbound|TRAVERSE_LUA' "$LOG" 2>/dev/null; then
  echo "[traverse-cv] bridge/player activity found in log"
fi
exit "$code"
