## Standalone bird's-eye continent viewer (WDL mesh) + headless smoke.
##
##   make map-browser
##   make map-browser-once
##   make map-browser-probe
##
## Env: VANILLA_WOW_EXTRACTED_DATA_DIR, VANILLA_WOW_CLIENT_DATA_DIR,
##      MAP_BROWSER_ONCE=1, MAP_BROWSER_STATS, MAP_BROWSER_AUTO

import
  std/[math, monotimes, os, strutils],
  chroma, opengl, pixie, silky, vmath, windy,
  environment/client/localpaths,
  environment/client/world_catalogs,
  map_browser/[debug, gl_view, waypoints, wdl_terrain]

const
  AppTitle = "map browser"
  ClearR = 0.12'f32
  ClearG = 0.14'f32
  ClearB = 0.18'f32
  AtlasOut = "local_data" / "map_browser_atlas.png"
  HeaderLine =
    "  |  WASD/drag pan | wheel zoom | RMB orbit | Tab continent | Home reset"

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

proc runWindow() =
  ## Real window: WDL terrain + bird's-eye camera + optional silky header.
  mbDebugInit()

  let fontPath = findUiFont()
  var haveUi = false
  if fontPath.len == 0:
    echo "map_browser: warning: no UI font found; running without text UI"
  else:
    haveUi = buildAtlas(fontPath)
    if not haveUi:
      echo "map_browser: warning: atlas failed; running without text UI"

  let window = newWindow(
    AppTitle,
    ivec2(1280, 800),
    vsync = false
  )
  makeContextCurrent(window)
  loadExtensions()
  initTerrainGpu()

  if not ensureContinent(1'u32):
    echo "map_browser: failed to load Kalimdor mesh"
    mbAutoMarkDone(false)
    mbStatsWrite(final = true)
    quit 1
  fitCurrentContinent(float32(window.size.x) / float32(window.size.y))

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

    updateBirdCamera(window, dt)

    let
      aspect =
        if window.size.y > 0:
          float32(window.size.x) / float32(window.size.y)
        else:
          16.0'f32 / 9.0'f32
      vp = birdCam.viewProjMatrix(aspect)

    glViewport(0, 0, window.size.x, window.size.y)
    glClearColor(ClearR, ClearG, ClearB, 1.0)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    drawTerrain(vp)

    if sk != nil:
      sk.beginUI(window, window.size)
      ui:
        text "hdr":
          box 12, 10, float32(window.size.x) - 24, 24
          characters currentContinentName() & "  |  h=" &
            $int(birdCam.height) & HeaderLine
      sk.endUi()

    mbDebugFrame()

    if mbAutoDue():
      let g = currentGpu()
      let ok = g.ready and g.vertexCount > 0
      if ok:
        discard captureScreenshot(
          mbAuto().screenshot,
          window.size.x.int,
          window.size.y.int
        )
      else:
        echo "map_browser: autopilot failed: vertex_count=", g.vertexCount
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
