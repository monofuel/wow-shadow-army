## Bird's-eye 3D zone viewer (fork runMapViewer).
##
##   nix develop --command nim r src/tools/map_browser_3d.nim -- \
##     --map:1 --x:… --y:… --z:… --overhead:… --label:Barrens
##
## Controls (stock map viewer free camera):
##   WASD / arrows — move, mouse drag — look, scroll — zoom along view
##   Esc or Q — close and return to the 2D map browser

import
  std/[os, parseopt, strutils],
  windy,
  environment/client/renderer/runtime,
  map_browser/[assets, view3d]

type
  FocusArgs = object
    mapId: uint32
    x, y, z, overhead: float32
    label: string

proc parseArgs(args: seq[string]): FocusArgs =
  result = FocusArgs(
    mapId: 1'u32,
    x: -2370.0'f32,
    y: -1990.0'f32,
    z: 100.0'f32,
    overhead: 1200.0'f32,
    label: "Zone"
  )
  for kind, key, val in getopt(args):
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "map", "m":
        result.mapId = uint32(parseInt(val))
      of "x":
        result.x = parseFloat(val)
      of "y":
        result.y = parseFloat(val)
      of "z":
        result.z = parseFloat(val)
      of "overhead", "o":
        result.overhead = parseFloat(val)
      of "label", "l":
        result.label = val
      of "help", "h":
        echo "map_browser_3d --map:ID --x:X --y:Y --z:Z --overhead:H --label:Name"
        quit(0)
      else:
        echo "unknown option: ", key
    of cmdArgument:
      discard
    of cmdEnd:
      discard

proc main() =
  let focus = parseArgs(commandLineParams())
  echo "map_browser_3d: map=", focus.mapId,
    " pos=(", focus.x, ", ", focus.y, ", ", focus.z, ")",
    " overhead=", focus.overhead,
    " label=", focus.label
  # Point client Data at a real tree before any renderer path resolve.
  if getEnv("VANILLA_WOW_CLIENT_DATA_DIR").strip().len == 0:
    let client = resolveClientDataDir()
    if client.len > 0:
      putEnv("VANILLA_WOW_CLIENT_DATA_DIR", client)
      echo "map_browser_3d: VANILLA_WOW_CLIENT_DATA_DIR=", client
    else:
      echo "map_browser_3d: warning: no client Data dir found"
  if getEnv("VANILLA_WOW_EXTRACTED_DATA_DIR").strip().len == 0:
    let extracted =
      siblingCoworld("coworld-vanilla-wow") / "local_data" / "vmangos-5875-data"
    if dirExists(extracted):
      putEnv("VANILLA_WOW_EXTRACTED_DATA_DIR", extracted)
      echo "map_browser_3d: VANILLA_WOW_EXTRACTED_DATA_DIR=", extracted
  if not ensureForkPlayerAssets():
    echo "map_browser_3d: prepared client assets incomplete — expect grey screen"
  setInitialWorldFocus(
    focus.mapId,
    focus.x,
    focus.y,
    focus.z,
    overhead = focus.overhead
  )

  let title = "map browser 3D — " & focus.label & "  ·  Esc/Q back"

  proc topChrome() =
    ## Lightweight exit hatch; free camera owns WASD/mouse/scroll.
    if window != nil:
      if window.clientButtonPressed(KeyEscape) or
          window.clientButtonPressed(KeyQ):
        window.closeRequested = true

  runMapViewer(
    title = title,
    topUi = topChrome,
    showMapPanel = false,
    enableCameraInput = true,
    loadInitialMapTiles = true
  )

when isMainModule:
  main()
