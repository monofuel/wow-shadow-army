## Godview trajectory reader for the map-browser run visualizer.
import std/[json, os, unittest]

import map_browser/runs

let fixture =
  getCurrentDir() / "tools" / "tests" / "fixtures" / "godview_synthetic.jsonl"

proc writeSyntheticTraverseConfig(root: string) =
  ## Write a synthetic beats file and checkpoint table under root.
  createDir(root / "lua" / "config")
  createDir(root / "tools")
  var beats = newJArray()
  for i in 0 ..< 5:
    beats.add %*{"id": "synthetic_" & $i, "x": -9000.0 + 100.0 * float(i),
      "y": -2500.0, "z": 10.0, "radius": 25.0}
  writeFile(root / "lua" / "config" / "traverse_beats.json",
    $(%*{"map_id": 1, "goal_id": "synthetic_4", "beats": beats}))
  writeFile(root / "tools" / "traverse_checkpoints.json", $(%*{
    "spawn": {"map_id": 1, "x": -9187.0, "y": -2530.0, "z": 14.0},
    "midway": {"map_id": 1, "x": -8800.0, "y": -2500.0, "z": 10.0,
      "tele_name": "synthetic_midway"},
    "finish": {"map_id": 1, "x": -8600.0, "y": -2500.0, "z": 10.0,
      "tele_name": "synthetic_finish"}
  }))

suite "traverse run parsing":
  test "northing yards":
    check northingYards(TraverseStartX) == 0.0'f32
    check northingYards(TraverseStartX - 100.0'f32) == 0.0'f32
    check int(northingYards(0.0'f32)) == 9187
    check int(northingYards(20000.0'f32)) == int(TraverseGoalX + 9187.0'f32)

  test "fixture parses with decimation and northing":
    check fileExists(fixture)
    let run = parseTraverseRun(fixture)
    check run.ok
    check run.error.len == 0
    check run.mapId == 1'u32
    check run.frameCount == 3
    check run.points.len >= 2
    check run.points[0].x == -9187.0'f32
    check run.points[^1].x == -9000.0'f32
    check run.durationSec == 1.0
    check int(run.maxNorthing) == 187

  test "missing player reports an error":
    let run = parseTraverseRun(
      getCurrentDir() / "tools" / "tests" / "fixtures" / "does_not_exist.jsonl")
    check not run.ok

suite "traverse overlays config":
  test "beats and checkpoints load from a repo root":
    let root = getTempDir() / "wsa_test_map_browser_runs_" & $getCurrentProcessId()
    removeDir(root)
    writeSyntheticTraverseConfig(root)
    defer: removeDir(root)
    let beats = loadTraverseBeats(root)
    check beats.len == 5
    for beat in beats:
      check beat.mapId == 1'u32
      check beat.radius == 25.0'f32
    check beats[0].id == "synthetic_0"
    check beats[^1].x == -8600.0'f32
    let checkpoints = loadTraverseCheckpoints(root)
    check checkpoints.len == 3
    for checkpoint in checkpoints:
      check checkpoint.mapId == 1'u32

  test "local beats and checkpoints load":
    ## The recorded route and checkpoint table are local-only;
    ## WSA_PRIVATE_INPUTS (default the repo root) points at them.
    let root = getEnv("WSA_PRIVATE_INPUTS", getCurrentDir())
    if not fileExists(root / "lua" / "config" / "traverse_beats.json") or
        not fileExists(root / "tools" / "traverse_checkpoints.json"):
      echo "  SKIP local traverse config not present under ", root
      skip()
    else:
      let beats = loadTraverseBeats(root)
      check beats.len >= 5
      for beat in beats:
        check beat.mapId == 1'u32
      check loadTraverseCheckpoints(root).len >= 3

  test "missing traverse config is empty":
    check loadTraverseBeats("/nonexistent").len == 0
    check loadTraverseCheckpoints("/nonexistent").len == 0
