#!/usr/bin/env bash
# Run headless ClientView traverse until water-entry goal or timeout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TRAVERSE_CV_LOG="${TRAVERSE_CV_LOG:-$ROOT/local_data/brain-logs/traverse-cv-pol.log}"
export TRAVERSE_CV_MAX_SECONDS="${TRAVERSE_CV_MAX_SECONDS:-1200}"
export TRAVERSE_GOAL_X="${TRAVERSE_GOAL_X:--6784.5}"
export TRAVERSE_GOAL_Y="${TRAVERSE_GOAL_Y:--4833.9}"
export TRAVERSE_GOAL_RADIUS="${TRAVERSE_GOAL_RADIUS:-50}"
STATUS="$ROOT/local_data/traverse-cv-status.json"
rm -f "$STATUS"
# Start launcher in background without its own timeout (we watch status).
export TRAVERSE_CV_NO_TIMEOUT=1
"$ROOT/tools/traverse_cv.sh" headless &
pid=$!
echo "[pol] launcher pid=$pid log=$TRAVERSE_CV_LOG"
deadline=$((SECONDS + TRAVERSE_CV_MAX_SECONDS))
while kill -0 "$pid" 2>/dev/null; do
  if [[ -f "$STATUS" ]]; then
    if python3 -c "import json;d=json.load(open('$STATUS'));exit(0 if d.get('at_goal') else 1)"; then
      echo "[pol] GOAL reached: $(cat "$STATUS")"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exit 0
    fi
    # progress line occasionally
    if (( SECONDS % 30 == 0 )); then
      echo "[pol] $(cat "$STATUS" 2>/dev/null | tr '\n' ' ')"
    fi
  fi
  if (( SECONDS >= deadline )); then
    echo "[pol] timeout"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
wait "$pid" || true
if [[ -f "$STATUS" ]] && python3 -c "import json;d=json.load(open('$STATUS'));exit(0 if d.get('at_goal') else 1)"; then
  echo "[pol] GOAL after process exit"
  exit 0
fi
echo "[pol] process exited without goal"
tail -40 "$TRAVERSE_CV_LOG" || true
exit 1
