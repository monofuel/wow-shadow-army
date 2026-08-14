## Road waypoint JSONL loader for the map browser.
import std/[os, unittest]

import map_browser/roads

let fixture =
  getCurrentDir() / "tools" / "tests" / "fixtures" / "road_waypoints_fixture.jsonl"
let azerothArtifact =
  getCurrentDir() / "tools" / "data" / "road_waypoints_azeroth.jsonl"

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
    let roads = loadRoadWaypoints(getCurrentDir())
    check roads.len > 50
    var haveKalimdor = false
    var haveAzeroth = false
    for segment in roads:
      if segment.mapId == 1'u32:
        haveKalimdor = true
      elif segment.mapId == 0'u32:
        haveAzeroth = true
    check haveKalimdor
    if fileExists(azerothArtifact):
      check haveAzeroth

  test "missing dir is empty":
    check loadRoadWaypoints("/nonexistent").len == 0
