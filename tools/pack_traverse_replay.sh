#!/usr/bin/env bash
# Package the latest local traverse captures into run/replay.json.z so
# `make traverse-replay` can open the run we just finished.
#
# Why this exists: official game.server only writes results.json + replay.json.z
# on a clean episode finish (max ticks / completion). Our local harness
# (traverse-pol / dashboard Start) stops army_host early then `cleanup`s the
# container — so the official finalizer never runs and godview/worldwire sit
# orphaned under captures/. This packs those captures offline via upstream
# finalize_replay.
#
# Usage:
#   tools/pack_traverse_replay.sh
#   TRAVERSE_CAPTURES_DIR=... TRAVERSE_RUN_DIR=... tools/pack_traverse_replay.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${UPSTREAM:-$ROOT/../coworld-vanilla-wow}"
RUNTIME_ROOT="${TRAVERSE_REPLAY_RUNTIME:-$HOME/.coworld/player/launcher_units/runtime}"

if [[ ! -d "$UPSTREAM" ]]; then
  echo "error: upstream missing: $UPSTREAM" >&2
  exit 1
fi

# Resolve captures + run dirs: env override, else newest unit with godview.
if [[ -z "${TRAVERSE_CAPTURES_DIR:-}" || -z "${TRAVERSE_RUN_DIR:-}" ]]; then
  latest_godview=""
  latest_mtime=0
  if [[ -d "$RUNTIME_ROOT" ]]; then
    while IFS= read -r -d '' f; do
      m=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f")
      if (( m >= latest_mtime )); then
        latest_mtime=$m
        latest_godview=$f
      fi
    done < <(find "$RUNTIME_ROOT" -type f -path '*/leagues/*/captures/godview_*.jsonl' -print0 2>/dev/null)
  fi
  if [[ -z "$latest_godview" ]]; then
    echo "error: no traverse godview captures under $RUNTIME_ROOT" >&2
    exit 1
  fi
  CAPTURES_DIR="$(cd "$(dirname "$latest_godview")" && pwd)"
  RUN_DIR="$(cd "$CAPTURES_DIR/../run" && pwd)"
  mkdir -p "$RUN_DIR"
else
  CAPTURES_DIR="$(cd "$TRAVERSE_CAPTURES_DIR" && pwd)"
  RUN_DIR="$(cd "$TRAVERSE_RUN_DIR" && pwd)"
  mkdir -p "$RUN_DIR"
fi

echo "[pack-traverse-replay] captures=$CAPTURES_DIR"
echo "[pack-traverse-replay] run=$RUN_DIR"

cd "$UPSTREAM"
export PACK_CAPTURES_DIR="$CAPTURES_DIR"
export PACK_RUN_DIR="$RUN_DIR"
uv run python - <<'PY'
from __future__ import annotations

import json
import math
import os
import time
from pathlib import Path

# Upstream 2026-08-14: game.replay -> game.replays.artifact,
# game.replay_sessions -> game.replays.sessions.
from game.replays.artifact import (
    ReplayCapturePov,
    ReplayExtractionRequest,
    ReplayPlaybackWindowRequest,
    finalize_replay,
)
from game.replays.sessions import read_godview_sessions
from game.results import ResultsArtifact

cap = Path(os.environ["PACK_CAPTURES_DIR"])
run = Path(os.environ["PACK_RUN_DIR"])
START_X = -9187.0
GOAL_X = 6687.333052

godviews = sorted(cap.glob("godview_*.jsonl"), key=lambda p: p.stat().st_mtime)
if not godviews:
    raise SystemExit(f"no godview_*.jsonl in {cap}")
path = godviews[-1]
sessions = read_godview_sessions(path, map_id=1)
if not sessions:
    raise SystemExit(f"no map-1 sessions in {path.name}")
session = sessions[-1]

by_guid: dict[int, str] = {}
last_player: dict | None = None
for frame in session.frames:
    for player in frame.players:
        guid = player.get("raw_guid")
        name = player.get("name")
        if isinstance(guid, int) and guid > 0 and isinstance(name, str) and name:
            by_guid[guid] = name
        if isinstance(name, str) and name.casefold() == "northbound":
            last_player = player
if not by_guid:
    raise SystemExit(f"{path.name}: no player POV roster")
if last_player is None:
    # Fall back to any last player in the stream.
    for frame in reversed(session.frames):
        if frame.players:
            last_player = frame.players[-1]
            break
if last_player is None:
    raise SystemExit(f"{path.name}: empty player frames")

x = float(last_player.get("x") or 0.0)
y = float(last_player.get("y") or 0.0)
z = float(last_player.get("z") or 0.0)
map_id = int(last_player.get("map_id") or session.map_id or 1)
level = int(last_player.get("level") or 60)
northing = max(0.0, min(x, GOAL_X) - START_X)
score_valid = level == 60 and map_id == 1
invalid_reason = None if score_valid else (
    "character_left_kalimdor" if map_id != 1 else "character_not_level_60"
)

# Prefer reshaping a prior official results.json; otherwise invent a minimal one
# from the last scored artifact shape upstream validates.
template_path = run / "results.json"
if template_path.is_file():
    base = json.loads(template_path.read_text())
else:
    # Upstream 2026-08-14: every per-slot list is typed and non-empty.
    seat_name = (last_player.get("name") or "Northbound")
    char_score = {
        "slot": 0, "name": seat_name, "character_found": True,
        "character_id": "1", "character_name": seat_name,
        "level": level, "xp": 0, "total_xp": 0,
    }
    base = {
        "game": "vanilla_wow_local",
        "scenario_id": "kalimdor-south-to-north",
        "scores": [northing],
        "score_metric": "kalimdor_northing_yards",
        "session_score_metric": "top_character_xp_gained",
        "session_xp_gained": [0],
        "session_scores": [{
            "slot": 0, "name": seat_name,
            "start_character_id": "1", "start_character_name": seat_name,
            "start_total_xp": 0,
            "end_character_id": "1", "end_character_name": seat_name,
            "end_total_xp": 0, "xp_gained": 0,
        }],
        "leaderboard": [{
            "rank": 1, "slot": 0, "name": seat_name,
            "character_name": seat_name, "level": level,
            "score_metric": "kalimdor_northing_yards",
            "score": northing, "xp_gained": 0, "total_xp": 0,
        }],
        "initial_character_scores": [dict(char_score)],
        "character_scores": [dict(char_score)],
        "episode_xp_awarded": [0],
        "outcome": "completed",
        "objectives": [{"id": "kalimdor-south-to-north", "complete": False}],
        "deaths": [0],
        "leveling": None,
        "tower": None,
        "dungeon": None,
        "kalimdor_traversal": {},
        "ticks": len(session.frames),
    }

base["scores"] = [northing]
base["score_metric"] = "kalimdor_northing_yards"
base["scenario_id"] = base.get("scenario_id") or "kalimdor-south-to-north"
base["ticks"] = len(session.frames)
kt = dict(base.get("kalimdor_traversal") or {})
kt.update(
    {
        # Upstream results schema v2 (2026-08-14): full goal pose +
        # radius are required; protocol literal bumped.
        "protocol": "vanilla_wow.kalimdor_traversal.v2",
        "score_metric": "kalimdor_northing_yards",
        "map_id": map_id,
        "zone_id": kt.get("zone_id"),
        "world_x": x,
        "world_y": y,
        "world_z": z,
        "start_world_x": START_X,
        "goal_world_x": GOAL_X,
        "goal_world_y": -4647.667,
        "goal_world_z": 721.678,
        "goal_radius_yards": 50.0,
        "goal_distance_yards": (
            math.dist((x, y, z), (GOAL_X, -4647.667, 721.678))
            if score_valid else None
        ),
        "northing_yards": northing,
        "reached_goal": bool(score_valid and x >= GOAL_X),
        "score_valid": score_valid,
        "invalid_reason": invalid_reason,
    }
)
base["kalimdor_traversal"] = kt

for row in base.get("leaderboard") or []:
    if isinstance(row, dict):
        row["score"] = northing
        row["score_metric"] = "kalimdor_northing_yards"

results = ResultsArtifact.model_validate(base)
extraction = ReplayExtractionRequest(
    capture_dir=cap,
    simulation_time_scale=1,
    povs=[
        ReplayCapturePov(guid=guid, name=name)
        for guid, name in sorted(by_guid.items(), key=lambda item: item[1].casefold())
    ],
    playback_window=ReplayPlaybackWindowRequest(
        kind="episode",
        started_wall_clock_ms=session.started_wall_clock_ms,
        ended_wall_clock_ms=session.ended_wall_clock_ms,
        started_server_ms=session.started_server_ms,
        ended_server_ms=session.ended_server_ms,
        map_id=session.map_id,
        instance_id=session.instance_id,
        closed_cleanly=bool(session.closed_cleanly),
    ),
)
finalized = finalize_replay(
    extraction=extraction,
    scope="episode",
    scenario_id=str(base["scenario_id"]),
    events=[],
    results=results,
    godview_jsonl=path.read_bytes(),
)

ts = int(time.time())
history = run / "history"
history.mkdir(parents=True, exist_ok=True)
hist_path = history / f"replay-{ts}.json.z"
hist_path.write_bytes(finalized.payload)
(run / "replay.json.z").write_bytes(finalized.payload)
(run / "results.json").write_text(json.dumps(base, indent=2) + "\n")
print(
    f"[pack-traverse-replay] wrote {run / 'replay.json.z'} "
    f"({(run / 'replay.json.z').stat().st_size} bytes) "
    f"northing={northing:.1f} from {path.name}"
)
print(f"[pack-traverse-replay] history {hist_path}")
PY
