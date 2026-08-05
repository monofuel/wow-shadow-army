## Resolve stock WorldMap tile roots and compose detail surfaces.
## Stock layout (upstream `ui/wow_atlas_assets.nim`): 4×3 tiles of 256 → crop
## to 1002×668. Zone base BLPs are the fog-of-war “hidden” art; full detail
## is WorldMapOverlay pieces (Razor Hill, Valley of Trials, …) composited on
## top — always fully revealed in this tool (no PLAYER_EXPLORED_ZONES gate).

import
  std/[os, strutils],
  pixie,
  wololo/blp,
  environment/client/localpaths,
  environment/client/world_catalogs/model

const
  WorldMapDetailWidth* = 1002
  WorldMapDetailHeight* = 668
  WorldMapTileSize* = 256
  WorldMapColumns* = 4
  WorldMapRows* = 3
  WorldMapSurfaceFile* = "World"

type
  AssetRoots* = object
    ## Where we found tiles and what the client localpaths resolver reports.
    tileDir*: string
    clientDataDir*: string
    sourceLabel*: string
    overlayCount*: int

proc premultiplyAlpha(image: Image) {.raises: [].} =
  ## BLP is straight alpha; Pixie NormalBlend wants premultiplied.
  if image == nil:
    return
  for i in 0 ..< image.data.len:
    var color = image.data[i]
    if color.a == 255'u8:
      continue
    let a = uint32(color.a)
    color.r = uint8((uint32(color.r) * a + 127'u32) div 255'u32)
    color.g = uint8((uint32(color.g) * a + 127'u32) div 255'u32)
    color.b = uint8((uint32(color.b) * a + 127'u32) div 255'u32)
    image.data[i] = color

proc overlayTileCount(textureSize: int32): int {.raises: [].} =
  if textureSize <= 0:
    return 0
  (textureSize.int + WorldMapTileSize - 1) div WorldMapTileSize

proc overlayTilePixelSize(textureSize: int32; tileIndex, tileCount: int): int
    {.raises: [].} =
  if tileIndex < tileCount:
    WorldMapTileSize
  else:
    let remainder = textureSize.int mod WorldMapTileSize
    if remainder == 0: WorldMapTileSize else: remainder

proc repoRoot*(): string {.raises: [].} =
  ## wow-shadow-army root (this file is src/map_browser/assets.nim).
  currentSourcePath().parentDir().parentDir().parentDir()

proc siblingCoworld*(name: string): string {.raises: [].} =
  repoRoot().parentDir() / name

proc worldMapTileDirCandidates*(fileName = WorldMapSurfaceFile): seq[string]
    {.raises: [].} =
  ## Ordered search for prepared Interface/WorldMap/<file>/ tile folders.
  let lower = fileName.toLowerAscii()
  let classicClient = getEnv("VANILLA_WOW_CLIENT_DATA_DIR").strip()
  let override = getEnv("MAP_BROWSER_WORLD_MAP_DIR").strip()
  # MAP_BROWSER_WORLD_MAP_DIR may point at a single surface folder or the
  # worldmap parent that contains World/, Kalimdor/, Durotar/, …
  if override.len > 0:
    result.add override
    result.add override / fileName
    result.add override / lower
  for coworld in [
    siblingCoworld("coworld-vanilla-wow-fork"),
    siblingCoworld("coworld-vanilla-wow")
  ]:
    result.add coworld / "player" / "assets" / "interface" / "worldmap" / lower
    result.add coworld / "local_data" / "player" / "browser-assets" / "delta" /
      "interface" / "worldmap" / lower
  if classicClient.len > 0:
    let data = classicClient
    result.add data / "Interface" / "WorldMap" / fileName
    result.add data / "interface" / "worldmap" / lower
  result.add repoRoot() / "local_classic" / "client" / "Data" / "Interface" /
    "WorldMap" / fileName

proc resolveWorldMapTileDir*(fileName = WorldMapSurfaceFile): AssetRoots
    {.raises: [].} =
  result.clientDataDir = defaultClientDataDir()
  for candidate in fileName.worldMapTileDirCandidates():
    if candidate.len == 0 or not dirExists(candidate):
      continue
    let probe = candidate / (fileName.toLowerAscii() & "1.blp")
    let probeAlt = candidate / (fileName & "1.blp")
    if fileExists(probe) or fileExists(probeAlt):
      result.tileDir = candidate
      result.sourceLabel = candidate
      return
  result.sourceLabel = "not found"

proc tileBlpPath(tileDir, fileName: string; tileIndex: int): string
    {.raises: [].} =
  let lower = fileName.toLowerAscii()
  let a = tileDir / (lower & $tileIndex & ".blp")
  if fileExists(a):
    return a
  tileDir / (fileName & $tileIndex & ".blp")

proc composeWorldMapSurface*(
  tileDir: string;
  fileName = WorldMapSurfaceFile
): Image {.raises: [IOError, PixieError, BlpError].} =
  ## Compose stock 12-tile WorldMap detail (1002×668) from prepared BLPs.
  let mosaic = newImage(
    WorldMapTileSize * WorldMapColumns,
    WorldMapTileSize * WorldMapRows
  )
  for tileIndex in 1 .. (WorldMapColumns * WorldMapRows):
    let path = tileBlpPath(tileDir, fileName, tileIndex)
    if not fileExists(path):
      raise newException(IOError, "missing world map tile: " & path)
    let tile = readBlpTexture(path).image
    if tile == nil:
      raise newException(IOError, "failed to decode BLP: " & path)
    let
      column = (tileIndex - 1) mod WorldMapColumns
      row = (tileIndex - 1) div WorldMapColumns
    mosaic.draw(
      tile,
      translate(vec2(
        float32(column * WorldMapTileSize),
        float32(row * WorldMapTileSize)
      )),
      OverwriteBlend
    )
  result = mosaic.subImage(0, 0, WorldMapDetailWidth, WorldMapDetailHeight)

proc overlayBlpPath(tileDir, textureName: string; tileIndex: int): string
    {.raises: [].} =
  var base = textureName.strip()
  if base.toLowerAscii().endsWith(".blp"):
    base = base[0 ..< base.len - 4]
  let lower = base.toLowerAscii()
  let a = tileDir / (lower & $tileIndex & ".blp")
  if fileExists(a):
    return a
  tileDir / (base & $tileIndex & ".blp")

proc composeWorldMapOverlay*(
  tileDir: string;
  overlay: WorldMapOverlayInfo
): Image {.raises: [IOError, PixieError, BlpError].} =
  ## Numbered overlay tiles at 256px steps (stock FrameXML / composeWorldMapOverlay).
  let
    columns = overlay.textureWidth.overlayTileCount()
    rows = overlay.textureHeight.overlayTileCount()
  if columns <= 0 or rows <= 0:
    raise newException(IOError, "empty world-map overlay dimensions")
  result = newImage(overlay.textureWidth.int, overlay.textureHeight.int)
  for row in 0 ..< rows:
    let tileHeight = overlayTilePixelSize(overlay.textureHeight, row + 1, rows)
    for column in 0 ..< columns:
      let
        tileWidth = overlayTilePixelSize(
          overlay.textureWidth, column + 1, columns)
        tileIndex = row * columns + column + 1
        path = overlayBlpPath(tileDir, overlay.textureName, tileIndex)
      if not fileExists(path):
        raise newException(IOError, "missing overlay tile: " & path)
      let tile = readBlpTexture(path).image
      if tile == nil:
        raise newException(IOError, "failed to decode overlay BLP: " & path)
      let clipped = tile.subImage(
        0, 0,
        min(tileWidth, tile.width),
        min(tileHeight, tile.height)
      )
      result.draw(
        clipped,
        translate(vec2(
          float32(column * WorldMapTileSize),
          float32(row * WorldMapTileSize)
        )),
        OverwriteBlend
      )
  result.premultiplyAlpha()

proc allOverlaysForArea*(
  overlays: openArray[WorldMapOverlayInfo];
  areaMapId: uint32
): seq[WorldMapOverlayInfo] {.raises: [].} =
  ## Every WorldMapOverlay row for a surface — no explored-bit filter.
  if areaMapId == 0'u32:
    return
  for overlay in overlays:
    if overlay.mapAreaId == areaMapId:
      result.add overlay

proc compositeRevealedSurface*(
  base: Image;
  tileDir: string;
  overlays: openArray[WorldMapOverlayInfo]
): tuple[image: Image, applied: int]
    {.raises: [IOError, PixieError, BlpError].} =
  ## Base fog art + all overlay pieces (fully explored).
  result.image = base
  for overlay in overlays:
    if overlay.textureWidth <= 0 or overlay.textureHeight <= 0:
      continue
    try:
      let piece = composeWorldMapOverlay(tileDir, overlay)
      result.image.draw(
        piece,
        translate(vec2(float32(overlay.offsetX), float32(overlay.offsetY))),
        NormalBlend
      )
      inc result.applied
    except CatchableError as err:
      # Missing optional overlay tiles should not blank the whole map.
      echo "map_browser: overlay skip ", overlay.textureName, ": ", err.msg

proc loadSurfaceMosaic*(
  fileName: string;
  areaMapId: uint32 = 0'u32;
  overlays: openArray[WorldMapOverlayInfo] = []
): tuple[image: Image, roots: AssetRoots]
    {.raises: [IOError, PixieError, BlpError].} =
  ## Load World / continent / zone surface; zone maps get full overlay reveal.
  let token =
    if fileName.len > 0: fileName
    else: WorldMapSurfaceFile
  var roots = resolveWorldMapTileDir(token)
  if roots.tileDir.len == 0:
    raise newException(
      IOError,
      "World map tiles not found for '" & token & "'. Set MAP_BROWSER_WORLD_MAP_DIR " &
        "or ensure coworld-vanilla-wow player/assets interface/worldmap/" &
        token.toLowerAscii() & " exists. defaultClientDataDir=" & roots.clientDataDir
    )
  var image = composeWorldMapSurface(roots.tileDir, token)
  let applicable = overlays.allOverlaysForArea(areaMapId)
  if applicable.len > 0:
    let composed = compositeRevealedSurface(image, roots.tileDir, applicable)
    image = composed.image
    roots.overlayCount = composed.applied
  (image, roots)

proc loadWorldMosaic*(): tuple[image: Image, roots: AssetRoots]
    {.raises: [IOError, PixieError, BlpError].} =
  loadSurfaceMosaic(WorldMapSurfaceFile)

proc zmpPathCandidates*(): seq[string] {.raises: [].} =
  ## Folders that may contain azeroth.zmp / kalimdor.zmp (zone ownership grids).
  let override = getEnv("MAP_BROWSER_ZMP_DIR").strip()
  if override.len > 0:
    result.add override
  for coworld in [
    siblingCoworld("coworld-vanilla-wow-fork"),
    siblingCoworld("coworld-vanilla-wow")
  ]:
    result.add coworld / "player" / "assets" / "client_assets" / "interface" /
      "worldmap"
    result.add coworld / "local_data" / "player" / "browser-assets" / "delta" /
      "client_assets" / "interface" / "worldmap"

proc findZmpFile*(logicalPath: string): string {.raises: [].} =
  ## Resolve Interface\\WorldMap\\Kalimdor.zmp → on-disk path, or "".
  let base = logicalPath.replace("\\", "/").split('/')[^1].toLowerAscii()
  for dir in zmpPathCandidates():
    let path = dir / base
    if fileExists(path):
      return path
  ""
