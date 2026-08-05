#!/usr/bin/env bash
# Open the latest local traverse league replay in upstream live_admin_viewer.
#
# Finds newest:
#   ~/.coworld/player/launcher_units/runtime/*/leagues/traverse/run/replay.json.z
# Override: TRAVERSE_REPLAY=/abs/path/to/replay.json.z
#
# Uses the same native viewer + asset/nginx prep as observe/watch_bots.py
# (not the Observatory browser shell). Headed GUI — for manual review after
# make traverse / traverse-pol / traverse-desert.
#
# Usage:
#   make traverse-replay
#   TRAVERSE_REPLAY=/path/to/replay.json.z tools/traverse_replay.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${UPSTREAM:-$ROOT/../coworld-vanilla-wow}"
WOW_ENV="${WOW_ENV:-$ROOT/tools/wow_env.sh}"
RUNTIME_ROOT="${TRAVERSE_REPLAY_RUNTIME:-$HOME/.coworld/player/launcher_units/runtime}"
WATCH_PLAYER="${TRAVERSE_REPLAY_WATCH:-Northbound}"
REPLAY_SPEED="${TRAVERSE_REPLAY_SPEED:-}"
REPLAY_START="${TRAVERSE_REPLAY_START:-}"

if [[ ! -d "$UPSTREAM" ]]; then
  echo "error: upstream missing: $UPSTREAM" >&2
  exit 1
fi

find_latest_replay() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    return 1
  fi
  # Portable: no GNU -printf required.
  find "$root" -type f -path '*/leagues/traverse/run/replay.json.z' 2>/dev/null \
    | while IFS= read -r f; do
        # mtime epoch + path
        printf '%s\t%s\n' "$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f")" "$f"
      done \
    | sort -nr \
    | head -n 1 \
    | cut -f2-
}

if [[ -n "${TRAVERSE_REPLAY:-}" ]]; then
  REPLAY="$(cd "$(dirname "$TRAVERSE_REPLAY")" && pwd)/$(basename "$TRAVERSE_REPLAY")"
else
  REPLAY="$(find_latest_replay "$RUNTIME_ROOT" || true)"
fi

if [[ -z "${REPLAY:-}" || ! -f "$REPLAY" ]]; then
  echo "error: no local traverse replay found under $RUNTIME_ROOT" >&2
  echo "  (expected */leagues/traverse/run/replay.json.z after make traverse / traverse-pol / traverse-desert)" >&2
  echo "  or set TRAVERSE_REPLAY=/path/to/replay.json.z" >&2
  exit 1
fi

RESULTS="$(dirname "$REPLAY")/results.json"
echo "[traverse-replay] replay: $REPLAY"
if [[ -f "$RESULTS" ]]; then
  python3 - "$RESULTS" <<'PY' || true
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    d = json.loads(p.read_text())
except Exception as e:
    print(f"[traverse-replay] results: unreadable ({e})")
    raise SystemExit(0)
scores = d.get("scores") or []
metric = d.get("score_metric") or "score"
score = scores[0] if scores else None
scenario = d.get("scenario_id") or "?"
print(f"[traverse-replay] results: scenario={scenario} {metric}={score}")
PY
fi

cd "$UPSTREAM"
if [[ -f "$WOW_ENV" ]]; then
  set +u
  # shellcheck source=/dev/null
  . "$WOW_ENV"
  set -u
fi

export TRAVERSE_REPLAY_PATH="$REPLAY"
export TRAVERSE_REPLAY_WATCH="$WATCH_PLAYER"
export TRAVERSE_REPLAY_SPEED="$REPLAY_SPEED"
export TRAVERSE_REPLAY_START="$REPLAY_START"

echo "[traverse-replay] preparing native viewer (assets + nginx + live_admin_viewer)…"
# Same stack as observe/watch_observatory.py for a local file path.
exec uv run python - <<'PY'
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from observe import watch_bots

replay = Path(os.environ["TRAVERSE_REPLAY_PATH"]).resolve()
if not replay.is_file():
    print(f"error: replay missing: {replay}", file=sys.stderr)
    raise SystemExit(1)

# Defaults match watch_bots CLI; no realm bring-up for offline replay.
args = watch_bots.build_parser().parse_args(
    [
        "--no-bring-up",
        "--no-provision",
        "--open",
        f"--watch={os.environ.get('TRAVERSE_REPLAY_WATCH') or 'Northbound'}",
    ]
)

asset_version = watch_bots.ensure_native_assets(args)
binary = watch_bots.ensure_native_viewer_current(args, asset_version)
watch_bots.ensure_nginx_serving(args)

command = [
    str(binary),
    f"--replay={replay}",
    f"--watch-player={args.watch}",
    "--follow-watch-player",
]
speed = (os.environ.get("TRAVERSE_REPLAY_SPEED") or "").strip()
start = (os.environ.get("TRAVERSE_REPLAY_START") or "").strip()
if speed:
    command.append(f"--replay-speed={speed}")
if start:
    command.append(f"--replay-start={start}")

print("[traverse-replay] command:", " ".join(command), flush=True)
viewer = watch_bots.spawn_native_viewer(command)
proc = viewer.process
if proc is None:
    print("error: viewer process missing after spawn", file=sys.stderr)
    raise SystemExit(1)
print(f"[traverse-replay] viewer pid={proc.pid} (Ctrl-C to stop)", flush=True)
try:
    raise SystemExit(proc.wait())
except KeyboardInterrupt:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
    raise SystemExit(130)
PY
