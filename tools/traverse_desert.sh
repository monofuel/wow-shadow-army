#!/usr/bin/env bash
# Petrel land-leg proof: spawn -> desert ocean coast (water_entry beat), on
# the lua-bot host, headless, with client CPU sampling for the suspected
# RPB-CPU/world-streaming starvation (bot outruns terrain streaming and
# sticks). Evidence capture only — no recovery, no retries.
#
# Success: lua-bot-status.json ends with bot.beat=water_entry and a small
# bot.dist_water (hold reason awaiting_swim_pass). Death or a stall is a
# finding, not something this script works around.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORK="$(cd "$ROOT/../monofuel-vanilla-wow" && pwd)"
STATUS="$ROOT/local_data/traverse-status/status.json"
LOGDIR="$ROOT/local_data/health-logs"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$LOGDIR/traverse-desert-$STAMP.log"
CPU_LOG="$LOGDIR/traverse-desert-cpu-$STAMP.log"
# Episode is 270 wall seconds at 10x; startup adds a minute or two.
RUN_SECONDS="${TRAVERSE_DESERT_SECONDS:-480}"

mkdir -p "$LOGDIR"
rm -f "$STATUS"

echo "traverse-desert: $RUN_SECONDS s headless run -> $RUN_LOG"
(
  cd "$FORK" &&
  PETREL_SWIM=0 nix develop "$FORK" --command \
    timeout "$RUN_SECONDS" nim r tools/launch_nim_player.nim -- \
    --league=race --bot=lua-bot \
    --lua-status-dir="$ROOT/local_data/traverse-status" \
    --lua-repo="$ROOT" --lua-entry=traverse \
    --presentation=headless
) >"$RUN_LOG" 2>&1 &
run_pid=$!

# Sample every player-related process: %CPU, RSS, elapsed. A pegged core on
# the client while the seat is frozen is the streaming-starvation signature.
{
  echo "# stamp pid pcpu rss etime comm"
  while kill -0 "$run_pid" 2>/dev/null; do
    now="$(date -u +%H:%M:%S)"
    # ps %cpu is a lifetime average; the second top iteration is the
    # instantaneous load, which is the number the starvation question needs.
    top -b -d 1 -n 2 2>/dev/null | awk 'seen && ($NF == "player" || $NF ~ /mangosd/) { print "'"$now"' INST", $1, $9, $NF } /^top -/ { count++; seen = (count == 2) }'
    ps -eo pid,pcpu,rss,etime,args --no-headers |
      grep -E 'native_player_launcher/player|mangosd|launch_nim_player' |
      grep -v grep |
      while read -r line; do echo "$now $line"; done
    # Bot status heartbeat alongside the CPU rows, for correlation.
    if [ -f "$STATUS" ]; then
      python3 - "$STATUS" "$now" <<'EOF' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
bot = s.get("bot") or {}
print(f'{sys.argv[2]} STATUS beat={bot.get("beat")} x={bot.get("x")} '
      f'dist_water={bot.get("dist_water")} '
      f'stalled={bot.get("stalled_seconds")} '
      f'nav={s.get("nav_progress")} summary={s.get("summary")!r}')
EOF
    fi
    sleep 5
  done
} >"$CPU_LOG" 2>&1 &
sampler_pid=$!

wait "$run_pid"
code=$?
wait "$sampler_pid" 2>/dev/null

echo "traverse-desert: run exited $code; cpu samples -> $CPU_LOG"
if [ -f "$STATUS" ]; then
  python3 - "$STATUS" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
bot = s.get("bot") or {}
print("final status:")
print(f'  summary      {s.get("summary")}')
print(f'  intent       {s.get("intent_kind")} / {s.get("intent_reason")}')
print(f'  nav          {s.get("nav_progress")} err={s.get("nav_error")!r}')
print(f'  beat         {bot.get("beat")}')
print(f'  position     x={bot.get("x")} y={bot.get("y")}')
print(f'  dist_water   {bot.get("dist_water")}')
print(f'  stalled      {bot.get("stalled_seconds")}')
reason = s.get("intent_reason")
if reason == "awaiting_swim_pass":
    print("RESULT: PASS — reached the desert ocean coast")
elif reason == "run_over":
    print("RESULT: FAIL — died (speedrun over; find what stopped the movement)")
else:
    print("RESULT: INCOMPLETE — did not reach water_entry")
EOF
else
  echo "no lua-bot-status.json written — check $RUN_LOG"
fi
exit "$code"
