## City waypoint data for the map browser, extracted from the fork's authored
## world routes (roads, local transports, portals, boats) and the DBC taxi
## flight network. Pure data — rendering happens in the tool.

import
  std/[sets, tables],
  environment/contract/spatial_types,
  environment/client/world_catalogs/world_catalog_types,
  coworld_wow_sdk/[activity_catalog, authored_world_routes, route_graph, world_routes]

export activity_catalog, world_routes

type
  WaypointEdgeKind* = enum
    wekWalk
    wekLift
    wekSpell

  WaypointEdge* = object
    a*, b*: int
    kind*: WaypointEdgeKind

  WaypointGraph* = object
    nodes*: seq[WorldRouteNode]
    edges*: seq[WaypointEdge]

  TaxiPolyline* = object
    mapId*: uint32
    name*: string
    points*: seq[Position]

const GraphSeedNodeIds = [
  "great-lift-lower-dock",
  "alliance-wetlands-north"
]

proc edgeKind*(a, b: WorldRouteNode): WaypointEdgeKind =
  ## Classify one authored connection. `wekLift` is a ride between two
  ## vertical-transport nodes boarding the same local transport (great lift,
  ## elevator). `wekSpell` is a teleport-style public transition — a portal
  ## trigger or a boat/zeppelin crossing — whose endpoints share no walkable
  ## ground. Everything else is an ordinary walking leg.
  if a.verticalTransport and b.verticalTransport and
      a.localTransportEntry != 0'u32 and
      a.localTransportEntry == b.localTransportEntry:
    wekLift
  elif worldRouteEdgeUsesPublicTransition(a, b):
    wekSpell
  else:
    wekWalk

proc addRoute(graph: var WaypointGraph; route: WorldRoute) =
  ## Append every node and authored edge of one route to the graph.
  let base = graph.nodes.len
  for node in route.nodes:
    graph.nodes.add node
  for edge in route.graph.edges:
    if edge.first == edge.second:
      continue
    graph.edges.add WaypointEdge(
      a: base + edge.first,
      b: base + edge.second,
      kind: edgeKind(route.nodes[edge.first], route.nodes[edge.second])
    )

proc buildWaypointGraph*(): WaypointGraph =
  ## All authored routes reachable from activity regions + known seeds.
  var seeds: seq[string]
  for region in AuthoredActivityRegions:
    if region.routeNodeId.len > 0:
      seeds.add region.routeNodeId
  for id in GraphSeedNodeIds:
    seeds.add id

  var seenRoutes = initHashSet[int]()
  for id in seeds:
    let matched = worldRouteMatch(id)
    if matched.matchCount == 0 or matched.route.nodes.len == 0:
      continue
    if matched.routeIndex in seenRoutes:
      continue
    seenRoutes.incl matched.routeIndex
    result.addRoute(matched.route)

proc activityRegions*(): seq[AuthoredActivityRegion] =
  ## Authored activity regions (city and field anchors) for the overlay.
  for region in AuthoredActivityRegions:
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
