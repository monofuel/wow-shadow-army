## Opt-in debug instrumentation for the map browser, aimed at AI agents
## diagnosing the tool from logs and files instead of watching the GUI.
##
##   MAP_BROWSER_DEBUG=1     per-second `[mb-debug]` stdout line
##   MAP_BROWSER_STATS=path  stats JSON rewritten every ~2 s and on exit
##   MAP_BROWSER_AUTO="zone=Durotar,seconds=8,screenshot=local_data/mb.png"
##                           autopilot: drill the zone, stream N seconds,
##                           screenshot + final stats, exit (nonzero on fail)

import
  std/[algorithm, json, monotimes, os, strformat, strutils, tables, times],
  vmath,
  environment/client/world_tiles,
  environment/client/renderer/cameras,
  # The facade hides the raw stream counters; read them directly (read-only).
  environment/client/renderer/world_streaming/model_and_viewer,
  environment/client/renderer/world_streaming/readiness

from environment/client/renderer/environments import
  fogStartOverride, fogEndOverride, renderFarclip

type
  MbAutoCfg* = object
    active*: bool
    zone*: string
    seconds*: float64
    screenshot*: string

  MbAutoAction* = enum
    mbaNone
    mbaDrill
    mbaFinish

  MbAutoState = enum
    masIdle
    masWaitDrill
    masStreaming
    masFinishing
    masDone

  MbDebug = object
    lineEnabled: bool
    statsPath: string
    auto: MbAutoCfg
    autoState: MbAutoState
    autoResult: string
    autoSuccess: bool
    startNs: int64
    lastFrameNs: int64
    lastLineNs: int64
    lastStatsNs: int64
    frameMs: seq[float64]
    framesThisSecond: int
    fpsLastSecond: float64
    mode: string
    surface: string
    focusLabel: string
    focusNs: int64
    terrainVisibleNs: int64
    streamSettledNs: int64
    mosaicPackMs: OrderedTable[string, float64]
    overlayBuildMs: OrderedTable[string, float64]

var mb: MbDebug

const
  MbFrameWindow = 600
  MbLinePeriodNs = 1_000_000_000'i64
  MbStatsPeriodNs = 2_000_000_000'i64

proc nowNs(): int64 =
  getMonoTime().ticks

proc msSince(sinceNs: int64): float64 =
  if sinceNs <= 0:
    return -1.0
  float64(nowNs() - sinceNs) / 1e6

proc mbDebugInit*() =
  mb = MbDebug(startNs: nowNs())
  mb.lineEnabled = getEnv("MAP_BROWSER_DEBUG").strip() in ["1", "true", "yes"]
  mb.statsPath = getEnv("MAP_BROWSER_STATS").strip()
  let auto = getEnv("MAP_BROWSER_AUTO").strip()
  if auto.len > 0:
    mb.auto.active = true
    mb.auto.seconds = 8.0
    for part in auto.split(","):
      let kv = part.split("=", maxsplit = 1)
      if kv.len != 2:
        continue
      case kv[0].strip().toLowerAscii()
      of "zone": mb.auto.zone = kv[1].strip()
      of "seconds":
        try:
          mb.auto.seconds = parseFloat(kv[1].strip())
        except ValueError:
          discard
      of "screenshot": mb.auto.screenshot = kv[1].strip()
      else: discard
    mb.autoState = masWaitDrill
    ## Autopilot implies machine-readable output even when not asked for.
    if mb.statsPath.len == 0:
      mb.statsPath = "local_data" / "map_browser_stats.json"
    echo "map_browser: autopilot zone=", mb.auto.zone,
      " seconds=", mb.auto.seconds, " screenshot=", mb.auto.screenshot

proc mbAuto*(): MbAutoCfg =
  mb.auto

proc mbNoteFocus*(label: string) =
  mb.focusLabel = label
  mb.focusNs = nowNs()
  mb.terrainVisibleNs = 0
  mb.streamSettledNs = 0

proc mbNoteMosaicPackMs*(fileName: string; ms: float64) =
  mb.mosaicPackMs[fileName] = ms

proc mbNoteOverlayBuildMs*(name: string; ms: float64) =
  mb.overlayBuildMs[name] = ms

proc percentile(sorted: seq[float64]; p: float64): float64 =
  if sorted.len == 0:
    return 0.0
  let idx = clamp(int(p * float64(sorted.len - 1)), 0, sorted.len - 1)
  sorted[idx]

proc streamPendingNow(): bool =
  selectedMap.len > 0 and streamHasPendingLoads(selectedMap)

proc mbStatsJson(): JsonNode =
  var sorted = mb.frameMs
  sorted.sort()
  let rect = loadedTerrainRequiredTiles
  result = %*{
    "ts": epochTime(),
    "uptime_s": float64(nowNs() - mb.startNs) / 1e9,
    "fps": mb.fpsLastSecond,
    "frame_ms_p50": percentile(sorted, 0.50),
    "frame_ms_p95": percentile(sorted, 0.95),
    "frame_ms_max": (if sorted.len > 0: sorted[^1] else: 0.0),
    "mode": mb.mode,
    "surface": mb.surface,
    "cam": {
      "x": cameraPos.x, "y": cameraPos.y, "z": cameraPos.z,
      "yaw": cameraYaw, "pitch": cameraPitch
    },
    "presentation": {
      "render_farclip": renderFarclip,
      "fog_start": fogStartOverride,
      "fog_end": fogEndOverride
    },
    "stream": {
      "map": selectedMap,
      "pending_labels": streamLabels.len,
      "active_tiles": streamActiveSet.len,
      "loaded_tiles": loadedTileCount,
      "terrain_tiles": loadedTerrainTileCount,
      "object_tiles": loadedObjectTileCount,
      "nav_tiles": loadedNavTileCount,
      "center_x": loadedCenterTileX,
      "center_y": loadedCenterTileY,
      "window": loadedChunkWindowSize,
      "required_rect": {
        "min_x": rect.minX, "min_y": rect.minY,
        "max_x": rect.maxX, "max_y": rect.maxY
      },
      "progress": visualStreamProgress(),
      "required_ready": visualStreamRequiredReady(),
      "has_pending": streamPendingNow(),
      "loaded_whole_map": loadedWholeMap
    },
    "milestones": {
      "focus_label": mb.focusLabel,
      "focus_to_terrain_visible_ms":
        (if mb.terrainVisibleNs > 0:
          float64(mb.terrainVisibleNs - mb.focusNs) / 1e6 else: -1.0),
      "focus_to_stream_settled_ms":
        (if mb.streamSettledNs > 0:
          float64(mb.streamSettledNs - mb.focusNs) / 1e6 else: -1.0)
    },
    "auto": {
      "active": mb.auto.active,
      "zone": mb.auto.zone,
      "result": mb.autoResult
    }
  }
  var packs = newJObject()
  for name, ms in mb.mosaicPackMs:
    packs[name] = %ms
  result["mosaic_pack_ms"] = packs
  var overlays = newJObject()
  for name, ms in mb.overlayBuildMs:
    overlays[name] = %ms
  result["overlay_build_ms"] = overlays

proc mbStatsWrite*(final = false) =
  if mb.statsPath.len == 0:
    return
  try:
    createDir(mb.statsPath.parentDir())
    writeFile(mb.statsPath, mbStatsJson().pretty())
  except CatchableError as err:
    if final:
      echo "map_browser: stats write failed: ", err.msg

proc mbDebugLine() =
  let rect = loadedTerrainRequiredTiles
  echo &"[mb-debug] fps={mb.fpsLastSecond:.0f}" &
    &" stream{{pending={streamLabels.len} active={streamActiveSet.len}" &
    &" loaded={loadedTileCount} rect={rect.maxX - rect.minX + 1}x" &
    &"{rect.maxY - rect.minY + 1} progress={visualStreamProgress():.2f}}}" &
    &" cam=({cameraPos.x:.0f},{cameraPos.y:.0f},{cameraPos.z:.0f})" &
    &" mode={mb.mode} surface={mb.surface}"

proc mbOverlayLines*(): seq[string] =
  ## On-screen mirror of the debug line (backtick panel).
  let rect = loadedTerrainRequiredTiles
  result.add &"fps {mb.fpsLastSecond:.0f}"
  result.add &"tiles loaded={loadedTileCount} pending={streamLabels.len} " &
    &"active={streamActiveSet.len}"
  result.add &"aoi rect {rect.minX}..{rect.maxX} x {rect.minY}..{rect.maxY} " &
    &"window={loadedChunkWindowSize}"
  result.add &"stream progress {visualStreamProgress():.2f} " &
    &"ready={visualStreamRequiredReady()} pending={streamPendingNow()}"
  result.add &"cam ({cameraPos.x:.0f}, {cameraPos.y:.0f}, {cameraPos.z:.0f}) " &
    &"yaw={cameraYaw:.2f} pitch={cameraPitch:.2f}"
  result.add &"farclip {renderFarclip:.0f} fog {fogStartOverride:.0f}.." &
    &"{fogEndOverride:.0f}"
  if mb.focusNs > 0:
    result.add &"focus {mb.focusLabel} terrain_ms=" &
      &"{msSince(mb.focusNs) - msSince(mb.terrainVisibleNs):.0f}" &
      &" settled={mb.streamSettledNs > 0}"

proc mbDebugFrame*(mode, surface: string) =
  ## Call once per app frame (frameBoundary). Cheap when nothing is enabled.
  mb.mode = mode
  mb.surface = surface
  let now = nowNs()
  if mb.lastFrameNs > 0:
    let frameMs = float64(now - mb.lastFrameNs) / 1e6
    mb.frameMs.add frameMs
    if mb.frameMs.len > MbFrameWindow:
      mb.frameMs.delete(0)
  mb.lastFrameNs = now
  inc mb.framesThisSecond

  if mb.focusNs > 0:
    if mb.terrainVisibleNs == 0 and loadedTileCount > 0 and
        visualStreamRequiredReady():
      mb.terrainVisibleNs = now
      if mb.lineEnabled or mb.auto.active:
        echo &"[mb-debug] terrain visible after " &
          &"{float64(now - mb.focusNs) / 1e6:.0f}ms ({mb.focusLabel})"
    if mb.streamSettledNs == 0 and mb.terrainVisibleNs > 0 and
        not streamPendingNow():
      mb.streamSettledNs = now
      if mb.lineEnabled or mb.auto.active:
        echo &"[mb-debug] stream settled after " &
          &"{float64(now - mb.focusNs) / 1e6:.0f}ms ({mb.focusLabel})"

  if now - mb.lastLineNs >= MbLinePeriodNs:
    mb.fpsLastSecond =
      float64(mb.framesThisSecond) * 1e9 / float64(max(now - mb.lastLineNs, 1))
    if mb.lastLineNs > 0 and mb.lineEnabled:
      mbDebugLine()
    mb.lastLineNs = now
    mb.framesThisSecond = 0

  if mb.statsPath.len > 0 and now - mb.lastStatsNs >= MbStatsPeriodNs:
    mb.lastStatsNs = now
    mbStatsWrite()

proc mbAutopilotTick*(): MbAutoAction =
  ## Time-based autopilot state machine; the caller owns drilling/finishing.
  case mb.autoState
  of masIdle, masDone, masFinishing:
    mbaNone
  of masWaitDrill:
    ## One warmup second so the catalog/window are up before drilling.
    if float64(nowNs() - mb.startNs) / 1e9 >= 1.0:
      mb.autoState = masStreaming
      mbaDrill
    else:
      mbaNone
  of masStreaming:
    if mb.focusNs > 0 and msSince(mb.focusNs) / 1e3 >= mb.auto.seconds:
      mb.autoState = masFinishing
      mbaFinish
    else:
      mbaNone

proc mbAutoDrillFailed*(reason: string) =
  mb.autoResult = "drill failed: " & reason
  mb.autoSuccess = false
  mb.autoState = masFinishing

proc mbAutoFinish*(): bool =
  ## Final verdict: terrain became visible and streaming settled in time.
  if mb.autoResult.len == 0:
    if loadedTileCount == 0:
      mb.autoResult = "no map tiles loaded"
      mb.autoSuccess = false
    elif mb.terrainVisibleNs == 0:
      mb.autoResult = "terrain never became visible"
      mb.autoSuccess = false
    elif mb.streamSettledNs == 0:
      mb.autoResult = "streaming never settled"
      mb.autoSuccess = false
    else:
      mb.autoResult = &"ok terrain_ms=" &
        &"{float64(mb.terrainVisibleNs - mb.focusNs) / 1e6:.0f}" &
        &" settled_ms={float64(mb.streamSettledNs - mb.focusNs) / 1e6:.0f}"
      mb.autoSuccess = true
  mb.autoState = masDone
  echo "map_browser: autopilot ", mb.autoResult
  mbStatsWrite(final = true)
  mb.autoSuccess

proc mbExitCode*(): int =
  if mb.auto.active and not mb.autoSuccess: 1 else: 0
