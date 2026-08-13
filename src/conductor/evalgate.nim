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

proc runEval*(checkoutDir: string, lc: LeagueConfig, slug: string,
    extraVars: openArray[(string, string)] = []): EvalResult =
  ## One eval run in checkoutDir. Exit code 2 (flock held / bad bracket
  ## args) and a stale run.log both come back evalBusy — the candidate
  ## is NOT charged for slot contention.
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
  if rc == 2:
    return EvalResult(outcome: evalBusy,
      detail: "make rc=2 (eval lock held or bracket args): " &
        output[max(0, output.len - 300) .. ^1])

  if not fileExists(runLogPath) or
      getLastModificationTime(runLogPath) <= beforeMtime:
    return EvalResult(outcome: evalBusy,
      detail: "run.log not refreshed — lost the slot race, no fresh run")

  # Archive before anything else can truncate it (ticket 0017).
  let archiveDir = checkoutDir / ArchiveRelDir
  createDir(archiveDir)
  let archived = archiveDir / ("run-" &
    now().utc.format("yyyyMMdd-HHmmss") & "-" & slug & ".log")
  copyFile(runLogPath, archived)

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

  # (b) configured assertions.
  for a in lc.assertions:
    let cand = jsonNumber(candidate, a.field)
    if cand.isNone:
      result.pass = false
      result.reasons.add("candidate missing " & a.field)
      continue
    let reference =
      if a.vsChampion:
        let champ = jsonNumber(champion, a.field)
        if champ.isSome: champ.get() else: a.value
      else:
        a.value
    if not compareVals(a.op, cand.get(), reference):
      result.pass = false
      result.reasons.add("assert " & a.field & " " & a.op & " " &
        $reference & " failed (candidate " & $cand.get() & ")")

  # (c) no new warning classes vs the champion run.
  let newClasses = warningClasses(candidate) - warningClasses(champion)
  for cls in newClasses:
    result.pass = false
    result.reasons.add("new warning class vs champion: " & cls)

  if result.pass:
    result.reasons.add("floor + " & $lc.assertions.len &
      " assertions + warning classes all hold")
