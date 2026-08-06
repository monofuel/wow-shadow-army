## Full-region 3D map explorer using the **fork terrain renderer**.
##
## Reuses stock ADT terrain + materials (`runMapViewer`) but configured as a
## map tool, not a game client:
##   - camera framed for the whole zone AABB (high bird's-eye)
##   - fog forced far / effectively off
##   - doodads + WMOs off (`showVisual = false`) — terrain only
##   - larger stream window so more of the zone loads
##
##   make map-browser-3d
##   (or zone-click from map_browser)
##
## Controls (stock free camera + map-tool tweaks):
##   WASD / mouse look / scroll — move
##   Esc / Q — quit back to 2D browser

import
  std/[math, os, parseopt, strutils],
  windy,
  environment/client/renderer/runtime,
  environment/client/renderer/world_streaming,
  environment/client/renderer/cameras,
  map_browser/[assets, terrain3d, view3d]

# Fog knobs live on environments; import selectively to avoid `window` clash.
from environment/client/renderer/environments import
  fogDistanceOverride, fogStartOverride, fogEndOverride, renderFarclip

type
  FocusArgs = object
    mapId: uint32
    mapDirectory: string
    minX, maxX, minY, maxY: float32
    label: string
    hasBounds: bool
    # legacy point focus
    x, y, z, overhead: float32

proc parseArgs(args: seq[string]): FocusArgs =
  result = FocusArgs(
    mapId: 1'u32,
    mapDirectory: "Kalimdor",
    minX: -4500,
    maxX: -500,
    minY: -4500,
    maxY: -500,
    label: "Zone",
    hasBounds: false,
    x: -2372,
    y: -1940,
    z: 96,
    overhead: 1200
  )
  for kind, key, val in getopt(args):
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "map", "m":
        result.mapId = uint32(parseInt(val))
      of "dir", "d":
        result.mapDirectory = val
      of "minx":
        result.minX = parseFloat(val)
        result.hasBounds = true
      of "maxx":
        result.maxX = parseFloat(val)
        result.hasBounds = true
      of "miny":
        result.minY = parseFloat(val)
        result.hasBounds = true
      of "maxy":
        result.maxY = parseFloat(val)
        result.hasBounds = true
      of "label", "l":
        result.label = val
      of "x":
        result.x = parseFloat(val)
      of "y":
        result.y = parseFloat(val)
      of "z":
        result.z = parseFloat(val)
      of "overhead", "o":
        result.overhead = parseFloat(val)
      of "help", "h":
        echo "map_browser_3d --map:1 --minx: --maxx: --miny: --maxy: --label:"
        quit(0)
      else:
        echo "unknown option: ", key
    else:
      discard

proc applyMapExplorerPresentation*() =
  ## Map-tool presentation: terrain yes, full client clutter no.
  showVisual = false ## doodads + WMOs off (panel "Show doodads/WMOs")
  showNav = false
  showCollision = false
  chunkWindowSize = MaxChunkWindowSize ## stream a wide terrain window
  moveSpeed = 220.0'f32
  # Distance fog: force far so high bird's-eye isn't solid grey
  fogDistanceOverride = true
  fogStartOverride = 6000.0'f32
  fogEndOverride = 9500.0'f32
  renderFarclip = 10000.0'f32

proc frameOverhead(spanX, spanY: float32): float32 =
  ## Height so most of the zone fits a bird's-eye perspective.
  let half = max(spanX, spanY) * 0.5'f32
  clamp(half * 1.05'f32, 350.0'f32, 3200.0'f32)

proc main() =
  let args = parseArgs(commandLineParams())

  if getEnv("VANILLA_WOW_CLIENT_DATA_DIR").strip().len == 0:
    let client = resolveClientDataDir()
    if client.len > 0:
      putEnv("VANILLA_WOW_CLIENT_DATA_DIR", client)
      echo "map_browser_3d: CLIENT_DATA=", client
  if getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR").strip().len == 0:
    let extracted =
      siblingCoworld("coworld-vanilla-wow") / "local_data" / "vmangos-5875-data"
    if dirExists(extracted):
      putEnv("VANILLA_WOW_EXTRACTED_DATA_DIR", extracted)

  if not ensureForkPlayerAssets():
    echo "map_browser_3d: prepared assets incomplete — terrain may fail to load"

  var
    cx, cy, cz, overhead: float32
  if args.hasBounds:
    cx = (args.minX + args.maxX) * 0.5'f32
    cy = (args.minY + args.maxY) * 0.5'f32
    cz = 50.0'f32
    overhead = frameOverhead(args.maxX - args.minX, args.maxY - args.minY)
    echo "map_browser_3d: full-region ", args.label,
      " center=(", cx, ", ", cy, ") spanX=", args.maxX - args.minX,
      " spanY=", args.maxY - args.minY, " overhead=", overhead
  else:
    cx = args.x
    cy = args.y
    cz = args.z
    overhead = args.overhead
    echo "map_browser_3d: point focus ", args.label,
      " @(", cx, ", ", cy, ", ", cz, ") overhead=", overhead

  # Presentation before the renderer window opens / streams.
  applyMapExplorerPresentation()

  setInitialWorldFocus(
    args.mapId,
    cx,
    cy,
    cz,
    overhead = overhead
  )

  let title =
    "map explorer — " & args.label & "  ·  terrain only · Esc/Q back"

  proc keepMapExplorerMode() =
    ## Re-assert each frame (setup/lighting can touch fog/stream settings).
    applyMapExplorerPresentation()
    # `window` is the renderer facade (runtime), not environments.
    if runtime.window != nil:
      if runtime.window.clientButtonPressed(KeyEscape) or
          runtime.window.clientButtonPressed(KeyQ):
        runtime.window.closeRequested = true

  runMapViewer(
    title = title,
    topUi = keepMapExplorerMode,
    showMapPanel = false,
    enableCameraInput = true,
    loadInitialMapTiles = true
  )

when isMainModule:
  main()
