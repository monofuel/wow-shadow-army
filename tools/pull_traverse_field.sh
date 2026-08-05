#!/usr/bin/env bash
# Pull hosted Kalimdor Traverse episodes into a durable local cache for The System
# dashboard (ctf-bots tools/pull_field_data.sh pattern, solo-league simplified).
#
# Writes:
#   local_data/traverse/memberships_mine.json
#   local_data/traverse/episodes_mine.json
#   local_data/traverse/episodes_history.json  (merged, never drop old ids)
#
# Requires coworld CLI with Softmax auth. Prefer:
#   1) COWORLD_BIN or coworld on PATH
#   2) crewrift-prime-bots .venv/bin/coworld
#   3) nix develop in COWORLD_BOTS_REPO + uv run coworld
#
# Usage:
#   tools/pull_traverse_field.sh
#   make traverse-field
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTDIR="$ROOT/local_data/traverse"
LOGDIR="$ROOT/local_data/brain-logs"
mkdir -p "$OUTDIR" "$LOGDIR"

LEAGUE=${TRAVERSE_LEAGUE:-league_0f38d762-930a-41d3-9979-1858dd52c1ae}
DIV=${TRAVERSE_DIVISION:-div_b50e0091-514d-4406-837a-420ef9c372ca}
LIMIT=${TRAVERSE_EPISODE_LIMIT:-200}
BOTS_REPO=${COWORLD_BOTS_REPO:-/home/monofuel/Documents/Projects/Softmax/crewrift-prime-bots}
LOCK="$LOGDIR/traverse-field-pull.lock"

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "traverse-field: another pull holds $LOCK — skip"
  exit 0
fi
echo $$ >"$LOGDIR/traverse-field-pull.pid"

resolve_coworld() {
  if [ -n "${COWORLD_BIN:-}" ] && [ -x "$COWORLD_BIN" ]; then
    echo "$COWORLD_BIN"
    return 0
  fi
  if command -v coworld >/dev/null 2>&1; then
    command -v coworld
    return 0
  fi
  if [ -x "$BOTS_REPO/.venv/bin/coworld" ]; then
    echo "$BOTS_REPO/.venv/bin/coworld"
    return 0
  fi
  return 1
}

run_cw_json() {
  local dest=$1
  shift
  local raw
  if [ -n "${CW_BIN:-}" ]; then
    raw=$("$CW_BIN" "$@" 2>/dev/null) || {
      echo "error: coworld failed: $*" >&2
      return 1
    }
  else
    raw=$(
      cd "$BOTS_REPO"
      nix develop --command bash -c "uv run coworld $*" 2>/dev/null
    ) || {
      echo "error: coworld (nix) failed: $*" >&2
      return 1
    }
  fi
  python3 -c "
import json,sys
t=sys.stdin.read()
obj=None
for i,ch in enumerate(t):
    if ch not in '[{':
        continue
    try:
        obj=json.loads(t[i:])
        break
    except Exception:
        continue
if obj is None:
    sys.stderr.write('error: no JSON in coworld output\\n')
    sys.exit(2)
open(sys.argv[1],'w').write(json.dumps(obj)+'\\n')
n=len(obj) if hasattr(obj,'__len__') else type(obj).__name__
print(f'  wrote {sys.argv[1]} ({n})')
" "$dest" <<<"$raw"
}

CW_BIN=""
if resolve_coworld >/tmp/traverse-cw-bin.$$ 2>/dev/null; then
  CW_BIN=$(cat /tmp/traverse-cw-bin.$$)
  rm -f /tmp/traverse-cw-bin.$$
  echo "== traverse-field league=$LEAGUE div=$DIV limit=$LIMIT via $CW_BIN =="
else
  rm -f /tmp/traverse-cw-bin.$$
  if [ ! -d "$BOTS_REPO" ]; then
    echo "error: no coworld on PATH and BOTS_REPO missing: $BOTS_REPO" >&2
    exit 2
  fi
  echo "== traverse-field league=$LEAGUE div=$DIV limit=$LIMIT via nix+uv ($BOTS_REPO) =="
fi

echo "→ memberships --mine"
if [ -n "$CW_BIN" ]; then
  run_cw_json "$OUTDIR/memberships_mine.json" \
    memberships -l "$LEAGUE" --mine --limit 1000 --json
else
  run_cw_json "$OUTDIR/memberships_mine.json" \
    "memberships -l '$LEAGUE' --mine --limit 1000 --json"
fi

echo "→ episodes --mine (division)"
if [ -n "$CW_BIN" ]; then
  run_cw_json "$OUTDIR/episodes_mine.json" \
    episodes -d "$DIV" --mine --limit "$LIMIT" --json
else
  run_cw_json "$OUTDIR/episodes_mine.json" \
    "episodes -d '$DIV' --mine --limit $LIMIT --json"
fi

echo "→ merge into episodes_history.json"
python3 - <<PY
import json
from pathlib import Path
out = Path("$OUTDIR")
hist_path = out / "episodes_history.json"
pull = json.loads((out / "episodes_mine.json").read_text())
if not isinstance(pull, list):
    pull = []
hist = []
if hist_path.is_file():
    try:
        hist = json.loads(hist_path.read_text())
        if not isinstance(hist, list):
            hist = []
    except Exception:
        hist = []

by_id = {}
for ep in hist:
    eid = ep.get("id") or ep.get("episode_id")
    if eid:
        by_id[eid] = ep
before = len(by_id)
for ep in pull:
    eid = ep.get("id") or ep.get("episode_id")
    if not eid:
        continue
    prev = by_id.get(eid)
    if prev is None:
        by_id[eid] = ep
        continue
    def score(e):
        st = (e.get("status") or "").lower()
        n = len(e.get("scores") or [])
        has_replay = 1 if e.get("replay_url") else 0
        return (1 if st in ("completed", "complete", "succeeded") else 0, has_replay, n)
    if score(ep) >= score(prev):
        by_id[eid] = ep

merged = list(by_id.values())
merged.sort(
    key=lambda e: e.get("completed_at") or e.get("running_at") or e.get("created_at") or "",
    reverse=True,
)
hist_path.write_text(json.dumps(merged) + "\n")
print(f"  history: {before} → {len(merged)} episodes (pull_n={len(pull)})")
labels = {}
for ep in merged:
    for p in ep.get("participants") or []:
        if p.get("is_filler"):
            continue
        lab = p.get("label") or f"{p.get('policy_name')}:v{p.get('version')}"
        if lab:
            labels[lab] = labels.get(lab, 0) + 1
print("  versions:", ", ".join(f"{k}×{v}" for k, v in sorted(labels.items())))
with_replay = sum(1 for e in merged if e.get("replay_url"))
print(f"  with_replay={with_replay}")
PY

echo "traverse-field: done"
rm -f "$LOGDIR/traverse-field-pull.pid"
