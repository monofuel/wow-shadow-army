## Phase 0 map browser spike: open a window and draw the stock World map
## mosaic (Interface\\WorldMap\\World\\World{1..12}.blp → 1002×668).
##
##   nix develop --command nim r src/tools/map_browser.nim
##   make map-browser
##
## Optional:
##   MAP_BROWSER_WORLD_MAP_DIR=/path/to/world   # folder containing world1.blp…
##   MAP_BROWSER_ONCE=1                        # write PNG and exit (no window)
##   MAP_BROWSER_OUT=local_data/map_browser_world.png

import
  std/os,
  chroma, pixie, silky, vmath,
  map_browser/assets

const
  WindowTitle = "map browser — World (phase 0)"
  AtlasSize = 2048

proc fitRect(content, viewport: Vec2): tuple[pos, size: Vec2] =
  if content.x <= 0 or content.y <= 0 or viewport.x <= 0 or viewport.y <= 0:
    return (vec2(0, 0), vec2(0, 0))
  let scale = min(viewport.x / content.x, viewport.y / content.y)
  let size = content * scale
  ((viewport - size) * 0.5'f32, size)

proc drawWorldMosaic(sk: Silky; name: string; pos, size: Vec2) =
  ## Draw a packed atlas image stretched into `size` (drawImage is 1:1 only).
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

proc main() =
  let loaded = loadWorldMosaic()
  let mosaic = loaded.image
  let roots = loaded.roots
  echo "map_browser: tiles from ", roots.sourceLabel
  echo "map_browser: client data dir (fork localpaths) = ", roots.clientDataDir
  echo "map_browser: mosaic ", mosaic.width, "x", mosaic.height

  let once = getEnv("MAP_BROWSER_ONCE").strip() in ["1", "true", "yes"]
  let outPath = block:
    let o = getEnv("MAP_BROWSER_OUT").strip()
    if o.len > 0: o
    else: repoRoot() / "local_data" / "map_browser_world.png"

  if once:
    createDir(outPath.parentDir())
    mosaic.writeFile(outPath)
    echo "map_browser: wrote ", outPath
    return

  let window = newWindow(
    WindowTitle,
    ivec2(1100, 780),
    vsync = true
  )
  makeContextCurrent(window)
  loadExtensions()

  let builder = newAtlasBuilder(AtlasSize, 4)
  if not builder.addImage("world", mosaic):
    quit("map_browser: failed to pack world mosaic into atlas", QuitFailure)

  let sk = newSilky(window, builder.atlasImage, builder.atlas)
  sk.builder = builder

  window.onFrame = proc() =
    sk.beginUi(window, window.size)
    sk.clearScreen(rgbx(12, 14, 20, 255))
    let
      content = vec2(float32(WorldMapDetailWidth), float32(WorldMapDetailHeight))
      layout = fitRect(content, sk.size)
    if layout.size.x > 0 and layout.size.y > 0:
      sk.drawWorldMosaic("world", layout.pos, layout.size)
    sk.endUi()
    window.swapBuffers()

  while not window.closeRequested:
    pollEvents()

when isMainModule:
  main()
