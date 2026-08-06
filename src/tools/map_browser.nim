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
##   Esc / RMB    zoom out (zone 3D → continent 2D → world 2D)
##   Zone 3D:     WASD / mouse / scroll (stock free camera)
##   M            (on zone) toggle painted map overlay on top of 3D
##
## Env: VANILLA_WOW_EXTRACTED_DATA_DIR, VANILLA_WOW_CLIENT_DATA_DIR,
##      MAP_BROWSER_ONCE=1 (headless smoke, no window)

import
  std/[math, os, strutils, tables],
  chroma, pixie, silky, vmath, windy,
  environment/client/renderer/runtime,
  environment/client/renderer/world_streaming,
  environment/client/renderer/cameras,
  environment/client/world_catalogs,
  environment/client/world_catalogs/model,
  map_browser/[assets, surface, terrain3d, view3d]

from environment/client/renderer/environments import
  fogDistanceOverride, fogStartOverride, fogEndOverride, renderFarclip

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

var browser: Browser

proc atlasKey(fileName: string): string =
  "mb:" & fileName.toLowerAscii()

proc applyMapExplorerPresentation() =
  ## Terrain yes; full-client clutter no. Re-applied each frame in terrain mode.
  showVisual = false
  showNav = false
  showCollision = false
  chunkWindowSize = MaxChunkWindowSize
  moveSpeed = 260.0'f32
  fogDistanceOverride = true
  fogStartOverride = 7000.0'f32
  fogEndOverride = 9800.0'f32
  renderFarclip = 12000.0'f32

proc ensurePacked(fileName: string; areaMapId: uint32) =
  let key = fileName.atlasKey
  if browser.packed.getOrDefault(key):
    return
  if sk == nil:
    return
  let loaded = loadSurfaceMosaic(
    fileName, areaMapId, browser.catalog.worldMapOverlays)
  sk.addAtlasImage(key, loaded.image)
  browser.packed[key] = true
  echo "map_browser: packed ", fileName,
    " overlays=", loaded.roots.overlayCount

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
  let
    cx = (b.minX + b.maxX) * 0.5'f32
    cy = (b.minY + b.maxY) * 0.5'f32
    span = max(b.maxX - b.minX, b.maxY - b.minY)
    overhead = clamp(span * 0.55'f32, 400.0'f32, 2800.0'f32)
  applyMapExplorerPresentation()
  focusWorldPosition(
    b.mapId, cx, cy, 80.0'f32,
    overhead = overhead,
    loadTiles = true
  )
  browser.terrainMode = true
  browser.showPaintedOverlay = false
  echo "map_browser: terrain focus ", b.label,
    " center=(", cx, ",", cy, ") span=", span, " overhead=", overhead

proc setSurface(next: SurfaceState; enterTerrain = false) =
  browser.state = next
  try:
    ensurePacked(next.fileName, next.areaMapId)
  except CatchableError as err:
    echo "map_browser: pack failed ", next.fileName, ": ", err.msg
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
      "WASD/mouse 3D  ·  M painted  ·  Esc out"
    else:
      "click drill  ·  Esc out"
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

proc drawMapBrowserUi() =
  if sk == nil or window == nil:
    return

  if not browser.ready:
    browser.ready = true
    try:
      ensurePacked(browser.state.fileName, browser.state.areaMapId)
    except CatchableError as err:
      echo "map_browser: initial pack: ", err.msg

  if browser.terrainMode:
    applyMapExplorerPresentation()

  # Esc / RMB zoom out
  if window.buttonPressed[KeyEscape] or window.buttonPressed[MouseRight] or
      window.buttonPressed[KeyBackspace]:
    if browser.terrainMode and browser.showPaintedOverlay:
      browser.showPaintedOverlay = false
    elif browser.terrainMode:
      browser.terrainMode = false
      setSurface(browser.catalog.zoomOut(browser.state))
    else:
      setSurface(browser.catalog.zoomOut(browser.state))

  if browser.terrainMode and window.buttonPressed[KeyM]:
    browser.showPaintedOverlay = not browser.showPaintedOverlay

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
    try:
      ensurePacked(browser.state.fileName, browser.state.areaMapId)
    except CatchableError:
      discard
    if browser.packed.getOrDefault(key):
      drawPacked(key, browser.mapLayout.pos, browser.mapLayout.size)

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
    extra = "3D terrain  ·  full zone"

  drawHeader(crumbs, extra)
  window.title = AppTitle & " — " & crumbs

proc runHeadlessSmoke() =
  let catalog = loadMapCatalog()
  echo "map_browser: dbc=", extractedDbcDir()
  echo "map_browser: areas=", catalog.worldMapAreas.len
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
  applyMapExplorerPresentation()
  setInitialWorldFocus(
    1'u32, -600.0'f32, -4200.0'f32, 50.0'f32,
    overhead = 800.0'f32
  )

  # Free camera only useful in zone terrain mode; still allow look around.
  runMapViewer(
    title = AppTitle,
    topUi = drawMapBrowserUi,
    showMapPanel = false,
    enableCameraInput = true,
    loadInitialMapTiles = true
  )

when isMainModule:
  main()
