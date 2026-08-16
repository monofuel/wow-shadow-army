## The eval executor and the code gate — the heart of the conductor.
##
## runEval shells the league's make target in a checkout, archives the
## run log (ticket 0017: every launch truncates run.log), and returns
## one RunReport JSON: the segment-result superset (ok/deaths/scorecard)
## plus max_northing computed here from FLIGHT lines.
##
## runGate is a PURE comparator — floor ratchet + configured assertions
## vs the champion row + no new warning classes. No LLM is consulted;
## a reviewer agent may reject earlier, but only this gate can pass.

import
  std/[algorithm, json, options, os, osproc, sets, strutils, tables, times],
  scriptorium/git_ops,
  ./cfg

const
  # Kalimdor race scoring line (tools/pack_traverse_replay.sh:115).
  GoalX = 6687.333052
  StartX = -9187.0
  LegacyRunLogRelPath = "local_data/traverse-status/run.log"
  LegacySegmentResultRelPath = "local_data/traverse-segment-result.json"
  LegacyArchiveRelDir = "local_data/traverse-status/archive"
  DefaultEvalLoadCap* = 45.0
  EvalSlotMin* = 1
  EvalSlotMax* = 3
  EvalSlotTtlMinutes* = 45
  EvalSeriesRetryBudget* = 4
  LaunchToolRel = "tools/launch_nim_player.nim"

type
  EvalOutcome* = enum
    evalOk        ## a fresh run happened; report is valid (bot may still have died)
    evalBusy      ## eval slot held elsewhere / no fresh run — retry later
    evalFailed    ## harness problem: no parseable result from a fresh run

  EvalResult* = object
    outcome*: EvalOutcome
    report*: JsonNode
    detail*: string

  EvalCommand* = object
    args*: seq[string]
    wallTimeout*: int

  SlotClaimStatus* = enum
    claimReady     ## one or more evalslot-N leases held
    claimBusy      ## CLI works; every slot is taken
    claimUnusable  ## CLI missing/broken — degrade to legacy slot 0

  SlotClaim* = object
    slots*: seq[int]
    status*: SlotClaimStatus

proc slotDataPrefix*(slot = 0): string =
  ## Checkout-relative root for a slot's run files. Slot 0 is legacy `local_data`.
  if slot <= 0: "local_data"
  else: "local_data" / "eval-slots" / ("s" & $slot)

proc runLogRelPath*(slot = 0): string =
  ## `run.log` for this slot. Slot 0 is the legacy path exactly.
  if slot <= 0: LegacyRunLogRelPath
  else: slotDataPrefix(slot) / "traverse-status" / "run.log"

proc segmentResultRelPath*(slot = 0): string =
  ## Segment-result JSON for this slot. Slot 0 is the legacy path exactly.
  if slot <= 0: LegacySegmentResultRelPath
  else: slotDataPrefix(slot) / "traverse-segment-result.json"

proc archiveRelDir*(slot = 0): string =
  ## Shared legacy archive so downstream tools read one directory.
  discard slot
  LegacyArchiveRelDir

proc archiveLogName*(slug: string, slot = 0, stamp = ""): string =
  ## Archive filename; slot runs gain `-s<n>` before `.log`.
  let ts = if stamp.len > 0: stamp else: now().utc.format("yyyyMMdd-HHmmss")
  if slot <= 0:
    "run-" & ts & "-" & slug & ".log"
  else:
    "run-" & ts & "-" & slug & "-s" & $slot & ".log"

proc reportNorthing*(r: JsonNode): float =
  ## `max_northing` or 0.0 when the report is missing it.
  if r.isNil: 0.0 else: r{"max_northing"}.getFloat(0.0)

proc pickMedianReport*(reports: seq[JsonNode]): JsonNode =
  ## Middle report by max_northing (upper median on an even count).
  doAssert reports.len > 0
  var ranked = reports
  ranked.sort(proc(a, b: JsonNode): int = cmp(reportNorthing(a), reportNorthing(b)))
  ranked[ranked.len div 2]

proc seriesHasFullReports*(validCount, rollTarget: int): bool =
  ## True only when the series produced exactly `rollTarget` valid reports.
  validCount == rollTarget

proc seriesAttemptsExhausted*(attempts, rollTarget: int): bool =
  ## Serial and concurrent paths share this bound: `rollTarget + 4`.
  attempts >= rollTarget + EvalSeriesRetryBudget

proc seriesOutcome*(validCount, rollTarget: int,
    sawFailed, sawBusy: bool): EvalOutcome =
  ## Gate only on a full series. A short series is busy; a completely
  ## empty series of harness failures stays failed.
  if seriesHasFullReports(validCount, rollTarget):
    evalOk
  elif validCount == 0 and sawFailed and not sawBusy:
    evalFailed
  else:
    evalBusy

proc joinEvalDetails*(batch: openArray[EvalResult]): string =
  ## Join every roll's outcome and detail so an all-fail report is complete.
  var parts: seq[string] = @[]
  for item in batch:
    parts.add($item.outcome & ": " & item.detail)
  parts.join("; ")

proc countFlightSamples*(runLogPath: string): int =
  ## Valid FLIGHT lines in the log. Zero on a "fresh" run means the
  ## client/server never got airborne — an infra fault, never a
  ## candidate score.
  if not fileExists(runLogPath):
    return 0
  for line in lines(runLogPath):
    let idx = line.find("FLIGHT {")
    if idx < 0:
      continue
    try:
      let node = parseJson(line[idx + len("FLIGHT ") .. ^1])
      if node.kind == JObject and node.hasKey("x"):
        inc result
    except CatchableError:
      discard

proc computeMaxNorthing*(runLogPath: string): float =
  ## Best northing over the run's FLIGHT samples; 0.0 when none parse.
  result = 0.0
  if not fileExists(runLogPath):
    return
  for line in lines(runLogPath):
    let idx = line.find("FLIGHT {")
    if idx < 0:
      continue
    let node =
      try:
        parseJson(line[idx + len("FLIGHT ") .. ^1])
      except CatchableError:
        continue
    if node.kind != JObject or not node.hasKey("x"):
      continue
    let northing = max(0.0, min(node["x"].getFloat(), GoalX) - StartX)
    if northing > result:
      result = northing

proc jsonNumber*(node: JsonNode, path: string): Option[float] =
  ## Dot-path lookup ("scorecard.fat_min") returning a float; none when
  ## the path is missing, null, or not a number.
  var cur = node
  for part in path.split('.'):
    if cur.isNil or cur.kind != JObject or not cur.hasKey(part):
      return none(float)
    cur = cur[part]
  case cur.kind
  of JInt, JFloat: some(cur.getFloat())
  else: none(float)

proc warningClasses*(report: JsonNode): HashSet[string] =
  ## "WARN fatigue: ..." -> "WARN fatigue"; set semantics — the gate cares
  ## about NEW classes of badness, not about counts or wording.
  result = initHashSet[string]()
  let warnings = report{"scorecard", "warnings"}
  if warnings.isNil or warnings.kind != JArray:
    return
  for w in warnings:
    if w.kind == JString:
      result.incl(w.getStr().split(':')[0].strip())

proc oneMinuteLoad*(loadavgLine: string): float =
  ## First field of /proc/loadavg; 0.0 when unparseable (never blocks).
  let fields = loadavgLine.splitWhitespace()
  if fields.len == 0: return 0.0
  try: parseFloat(fields[0]) except ValueError: 0.0

proc evalLoadCap*(raw = getEnv("CONDUCTOR_EVAL_LOAD_CAP", "45")): float =
  ## Parse the eval load cap; garbage falls back to DefaultEvalLoadCap.
  try: parseFloat(raw) except ValueError: DefaultEvalLoadCap

proc waitForQuietBox*(capEnv = "CONDUCTOR_EVAL_LOAD_CAP"): bool =
  ## Scores rolled on a loaded box are noise, not verdicts (0070's 8,380
  ## park and the 0072 park both rolled at load 40+ next to navmesh
  ## bakes). Hold the eval until 1-min load is under the cap, bounded so
  ## a stuck storm degrades to evalBusy (uncharged) instead of wedging.
  ## The lease is the capacity governor; this cap only guards foreign load.
  let cap = evalLoadCap(getEnv(capEnv, "45"))
  const waitLimitS = 1800
  var waited = 0
  while waited <= waitLimitS:
    let load =
      try: oneMinuteLoad(readFile("/proc/loadavg")) except IOError: 0.0
    if load <= cap:
      return true
    if waited == 0:
      echo "conductor: eval waiting for quiet box (load ",
        load.formatFloat(ffDecimal, 1), " > cap ",
        cap.formatFloat(ffDecimal, 1), ")"
    sleep(60_000)
    waited += 60
  false

proc median3Enabled*(): bool =
  ## Median-of-3 is on unless CONDUCTOR_GATE_MEDIAN3=0.
  getEnv("CONDUCTOR_GATE_MEDIAN3", "1") != "0"

proc buildEvalCommand*(lc: LeagueConfig,
    extraVars: openArray[(string, string)] = [], slot = 0): EvalCommand =
  ## Make args + wall timeout for one eval. Slot 0 omits SLOT= (legacy).
  result.wallTimeout = 2700
  result.args = @[lc.evalMake.target]
  for key, value in lc.evalMake.vars:
    result.args.add(key & "=" & value)
    if key == "END_TIMEOUT":
      result.wallTimeout = try: parseInt(value) except ValueError: 2700
  for (key, value) in extraVars:
    result.args.add(key & "=" & value)
  if slot != 0:
    result.args.add("SLOT=" & $slot)

proc collectEvalResult*(checkoutDir, slug: string, slot: int,
    rc: int, output: string, beforeMtime: Time): EvalResult =
  ## Turn a finished make into an EvalResult. Flock string and mtime
  ## freshness stay as backstops even when a lease reserved the slot.
  if "another live Traverse run owns" in output:
    return EvalResult(outcome: evalBusy,
      detail: "eval flock held by another live run")

  let runLogPath = checkoutDir / runLogRelPath(slot)
  if not fileExists(runLogPath) or
      getLastModificationTime(runLogPath) <= beforeMtime:
    return EvalResult(outcome: evalBusy,
      detail: "run.log not refreshed — lost the slot race, no fresh run" &
        " (make rc=" & $rc & ")")

  let archiveDir = checkoutDir / archiveRelDir(slot)
  createDir(archiveDir)
  var archived = archiveDir / archiveLogName(slug, slot)
  copyFile(runLogPath, archived)
  archived = try: expandFilename(archived) except OSError: archived

  if countFlightSamples(archived) == 0:
    return EvalResult(outcome: evalFailed,
      detail: "fresh run produced zero FLIGHT telemetry — client/server " &
        "prep failure, not a candidate result (log: " & archived & ")")

  let segmentPath = checkoutDir / segmentResultRelPath(slot)
  var report: JsonNode
  if fileExists(segmentPath):
    try:
      report = parseJson(readFile(segmentPath))
    except CatchableError:
      report = nil
  if report.isNil or report.kind != JObject:
    return EvalResult(outcome: evalFailed,
      detail: "fresh run but no parseable " & segmentResultRelPath(slot) &
        " (make rc=" & $rc & ")")

  report["max_northing"] = %computeMaxNorthing(archived)
  report["archived_log"] = %archived
  report["make_rc"] = %rc
  if slot != 0:
    report["eval_slot"] = %slot
  EvalResult(outcome: evalOk, report: report)

proc runLogMtime(path: string): Time =
  if fileExists(path): getLastModificationTime(path) else: fromUnix(0)

proc runEval*(checkoutDir: string, lc: LeagueConfig, slug: string,
    extraVars: openArray[(string, string)] = [], slot: int = 0,
    skipLoadWait = false): EvalResult =
  ## One eval run in checkoutDir. Exit code 2 (flock held / bad bracket
  ## args) and a stale run.log both come back evalBusy — the candidate
  ## is NOT charged for slot contention. Slot acquisition is the caller's
  ## job; slot 0 keeps the legacy make invocation and paths.
  if not skipLoadWait and not waitForQuietBox():
    return EvalResult(outcome: evalBusy,
      detail: "box load stayed over the eval cap for 30 min — not rolling")
  let cmd = buildEvalCommand(lc, extraVars, slot)
  let beforeMtime = runLogMtime(checkoutDir / runLogRelPath(slot))
  let (rc, output) = runCommandCapture(checkoutDir, "make", cmd.args,
    timeoutMs = (cmd.wallTimeout + 900) * 1000)
  collectEvalResult(checkoutDir, slug, slot, rc, output, beforeMtime)

proc startEvalProcess(checkoutDir: string, cmd: EvalCommand,
    outPath: string): Process =
  createDir(outPath.parentDir)
  var parts = @[quoteShell("make")]
  for a in cmd.args:
    parts.add(quoteShell(a))
  parts.add(">")
  parts.add(quoteShell(outPath))
  parts.add("2>&1")
  startProcess("setsid", workingDir = checkoutDir,
    args = ["/bin/sh", "-c", parts.join(" ")], options = {poUsePath})

proc killEvalProcessGroup(p: Process) =
  let pid = processID(p)
  if pid <= 0:
    return
  discard execShellCmd("kill -KILL -" & $pid &
    " 2>/dev/null || kill -KILL " & $pid & " 2>/dev/null || true")

proc runConcurrentEvals*(checkoutDir: string, lc: LeagueConfig,
    slugs: seq[string], slots: seq[int],
    extraVars: openArray[(string, string)] = []): seq[EvalResult] =
  ## One make per slot, started together. Shared command builder with runEval.
  ## Caller already gated on load; this does not wait again.
  doAssert slugs.len == slots.len
  if slugs.len == 0:
    return

  type Job = object
    p: Process
    slot: int
    slug: string
    before: Time
    outPath: string
    wallTimeout: int

  var befores: seq[Time] = @[]
  var cmds: seq[EvalCommand] = @[]
  var outPaths: seq[string] = @[]
  for slot in slots:
    befores.add(runLogMtime(checkoutDir / runLogRelPath(slot)))
    cmds.add(buildEvalCommand(lc, extraVars, slot))
    outPaths.add(checkoutDir / slotDataPrefix(slot) / "make.out")

  var jobs: seq[Job]
  for i, slot in slots:
    jobs.add(Job(
      p: startEvalProcess(checkoutDir, cmds[i], outPaths[i]),
      slot: slot,
      slug: slugs[i],
      before: befores[i],
      outPath: outPaths[i],
      wallTimeout: cmds[i].wallTimeout,
    ))

  let started = epochTime()
  let limitS = float(jobs[0].wallTimeout + 900)
  for job in jobs:
    let elapsed = epochTime() - started
    var rc = 0
    var timedOut = false
    if not running(job.p):
      rc = job.p.waitForExit(1)
    elif elapsed >= limitS:
      killEvalProcessGroup(job.p)
      rc = job.p.waitForExit(5_000)
      timedOut = true
    else:
      let remaining = max(1, int((limitS - elapsed) * 1000))
      rc = job.p.waitForExit(remaining)
      if epochTime() - started >= limitS:
        killEvalProcessGroup(job.p)
        if running(job.p):
          rc = job.p.waitForExit(5_000)
        timedOut = true
    job.p.close()
    if timedOut:
      result.add(EvalResult(outcome: evalFailed,
        detail: "eval wall timeout — killed process group slot=" & $job.slot))
    else:
      let output = if fileExists(job.outPath): readFile(job.outPath) else: ""
      result.add(collectEvalResult(checkoutDir, job.slug, job.slot, rc,
        output, job.before))

proc agentLeaseCli(root: string): string =
  root / "monofuel-vanilla-wow" / "agents" / "agent_lease.py"

proc evalSlotOwner*(): string =
  ## Lease owner for this conductor process. Same owner on every slot.
  "conductor-" & $getCurrentProcessId()

proc leaseCliUsable*(root: string): bool =
  ## True when the fork lease CLI exists and answers `--help`.
  let cli = agentLeaseCli(root)
  if not fileExists(cli):
    return false
  try:
    let (rc, _) = runCommandCapture(root, cli, @["--help"], timeoutMs = 10_000)
    rc == 0
  except CatchableError:
    false

proc claimEvalSlots*(root: string, want: int, purpose = "eval"): seq[int] =
  ## Non-blocking probe of evalslot-1..3. Never claims slot 0.
  let nWant = max(0, min(want, EvalSlotMax))
  let cli = agentLeaseCli(root)
  if not fileExists(cli) or nWant == 0:
    return
  let owner = evalSlotOwner()
  for n in EvalSlotMin .. EvalSlotMax:
    if result.len >= nWant:
      break
    let (rc, _) = runCommandCapture(root, cli, @[
      "claim", "evalslot-" & $n,
      "--owner", owner,
      "--purpose", purpose,
      "--ttl-minutes", $EvalSlotTtlMinutes,
    ], timeoutMs = 15_000)
    if rc == 0:
      result.add(n)

proc acquireEvalSlots*(root: string, want: int, purpose = "eval"): SlotClaim =
  ## Claim up to `want` slots. Unusable CLI is not the same as busy.
  if not leaseCliUsable(root):
    return SlotClaim(status: claimUnusable)
  let slots = claimEvalSlots(root, want, purpose)
  if slots.len == 0:
    return SlotClaim(status: claimBusy)
  SlotClaim(slots: slots, status: claimReady)

proc claimEvalSlot*(root: string, purpose = "eval"): int =
  ## First free agent slot, or 0 when none are free.
  let got = claimEvalSlots(root, 1, purpose)
  if got.len == 0: 0 else: got[0]

proc refreshEvalSlots*(root: string, slots: openArray[int], purpose = "eval") =
  ## Same-owner re-claim refreshes the 45-min crash-net TTL.
  if slots.len == 0 or not leaseCliUsable(root):
    return
  let cli = agentLeaseCli(root)
  let owner = evalSlotOwner()
  for slot in slots:
    if slot < EvalSlotMin or slot > EvalSlotMax:
      continue
    try:
      let (rc, output) = runCommandCapture(root, cli, @[
        "claim", "evalslot-" & $slot,
        "--owner", owner,
        "--purpose", purpose,
        "--ttl-minutes", $EvalSlotTtlMinutes,
      ], timeoutMs = 15_000)
      if rc != 0:
        echo "conductor: WARN refresh evalslot-", slot, " failed: ",
          output.strip()
    except CatchableError as e:
      echo "conductor: WARN refresh evalslot-", slot, " raised: ", e.msg

proc releaseEvalSlot*(root: string, slot: int) =
  ## Drop this process's lease on evalslot-N. No-op for slot 0 or a missing CLI.
  if slot < EvalSlotMin or slot > EvalSlotMax:
    return
  let cli = agentLeaseCli(root)
  if not fileExists(cli):
    return
  discard runCommandCapture(root, cli, @[
    "release", "evalslot-" & $slot,
    "--owner", evalSlotOwner(),
  ], timeoutMs = 15_000)

proc releaseEvalSlots*(root: string, slots: openArray[int]) =
  ## Release every held agent slot. Each release is isolated so one
  ## failure cannot skip the rest or mask an in-flight exception.
  for slot in slots:
    try:
      releaseEvalSlot(root, slot)
    except CatchableError as e:
      echo "conductor: WARN failed to release evalslot-", slot, ": ", e.msg

proc extraVar(extraVars: openArray[(string, string)], key: string): string =
  for (k, v) in extraVars:
    if k == key:
      return v

proc launchCheckout(root: string, extraVars: openArray[(string, string)]): string =
  result = extraVar(extraVars, "FORK_CLIENT")
  if result.len == 0:
    result = root / "monofuel-vanilla-wow"

proc prewarmLaunchTool*(forkClient: string) =
  ## Serial compile of the player launch tool so a concurrent `nim r`
  ## batch does not share a cold write of the same checkout cache.
  if forkClient.len == 0:
    return
  if not fileExists(forkClient / LaunchToolRel):
    return
  let outBin = getTempDir() / "sa-launch-prewarm-" & $getCurrentProcessId()
  echo "conductor: pre-warming launch tool"
  try:
    let (rc, output) = runCommandCapture(forkClient, "nim",
      @["c", "--hints:off", "--warnings:off", "-o:" & outBin, LaunchToolRel],
      timeoutMs = 600_000)
    if rc != 0:
      echo "conductor: WARN launch-tool prewarm failed rc=", rc, " ",
        output[max(0, output.len - 200) .. ^1]
  except CatchableError as e:
    echo "conductor: WARN launch-tool prewarm raised: ", e.msg
  if fileExists(outBin):
    try:
      removeFile(outBin)
    except OSError:
      discard

proc runEvalSeries*(checkoutDir, root: string, lc: LeagueConfig,
    slugPrefix: string, extraVars: openArray[(string, string)],
    rollTarget: int, purpose: string): EvalResult =
  ## Exactly `rollTarget` valid reports (median) or busy/failed.
  ## Claims slots, refreshes TTL before each roll, releases before return.
  doAssert rollTarget >= 1
  var held: seq[int] = @[]
  defer:
    releaseEvalSlots(root, held)
  if not waitForQuietBox():
    return EvalResult(outcome: evalBusy,
      detail: "box load stayed over the eval cap for 30 min — not rolling")
  var vars: seq[(string, string)] = @[]
  for pair in extraVars:
    vars.add(pair)
  let claim = acquireEvalSlots(root, rollTarget, purpose)
  var serialSlot = 0
  case claim.status
  of claimUnusable:
    echo "conductor: lease CLI unusable — degrading to legacy serial slot 0"
    serialSlot = 0
  of claimBusy:
    return EvalResult(outcome: evalBusy, detail: "no eval slot free")
  of claimReady:
    held = claim.slots
    serialSlot = held[0]

  var reports: seq[JsonNode] = @[]
  var failures: seq[EvalResult] = @[]
  var attempts = 0
  let budget = rollTarget + EvalSeriesRetryBudget

  if held.len >= 2 and reports.len < rollTarget:
    refreshEvalSlots(root, held, purpose)
    prewarmLaunchTool(launchCheckout(root, vars))
    var slugs: seq[string] = @[]
    var batchSlots: seq[int] = @[]
    let n = min(held.len, rollTarget - reports.len)
    for i in 0 ..< n:
      inc attempts
      slugs.add(slugPrefix & "-r" & $attempts)
      batchSlots.add(held[i])
    var slotList = $batchSlots[0]
    for i in 1 ..< batchSlots.len:
      slotList.add(",")
      slotList.add($batchSlots[i])
    echo "conductor: concurrent evals on slots ", slotList
    let batch = runConcurrentEvals(checkoutDir, lc, slugs, batchSlots, vars)
    for item in batch:
      if item.outcome == evalOk:
        reports.add(item.report)
      else:
        failures.add(item)

  while reports.len < rollTarget and attempts < budget:
    inc attempts
    refreshEvalSlots(root, held, purpose)
    echo "conductor: eval roll ", reports.len + 1, "/", rollTarget,
      " (attempt ", attempts, "/", budget, ")"
    let ev = runEval(checkoutDir, lc, slugPrefix & "-r" & $attempts,
      vars, serialSlot, skipLoadWait = true)
    if ev.outcome == evalOk:
      reports.add(ev.report)
    else:
      failures.add(ev)

  var sawFailed = false
  var sawBusy = false
  for item in failures:
    if item.outcome == evalFailed: sawFailed = true
    if item.outcome == evalBusy: sawBusy = true
  let outcome = seriesOutcome(reports.len, rollTarget, sawFailed, sawBusy)
  if outcome != evalOk:
    let detail =
      if failures.len > 0: joinEvalDetails(failures)
      else: "eval series produced " & $reports.len & "/" & $rollTarget &
        " valid reports"
    return EvalResult(outcome: outcome, detail: detail)

  var northings: seq[string] = @[]
  for r in reports:
    northings.add($reportNorthing(r).int)
  EvalResult(outcome: evalOk, report: pickMedianReport(reports),
    detail: "median of " & $reports.len & " rolls: " & northings.join("/"))

proc compareVals(op: string, cand, reference: float): bool =
  case op
  of "<=": cand <= reference
  of ">=": cand >= reference
  of "==": cand == reference
  else: false

proc runGate*(candidate, champion: JsonNode,
    lc: LeagueConfig): tuple[pass: bool, reasons: seq[string]] =
  ## Pure verdict. Champion nil = ledger empty (baseline seeding) — pass.
  result.pass = true
  if champion.isNil:
    result.reasons.add("no champion row — seeding baseline")
    return

  # (a) floor ratchet: the score must never go down.
  let candFloor = jsonNumber(candidate, lc.floorMetric)
  let champFloor = jsonNumber(champion, lc.floorMetric)
  if candFloor.isNone:
    result.pass = false
    result.reasons.add("candidate missing floor metric " & lc.floorMetric)
  elif champFloor.isSome and candFloor.get() < champFloor.get():
    result.pass = false
    result.reasons.add("floor regress: " & lc.floorMetric & " " &
      $candFloor.get() & " < champion " & $champFloor.get())

  # (b) configured assertions. Accumulator axes (perDurationS) compare
  # per-1000-sim-s rates so surviving longer is never itself a failure.
  let candDur = jsonNumber(candidate, "scorecard.duration_s")
  let champDur = jsonNumber(champion, "scorecard.duration_s")
  for a in lc.assertions:
    var cand = jsonNumber(candidate, a.field)
    if cand.isNone:
      result.pass = false
      result.reasons.add("candidate missing " & a.field)
      continue
    var champ = jsonNumber(champion, a.field)
    var suffix = ""
    if a.perDurationS:
      if candDur.isSome and candDur.get() > 0:
        cand = some(cand.get() / candDur.get() * 1000.0)
      if champ.isSome and champDur.isSome and champDur.get() > 0:
        champ = some(champ.get() / champDur.get() * 1000.0)
      suffix = "/ks"
    let reference =
      if a.vsChampion:
        if champ.isSome: champ.get() else: a.value
      else:
        a.value
    if not compareVals(a.op, cand.get(), reference):
      result.pass = false
      result.reasons.add("assert " & a.field & suffix & " " & a.op & " " &
        $reference & " failed (candidate " & $cand.get() & ")")

  # (c) no new warning classes vs the champion run — but only when the
  # floor did not strictly improve. A candidate that pushes further than
  # the champion ever reached will legitimately meet new terrain and its
  # warning classes (extent bias: a champion that died in the bay has
  # pristine land axes for land it never touched). Cop-out protection is
  # preserved where it matters: no floor progress = no new badness.
  let floorImproved = candFloor.isSome and champFloor.isSome and
    candFloor.get() > champFloor.get()
  let newClasses = warningClasses(candidate) - warningClasses(champion)
  for cls in newClasses:
    if floorImproved:
      result.reasons.add("note: new warning class on extended run: " & cls)
    else:
      result.pass = false
      result.reasons.add("new warning class vs champion: " & cls)

  if result.pass:
    result.reasons.add("floor + " & $lc.assertions.len &
      " assertions + warning classes all hold")
