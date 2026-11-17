## Map-browser waypoint graph extraction against the fork world catalog.
import std/unittest

import map_browser/waypoints

proc edgeKindBetween(graph: WaypointGraph; first, second: string): seq[WaypointEdgeKind] =
  ## Kinds of every graph edge joining nodes with the two ids, either direction.
  for edge in graph.edges:
    let
      a = graph.nodes[edge.a].id
      b = graph.nodes[edge.b].id
    if (a == first and b == second) or (a == second and b == first):
      result.add edge.kind

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
      if node.verticalTransport:
        inc liftNodes
    for edge in graph.edges:
      if edge.kind == wekLift:
        inc liftEdges
    check liftNodes > 0
    check liftEdges > 0
    check wekLift in graph.edgeKindBetween(
      "great-lift-lower-dock", "great-lift-transition")

  test "travel-spell connections are flagged":
    var spellEdges = 0
    for edge in graph.edges:
      if edge.kind == wekSpell:
        inc spellEdges
    check spellEdges > 0
    check wekSpell in graph.edgeKindBetween(
      "darnassus-bank-portal", "ruttheran-portal-exit")
    check wekSpell in graph.edgeKindBetween(
      "ruttheran-boat-board", "auberdine-boat-exit")

  test "activity regions expose city anchors":
    check activityRegions().len > 20
