#!/usr/bin/env bash
# Run headless ClientView traverse until merchant-coast goal or timeout.
# Default prove: planar ≤100 yd of (-1533.7, -4056.5). Wall clock long (swim).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TRAVERSE_CV_LOG="${TRAVERSE_CV_LOG:-$ROOT/local_data/brain-logs/traverse-cv-pol.log}"
# Swim leg can take a long time (water entry + coast).
export TRAVERSE_CV_MAX_SECONDS="${TRAVERSE_CV_MAX_SECONDS:-3600}"
export TRAVERSE_GOAL_X="${TRAVERSE_GOAL_X:--4627.01}"
export TRAVERSE_GOAL_Y="${TRAVERSE_GOAL_Y:--4869.45}"
export TRAVERSE_GOAL_RADIUS="${TRAVERSE_GOAL_RADIUS:-100}"
STATUS="$ROOT/local_data/traverse-cv-status.json"
rm -f "$STATUS"
export TRAVERSE_CV_NO_TIMEOUT=1
"$ROOT/tools/traverse_cv.sh" headless &
pid=$!
echo "[pol] launcher pid=$pid log=$TRAVERSE_CV_LOG"
echo "[pol] prove goal=($TRAVERSE_GOAL_X,$TRAVERSE_GOAL_Y) r=$TRAVERSE_GOAL_RADIUS max=${TRAVERSE_CV_MAX_SECONDS}s"
deadline=$((SECONDS + TRAVERSE_CV_MAX_SECONDS))
last_print=0
while kill -0 "$pid" 2>/dev/null; do
  if [[ -f "$STATUS" ]]; then
    if python3 -c "import json;d=json.load(open('$STATUS'));exit(0 if d.get('at_goal') else 1)"; then
      echo "[pol] GOAL reached: $(cat "$STATUS")"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exit 0
    fi
    if (( SECONDS - last_print >= 30 )); then
      last_print=$SECONDS
      echo "[pol] t=${SECONDS}s $(cat "$STATUS" 2>/dev/null | tr '\n' ' ')"
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
