## Map browser: stock World map surfaces with discrete drill
## (World → continent → zone). Phase 0+1.
##
##   nix develop --command nim r src/tools/map_browser.nim
##   make map-browser
##
## Optional:
##   MAP_BROWSER_WORLD_MAP_DIR=/path/to/worldmap_or_surface
##   MAP_BROWSER_ZMP_DIR=/path/to/zmp_folder
##   MAP_BROWSER_ONCE=1          # compose current surface PNG and exit
##   MAP_BROWSER_OUT=local_data/map_browser_world.png
##   VANILLA_WOW_EXTRACTED_DATA_DIR=…/vmangos-5875-data

import
  std/[os, strutils, tables],
  chroma, pixie, silky, vmath,
  environment/client/world_catalogs,
  map_browser/[assets, surface]

const
  WindowTitle = "map browser"
  AtlasSize = 8192

type
  Browser = object
    catalog: WorldCatalog
    state: SurfaceState
    sk: Silky
    packed: Table[string, bool]
    mapLayout: tuple[pos, size: Vec2]
    statusLine: string

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

proc atlasKey(fileName: string): string =
  "map:" & fileName.toLowerAscii()

proc ensurePacked(b: var Browser; fileName: string) =
  let key = fileName.atlasKey
  if b.packed.getOrDefault(key):
    return
  let loaded = loadSurfaceMosaic(fileName)
  if not b.sk.builder.addImage(key, loaded.image):
    raise newException(IOError, "atlas full packing " & fileName)
  b.sk.image = b.sk.builder.atlasImage
  b.sk.atlas = b.sk.builder.atlas
  b.sk.uploadAtlas()
  b.packed[key] = true
  echo "map_browser: packed ", fileName, " from ", loaded.roots.sourceLabel

proc setSurface(b: var Browser; next: SurfaceState) =
  b.state = next
  try:
    b.ensurePacked(next.fileName)
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
    # Smoke the catalog drill without a window.
    let cont = catalog.drillIn(state, vec2(0.25, 0.5))
    echo "map_browser: sample world→continent level=", cont.level,
      " file=", cont.fileName, " label=", cont.label
    if cont.level == MapLevelContinent:
      var zoneHits = 0
      var sampleZone = cont
      for yi in 0 .. 4:
        for xi in 0 .. 7:
          let uv = vec2(
            (xi.float32 + 0.5'f32) / 8.0'f32,
            (yi.float32 + 0.5'f32) / 5.0'f32
          )
          let z = catalog.drillIn(cont, uv)
          if z.level == MapLevelZone:
            inc zoneHits
            if sampleZone.level != MapLevelZone:
              sampleZone = z
      echo "map_browser: sample zone hits on ", cont.fileName, "=", zoneHits
      if sampleZone.level == MapLevelZone:
        echo "map_browser: sample zone file=", sampleZone.fileName,
          " label=", sampleZone.label
        let back = catalog.zoomOut(sampleZone)
        echo "map_browser: zoomOut zone→", back.level, " ", back.fileName
        let world = catalog.zoomOut(back)
        echo "map_browser: zoomOut continent→", world.level, " ", world.fileName
    return

  let window = newWindow(WindowTitle, ivec2(1100, 780), vsync = true)
  makeContextCurrent(window)
  loadExtensions()

  let builder = newAtlasBuilder(AtlasSize, 4)
  let sk = newSilky(window, builder.atlasImage, builder.atlas)
  sk.builder = builder

  var b = Browser(catalog: catalog, sk: sk, packed: initTable[string, bool]())
  b.setSurface(state)

  window.onFrame = proc() =
    # Zoom out
    if window.buttonPressed[KeyEscape] or window.buttonPressed[MouseRight] or
        window.buttonPressed[KeyBackspace]:
      b.setSurface(b.catalog.zoomOut(b.state))

    sk.beginUi(window, window.size)
    sk.clearScreen(rgbx(12, 14, 20, 255))

    let
      pad = 12.0'f32
      header = 28.0'f32
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

    # Hover label + status
    let mouse = window.mousePos.vec2 / sk.uiScale
    let hit = b.screenToUv(mouse)
    var hover = ""
    if hit.ok:
      hover = b.catalog.hoverLabel(b.state, hit.uv)

    # Left click drill-in
    if window.buttonPressed[MouseLeft] and hit.ok:
      b.setSurface(b.catalog.drillIn(b.state, hit.uv))

    # Simple text via drawRect bars (no font packed) — title in window chrome.
    window.title = WindowTitle & " — " & b.state.label
    if hover.len > 0:
      window.title = WindowTitle & " — " & b.state.label & " / " & hover

    # Status strip
    sk.drawRect(vec2(pad, pad), vec2(sk.size.x - pad * 2, 22), rgbx(24, 28, 36, 230))

    sk.endUi()
    window.swapBuffers()

  while not window.closeRequested:
    pollEvents()

when isMainModule:
  main()
