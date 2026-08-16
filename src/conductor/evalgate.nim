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
  std/[json, options, os, sets, strutils, tables, times],
  scriptorium/git_ops,
  ./cfg

const
  # Kalimdor race scoring line (tools/pack_traverse_replay.sh:115).
  GoalX = 6687.333052
  StartX = -9187.0
  RunLogRelPath = "local_data/traverse-status/run.log"
  SegmentResultRelPath = "local_data/traverse-segment-result.json"
  ArchiveRelDir = "local_data/traverse-status/archive"

type
  EvalOutcome* = enum
    evalOk        ## a fresh run happened; report is valid (bot may still have died)
    evalBusy      ## eval slot held elsewhere / no fresh run — retry later
    evalFailed    ## harness problem: no parseable result from a fresh run

  EvalResult* = object
    outcome*: EvalOutcome
    report*: JsonNode
    detail*: string

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

proc waitForQuietBox(capEnv = "CONDUCTOR_EVAL_LOAD_CAP"): bool =
  ## Scores rolled on a loaded box are noise, not verdicts (0070's 8,380
  ## park and the 0072 park both rolled at load 40+ next to navmesh
  ## bakes). Hold the eval until 1-min load is under the cap, bounded so
  ## a stuck storm degrades to evalBusy (uncharged) instead of wedging.
  let cap = try: parseFloat(getEnv(capEnv, "20")) except ValueError: 20.0
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

proc runEval*(checkoutDir: string, lc: LeagueConfig, slug: string,
    extraVars: openArray[(string, string)] = []): EvalResult =
  ## One eval run in checkoutDir. Exit code 2 (flock held / bad bracket
  ## args) and a stale run.log both come back evalBusy — the candidate
  ## is NOT charged for slot contention.
  if not waitForQuietBox():
    return EvalResult(outcome: evalBusy,
      detail: "box load stayed over the eval cap for 30 min — not rolling")
  let runLogPath = checkoutDir / RunLogRelPath
  let beforeMtime =
    if fileExists(runLogPath): getLastModificationTime(runLogPath)
    else: fromUnix(0)

  var args = @[lc.evalMake.target]
  var wallTimeout = 2700
  for key, value in lc.evalMake.vars:
    args.add(key & "=" & value)
    if key == "END_TIMEOUT":
      wallTimeout = try: parseInt(value) except ValueError: 2700
  for (key, value) in extraVars:
    args.add(key & "=" & value)

  let (rc, output) = runCommandCapture(checkoutDir, "make", args,
    timeoutMs = (wallTimeout + 900) * 1000)
  # GNU make exits 2 for ANY failing recipe, so the exit code cannot
  # distinguish "flock held" from "waiter verdict not-ok" (rc=1 inside
  # the recipe — NORMAL while no run reaches the end checkpoint). Decide
  # by evidence: the lock message, then run.log freshness.
  if "another live Traverse run owns" in output:
    return EvalResult(outcome: evalBusy,
      detail: "eval flock held by another live run")

  if not fileExists(runLogPath) or
      getLastModificationTime(runLogPath) <= beforeMtime:
    return EvalResult(outcome: evalBusy,
      detail: "run.log not refreshed — lost the slot race, no fresh run" &
        " (make rc=" & $rc & ")")

  # Archive before anything else can truncate it (ticket 0017). Store
  # the symlink-resolved path — worktree-relative paths die at teardown.
  let archiveDir = checkoutDir / ArchiveRelDir
  createDir(archiveDir)
  var archived = archiveDir / ("run-" &
    now().utc.format("yyyyMMdd-HHmmss") & "-" & slug & ".log")
  copyFile(runLogPath, archived)
  archived = try: expandFilename(archived) except OSError: archived

  if countFlightSamples(archived) == 0:
    return EvalResult(outcome: evalFailed,
      detail: "fresh run produced zero FLIGHT telemetry — client/server " &
        "prep failure, not a candidate result (log: " & archived & ")")

  let segmentPath = checkoutDir / SegmentResultRelPath
  var report: JsonNode
  if fileExists(segmentPath):
    try:
      report = parseJson(readFile(segmentPath))
    except CatchableError:
      report = nil
  if report.isNil or report.kind != JObject:
    return EvalResult(outcome: evalFailed,
      detail: "fresh run but no parseable " & SegmentResultRelPath &
        " (make rc=" & $rc & ")")

  report["max_northing"] = %computeMaxNorthing(archived)
  report["archived_log"] = %archived
  report["make_rc"] = %rc
  EvalResult(outcome: evalOk, report: report)

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
