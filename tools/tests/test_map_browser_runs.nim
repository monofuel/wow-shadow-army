## Godview trajectory reader for the map-browser run visualizer.
import std/[os, unittest]

import map_browser/runs

let fixture =
  getCurrentDir() / "tools" / "tests" / "fixtures" / "godview_fixture.jsonl"

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
  test "beats and checkpoints load from the repo":
    let beats = loadTraverseBeats(getCurrentDir())
    check beats.len >= 5
    for beat in beats:
      check beat.mapId == 1'u32
    check loadTraverseCheckpoints(getCurrentDir()).len >= 3
