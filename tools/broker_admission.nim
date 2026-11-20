## Model admission and drain control for the private request broker.
##
## A request chain is one broker `handle` call for one addressed request:
## the Kev route POST and the Lightning decision and answer POSTs it makes,
## zero to three in order. The broker admits a chain before its first POST.
## An admitted chain always finishes its remaining POSTs; a hold only stops
## new chains from being admitted.
##
## A caller asks for a hold by writing `control.json` bound to the live
## broker instance with a fresh token. The broker answers in `status.json`:
## `draining` while an admitted chain or POST is still running, then `held`
## once both counts are zero. Only a fresh `held` status naming the caller's
## new token, written by the same live process (PID, kernel start time and
## executable hash), is a receipt. A missing, stale or foreign status is
## unknown, never zero. Holds expire on their own; release removes only the
## matching token. A broker restarted under an unexpired hold of an older
## instance admits nothing and reports `mismatch` until that hold expires or
## is released.
##
## A receipt depends only on zero admitted chains and zero active POSTs.
## Deferred chat rows and operator files are meant to survive a hold and are
## handled after it; the broker keeps no authoritative inventory of them, so
## status publishes `pendingFileRows: null` (unknown, never zero).
## `deferredByInstanceThisHold` counts only rows this broker instance
## deferred since it first saw the current hold token: a new token or a
## restarted broker starts it at zero while older rows still wait on disk.
##
## Hold requests and releases from any number of CLI processes are serialized
## by an exclusive POSIX `lockf` lock on `control.lock`. The kernel drops the
## lock when its holder exits; the empty file itself carries no state. The
## broker only reads `control.json` and never takes the lock.
##
## This receipt covers this broker only. Status proves only that it is
## self-consistent with the running process; it does not authorize that
## binary or profile. Callers compare the published `exeSha256` and full
## nonsecret `config` against the values they approved, and still validate
## their other model clients and backend state before changing models.

import
  std/[json, math, os, parseopt, posix, strutils, sysrand, times],
  crunchy

type
  GateState* = enum
    gsOpen = "open", gsDraining = "draining", gsHeld = "held",
    gsMismatch = "mismatch"

  Gate* = object
    ## Broker-side admission state. A default Gate is disabled and admits
    ## everything without writing status.
    enabled*: bool
    dir*: string
    instance*, exeSha256*, configSha256*, startTicks*: string
    pid*: int
    config*: JsonNode
    state*: GateState
    token*, foreignInstance*, note*, statusError*: string
    expiresAt*: float
    admitted*, activePosts*: int
    ## Rows this instance deferred since it first saw the current hold token;
    ## not a count of rows waiting on disk.
    deferredByInstanceThisHold*: int
    ## A written `held` status stays a valid receipt until this time, so the
    ## broker admits nothing before it unless a newer status replaced it.
    heldClaimUntil*: float

const
  AdmissionProtocol* = "wow_shadow_army.broker_admission.v1"
  AdmissionDir* = "broker-admission"
  ControlFile = "control.json"
  LockFile = "control.lock"
  StatusFile = "status.json"
  ## A receipt older than this is unknown. The broker rewrites status every
  ## poll while held, because a held broker makes no model calls.
  StatusFreshSeconds* = 10.0
  DefaultHoldSeconds* = 600.0
  MaxHoldSeconds* = 1800.0
  ## Allowed clock difference for a control's request time.
  ClockSlackSeconds = 5.0
  TokenBytes = 16
  WaitPollMs = 250
  ## Writers hold the control lock for milliseconds; a longer wait means a
  ## stuck writer, which refuses rather than blocks.
  LockWaitSeconds = 5.0
  LockPollMs = 20

proc hexOf(bytes: openArray[uint8]): string =
  ## Lowercase hex of raw bytes.
  for b in bytes: result.add b.toHex(2).toLowerAscii

proc fileSha256*(path: string): string =
  ## SHA-256 of a file's bytes; a running process's executable reads through
  ## `/proc/PID/exe` even after its path was replaced.
  hexOf(sha256(readFile(path)))

proc procStartTicks*(pid: int): string =
  ## Kernel start time of a process (field 22 of `/proc/PID/stat`); together
  ## with the PID it names one process across PID reuse. "" when not running.
  var stat = ""
  try: stat = readFile("/proc/" & $pid & "/stat")
  except CatchableError: return ""
  let close = stat.rfind(')')
  if close < 0: return ""
  let fields = stat[close + 1 .. ^1].splitWhitespace
  # Fields after the command name start at field 3 (state).
  if fields.len > 19: result = fields[19]

proc controlPath*(dir: string): string =
  ## Hold request file in the admission directory.
  dir / ControlFile

proc statusPath*(dir: string): string =
  ## Broker status file in the admission directory.
  dir / StatusFile

proc newToken*(): string =
  ## Random identifier for a broker instance or a hold.
  hexOf(urandom(TokenBytes))

proc finite(value: float): bool =
  ## Whether a number is neither NaN nor infinite.
  value.classify notin {fcNan, fcInf, fcNegInf}

proc writeAtomic(path, body: string) =
  ## Write a private same-directory temporary file, then rename it over path:
  ## a reader never sees half a file and concurrent writers never share a
  ## temporary. A failed write removes its temporary and raises.
  let tmp = path & ".tmp." & $getCurrentProcessId() & "." & newToken()
  try:
    writeFile(tmp, body)
    moveFile(tmp, path)
  except CatchableError:
    try: removeFile(tmp)
    except CatchableError: discard
    raise

proc acquireControlLock(dir: string): cint =
  ## Take the exclusive control-writer lock and return its descriptor; the
  ## lock lasts until the descriptor is closed or the process exits. Raises
  ## ValueError when another writer keeps it past LockWaitSeconds.
  result = posix.open(cstring(dir / LockFile), O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
  if result < 0:
    raiseOSError(osLastError(), "cannot open control lock")
  let deadline = epochTime() + LockWaitSeconds
  while lockf(result, F_TLOCK, 0) != 0:
    let err = errno
    if err notin [EACCES, EAGAIN, EINTR]:
      discard posix.close(result)
      raiseOSError(OSErrorCode(err), "cannot lock control")
    if epochTime() >= deadline:
      discard posix.close(result)
      raise newException(ValueError, "another control writer holds the lock")
    os.sleep(LockPollMs)

template withControlLock(dir: string; body: untyped) =
  ## Run body as the only control writer.
  let lockFd = acquireControlLock(dir)
  try:
    body
  finally:
    discard posix.close(lockFd)

proc validToken(value: string): bool =
  ## Whether a value has the shape newToken produces.
  value.len == TokenBytes * 2 and value.allCharsInSet(HexDigits)

proc parseControl*(node: JsonNode; now: float): JsonNode =
  ## A well-formed, bounded hold request, or raise ValueError naming why not.
  ## Expiry is checked by the caller: an expired hold is well-formed.
  if node.kind != JObject or node{"protocol"}.getStr != AdmissionProtocol:
    raise newException(ValueError, "control is not an admission hold")
  for key in ["token", "instance"]:
    if not validToken(node{key}.getStr):
      raise newException(ValueError, "control has no valid " & key)
  for key in ["requestedAt", "expiresAt", "pid"]:
    if node{key}.isNil or node{key}.kind notin {JInt, JFloat}:
      raise newException(ValueError, "control has no numeric " & key)
  let
    requested = node["requestedAt"].getFloat
    expires = node["expiresAt"].getFloat
  # Written as accept-if-good so NaN and infinities are rejected.
  if not (requested.finite and expires.finite and
      requested <= now + ClockSlackSeconds and expires > requested and
      expires - requested <= MaxHoldSeconds):
    raise newException(ValueError, "control hold window is out of bounds")
  node

proc openGate*(homeDir: string; config: JsonNode): Gate =
  ## Identify this broker process and enable admission control under the
  ## home directory. The instance is new on every start.
  result = Gate(enabled: true, dir: homeDir / AdmissionDir, config: config,
    instance: newToken(), pid: getCurrentProcessId(), state: gsOpen)
  result.startTicks = procStartTicks(result.pid)
  result.exeSha256 = fileSha256("/proc/self/exe")
  result.configSha256 = hexOf(sha256($config))
  createDir(result.dir)

proc statusNode*(g: Gate; now: float): JsonNode =
  ## The status record the broker publishes.
  %*{"protocol": AdmissionProtocol, "instance": g.instance, "pid": g.pid,
    "startTicks": g.startTicks, "exeSha256": g.exeSha256,
    "configSha256": g.configSha256, "config": g.config, "observedAt": now,
    "state": $g.state,
    "token": (if g.token.len > 0: %g.token else: newJNull()),
    "expiresAt": (if g.token.len > 0: %g.expiresAt else: newJNull()),
    "foreignInstance": (if g.foreignInstance.len > 0: %g.foreignInstance else: newJNull()),
    "admittedChains": g.admitted, "activePosts": g.activePosts,
    "deferredByInstanceThisHold": g.deferredByInstanceThisHold,
    "pendingFileRows": newJNull(), "note": g.note}

proc writeStatus(g: var Gate; now: float) =
  ## Publish status. A failed write never stops the broker; it removes the
  ## old file when it can, and otherwise leaves heldClaimUntil in force so a
  ## stale `held` file cannot overlap a newly admitted chain.
  try:
    writeAtomic(statusPath(g.dir), $g.statusNode(now))
    g.statusError = ""
    g.heldClaimUntil = if g.state == gsHeld:
        min(now + StatusFreshSeconds, g.expiresAt)
      else: 0.0
  except CatchableError as error:
    g.statusError = error.msg
    try:
      removeFile(statusPath(g.dir))
      if not fileExists(statusPath(g.dir)): g.heldClaimUntil = 0.0
    except CatchableError:
      discard

proc clearHold(g: var Gate) =
  ## Forget the current hold.
  g.token = ""
  g.foreignInstance = ""
  g.expiresAt = 0.0
  g.deferredByInstanceThisHold = 0

proc refresh*(g: var Gate; now = epochTime()) =
  ## Re-read the hold request, settle this broker's state and publish it.
  ## An unreadable or invalid control keeps an existing hold only until its
  ## own expiry, so a bad file can neither freeze the broker nor end a
  ## boundary early.
  if not g.enabled: return
  var control: JsonNode
  var problem = ""
  if fileExists(controlPath(g.dir)):
    try:
      control = parseControl(parseFile(controlPath(g.dir)), now)
    except CatchableError as error:
      problem = error.msg
  if not control.isNil:
    let token = control["token"].getStr
    if now >= control["expiresAt"].getFloat:
      if g.token == token or g.token.len == 0:
        g.note = "hold " & token & " expired"
      clearHold(g)
    else:
      if token != g.token: g.deferredByInstanceThisHold = 0
      g.token = token
      g.expiresAt = control["expiresAt"].getFloat
      let ours = control{"instance"}.getStr == g.instance and
        control{"pid"}.getInt == g.pid and
        control{"startTicks"}.getStr == g.startTicks and
        control{"exeSha256"}.getStr == g.exeSha256 and
        control{"configSha256"}.getStr == g.configSha256
      g.foreignInstance = if ours: "" else: control{"instance"}.getStr
      g.note = if ours: "" else: "hold names another broker instance; admitting nothing until it expires or is released"
  elif problem.len > 0:
    if g.token.len > 0 and now < g.expiresAt:
      g.note = "invalid control (" & problem & "); prior hold kept until its expiry"
    else:
      g.note = "invalid control ignored: " & problem
      clearHold(g)
  else:
    if g.token.len > 0: g.note = "hold " & g.token & " released"
    clearHold(g)
  g.state = if g.token.len == 0: gsOpen
    elif g.foreignInstance.len > 0: gsMismatch
    elif g.admitted > 0 or g.activePosts > 0: gsDraining
    else: gsHeld
  writeStatus(g, now)

proc admit*(g: var Gate; now = epochTime()): bool =
  ## Admit one new request chain, or refuse while any hold applies or a
  ## written `held` receipt could still be read as current.
  if not g.enabled: return true
  g.refresh(now)
  if g.state != gsOpen or now < g.heldClaimUntil:
    return false
  inc g.admitted
  g.refresh(now)
  true

proc finish*(g: var Gate) =
  ## End an admitted chain, whether it succeeded or raised.
  if not g.enabled: return
  g.admitted = max(0, g.admitted - 1)
  g.refresh()

proc beginPost*(g: var Gate) =
  ## Record one model POST of an admitted chain before it starts.
  if not g.enabled: return
  inc g.activePosts
  g.refresh()

proc endPost*(g: var Gate) =
  ## Record that a POST returned or failed.
  if not g.enabled: return
  g.activePosts = max(0, g.activePosts - 1)

proc readLive*(dir: string): JsonNode =
  ## The broker's status, only if it was written by the process running now
  ## under that PID with that executable and profile; otherwise raise
  ## ValueError naming why the broker is unknown.
  let path = statusPath(dir)
  if not fileExists(path):
    raise newException(ValueError, "no broker status")
  let node = try: parseFile(path)
    except CatchableError as error:
      raise newException(ValueError, "unreadable broker status: " & error.msg)
  if node.kind != JObject or node{"protocol"}.getStr != AdmissionProtocol:
    raise newException(ValueError, "status is not an admission status")
  let pid = node{"pid"}.getInt
  let ticks = procStartTicks(pid)
  if pid <= 0 or ticks.len == 0:
    raise newException(ValueError, "broker pid " & $pid & " is not running")
  if ticks != node{"startTicks"}.getStr:
    raise newException(ValueError, "pid " & $pid & " is a different process now")
  let exe = try: fileSha256("/proc/" & $pid & "/exe")
    except CatchableError as error:
      raise newException(ValueError, "cannot read broker executable: " & error.msg)
  if exe != node{"exeSha256"}.getStr:
    raise newException(ValueError, "broker executable does not match its status")
  if node{"config"}.isNil or hexOf(sha256($node{"config"})) != node{"configSha256"}.getStr:
    raise newException(ValueError, "status profile does not match its fingerprint")
  node

proc receipt*(dir, token: string; now = epochTime()): JsonNode =
  ## The live, fresh `held` status for exactly this hold token, or raise
  ## ValueError naming why there is no receipt.
  let node = readLive(dir)
  let observed = node{"observedAt"}.getFloat
  if node{"state"}.getStr != $gsHeld:
    raise newException(ValueError, "broker is " & node{"state"}.getStr & ", not held")
  if node{"token"}.getStr != token:
    raise newException(ValueError, "broker has not acknowledged this hold token")
  if not (observed.finite and now - observed <= StatusFreshSeconds and
      observed <= now + ClockSlackSeconds):
    raise newException(ValueError, "held status is stale")
  let expires = node{"expiresAt"}.getFloat
  if not (expires.finite and expires > now):
    raise newException(ValueError, "hold has expired")
  if node{"admittedChains"}.getInt(-1) != 0 or node{"activePosts"}.getInt(-1) != 0:
    raise newException(ValueError, "held status does not report zero work")
  let control = try: parseFile(controlPath(dir))
    except CatchableError:
      raise newException(ValueError, "hold control is missing")
  if control{"token"}.getStr != token or
      control{"instance"}.getStr != node{"instance"}.getStr:
    raise newException(ValueError, "hold control no longer names this token and instance")
  node

proc requestHold*(dir: string; seconds: float; now = epochTime()): JsonNode =
  ## Write a new hold bound to the live broker and return it. Refuses an
  ## unknown broker, an out-of-bounds duration, or a second unexpired hold.
  ## The check and the write happen under the control lock, so two callers
  ## cannot both be granted a hold.
  if not (seconds.finite and seconds > 0 and seconds <= MaxHoldSeconds):
    raise newException(ValueError, "hold seconds must be in (0, " & $MaxHoldSeconds & "]")
  let live = readLive(dir)
  withControlLock(dir):
    if fileExists(controlPath(dir)):
      var existing: JsonNode
      try: existing = parseControl(parseFile(controlPath(dir)), now)
      except CatchableError: existing = nil
      if not existing.isNil and existing["expiresAt"].getFloat > now:
        raise newException(ValueError, "another hold is active: " & existing["token"].getStr)
    result = %*{"protocol": AdmissionProtocol, "token": newToken(),
      "instance": live{"instance"}, "pid": live{"pid"},
      "startTicks": live{"startTicks"}, "exeSha256": live{"exeSha256"},
      "configSha256": live{"configSha256"}, "requestedAt": now,
      "expiresAt": now + seconds}
    writeAtomic(controlPath(dir), $result)

proc releaseHold*(dir, token: string) =
  ## Remove the hold only when it carries exactly this token; raise
  ## ValueError otherwise. Releasing a hold that is already gone succeeds.
  let path = controlPath(dir)
  if not fileExists(path): return
  withControlLock(dir):
    if fileExists(path):
      let current = try: parseFile(path){"token"}.getStr
        except CatchableError: ""
      if current != token:
        raise newException(ValueError, "the current hold does not carry this token")
      removeFile(path)

proc statusReport*(dir: string; now = epochTime()): JsonNode =
  ## Caller-facing status: the live fresh status, or state `unknown` with
  ## null counts and the reason.
  try:
    result = readLive(dir)
    let observed = result{"observedAt"}.getFloat
    if not (observed.finite and now - observed <= StatusFreshSeconds):
      result = %*{"state": "unknown", "reason": "status is stale",
        "lastState": result{"state"}, "observedAt": observed,
        "instance": result{"instance"}, "admittedChains": newJNull(),
        "activePosts": newJNull(), "deferredByInstanceThisHold": newJNull(),
        "pendingFileRows": newJNull()}
  except ValueError as error:
    result = %*{"state": "unknown", "reason": error.msg,
      "admittedChains": newJNull(), "activePosts": newJNull(),
      "deferredByInstanceThisHold": newJNull(), "pendingFileRows": newJNull()}

proc parseSeconds(name, value: string): float =
  ## A finite, non-negative CLI duration; quits with usage status 2 otherwise,
  ## before anything is written.
  try: result = parseFloat(value)
  except ValueError: quit("--" & name & " must be a finite number of seconds", 2)
  if not (result.finite and result >= 0):
    quit("--" & name & " must be a finite number of seconds", 2)

proc main() =
  ## `status [--token=T]`, `hold [--seconds=S] [--wait=W]` or
  ## `release --token=T`, all with `--home-dir=DIR`. Exit 0 is a receipt,
  ## written hold or release; 3 is unknown or refused; 2 is a usage error.
  var
    command = ""
    homeDir = getCurrentDir() / "local_data" / "home-army"
    token = ""
    seconds = DefaultHoldSeconds
    wait = 0.0
  for kind, key, value in getopt():
    case kind
    of cmdArgument: command = key
    of cmdLongOption, cmdShortOption:
      case key
      of "home-dir": homeDir = value
      of "token": token = value
      of "seconds": seconds = parseSeconds(key, value)
      of "wait": wait = parseSeconds(key, value)
      else: quit("unknown option: " & key, 2)
    of cmdEnd: discard
  let dir = homeDir / AdmissionDir
  case command
  of "status":
    if token.len > 0:
      try:
        echo $receipt(dir, token)
      except CatchableError as error:
        echo $(%*{"state": "unknown", "receipt": false, "reason": error.msg})
        quit(3)
    else:
      let report = statusReport(dir)
      echo $report
      if report{"state"}.getStr == "unknown": quit(3)
  of "hold":
    let control = try: requestHold(dir, seconds)
      except CatchableError as error: quit("hold refused: " & error.msg, 3)
    let held = control["token"].getStr
    if wait <= 0:
      echo $control
      return
    let deadline = epochTime() + min(wait, seconds)
    while true:
      try:
        echo $receipt(dir, held)
        return
      except CatchableError as error:
        if epochTime() >= deadline:
          # The boundary failed: give the broker back rather than leave a
          # hold nobody acknowledged. A control that no longer carries this
          # token belongs to someone else and stays.
          let outcome = try:
              releaseHold(dir, held)
              "released"
            except CatchableError as failure:
              "not released: " & failure.msg
          quit("hold " & held & " not acknowledged before deadline (" &
            error.msg & "); " & outcome, 3)
      os.sleep(WaitPollMs)
  of "release":
    if token.len == 0: quit("--token is required", 2)
    try: releaseHold(dir, token)
    except CatchableError as error: quit("release refused: " & error.msg, 3)
    echo "released ", token
  else:
    quit("usage: broker_admission status|hold|release --home-dir=DIR " &
      "[--token=T] [--seconds=S] [--wait=W]", 2)

when isMainModule:
  main()
