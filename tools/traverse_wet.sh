#!/usr/bin/env bash
# Petrel wet-lab: SOAP-tele the traverse episode character to the
# water_entry checkpoint and prove the cheese-coast swim to Dustwallow on
# the lua-bot host. Local debug only — the fair prove is the full run from
# stock spawn (PETREL_SWIM=1 make traverse).
#
# PASS: lua-bot-status.json ends holding intent_reason=duskwallow_coast
# while swimming. FAIL: run_over (death — a policy bug to fix, never to
# work around). Anything else: INCOMPLETE. Either way the report carries
# the Number for the improve-or-revert board: the minimum planar yards to
# the duskwallow goal over samples taken while swimming in Aquatic Form
# (best_planar_to_duskwallow_wet, docs/traverse/duskwallow-plan.md §1c).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORK="$(cd "$ROOT/../monofuel-vanilla-wow" && pwd)"
STATUS="$ROOT/local_data/traverse-status/status.json"
LOGDIR="$ROOT/local_data/health-logs"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$LOGDIR/traverse-wet-$STAMP.log"
CPU_LOG="$LOGDIR/traverse-wet-cpu-$STAMP.log"
TELE_LOG="$LOGDIR/traverse-wet-tele-$STAMP.log"
# Episode is 270 wall seconds at 10x; startup adds a minute or two.
RUN_SECONDS="${TRAVERSE_WET_SECONDS:-480}"

mkdir -p "$LOGDIR"
rm -f "$STATUS"

# The episode realm is destroyed and recreated on every launch; SOAP must be
# enabled at birth or the checkpoint tele has nothing to talk to.
VMANGOS_MANGOSD_CONFIG_OVERRIDES="$(python3 "$ROOT/tools/traverse_soap.py" env)"
export VMANGOS_MANGOSD_CONFIG_OVERRIDES

echo "traverse-wet: $RUN_SECONDS s headless run -> $RUN_LOG"
(
  cd "$FORK" &&
  PETREL_SWIM=1 nix develop "$FORK" --command \
    timeout "$RUN_SECONDS" nim r tools/launch_nim_player.nim -- \
    --league=race --bot=lua-bot \
    --lua-status-dir="$ROOT/local_data/traverse-status" \
    --lua-repo="$ROOT" --lua-entry=traverse \
    --presentation=headless
) >"$RUN_LOG" 2>&1 &
run_pid=$!

# Checkpoint tele, but only once the traverse episode container exists —
# find_traverse_container() otherwise falls back to any coworld-game
# container, i.e. the persistent realm, which must not be touched here.
(
  for _ in $(seq 1 150); do
    if docker ps --format '{{.Names}}' 2>/dev/null |
        grep -qE '(traverse|race).*coworld-game'; then
      break
    fi
    kill -0 "$run_pid" 2>/dev/null || exit 0
    sleep 2
  done
  # wet_start lands 1 yd under the surface at the cheese_01 pose: the lab
  # tests the swim, not the shoreline entry (which the lua-bot host cannot
  # do from the dry water_entry tele — no entry path; see the 2026-08-10
  # baseline run). The dry entry is the full-run problem.
  python3 "$ROOT/tools/traverse_checkpoint.py" apply "${TRAVERSE_WET_CHECKPOINT:-wet_start}" \
    --character Northbound --status "$STATUS" --timeout 300
) >"$TELE_LOG" 2>&1 &
tele_pid=$!

# CPU + status sampler (same starvation watch as the desert proof, plus the
# wet Number inputs: dist_goal sampled only while swimming in Aquatic Form).
{
  echo "# stamp pid pcpu rss etime comm"
  while kill -0 "$run_pid" 2>/dev/null; do
    now="$(date -u +%H:%M:%S)"
    top -b -d 1 -n 2 2>/dev/null | awk 'seen && ($NF == "player" || $NF ~ /mangosd/) { print "'"$now"' INST", $1, $9, $NF } /^top -/ { count++; seen = (count == 2) }'
    ps -eo pid,pcpu,rss,etime,args --no-headers |
      grep -E 'native_player_launcher/player|mangosd|launch_nim_player' |
      grep -v grep |
      while read -r line; do echo "$now $line"; done
    if [ -f "$STATUS" ]; then
      python3 - "$STATUS" "$now" <<'EOF' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
bot = s.get("bot") or {}
wet = 1 if (s.get("swimming") and s.get("form_spell") == 1066) else 0
print(f'{sys.argv[2]} STATUS beat={bot.get("beat")} x={bot.get("x")} '
      f'y={bot.get("y")} wet={wet} dist_goal={bot.get("dist_goal")} '
      f'stalled={bot.get("stalled_seconds")} '
      f'nav={s.get("nav_progress")} summary={s.get("summary")!r}')
EOF
    fi
    sleep 2
  done
} >"$CPU_LOG" 2>&1 &
sampler_pid=$!

wait "$run_pid"
code=$?
wait "$sampler_pid" 2>/dev/null
wait "$tele_pid" 2>/dev/null

echo "traverse-wet: run exited $code; samples -> $CPU_LOG; tele -> $TELE_LOG"
if [ -f "$STATUS" ]; then
  python3 - "$STATUS" "$CPU_LOG" <<'EOF'
import json, re, sys
s = json.load(open(sys.argv[1]))
bot = s.get("bot") or {}
best = None
try:
    for line in open(sys.argv[2], encoding="utf-8", errors="replace"):
        m = re.search(r"wet=1 dist_goal=([0-9.]+)", line)
        if m:
            d = float(m.group(1))
            best = d if best is None or d < best else best
except OSError:
    pass
print("final status:")
print(f'  summary      {s.get("summary")}')
print(f'  intent       {s.get("intent_kind")} / {s.get("intent_reason")}')
print(f'  nav          {s.get("nav_progress")} err={s.get("nav_error")!r}')
print(f'  beat         {bot.get("beat")}')
print(f'  position     x={bot.get("x")} y={bot.get("y")}')
print(f'  swimming     {s.get("swimming")} form={s.get("form_spell")}')
print(f'  dist_goal    {bot.get("dist_goal")}')
print(f'  NUMBER       best_planar_to_duskwallow_wet = '
      f'{best if best is not None else "no wet samples"}')
reason = s.get("intent_reason")
if reason == "duskwallow_coast":
    print("RESULT: PASS — holding at the Dustwallow coast")
elif reason == "run_over":
    print("RESULT: FAIL — died (speedrun over; find what stopped the movement)")
else:
    print("RESULT: INCOMPLETE — did not reach the duskwallow goal")
EOF
else
  echo "no lua-bot-status.json written — check $RUN_LOG"
fi
exit "$code"
