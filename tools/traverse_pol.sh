#!/usr/bin/env bash
# Local Lua traverse proof-of-life (docs/traverse/traverse-2026-08-04.md).
#
# Stock RPB --proof-of-life is not this path (ClientView only). We:
#   1) prepare upstream local --league=traverse backend
#   2) inject vanilla-wow-env-host into the container network (local image
#      is vmangos_local_runtime and does not ship env-host; WS /env 1011s without it)
#   3) attach army_host --mode=traverse over WS /env
#   4) pass when path_yards >= MIN_YARDS (default 50) within max-seconds
#      OR when TRAVERSE_POL_GOAL_RADIUS>0 and within goal (desert checkpoint)
#
# Wall time is minutes, not 45m. Needs docker, uv, sudo (nsenter netns).
# Desert MVP: TRAVERSE_POL_GOAL_* set → stop at checkpoint, do not wait 45m.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${UPSTREAM:-$ROOT/../coworld-vanilla-wow}"
WOW_ENV="${WOW_ENV:-$HOME/.config/wow-env.sh}"
RESULT="${TRAVERSE_POL_RESULT:-$ROOT/local_data/traverse-pol-prepare.json}"
LOG="${TRAVERSE_POL_LOG:-$ROOT/local_data/brain-logs/traverse-pol.log}"
ENV_LOG="${TRAVERSE_POL_ENV_LOG:-$ROOT/local_data/env-host-traverse.log}"
ENV_PIDFILE="${TRAVERSE_POL_ENV_PID:-$ROOT/local_data/env-host-traverse.pid}"
# Desert checkpoint (planar). When radius>0, army_host exits 0 at goal (not 45m).
GOAL_X="${TRAVERSE_POL_GOAL_X:--6784.5}"
GOAL_Y="${TRAVERSE_POL_GOAL_Y:--4833.9}"
GOAL_RADIUS="${TRAVERSE_POL_GOAL_RADIUS:-0}"
if awk "BEGIN{exit !($GOAL_RADIUS > 0)}"; then
  # Checkpoint MVP: default 15m fail budget; path-yards bar off unless set.
  # ~2.4k yd in form is often ~12–18m; budget headroom, still << 45m.
  MAX_SECONDS="${TRAVERSE_POL_MAX_SECONDS:-1200}"
  MIN_YARDS="${TRAVERSE_POL_MIN_YARDS:-0}"
else
  MAX_SECONDS="${TRAVERSE_POL_MAX_SECONDS:-180}"
  MIN_YARDS="${TRAVERSE_POL_MIN_YARDS:-50}"
fi
CLEANUP="${TRAVERSE_POL_CLEANUP:-1}"
CONTAINER_SUFFIX="-traverse-coworld-game-1"

if [[ ! -d "$UPSTREAM" ]]; then
  echo "error: upstream missing: $UPSTREAM" >&2
  exit 1
fi

mkdir -p "$(dirname "$RESULT")" "$(dirname "$LOG")" "$ROOT/local_data/bin"
cd "$ROOT"

# Fast path: only rebuild when sources are newer than the binary.
need_army=0
if [[ ! -x tools/army_host ]]; then
  need_army=1
else
  for src in tools/army_host.nim tools/army_debug.nim tools/env_transport.nim \
             tools/msgpack_json.nim tools/fair_play_audit.nim; do
    if [[ -f "$src" && "$src" -nt tools/army_host ]]; then
      need_army=1
      break
    fi
  done
fi
if [[ "$need_army" == "1" ]]; then
  echo "[traverse-pol] building army_host (threads for debug admin)…"
  nim c --hints:off --threads:on -o:tools/army_host tools/army_host.nim
else
  echo "[traverse-pol] army_host up to date — skip rebuild"
fi

echo "[traverse-pol] ensuring env host binary…"
# env_host.sh build is idempotent / cached when possible.
tools/env_host.sh build
BIN="$ROOT/local_data/bin/vanilla-wow-env-host"
LIBS="$(cat "$ROOT/local_data/env-host-libs.path")"

stop_env_host() {
  if [[ -f "$ENV_PIDFILE" ]]; then
    local pid
    pid="$(cat "$ENV_PIDFILE" || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$ENV_PIDFILE"
  fi
}

pack_replay() {
  # Official game.server only writes replay.json.z on full episode finish.
  # We exit army_host early then tear down — pack captures offline so
  # make traverse-replay opens *this* run, not a stale scored episode.
  if [[ "${TRAVERSE_POL_PACK_REPLAY:-1}" == "1" ]]; then
    echo "[traverse-pol] packing replay from captures…"
    "$ROOT/tools/pack_traverse_replay.sh" || echo "[traverse-pol] pack replay failed (non-fatal)" >&2
  fi
}

cleanup_all() {
  stop_env_host
  # Pack while the unit still exists (captures already on host bind mounts).
  pack_replay
  if [[ "$CLEANUP" == "1" ]]; then
    echo "[traverse-pol] cleanup traverse backend…"
    (cd "$UPSTREAM" && uv run python -m player.launch.native_support cleanup --league=traverse) || true
  fi
}
# EXIT covers normal army_host finish; TERM/INT so Stop also tears down the unit.
trap cleanup_all EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

echo "[traverse-pol] preparing local --league=traverse backend…"
cd "$UPSTREAM"
if [[ -f "$WOW_ENV" ]]; then
  set +u
  # shellcheck source=/dev/null
  . "$WOW_ENV" || true
  set -u
fi

uv run python -m player.launch.native_support prepare \
  --league=traverse \
  --result="$RESULT" \
  --skip-local-assets

python3 - <<'PY' "$RESULT" >"$ROOT/local_data/traverse-pol-env.sh"
import json, sys, urllib.parse
path = sys.argv[1]
with open(path) as f:
    p = json.load(f)
ws = p["player_ws_url"]
u = urllib.parse.urlsplit(ws)
q = urllib.parse.parse_qs(u.query)
host = u.hostname or "127.0.0.1"
port = u.port or (443 if u.scheme == "wss" else 80)
token = q.get("token", [""])[0]
slot = q.get("slot", ["0"])[0]
print(f"export TRAVERSE_POL_HOST={host!r}")
print(f"export TRAVERSE_POL_PORT={port}")
print(f"export TRAVERSE_POL_TOKEN={token!r}")
print(f"export TRAVERSE_POL_SLOT={slot}")
print(f"export TRAVERSE_POL_ACCOUNT={p.get('username', '')!r}")
print(f"export TRAVERSE_POL_PASSWORD={p.get('password', '')!r}")
print(f"export TRAVERSE_POL_CHARACTER={p.get('character_name', 'Northbound')!r}")
print(f'export TRAVERSE_POL_GAME_URL="http://{host}:{port}"')
PY

# shellcheck source=/dev/null
source "$ROOT/local_data/traverse-pol-env.sh"

CONTAINER="$(docker ps --format '{{.Names}}' | grep -- "$CONTAINER_SUFFIX" | head -1 || true)"
if [[ -z "$CONTAINER" ]]; then
  echo "error: no running *$CONTAINER_SUFFIX container" >&2
  exit 1
fi
CPID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
echo "[traverse-pol] container=$CONTAINER pid=$CPID"

echo "[traverse-pol] starting env host in container network namespace (needs sudo)…"
stop_env_host
# shellcheck disable=SC2024
sudo nsenter -t "$CPID" -n env LD_LIBRARY_PATH="$LIBS" "$BIN" \
  >"$ENV_LOG" 2>&1 &
echo $! >"$ENV_PIDFILE"
sleep 1
if ! kill -0 "$(cat "$ENV_PIDFILE")" 2>/dev/null; then
  echo "error: env host failed to start; see $ENV_LOG" >&2
  cat "$ENV_LOG" >&2 || true
  exit 1
fi

GOAL_ARGS=()
if awk "BEGIN{exit !($GOAL_RADIUS > 0)}"; then
  GOAL_ARGS=(
    --pol-goal-x="$GOAL_X"
    --pol-goal-y="$GOAL_Y"
    --pol-goal-radius="$GOAL_RADIUS"
  )
  echo "[traverse-pol] desert goal=($GOAL_X,$GOAL_Y) radius=$GOAL_RADIUS max_seconds=$MAX_SECONDS (stop on checkpoint)"
fi

echo "[traverse-pol] army_host mode=traverse ws://$TRAVERSE_POL_HOST:$TRAVERSE_POL_PORT/env slot=$TRAVERSE_POL_SLOT"
if [[ -n "${ARMY_DEBUG_PORT:-}" && "${ARMY_DEBUG_PORT}" != "0" ]]; then
  echo "[traverse-pol] debug admin http://127.0.0.1:${ARMY_DEBUG_PORT}/  (ARMY_DEBUG_PORT)"
fi
cd "$ROOT"
set +e
./tools/army_host \
  --mode=traverse \
  --ws \
  --host="$TRAVERSE_POL_HOST" \
  --port="$TRAVERSE_POL_PORT" \
  --slot="$TRAVERSE_POL_SLOT" \
  --token="$TRAVERSE_POL_TOKEN" \
  --account="$TRAVERSE_POL_ACCOUNT" \
  --password="$TRAVERSE_POL_PASSWORD" \
  --character="$TRAVERSE_POL_CHARACTER" \
  --game-url="$TRAVERSE_POL_GAME_URL" \
  --asset-slot="$TRAVERSE_POL_SLOT" \
  --max-seconds="$MAX_SECONDS" \
  --pol-min-yards="$MIN_YARDS" \
  --pol-require-move \
  "${GOAL_ARGS[@]}" \
  --no-audit \
  --verbose \
  ${ARMY_DEBUG_PORT:+--debug-port="$ARMY_DEBUG_PORT"} \
  ${ARMY_DEBUG_TOKEN:+--debug-token="$ARMY_DEBUG_TOKEN"} \
  >"$LOG" 2>&1
rc=$?
set -e

echo "[traverse-pol] --- last log lines ---"
tail -n 40 "$LOG" || true
echo "[traverse-pol] army_host exit=$rc log=$LOG"
exit "$rc"
