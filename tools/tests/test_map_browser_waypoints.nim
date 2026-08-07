## Map-browser waypoint graph extraction against the fork world catalog.
import std/unittest

import map_browser/[terrain3d, waypoints]

suite "waypoint graph":
  let graph = buildWaypointGraph()

  test "catalog routes yield a real graph":
    check graph.nodes.len > 50
    check graph.edges.len > 0
    for edge in graph.edges:
      check edge.a >= 0 and edge.a < graph.nodes.len
      check edge.b >= 0 and edge.b < graph.nodes.len
      check edge.a != edge.b

  test "great lift is present as a logical edge":
    var liftNodes = 0
    var liftEdges = 0
    for node in graph.nodes:
      if node.greatLift:
        inc liftNodes
    for edge in graph.edges:
      if edge.kind == wekLift:
        inc liftEdges
    check liftNodes > 0
    check liftEdges > 0

  test "travel-spell connections are flagged":
    var spellEdges = 0
    for edge in graph.edges:
      if edge.kind == wekSpell:
        inc spellEdges
    check spellEdges > 0

  test "activity regions expose city anchors":
    check activityRegions().len > 20

suite "zone terrain support":
  test "on-world kalimdor bounds are supported":
    check zoneTerrainSupported(ZoneWorldBounds(
      mapId: 1, minX: -7000, maxX: -6000, minY: -5000, maxY: -4000,
      label: "Tanaris", mapDirectory: "Kalimdor"
    ))

  test "battleground instance maps are off-world":
    check not zoneTerrainSupported(ZoneWorldBounds(
      mapId: 30, minX: -1739, maxX: 1085, minY: -2456, maxY: 1781,
      label: "Alterac Valley", mapDirectory: ""
    ))

  test "degenerate bounds are off-world":
    check not zoneTerrainSupported(ZoneWorldBounds(
      mapId: 1, minX: 100, maxX: 100, minY: 50, maxY: 50,
      label: "broken", mapDirectory: "Kalimdor"
    ))
