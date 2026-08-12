## City waypoint data for the map browser, extracted from the fork's
## real-playerbot world catalog (routes, great lifts, travel spells) and the
## DBC taxi flight network. Pure data — rendering happens in the tool.
##
## The fork keeps route edges private; they are reconstructed here by probing
## worldRoutePath for adjacent pairs (a direct edge is a 2-node path).

import
  std/[sets, tables],
  environment/contract/spatial_types,
  environment/client/common,
  environment/client/world_catalogs/world_catalog_types,
  bots/real_playerbot/policy/world_catalog

type
  WaypointEdgeKind* = enum
    wekWalk
    wekLift
    wekSpell

  WaypointEdge* = object
    a*, b*: int
    kind*: WaypointEdgeKind

  WaypointGraph* = object
    nodes*: seq[RealPlayerBotWorldNode]
    edges*: seq[WaypointEdge]

  TaxiPolyline* = object
    mapId*: uint32
    name*: string
    points*: seq[Position]

const GraphSeedNodeIds = [
  "great-lift-lower-dock",
  "alliance-wetlands-north"
]

proc edgeKind(a, b: RealPlayerBotWorldNode): WaypointEdgeKind =
  if a.greatLift or b.greatLift:
    wekLift
  elif a.travelSpellId != 0'u32 or b.travelSpellId != 0'u32:
    wekSpell
  else:
    wekWalk

proc addRoute(graph: var WaypointGraph; route: RealPlayerBotWorldRoute) =
  let base = graph.nodes.len
  for node in route.nodes:
    graph.nodes.add node
  for i in 0 ..< route.nodes.len:
    for j in i + 1 ..< route.nodes.len:
      if worldRoutePath(route, i, j).len == 2 or
          worldRoutePath(route, j, i).len == 2:
        graph.edges.add WaypointEdge(
          a: base + i,
          b: base + j,
          kind: edgeKind(route.nodes[i], route.nodes[j])
        )

proc buildWaypointGraph*(): WaypointGraph =
  ## All catalog routes reachable from activity regions + known seeds.
  var seeds: seq[string]
  for region in RealPlayerBotActivityRegions:
    if region.routeNodeId.len > 0:
      seeds.add region.routeNodeId
  for id in GraphSeedNodeIds:
    seeds.add id

  var seenRoutes = initHashSet[string]()
  for id in seeds:
    let matched = worldRouteMatch(id)
    if matched.matchCount == 0 or matched.route.nodes.len == 0:
      continue
    let routeKey = matched.route.nodes[0].id
    if routeKey in seenRoutes:
      continue
    seenRoutes.incl routeKey
    result.addRoute(matched.route)

proc activityRegions*(): seq[RealPlayerBotActivityRegion] =
  for region in RealPlayerBotActivityRegions:
    result.add region

proc taxiPolylines*(
  catalog: WorldCatalog;
  everyNth = 4
): seq[TaxiPolyline] =
  ## Flight paths as decimated world polylines (first/last always kept).
  proc nodeName(nodeId: uint32): string =
    if nodeId in catalog.taxiNodes:
      catalog.taxiNodes[nodeId].name
    else:
      ""

  for path in catalog.taxiPaths.values:
    if path.pathId notin catalog.taxiPathNodes:
      continue
    var pathNodes = catalog.taxiPathNodes[path.pathId]
    for i in 1 ..< pathNodes.len:
      var j = i
      while j > 0 and pathNodes[j - 1].sequence > pathNodes[j].sequence:
        swap(pathNodes[j - 1], pathNodes[j])
        dec j
    if pathNodes.len < 2:
      continue
    var line = TaxiPolyline(
      mapId: uint32(pathNodes[0].location.mapId),
      name: nodeName(path.fromNodeId) & " → " & nodeName(path.toNodeId)
    )
    for index, pathNode in pathNodes:
      if index mod max(everyNth, 1) == 0 or index == pathNodes.len - 1:
        line.points.add pathNode.location.position
    result.add line
