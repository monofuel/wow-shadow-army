## Map browser: World → continent → zone (2D) → bird's-eye 3D terrain.
##
##   nix develop --command nim r src/tools/map_browser.nim
##   make map-browser
##
## Zone drill opens a 3D bird's-eye view (map_browser_3d). Esc/Q closes 3D
## and returns here. Enter/Space on a zone 2D map re-opens 3D.
##
## Optional:
##   MAP_BROWSER_WORLD_MAP_DIR=/path/to/worldmap_or_surface
##   MAP_BROWSER_ZMP_DIR=/path/to/zmp_folder
##   MAP_BROWSER_ONCE=1          # compose current surface PNG and exit
##   MAP_BROWSER_OUT=local_data/map_browser_world.png
##   MAP_BROWSER_NO_3D=1         # skip auto 3D on zone drill
##   VANILLA_WOW_EXTRACTED_DATA_DIR=…/vmangos-5875-data

import
  std/[os, osproc, strutils, tables],
  chroma, pixie, silky, vmath,
  environment/client/world_catalogs,
  environment/client/world_catalogs/model,
  map_browser/[assets, surface, view3d]

const
  WindowTitle = "map browser"
  AtlasSize = 8192
  HoverOutline = rgbx(220, 200, 140, 180)
  HeaderBg = rgbx(24, 28, 36, 240)
  HeaderText = rgbx(230, 220, 190, 255)
  HeaderMuted = rgbx(160, 150, 130, 255)

type
  Browser = object
    catalog: WorldCatalog
    state: SurfaceState
    sk: Silky
    packed: Table[string, bool]
    mapLayout: tuple[pos, size: Vec2]
    statusLine: string

proc auto3dEnabled(): bool =
  getEnv("MAP_BROWSER_NO_3D").strip() notin ["1", "true", "yes"]

proc launchZone3d*(focus: BirdseyeFocus) =
  ## Blocks in a child map_browser_3d process (fork runMapViewer).
  discard ensureForkPlayerAssets()
  # Child inherits env; fill dead defaults so MPQ/extract paths resolve.
  if getEnv("VANILLA_WOW_CLIENT_DATA_DIR").strip().len == 0:
    let client = resolveClientDataDir()
    if client.len > 0:
      putEnv("VANILLA_WOW_CLIENT_DATA_DIR", client)
  if getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR").strip().len == 0:
    let extracted =
      siblingCoworld("coworld-vanilla-wow") / "local_data" / "vmangos-5875-data"
    if dirExists(extracted):
      putEnv("VANILLA_WOW_EXTRACTED_DATA_DIR", extracted)
  let
    root = repoRoot()
    tool = root / "src" / "tools" / "map_browser_3d.nim"
  var args = @[
    "develop", "--command", "nim", "r", "--hints:off", tool, "--"
  ]
  args.add focus.birdseyeCliArgs()
  echo "map_browser: 3D bird's-eye ", focus.label,
    " map=", focus.mapId,
    " @(", focus.x, ", ", focus.y, ", ", focus.z, ")",
    " overhead=", focus.overhead
  echo "map_browser: CLIENT_DATA=", getEnv("VANILLA_WOW_CLIENT_DATA_DIR")
  echo "map_browser: EXTRACTED=", getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR")
  let p = startProcess(
    command = "nix",
    args = args,
    workingDir = root,
    options = {poParentStreams, poUsePath}
  )
  let code = p.waitForExit()
  if code != 0:
    echo "map_browser: 3D viewer exited with code ", code
  p.close()

proc openZone3d(b: var Browser; state: SurfaceState) =
  if state.level != MapLevelZone or not state.surface.found:
    return
  let focus = state.birdseyeFocus()
  if focus.overhead < 1.0'f32:
    echo "map_browser: no 3D focus for ", state.label
    return
  b.statusLine = "3D: " & focus.label & "  ·  Esc/Q returns"
  launchZone3d(focus)

proc fitRect(content, viewport: Vec2): tuple[pos, size: Vec2] =
  if content.x <= 0 or content.y <= 0 or viewport.x <= 0 or viewport.y <= 0:
    return (vec2(0, 0), vec2(0, 0))
  let scale = min(viewport.x / content.x, viewport.y / content.y)
  let size = content * scale
  ((viewport - size) * 0.5'f32, size)

proc drawPackedImage(sk: Silky; name: string; pos, size: Vec2) =
  var entry: Entry
  if not sk.getAtlasEntry(name, entry):
    return
  sk.drawQuad(
    pos,
    size,
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32),
    rgbx(255, 255, 255, 255)
  )

proc drawBorder(sk: Silky; pos, size: Vec2; thickness: float32; color: ColorRGBX) =
  if size.x <= 0 or size.y <= 0:
    return
  let t = max(1.0'f32, thickness)
  sk.drawRect(pos, vec2(size.x, t), color)
  sk.drawRect(pos + vec2(0, size.y - t), vec2(size.x, t), color)
  sk.drawRect(pos, vec2(t, size.y), color)
  sk.drawRect(pos + vec2(size.x - t, 0), vec2(t, size.y), color)

proc uvToScreen(
  mapPos, mapSize, uvPos, uvSize: Vec2
): tuple[pos, size: Vec2] {.raises: [].} =
  (
    pos: mapPos + vec2(uvPos.x * mapSize.x, uvPos.y * mapSize.y),
    size: vec2(uvSize.x * mapSize.x, uvSize.y * mapSize.y)
  )

proc drawHoverHint(
  sk: Silky;
  mapPos, mapSize: Vec2;
  hover: WorldMapAreaHover
) =
  ## Thin outline only over stock highlight UV (no fill).
  if not hover.found:
    return
  if hover.highlightUvSize.x > 0.0'f32 and hover.highlightUvSize.y > 0.0'f32:
    let r = uvToScreen(
      mapPos, mapSize, hover.highlightUvPos, hover.highlightUvSize)
    if r.size.x >= 4.0'f32 and r.size.y >= 4.0'f32:
      sk.drawBorder(r.pos, r.size, 1.5'f32, HoverOutline)

proc resolveUiFont(): string {.raises: [].} =
  ## Prefer fontconfig match, then common paths / silky example.
  try:
    let (output, code) = execCmdEx("fc-match -f '%{file}' 'DejaVu Sans'")
    if code == 0:
      let path = output.strip()
      if path.len > 0 and fileExists(path):
        return path
  except CatchableError:
    discard
  const candidates = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf"
  ]
  for path in candidates:
    if fileExists(path):
      return path
  let silkyExample =
    getHomeDir() / ".nimby" / "pkgs" / "silky" / "examples" / "basicwindow" /
      "data" / "IBMPlexSans-Regular.ttf"
  if fileExists(silkyExample):
    return silkyExample
  ""

proc atlasKey(fileName: string): string =
  "map:" & fileName.toLowerAscii()

proc ensurePacked(b: var Browser; state: SurfaceState) =
  ## Pack fully-revealed surface (base + all WorldMapOverlay pieces).
  let key = state.fileName.atlasKey
  if b.packed.getOrDefault(key):
    return
  let loaded = loadSurfaceMosaic(
    state.fileName,
    state.areaMapId,
    b.catalog.worldMapOverlays
  )
  if not b.sk.builder.addImage(key, loaded.image):
    raise newException(IOError, "atlas full packing " & state.fileName)
  b.sk.image = b.sk.builder.atlasImage
  b.sk.atlas = b.sk.builder.atlas
  b.sk.uploadAtlas()
  b.packed[key] = true
  echo "map_browser: packed ", state.fileName,
    " overlays=", loaded.roots.overlayCount,
    " from ", loaded.roots.sourceLabel

proc setSurface(b: var Browser; next: SurfaceState) =
  b.state = next
  try:
    b.ensurePacked(next)
    b.statusLine = next.label & "  ·  " & next.status
  except CatchableError as err:
    b.statusLine = "failed to load " & next.fileName & ": " & err.msg
    echo "map_browser: ", b.statusLine

proc screenToUv(b: Browser; mouse: Vec2): tuple[ok: bool, uv: Vec2] =
  let layout = b.mapLayout
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

proc drawHeader(
  sk: Silky;
  pad: float32;
  crumbs, hoverName: string
) =
  let
    barW = sk.size.x - pad * 2
    barH = 26.0'f32
  sk.drawRect(vec2(pad, pad), vec2(barW, barH), HeaderBg)
  let crumbLine =
    if hoverName.len > 0:
      crumbs & "   ·   " & hoverName
    else:
      crumbs
  discard sk.drawText(
    sk.textStyle,
    crumbLine,
    vec2(pad + 8, pad + 5),
    HeaderText
  )
  let hint = "click drill  ·  zone→3D  ·  Esc zoom out"
  let hintSize = sk.getTextSize(sk.textStyle, hint)
  discard sk.drawText(
    sk.textStyle,
    hint,
    vec2(pad + barW - hintSize.x - 8, pad + 5),
    HeaderMuted
  )

proc main() =
  var catalog = loadMapCatalog()
  echo "map_browser: dbc=", extractedDbcDir()
  echo "map_browser: worldMapAreas=", catalog.worldMapAreas.len
  echo "map_browser: zoneMasks=", catalog.worldMapZoneMasks.len

  var state = worldSurfaceState()

  let once = getEnv("MAP_BROWSER_ONCE").strip() in ["1", "true", "yes"]
  let outPath = block:
    let o = getEnv("MAP_BROWSER_OUT").strip()
    if o.len > 0: o
    else: repoRoot() / "local_data" / "map_browser_world.png"

  if once:
    let loaded = loadSurfaceMosaic(state.fileName)
    createDir(outPath.parentDir())
    loaded.image.writeFile(outPath)
    echo "map_browser: wrote ", outPath, " (", state.fileName, ")"
    let cont = catalog.drillIn(state, vec2(0.25, 0.5))
    echo "map_browser: sample world→continent level=", cont.level,
      " file=", cont.fileName, " label=", cont.label
    echo "map_browser: breadcrumb=", catalog.breadcrumb(cont)
    if cont.level == MapLevelContinent:
      var sampleZone = cont
      for yi in 0 .. 4:
        for xi in 0 .. 7:
          let uv = vec2(
            (xi.float32 + 0.5'f32) / 8.0'f32,
            (yi.float32 + 0.5'f32) / 5.0'f32
          )
          let z = catalog.drillIn(cont, uv)
          if z.level == MapLevelZone:
            sampleZone = z
            break
        if sampleZone.level == MapLevelZone:
          break
      if sampleZone.level == MapLevelZone:
        echo "map_browser: breadcrumb=", catalog.breadcrumb(sampleZone)
        let hover = catalog.hoverAt(cont, vec2(0.5, 0.5))
        echo "map_browser: sample hover found=", hover.found,
          " label=", hover.label,
          " rect=", hover.highlightUvPos, " ", hover.highlightUvSize
        let focus = sampleZone.birdseyeFocus()
        echo "map_browser: 3D focus map=", focus.mapId,
          " pos=(", focus.x, ", ", focus.y, ", ", focus.z, ")",
          " overhead=", focus.overhead, " label=", focus.label
    return

  let fontPath = resolveUiFont()
  if fontPath.len == 0:
    echo "map_browser: warning: no UI font found; breadcrumbs may not render"

  let window = newWindow(WindowTitle, ivec2(1100, 780), vsync = true)
  makeContextCurrent(window)
  loadExtensions()

  let builder = newAtlasBuilder(AtlasSize, 4)
  if fontPath.len > 0:
    builder.addFont(fontPath, "Default", 16.0)
  let sk = newSilky(window, builder.atlasImage, builder.atlas)
  sk.builder = builder
  sk.textStyle = "Default"

  var b = Browser(catalog: catalog, sk: sk, packed: initTable[string, bool]())
  b.setSurface(state)

  window.onFrame = proc() =
    if window.buttonPressed[KeyEscape] or window.buttonPressed[MouseRight] or
        window.buttonPressed[KeyBackspace]:
      b.setSurface(b.catalog.zoomOut(b.state))

    # Re-enter bird's-eye 3D while already on a zone 2D map.
    if b.state.level == MapLevelZone and
        (window.buttonPressed[KeyEnter] or window.buttonPressed[KeySpace] or
          window.buttonPressed[Key3]):
      b.openZone3d(b.state)

    sk.beginUi(window, window.size)
    sk.clearScreen(rgbx(12, 14, 20, 255))

    let
      pad = 12.0'f32
      header = 32.0'f32
      content = vec2(float32(WorldMapDetailWidth), float32(WorldMapDetailHeight))
      viewport = sk.size - vec2(pad * 2, pad * 2 + header)
      layout = fitRect(content, viewport)
    b.mapLayout = (
      pos: layout.pos + vec2(pad, pad + header),
      size: layout.size
    )

    let key = b.state.fileName.atlasKey
    if b.packed.getOrDefault(key):
      sk.drawPackedImage(key, b.mapLayout.pos, b.mapLayout.size)

    let mouse = window.mousePos.vec2 / sk.uiScale
    let hit = b.screenToUv(mouse)
    var hover = WorldMapAreaHover()
    if hit.ok:
      hover = b.catalog.hoverAt(b.state, hit.uv)
      # Only show clickable hint when drill can go deeper.
      if b.state.level != MapLevelZone:
        sk.drawHoverHint(b.mapLayout.pos, b.mapLayout.size, hover)

    if window.buttonPressed[MouseLeft] and hit.ok:
      let next = b.catalog.drillIn(b.state, hit.uv)
      b.setSurface(next)
      if next.level == MapLevelZone and auto3dEnabled():
        # Pack 2D first so returning from 3D shows the zone art immediately.
        b.openZone3d(next)

    let crumbs = b.catalog.breadcrumb(b.state)
    let hoverName =
      if hover.found and hover.label.len > 0 and
          b.state.level != MapLevelZone:
        hover.label
      elif b.state.level == MapLevelZone:
        "Enter/Space/3 · bird's-eye 3D"
      else:
        ""
    sk.drawHeader(pad, crumbs, hoverName)

    window.title = WindowTitle & " — " & crumbs
    if hoverName.len > 0 and b.state.level != MapLevelZone:
      window.title = window.title & " / " & hoverName

    sk.endUi()
    window.swapBuffers()

  while not window.closeRequested:
    pollEvents()

when isMainModule:
  main()
