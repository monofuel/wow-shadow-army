## Single-window map browser: 2D WorldMap drill + full-region 3D terrain.
##
## One process, one window (`runMapViewer` shell — same pattern as world_editor).
## Zone view reuses **client ADT terrain** with map-tool presentation (no fog
## wall, no doodads/WMOs). World/continent levels are painted 2D overlays.
##
##   make map-browser
##
## Controls
##   Left-click   drill World → continent → zone (3D terrain)
##   Esc / Backspace / RMB (not look)  zoom out
##   Zone 3D:     WASD pan map plane  ·  scroll height  ·  RMB look
##   M            (on zone) toggle painted map overlay on top of 3D
##
## Env: VANILLA_WOW_EXTRACTED_DATA_DIR, VANILLA_WOW_CLIENT_DATA_DIR,
##      MAP_BROWSER_ONCE=1 (headless smoke, no window)

import
  std/[math, monotimes, os, strutils, tables, times],
  chroma, pixie, silky, vmath, windy,
  environment/client/common,
  environment/client/renderer/runtime,
  environment/client/renderer/world_streaming,
  environment/client/renderer/cameras,
  environment/client/video_options,
  environment/client/world_catalogs,
  environment/client/world_catalogs/model,
  environment/client/wheel_input,
  map_browser/[assets, camera, debug, packer, runs, streaming, surface,
    terrain3d, view3d, waypoints]

const
  AppTitle = "map browser"
  HoverOutline = rgbx(220, 200, 140, 180)
  HeaderBg = rgbx(24, 28, 36, 230)
  HeaderText = rgbx(230, 220, 190, 255)
  HeaderMuted = rgbx(160, 150, 130, 255)
  MapDim = rgbx(0, 0, 0, 40)

type
  Browser = object
    catalog: WorldCatalog
    state: SurfaceState
    ## True when the main view is zone 3D terrain (not covered by 2D art).
    terrainMode: bool
    ## Optional painted zone map drawn over 3D when true.
    showPaintedOverlay: bool
    packed: Table[string, bool]
    mapLayout: tuple[pos, size: Vec2]
    ready: bool
    showDebugOverlay: bool
    viewMode: MapViewMode
    showWaypoints: bool
    showTaxi: bool
    waypointGraph: WaypointGraph
    waypointGraphBuilt: bool
    taxiLines: seq[TaxiPolyline]
    taxiLinesBuilt: bool
    overlaysSubmittedMap: string
    overlaysDirty: bool
    showRunsPanel: bool
    runListingsLoaded: bool
    runListings: seq[RunListing]
    loadedRuns: Table[string, TraverseRun]
    selectedRuns: seq[string]
    beats: seq[TraverseBeat]
    checkpoints: seq[TraverseCheckpoint]

var browser: Browser

proc atlasKey(fileName: string): string =
  "mb:" & fileName.toLowerAscii()

proc ensurePacked(fileName: string; areaMapId: uint32) =
  ## Queue a background pack; the atlas upload happens in pollPacker.
  let key = fileName.atlasKey
  if browser.packed.getOrDefault(key):
    return
  packerRequest(fileName, areaMapId, browser.catalog.worldMapOverlays)

proc pollPacker() =
  if sk == nil:
    return
  let polled = packerPoll()
  if not polled.has:
    return
  let res = polled.res
  if not res.ok:
    echo "map_browser: pack failed ", res.fileName, ": ", res.error
    return
  sk.addAtlasImage(res.fileName.atlasKey, packerImage(res))
  browser.packed[res.fileName.atlasKey] = true
  mbNoteMosaicPackMs(res.fileName, res.elapsedMs)
  echo "map_browser: packed ", res.fileName,
    " overlays=", res.overlayCount,
    " in ", res.elapsedMs.int, "ms"

proc fitRect(content, viewport: Vec2): tuple[pos, size: Vec2] =
  if content.x <= 0 or content.y <= 0 or viewport.x <= 0 or viewport.y <= 0:
    return (vec2(0, 0), vec2(0, 0))
  let scale = min(viewport.x / content.x, viewport.y / content.y)
  let size = content * scale
  ((viewport - size) * 0.5'f32, size)

proc drawPacked(name: string; pos, size: Vec2) =
  var entry: Entry
  if not sk.getAtlasEntry(name, entry):
    return
  sk.drawQuad(
    pos, size,
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32),
    rgbx(255, 255, 255, 255)
  )

proc drawBorder(pos, size: Vec2; thickness: float32; color: ColorRGBX) =
  let t = max(1.0'f32, thickness)
  sk.drawRect(pos, vec2(size.x, t), color)
  sk.drawRect(pos + vec2(0, size.y - t), vec2(size.x, t), color)
  sk.drawRect(pos, vec2(t, size.y), color)
  sk.drawRect(pos + vec2(size.x - t, 0), vec2(t, size.y), color)

proc screenToUv(mouse: Vec2): tuple[ok: bool, uv: Vec2] =
  let layout = browser.mapLayout
  if layout.size.x <= 0 or layout.size.y <= 0:
    return
  if mouse.x < layout.pos.x or mouse.y < layout.pos.y or
      mouse.x > layout.pos.x + layout.size.x or
      mouse.y > layout.pos.y + layout.size.y:
    return
  result.ok = true
  result.uv = vec2(
    clamp((mouse.x - layout.pos.x) / layout.size.x, 0.0'f32, 1.0'f32),
    clamp((mouse.y - layout.pos.y) / layout.size.y, 0.0'f32, 1.0'f32)
  )

proc focusZoneTerrain(state: SurfaceState) =
  ## Point stock terrain camera at the whole zone AABB.
  if not state.surface.found:
    return
  let b = state.zoneWorldBounds()
  if not zoneTerrainSupported(b):
    echo "map_browser: ", b.label, " is off-world (map ", b.mapId,
      ") — staying 2D"
    return
  let
    cx = (b.minX + b.maxX) * 0.5'f32
    cy = (b.minY + b.maxY) * 0.5'f32
    span = max(b.maxX - b.minX, b.maxY - b.minY)
    overhead = clamp(
      span * 0.7'f32,
      500.0'f32,
      maxCameraHeightFor(browser.viewMode) * 0.9'f32
    )
  browser.terrainMode = true
  browser.showPaintedOverlay = false
  resetMapCamera()
  mbNoteFocus(b.label)
  applyMapExplorerPresentation(browser.viewMode)
  case browser.viewMode
  of mvmRealMap:
    noteTerrainFocusBoost()
    focusWorldPosition(
      b.mapId, cx, cy, 80.0'f32,
      overhead = overhead,
      loadTiles = true
    )
    # focusWorldPosition pins the stream anchor; clear it so streaming
    # follows the camera instead of staying centered here forever.
    clearStreamAnchor()
  of mvmNavMesh:
    # Whole map loads in one pass below; nothing streams afterwards.
    focusWorldPosition(
      b.mapId, cx, cy, 80.0'f32,
      overhead = overhead,
      loadTiles = false
    )
    if not ensureWholeMapLoaded():
      browser.terrainMode = false
      return
  ## Steeper look-down for map feel (stock focus uses -1.32 ≈ -75°).
  cameraPitch = clampCameraPitch(-1.45'f32)
  echo "map_browser: terrain focus ", b.label,
    " center=(", cx, ",", cy, ") span=", span, " overhead=", overhead

proc setSurface(next: SurfaceState; enterTerrain = false) =
  browser.state = next
  ensurePacked(next.fileName, next.areaMapId)
  if enterTerrain and next.level == MapLevelZone:
    focusZoneTerrain(next)
  else:
    browser.terrainMode = false
    browser.showPaintedOverlay = false

proc drawHeader(crumbs, extra: string) =
  let
    pad = 10.0'f32
    barW = sk.size.x - pad * 2
    barH = 28.0'f32
  sk.drawRect(vec2(pad, pad), vec2(barW, barH), HeaderBg)
  let line =
    if extra.len > 0: crumbs & "   ·   " & extra
    else: crumbs
  discard sk.drawText(sk.textStyle, line, vec2(pad + 8, pad + 6), HeaderText)
  let hint =
    if browser.terrainMode:
      "WASD pan  ·  wheel zoom  ·  RMB look  ·  V real/mesh  ·  " &
        "Tab continent  ·  1 routes  ·  2 taxi  ·  N nav  ·  L runs  ·  " &
        "M  ·  Esc"
    else:
      "click drill  ·  T 3D  ·  Esc out"
  let hs = sk.getTextSize(sk.textStyle, hint)
  discard sk.drawText(
    sk.textStyle, hint,
    vec2(pad + barW - hs.x - 8, pad + 6),
    HeaderMuted
  )
  # Surface load errors (why grey happened before)
  if loadError.len > 0:
    let err = "terrain: " & loadError
    discard sk.drawText(
      sk.textStyle, err,
      vec2(pad + 8, pad + barH + 4),
      rgbx(255, 120, 100, 255)
    )

const
  WaypointNodeSize = 6.0'f32
  WaypointTrailSize = 1.8'f32
  WaypointTrailSpacing = 25.0'f32
  TaxiDotSize = 1.4'f32

proc edgeColor(kind: WaypointEdgeKind): tuple[r, g, b: float32] =
  case kind
  of wekWalk: (0.92'f32, 0.78'f32, 0.25'f32)
  of wekLift: (0.72'f32, 0.32'f32, 0.95'f32)
  of wekSpell: (0.30'f32, 0.55'f32, 0.95'f32)

proc addTrailCubes(
  cubes: var seq[WorldCube];
  mapId: uint32;
  ax, ay, az, bx, by, bz: float32;
  kind: WaypointEdgeKind
) =
  let
    color = edgeColor(kind)
    dist = sqrt(
      (bx - ax) * (bx - ax) + (by - ay) * (by - ay) + (bz - az) * (bz - az))
    steps = max(1, int(dist / WaypointTrailSpacing))
  for k in 1 ..< steps:
    let t = float32(k) / float32(steps)
    cubes.add WorldCube(
      mapId: mapId,
      x: ax + (bx - ax) * t,
      y: ay + (by - ay) * t,
      z: az + (bz - az) * t + 1.0'f32,
      size: WaypointTrailSize,
      red: color.r, green: color.g, blue: color.b
    )

proc ensureOverlayData() =
  if browser.showWaypoints and not browser.waypointGraphBuilt:
    let startNs = getMonoTime().ticks
    browser.waypointGraph = buildWaypointGraph()
    browser.waypointGraphBuilt = true
    mbNoteOverlayBuildMs(
      "waypoint_graph", float64(getMonoTime().ticks - startNs) / 1e6)
    echo "map_browser: waypoint graph nodes=",
      browser.waypointGraph.nodes.len,
      " edges=", browser.waypointGraph.edges.len
  if browser.showTaxi and not browser.taxiLinesBuilt:
    let startNs = getMonoTime().ticks
    browser.taxiLines = taxiPolylines(browser.catalog)
    browser.taxiLinesBuilt = true
    mbNoteOverlayBuildMs(
      "taxi_lines", float64(getMonoTime().ticks - startNs) / 1e6)
    echo "map_browser: taxi paths=", browser.taxiLines.len

const RunPalette = [
  (0.95'f32, 0.30'f32, 0.25'f32),
  (0.30'f32, 0.90'f32, 0.40'f32),
  (0.35'f32, 0.55'f32, 0.98'f32),
  (0.95'f32, 0.65'f32, 0.20'f32),
  (0.90'f32, 0.35'f32, 0.90'f32),
  (0.30'f32, 0.90'f32, 0.90'f32)
]

proc submitRunOverlays(rings: var seq[WorldRing]) =
  ## Selected traverse-run trails (+ beat rings / checkpoint cubes).
  var debugCubes: seq[WorldCube]
  for index, path in browser.selectedRuns:
    if path notin browser.loadedRuns:
      continue
    let run = browser.loadedRuns[path]
    let color = RunPalette[index mod RunPalette.len]
    for point in run.points:
      debugCubes.add WorldCube(
        mapId: run.mapId,
        x: point.x, y: point.y, z: point.z + 1.5'f32,
        size: 2.2'f32,
        red: color[0], green: color[1], blue: color[2]
      )
    if run.points.len > 0:
      debugCubes.add WorldCube(
        mapId: run.mapId,
        x: run.points[0].x, y: run.points[0].y, z: run.points[0].z + 3.0'f32,
        size: 8.0'f32,
        red: 0.2'f32, green: 1.0'f32, blue: 0.35'f32
      )
      debugCubes.add WorldCube(
        mapId: run.mapId,
        x: run.points[^1].x, y: run.points[^1].y,
        z: run.points[^1].z + 3.0'f32,
        size: 8.0'f32,
        red: 1.0'f32, green: 0.25'f32, blue: 0.2'f32
      )
  if browser.selectedRuns.len > 0:
    for beat in browser.beats:
      rings.add WorldRing(
        mapId: 1'u32,
        x: beat.x, y: beat.y, z: beat.z,
        radius: beat.radius,
        thickness: 1.5'f32,
        red: 0.95'f32, green: 0.80'f32, blue: 0.30'f32
      )
    for checkpoint in browser.checkpoints:
      debugCubes.add WorldCube(
        mapId: checkpoint.mapId,
        x: checkpoint.x, y: checkpoint.y, z: checkpoint.z + 2.0'f32,
        size: 6.0'f32,
        red: 0.95'f32, green: 0.95'f32, blue: 0.95'f32
      )
  setWorldDebugCubes(debugCubes)

proc submitOverlays() =
  ## Rebuild the per-map overlay sets (cheap; only on toggle or map switch).
  ensureOverlayData()
  var cubes: seq[WorldCube]
  var rings: seq[WorldRing]
  if browser.showWaypoints:
    let graph = browser.waypointGraph
    for node in graph.nodes:
      let kind =
        if node.greatLift: wekLift
        elif node.travelSpellId != 0'u32: wekSpell
        else: wekWalk
      let color = edgeColor(kind)
      cubes.add WorldCube(
        mapId: node.point.mapId,
        x: node.point.x, y: node.point.y, z: node.point.z + 2.0'f32,
        size: WaypointNodeSize,
        red: color.r, green: color.g, blue: color.b
      )
    for edge in graph.edges:
      let
        a = graph.nodes[edge.a].point
        b = graph.nodes[edge.b].point
      cubes.addTrailCubes(a.mapId, a.x, a.y, a.z, b.x, b.y, b.z, edge.kind)
    for region in activityRegions():
      rings.add WorldRing(
        mapId: region.point.mapId,
        x: region.point.x, y: region.point.y, z: region.point.z,
        radius: region.entryRadius,
        thickness: 1.5'f32,
        red: 0.35'f32, green: 0.85'f32, blue: 0.45'f32
      )
  if browser.showTaxi:
    for line in browser.taxiLines:
      for point in line.points:
        cubes.add WorldCube(
          mapId: line.mapId,
          x: point.x, y: point.y, z: point.z,
          size: TaxiDotSize,
          red: 0.30'f32, green: 0.82'f32, blue: 0.90'f32
        )
  submitRunOverlays(rings)
  setWorldCubes(cubes)
  setWorldTargetRings(rings)
  browser.overlaysSubmittedMap = selectedMap
  browser.overlaysDirty = false

proc drawLogicalEdgeLabels() =
  ## Floating LIFT / TELEPORT tags over logical (non-walk) connections.
  if not (browser.terrainMode and browser.showWaypoints):
    return
  let graph = browser.waypointGraph
  for edge in graph.edges:
    if edge.kind == wekWalk:
      continue
    let
      a = graph.nodes[edge.a].point
      b = graph.nodes[edge.b].point
      projected = projectWorldPosition(
        a.mapId,
        (a.x + b.x) * 0.5'f32,
        (a.y + b.y) * 0.5'f32,
        (a.z + b.z) * 0.5'f32 + 4.0'f32
      )
    if not projected.ok:
      continue
    let label = (if edge.kind == wekLift: "LIFT" else: "TELEPORT")
    discard sk.drawText(
      sk.textStyle, label,
      projected.pos / max(sk.uiScale, 0.01'f32),
      rgbx(220, 160, 255, 255)
    )

proc autoDrillZone(name: string): bool =
  ## Autopilot: enter 3D terrain for a zone by WorldMapArea name or file token.
  for area in browser.catalog.worldMapAreas:
    if area.areaId == 0'u32:
      continue
    if cmpIgnoreCase(area.name, name) == 0 or
        cmpIgnoreCase(area.fileName, name) == 0:
      let state = browser.catalog.applyZone(MapId(area.mapId), area.areaId)
      if state.level == MapLevelZone:
        setSurface(state, enterTerrain = true)
        return true
  false

proc autoFinishAndClose() =
  discard mbAutoFinish()
  let shot = mbAuto().screenshot
  if shot.len > 0 and window != nil:
    discard requestScreenshotCapture(
      "map-browser-auto",
      proc(success: bool; path: string) {.closure, raises: [].} =
        if success:
          try:
            if shot.parentDir().len > 0:
              createDir(shot.parentDir())
            copyFile(path, shot)
            echo "map_browser: autopilot screenshot ", shot
          except CatchableError as err:
            echo "map_browser: screenshot copy failed: ", err.msg
        try:
          window.closeRequested = true
        except Exception:
          discard
    )
  elif window != nil:
    try:
      window.closeRequested = true
    except Exception:
      discard

proc onFrameBoundary() =
  ## Per-app-tick hook (before simulation/draw): stream budget, packer,
  ## debug stats, autopilot.
  tickTerrainPresentation(
    browser.viewMode, browser.terrainMode, cameraPos.y)
  updateMapPlaneCamera(
    browser.terrainMode, maxCameraHeightFor(browser.viewMode))
  pollPacker()
  let polledRun = pollRunLoad()
  if polledRun.has:
    let run = polledRun.run
    browser.loadedRuns[run.path] = run
    if run.ok:
      browser.selectedRuns.add run.path
      browser.overlaysDirty = true
      mbNoteOverlayBuildMs("run:" & run.fileName, run.elapsedMs)
      echo "map_browser: run ", run.fileName,
        " frames=", run.frameCount,
        " points=", run.points.len,
        " northing=", run.maxNorthing.int, "yd",
        " in ", run.elapsedMs.int, "ms"
    else:
      echo "map_browser: run load failed ", run.fileName, ": ", run.error
  if browser.overlaysDirty or
      ((browser.showWaypoints or browser.showTaxi or
        browser.selectedRuns.len > 0) and
        selectedMap != browser.overlaysSubmittedMap):
    submitOverlays()
  mbDebugFrame(
    (if browser.terrainMode: "terrain" else: "2d"),
    browser.state.label
  )
  case mbAutopilotTick()
  of mbaNone:
    discard
  of mbaDrill:
    let zone = mbAuto().zone
    if not autoDrillZone(zone):
      mbAutoDrillFailed("zone not found: " & zone)
      autoFinishAndClose()
  of mbaFinish:
    autoFinishAndClose()

proc runRowLabel(listing: RunListing): string =
  let stamp =
    if listing.mtimeEpoch > 0:
      listing.mtimeEpoch.fromUnixFloat().local().format("MM-dd HH:mm")
    else:
      "?"
  let mb = float64(listing.sizeBytes) / (1024.0 * 1024.0)
  result = stamp & "  " & listing.fileName & "  (" &
    formatFloat(mb, ffDecimal, 1) & " MB)"
  if listing.path in browser.loadedRuns:
    let run = browser.loadedRuns[listing.path]
    if run.ok:
      result &= "  " & $int(run.maxNorthing) & "yd " &
        $int(run.durationSec) & "s"
    else:
      result &= "  [error]"
  elif runLoadBusy() == listing.path:
    result &= "  [loading…]"

proc drawRunsPanel(mouse: Vec2) =
  let
    pad = 10.0'f32
    top = 50.0'f32
    rowH = 18.0'f32
    width = 460.0'f32
    maxRows = max(1, int((sk.size.y - top - pad) / rowH) - 1)
    rows = min(browser.runListings.len, maxRows)
  sk.drawRect(
    vec2(pad, top),
    vec2(width, float32(rows + 1) * rowH + 8.0'f32),
    HeaderBg
  )
  discard sk.drawText(
    sk.textStyle,
    "traverse runs (click to load/plot)  ·  L closes",
    vec2(pad + 6, top + 4),
    HeaderMuted
  )
  for i in 0 ..< rows:
    let listing = browser.runListings[i]
    let rowPos = vec2(pad + 6, top + 4 + float32(i + 1) * rowH)
    let selected = listing.path in browser.selectedRuns
    let hovered =
      mouse.x >= pad and mouse.x <= pad + width and
      mouse.y >= rowPos.y and mouse.y < rowPos.y + rowH
    var color = HeaderText
    if selected:
      let idx = browser.selectedRuns.find(listing.path)
      let palette = RunPalette[idx mod RunPalette.len]
      color = rgbx(
        uint8(palette[0] * 255), uint8(palette[1] * 255),
        uint8(palette[2] * 255), 255)
    elif hovered:
      color = rgbx(255, 255, 255, 255)
    discard sk.drawText(sk.textStyle, runRowLabel(listing), rowPos, color)
    if hovered and window.buttonPressed[MouseLeft]:
      if listing.path in browser.loadedRuns:
        let at = browser.selectedRuns.find(listing.path)
        if at >= 0:
          browser.selectedRuns.delete(at)
        else:
          browser.selectedRuns.add listing.path
        browser.overlaysDirty = true
      else:
        discard requestRunLoad(listing.path)

proc drawDebugOverlay() =
  let lines = mbOverlayLines()
  let
    pad = 10.0'f32
    top = 50.0'f32
    lineH = 16.0'f32
  sk.drawRect(
    vec2(pad, top),
    vec2(430.0'f32, float32(lines.len) * lineH + 8.0'f32),
    HeaderBg
  )
  for i, line in lines:
    discard sk.drawText(
      sk.textStyle, line,
      vec2(pad + 6, top + 4 + float32(i) * lineH),
      HeaderText
    )

proc drawMapBrowserUi() =
  if sk == nil or window == nil:
    return

  if not browser.ready:
    browser.ready = true
    ensurePacked(browser.state.fileName, browser.state.areaMapId)

  # Esc / Backspace zoom out. RMB is mouse-look in terrain mode.
  let zoomOut =
    window.buttonPressed[KeyEscape] or
    window.buttonPressed[KeyBackspace] or
    (not browser.terrainMode and window.buttonPressed[MouseRight])
  if zoomOut:
    if browser.terrainMode and browser.showPaintedOverlay:
      browser.showPaintedOverlay = false
    elif browser.terrainMode:
      browser.terrainMode = false
      setSurface(browser.catalog.zoomOut(browser.state))
    else:
      setSurface(browser.catalog.zoomOut(browser.state))

  if browser.terrainMode and window.buttonPressed[KeyM]:
    browser.showPaintedOverlay = not browser.showPaintedOverlay
  if window.buttonPressed[KeyBacktick]:
    browser.showDebugOverlay = not browser.showDebugOverlay
  if window.buttonPressed[Key1]:
    browser.showWaypoints = not browser.showWaypoints
    browser.overlaysDirty = true
  if window.buttonPressed[Key2]:
    browser.showTaxi = not browser.showTaxi
    browser.overlaysDirty = true
  if window.buttonPressed[KeyN]:
    echo "map_browser: navmesh overlay ", toggleNavmeshDebugOverlay()
  if window.buttonPressed[KeyV]:
    browser.viewMode =
      if browser.viewMode == mvmRealMap: mvmNavMesh else: mvmRealMap
    echo "map_browser: view mode ", browser.viewMode
    if browser.terrainMode:
      applyMapExplorerPresentation(browser.viewMode)
      cameraPos.y = min(cameraPos.y, maxCameraHeightFor(browser.viewMode))
      resetMapCamera()
      case browser.viewMode
      of mvmRealMap:
        enterRealMapStreaming()
      of mvmNavMesh:
        discard ensureWholeMapLoaded()
  if window.buttonPressed[KeyL]:
    browser.showRunsPanel = not browser.showRunsPanel
    if browser.showRunsPanel and not browser.runListingsLoaded:
      browser.runListingsLoaded = true
      browser.runListings = listTraverseRuns()
      browser.beats = loadTraverseBeats(repoRoot())
      browser.checkpoints = loadTraverseCheckpoints(repoRoot())
      echo "map_browser: runs=", browser.runListings.len,
        " beats=", browser.beats.len,
        " checkpoints=", browser.checkpoints.len

  # T: enter 3D terrain for the current surface (zone or whole continent).
  if not browser.terrainMode and window.buttonPressed[KeyT] and
      browser.state.surface.found:
    focusZoneTerrain(browser.state)

  # Tab: cycle continent focus without leaving terrain mode.
  if browser.terrainMode and window.buttonPressed[KeyTab]:
    let cur = zoneWorldBounds(browser.state).mapId
    let next = MapId(if cur == 1'u32: 0'u32 else: 1'u32)
    let state = browser.catalog.applyContinent(next)
    if state.level == MapLevelContinent:
      browser.state = state
      ensurePacked(state.fileName, state.areaMapId)
      focusZoneTerrain(state)

  let
    pad = 10.0'f32
    header = 36.0'f32
    content = vec2(float32(WorldMapDetailWidth), float32(WorldMapDetailHeight))
    viewport = sk.size - vec2(pad * 2, pad * 2 + header)
    layout = fitRect(content, viewport)
  browser.mapLayout = (
    pos: layout.pos + vec2(pad, pad + header),
    size: layout.size
  )

  let mouse = window.mousePos.vec2 / max(sk.uiScale, 0.01'f32)
  let crumbs = browser.catalog.breadcrumb(browser.state)
  var extra = ""

  # --- 2D painted layers: fullscreen when not terrain, or optional overlay ---
  let show2d =
    not browser.terrainMode or browser.showPaintedOverlay
  if show2d:
    # Dim 3D behind optional overlay
    if browser.terrainMode and browser.showPaintedOverlay:
      sk.drawRect(vec2(0, 0), sk.size, MapDim)
    let key = browser.state.fileName.atlasKey
    ensurePacked(browser.state.fileName, browser.state.areaMapId)
    if browser.packed.getOrDefault(key):
      drawPacked(key, browser.mapLayout.pos, browser.mapLayout.size)
    else:
      extra = "packing map…"

    if not browser.terrainMode:
      let hit = screenToUv(mouse)
      if hit.ok:
        let hover = browser.catalog.hoverAt(browser.state, hit.uv)
        if hover.found and hover.highlightUvSize.x > 0:
          let
            hp = browser.mapLayout.pos + vec2(
              hover.highlightUvPos.x * browser.mapLayout.size.x,
              hover.highlightUvPos.y * browser.mapLayout.size.y)
            hs = vec2(
              hover.highlightUvSize.x * browser.mapLayout.size.x,
              hover.highlightUvSize.y * browser.mapLayout.size.y)
          drawBorder(hp, hs, 1.5'f32, HoverOutline)
          extra = hover.label
        if window.buttonPressed[MouseLeft]:
          let next = browser.catalog.drillIn(browser.state, hit.uv)
          setSurface(next, enterTerrain = next.level == MapLevelZone)
  else:
    extra =
      if browser.viewMode == mvmRealMap:
        "3D real map  ·  streams around camera  ·  V for whole-map mesh"
      else:
        "3D nav mesh  ·  whole map  ·  V for real terrain"

  if not browser.terrainMode and browser.state.level == MapLevelZone and
      not zoneTerrainSupported(zoneWorldBounds(browser.state)):
    extra = "2D only (off-world area)"

  drawLogicalEdgeLabels()
  drawHeader(crumbs, extra)
  if browser.showRunsPanel:
    drawRunsPanel(mouse)
  if browser.showDebugOverlay:
    drawDebugOverlay()
  window.title = AppTitle & " — " & crumbs

proc reportOffWorldAreas(catalog: WorldCatalog) =
  ## Inventory of WorldMapAreas whose bounds fall off the world grid.
  var offWorld = 0
  for area in catalog.worldMapAreas:
    if area.areaId == 0'u32:
      continue
    let b = zoneWorldBounds(area)
    if not zoneTerrainSupported(b):
      inc offWorld
      echo "map_browser: off-world area ", b.label,
        " map=", b.mapId,
        " x=", b.minX, "..", b.maxX,
        " y=", b.minY, "..", b.maxY
  echo "map_browser: off-world areas=", offWorld

proc runHeadlessSmoke() =
  let catalog = loadMapCatalog()
  echo "map_browser: dbc=", extractedDbcDir()
  echo "map_browser: areas=", catalog.worldMapAreas.len
  reportOffWorldAreas(catalog)
  let graph = buildWaypointGraph()
  var liftEdges = 0
  for edge in graph.edges:
    if edge.kind == wekLift:
      inc liftEdges
  echo "map_browser: waypoint graph nodes=", graph.nodes.len,
    " edges=", graph.edges.len, " lift-edges=", liftEdges
  doAssert graph.nodes.len > 50, "waypoint graph too small"
  doAssert liftEdges > 0, "great lift missing from waypoint graph"
  let loaded = loadSurfaceMosaic("World")
  let outPath = repoRoot() / "local_data" / "map_browser_world.png"
  createDir(outPath.parentDir())
  loaded.image.writeFile(outPath)
  echo "map_browser: wrote ", outPath
  let cont = catalog.drillIn(worldSurfaceState(), vec2(0.25, 0.5))
  echo "map_browser: sample continent ", cont.fileName
  if cont.level == MapLevelContinent:
    for yi in 0 .. 6:
      for xi in 0 .. 10:
        let uv = vec2((xi.float32 + 0.5) / 11.0, (yi.float32 + 0.5) / 7.0)
        let z = catalog.drillIn(cont, uv)
        if z.level == MapLevelZone:
          let b = z.zoneWorldBounds()
          echo "map_browser: sample zone ", b.label,
            " span=", max(b.maxX - b.minX, b.maxY - b.minY)
          return

proc main() =
  if getEnv("MAP_BROWSER_ONCE").strip() in ["1", "true", "yes"]:
    runHeadlessSmoke()
    return

  mbDebugInit()

  if getEnv("VANILLA_WOW_CLIENT_DATA_DIR").strip().len == 0:
    let client = resolveClientDataDir()
    if client.len > 0:
      putEnv("VANILLA_WOW_CLIENT_DATA_DIR", client)
      echo "map_browser: CLIENT_DATA=", client
  if getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR").strip().len == 0:
    let extracted =
      siblingCoworld("coworld-vanilla-wow") / "local_data" / "vmangos-5875-data"
    if dirExists(extracted):
      putEnv("VANILLA_WOW_EXTRACTED_DATA_DIR", extracted)

  if not ensureForkPlayerAssets():
    echo "map_browser: WARNING prepared assets incomplete — 3D may stay grey"

  browser = Browser(
    catalog: loadMapCatalog(),
    state: worldSurfaceState(),
    packed: initTable[string, bool]()
  )
  echo "map_browser: catalog areas=", browser.catalog.worldMapAreas.len,
    " masks=", browser.catalog.worldMapZoneMasks.len

  # Seed terrain stream somewhere on Kalimdor so setup is happy; 2D covers it
  # until the user drills into a zone.
  applyMapExplorerPresentation(browser.viewMode)
  setInitialWorldFocus(
    1'u32, -600.0'f32, -4200.0'f32, 50.0'f32,
    overhead = 800.0'f32
  )

  ## Stock free-cam moves along the look vector (W ≈ zoom at bird's-eye).
  ## Zone mode uses our map-plane pan instead.
  runMapViewer(
    title = AppTitle,
    topUi = drawMapBrowserUi,
    frameBoundary = onFrameBoundary,
    showMapPanel = false,
    enableCameraInput = false,
    # Whole-map mode: nothing streams; 3D load happens on terrain entry.
    loadInitialMapTiles = false
  )
  mbStatsWrite(final = true)
  if mbExitCode() != 0:
    quit(mbExitCode())

when isMainModule:
  main()
