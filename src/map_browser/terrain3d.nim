## World-coordinate helpers for the map browser: zone AABBs in VMaNGOS world
## X/Y and world → ADT tile math. The 3D backdrop itself comes from the fork
## renderer (streamed ADTs near the camera, WDL horizon ring beyond).

import
  std/math,
  vmath,
  environment/client/formats/common,
  environment/client/world_catalogs/model,
  environment/client/world_catalogs/world_map,
  map_browser/surface

const
  WorldTileSize* = GridSize ## 533.333 yards per ADT / WDL tile
  WorldTileOrigin* = 32.0'f32

type
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

proc zoneTerrainSupported*(bounds: ZoneWorldBounds): bool {.raises: [].} =
  ## Some WorldMapAreas live off the regular world grid (oversized painted
  ## cities, non-continent maps) — those stay 2D-only instead of focusing a
  ## grey void.
  if bounds.mapId notin [0'u32, 1'u32]:
    return false
  if bounds.maxX <= bounds.minX or bounds.maxY <= bounds.minY:
    return false
  let
    t0 = worldToTile(bounds.minX, bounds.minY)
    t1 = worldToTile(bounds.maxX, bounds.maxY)
  for tileIndex in [t0.tx, t0.ty, t1.tx, t1.ty]:
    if tileIndex < 0 or tileIndex > 63:
      return false
  true
