## Opt-in stats + autopilot probe for the standalone map browser.
##
##   MAP_BROWSER_STATS=path.json
##       rewritten every ~2s and at exit
##   MAP_BROWSER_AUTO="seconds=N,screenshot=path.png"
##       run the real window N seconds, screenshot, exit
##       (exit 1 if mesh failed / vertex_count == 0)

import
  std/[algorithm, json, monotimes, os, strutils, times],
  map_browser/gl_view

type
  MbAutoCfg* = object
    active*: bool
    seconds*: float64
    screenshot*: string

var
  statsPath: string
  autoCfg: MbAutoCfg
  startNs: int64
  lastFrameNs: int64
  lastStatsNs: int64
  lastFpsNs: int64
  frameMs: seq[float64]
  framesThisSecond: int
  fpsLastSecond: float64
  autoFinished: bool
  autoSuccess: bool

const
  FrameWindow = 600
  StatsPeriodNs = 2_000_000_000'i64
  FpsPeriodNs = 1_000_000_000'i64

proc nowNs(): int64 =
  getMonoTime().ticks

proc percentile(sorted: seq[float64]; p: float64): float64 =
  if sorted.len == 0:
    return 0.0
  let idx = clamp(int(p * float64(sorted.len - 1)), 0, sorted.len - 1)
  sorted[idx]

proc mbDebugInit*() =
  ## Read MAP_BROWSER_STATS / MAP_BROWSER_AUTO once at startup.
  startNs = nowNs()
  lastFpsNs = startNs
  lastStatsNs = startNs
  statsPath = getEnv("MAP_BROWSER_STATS").strip()
  let auto = getEnv("MAP_BROWSER_AUTO").strip()
  if auto.len > 0:
    autoCfg.active = true
    autoCfg.seconds = 8.0
    for part in auto.split(','):
      let kv = part.split('=', maxsplit = 1)
      if kv.len != 2:
        continue
      case kv[0].strip().toLowerAscii()
      of "seconds":
        try:
          autoCfg.seconds = parseFloat(kv[1].strip())
        except ValueError:
          discard
      of "screenshot":
        autoCfg.screenshot = kv[1].strip()
      else:
        discard
    if statsPath.len == 0:
      statsPath = "local_data" / "map_browser_stats.json"
    echo "map_browser: autopilot seconds=", autoCfg.seconds,
      " screenshot=", autoCfg.screenshot

proc mbAuto*(): MbAutoCfg =
  ## Current autopilot config (empty when inactive).
  autoCfg

proc mbStatsJson*(): JsonNode =
  ## Snapshot of viewer stats for agents (overlay counts stay 0 until T4).
  var sorted = frameMs
  sorted.sort()
  let g = currentGpu()
  result = %*{
    "ts": epochTime(),
    "uptime_s": float64(nowNs() - startNs) / 1e9,
    "fps": fpsLastSecond,
    "frame_ms_p50": percentile(sorted, 0.50),
    "frame_ms_p95": percentile(sorted, 0.95),
    "continent": currentContinentName(),
    "map_id": terrainGpu.currentMapId.int,
    "cam": {
      "x": birdCam.targetX,
      "y": birdCam.targetY,
      "height": birdCam.height,
      "yaw": birdCam.yaw,
      "pitch": birdCam.pitch
    },
    "tile_count": g.tileCount,
    "vertex_count": g.vertexCount,
    "overlays": {
      "waypoints": 0,
      "taxi": 0,
      "runs": 0,
      "labels": 0
    }
  }

proc mbStatsWrite*(final = false) =
  ## Rewrite MAP_BROWSER_STATS path when configured.
  if statsPath.len == 0:
    return
  try:
    createDir(statsPath.parentDir())
    writeFile(statsPath, mbStatsJson().pretty())
  except CatchableError as err:
    if final:
      echo "map_browser: stats write failed: ", err.msg

proc mbDebugFrame*() =
  ## Per-frame timing + periodic stats rewrite.
  let now = nowNs()
  if lastFrameNs > 0:
    let ms = float64(now - lastFrameNs) / 1e6
    frameMs.add ms
    if frameMs.len > FrameWindow:
      frameMs.delete(0)
  lastFrameNs = now
  inc framesThisSecond

  if now - lastFpsNs >= FpsPeriodNs:
    fpsLastSecond =
      float64(framesThisSecond) * 1e9 / float64(max(now - lastFpsNs, 1))
    lastFpsNs = now
    framesThisSecond = 0

  if statsPath.len > 0 and now - lastStatsNs >= StatsPeriodNs:
    lastStatsNs = now
    mbStatsWrite()

proc mbUptimeS*(): float64 =
  ## Seconds since mbDebugInit.
  float64(nowNs() - startNs) / 1e9

proc mbAutoDue*(): bool =
  ## True when autopilot has streamed long enough to finish.
  autoCfg.active and not autoFinished and mbUptimeS() >= autoCfg.seconds

proc mbAutoMarkDone*(success: bool) =
  ## Record autopilot verdict after screenshot / failure.
  autoFinished = true
  autoSuccess = success

proc mbExitCode*(): int =
  ## Nonzero when autopilot ran and failed.
  if autoCfg.active and not autoSuccess: 1 else: 0
