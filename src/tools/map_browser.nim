## Standalone bird's-eye continent viewer (WDL mesh) + overlays + headless smoke.
##
##   make map-browser
##   make map-browser-once
##   make map-browser-probe
##
## Env: VANILLA_WOW_EXTRACTED_DATA_DIR, VANILLA_WOW_CLIENT_DATA_DIR,
##      MAP_BROWSER_ONCE=1, MAP_BROWSER_STATS, MAP_BROWSER_AUTO,
##      MAP_BROWSER_MAP=0|1 (window startup continent; 0 Azeroth, 1 Kalimdor)

import
  std/[math, monotimes, os, strutils, tables, times],
  chroma, opengl, pixie, silky, vmath, windy,
  environment/client/localpaths,
  environment/client/world_catalogs,
  map_browser/[debug, gl_view, overlay_gl, roads, runs, waypoints, wdl_terrain]

const
  AppTitle = "map browser"
  ClearR = 0.12'f32
  ClearG = 0.14'f32
  ClearB = 0.18'f32
  AtlasOut = "local_data" / "map_browser_atlas.png"
  HeaderHints = "1 wp | 2 taxi | 3 roads | L runs | X xray | WASD/drag pan | wheel zoom | RMB orbit | Tab continent | Home reset"
  HeaderBg = rgbx(24, 28, 36, 230)
  HeaderText = rgbx(230, 220, 190, 255)
  HeaderMuted = rgbx(160, 150, 130, 255)
  LabelColor = rgbx(220, 160, 255, 255)

type
  BrowserState = object
    catalog: WorldCatalog
    waypointGraph: WaypointGraph
    taxiLines: seq[TaxiPolyline]
    roads*: seq[RoadSegment]
    showWaypoints: bool
    showTaxi: bool
    showRoads*: bool
    xray: bool
    showRunsPanel: bool
    runListingsLoaded: bool
    runListings: seq[RunListing]
    loadedRuns: Table[string, TraverseRun]
    selectedRuns: seq[string]
    beats: seq[TraverseBeat]
    checkpoints: seq[TraverseCheckpoint]

var browser: BrowserState

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

proc findUiFont(): string =
  ## First existing font path suitable for the silky header line.
  let candidates = [
    getHomeDir() / ".nimby/pkgs/silky/examples/basicwindow/data/IBMPlexSans-Regular.ttf",
    "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
    "/run/current-system/sw/share/X11/fonts/FreeSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf"
  ]
  for path in candidates:
    if fileExists(path):
      return path
  ""

proc buildAtlas(fontPath: string): bool =
  ## Write a minimal silky atlas with Default font into local_data/.
  if fontPath.len == 0:
    return false
  try:
    createDir(AtlasOut.parentDir())
    let builder = newAtlasBuilder(1024, 4)
    builder.addFont(fontPath, "Default", 18.0)
    builder.write(AtlasOut)
    result = true
  except CatchableError as err:
    echo "map_browser: atlas build failed: ", err.msg
    result = false

proc captureScreenshot(path: string; w, h: int): bool =
  ## glReadPixels → pixie Image (flip Y) → writeFile.
  if w <= 0 or h <= 0 or path.len == 0:
    return false
  var raw = newSeq[uint8](w * h * 4)
  glReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, raw[0].addr)
  let img = newImage(w, h)
  for y in 0 ..< h:
    let srcY = h - 1 - y
    for x in 0 ..< w:
      let si = (srcY * w + x) * 4
      img.data[y * w + x] = rgbx(raw[si], raw[si + 1], raw[si + 2], 255)
  try:
    createDir(path.parentDir())
    img.writeFile(path)
    echo "map_browser: screenshot ", path
    result = true
  except CatchableError as err:
    echo "map_browser: screenshot failed: ", err.msg
    result = false

proc repoRoot(): string =
  ## Process cwd is the repo root when launched via make targets.
  getCurrentDir()

proc runRowLabel(listing: RunListing): string =
  ## One-line runs panel row: time, name, size, load state.
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

proc toggleRunSelection(path: string) =
  ## Load a run if needed, else toggle selection on/off.
  if path in browser.loadedRuns:
    let at = browser.selectedRuns.find(path)
    if at >= 0:
      browser.selectedRuns.delete(at)
    else:
      browser.selectedRuns.add path
    markOverlaysDirty()
  else:
    discard requestRunLoad(path)

proc headerStatusLine(): string =
  ## Continent, camera height, toggle hints, and live overlay counts.
  let oc = overlayCounts()
  var parts = currentContinentName() & "  |  h=" & $int(birdCam.height)
  parts &= "  |  " & HeaderHints
  if browser.showWaypoints:
    parts &= "  |  wp " & $oc.wpNodes & "/" & $oc.wpEdges & "e"
  if browser.showTaxi:
    parts &= "  |  taxi " & $oc.taxiPaths
  if browser.showRoads:
    parts &= "  |  roads " & $oc.roadSegments
  if browser.selectedRuns.len > 0:
    parts &= "  |  runs " & $oc.runsLoaded
  if browser.xray:
    parts &= "  |  xray"
  if continentLoadError.len > 0:
    parts &= "  |  ERR " & continentLoadError
  parts

proc pollRuns() =
  ## Drain background godview load; select on success and rebuild overlays.
  let polled = pollRunLoad()
  if not polled.has:
    return
  let run = polled.run
  browser.loadedRuns[run.path] = run
  if run.ok:
    if run.path notin browser.selectedRuns:
      browser.selectedRuns.add run.path
    markOverlaysDirty()
    echo "map_browser: run ", run.fileName,
      " frames=", run.frameCount,
      " points=", run.points.len,
      " northing=", run.maxNorthing.int, "yd",
      " in ", run.elapsedMs.int, "ms"
  else:
    echo "map_browser: run load failed ", run.fileName, ": ", run.error

proc ensureOverlayGeometry() =
  ## Rebuild GPU overlay batches when continent or toggles change.
  let mapId = terrainGpu.currentMapId
  if not needsRebuild(mapId):
    return
  rebuildOverlays(
    mapId,
    browser.showWaypoints,
    browser.showTaxi,
    browser.waypointGraph,
    browser.taxiLines,
    activityRegions(),
    browser.loadedRuns,
    browser.selectedRuns,
    browser.beats,
    browser.checkpoints,
    browser.showRoads,
    browser.roads
  )

proc handleOverlayKeys(window: Window) =
  ## Toggle overlays and the runs panel from the keyboard.
  if window.buttonPressed[Key1]:
    browser.showWaypoints = not browser.showWaypoints
    markOverlaysDirty()
  if window.buttonPressed[Key2]:
    browser.showTaxi = not browser.showTaxi
    markOverlaysDirty()
  if window.buttonPressed[Key3]:
    browser.showRoads = not browser.showRoads
    markOverlaysDirty()
  if window.buttonPressed[KeyX]:
    browser.xray = not browser.xray
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
      markOverlaysDirty()

proc drawEdgeLabels(sk: Silky; window: Window; vp: Mat4) =
  ## Project LIFT / TELEPORT midpoints into screen space and draw silky text.
  ## Immediate-mode draws: silky's DSL reorders overlapping quads across
  ## layers, so overlays and panels use direct drawRect/drawText instead.
  if not browser.showWaypoints or sk == nil:
    return
  for label in edgeLabels():
    let projected = worldToScreen(vp, window.size, label.x, label.y, label.z)
    if not projected.ok:
      continue
    let
      px = projected.pos.x / max(sk.uiScale, 0.01'f32)
      py = projected.pos.y / max(sk.uiScale, 0.01'f32)
    discard sk.drawText(
      sk.textStyle, label.text, vec2(px - 24, py - 8), LabelColor)

proc drawRunsPanelUi(sk: Silky; window: Window) =
  ## Newest-first traverse run list; click to load / toggle selection.
  ## Immediate-mode rect + text with manual hit-testing (see drawEdgeLabels).
  if not browser.showRunsPanel or sk == nil:
    return
  let
    pad = 10.0'f32
    top = 50.0'f32
    rowH = 18.0'f32
    width = 460.0'f32
    maxRows = 28
    rows = min(browser.runListings.len, maxRows)
    panelH = float32(rows + 1) * rowH + 8.0'f32
    mouse = window.mousePos.vec2 / max(sk.uiScale, 0.01'f32)
  sk.drawRect(vec2(pad, top), vec2(width, panelH), HeaderBg)
  discard sk.drawText(
    sk.textStyle,
    "traverse runs (click to load/plot)  |  L closes",
    vec2(pad + 6, top + 4),
    HeaderMuted
  )
  for i in 0 ..< rows:
    let
      listing = browser.runListings[i]
      selected = listing.path in browser.selectedRuns
      rowY = top + 4 + float32(i + 1) * rowH
      hovered =
        mouse.x >= pad and mouse.x <= pad + width and
        mouse.y >= rowY and mouse.y < rowY + rowH
    var color = HeaderText
    if selected:
      let idx = browser.selectedRuns.find(listing.path)
      let palette = RunPalette[max(idx, 0) mod RunPalette.len]
      color = rgbx(
        uint8(palette[0] * 255),
        uint8(palette[1] * 255),
        uint8(palette[2] * 255),
        255
      )
    elif hovered:
      color = rgbx(255, 255, 255, 255)
    discard sk.drawText(
      sk.textStyle, runRowLabel(listing), vec2(pad + 6, rowY), color)
    if hovered and window.buttonPressed[MouseLeft]:
      toggleRunSelection(listing.path)

proc runHeadlessOnce() =
  ## MAP_BROWSER_ONCE smoke: catalog + waypoints + WDL mesh asserts.
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

  let roads = loadRoadWaypoints(repoRoot())
  var
    kalimdorSegs = 0
    kalimdorPts = 0
    azerothSegs = 0
    azerothPts = 0
  for segment in roads:
    case segment.mapId
    of 1'u32:
      inc kalimdorSegs
      kalimdorPts += segment.points.len
    of 0'u32:
      inc azerothSegs
      azerothPts += segment.points.len
    else:
      discard
  echo "map_browser: roads kalimdor segments=", kalimdorSegs,
    " points=", kalimdorPts
  echo "map_browser: roads azeroth segments=", azerothSegs,
    " points=", azerothPts
  doAssert kalimdorSegs > 50,
    "kalimdor (mapId 1) road segments expected > 50, got " & $kalimdorSegs
  doAssert azerothSegs > 50,
    "azeroth (mapId 0) road segments expected > 50, got " & $azerothSegs

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

  let azerothMesh = loadContinentMesh(0'u32)
  echo "map_browser: WDL Azeroth tiles=", azerothMesh.tileCount,
    " vertices=", azerothMesh.vertices.len,
    " minZ=", azerothMesh.minZ, " maxZ=", azerothMesh.maxZ
  doAssert azerothMesh.tileCount > 500
  doAssert azerothMesh.vertices.len > 100_000
  doAssert azerothMesh.minZ < 0
  doAssert azerothMesh.maxZ > 500

  var
    azerothMapNodes = 0
    azerothAligned = 0
  for node in graph.nodes:
    if node.point.mapId != 0'u32:
      continue
    inc azerothMapNodes
    let sample = sampleHeight(azerothMesh, node.point.x, node.point.y)
    if sample == sample and abs(sample - node.point.z) < 250.0'f32:
      inc azerothAligned
  let azerothPct =
    if azerothMapNodes > 0:
      100.0 * float(azerothAligned) / float(azerothMapNodes)
    else:
      0.0
  echo "map_browser: WDL alignment Azeroth ", azerothAligned, "/",
    azerothMapNodes, " (", formatFloat(azerothPct, ffDecimal, 1), "%)"
  doAssert azerothMapNodes > 0
  doAssert azerothAligned * 100 >= azerothMapNodes * 70

proc runWindow() =
  ## Real window: WDL terrain + overlays + bird's-eye camera + silky UI.
  mbDebugInit()

  let fontPath = findUiFont()
  var haveUi = false
  if fontPath.len == 0:
    echo "map_browser: warning: no UI font found; running without text UI"
  else:
    haveUi = buildAtlas(fontPath)
    if not haveUi:
      echo "map_browser: warning: atlas failed; running without text UI"

  let catalog = loadMapCatalog()
  browser = BrowserState(
    catalog: catalog,
    waypointGraph: buildWaypointGraph(),
    taxiLines: taxiPolylines(catalog),
    roads: loadRoadWaypoints(repoRoot()),
    showWaypoints: true,
    showTaxi: true,
    showRoads: true,
    xray: true,
    loadedRuns: initTable[string, TraverseRun]()
  )
  echo "map_browser: catalog areas=", browser.catalog.worldMapAreas.len
  echo "map_browser: waypoint graph nodes=", browser.waypointGraph.nodes.len,
    " edges=", browser.waypointGraph.edges.len
  echo "map_browser: taxi paths=", browser.taxiLines.len

  let window = newWindow(
    AppTitle,
    ivec2(1280, 800),
    vsync = false
  )
  makeContextCurrent(window)
  loadExtensions()
  initTerrainGpu()
  initOverlayGpu()

  var startMap =
    try:
      uint32(parseInt(getEnv("MAP_BROWSER_MAP", "1")))
    except ValueError:
      1'u32
  if startMap != 0'u32 and startMap != 1'u32:
    echo "map_browser: MAP_BROWSER_MAP=", startMap, " invalid, falling back to 1"
    startMap = 1'u32
  if not ensureContinent(startMap):
    echo "map_browser: failed to load continent mesh mapId=" & $startMap
    mbAutoMarkDone(false)
    mbStatsWrite(final = true)
    quit 1
  fitCurrentContinent(float32(window.size.x) / float32(window.size.y))
  markOverlaysDirty()

  var sk: Silky = nil
  if haveUi:
    sk = newSilky(window, AtlasOut)

  var lastNs = getMonoTime().ticks

  window.onFrame = proc() =
    let now = getMonoTime().ticks
    var dt = 1.0'f32 / 60.0'f32
    if lastNs > 0:
      dt = float32(float64(now - lastNs) / 1e9)
    lastNs = now
    dt = clamp(dt, 0.001'f32, 0.05'f32)

    handleOverlayKeys(window)
    updateBirdCamera(window, dt)
    pollRuns()

    let
      aspect =
        if window.size.y > 0:
          float32(window.size.x) / float32(window.size.y)
        else:
          16.0'f32 / 9.0'f32
      vp = birdCam.viewProjMatrix(aspect)

    ensureOverlayGeometry()

    glViewport(0, 0, window.size.x, window.size.y)
    glClearColor(ClearR, ClearG, ClearB, 1.0)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    drawTerrain(vp)
    drawOverlays(vp, browser.xray)

    if sk != nil:
      # Silky quads all share depth 0; with depth testing left on, the first
      # quad drawn wins and everything overlapping it is discarded.
      glDisable(GL_DEPTH_TEST)
      sk.beginUI(window, window.size)
      sk.drawRect(
        vec2(10, 8), vec2(float32(window.size.x) - 20, 28), HeaderBg)
      discard sk.drawText(
        sk.textStyle, headerStatusLine(), vec2(18, 14), HeaderText)
      drawEdgeLabels(sk, window, vp)
      drawRunsPanelUi(sk, window)
      sk.endUi()

    mbDebugFrame()

    if mbAutoDue():
      let g = currentGpu()
      let oc = overlayCounts()
      let ok = g.ready and g.vertexCount > 0 and
        (oc.wpNodes > 0 or oc.taxiPaths > 0)
      if ok:
        discard captureScreenshot(
          mbAuto().screenshot,
          window.size.x.int,
          window.size.y.int
        )
      else:
        echo "map_browser: autopilot failed: vertex_count=", g.vertexCount,
          " wp_nodes=", oc.wpNodes, " taxi_paths=", oc.taxiPaths
      mbAutoMarkDone(ok)
      mbStatsWrite(final = true)
      window.closeRequested = true

    window.swapBuffers()

  while not window.closeRequested:
    pollEvents()

  mbStatsWrite(final = true)
  quit mbExitCode()

proc main() =
  ## Headless smoke under MAP_BROWSER_ONCE; otherwise open the GL viewer.
  let once = getEnv("MAP_BROWSER_ONCE").strip().toLowerAscii()
  if once in ["1", "true", "yes"]:
    runHeadlessOnce()
    quit 0
  runWindow()

when isMainModule:
  main()
