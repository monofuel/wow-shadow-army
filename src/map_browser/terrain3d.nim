## Lightweight full-region 3D heightfield from WDL (low-res continent terrain).
## Not a game client: no fog, no doodads, no ADT/model streaming — just heights.

import
  std/[math, os, strformat, strutils, tables],
  vmath,
  environment/client/formats/[common, wdl],
  environment/client/world_catalogs/model,
  environment/client/world_catalogs/world_map,
  map_browser/[assets, surface]

const
  WorldTileSize* = GridSize ## 533.333 yards per ADT / WDL tile
  WorldTileOrigin* = 32.0'f32

type
  TerrainVertex* = object
    pos*: Vec3
    color*: Vec3 ## RGB 0..1 height-tinted

  TerrainMesh* = object
    vertices*: seq[TerrainVertex]
    indices*: seq[uint32]
    ## Bounds in renderer space (X/Z horizontal, Y up).
    minPos*, maxPos*: Vec3
    label*: string
    mapDirectory*: string
    tileCount*: int

  ZoneWorldBounds* = object
    mapId*: uint32
    ## VMaNGOS world axes (x/y horizontal, z height unused for framing).
    minX*, maxX*, minY*, maxY*: float32
    label*: string
    mapDirectory*: string

proc continentDir*(mapId: uint32): string {.raises: [].} =
  case mapId
  of 0'u32: "Azeroth"
  of 1'u32: "Kalimdor"
  else: ""

proc zoneWorldBounds*(area: WorldMapAreaBounds; label = ""): ZoneWorldBounds
    {.raises: [].} =
  ## AABB of a WorldMapArea in VMaNGOS world X/Y.
  var
    minX = float32.high
    maxX = float32.low
    minY = float32.high
    maxY = float32.low
  for uv in [
    vec2(0'f32, 0'f32), vec2(1'f32, 0'f32),
    vec2(0'f32, 1'f32), vec2(1'f32, 1'f32)
  ]:
    let p = area.worldMapAreaLocation(uv, 0'f32).position
    minX = min(minX, p.x)
    maxX = max(maxX, p.x)
    minY = min(minY, p.y)
    maxY = max(maxY, p.y)
  result = ZoneWorldBounds(
    mapId: uint32(area.mapId),
    minX: minX,
    maxX: maxX,
    minY: minY,
    maxY: maxY,
    label:
      if label.len > 0: label
      elif area.name.len > 0: area.name
      else: area.fileName,
    mapDirectory:
      if area.fileName.len > 0 and area.areaId == 0'u32:
        area.fileName
      else:
        continentDir(uint32(area.mapId))
  )
  if result.mapDirectory.len == 0:
    result.mapDirectory = continentDir(result.mapId)

proc zoneWorldBounds*(state: SurfaceState): ZoneWorldBounds {.raises: [].} =
  if state.surface.found:
    zoneWorldBounds(state.surface.area, state.label)
  else:
    ZoneWorldBounds(label: state.label, mapDirectory: "Kalimdor", mapId: 1)

proc worldToTile*(worldX, worldY: float32): tuple[tx, ty: int] {.raises: [].} =
  ## VMaNGOS world → ADT/WDL tile indices (same as minimap / stock terrain).
  (
    int(floor(WorldTileOrigin - worldY / WorldTileSize)),
    int(floor(WorldTileOrigin - worldX / WorldTileSize))
  )

proc wdlPathCandidates*(mapDirectory: string): seq[string] {.raises: [].} =
  let name = mapDirectory & ".wdl"
  let lower = mapDirectory.toLowerAscii() & ".wdl"
  for coworld in [
    siblingCoworld("coworld-vanilla-wow-fork"),
    siblingCoworld("coworld-vanilla-wow")
  ]:
    let base = coworld / "player" / "tmp" / "client_assets"
    result.add base / "World" / "Maps" / mapDirectory / name
    result.add base / "world" / "maps" / mapDirectory.toLowerAscii() / lower
    result.add base / "World" / "Maps" / mapDirectory / lower
  # Also prepared assets tree
  for coworld in [
    siblingCoworld("coworld-vanilla-wow-fork"),
    siblingCoworld("coworld-vanilla-wow")
  ]:
    let base = coworld / "player" / "assets"
    result.add base / "world" / "maps" / mapDirectory.toLowerAscii() / lower
    result.add base / "client_assets" / "world" / "maps" /
      mapDirectory.toLowerAscii() / lower

proc loadWdl*(mapDirectory: string): WdlMap {.raises: [IOError].} =
  for path in wdlPathCandidates(mapDirectory):
    if fileExists(path):
      echo "terrain3d: WDL ", path
      try:
        return readWdlMap(readFile(path))
      except CatchableError as err:
        raise newException(IOError, "WDL parse failed: " & err.msg)
  raise newException(
    IOError,
    "WDL not found for " & mapDirectory &
      " (need player/tmp/client_assets/World/Maps/" & mapDirectory & "/" &
      mapDirectory & ".wdl)"
  )

proc heightColor(h, hMin, hMax: float32): Vec3 {.raises: [].} =
  ## Simple hypsometric tint (map-explorer look, not textured terrain).
  let t =
    if hMax <= hMin: 0.5'f32
    else: clamp((h - hMin) / (hMax - hMin), 0.0'f32, 1.0'f32)
  # deep → low green, mid brown, high pale rock
  if t < 0.35'f32:
    let u = t / 0.35'f32
    result = vec3(0.15'f32 + u * 0.15'f32, 0.35'f32 + u * 0.35'f32, 0.18'f32)
  elif t < 0.7'f32:
    let u = (t - 0.35'f32) / 0.35'f32
    result = vec3(0.30'f32 + u * 0.35'f32, 0.55'f32 - u * 0.15'f32, 0.20'f32)
  else:
    let u = (t - 0.7'f32) / 0.3'f32
    result = vec3(0.55'f32 + u * 0.35'f32, 0.45'f32 + u * 0.35'f32, 0.35'f32 + u * 0.4'f32)

proc outerIndex(row, col: int): int {.inline, raises: [].} =
  row * WdlOuterGridSize + col

proc buildTerrainMesh*(
  bounds: ZoneWorldBounds;
  padTiles = 1
): TerrainMesh {.raises: [IOError].} =
  ## Build a height mesh covering the zone AABB (outer WDL grid only).
  let wdl = loadWdl(bounds.mapDirectory)
  let
    t0 = worldToTile(bounds.minX, bounds.minY)
    t1 = worldToTile(bounds.maxX, bounds.maxY)
  var
    minTx = min(t0.tx, t1.tx) - padTiles
    maxTx = max(t0.tx, t1.tx) + padTiles
    minTy = min(t0.ty, t1.ty) - padTiles
    maxTy = max(t0.ty, t1.ty) + padTiles
  minTx = max(0, minTx)
  maxTx = min(WdlGridTiles - 1, maxTx)
  minTy = max(0, minTy)
  maxTy = min(WdlGridTiles - 1, maxTy)

  result.label = bounds.label
  result.mapDirectory = bounds.mapDirectory
  result.minPos = vec3(float32.high, float32.high, float32.high)
  result.maxPos = vec3(float32.low, float32.low, float32.low)

  # First pass: collect heights for color scale
  var hMin = float32.high
  var hMax = float32.low
  for ty in minTy .. maxTy:
    for tx in minTx .. maxTx:
      let idx = wdlTileIndex(tx, ty)
      wdl.tiles.withValue(idx, tile):
        for h in tile.outerHeights:
          hMin = min(hMin, h)
          hMax = max(hMax, h)
  if hMax <= hMin:
    hMin = 0
    hMax = 1

  let step = WorldTileSize / WdlInnerGridSize.float32 ## 17 outer points → 16 steps

  for ty in minTy .. maxTy:
    for tx in minTx .. maxTx:
      let idx = wdlTileIndex(tx, ty)
      if idx notin wdl.tiles:
        continue
      let tile = wdl.tiles.getOrDefault(idx)
      if tile.outerHeights[0] == 0 and tile.outerHeights[1] == 0:
        # empty default — still might be ocean tile with zeros; keep if present
        discard
      inc result.tileCount
      let
        originX = (WorldTileOrigin - tx.float32) * WorldTileSize
        originZ = (WorldTileOrigin - ty.float32) * WorldTileSize
        base = result.vertices.len

      for row in 0 ..< WdlOuterGridSize:
        for col in 0 ..< WdlOuterGridSize:
          let
            oi = outerIndex(row, col)
            h = tile.outerHeights[oi]
            # Renderer space (same as stock WDL horizon): X/Z ground, Y up.
            p = vec3(
              originX - col.float32 * step,
              h,
              originZ - row.float32 * step
            )
          result.vertices.add TerrainVertex(pos: p, color: heightColor(h, hMin, hMax))
          result.minPos.x = min(result.minPos.x, p.x)
          result.minPos.y = min(result.minPos.y, p.y)
          result.minPos.z = min(result.minPos.z, p.z)
          result.maxPos.x = max(result.maxPos.x, p.x)
          result.maxPos.y = max(result.maxPos.y, p.y)
          result.maxPos.z = max(result.maxPos.z, p.z)

      # Quads as two triangles (outer grid only).
      for row in 0 ..< WdlOuterGridSize - 1:
        for col in 0 ..< WdlOuterGridSize - 1:
          let
            i00 = uint32(base + outerIndex(row, col))
            i10 = uint32(base + outerIndex(row, col + 1))
            i01 = uint32(base + outerIndex(row + 1, col))
            i11 = uint32(base + outerIndex(row + 1, col + 1))
          result.indices.add i00
          result.indices.add i10
          result.indices.add i11
          result.indices.add i00
          result.indices.add i11
          result.indices.add i01

  if result.vertices.len == 0:
    raise newException(
      IOError,
      "no WDL tiles in zone bounds for " & bounds.label &
        " (tiles " & $minTx & ".." & $maxTx & "," & $minTy & ".." & $maxTy & ")"
    )

proc meshCenter*(mesh: TerrainMesh): Vec3 {.raises: [].} =
  (mesh.minPos + mesh.maxPos) * 0.5'f32

proc meshHorizontalSpan*(mesh: TerrainMesh): float32 {.raises: [].} =
  max(mesh.maxPos.x - mesh.minPos.x, mesh.maxPos.z - mesh.minPos.z)

proc terrainCliArgs*(bounds: ZoneWorldBounds): seq[string] {.raises: [].} =
  @[
    &"--map:{bounds.mapId}",
    &"--dir:{bounds.mapDirectory}",
    &"--minx:{bounds.minX}",
    &"--maxx:{bounds.maxX}",
    &"--miny:{bounds.minY}",
    &"--maxy:{bounds.maxY}",
    &"--label:{bounds.label}"
  ]
