## Stock WorldMapFrame surface levels: World → continent → zone.
## Uses fork catalog + processMapClick / worldMapSurfaceFor.

import
  std/[os, strutils],
  vmath,
  environment/client/[common, localpaths, world_catalogs, world_maps],
  environment/client/world_catalogs/model,
  map_browser/assets

type
  MapLevel* = enum
    MapLevelWorld
    MapLevelContinent
    MapLevelZone

  SurfaceState* = object
    level*: MapLevel
    worldLevel*: bool
    surface*: WorldMapSurface ## meaningful when not world level
    fileName*: string         ## BLP folder token: World / Kalimdor / Durotar
    areaMapId*: uint32        ## WorldMapArea id for overlay lookup (0 = none)
    label*: string
    status*: string

proc extractedDbcDir*(): string {.raises: [].} =
  ## Prefer env (Makefile sets it), else fork localpaths default.
  let envDir = getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR").strip()
  if envDir.len > 0:
    return envDir / "dbc"
  defaultExtractedDataDir() / "dbc"

proc loadMapCatalog*(): WorldCatalog {.raises: [].} =
  ## DBC world catalog + continent ZMP grids for zone drill.
  let dbcDir = extractedDbcDir()
  if dirExists(dbcDir):
    try:
      result = loadWorldCatalog(dbcDir)
    except CatchableError:
      result = loadDefaultWorldCatalog()
  else:
    result = loadDefaultWorldCatalog()

  var loaded = 0
  for entry in WorldMapZoneMaskLogicalPaths:
    let path = findZmpFile(entry.path)
    if path.len == 0:
      continue
    try:
      let data = readFile(path)
      if result.loadWorldMapZoneMaskData(MapId(entry.mapId), data):
        inc loaded
    except CatchableError:
      discard
  if loaded == 0:
    # Zone drill needs ZMPs; world→continent still works from WorldMapContinent.
    discard

proc worldSurfaceState*(): SurfaceState {.raises: [].} =
  SurfaceState(
    level: MapLevelWorld,
    worldLevel: true,
    fileName: WorldMapSurfaceFile,
    areaMapId: 0'u32,
    label: "World",
    status: "click a continent · Esc/right-click zoom out"
  )

proc applyContinent*(
  catalog: WorldCatalog;
  mapId: MapId
): SurfaceState {.raises: [].} =
  let surface = catalog.worldMapSurfaceFor(mapId, 0'u32)
  if not surface.found:
    result = worldSurfaceState()
    result.status = "continent not found for map " & $uint32(mapId)
    return
  result = SurfaceState(
    level: MapLevelContinent,
    worldLevel: false,
    surface: surface,
    fileName:
      if surface.fileName.len > 0: surface.fileName
      else: $uint32(mapId),
    areaMapId: surface.area.areaMapId,
    label: surface.label,
    status: "click a zone · Esc/right-click zoom out"
  )

proc applyZone*(
  catalog: WorldCatalog;
  mapId: MapId;
  areaId: uint32
): SurfaceState {.raises: [].} =
  let surface = catalog.worldMapSurfaceFor(mapId, areaId)
  if not surface.found or surface.areaId == 0'u32:
    # Fall back to continent if zone DBC row missing.
    result = catalog.applyContinent(mapId)
    result.status = "zone area " & $areaId & " not in WorldMapArea"
    return
  let fileName =
    if surface.fileName.len > 0:
      surface.fileName
    else:
      surface.label.replace(" ", "")
  result = SurfaceState(
    level: MapLevelZone,
    worldLevel: false,
    surface: surface,
    fileName: fileName,
    areaMapId: surface.area.areaMapId,
    label: surface.label,
    status: "zone view (fully revealed) · Esc/right-click zoom out"
  )

proc drillIn*(
  catalog: WorldCatalog;
  state: SurfaceState;
  uv: Vec2
): SurfaceState {.raises: [].} =
  ## ProcessMapClick-style drill one level deeper.
  if state.worldLevel or state.level == MapLevelWorld:
    let click = catalog.processMapClick(uv, worldLevel = true)
    if click.hasContinent:
      result = catalog.applyContinent(click.continentMapId)
      if result.label.len == 0:
        result.label = click.label
      return
    result = state
    result.status = "no continent under click"
    return

  if state.level == MapLevelContinent and state.surface.found:
    let click = catalog.processMapClick(
      uv,
      surface = state.surface,
      mapId = state.surface.mapId
    )
    if click.hasZone and click.areaId != 0'u32:
      # zoneMapId on MapClickResult is WorldMapArea.areaMapId, not map id —
      # keep the continent mapId from the current surface.
      result = catalog.applyZone(state.surface.mapId, click.areaId)
      if result.label.len == 0 and click.label.len > 0:
        result.label = click.label
      return
    result = state
    result.status = "no zone under click"
    return

  result = state
  result.status = "already at zone · zoom out to leave"

proc zoomOut*(
  catalog: WorldCatalog;
  state: SurfaceState
): SurfaceState {.raises: [].} =
  case state.level
  of MapLevelWorld:
    result = worldSurfaceState()
    result.status = "already at world"
  of MapLevelContinent:
    result = worldSurfaceState()
  of MapLevelZone:
    if state.surface.found:
      result = catalog.applyContinent(state.surface.mapId)
    else:
      result = worldSurfaceState()

proc hoverAt*(
  catalog: WorldCatalog;
  state: SurfaceState;
  uv: Vec2
): WorldMapAreaHover {.raises: [].} =
  ## Stock UpdateMapHighlight for the current surface (geometry + label).
  if state.worldLevel or state.level == MapLevelWorld:
    catalog.updateMapHighlight(uv, worldLevel = true)
  elif state.surface.found:
    catalog.updateMapHighlight(
      uv,
      surface = state.surface,
      mapId = state.surface.mapId
    )
  else:
    WorldMapAreaHover()

proc hoverLabel*(
  catalog: WorldCatalog;
  state: SurfaceState;
  uv: Vec2
): string {.raises: [].} =
  let hover = catalog.hoverAt(state, uv)
  if hover.found: hover.label else: ""

proc continentLabel*(catalog: WorldCatalog; mapId: MapId): string
    {.raises: [].} =
  let surface = catalog.worldMapSurfaceFor(mapId, 0'u32)
  if surface.found and surface.label.len > 0:
    surface.label
  else:
    "Map " & $uint32(mapId)

proc breadcrumb*(catalog: WorldCatalog; state: SurfaceState): string
    {.raises: [].} =
  ## e.g. "World  ›  Kalimdor  ›  Thousand Needles"
  const Sep = "  ›  "
  case state.level
  of MapLevelWorld:
    "World"
  of MapLevelContinent:
    "World" & Sep & state.label
  of MapLevelZone:
    let cont =
      if state.surface.found:
        catalog.continentLabel(state.surface.mapId)
      else:
        "?"
    "World" & Sep & cont & Sep & state.label
