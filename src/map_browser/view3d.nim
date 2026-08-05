## Bird's-eye 3D zone view focus math (GL entry: src/tools/map_browser_3d.nim).

import
  std/[math, os, strformat, strutils],
  vmath,
  environment/client/common,
  environment/client/world_catalogs/model,
  environment/client/world_catalogs/world_map,
  map_browser/[assets, surface]

type
  BirdseyeFocus* = object
    mapId*: uint32
    x*, y*, z*: float32
    overhead*: float32
    label*: string
    fileName*: string

proc zoneWorldSpan*(area: WorldMapAreaBounds): tuple[spanX, spanY, half: float32]
    {.raises: [].} =
  ## WorldMapArea is axis-aligned in world X/Y (see worldMapAreaLocation).
  let
    spanX = abs(area.bottom - area.top)
    spanY = abs(area.right - area.left)
  (spanX, spanY, max(spanX, spanY) * 0.5'f32)

proc birdseyeOverhead*(halfExtent: float32): float32 {.raises: [].} =
  ## Height so the zone roughly fills a bird's-eye frustum (pitch ≈ -75°).
  clamp(halfExtent * 1.25'f32, 280.0'f32, 4200.0'f32)

proc birdseyeFocusForArea*(
  area: WorldMapAreaBounds;
  label = "";
  fileName = ""
): BirdseyeFocus {.raises: [].} =
  let
    center = area.worldMapAreaLocation(vec2(0.5'f32, 0.5'f32), 0.0'f32)
    span = area.zoneWorldSpan()
  result = BirdseyeFocus(
    mapId: uint32(area.mapId),
    x: center.position.x,
    y: center.position.y,
    z: center.position.z,
    overhead: birdseyeOverhead(span.half),
    label:
      if label.len > 0: label
      elif area.name.len > 0: area.name
      else: area.fileName,
    fileName:
      if fileName.len > 0: fileName
      else: area.fileName
  )

proc birdseyeFocus*(state: SurfaceState): BirdseyeFocus {.raises: [].} =
  ## Focus for the current zone (or continent) surface.
  if state.surface.found:
    birdseyeFocusForArea(state.surface.area, state.label, state.fileName)
  else:
    BirdseyeFocus(
      label: state.label,
      fileName: state.fileName,
      overhead: 800.0'f32
    )

proc birdseyeCliArgs*(focus: BirdseyeFocus): seq[string] {.raises: [].} =
  @[
    &"--map:{focus.mapId}",
    &"--x:{focus.x}",
    &"--y:{focus.y}",
    &"--z:{focus.z}",
    &"--overhead:{focus.overhead}",
    &"--label:{focus.label}"
  ]

proc linkIfMissing(linkPath, targetPath, label: string): bool {.raises: [].} =
  ## Create a symlink when missing; succeed if already present and usable.
  if fileExists(linkPath) or dirExists(linkPath) or symlinkExists(linkPath):
    return true
  if not (fileExists(targetPath) or dirExists(targetPath)):
    echo "map_browser: missing ", label, " at ", targetPath
    return false
  try:
    createDir(linkPath.parentDir())
    createSymlink(targetPath, linkPath)
    echo "map_browser: linked ", linkPath, " -> ", targetPath
    result = true
  except CatchableError as err:
    echo "map_browser: could not link ", label, ": ", err.msg
    result = false

proc ensureForkPlayerAssets*(): bool {.raises: [].} =
  ## Map viewer resolves paths under the *fork* player/ tree (compile-time
  ## source root). Native GL uses:
  ##   player/assets/atlas.png          — UI atlas
  ##   player/tmp/client_assets/…       — prepared ADTs / DBFilesClient
  ## Upstream already has both (tmp often → coworld-local-data cache). Link
  ## them into the fork when absent so 3D isn't a grey empty stream.
  let
    forkPlayer = siblingCoworld("coworld-vanilla-wow-fork") / "player"
    upPlayer = siblingCoworld("coworld-vanilla-wow") / "player"
    forkAssets = forkPlayer / "assets"
    upAssets = upPlayer / "assets"
    forkClientAssets = forkPlayer / "tmp" / "client_assets"
    upClientAssets = upPlayer / "tmp" / "client_assets"
  var ok = true
  if not linkIfMissing(forkAssets, upAssets, "player/assets"):
    ok = false
  if not linkIfMissing(forkClientAssets, upClientAssets, "player/tmp/client_assets"):
    ok = false
  # Hard requirement for terrain: at least one Kalimdor ADT in the scratch tree.
  let probeAdt = forkClientAssets / "World" / "Maps" / "Kalimdor" /
    "Kalimdor_35_36.adt"
  if not fileExists(probeAdt):
    # case-insensitive probe
    let lower = forkClientAssets / "world" / "maps" / "kalimdor" /
      "kalimdor_35_36.adt"
    if not fileExists(lower):
      echo "map_browser: no prepared ADTs under ", forkClientAssets,
        " (expected World/Maps/Kalimdor/*.adt) — 3D will be blank grey"
      ok = false
    else:
      ok = ok and true
  if not fileExists(forkClientAssets / "DBFilesClient" / "Light.dbc") and
      not fileExists(forkClientAssets / "dbfilesclient" / "Light.dbc"):
    echo "map_browser: warning: Light.dbc missing under client_assets ",
      "(lighting may fail; terrain can still load)"
  result = ok

proc resolveClientDataDir*(): string {.raises: [].} =
  ## Prefer env, then known Softmax layouts (Makefile used a dead default).
  let envDir = getEnv("VANILLA_WOW_CLIENT_DATA_DIR").strip()
  if envDir.len > 0 and (dirExists(envDir) or dirExists(envDir / "Data")):
    return envDir
  for candidate in [
    siblingCoworld("wow-classic-data") / "Coworld-WoW-Classic" / "client",
    siblingCoworld("coworld-vanilla-wow") / "local_data" / "coworld-bundle" /
      "Coworld-WoW-Classic" / "client",
    repoRoot() / "local_classic" / "client",
    getHomeDir() / "Code" / "local_data" / "Coworld-WoW-Classic" / "client",
    getHomeDir() / "Code" / "local_data" / "wow-1.12.1"
  ]:
    if dirExists(candidate / "Data") or dirExists(candidate):
      return candidate
  ""
