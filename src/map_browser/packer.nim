## Background mosaic packer: composes 2D world-map surfaces (BLP decode +
## pixie draw) off the render thread. The render thread polls for finished
## RGBA pixels and uploads them to the silky atlas.

import
  std/monotimes,
  pixie,
  environment/client/world_catalogs/model,
  map_browser/assets

type
  PackRequest = object
    fileName: string
    areaMapId: uint32
    overlays: seq[WorldMapOverlayInfo]

  PackResult* = object
    ok*: bool
    fileName*: string
    error*: string
    width*, height*: int
    data*: seq[ColorRGBX]
    overlayCount*: int
    elapsedMs*: float64

var
  packThread: Thread[PackRequest]
  packChan: Channel[PackResult]
  packChanOpen = false
  packRunning = false
  packRunningFile = ""
  packQueue: seq[PackRequest]

proc packWorker(req: PackRequest) {.thread.} =
  var res = PackResult(fileName: req.fileName)
  let startNs = getMonoTime().ticks
  try:
    let loaded = loadSurfaceMosaic(req.fileName, req.areaMapId, req.overlays)
    res.ok = true
    res.width = loaded.image.width
    res.height = loaded.image.height
    res.data = loaded.image.data
    res.overlayCount = loaded.roots.overlayCount
  except CatchableError as err:
    res.error = err.msg
  res.elapsedMs = float64(getMonoTime().ticks - startNs) / 1e6
  packChan.send(res)

proc startNext() =
  if packRunning or packQueue.len == 0:
    return
  let req = packQueue[0]
  packQueue.delete(0)
  packRunning = true
  packRunningFile = req.fileName
  createThread(packThread, packWorker, req)

proc packerRequest*(
  fileName: string;
  areaMapId: uint32;
  overlays: seq[WorldMapOverlayInfo]
) =
  if not packChanOpen:
    packChan.open()
    packChanOpen = true
  if packRunningFile == fileName:
    return
  for queued in packQueue:
    if queued.fileName == fileName:
      return
  packQueue.add PackRequest(
    fileName: fileName, areaMapId: areaMapId, overlays: overlays)
  startNext()

proc packerBusyFile*(): string =
  packRunningFile

proc packerPoll*(): tuple[has: bool, res: PackResult] =
  ## Non-blocking; joins the worker and starts the next queued pack.
  if not packChanOpen:
    return
  let tried = packChan.tryRecv()
  if not tried.dataAvailable:
    return
  joinThread(packThread)
  packRunning = false
  packRunningFile = ""
  startNext()
  (true, tried.msg)

proc packerImage*(res: PackResult): Image =
  result = newImage(res.width, res.height)
  result.data = res.data
