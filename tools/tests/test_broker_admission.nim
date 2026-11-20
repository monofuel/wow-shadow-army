## Model admission and drain through the real broker tick: holds, receipts,
## deferred requests, expiry and identity, with synthetic seats and transport.
## Control-writer cases run the real `broker_admission` CLI as separate
## processes against this test process acting as the live broker. Set
## BROKER_ADMISSION_BIN to the binary under test; otherwise it is built.

import
  std/[json, os, osproc, posix, streams, strutils, tables, times, unittest],
  curly,
  ../[bot_requests, broker_admission]

const
  Murist = "1000007"
  ProfileKeys = ["homeDir", "seats", "authority", "authorityGuid", "pollSeconds",
    "baseUrl", "model", "routeBaseUrl", "routeModel", "outputTokens", "timeoutMs"]
  Malformed = ["--seconds=nan", "--seconds=inf", "--seconds=-inf", "--seconds=1e400",
    "--seconds=abc", "--seconds=", "--wait=nan", "--wait=inf", "--wait=abc", "--wait=-1"]
  UnprivilegedId = 65534 ## The conventional nobody/nogroup id, which owns none of the suite's inputs.

var
  posts: seq[string] ## Each synthetic model POST in order: kev, decision or reply.
  onPost: proc (url: string) ## Runs at the start of every synthetic POST.
  midToken: string
  midStatus: JsonNode
  midReceiptRefused: bool
  mtimeStep = 0
  cliBin = ""

proc fakePost(url, apiKey, body: string; timeoutMs: int): Response =
  ## Synthetic Kev/Lightning: "come" is an action, "level" a question.
  if onPost != nil: onPost(url)
  result.code = 200
  let req = parseJson(body)
  if url.endsWith("/systemone"):
    posts.add "kev"
    let state = req{"state"}.getStr
    let message = state[state.find("Message: ") + 9 ..^ 1]
    let intent = if "come" in message: "action"
      elif "level" in message: "question" else: "chatter"
    var probs = %*{"question": 0.0, "action": 0.0, "chatter": 0.0}
    probs[intent] = %1.0
    result.body = $(%*{"model": "kev-4b", "answers": {"intent": {"type": "choice",
      "choice": intent, "confidence": 0.95, "probabilities": probs}}})
  elif not req{"response_format"}.isNil:
    posts.add "decision"
    let keys = $req{"response_format"}{"json_schema"}{"schema"}{"properties"}{"choice"}{"enum"}
    let choice = if "come_here" in keys: "come_here" else: "hold_here"
    result.body = $(%*{"model": "lightning", "choices": [{"finish_reason": "stop",
      "message": {"content": $(%*{"intent": "action", "choice": choice})}}]})
  else:
    posts.add "reply"
    result.body = $(%*{"model": "lightning", "choices": [{"finish_reason": "stop",
      "message": {"content": "Level five."}}]})

proc chat(sequence: int; text: string): JsonNode =
  ## One synthetic whisper from the authority.
  %*{"sequence": sequence, "kind": "whisper", "sender_guid": Murist,
    "sender_name": "Murist", "text": text}

proc writeSeat(home: string; rows: JsonNode) =
  ## The live seat Legia in the authority's party with a new observation.
  let dir = home / "Legia"
  createDir(dir / "observer")
  writeFile(dir / "launcher.pid", $getCurrentProcessId())
  var last = 0
  for r in rows: last = max(last, r{"sequence"}.getInt)
  let obs = %*{"episode_id": "episode-1", "player_guid": "205", "class_id": 9,
    "level": 5, "xp": 10, "next_level_xp": 400, "copper": 20, "known_spells": [],
    "active_pet_guid": "0", "inventory_items": [],
    "location": {"x": 1, "y": 2, "z": 3, "map_id": 0},
    "units": [{"guid": Murist, "location": {"x": 4, "y": 5, "z": 3, "map_id": 0}}],
    "party": {"members": [{"guid": Murist, "name": "Murist"}]},
    "chat_messages_last_sequence": last, "chat_messages": rows}
  let path = dir / "observer" / "observation.json"
  writeFile(path, $obs)
  inc mtimeStep
  setLastModificationTime(path, fromUnixFloat(epochTime() + float(mtimeStep) / 100))

proc jobsOf(home: string): seq[JsonNode] =
  ## Every job handed to Legia: its one-slot inbox, then its queue.
  let jobs = home / "Legia" / "jobs"
  if fileExists(jobs / "inbox.json"): result.add parseFile(jobs / "inbox.json")
  if fileExists(jobs / "queue.jsonl"):
    for line in lines(jobs / "queue.jsonl"):
      if line.strip.len > 0: result.add parseJson(line)

proc fresh(name: string): (string, Config) =
  ## An empty synthetic home with an opened broker gate and stub transport.
  let home = getTempDir() / ("test_broker_admission_" & $getCurrentProcessId()) / name
  removeDir(home)
  createDir(home)
  postJson = fakePost
  onPost = nil
  posts = @[]
  var cfg = defaultConfig(home)
  cfg.seats = @["Legia"]
  gate = openGate(home, profile(cfg))
  (home, cfg)

proc cli(): string =
  ## The broker_admission CLI under test.
  if cliBin.len > 0: return cliBin
  cliBin = getEnv("BROKER_ADMISSION_BIN")
  if cliBin.len == 0:
    cliBin = getTempDir() / "broker_admission_cli"
    let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
      quoteShell(getTempDir() / "broker_admission_cli_cache") & " --out:" &
      quoteShell(cliBin) & " " &
      quoteShell(currentSourcePath().parentDir.parentDir / "broker_admission.nim"))
    doAssert code == 0, output
  cliBin

proc startCli(home: string; args: openArray[string]): Process =
  ## Start one CLI process against the home.
  startProcess(cli(), args = @args & @["--home-dir=" & home],
    options = {poStdErrToStdOut})

proc finishCli(p: Process): (string, int) =
  ## Collect a CLI process's output and exit code.
  let output = p.outputStream.readAll.strip
  let code = p.waitForExit
  p.close
  (output, code)

proc runCli(home: string; args: varargs[string]): (string, int) =
  ## Run the CLI to completion.
  finishCli(startCli(home, args))

proc stray(dir: string): seq[string] =
  ## Temporary files left in a directory.
  for path in walkFiles(dir / "*.tmp*"): result.add path

proc expire(dir: string) =
  ## Move the current hold's window into the past, as time passing would.
  var control = parseFile(controlPath(dir))
  let now = epochTime()
  control["requestedAt"] = %(now - 61.0)
  control["expiresAt"] = %(now - 1.0)
  writeFile(controlPath(dir), $control)

proc setgroups(size: csize_t; list: ptr Gid): cint {.importc, header: "<grp.h>".}

proc runUnprivileged(): int =
  ## Run this whole suite as an unprivileged child and return its exit status.
  ## Root ignores directory permissions, so the read-only fault cases would not
  ## fault. The child gets a private /tmp directory it owns, holding copies of
  ## this test and the CLI built here first, so it needs no compiler, no
  ## configuration and no private path. Only the child drops its groups, gid and
  ## uid; this process keeps its credentials and removes the directory.
  var owned = "/tmp/test_broker_admission_root_XXXXXX"
  # mkdtemp fills in the X's in place; a literal's buffer is read-only.
  prepareMutation(owned)
  if mkdtemp(owned.cstring) == nil: raiseOSError(osLastError())
  try:
    let exe = owned / "test_broker_admission"
    let bin = owned / "broker_admission_cli"
    copyFile(getAppFilename(), exe)
    copyFile(cli(), bin)
    for path in [exe, bin]:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    for path in [owned, exe, bin]:
      if chown(path.cstring, Uid(UnprivilegedId), Gid(UnprivilegedId)) != 0:
        raiseOSError(osLastError())
    var env = @["TMPDIR=" & owned, "HOME=" & owned, "BROKER_ADMISSION_BIN=" & bin,
      "PATH=" & getEnv("PATH")]
    if existsEnv("LD_LIBRARY_PATH"):
      env.add "LD_LIBRARY_PATH=" & getEnv("LD_LIBRARY_PATH")
    let argv = allocCStringArray([exe])
    let envp = allocCStringArray(env)
    defer:
      deallocCStringArray(argv)
      deallocCStringArray(envp)
    flushFile(stdout)
    flushFile(stderr)
    let pid = fork()
    if pid < 0: raiseOSError(osLastError())
    if pid == 0:
      if setgroups(0, nil) == 0 and setgid(Gid(UnprivilegedId)) == 0 and
          setuid(Uid(UnprivilegedId)) == 0 and geteuid() != 0 and
          chdir(owned.cstring) == 0:
        discard execve(exe.cstring, argv, envp)
      exitnow(127)
    var status: cint
    while waitpid(pid, status, 0) < 0:
      if osLastError() != OSErrorCode(EINTR): raiseOSError(osLastError())
    result = if WIFEXITED(status): int(WEXITSTATUS(status))
      else: 128 + int(WTERMSIG(status))
  finally:
    removeDir(owned)

if geteuid() == 0:
  quit(runUnprivileged())

suite "broker admission":
  test "a hold before admission defers chat and operator work; release replays it once":
    let (home, cfg) = fresh("hold")
    let dir = home / AdmissionDir
    let jobs = home / "Legia" / "jobs"
    var seats = initTable[string, SeatState]()
    var rows = %*[chat(1, "hello from before")]
    writeSeat(home, rows)
    tick(cfg, seats)
    check posts.len == 0
    let opened = statusReport(dir)
    check opened{"state"}.getStr == "open"
    check opened{"admittedChains"}.getInt(-1) == 0 and opened{"activePosts"}.getInt(-1) == 0
    # The published profile is the broker's public nonsecret profile, with
    # the default Switchyard route; credentials are never part of it.
    check opened{"config"} == profile(cfg)
    check opened{"config"}{"model"}.getStr == "local"
    check opened{"config"}{"routeModel"}.getStr == "kev-4b"
    check opened{"config"}{"timeoutMs"}.getInt == 120_000
    check not opened{"config"}.hasKey("apiKey") and not opened{"config"}.hasKey("routeApiKey")
    check opened{"config"}{"outputTokens"}.getInt == 32768
    # The full approved nonsecret profile, including authority GUID and
    # poll interval, so a caller can compare it field for field.
    check opened{"config"}{"authorityGuid"}.getStr == Murist
    check opened{"config"}{"authority"}.getStr == "Murist"
    check opened{"config"}{"pollSeconds"}.getFloat == 1.0
    check opened{"config"}{"seats"} == %["Legia"]
    check opened{"config"}{"baseUrl"}.getStr == "https://switchyard.mle.monofuel.dev/v1"
    check opened{"config"}{"routeBaseUrl"}.getStr == "http://10.11.2.22:1234/v1"
    var keys: seq[string]
    for key in opened{"config"}.keys: keys.add key
    check keys == @ProfileKeys
    check "unused" notin readFile(statusPath(dir))

    let token = requestHold(dir, 60)["token"].getStr
    # The request alone is not a receipt: the broker has not acknowledged it.
    expect ValueError:
      discard receipt(dir, token)
    rows.add chat(2, "what level are you")
    writeSeat(home, rows)
    tick(cfg, seats)
    check posts.len == 0
    let held = receipt(dir, token)
    check held{"deferredByInstanceThisHold"}.getInt == 1
    check held{"pendingFileRows"}.kind == JNull
    check not held.hasKey("deferredRows")
    check held{"admittedChains"}.getInt == 0 and held{"activePosts"}.getInt == 0
    check parseFile(jobs / "chat_cursor.json"){"sequence"}.getInt == 2
    check fileExists(jobs / "deferred.jsonl")
    check not fileExists(jobs / "ledger.txt")

    writeFile(jobs / "operator.jsonl",
      """{"key":"operator-Legia-1","actor":"operator","text":"come here"}""" & "\n")
    tick(cfg, seats)
    check posts.len == 0
    check fileExists(jobs / "operator.jsonl")
    check not fileExists(jobs / "operator.claimed.jsonl")
    discard receipt(dir, token)
    expect ValueError:
      discard requestHold(dir, 60)
    expect ValueError:
      releaseHold(dir, newToken())
    check fileExists(controlPath(dir))

    releaseHold(dir, token)
    tick(cfg, seats)
    check posts == @["kev", "reply", "kev", "decision"]
    let handed = jobsOf(home)
    check handed.len == 2
    check handed[0]{"intent"}.getStr == "question" and handed[0]{"reply"}.getStr == "Level five."
    check handed[1]{"origin"}.getStr == "operator" and handed[1]{"choice"}.getStr == "hold_here"
    check not fileExists(jobs / "deferred.jsonl")
    check not fileExists(jobs / "operator.jsonl")
    check not fileExists(jobs / "operator.claimed.jsonl")
    check statusReport(dir){"state"}.getStr == "open"
    expect ValueError:
      discard receipt(dir, token)

    # Nothing is handled twice, by this broker or a restarted one.
    tick(cfg, seats)
    var restarted = initTable[string, SeatState]()
    writeSeat(home, rows)
    tick(cfg, restarted)
    check posts.len == 4

  test "a hold arriving mid Kev to Lightning chain lets it finish, then expiry replays once":
    let (home, cfg) = fresh("midchain")
    let dir = home / AdmissionDir
    var seats = initTable[string, SeatState]()
    var rows = %*[chat(1, "history")]
    writeSeat(home, rows)
    tick(cfg, seats)
    midToken = ""
    midStatus = nil
    midReceiptRefused = false
    onPost = proc (url: string) =
      if url.endsWith("/systemone") and midToken.len == 0:
        midToken = requestHold(dir, 60)["token"].getStr
      elif url.endsWith("/chat/completions") and midStatus.isNil:
        midStatus = parseFile(statusPath(dir))
        try:
          discard receipt(dir, midToken)
        except ValueError:
          midReceiptRefused = true
    rows.add chat(2, "come here please")
    rows.add chat(3, "hello there")
    writeSeat(home, rows)
    tick(cfg, seats)
    onPost = nil
    # The admitted chain made both of its POSTs; the next row waited.
    check posts == @["kev", "decision"]
    check midStatus{"state"}.getStr == "draining"
    check midStatus{"token"}.getStr == midToken
    check midStatus{"admittedChains"}.getInt == 1 and midStatus{"activePosts"}.getInt == 1
    check midReceiptRefused
    let held = receipt(dir, midToken)
    check held{"deferredByInstanceThisHold"}.getInt == 1
    check held{"pendingFileRows"}.kind == JNull
    check jobsOf(home).len == 1 and jobsOf(home)[0]{"choice"}.getStr == "come_here"

    expire(dir)
    tick(cfg, seats)
    check posts == @["kev", "decision", "kev", "reply"]
    check jobsOf(home).len == 2
    let after = statusReport(dir)
    check after{"state"}.getStr == "open"
    check "expired" in after{"note"}.getStr
    expect ValueError:
      discard receipt(dir, midToken)
    tick(cfg, seats)
    check posts.len == 4

  test "a restarted broker under an old instance's hold reports mismatch, never a receipt":
    let (home, cfg) = fresh("restart")
    let dir = home / AdmissionDir
    var seats = initTable[string, SeatState]()
    var rows = %*[chat(1, "history")]
    writeSeat(home, rows)
    tick(cfg, seats)
    let token = requestHold(dir, 60)["token"].getStr
    tick(cfg, seats)
    let old = receipt(dir, token){"instance"}.getStr

    gate = openGate(home, profile(cfg))
    check gate.instance != old
    var restarted = initTable[string, SeatState]()
    rows.add chat(2, "hello")
    writeSeat(home, rows)
    tick(cfg, restarted)
    check posts.len == 0
    let report = statusReport(dir)
    check report{"state"}.getStr == "mismatch"
    check report{"instance"}.getStr == gate.instance
    check report{"foreignInstance"}.getStr == old
    expect ValueError:
      discard receipt(dir, token)
    expect ValueError:
      discard requestHold(dir, 60)

    releaseHold(dir, token)
    tick(cfg, restarted)
    check posts == @["kev", "reply"]
    check statusReport(dir){"state"}.getStr == "open"

  test "missing, stale, reused or foreign status is unknown, never zero":
    let (home, cfg) = fresh("identity")
    let dir = home / AdmissionDir
    let none = statusReport(dir)
    check none{"state"}.getStr == "unknown"
    check none{"admittedChains"}.kind == JNull and none{"activePosts"}.kind == JNull
    check none{"deferredByInstanceThisHold"}.kind == JNull
    check none{"pendingFileRows"}.kind == JNull
    expect ValueError:
      discard requestHold(dir, 60)
    var seats = initTable[string, SeatState]()
    tick(cfg, seats)
    let good = parseFile(statusPath(dir))
    check statusReport(dir){"state"}.getStr == "open"
    for (key, value) in [("pid", %999999999), ("startTicks", %"1"),
        ("exeSha256", %("0".repeat(64))), ("observedAt", %(epochTime() - 60.0))]:
      var bad = good.copy
      bad[key] = value
      writeFile(statusPath(dir), $bad)
      let report = statusReport(dir)
      check report{"state"}.getStr == "unknown"
      check report{"admittedChains"}.kind == JNull
    var tampered = good.copy
    tampered["config"]["model"] = %"other"
    writeFile(statusPath(dir), $tampered)
    check statusReport(dir){"state"}.getStr == "unknown"
    writeFile(statusPath(dir), "{not json")
    check statusReport(dir){"state"}.getStr == "unknown"
    expect ValueError:
      discard requestHold(dir, 60)
    expect ValueError:
      discard requestHold(dir, MaxHoldSeconds + 1)

  test "invalid controls never freeze the broker and never end a hold early":
    let (home, cfg) = fresh("invalid")
    let dir = home / AdmissionDir
    var seats = initTable[string, SeatState]()
    var rows = %*[chat(1, "history")]
    writeSeat(home, rows)
    tick(cfg, seats)
    writeFile(controlPath(dir), "{not json")
    rows.add chat(2, "hello")
    writeSeat(home, rows)
    tick(cfg, seats)
    check posts.len == 2
    check "invalid control" in statusReport(dir){"note"}.getStr

    var unbounded = %*{"protocol": AdmissionProtocol, "token": newToken(),
      "instance": gate.instance, "pid": gate.pid, "startTicks": gate.startTicks,
      "exeSha256": gate.exeSha256, "configSha256": gate.configSha256,
      "requestedAt": epochTime(), "expiresAt": epochTime() + MaxHoldSeconds + 60}
    writeFile(controlPath(dir), $unbounded)
    rows.add chat(3, "hello again")
    writeSeat(home, rows)
    tick(cfg, seats)
    check posts.len == 4
    check statusReport(dir){"state"}.getStr == "open"

    removeFile(controlPath(dir))
    tick(cfg, seats)
    let hold = requestHold(dir, 60)
    tick(cfg, seats)
    discard receipt(dir, hold["token"].getStr)
    writeFile(controlPath(dir), "{not json")
    rows.add chat(4, "still there")
    writeSeat(home, rows)
    tick(cfg, seats)
    check posts.len == 4
    check gate.state == gsHeld
    check "prior hold kept" in gate.note
    # Bounded: past the hold's own expiry the broker admits again.
    check gate.admit(hold["expiresAt"].getFloat + 1.0)
    gate.finish()
    check gate.state == gsOpen
    tick(cfg, seats)
    check posts.len == 6

  test "the deferred counter is per instance and hold; pending rows survive H1 to H2 and restart":
    let (home, cfg) = fresh("counter")
    let dir = home / AdmissionDir
    let jobs = home / "Legia" / "jobs"
    var seats = initTable[string, SeatState]()
    var rows = %*[chat(1, "history")]
    writeSeat(home, rows)
    tick(cfg, seats)
    let h1 = requestHold(dir, 60)["token"].getStr
    rows.add chat(2, "what level are you")
    writeSeat(home, rows)
    tick(cfg, seats)
    check receipt(dir, h1){"deferredByInstanceThisHold"}.getInt == 1
    let queued = readFile(jobs / "deferred.jsonl")
    check queued.splitLines.len == 2

    # H1 released and H2 requested before the broker's next poll: the new
    # token's counter is zero while the H1 row still waits, so the published
    # backlog is unknown, not zero, and the receipt does not need it empty.
    releaseHold(dir, h1)
    let h2 = requestHold(dir, 60)["token"].getStr
    tick(cfg, seats)
    let r2 = receipt(dir, h2)
    check r2{"deferredByInstanceThisHold"}.getInt == 0
    check r2{"pendingFileRows"}.kind == JNull
    check readFile(jobs / "deferred.jsonl") == queued
    check posts.len == 0

    # A restarted broker likewise starts at zero with the row still queued.
    gate = openGate(home, profile(cfg))
    var restarted = initTable[string, SeatState]()
    releaseHold(dir, h2)
    gate.refresh()
    let h3 = requestHold(dir, 60)["token"].getStr
    tick(cfg, restarted)
    let r3 = receipt(dir, h3)
    check r3{"instance"}.getStr == gate.instance
    check r3{"deferredByInstanceThisHold"}.getInt == 0
    check r3{"pendingFileRows"}.kind == JNull
    check readFile(jobs / "deferred.jsonl") == queued
    check posts.len == 0

    releaseHold(dir, h3)
    tick(cfg, restarted)
    check posts == @["kev", "reply"]
    check jobsOf(home).len == 1 and jobsOf(home)[0]{"reply"}.getStr == "Level five."
    check not fileExists(jobs / "deferred.jsonl")
    tick(cfg, restarted)
    var again = initTable[string, SeatState]()
    writeSeat(home, rows)
    tick(cfg, again)
    check posts.len == 2

  test "a failed deferred write keeps committed rows and the cursor, and loses no row":
    let (home, cfg) = fresh("deferfail")
    let dir = home / AdmissionDir
    let jobs = home / "Legia" / "jobs"
    var seats = initTable[string, SeatState]()
    var rows = %*[chat(1, "history")]
    writeSeat(home, rows)
    tick(cfg, seats)
    let token = requestHold(dir, 60)["token"].getStr
    rows.add chat(2, "what level are you")
    writeSeat(home, rows)
    tick(cfg, seats)
    let committed = readFile(jobs / "deferred.jsonl")
    let cursor = readFile(jobs / "chat_cursor.json")
    rows.add chat(3, "hello there")
    writeSeat(home, rows)
    # The seat's jobs directory refuses new files: the deferred update
    # cannot be written or renamed into place.
    setFilePermissions(jobs, {fpUserRead, fpUserExec})
    var failed = false
    try:
      try:
        tick(cfg, seats)
      except CatchableError:
        failed = true
    finally:
      setFilePermissions(jobs, {fpUserRead, fpUserWrite, fpUserExec})
    check failed
    check readFile(jobs / "deferred.jsonl") == committed
    check readFile(jobs / "chat_cursor.json") == cursor
    check stray(jobs).len == 0

    tick(cfg, seats)
    var keys: seq[string]
    for line in readFile(jobs / "deferred.jsonl").splitLines:
      if line.len > 0: keys.add parseJson(line){"key"}.getStr
    check keys.len == 2 and keys[0].endsWith("-2") and keys[1].endsWith("-3")
    check not fileExists(jobs / "deferred.bad.jsonl")
    check posts.len == 0
    releaseHold(dir, token)
    tick(cfg, seats)
    check posts == @["kev", "reply", "kev", "reply"]
    check jobsOf(home).len == 2
    tick(cfg, seats)
    check posts.len == 4

  test "non-finite or malformed numbers are refused and never create or replace a control":
    let (home, cfg) = fresh("numbers")
    let dir = home / AdmissionDir
    var seats = initTable[string, SeatState]()
    tick(cfg, seats)
    for seconds in [NaN, Inf, NegInf, 0.0, -1.0, MaxHoldSeconds + 1]:
      expect ValueError:
        discard requestHold(dir, seconds)
    let now = epochTime()
    for (key, value) in [("requestedAt", %NaN), ("expiresAt", %NaN),
        ("expiresAt", %Inf), ("requestedAt", %NegInf)]:
      var control = %*{"protocol": AdmissionProtocol, "token": newToken(),
        "instance": gate.instance, "pid": gate.pid, "requestedAt": now,
        "expiresAt": now + 60}
      control[key] = value
      expect ValueError:
        discard parseControl(control, now)
    for arg in Malformed:
      let (output, code) = runCli(home, "hold", arg)
      check code == 2
      check "finite number" in output
      check not fileExists(controlPath(dir))
    for arg in ["--seconds=0", "--seconds=1801"]:
      let (output, code) = runCli(home, "hold", arg)
      check code == 3 and "hold refused" in output
      check not fileExists(controlPath(dir))
    # An expired control a valid hold would replace stays byte for byte.
    discard requestHold(dir, 60)
    expire(dir)
    let before = readFile(controlPath(dir))
    for arg in Malformed:
      check runCli(home, "hold", arg)[1] == 2
      check readFile(controlPath(dir)) == before
    check stray(dir).len == 0

  test "competing CLI writers get one hold; locked, unacknowledged and replaced holds are controlled":
    let (home, cfg) = fresh("writers")
    let dir = home / AdmissionDir
    var seats = initTable[string, SeatState]()
    tick(cfg, seats)
    var procs: seq[Process]
    for i in 0 ..< 8:
      procs.add startCli(home, ["hold", "--seconds=60"])
    var winners: seq[string]
    var refused = 0
    for p in procs:
      let (output, code) = finishCli(p)
      if code == 0: winners.add parseJson(output)["token"].getStr
      elif code == 3 and "another hold is active" in output: inc refused
    check winners.len == 1 and refused == 7
    check parseFile(controlPath(dir))["token"].getStr == winners[0]
    check stray(dir).len == 0
    check runCli(home, "release", "--token=" & newToken())[1] == 3
    check parseFile(controlPath(dir))["token"].getStr == winners[0]
    check runCli(home, "release", "--token=" & winners[0])[1] == 0
    check not fileExists(controlPath(dir))

    # While another process holds the writer lock, a hold is refused and
    # writes nothing.
    let fd = posix.open(cstring(dir / "control.lock"), O_RDWR or O_CLOEXEC, Mode(0o600))
    check fd >= 0
    check lockf(fd, F_LOCK, 0) == 0
    let (locked, lockedCode) = runCli(home, "hold", "--seconds=60")
    discard posix.close(fd)
    check lockedCode == 3 and "holds the lock" in locked
    check not fileExists(controlPath(dir))

    # The real CLI receives a receipt from the live broker while waiting.
    let waiting = startCli(home, ["hold", "--seconds=60", "--wait=5"])
    while waiting.running:
      gate.refresh()
      os.sleep(50)
    let (receiptOut, receiptCode) = finishCli(waiting)
    check receiptCode == 0
    let acked = parseJson(receiptOut)
    check acked{"state"}.getStr == "held" and acked{"instance"}.getStr == gate.instance
    check runCli(home, "release", "--token=" & acked{"token"}.getStr)[1] == 0
    gate.refresh()

    # Unacknowledged by the deadline: the CLI releases its own hold.
    let (lapsed, lapsedCode) = runCli(home, "hold", "--seconds=60", "--wait=1")
    check lapsedCode == 3 and "); released" in lapsed
    check not fileExists(controlPath(dir))

    # Replaced before the deadline: the other token's control stays.
    let replacedProc = startCli(home, ["hold", "--seconds=60", "--wait=2"])
    var spins = 0
    while not fileExists(controlPath(dir)) and spins < 200:
      os.sleep(10)
      inc spins
    var other = parseFile(controlPath(dir))
    other["token"] = %newToken()
    writeFile(controlPath(dir), $other)
    let (replaced, replacedCode) = finishCli(replacedProc)
    check replacedCode == 3 and "not released" in replaced
    check parseFile(controlPath(dir))["token"] == other["token"]

  test "an unwritable status cannot leave a stale held receipt in force":
    let (home, cfg) = fresh("unwritable")
    let dir = home / AdmissionDir
    var seats = initTable[string, SeatState]()
    tick(cfg, seats)
    let token = requestHold(dir, 60)["token"].getStr
    tick(cfg, seats)
    discard receipt(dir, token)
    releaseHold(dir, token)
    setFilePermissions(dir, {fpUserRead, fpUserExec})
    try:
      gate.refresh()
      check gate.statusError.len > 0
      check gate.state == gsOpen
      check parseFile(statusPath(dir)){"state"}.getStr == "held"
      # The stale file is not a receipt, and nothing is admitted while it
      # could still be read as fresh.
      expect ValueError:
        discard receipt(dir, token)
      check not gate.admit()
      check gate.admit(epochTime() + StatusFreshSeconds + 1.0)
      gate.finish()
    finally:
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    gate.refresh()
    check statusReport(dir){"state"}.getStr == "open"
    removeDir(getTempDir() / ("test_broker_admission_" & $getCurrentProcessId()))
