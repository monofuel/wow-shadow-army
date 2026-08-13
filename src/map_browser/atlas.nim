## Pre-baked continent minimap atlas loader for the map-browser terrain drape.
## Missing files and parse errors return none; the viewer stays on flat shading.

import
  std/[json, options, os, strutils],
  pixie

type
  MinimapAtlas* = object
    image*: Image
    mapId*: uint32
    pxPerTile*: int
    aMin*, aMax*: int
    bMin*, bMax*: int
    width*, height*: int
    tileYd*: float32

const
  AtlasDirEnv* = "MAP_BROWSER_ATLAS_DIR"
  DefaultAtlasDir = "local_data" / "map_browser"
  WorldTileOrigin = 32.0'f32
  RequiredKeys = [
    "map_id", "px_per_tile", "a_min", "a_max", "b_min", "b_max",
    "width", "height", "tile_yd"
  ]

proc atlasDir*(): string =
  ## Directory holding minimap_atlas_<map>.{png,json}. Env overrides default.
  let env = getEnv(AtlasDirEnv).strip()
  if env.len > 0:
    result = env
  else:
    result = DefaultAtlasDir

proc atlasMapName*(mapId: uint32): string =
  ## Filename stem for a continent map id.
  case mapId
  of 0'u32: "azeroth"
  of 1'u32: "kalimdor"
  else: ""

proc atlasFail(msg: string): Option[MinimapAtlas] =
  ## One stderr line, then none — never raise into the viewer.
  stderr.writeLine("map_browser: " & msg)
  none(MinimapAtlas)

proc hasNum(node: JsonNode; key: string): bool =
  ## True when key is a JSON number.
  let v = node{key}
  not v.isNil and v.kind in {JInt, JFloat}

proc asInt(node: JsonNode; key: string): int =
  ## Read a JSON number as int (ints or floats).
  let v = node{key}
  if v.kind == JInt:
    v.getInt()
  else:
    int(v.getFloat())

proc asFloat(node: JsonNode; key: string): float =
  ## Read a JSON number as float (ints or floats).
  let v = node{key}
  if v.kind == JFloat:
    v.getFloat()
  else:
    float(v.getInt())

proc parseAtlasJson*(body: string): Option[MinimapAtlas] =
  ## Parse atlas sidecar JSON. Image stays nil; loadAtlas attaches the PNG.
  result = none(MinimapAtlas)
  var root: JsonNode
  try:
    root = parseJson(body)
  except CatchableError:
    return
  if root.isNil or root.kind != JObject:
    return
  for key in RequiredKeys:
    if not hasNum(root, key):
      return
  let
    mapId = uint32(asInt(root, "map_id"))
    pxPerTile = asInt(root, "px_per_tile")
    aMin = asInt(root, "a_min")
    aMax = asInt(root, "a_max")
    bMin = asInt(root, "b_min")
    bMax = asInt(root, "b_max")
    width = asInt(root, "width")
    height = asInt(root, "height")
    tileYd = asFloat(root, "tile_yd")
  if pxPerTile <= 0 or width <= 0 or height <= 0 or tileYd <= 0.0:
    return
  if aMax < aMin or bMax < bMin:
    return
  result = some(MinimapAtlas(
    mapId: mapId,
    pxPerTile: pxPerTile,
    aMin: aMin,
    aMax: aMax,
    bMin: bMin,
    bMax: bMax,
    width: width,
    height: height,
    tileYd: float32(tileYd)
  ))

proc loadAtlas*(mapId: uint32): Option[MinimapAtlas] =
  ## Load atlas PNG+JSON for a continent. Missing or invalid files return none.
  let name = atlasMapName(mapId)
  if name.len == 0:
    return atlasFail("atlas unknown mapId=" & $mapId)
  let
    root = atlasDir()
    pngPath = root / ("minimap_atlas_" & name & ".png")
    jsonPath = root / ("minimap_atlas_" & name & ".json")
  if not fileExists(pngPath) or not fileExists(jsonPath):
    return atlasFail("atlas missing " & name)
  var body: string
  try:
    body = readFile(jsonPath)
  except CatchableError as err:
    return atlasFail("atlas read failed " & name & ": " & err.msg)
  let parsed = parseAtlasJson(body)
  if parsed.isNone:
    return atlasFail("atlas parse failed " & name)
  var atlas = parsed.get()
  var img: Image
  try:
    img = readImage(pngPath)
  except CatchableError as err:
    return atlasFail("atlas png failed " & name & ": " & err.msg)
  if img.width != atlas.width or img.height != atlas.height:
    return atlasFail(
      "atlas size mismatch " & name &
      ": json " & $atlas.width & "x" & $atlas.height &
      " png " & $img.width & "x" & $img.height
    )
  atlas.image = img
  atlas.mapId = mapId
  some(atlas)

proc atlasUvParams*(atlas: MinimapAtlas):
    tuple[uOrigin, uScale, vOrigin, vScale: float32] =
  ## World (x, y) to atlas UV origin/scale.
  ## Horizontal u comes from world y; vertical v from world x. Axes read
  ## transposed to intuition; do not "fix". Shader: u = (uOrigin - y) * uScale,
  ## v = (vOrigin - x) * vScale.
  let
    t = atlas.tileYd
    aCount = float32(atlas.aMax - atlas.aMin + 1)
    bCount = float32(atlas.bMax - atlas.bMin + 1)
  result.uOrigin = (WorldTileOrigin - float32(atlas.aMin)) * t
  result.uScale = 1.0'f32 / (aCount * t)
  result.vOrigin = (WorldTileOrigin - float32(atlas.bMin)) * t
  result.vScale = 1.0'f32 / (bCount * t)
