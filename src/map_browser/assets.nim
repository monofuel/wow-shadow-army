## Resolve stock WorldMap tile roots and compose the 12-tile detail surface.
## Stock layout (upstream `ui/wow_atlas_assets.nim`): 4×3 tiles of 256 → crop
## to 1002×668. Phase 0 only needs the world mosaic ("World").

import
  std/[os, strutils],
  pixie,
  wololo/blp,
  environment/client/localpaths

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
  if override.len > 0:
    result.add override
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
  # local_classic thin instance (symlinked MPQ + optional extracts)
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

proc loadWorldMosaic*(): tuple[image: Image, roots: AssetRoots]
    {.raises: [IOError, PixieError, BlpError].} =
  let roots = resolveWorldMapTileDir(WorldMapSurfaceFile)
  if roots.tileDir.len == 0:
    raise newException(
      IOError,
      "World map tiles not found. Set MAP_BROWSER_WORLD_MAP_DIR or ensure " &
        "coworld-vanilla-wow player/assets interface/worldmap/world exists. " &
        "defaultClientDataDir=" & roots.clientDataDir
    )
  (composeWorldMapSurface(roots.tileDir, WorldMapSurfaceFile), roots)
