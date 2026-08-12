## Map browser stub: headless catalog + waypoint graph smoke until the
## bird's-eye viewer lands.

import
  std/[math, os, strutils],
  environment/client/localpaths,
  environment/client/world_catalogs,
  map_browser/[waypoints, wdl_terrain]

proc loadMapCatalog(): WorldCatalog =
  ## Load DBC world catalog; fall back to defaults if missing or unloadable.
  let envDir = getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR").strip()
  let dbcDir =
    if envDir.len > 0:
      envDir / "dbc"
    else:
      defaultExtractedDataDir() / "dbc"
  if dirExists(dbcDir):
    try:
      result = loadWorldCatalog(dbcDir)
    except CatchableError:
      result = loadDefaultWorldCatalog()
  else:
    result = loadDefaultWorldCatalog()

proc main() =
  ## Headless smoke under MAP_BROWSER_ONCE; otherwise refuse the GUI path.
  let once = getEnv("MAP_BROWSER_ONCE").strip().toLowerAscii()
  if once in ["1", "true", "yes"]:
    let catalog = loadMapCatalog()
    echo "map_browser: worldMapAreas=", catalog.worldMapAreas.len
    let graph = buildWaypointGraph()
    var liftEdges = 0
    for edge in graph.edges:
      if edge.kind == wekLift:
        inc liftEdges
    echo "map_browser: waypoint graph nodes=", graph.nodes.len,
      " edges=", graph.edges.len, " lift-edges=", liftEdges
    doAssert graph.nodes.len > 50
    doAssert liftEdges > 0
    let taxi = taxiPolylines(catalog)
    echo "map_browser: taxi paths=", taxi.len
    doAssert taxi.len > 10

    let mesh = loadContinentMesh(1'u32)
    echo "map_browser: WDL Kalimdor tiles=", mesh.tileCount,
      " vertices=", mesh.vertices.len,
      " minZ=", mesh.minZ, " maxZ=", mesh.maxZ
    doAssert mesh.tileCount > 500
    doAssert mesh.vertices.len > 100_000
    doAssert mesh.minZ < 0
    doAssert mesh.maxZ > 500

    var
      mapNodes = 0
      aligned = 0
    for node in graph.nodes:
      if node.point.mapId != 1'u32:
        continue
      inc mapNodes
      let sample = sampleHeight(mesh, node.point.x, node.point.y)
      if sample == sample and abs(sample - node.point.z) < 250.0'f32:
        inc aligned
    let pct =
      if mapNodes > 0:
        100.0 * float(aligned) / float(mapNodes)
      else:
        0.0
    echo "map_browser: WDL alignment ", aligned, "/", mapNodes,
      " (", formatFloat(pct, ffDecimal, 1), "%)"
    doAssert mapNodes > 0
    doAssert aligned * 100 >= mapNodes * 70

    quit 0

  else:
    echo "map_browser: 3D viewer rebuild in progress; use MAP_BROWSER_ONCE=1"
    quit 1

when isMainModule:
  main()
