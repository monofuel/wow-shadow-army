## Lightweight map explorer — full-region terrain overview, not a game client.
##
## Uses prebuilt continent minimap mosaics (64×64 ADT tiles → 2048² PNG) and
## crops them to a WorldMapArea / free pan-zoom viewport. No fog, no doodads,
## no runMapViewer.

import
  std/[math, os, strutils],
  pixie, vmath,
  environment/client/common,
  environment/client/world_catalogs/model,
  environment/client/world_catalogs/world_map,
  map_browser/[assets, surface]

const
  MinimapTileWorldSize* = 533.33333'f32
  MinimapWorldTiles* = 64
  MosaicPixelSize* = 2048 ## matches convert_all dedicated minimap mosaics

type
  MosaicUvRect* = object
    u0*, v0*, u1*, v1*: float32

  ExploreView* = object
    ## Pan/zoom state over one explorer image (full mosaic crop).
    image*: Image
    label*: string
    ## World map id this overview belongs to (0 EK, 1 Kalimdor).
    mapId*: uint32
    ## Zoom: 1 = fit image in viewport; >1 zooms in.
    zoom*: float32
    ## Pan in image-pixel space (top-left of visible region when zoomed).
    pan*: Vec2
    ## Source mosaic path for diagnostics.
    sourcePath*: string

proc mosaicCandidates*(continentToken: string): seq[string] {.raises: [].} =
  ## Paths to dedicated minimap mosaic PNGs (kalimdor.png / azeroth.png).
  let lower = continentToken.toLowerAscii()
  for coworld in [
    siblingCoworld("coworld-vanilla-wow-fork"),
    siblingCoworld("coworld-vanilla-wow")
  ]:
    result.add coworld / "player" / "assets" / "ui_dedicated" / "minimap" /
      "mosaic" / (lower & ".png")
    result.add coworld / "player" / "assets" / "ui_dedicated" / "minimap" /
      "mosaic" / (continentToken & ".png")

proc continentTokenForMap*(mapId: uint32): string {.raises: [].} =
  case mapId
  of 0'u32: "azeroth"
  of 1'u32: "kalimdor"
  else: ""

proc loadContinentMosaic*(mapId: uint32): tuple[image: Image, path: string]
    {.raises: [IOError, PixieError].} =
  let token = continentTokenForMap(mapId)
  if token.len == 0:
    raise newException(IOError, "no minimap mosaic for map id " & $mapId)
  for path in mosaicCandidates(token):
    if fileExists(path):
      return (readImage(path), path)
  raise newException(
    IOError,
    "minimap mosaic not found for " & token &
      " (expected player/assets/ui_dedicated/minimap/mosaic/" & token & ".png)"
  )

proc worldToMosaicUv*(mapId: uint32; x, y: float32): Vec2 {.raises: [].} =
  ## World (VMaNGOS) position → 0..1 UV on the continent minimap mosaic.
  ## Same convention as stock minimapTile / minimapTextureCrop.
  discard mapId
  let
    tileXf = 32.0'f32 - y / MinimapTileWorldSize
    tileYf = 32.0'f32 - x / MinimapTileWorldSize
  result = vec2(
    clamp(tileXf / MinimapWorldTiles.float32, 0.0'f32, 1.0'f32),
    clamp(tileYf / MinimapWorldTiles.float32, 0.0'f32, 1.0'f32)
  )

proc areaMosaicUvRect*(area: WorldMapAreaBounds): MosaicUvRect {.raises: [].} =
  ## Bounding UV rect of a WorldMapArea on the continent mosaic.
  var
    minU = 1.0'f32
    minV = 1.0'f32
    maxU = 0.0'f32
    maxV = 0.0'f32
  for uv in [
    vec2(0.0'f32, 0.0'f32),
    vec2(1.0'f32, 0.0'f32),
    vec2(0.0'f32, 1.0'f32),
    vec2(1.0'f32, 1.0'f32)
  ]:
    let loc = area.worldMapAreaLocation(uv, 0.0'f32)
    let m = worldToMosaicUv(
      uint32(area.mapId), loc.position.x, loc.position.y)
    minU = min(minU, m.x)
    minV = min(minV, m.y)
    maxU = max(maxU, m.x)
    maxV = max(maxV, m.y)
  # pad slightly so edges aren't clipped
  let
    padU = max(0.002'f32, (maxU - minU) * 0.02'f32)
    padV = max(0.002'f32, (maxV - minV) * 0.02'f32)
  result = MosaicUvRect(
    u0: clamp(minU - padU, 0.0'f32, 1.0'f32),
    v0: clamp(minV - padV, 0.0'f32, 1.0'f32),
    u1: clamp(maxU + padU, 0.0'f32, 1.0'f32),
    v1: clamp(maxV + padV, 0.0'f32, 1.0'f32)
  )

proc cropMosaic*(mosaic: Image; rect: MosaicUvRect): Image
    {.raises: [PixieError].} =
  let
    w = mosaic.width
    h = mosaic.height
    x0 = clamp(int(floor(rect.u0 * w.float32)), 0, w - 1)
    y0 = clamp(int(floor(rect.v0 * h.float32)), 0, h - 1)
    x1 = clamp(int(ceil(rect.u1 * w.float32)), x0 + 1, w)
    y1 = clamp(int(ceil(rect.v1 * h.float32)), y0 + 1, h)
  mosaic.subImage(x0, y0, x1 - x0, y1 - y0)

proc exploreForArea*(
  area: WorldMapAreaBounds;
  label = ""
): ExploreView {.raises: [IOError, PixieError].} =
  ## Full-region terrain overview for one zone/continent WorldMapArea.
  let loaded = loadContinentMosaic(uint32(area.mapId))
  let rect = area.areaMosaicUvRect()
  let crop =
    if area.areaId == 0'u32:
      # Continent: whole mosaic
      loaded.image
    else:
      cropMosaic(loaded.image, rect)
  result = ExploreView(
    image: crop,
    label:
      if label.len > 0: label
      elif area.name.len > 0: area.name
      else: area.fileName,
    mapId: uint32(area.mapId),
    zoom: 1.0'f32,
    pan: vec2(0, 0),
    sourcePath: loaded.path
  )

proc exploreForSurface*(state: SurfaceState): ExploreView
    {.raises: [IOError, PixieError].} =
  if state.surface.found:
    exploreForArea(state.surface.area, state.label)
  else:
    raise newException(IOError, "no surface for explore view")

proc clampPan*(view: var ExploreView; viewW, viewH: float32) {.raises: [].} =
  ## Keep pan so the image always covers the viewport when zoomed.
  if view.image == nil:
    return
  let
    imgW = view.image.width.float32
    imgH = view.image.height.float32
    # visible size in image pixels
    visW = viewW / max(view.zoom, 0.01'f32)
    visH = viewH / max(view.zoom, 0.01'f32)
  if visW >= imgW:
    view.pan.x = (imgW - visW) * 0.5'f32
  else:
    view.pan.x = clamp(view.pan.x, 0.0'f32, imgW - visW)
  if visH >= imgH:
    view.pan.y = (imgH - visH) * 0.5'f32
  else:
    view.pan.y = clamp(view.pan.y, 0.0'f32, imgH - visH)

proc fitZoom*(view: ExploreView; viewW, viewH: float32): float32 {.raises: [].} =
  ## Zoom that fits the whole image in the viewport.
  if view.image == nil or view.image.width == 0 or view.image.height == 0:
    return 1.0'f32
  min(viewW / view.image.width.float32, viewH / view.image.height.float32)

proc applyWheel*(
  view: var ExploreView;
  delta: float32;
  viewW, viewH: float32;
  anchorView: Vec2
) {.raises: [].} =
  ## Zoom toward anchor (viewport coords). delta > 0 zooms in.
  if view.image == nil:
    return
  let
    oldZoom = view.zoom
    factor = if delta > 0: 1.12'f32 elif delta < 0: 1.0'f32 / 1.12'f32 else: 1.0'f32
    fit = fitZoom(view, viewW, viewH)
  view.zoom = clamp(oldZoom * factor, fit * 0.95'f32, fit * 40.0'f32)
  # Keep world point under cursor stable
  let
    imgX = view.pan.x + anchorView.x / oldZoom
    imgY = view.pan.y + anchorView.y / oldZoom
  view.pan.x = imgX - anchorView.x / view.zoom
  view.pan.y = imgY - anchorView.y / view.zoom
  view.clampPan(viewW, viewH)

proc applyPan*(
  view: var ExploreView;
  deltaView: Vec2;
  viewW, viewH: float32
) {.raises: [].} =
  ## Pan by a viewport-pixel delta (drag).
  if view.image == nil:
    return
  view.pan.x -= deltaView.x / max(view.zoom, 0.01'f32)
  view.pan.y -= deltaView.y / max(view.zoom, 0.01'f32)
  view.clampPan(viewW, viewH)

proc applyWasd*(
  view: var ExploreView;
  dx, dy: float32;
  viewW, viewH: float32;
  speed = 280.0'f32
) {.raises: [].} =
  ## Map-space pan (WASD). dx/dy are direction in viewport axes.
  view.applyPan(vec2(dx, dy) * speed, viewW, viewH)
