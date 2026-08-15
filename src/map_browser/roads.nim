## Road waypoint overlay artifacts for the map browser.
##
## Each JSONL starts with a meta object (`meta`, `map`, `map_id`; default
## map_id 1). Every following line is a segment: `id`, `source` (baked,
## minimap_ribbon, terrain_medial, visual_gap_bridge, or legacy hand),
## `pts` as world `[x, y, z]` with z already baked. Optional `note`. Missing
## files are skipped.

import
  std/[json, os]

type
  RoadPoint* = object
    x*, y*, z*: float32

  RoadSegment* = object
    id*, source*: string
    confidence*: float32
    mapId*: uint32
    points*: seq[RoadPoint]

const
  KalimdorRoadFile = "road_waypoints_kalimdor.jsonl"
  AzerothRoadFile = "road_waypoints_azeroth.jsonl"

proc parseRoadPoint(node: JsonNode): bool =
  ## True when node is an array of at least three numbers.
  result = node.kind == JArray and node.len >= 3
  if not result:
    return
  for i in 0 .. 2:
    if node[i].kind notin {JInt, JFloat}:
      return false

proc loadRoadWaypointsFile*(path: string; segments: var seq[RoadSegment]) =
  ## Append valid segments from one JSONL artifact. A missing file is a no-op.
  if not fileExists(path):
    return
  var mapId = 1'u32
  try:
    for line in lines(path):
      if line.len == 0:
        continue
      var obj: JsonNode
      try:
        obj = parseJson(line)
      except CatchableError:
        continue
      if obj.kind != JObject:
        continue
      if "meta" in obj:
        mapId = uint32(obj{"map_id"}.getInt(1))
        continue
      let pts = obj{"pts"}
      if pts.isNil or pts.kind != JArray:
        continue
      var points: seq[RoadPoint]
      for pt in pts:
        if not parseRoadPoint(pt):
          continue
        points.add RoadPoint(
          x: pt[0].getFloat().float32,
          y: pt[1].getFloat().float32,
          z: pt[2].getFloat().float32
        )
      if points.len < 2:
        continue
      segments.add RoadSegment(
        id: obj{"id"}.getStr(),
        source: obj{"source"}.getStr(),
        confidence: float32(obj{"confidence"}.getFloat(
          if obj{"source"}.getStr() == "visual_gap_bridge": 0.0 else: 1.0)),
        mapId: mapId,
        points: points
      )
  except CatchableError:
    discard

proc loadRoadWaypoints*(repoDir: string): seq[RoadSegment] =
  ## Load both continent artifacts under `repoDir/tools/data/`.
  loadRoadWaypointsFile(repoDir / "tools" / "data" / KalimdorRoadFile, result)
  loadRoadWaypointsFile(repoDir / "tools" / "data" / AzerothRoadFile, result)
