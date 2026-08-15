## Local HTTP debug admin for ONE running home lua-bot seat.
##
## Revives the surface of the deleted tools/petrel_debug_admin.nim against the
## fork's bots/lua_bot embed. Like petrel's admin, this process never touches
## the Lua VM: it writes atomic control-request files that the seat picks up
## between decide ticks, and reads the ack the seat writes back. The client
## therefore ships no listener at all — see docs/lua-debug-port.md.
##
## Bound to 127.0.0.1 and started only when the home Makefile is asked for a
## debug port. League and traverse launch paths never start it.
##
##   nim r tools/lua_debug_admin.nim -- \
##     --seat=Igris --control-dir=<seat>/control --status-dir=<seat>/status \
##     --port=7789

import
  std/[json, os, parseopt, strformat, strutils, times],
  mummy, mummy/routers,
  webby/httpheaders as mummyheaders

const
  ServiceName = "lua_debug_admin"
  ControlProtocol = "wow_shadow_army.lua_bot_control.v1"
  ## The seat polls its control file a few times a second; give a healthy seat
  ## generous room to answer while still failing fast on a stopped one.
  DefaultTimeoutMs = 3000
  MaxTimeoutMs = 30000
  ## Ack poll interval while waiting for the seat.
  AckPollMs = 25

type
  Config = object
    seat, controlDir, statusDir: string
    port: int

var
  cfg: Config
  commandCounter: int

proc jsonHeaders(): mummyheaders.HttpHeaders =
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = "application/json"

proc respondJson(request: Request; code: int; node: JsonNode) =
  request.respond(code, jsonHeaders(), $node)

proc atomicWrite(path, body: string) =
  createDir(path.parentDir)
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  writeFile(tmp, body)
  moveFile(tmp, path)
  # The seat gates its poll on mtime; make each request's stamp distinct even
  # when two land inside one filesystem timestamp tick.
  setLastModificationTime(path, getTime())

proc readJsonOr(path: string; fallback: JsonNode): JsonNode =
  try:
    if fileExists(path):
      return parseJson(readFile(path))
  except CatchableError:
    discard
  fallback

proc queryParams(uriText: string): JsonNode =
  result = newJObject()
  let q = uriText.find('?')
  if q < 0:
    return
  for part in uriText[q + 1 .. ^1].split('&'):
    let kv = part.split('=', 1)
    if kv.len == 2:
      result[kv[0]] = %kv[1]

proc timeoutMs(params: JsonNode): int =
  result = DefaultTimeoutMs
  try:
    let raw = params{"timeout_ms"}.getStr("")
    if raw.len > 0:
      result = max(100, min(MaxTimeoutMs, parseInt(raw)))
  except ValueError:
    discard

proc seatStatus(): JsonNode =
  ## The seat's own per-frame status file, when it has written one.
  readJsonOr(cfg.statusDir / "status.json", newJObject())

proc command(kind: string; waitMs: int): (int, JsonNode) =
  ## Publish one control request and wait for the seat's ack.
  inc commandCounter
  let id = $int64(epochTime() * 1000) & "-" & $commandCounter
  let ackPath = cfg.controlDir / "acks" / (id & ".json")
  try:
    atomicWrite(cfg.controlDir / "request.json", $(%*{
      "protocol": ControlProtocol,
      "id": id,
      "kind": kind,
      "requested_at_unix_seconds": epochTime()
    }))
  except CatchableError as error:
    return (500, %*{
      "ok": false, "error": "control_write_failed", "detail": error.msg
    })
  let deadline = epochTime() + waitMs.float / 1000.0
  while epochTime() < deadline:
    if fileExists(ackPath):
      let ack = readJsonOr(ackPath, newJNull())
      if ack.kind == JObject:
        var body = ack
        body["seat"] = %cfg.seat
        body["status"] = seatStatus()
        # A refused reload is a real answer about a broken edit, not a
        # transport failure: 200 with ok=false, so callers read `detail`.
        return (200, body)
    sleep(AckPollMs)
  # No ack means the seat is stopped, wedged, or was launched without
  # VANILLA_WOW_LUA_DEBUG_DIR — never that the command was rejected.
  (504, %*{
    "ok": false,
    "error": "seat_timeout",
    "detail": "no ack from " & cfg.seat & " within " & $waitMs & "ms; " &
      "the seat may be stopped or launched without a debug control dir",
    "seat": cfg.seat,
    "command_id": id,
    "kind": kind,
    "status": seatStatus()
  })

proc handle(request: Request) {.gcsafe.} =
  {.cast(gcsafe).}:
    let params = queryParams(request.uri)
    let path =
      block:
        let q = request.uri.find('?')
        if q < 0: request.uri else: request.uri[0 ..< q]
    try:
      case path
      of "/healthz":
        # Pure sidecar liveness: never touches the seat, so it stays useful
        # for telling "admin is up, seat is gone" from "admin is gone".
        respondJson(request, 200, %*{
          "ok": true,
          "service": ServiceName,
          "seat": cfg.seat,
          "port": cfg.port,
          "control_dir": cfg.controlDir,
          "control_dir_present": dirExists(cfg.controlDir),
          "status_present": fileExists(cfg.statusDir / "status.json")
        })
      of "/status":
        let (code, body) = command("status", timeoutMs(params))
        respondJson(request, code, body)
      of "/hold":
        let (code, body) = command("hold", timeoutMs(params))
        respondJson(request, code, body)
      of "/resume":
        let (code, body) = command("resume", timeoutMs(params))
        respondJson(request, code, body)
      of "/lua/reload":
        let (code, body) = command("lua_reload", timeoutMs(params))
        respondJson(request, code, body)
      else:
        respondJson(request, 404, %*{
          "ok": false,
          "error": "unknown_op",
          "detail": "known ops: GET /healthz /status, " &
            "POST /hold /resume /lua/reload"
        })
    except CatchableError as error:
      respondJson(request, 500, %*{
        "ok": false, "error": "internal", "detail": error.msg
      })

proc refuse(request: Request) {.gcsafe.} =
  ## Every answer this port gives is JSON, including its refusals — a caller
  ## scripting against it should never have to parse an HTML error page.
  ## Dispatching an unrouted method here rather than at `handle` keeps a
  ## stray `DELETE /hold` from actually holding the seat.
  respondJson(request, 404, %*{
    "ok": false,
    "error": "unknown_op",
    "detail": "known ops: GET /healthz /status, POST /hold /resume /lua/reload"
  })

proc parseConfig(): Config =
  result.port = 7788
  for kind, key, value in getopt():
    if kind notin {cmdLongOption, cmdShortOption}:
      continue
    case key
    of "seat": result.seat = value
    of "control-dir": result.controlDir = value
    of "status-dir": result.statusDir = value
    of "port": result.port = parseInt(value)
    else: discard

proc main() =
  cfg = parseConfig()
  if cfg.controlDir.len == 0:
    quit "--control-dir is required"
  if cfg.seat.len == 0:
    cfg.seat = "unknown"
  createDir(cfg.controlDir / "acks")
  var router: Router
  router.get("/healthz", handle)
  router.get("/status", handle)
  router.post("/status", handle)
  router.post("/hold", handle)
  router.post("/resume", handle)
  router.post("/lua/reload", handle)
  router.notFoundHandler = refuse
  router.methodNotAllowedHandler = refuse
  let server = newServer(router)
  echo &"[lua-debug] seat={cfg.seat} control={cfg.controlDir} " &
    &"http://127.0.0.1:{cfg.port}"
  echo &"  GET  /healthz  /status"
  echo &"  POST /hold  /resume  /lua/reload"
  server.serve(Port(cfg.port), "127.0.0.1")

when isMainModule:
  main()
