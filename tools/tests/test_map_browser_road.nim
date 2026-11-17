## Road waypoint JSONL loader for the map browser.
import std/[os, strformat, unittest]

import map_browser/roads

const
  SyntheticSegmentsPerMap = 30

let fixture =
  getCurrentDir() / "tools" / "tests" / "fixtures" / "road_waypoints_fixture.jsonl"

proc writeSyntheticRoadArtifact(path: string; mapName: string; mapId: int) =
  ## Write a synthetic per-continent road artifact with a meta header line.
  var text = &"""{{"meta": 1, "map": "{mapName}", "map_id": {mapId}}}""" & "\n"
  for i in 0 ..< SyntheticSegmentsPerMap:
    let x = float(i) * 10.0
    text.add &"""{{"id": "b{i:04}", "source": "baked", "pts": [[{x}, 0.0, 1.0], [{x}, 10.0, 1.0]]}}"""
    text.add "\n"
  writeFile(path, text)

suite "road waypoint parsing":
  test "fixture skips garbage and short segments":
    check fileExists(fixture)
    var segments: seq[RoadSegment]
    loadRoadWaypointsFile(fixture, segments)
    check segments.len == 3
    for segment in segments:
      check segment.mapId == 0'u32
    var hand: RoadSegment
    var foundHand = false
    for segment in segments:
      if segment.source == "hand":
        hand = segment
        foundHand = true
    check foundHand
    check hand.source == "hand"
    check hand.confidence == 1.0'f32
    check hand.id == "h0001"
    check hand.points.len == 2
    check hand.points[0].x == 100.0'f32
    check hand.points[0].y == 200.0'f32
    check hand.points[0].z == 300.0'f32
    check hand.points[1].x == 400.0'f32
    check hand.points[1].y == 500.0'f32
    check hand.points[1].z == 600.0'f32
    check segments[0].id == "b0001"
    check segments[0].source == "baked"
    check segments[0].points.len == 2
    check segments[0].points[0].x == 1.0'f32
    check segments[0].points[0].y == 2.0'f32
    check segments[0].points[0].z == 3.0'f32
    check segments[0].points[1].x == 4.0'f32
    check segments[0].points[1].y == 5.0'f32
    check segments[0].points[1].z == 6.0'f32
    check segments[1].id == "b0002"
    check segments[1].points.len == 3
    check segments[1].points[2].x == 70.0'f32
    check segments[1].points[2].y == 80.0'f32
    check segments[1].points[2].z == 90.0'f32

  test "repo artifacts load kalimdor and azeroth":
    let root = getTempDir() / "wsa_test_map_browser_road_" & $getCurrentProcessId()
    removeDir(root)
    createDir(root / "tools" / "data")
    defer: removeDir(root)
    writeSyntheticRoadArtifact(
      root / "tools" / "data" / "road_waypoints_kalimdor.jsonl", "kalimdor", 1)
    writeSyntheticRoadArtifact(
      root / "tools" / "data" / "road_waypoints_azeroth.jsonl", "azeroth", 0)
    let roads = loadRoadWaypoints(root)
    check roads.len == 2 * SyntheticSegmentsPerMap
    var kalimdorCount = 0
    var azerothCount = 0
    for segment in roads:
      if segment.mapId == 1'u32:
        inc kalimdorCount
      elif segment.mapId == 0'u32:
        inc azerothCount
    check kalimdorCount == SyntheticSegmentsPerMap
    check azerothCount == SyntheticSegmentsPerMap

  test "kalimdor artifact alone still loads":
    let root = getTempDir() / "wsa_test_map_browser_road_k_" & $getCurrentProcessId()
    removeDir(root)
    createDir(root / "tools" / "data")
    defer: removeDir(root)
    writeSyntheticRoadArtifact(
      root / "tools" / "data" / "road_waypoints_kalimdor.jsonl", "kalimdor", 1)
    let roads = loadRoadWaypoints(root)
    check roads.len == SyntheticSegmentsPerMap
    for segment in roads:
      check segment.mapId == 1'u32

  test "local road artifacts load kalimdor and azeroth":
    ## The baked artifacts are local-only; WSA_PRIVATE_INPUTS (default the
    ## repo root) points at them.
    let root = getEnv("WSA_PRIVATE_INPUTS", getCurrentDir())
    let dataDir = root / "tools" / "data"
    if not fileExists(dataDir / "road_waypoints_kalimdor.jsonl"):
      echo "  SKIP local road artifacts not present under ", dataDir
      skip()
    else:
      let roads = loadRoadWaypoints(root)
      check roads.len > 50
      var haveKalimdor = false
      var haveAzeroth = false
      for segment in roads:
        if segment.mapId == 1'u32:
          haveKalimdor = true
        elif segment.mapId == 0'u32:
          haveAzeroth = true
      check haveKalimdor
      if fileExists(dataDir / "road_waypoints_azeroth.jsonl"):
        check haveAzeroth

  test "missing dir is empty":
    check loadRoadWaypoints("/nonexistent").len == 0
