## Whole-continent low-res terrain mesh from the client's WDL heightmap.
## Pure data — no OpenGL, no window code.

import
  std/[math, os, strutils, tables],
  environment/client/formats/[format_primitives, mpq, resolvers, wdl],
  environment/client/localpaths

const
  WorldTileSize* = GridSize
  WorldTileOrigin* = 32.0'f32
  WdlStep = WorldTileSize / float32(WdlInnerGridSize)
  DefaultClientRoot =
    "src" / "wow-coworld" / "wow-classic-data" / "Coworld-WoW-Classic" / "client"

type
  TerrainVertex* = object
    x*, y*, z*: float32
    nx*, ny*, nz*: float32
    r*, g*, b*: float32

  ContinentMesh* = object
    mapId*: uint32
    mapDirectory*: string
    vertices*: seq[TerrainVertex]
    indices*: seq[uint32]
    tileCount*: int
    minZ*, maxZ*: float32
    tileHeights: Table[int, array[WdlOuterHeights, float32]]

proc continentDirectory*(mapId: uint32): string {.raises: [].} =
  ## Map.dbc World\\Maps directory name for a continent map id.
  case mapId
  of 0'u32: "Azeroth"
  of 1'u32: "Kalimdor"
  else: ""

proc resolveClientDataDir(): string {.raises: [].} =
  ## Client Data/ dir (MPQs). Env override, then ticket default, then fork default.
  let envDir = getEnv(ClientDataDirEnv).strip()
  if envDir.len > 0:
    if dirExists(envDir / "Data"):
      return envDir / "Data"
    return envDir
  let ticket = getHomeDir() / DefaultClientRoot
  if dirExists(ticket / "Data"):
    return ticket / "Data"
  if dirExists(ticket):
    return ticket
  defaultClientDataDir()

proc worldToTile*(worldX, worldY: float32): tuple[tx, ty: int] {.raises: [].} =
  ## VMaNGOS world X/Y → ADT/WDL tile indices.
  (
    int(floor(WorldTileOrigin - worldY / WorldTileSize)),
    int(floor(WorldTileOrigin - worldX / WorldTileSize))
  )

proc vertexWorldXY(
  tileX, tileY, row, col: int
): tuple[x, y: float32] {.inline, raises: [].} =
  ## Outer-grid vertex in VMaNGOS world X/Y for one WDL tile cell corner.
  ## Row increases → worldX decreases; col increases → worldY decreases.
  let
    originX = (WorldTileOrigin - float32(tileY)) * WorldTileSize
    originY = (WorldTileOrigin - float32(tileX)) * WorldTileSize
  (
    originX - float32(row) * WdlStep,
    originY - float32(col) * WdlStep
  )

proc elevationColor(z, slopeFactor: float32): tuple[r, g, b: float32]
    {.raises: [].} =
  ## Linear elevation ramp, then darken toward rock grey on steep slopes.
  var r, g, b: float32
  if z < 0'f32:
    let t = clamp((-z) / 200.0'f32, 0'f32, 1'f32)
    r = 0.05'f32 + 0.05'f32 * (1'f32 - t)
    g = 0.15'f32 + 0.25'f32 * (1'f32 - t)
    b = 0.35'f32 + 0.45'f32 * (1'f32 - t)
  elif z < 600'f32:
    let t = z / 600.0'f32
    r = 0.15'f32 + 0.20'f32 * t
    g = 0.45'f32 + 0.25'f32 * t
    b = 0.12'f32 + 0.05'f32 * t
  elif z < 1200'f32:
    let t = (z - 600.0'f32) / 600.0'f32
    r = 0.45'f32 + 0.20'f32 * t
    g = 0.35'f32 - 0.10'f32 * t
    b = 0.20'f32 - 0.05'f32 * t
  else:
    let t = clamp((z - 1200.0'f32) / 800.0'f32, 0'f32, 1'f32)
    r = 0.55'f32 + 0.40'f32 * t
    g = 0.55'f32 + 0.40'f32 * t
    b = 0.55'f32 + 0.40'f32 * t

  let rock = 1.0'f32 - slopeFactor
  r = r * slopeFactor + 0.40'f32 * rock
  g = g * slopeFactor + 0.38'f32 * rock
  b = b * slopeFactor + 0.35'f32 * rock
  (r, g, b)

proc loadContinentMesh*(mapId: uint32): ContinentMesh =
  ## Build a whole-continent 17×17-per-tile mesh from the WDL heightmap.
  let mapDirectory = continentDirectory(mapId)
  if mapDirectory.len == 0:
    raise newException(ValueError, "unsupported mapId for continent mesh: " & $mapId)

  enableMpqArchiveAccess()
  let
    dataDir = resolveClientDataDir()
    resolver = initWowResolver(dataDir, "", "")
    logicalPath = wdlLogicalPath(mapDirectory)
    extracted = resolver.extractClientFileBytes(logicalPath)
    wdl = readWdlMap(extracted.data)

  result.mapId = mapId
  result.mapDirectory = mapDirectory
  result.tileHeights = initTable[int, array[WdlOuterHeights, float32]]()
  result.minZ = float32.high
  result.maxZ = float32.low
  result.vertices = newSeqOfCap[TerrainVertex](wdl.tiles.len * WdlOuterHeights)
  result.indices = newSeqOfCap[uint32](wdl.tiles.len * WdlInnerGridSize * WdlInnerGridSize * 6)

  for tileIndex, tile in wdl.tiles:
    let
      tileX = tileIndex mod WdlGridTiles
      tileY = tileIndex div WdlGridTiles
      base = uint32(result.vertices.len)

    result.tileHeights[tileIndex] = tile.outerHeights
    inc result.tileCount

    var normals = newSeq[tuple[x, y, z: float32]](WdlOuterHeights)

    for row in 0 ..< WdlOuterGridSize:
      for col in 0 ..< WdlOuterGridSize:
        let
          i = row * WdlOuterGridSize + col
          xy = vertexWorldXY(tileX, tileY, row, col)
          z = tile.outerHeights[i]
        result.vertices.add TerrainVertex(
          x: xy.x, y: xy.y, z: z,
          nx: 0, ny: 0, nz: 1,
          r: 0.5, g: 0.5, b: 0.5
        )
        result.minZ = min(result.minZ, z)
        result.maxZ = max(result.maxZ, z)

    for row in 0 ..< WdlInnerGridSize:
      for col in 0 ..< WdlInnerGridSize:
        let
          i00 = row * WdlOuterGridSize + col
          i10 = row * WdlOuterGridSize + (col + 1)
          i01 = (row + 1) * WdlOuterGridSize + col
          i11 = (row + 1) * WdlOuterGridSize + (col + 1)

        # Two triangles, winding so face normal points +Z (up).
        for tri in [
          (i00, i01, i10),
          (i10, i01, i11)
        ]:
          let
            a = result.vertices[int(base) + tri[0]]
            b = result.vertices[int(base) + tri[1]]
            c = result.vertices[int(base) + tri[2]]
            e1x = b.x - a.x
            e1y = b.y - a.y
            e1z = b.z - a.z
            e2x = c.x - a.x
            e2y = c.y - a.y
            e2z = c.z - a.z
            nx = e1y * e2z - e1z * e2y
            ny = e1z * e2x - e1x * e2z
            nz = e1x * e2y - e1y * e2x
          for vi in [tri[0], tri[1], tri[2]]:
            normals[vi].x += nx
            normals[vi].y += ny
            normals[vi].z += nz
          result.indices.add base + uint32(tri[0])
          result.indices.add base + uint32(tri[1])
          result.indices.add base + uint32(tri[2])

    for i in 0 ..< WdlOuterHeights:
      var
        nx = normals[i].x
        ny = normals[i].y
        nz = normals[i].z
      let len = sqrt(nx * nx + ny * ny + nz * nz)
      if len > 1e-6'f32:
        nx /= len
        ny /= len
        nz /= len
      else:
        nx = 0
        ny = 0
        nz = 1
      let
        slope = clamp(nz / 0.7'f32, 0'f32, 1'f32)
        rgb = elevationColor(result.vertices[int(base) + i].z, slope)
      result.vertices[int(base) + i].nx = nx
      result.vertices[int(base) + i].ny = ny
      result.vertices[int(base) + i].nz = nz
      result.vertices[int(base) + i].r = rgb.r
      result.vertices[int(base) + i].g = rgb.g
      result.vertices[int(base) + i].b = rgb.b

  if result.tileCount == 0:
    result.minZ = 0
    result.maxZ = 0

proc sampleHeight*(mesh: ContinentMesh; x, y: float32): float32 =
  ## Bilinear height sample from the WDL outer grid at VMaNGOS (x, y).
  let (tx, ty) = worldToTile(x, y)
  let tileIndex = wdlTileIndex(tx, ty)
  if tileIndex notin mesh.tileHeights:
    return NaN
  let
    heights = mesh.tileHeights[tileIndex]
    originX = (WorldTileOrigin - float32(ty)) * WorldTileSize
    originY = (WorldTileOrigin - float32(tx)) * WorldTileSize
    rowF = (originX - x) / WdlStep
    colF = (originY - y) / WdlStep
  if rowF < -0.01'f32 or colF < -0.01'f32 or
      rowF > float32(WdlInnerGridSize) + 0.01'f32 or
      colF > float32(WdlInnerGridSize) + 0.01'f32:
    return NaN
  let
    row0 = clamp(int(floor(rowF)), 0, WdlInnerGridSize)
    col0 = clamp(int(floor(colF)), 0, WdlInnerGridSize)
    row1 = min(row0 + 1, WdlInnerGridSize)
    col1 = min(col0 + 1, WdlInnerGridSize)
    fr = clamp(rowF - float32(row0), 0'f32, 1'f32)
    fc = clamp(colF - float32(col0), 0'f32, 1'f32)
    h00 = heights[row0 * WdlOuterGridSize + col0]
    h10 = heights[row0 * WdlOuterGridSize + col1]
    h01 = heights[row1 * WdlOuterGridSize + col0]
    h11 = heights[row1 * WdlOuterGridSize + col1]
    h0 = h00 * (1'f32 - fc) + h10 * fc
    h1 = h01 * (1'f32 - fc) + h11 * fc
  h0 * (1'f32 - fr) + h1 * fr
