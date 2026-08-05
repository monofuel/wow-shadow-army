## Local admin surface for army_host: HTTP + WebSocket on 127.0.0.1.
## Live status/log, hold/resume decide, lua reload ack (disk is already
## re-read every frame via lua5.3 subprocess — reload validates + bumps gen).

import
  std/[
    json, locks, os, osproc, strformat, strutils, tables, times
  ],
  mummy, mummy/routers,
  webby/httpheaders as mummyheaders

const
  DefaultDebugPort* = 7788
  RingCap* = 400
  StatusPushIntervalSec* = 1.0

type
  LogLevel* = enum
    llDebug, llInfo, llWarn, llError

  DebugLogEntry* = object
    t*: float
    level*: string
    src*: string
    msg*: string

  DebugSelf* = object
    x*, y*, z*: float
    mapId*: int
    hpPct*: float
    formId*: int
    formSpellId*: int
    isSwimming*: bool
    hasPos*: bool

  DebugIntent* = object
    kind*, reason*: string
    spell*: int
    x*, y*, z*: float
    hasXy*: bool

  DebugState* = object
    startedAt*: float
    mode*, tool*, character*: string
    slot*: int
    transport*: string  ## "ws" | "direct"
    connected*: bool
    pathYards*: float
    acceptedMoves*: int
    goalX*, goalY*, goalRadius*, goalDist*: float
    hasGoal*: bool
    frameId*: int
    pendingAction*: bool
    actionState*: string
    held*: bool
    selfUnit*: DebugSelf
    lastIntent*: DebugIntent
    luaGen*: int
    luaEntry*: string
    luaLastError*: string
    luaRepo*: string

  WsClient* = object
    ws*: WebSocket
    wantStatus*: bool
    wantLog*: bool
    authed*: bool

var
  gLock: Lock
  gState: DebugState
  gRing: seq[DebugLogEntry]
  gRingStart: int
  gRingLen: int
  gToken: string
  gServer: Server
  gServeThread: Thread[void]
  gRunning: bool
  gWsClients: seq[WsClient]
  gWsLock: Lock
  gLastStatusPush: float
  gLastStatusSig: string

proc initArmyDebugGlobals() =
  initLock(gLock)
  initLock(gWsLock)
  gRing = newSeq[DebugLogEntry](RingCap)
  gRingStart = 0
  gRingLen = 0
  gState.startedAt = epochTime()
  gState.luaGen = 1

initArmyDebugGlobals()

proc jsonHeaders(): mummyheaders.HttpHeaders =
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = "application/json"

proc levelStr(level: LogLevel): string =
  case level
  of llDebug: "debug"
  of llInfo: "info"
  of llWarn: "warn"
  of llError: "error"

proc pushLog*(level: LogLevel; src, msg: string) =
  ## Append to ring (and optionally mirror later). Thread-safe.
  let e = DebugLogEntry(
    t: epochTime(), level: levelStr(level), src: src, msg: msg)
  withLock gLock:
    if gRingLen < RingCap:
      gRing[(gRingStart + gRingLen) mod RingCap] = e
      inc gRingLen
    else:
      gRing[gRingStart] = e
      gRingStart = (gRingStart + 1) mod RingCap
  # Fan-out to WS log subscribers (best-effort).
  let payload = $(%*{
    "op": "log",
    "data": {
      "t": e.t,
      "level": e.level,
      "src": e.src,
      "msg": e.msg
    }
  })
  withLock gWsLock:
    for c in gWsClients.mitems:
      if c.wantLog and c.authed:
        try:
          c.ws.send(payload)
        except CatchableError:
          discard

proc setHeld*(v: bool) =
  withLock gLock:
    gState.held = v
  pushLog(llInfo, "admin", if v: "held" else: "resumed")

proc isHeld*(): bool =
  withLock gLock:
    result = gState.held

proc luaGen*(): int =
  withLock gLock:
    result = gState.luaGen

proc configureMeta*(
    mode, tool, character, transport: string; slot: int; repo: string) =
  withLock gLock:
    gState.mode = mode
    gState.tool = tool
    gState.character = character
    gState.transport = transport
    gState.slot = slot
    gState.luaRepo = repo
    if mode.len > 0:
      gState.luaEntry = mode
    else:
      gState.luaEntry = tool

proc updateSession*(connected: bool) =
  withLock gLock:
    gState.connected = connected

proc updateLoop*(
    self: DebugSelf;
    intent: DebugIntent;
    pathYards: float;
    acceptedMoves: int;
    goalX, goalY, goalRadius, goalDist: float;
    hasGoal: bool;
    frameId: int;
    pending: bool;
    actionState: string) =
  withLock gLock:
    gState.selfUnit = self
    gState.lastIntent = intent
    gState.pathYards = pathYards
    gState.acceptedMoves = acceptedMoves
    gState.goalX = goalX
    gState.goalY = goalY
    gState.goalRadius = goalRadius
    gState.goalDist = goalDist
    gState.hasGoal = hasGoal
    gState.frameId = frameId
    gState.pendingAction = pending
    gState.actionState = actionState

proc ringSnapshot(n: int; srcFilter = ""): seq[DebugLogEntry] =
  result = @[]
  withLock gLock:
    let take = min(n, gRingLen)
    let start = gRingLen - take
    for i in 0 ..< take:
      let e = gRing[(gRingStart + start + i) mod RingCap]
      if srcFilter.len > 0 and e.src != srcFilter:
        continue
      result.add e

proc luaFileMtimes(repo, entry: string): JsonNode =
  result = newJArray()
  let candidates = @[
    repo / "lua" / "entry" / (entry & ".lua"),
    repo / "lua" / "tools" / (entry & ".lua"),
    repo / "lua" / "tools" / "move_to.lua",
    repo / "lua" / "tools" / "registry.lua"
  ]
  var seen: seq[string] = @[]
  for p in candidates:
    if p in seen: continue
    seen.add p
    if fileExists(p):
      try:
        result.add %*{"path": p, "mtime": getLastModificationTime(p).toUnix}
      except CatchableError:
        result.add %*{"path": p, "mtime": 0}

proc statusJson*(): JsonNode =
  withLock gLock:
    let up = epochTime() - gState.startedAt
    let entry = gState.luaEntry
    let repo = gState.luaRepo
    var goalNode = newJNull()
    if gState.hasGoal:
      goalNode = %*{
        "x": gState.goalX,
        "y": gState.goalY,
        "radius": gState.goalRadius,
        "dist": gState.goalDist
      }
    var selfNode = newJObject()
    if gState.selfUnit.hasPos:
      selfNode = %*{
        "x": gState.selfUnit.x,
        "y": gState.selfUnit.y,
        "z": gState.selfUnit.z,
        "map_id": gState.selfUnit.mapId,
        "hp_pct": gState.selfUnit.hpPct,
        "shapeshift_form_id": gState.selfUnit.formId,
        "shapeshift_form_spell_id": gState.selfUnit.formSpellId,
        "is_swimming": gState.selfUnit.isSwimming
      }
    var intentNode = %*{
      "kind": gState.lastIntent.kind,
      "reason": gState.lastIntent.reason
    }
    if gState.lastIntent.spell > 0:
      intentNode["spell"] = %gState.lastIntent.spell
    if gState.lastIntent.hasXy:
      intentNode["x"] = %gState.lastIntent.x
      intentNode["y"] = %gState.lastIntent.y
      intentNode["z"] = %gState.lastIntent.z
    let errNode =
      if gState.luaLastError.len > 0: %gState.luaLastError
      else: newJNull()
    result = %*{
      "ok": true,
      "pid": getCurrentProcessId(),
      "mode": gState.mode,
      "tool": gState.tool,
      "character": gState.character,
      "uptime_s": up,
      "lua": {
        "entry": entry,
        "gen": gState.luaGen,
        "last_error": errNode,
        "files": luaFileMtimes(repo, entry)
      },
      "session": {
        "connected": gState.connected,
        "slot": gState.slot,
        "transport": gState.transport
      },
      "self": selfNode,
      "goal": goalNode,
      "progress": {
        "path_yards": gState.pathYards,
        "accepted_moves": gState.acceptedMoves
      },
      "control": {
        "held": gState.held,
        "pending_action": gState.pendingAction,
        "action_state": gState.actionState,
        "frame_id": gState.frameId
      },
      "last_intent": intentNode
    }

proc statusSig(st: JsonNode): string =
  ## Compact change detector for WS push.
  let li = st{"last_intent"}
  let su = st{"self"}
  let ctl = st{"control"}
  let lua = st{"lua"}
  result = li{"reason"}.getStr & "|" & li{"kind"}.getStr & "|" &
    $su{"shapeshift_form_id"}.getInt & "|" & $su{"is_swimming"}.getBool & "|" &
    $ctl{"held"}.getBool & "|" & $lua{"gen"}.getInt & "|" &
    $ctl{"pending_action"}.getBool

proc authorized(request: Request): bool =
  if gToken.len == 0:
    return true
  let h = request.headers["Authorization"]
  if h.startsWith("Bearer ") and h[7 .. ^1] == gToken:
    return true
  let q = request.uri.find('?')
  if q >= 0:
    let query = request.uri[q+1 .. ^1]
    for part in query.split('&'):
      let kv = part.split('=', 1)
      if kv.len == 2 and kv[0] == "token" and kv[1] == gToken:
        return true
  false

proc respondJson(request: Request; code: int; node: JsonNode) =
  request.respond(code, jsonHeaders(), $node)

proc dryRunLuaLoad*(repo, entry: string; isMode: bool): tuple[ok: bool, detail: string] =
  ## Validate entry/tool can require without running decide.
  let packagePath =
    if isMode:
      repo & "/lua/?.lua;" & repo & "/lua/entry/?.lua;" & repo &
        "/lua/tools/?.lua;;"
    else:
      repo & "/lua/?.lua;" & repo & "/lua/tools/?.lua;;"
  let script =
    if isMode:
      "package.path = [[" & packagePath & "]]\n" &
      "local e = require(\"" & entry & "\")\n" &
      "assert(type(e.decide)==\"function\")\n" &
      "print(\"ok\")\n"
    else:
      "package.path = [[" & packagePath & "]]\n" &
      "local registry = require(\"registry\")\n" &
      "require(\"" & entry & "\")\n" &
      "local t = registry.get(\"" & entry & "\")\n" &
      "assert(t ~= nil and type(t.decide)==\"function\")\n" &
      "print(\"ok\")\n"
  let tmp = getTempDir() / ("army_reload_" & $getCurrentProcessId() & ".lua")
  try:
    writeFile(tmp, script)
  except CatchableError as e:
    return (false, e.msg)
  var bin = findExe("lua5.3")
  if bin.len == 0:
    bin = findExe("lua")
  if bin.len == 0:
    let (nixOut, nixCode) = execCmdEx(
      "nix shell nixpkgs#lua5_3 --command which lua"
    )
    if nixCode == 0:
      bin = nixOut.strip().splitLines()[^1].strip()
  if bin.len == 0:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return (false, "lua5.3/lua not found")
  let (outp, code) = execCmdEx(bin & " " & quoteShell(tmp))
  try:
    removeFile(tmp)
  except CatchableError:
    discard
  if code != 0:
    return (false, outp.strip())
  (true, "reloaded")

proc doReload*(): JsonNode =
  var repo, entry: string
  var isMode: bool
  withLock gLock:
    repo = gState.luaRepo
    entry = gState.luaEntry
    isMode = gState.mode.len > 0
  if entry.len == 0:
    return %*{"ok": false, "error": "lua_load_failed", "detail": "no entry"}
  let (ok, detail) = dryRunLuaLoad(repo, entry, isMode)
  if ok:
    var gen = 0
    withLock gLock:
      inc gState.luaGen
      gState.luaLastError = ""
      gen = gState.luaGen
    pushLog(llInfo, "admin", &"lua reload ok gen={gen} entry={entry}")
    return %*{"ok": true, "lua_gen": gen, "entry": entry, "detail": detail}
  else:
    withLock gLock:
      gState.luaLastError = detail
    pushLog(llError, "admin", &"lua reload failed: {detail}")
    var gen = 0
    withLock gLock:
      gen = gState.luaGen
    return %*{
      "ok": false,
      "error": "lua_load_failed",
      "detail": detail,
      "lua_gen": gen
    }

proc doDump*(): JsonNode =
  let st = statusJson()
  let dir = getCurrentDir() / "local_data" / "army-debug"
  try:
    createDir(dir)
  except CatchableError as e:
    return %*{"ok": false, "error": "dump_failed", "detail": e.msg}
  let path = dir / (&"snapshot-{getTime().toUnix}.json")
  try:
    writeFile(path, pretty(st))
  except CatchableError as e:
    return %*{"ok": false, "error": "dump_failed", "detail": e.msg}
  pushLog(llInfo, "admin", &"dump {path}")
  %*{"ok": true, "path": path}

proc handleHttp(request: Request) {.gcsafe.} =
  {.cast(gcsafe).}:
    if not authorized(request):
      respondJson(request, 401, %*{"ok": false, "error": "unauthorized"})
      return
    let path =
      if '?' in request.uri: request.uri.split('?', 1)[0]
      else: request.uri
    let verb = request.httpMethod
    try:
      if verb == "GET" and path == "/healthz":
        respondJson(request, 200,
          %*{"ok": true, "service": "army_host_debug"})
      elif verb == "GET" and path == "/status":
        respondJson(request, 200, statusJson())
      elif verb == "GET" and path == "/log":
        var n = 50
        var src = ""
        if '?' in request.uri:
          for part in request.uri.split('?', 1)[1].split('&'):
            let kv = part.split('=', 1)
            if kv.len != 2: continue
            if kv[0] == "n":
              try: n = parseInt(kv[1])
              except CatchableError: discard
            elif kv[0] == "src":
              src = kv[1]
        n = max(1, min(n, 500))
        let entries = ringSnapshot(n, src)
        var arr = newJArray()
        for e in entries:
          arr.add %*{"t": e.t, "level": e.level, "src": e.src, "msg": e.msg}
        respondJson(request, 200, %*{"ok": true, "entries": arr})
      elif verb == "POST" and path == "/hold":
        setHeld(true)
        respondJson(request, 200, %*{"ok": true, "detail": "held"})
      elif verb == "POST" and path == "/resume":
        setHeld(false)
        respondJson(request, 200, %*{"ok": true, "detail": "resumed"})
      elif verb == "POST" and path == "/lua/reload":
        respondJson(request, 200, doReload())
      elif verb == "POST" and path == "/dump":
        respondJson(request, 200, doDump())
      elif verb == "GET" and path == "/ws":
        try:
          discard request.upgradeToWebSocket()
        except CatchableError as e:
          respondJson(request, 400,
            %*{"ok": false, "error": "upgrade_failed", "detail": e.msg})
      else:
        respondJson(request, 404, %*{"ok": false, "error": "unknown_op"})
    except CatchableError as e:
      respondJson(request, 500,
        %*{"ok": false, "error": "internal", "detail": e.msg})

proc broadcastStatusIfNeeded*() =
  ## Call from main loop occasionally to push status to WS subscribers.
  let now = epochTime()
  let st = statusJson()
  let sig = statusSig(st)
  var should = false
  if now - gLastStatusPush >= StatusPushIntervalSec:
    should = true
  if sig != gLastStatusSig:
    should = true
  if not should:
    return
  gLastStatusPush = now
  gLastStatusSig = sig
  let payload = $(%*{"op": "status", "data": st})
  withLock gWsLock:
    for c in gWsClients.mitems:
      if c.wantStatus and c.authed:
        try:
          c.ws.send(payload)
        except CatchableError:
          discard

proc wsHandlerBody(
    websocket: WebSocket;
    event: WebSocketEvent;
    message: Message
)

proc wsHandler(
    websocket: WebSocket;
    event: WebSocketEvent;
    message: Message
) {.gcsafe.} =
  {.cast(gcsafe).}:
    wsHandlerBody(websocket, event, message)

proc wsHandlerBody(
    websocket: WebSocket;
    event: WebSocketEvent;
    message: Message
) =
  case event
  of OpenEvent:
    let authed = gToken.len == 0
    withLock gWsLock:
      gWsClients.add WsClient(
        ws: websocket, wantStatus: false, wantLog: false, authed: authed)
    var gen = 0
    withLock gLock:
      gen = gState.luaGen
    try:
      websocket.send($(%*{
        "op": "hello",
        "pid": getCurrentProcessId(),
        "lua_gen": gen,
        "auth_required": gToken.len > 0
      }))
    except CatchableError:
      discard
  of MessageEvent:
    if message.kind != TextMessage:
      return
    var node: JsonNode
    try:
      node = parseJson(message.data)
    except CatchableError:
      try:
        websocket.send($(%*{
          "op": "error", "error": "unknown_op", "detail": "invalid json"
        }))
      except CatchableError:
        discard
      return
    let op = node{"op"}.getStr
    # Find client
    var idx = -1
    withLock gWsLock:
      for i, c in gWsClients:
        if c.ws == websocket:
          idx = i
          break
    if idx < 0:
      return
    proc needAuth(): bool =
      withLock gWsLock:
        result = not gWsClients[idx].authed
    if op == "auth":
      let tok = node{"token"}.getStr
      let ok = gToken.len == 0 or tok == gToken
      withLock gWsLock:
        if idx >= 0 and idx < gWsClients.len:
          gWsClients[idx].authed = ok
      try:
        if ok:
          websocket.send($(%*{"op": "result", "ok": true, "detail": "authed"}))
        else:
          websocket.send($(%*{
            "op": "error", "error": "unauthorized"
          }))
      except CatchableError:
        discard
      return
    if gToken.len > 0 and needAuth():
      try:
        websocket.send($(%*{"op": "error", "error": "unauthorized"}))
      except CatchableError:
        discard
      return
    case op
    of "ping":
      try: websocket.send($(%*{"op": "pong"}))
      except CatchableError: discard
    of "status":
      try:
        websocket.send($(%*{"op": "status", "data": statusJson()}))
      except CatchableError: discard
    of "subscribe":
      let topics = node{"topics"}
      withLock gWsLock:
        if idx >= 0 and idx < gWsClients.len:
          if topics != nil and topics.kind == JArray:
            for t in topics:
              case t.getStr
              of "status": gWsClients[idx].wantStatus = true
              of "log": gWsClients[idx].wantLog = true
              else: discard
      try:
        websocket.send($(%*{"op": "result", "ok": true, "detail": "subscribed"}))
      except CatchableError: discard
      # Immediate status if subscribed
      withLock gWsLock:
        if idx >= 0 and idx < gWsClients.len and gWsClients[idx].wantStatus:
          try:
            websocket.send($(%*{"op": "status", "data": statusJson()}))
          except CatchableError: discard
    of "unsubscribe":
      let topics = node{"topics"}
      withLock gWsLock:
        if idx >= 0 and idx < gWsClients.len:
          if topics != nil and topics.kind == JArray:
            for t in topics:
              case t.getStr
              of "status": gWsClients[idx].wantStatus = false
              of "log": gWsClients[idx].wantLog = false
              else: discard
      try:
        websocket.send($(%*{"op": "result", "ok": true, "detail": "unsubscribed"}))
      except CatchableError: discard
    of "hold":
      setHeld(true)
      try:
        websocket.send($(%*{"op": "result", "ok": true, "detail": "held"}))
      except CatchableError: discard
    of "resume":
      setHeld(false)
      try:
        websocket.send($(%*{"op": "result", "ok": true, "detail": "resumed"}))
      except CatchableError: discard
    of "lua.reload":
      let r = doReload()
      try:
        websocket.send($(%*{
          "op": "event",
          "type": "reload",
          "data": r
        }))
        websocket.send($(%*{
          "op": "result",
          "ok": r{"ok"}.getBool,
          "data": r
        }))
      except CatchableError: discard
    else:
      try:
        websocket.send($(%*{
          "op": "error", "error": "unknown_op", "detail": op
        }))
      except CatchableError: discard
  of ErrorEvent, CloseEvent:
    withLock gWsLock:
      var next: seq[WsClient] = @[]
      for c in gWsClients:
        if c.ws != websocket:
          next.add c
      gWsClients = next

var gServePort: int

proc serveThreadPort() {.thread.} =
  try:
    gServer.serve(Port(gServePort), "127.0.0.1")
  except CatchableError as e:
    echo "[army_debug] serve failed: ", e.msg

proc startDebugServer*(port: int; token = ""): bool =
  ## Start mummy HTTP+WS admin on 127.0.0.1:port. Returns false if already running or port<=0.
  if port <= 0:
    return false
  if gRunning:
    return true
  gToken = token
  gServePort = port
  var router: Router
  router.get("/healthz", handleHttp)
  router.get("/status", handleHttp)
  router.get("/log", handleHttp)
  router.get("/ws", handleHttp)
  router.post("/hold", handleHttp)
  router.post("/resume", handleHttp)
  router.post("/lua/reload", handleHttp)
  router.post("/dump", handleHttp)
  try:
    gServer = newServer(router, wsHandler, workerThreads = 2)
    createThread(gServeThread, serveThreadPort)
    gRunning = true
    pushLog(llInfo, "admin", &"debug server 127.0.0.1:{port}")
    echo &"[army_host] debug admin http://127.0.0.1:{port}/  ws://127.0.0.1:{port}/ws"
    result = true
  except CatchableError as e:
    echo "[army_host] debug server failed: ", e.msg
    result = false

# Pure helpers for unit tests (no server).
proc ringPushForTest*(src, msg: string) =
  pushLog(llInfo, src, msg)

proc ringLenForTest*(): int =
  withLock gLock:
    result = gRingLen

proc resetDebugStateForTest*() =
  withLock gLock:
    gRingStart = 0
    gRingLen = 0
    gState = DebugState(startedAt: epochTime(), luaGen: 1)
  withLock gWsLock:
    gWsClients = @[]
