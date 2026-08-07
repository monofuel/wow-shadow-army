## Terrain presentation for the map browser's two 3D view modes.
##
## - mvmRealMap: textured ADT terrain streamed around the camera. Detail is
##   real game terrain but only a window near the camera can be resident;
##   far plane + fog scale with camera height so the ground never fogs out.
## - mvmNavMesh: the fork's whole-map path (`loadSelectedMap`, upstream
##   `--all`): every tile's navmesh + collision mesh in one blocking pass,
##   whole continent visible at once, nothing streams afterwards.

import
  std/monotimes,
  environment/client/video_options,
  environment/client/renderer/world_streaming

from environment/client/renderer/environments import
  fogDistanceOverride, fogStartOverride, fogEndOverride, renderFarclip

type
  MapViewMode* = enum
    mvmRealMap
    mvmNavMesh

const
  ## Real map: stream AOI = 1 + int(farclip * 0.03) chunks → ~5x5 ADT tiles.
  MapStreamFarclip = 1000.0'f32
  ## Real map far-plane bounds: must clear slant distance to the ground from
  ## the camera height; 5300 keeps the WDL horizon rect in its 512-tile cache.
  MapRealFarclipMin = 3900.0'f32
  MapRealFarclipMax = 5300.0'f32
  MapRealMaxCameraHeight* = 4000.0'f32
  ## Nav mesh: whole continent resident, no fog, camera can go way up.
  MapMeshFarclip = 20000.0'f32
  MapMeshMaxCameraHeight* = 9000.0'f32
  MapChunkWindow = 4
  StreamBoostSeconds = 1.5

var streamBoostUntilNs: int64

proc maxCameraHeightFor*(mode: MapViewMode): float32 =
  case mode
  of mvmRealMap: MapRealMaxCameraHeight
  of mvmNavMesh: MapMeshMaxCameraHeight

proc applyMapExplorerPresentation*(mode: MapViewMode) =
  ## Call on mode transitions / terrain entry, not per frame.
  showVisual = false
  fogDistanceOverride = true
  case mode
  of mvmRealMap:
    showNav = false
    showCollision = false
    var settings = defaultRendererStreamSettings()
    settings.worldFarclip = MapStreamFarclip
    settings.objectCullDistance = 1.0'f32
    applyStreamSettings(settings)
    chunkWindowSize = MapChunkWindow
  of mvmNavMesh:
    showNav = true
    showCollision = true
    fogStartOverride = MapMeshFarclip * 0.9'f32
    fogEndOverride = MapMeshFarclip
    renderFarclip = MapMeshFarclip
    setStreamLoadingScreenActive(false)

proc noteTerrainFocusBoost*() =
  streamBoostUntilNs =
    getMonoTime().ticks + int64(StreamBoostSeconds * 1e9)

proc tickTerrainPresentation*(
  mode: MapViewMode;
  terrainMode: bool;
  cameraHeight: float32
) =
  ## Per-frame presentation. Real map: fast 50 ms stream budget while
  ## required terrain is loading (3 ms steady after), and far plane + fog
  ## scale with camera height (from overhead the ground sits at slant
  ## distance ≥ height, so fixed values fog out or clip the whole map).
  if mode != mvmRealMap:
    return
  setStreamLoadingScreenActive(
    terrainMode and (
      getMonoTime().ticks < streamBoostUntilNs or
      not visualStreamRequiredReady()
    )
  )
  let farclip = clamp(
    cameraHeight * 1.6'f32 + 2600.0'f32,
    MapRealFarclipMin,
    MapRealFarclipMax
  )
  renderFarclip = farclip
  fogStartOverride = farclip * 0.85'f32
  fogEndOverride = farclip * 1.02'f32

proc enterRealMapStreaming*() =
  ## Switch the live scene to camera-following textured streaming.
  if loadedWholeMap:
    unloadScene()
  clearStreamAnchor()
  streamNearby = true
  noteTerrainFocusBoost()

proc ensureWholeMapLoaded*(): bool =
  ## Loads every tile of the currently selected map once (blocking; progress
  ## lines go to the terminal). No-op when the map is already fully loaded.
  if loadedWholeMap:
    return true
  echo "map_browser: loading whole map ", selectedMap,
    " — one-time blocking load, progress below"
  loadSelectedMap(resetCamera = false)
  if loadedWholeMap:
    echo "map_browser: whole map ready: ", statusText
  else:
    echo "map_browser: whole map load FAILED: ", loadError
  loadedWholeMap
