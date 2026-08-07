## Local file-backed HTTP/WebSocket admin for embedded Petrel.
## The player owns capture at simulation cadence; this process only serves
## durable artifacts and writes atomic control requests.

import
  std/[algorithm, json, locks, os, osproc, parseopt, sequtils, sha1,
       strformat, strutils, times, uri],
  mummy, mummy/routers,
  webby/httpheaders as mummyheaders

const
  DefaultPort = 7788
  ServiceName = "petrel_debug"

type
  Config = object
    runDir, repo, fork, token, checkpoint, presentation: string
    port, simulationScale: int
  WsClient = object
    socket: WebSocket
    authed, status, anomaly: bool

var
  cfg: Config
  server: Server
  watchThread: Thread[void]
  wsLock: Lock
  wsClients: seq[WsClient]
  commandCounter: int

proc jsonHeaders(contentType = "application/json"): mummyheaders.HttpHeaders =
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = contentType

proc atomicWrite(path, body: string) =
  createDir(path.parentDir)
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  writeFile(tmp, body)
  moveFile(tmp, path)

proc gitValue(repo: string; args: seq[string]): string =
  if repo.len == 0 or not dirExists(repo): return ""
  try:
    result = execProcess("git", args = @["-C", repo] & args,
      options = {poUsePath, poStdErrToStdOut}).strip()
  except CatchableError:
    discard

proc fileHash(path: string): string =
  if not fileExists(path): return ""
  try: result = $secureHashFile(path)
  except CatchableError: discard

proc writeManifest() =
  let path = cfg.runDir / "manifest.json"
  if fileExists(path): return
  let rootStatus = gitValue(cfg.repo, @["status", "--porcelain"])
  let forkStatus = gitValue(cfg.fork, @["status", "--porcelain"])
  let pinPath = cfg.repo / "upstream.lock"
  atomicWrite(path, pretty(%*{
    "protocol": "wow_shadow_army.petrel_debug_manifest.v1",
    "run_id": cfg.runDir.extractFilename,
    "started_at_unix_seconds": epochTime(),
    "started_at_utc": getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "checkpoint": cfg.checkpoint,
    "presentation": cfg.presentation,
    "simulation_scale": cfg.simulationScale,
    "shadow_army": {
      "path": cfg.repo,
      "revision": gitValue(cfg.repo, @["rev-parse", "HEAD"]),
      "dirty": rootStatus.len > 0
    },
    "fork": {
      "path": cfg.fork,
      "revision": gitValue(cfg.fork, @["rev-parse", "HEAD"]),
      "dirty": forkStatus.len > 0
    },
    "upstream_pin": (if fileExists(pinPath): readFile(pinPath).strip() else: ""),
    "inputs": {
      "traverse_lua_sha1": fileHash(cfg.repo / "lua/entry/traverse.lua"),
      "beats_sha1": fileHash(cfg.repo / "lua/config/traverse_beats.json"),
      "libpetrel_sha1": fileHash(cfg.repo / "tools/libpetrel.so")
    }
  }))

proc queryParams(uriText: string): JsonNode =
  result = newJObject()
  let q = uriText.find('?')
  if q < 0: return
  for part in uriText[q + 1 .. ^1].split('&'):
    let kv = part.split('=', 1)
    if kv.len == 2:
      result[kv[0]] = %decodeUrl(kv[1])

proc cleanPath(uriText: string): string =
  let q = uriText.find('?')
  if q < 0: uriText else: uriText[0 ..< q]

proc safeId(value: string): bool =
  value.len > 0 and value.len <= 160 and value.allCharsInSet(
    {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'})

proc runRoot(): string = cfg.runDir.parentDir

proc selectedRun(params: JsonNode): string =
  let id = params{"run_id"}.getStr("")
  if id.len == 0: return cfg.runDir
  if not safeId(id): return ""
  let candidate = runRoot() / id
  if dirExists(candidate): candidate else: ""

proc readJsonOr(path: string; fallback: JsonNode): JsonNode =
  try:
    if fileExists(path): return parseJson(readFile(path))
  except CatchableError:
    discard
  fallback

proc readJsonLines(path: string; limit: int; minSimulation = -1.0): JsonNode =
  result = newJArray()
  if not fileExists(path): return
  var rows: seq[JsonNode]
  try:
    for line in readFile(path).splitLines():
      if line.strip().len == 0: continue
      try:
        let row = parseJson(line)
        if minSimulation >= 0 and
            row{"simulation_time"}.getFloat(-1.0) < minSimulation:
          continue
        rows.add row
      except CatchableError:
        discard
  except CatchableError:
    return
  let first = max(0, rows.len - limit)
  for i in first ..< rows.len: result.add rows[i]

proc runList(): JsonNode =
  result = newJArray()
  if not dirExists(runRoot()): return
  var names: seq[string]
  for kind, path in walkDir(runRoot()):
    if kind == pcDir: names.add path.extractFilename
  names.sort(SortOrder.Descending)
  for name in names:
    let dir = runRoot() / name
    result.add %*{
      "run_id": name,
      "manifest": readJsonOr(dir / "manifest.json", newJObject()),
      "summary": readJsonOr(dir / "run-summary.json", newJObject())
    }

proc anomalyList(dir: string): JsonNode =
  result = newJArray()
  let root = dir / "anomalies"
  if not dirExists(root): return
  var names: seq[string]
  for kind, path in walkDir(root):
    if kind == pcDir: names.add path.extractFilename
  names.sort(SortOrder.Descending)
  for name in names:
    result.add readJsonOr(root / name / "anomaly.json", %*{"id": name})

proc anomalyBundle(dir, anomalyId: string): JsonNode =
  let root = dir / "anomalies" / anomalyId
  if not dirExists(root) or not fileExists(root / "anomaly.json"):
    return %*{"ok": false, "error": "anomaly_not_found"}
  %*{
    "ok": true,
    "anomaly": readJsonOr(root / "anomaly.json", newJObject()),
    "client_view": readJsonOr(root / "client-view.json", newJObject()),
    "timeline": readJsonLines(root / "timeline.jsonl", 5000),
    "frame_path": "/frame?run_id=" & dir.extractFilename &
      "&anomaly_id=" & anomalyId,
    "frame_available": fileExists(root / "frame.png")
  }

proc authorized(request: Request): bool =
  if cfg.token.len == 0: return true
  let h = request.headers["Authorization"]
  if h.startsWith("Bearer ") and h[7 .. ^1] == cfg.token: return true
  queryParams(request.uri){"token"}.getStr("") == cfg.token

proc respondJson(request: Request; code: int; node: JsonNode) =
  request.respond(code, jsonHeaders(), $node)

proc writeCommand(kind: string): JsonNode =
  inc commandCounter
  let id = $int64(epochTime() * 1000) & "-" & $commandCounter
  atomicWrite(cfg.runDir / "control" / "request.json", $(%*{
    "protocol": "wow_shadow_army.petrel_debug_command.v1",
    "id": id,
    "kind": kind,
    "requested_at_unix_seconds": epochTime()
  }))
  %*{"ok": true, "accepted": true, "command_id": id, "kind": kind}

proc handleHttp(request: Request) {.gcsafe.} =
  {.cast(gcsafe).}:
    if not authorized(request):
      respondJson(request, 401, %*{"ok": false, "error": "unauthorized"})
      return
    let path = cleanPath(request.uri)
    let params = queryParams(request.uri)
    let dir = selectedRun(params)
    try:
      if request.httpMethod == "GET" and path == "/healthz":
        respondJson(request, 200, %*{
          "ok": true, "service": ServiceName,
          "run_id": cfg.runDir.extractFilename
        })
      elif request.httpMethod == "GET" and path == "/status":
        if dir.len == 0:
          respondJson(request, 404, %*{"ok": false, "error": "run_not_found"})
        else:
          respondJson(request, 200,
            readJsonOr(dir / "status.json", %*{"ok": false, "state": "waiting"}))
      elif request.httpMethod == "GET" and path == "/runs":
        respondJson(request, 200, %*{"ok": true, "runs": runList()})
      elif request.httpMethod == "GET" and path in ["/timeline", "/transitions"]:
        if dir.len == 0:
          respondJson(request, 404, %*{"ok": false, "error": "run_not_found"})
        else:
          let limit = max(1, min(5000, parseInt(params{"limit"}.getStr("500"))))
          var minSim = -1.0
          let seconds = parseFloat(params{"sim_seconds"}.getStr("-1"))
          if seconds >= 0:
            let st = readJsonOr(dir / "status.json", newJObject())
            minSim = st{"simulation_time"}.getFloat(0.0) - seconds
          let fileName = if path == "/timeline": "timeline.jsonl" else: "transitions.jsonl"
          respondJson(request, 200, %*{
            "ok": true, "run_id": dir.extractFilename,
            "entries": readJsonLines(dir / fileName, limit, minSim)
          })
      elif request.httpMethod == "GET" and path in ["/anomalies", "/anomalies/latest"]:
        if dir.len == 0:
          respondJson(request, 404, %*{"ok": false, "error": "run_not_found"})
        else:
          let rows = anomalyList(dir)
          if path == "/anomalies/latest":
            respondJson(request, 200, %*{
              "ok": true,
              "bundle":
                (if rows.len > 0:
                  anomalyBundle(dir, rows[0]{"id"}.getStr(""))
                 else:
                  newJNull())
            })
          else:
            respondJson(request, 200, %*{"ok": true, "anomalies": rows})
      elif request.httpMethod == "GET" and path == "/anomaly":
        let anomalyId = params{"anomaly_id"}.getStr("")
        if dir.len == 0 or not safeId(anomalyId):
          respondJson(request, 400, %*{"ok": false, "error": "bad_artifact_id"})
        else:
          respondJson(request, 200, anomalyBundle(dir, anomalyId))
      elif request.httpMethod == "GET" and path == "/frame":
        let anomalyId = params{"anomaly_id"}.getStr("")
        let frame = if dir.len > 0 and safeId(anomalyId):
          dir / "anomalies" / anomalyId / "frame.png" else: ""
        if frame.len == 0 or not fileExists(frame):
          respondJson(request, 404, %*{"ok": false, "error": "frame_not_found"})
        else:
          request.respond(200, jsonHeaders("image/png"), readFile(frame))
      elif request.httpMethod == "GET" and path == "/command":
        let id = params{"id"}.getStr("")
        if not safeId(id):
          respondJson(request, 400, %*{"ok": false, "error": "bad_command_id"})
        else:
          respondJson(request, 200, readJsonOr(
            cfg.runDir / "control" / "acks" / (id & ".json"),
            %*{"ok": true, "pending": true, "command_id": id}))
      elif request.httpMethod == "POST" and path in
          ["/hold", "/resume", "/stop", "/dump", "/lua/reload"]:
        let kind = case path
          of "/hold": "hold"
          of "/resume": "resume"
          of "/stop": "stop"
          of "/dump": "dump"
          else: "lua_reload"
        respondJson(request, 202, writeCommand(kind))
      elif request.httpMethod == "POST" and path == "/finish":
        atomicWrite(cfg.runDir / "run-summary.json", pretty(%*{
          "protocol": "wow_shadow_army.petrel_debug_summary.v1",
          "run_id": cfg.runDir.extractFilename,
          "finished_at_unix_seconds": epochTime(),
          "exit_code": parseInt(params{"exit_code"}.getStr("0")),
          "status": readJsonOr(cfg.runDir / "status.json", newJObject()),
          "anomaly_count": anomalyList(cfg.runDir).len
        }))
        respondJson(request, 200, %*{"ok": true})
      elif request.httpMethod == "GET" and path == "/ws":
        discard request.upgradeToWebSocket()
      else:
        respondJson(request, 404, %*{"ok": false, "error": "unknown_op"})
    except CatchableError as error:
      respondJson(request, 500, %*{
        "ok": false, "error": "internal", "detail": error.msg
      })

proc wsHandler(socket: WebSocket; event: WebSocketEvent; message: Message) {.gcsafe.} =
  {.cast(gcsafe).}:
    case event
    of OpenEvent:
      withLock wsLock:
        wsClients.add WsClient(socket: socket, authed: cfg.token.len == 0)
      socket.send($(%*{"op": "hello", "auth_required": cfg.token.len > 0}))
    of MessageEvent:
      if message.kind != TextMessage: return
      let node = try: parseJson(message.data) except CatchableError: newJObject()
      let op = node{"op"}.getStr("")
      withLock wsLock:
        for client in wsClients.mitems:
          if client.socket != socket: continue
          if op == "auth": client.authed = node{"token"}.getStr("") == cfg.token
          elif client.authed and op == "subscribe":
            for topic in node{"topics"}:
              if topic.getStr == "status": client.status = true
              if topic.getStr == "anomaly": client.anomaly = true
          elif client.authed and op == "status":
            socket.send($(%*{"op": "status", "data": readJsonOr(
              cfg.runDir / "status.json", newJObject())}))
      socket.send($(%*{"op": "result", "ok": true, "detail": op}))
    of ErrorEvent, CloseEvent:
      withLock wsLock:
        wsClients = wsClients.filterIt(it.socket != socket)

proc watchLoop() {.thread.} =
  {.cast(gcsafe).}:
    var lastStatus, lastAnomaly = ""
    while true:
      sleep(100)
      let status = try: readFile(cfg.runDir / "status.json") except CatchableError: ""
      let anomalies = anomalyList(cfg.runDir)
      let anomaly = if anomalies.len > 0: $anomalies[0] else: ""
      withLock wsLock:
        for client in wsClients.mitems:
          if not client.authed: continue
          try:
            if client.status and status.len > 0 and status != lastStatus:
              client.socket.send($(%*{"op": "status", "data": parseJson(status)}))
            if client.anomaly and anomaly.len > 0 and anomaly != lastAnomaly:
              client.socket.send($(%*{"op": "anomaly", "data": parseJson(anomaly)}))
          except CatchableError:
            discard
      lastStatus = status
      lastAnomaly = anomaly

proc serve() {.thread.} =
  {.cast(gcsafe).}:
    server.serve(Port(cfg.port), "127.0.0.1")

proc parseConfig(): Config =
  result.port = DefaultPort
  result.simulationScale = 10
  for kind, key, value in getopt():
    if kind notin {cmdLongOption, cmdShortOption}: continue
    case key
    of "run-dir": result.runDir = value
    of "repo": result.repo = value
    of "fork": result.fork = value
    of "port": result.port = parseInt(value)
    of "token": result.token = value
    of "checkpoint": result.checkpoint = value
    of "presentation": result.presentation = value
    of "simulation-scale": result.simulationScale = parseInt(value)
    else: discard

proc main() =
  cfg = parseConfig()
  if cfg.runDir.len == 0: quit "--run-dir is required"
  createDir(cfg.runDir)
  createDir(cfg.runDir / "control" / "acks")
  createDir(cfg.runDir / "anomalies")
  writeManifest()
  initLock(wsLock)
  var router: Router
  for path in ["/healthz", "/status", "/runs", "/timeline", "/transitions",
      "/anomalies", "/anomalies/latest", "/anomaly", "/frame", "/command", "/ws"]:
    router.get(path, handleHttp)
  for path in ["/hold", "/resume", "/stop", "/dump", "/lua/reload", "/finish"]:
    router.post(path, handleHttp)
  server = newServer(router, wsHandler, workerThreads = 2)
  createThread(watchThread, watchLoop)
  echo &"[petrel-debug] run={cfg.runDir} http://127.0.0.1:{cfg.port}"
  serve()

when isMainModule:
  main()
