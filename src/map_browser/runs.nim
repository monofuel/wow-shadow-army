## Traverse run trajectories for the map browser.
##
## Trajectories come from godview JSONL captures written by the game server at
## 2 Hz under ~/.coworld/player/launcher_units/runtime/<unit>/leagues/
## traverse/captures/. Files run 2-24 MB, so parsing happens on a background
## thread and points are decimated before plotting. Beat/checkpoint overlays
## come from the repo's traverse configs.

import
  std/[algorithm, json, monotimes, os, times]

const
  TraverseStartX* = -9187.0'f32
  TraverseGoalX* = 6687.333052'f32
  TraversePlayerName* = "Northbound"
  RunMaxPoints = 2000
  RunMinSpacingYards = 5.0'f32

type
  RunListing* = object
    path*: string
    fileName*: string
    sizeBytes*: int64
    mtimeEpoch*: float64

  RunPoint* = object
    tSec*: float64
    x*, y*, z*: float32

  TraverseRun* = object
    ok*: bool
    path*: string
    fileName*: string
    error*: string
    mapId*: uint32
    frameCount*: int
    durationSec*: float64
    maxNorthing*: float32
    points*: seq[RunPoint]
    elapsedMs*: float64

  TraverseBeat* = object
    id*: string
    mapId*: uint32
    x*, y*, z*: float32
    radius*: float32

  TraverseCheckpoint* = object
    name*: string
    mapId*: uint32
    x*, y*, z*: float32

proc capturesRoot(): string =
  getHomeDir() / ".coworld" / "player" / "launcher_units" / "runtime"

proc listTraverseRuns*(): seq[RunListing] =
  ## Newest-first godview captures across all launcher units.
  let root = capturesRoot()
  if not dirExists(root):
    return
  for unitDir in walkDirs(root / "*"):
    let capturesDir = unitDir / "leagues" / "traverse" / "captures"
    if not dirExists(capturesDir):
      continue
    for path in walkFiles(capturesDir / "godview_*.jsonl"):
      var listing = RunListing(path: path, fileName: path.extractFilename())
      try:
        listing.sizeBytes = getFileSize(path)
        listing.mtimeEpoch = getLastModificationTime(path).toUnixFloat()
      except CatchableError:
        discard
      result.add listing
  result.sort(
    proc(a, b: RunListing): int =
      cmp(b.mtimeEpoch, a.mtimeEpoch)
  )

proc northingYards*(x: float32): float32 =
  max(0.0'f32, min(x, TraverseGoalX) - TraverseStartX)

proc decimate(points: seq[RunPoint]): seq[RunPoint] =
  if points.len == 0:
    return
  result.add points[0]
  for i in 1 ..< points.len - 1:
    let last = result[^1]
    let dx = points[i].x - last.x
    let dy = points[i].y - last.y
    if dx * dx + dy * dy >= RunMinSpacingYards * RunMinSpacingYards:
      result.add points[i]
  if points.len > 1:
    result.add points[^1]
  if result.len > RunMaxPoints:
    var strided: seq[RunPoint]
    let stride = (result.len + RunMaxPoints - 1) div RunMaxPoints
    for i in countup(0, result.len - 1, stride):
      strided.add result[i]
    if strided[^1].tSec != result[^1].tSec:
      strided.add result[^1]
    result = strided

proc parseTraverseRun*(path: string): TraverseRun =
  ## Full-file godview parse; call off the render thread for real captures.
  result = TraverseRun(path: path, fileName: path.extractFilename())
  let startNs = getMonoTime().ticks
  var
    raw: seq[RunPoint]
    firstT = 0.0
  try:
    for line in lines(path):
      if line.len == 0:
        continue
      var frame: JsonNode
      try:
        frame = parseJson(line)
      except CatchableError:
        continue
      if frame.kind != JObject or "players" notin frame:
        continue
      let t = frame{"t"}.getFloat() / 1000.0
      if raw.len == 0:
        firstT = t
        result.mapId = uint32(frame{"map"}.getInt())
      for player in frame["players"]:
        if player{"name"}.getStr() != TraversePlayerName:
          continue
        raw.add RunPoint(
          tSec: t - firstT,
          x: player{"x"}.getFloat().float32,
          y: player{"y"}.getFloat().float32,
          z: player{"z"}.getFloat().float32
        )
        break
    result.frameCount = raw.len
    if raw.len > 0:
      result.durationSec = raw[^1].tSec
      for point in raw:
        result.maxNorthing = max(result.maxNorthing, northingYards(point.x))
    result.points = decimate(raw)
    result.ok = raw.len > 0
    if not result.ok:
      result.error = "no frames for player " & TraversePlayerName
  except CatchableError as err:
    result.error = err.msg
  result.elapsedMs = float64(getMonoTime().ticks - startNs) / 1e6

var
  runThread: Thread[string]
  runChan: Channel[TraverseRun]
  runChanOpen = false
  runLoading = ""

proc runWorker(path: string) {.thread.} =
  runChan.send(parseTraverseRun(path))

proc runLoadBusy*(): string =
  runLoading

proc requestRunLoad*(path: string): bool =
  if runLoading.len > 0:
    return false
  if not runChanOpen:
    runChan.open()
    runChanOpen = true
  runLoading = path
  createThread(runThread, runWorker, path)
  true

proc pollRunLoad*(): tuple[has: bool, run: TraverseRun] =
  if not runChanOpen:
    return
  let tried = runChan.tryRecv()
  if not tried.dataAvailable:
    return
  joinThread(runThread)
  runLoading = ""
  (true, tried.msg)

proc loadTraverseBeats*(repoDir: string): seq[TraverseBeat] =
  let path = repoDir / "lua" / "config" / "traverse_beats.json"
  if not fileExists(path):
    return
  try:
    let root = parseJson(readFile(path))
    let mapId = uint32(root{"map_id"}.getInt(1))
    for beat in root{"beats"}:
      result.add TraverseBeat(
        id: beat{"id"}.getStr(),
        mapId: mapId,
        x: beat{"x"}.getFloat().float32,
        y: beat{"y"}.getFloat().float32,
        z: beat{"z"}.getFloat().float32,
        radius: beat{"radius"}.getFloat().float32
      )
  except CatchableError as err:
    echo "map_browser: beats load failed: ", err.msg

proc loadTraverseCheckpoints*(repoDir: string): seq[TraverseCheckpoint] =
  let path = repoDir / "tools" / "traverse_checkpoints.json"
  if not fileExists(path):
    return
  try:
    let root = parseJson(readFile(path))
    for name, checkpoint in root:
      result.add TraverseCheckpoint(
        name: name,
        mapId: uint32(checkpoint{"map_id"}.getInt()),
        x: checkpoint{"x"}.getFloat().float32,
        y: checkpoint{"y"}.getFloat().float32,
        z: checkpoint{"z"}.getFloat().float32
      )
  except CatchableError as err:
    echo "map_browser: checkpoints load failed: ", err.msg
