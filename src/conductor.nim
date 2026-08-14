# Conductor — automated autoresearch loop over the league lanes.
#
# A dumb, reliable Nim process drives the loop; LLM agents are fallible
# subprocess workers inside it (scriptorium harnesses). The merge gate is
# pure code — floor ratchet + assertions vs the champion run — and the
# reviewer agent can only reject, never approve past a failing gate.
#
#   nim r src/conductor.nim <league> <once|run|status|baseline|hosted|gate>
#
# Config: <wow-coworld root>/conductor.json.  Design: docs/conductor.md.

import
  std/[json, os, sequtils, sets, strutils, tables],
  scriptorium/git_ops,
  conductor/cfg,
  conductor/evalgate,
  conductor/ledger,
  conductor/shiplib,
  conductor/state,
  conductor/tick

proc usage() =
  echo "usage: conductor <league> <command>"
  echo "commands:"
  echo "  status    show config, state, pause/needs-human flags"
  echo "  baseline  evaluate lane HEAD and seed the score ledger"
  echo "  hosted    ingest hosted episode scores into the hosted ledger"
  echo "  once      run a single tick (ticket -> agent -> gate -> merge)"
  echo "  run       daemon loop (single instance, pause via .conductor/pause)"
  echo "  gate      re-run the gate for the current in-flight candidate"
  echo "  ship [guard-uuid]  manual ship of the champion (guard required"
  echo "            for the first ship, taken from the ledger afterwards)"
  quit 1

proc repoRoot(): string =
  ## The wow-shadow-army checkout conductor runs from.
  result = getEnv("CONDUCTOR_REPO", getCurrentDir())
  if not dirExists(result / ".git") and not fileExists(result / ".git"):
    quit "conductor: " & result & " is not a git checkout (set CONDUCTOR_REPO)"

proc monorepoRoot(repo: string): string =
  getEnv("CONDUCTOR_ROOT", repo.parentDir)

proc laneDir(root: string, lc: LeagueConfig): string =
  result = root / lc.laneCheckout
  if lc.laneCheckout.len == 0 or not dirExists(result):
    quit "conductor: laneCheckout '" & lc.laneCheckout &
      "' not found under " & root
  let (rc, branch) = gitRunCapture(result, @["rev-parse", "--abbrev-ref", "HEAD"])
  if rc != 0 or branch.strip() != lc.laneBranch:
    quit "conductor: " & result & " is on '" & branch.strip() &
      "', expected lane branch '" & lc.laneBranch & "'"

proc headSha(dir: string): string =
  let (rc, output) = gitRunCapture(dir, @["rev-parse", "--short=9", "HEAD"])
  if rc == 0: output.strip() else: "unknown"

proc pinShas(root, lane: string): JsonNode =
  %*{"wsa": headSha(lane), "fork": headSha(root / "monofuel-vanilla-wow")}

proc reportSummary(report: JsonNode): string =
  "northing=" & $report{"max_northing"}.getFloat() &
    " ok=" & $report{"ok"}.getBool() &
    " deaths=" & $report{"deaths"}.getInt() &
    " warnings=" & $warningClasses(report).len

proc cmdStatus(cfgAll: ConductorConfig, leagueName, repo, root: string) =
  let lc = cfgAll.league(leagueName)
  echo "conductor status — league: ", leagueName
  echo "  lane branch:   ", lc.laneBranch, " (checkout ", lc.laneCheckout, ")"
  echo "  eval:          make ", lc.evalMake.target, " (",
    lc.evalMake.vars.len, " vars)"
  echo "  floor metric:  ", lc.floorMetric
  echo "  assertions:    ", lc.assertions.len
  echo "  auto-ship:     ", lc.ship.auto
  echo "  coding agent:  ", $cfgAll.agents.coding.harness, " / ",
    cfgAll.agents.coding.model
  echo "  review agent:  ", $cfgAll.agents.reviewer.harness, " / ",
    cfgAll.agents.reviewer.model
  let champ = champion(ledgerPath(root / lc.laneCheckout, leagueName))
  if champ.isNil:
    echo "  champion:      (none — run `conductor ", leagueName, " baseline`)"
  else:
    echo "  champion:      ", reportSummary(champ{"report"}),
      " [", champ{"action"}.getStr(), " ", champ{"ts"}.getStr(), "]"
  let st = loadState(repo)
  echo "  tick phase:    ", $st.phase,
    (if st.ticketId.len > 0: " (ticket " & st.ticketId & ")" else: "")
  echo "  paused:        ", isPaused(repo)
  if fileExists(needsHumanPath(repo)):
    echo "  NEEDS-HUMAN:"
    for line in readFile(needsHumanPath(repo)).strip().splitLines():
      echo "    ", line

proc cmdBaseline(cfgAll: ConductorConfig, leagueName, root: string) =
  let lc = cfgAll.league(leagueName)
  let lane = laneDir(root, lc)
  echo "conductor: baseline eval of ", lc.laneBranch, " HEAD (",
    headSha(lane), ") — this takes several minutes"
  let res = runEval(lane, lc, "baseline")
  case res.outcome
  of evalBusy:
    quit "conductor: eval slot busy — " & res.detail
  of evalFailed:
    quit "conductor: eval failed — " & res.detail
  of evalOk:
    let path = ledgerPath(lane, leagueName)
    appendRow(path, makeRow(leagueName, "baseline", "", lc.laneBranch,
      pinShas(root, lane), res.report,
      %*{"pass": true, "reasons": ["baseline seed"]}))
    commitLedger(lane,
      "scores: " & leagueName & " baseline — " &
      reportSummary(res.report) & "\n\nCo-Authored-By: conductor")
    echo "conductor: baseline row appended — ", reportSummary(res.report)
    echo "conductor: archived log ", res.report{"archived_log"}.getStr()

proc ingestHosted(cfgAll: ConductorConfig, leagueName, root: string) =
  ## Pull hosted episodes (make traverse-field has its own flock and
  ## exits 0 when busy) and append one summary row when new data landed.
  ## Raises on harness trouble — the daemon logs and moves on.
  let lc = cfgAll.league(leagueName)
  let lane = laneDir(root, lc)
  # pull_traverse_field.sh resolves the coworld CLI via COWORLD_BIN ->
  # PATH -> a crewrift bots repo that this machine lacks; point it at
  # the fork's venv, which is how every other coworld call runs here.
  let coworldBin = root / "monofuel-vanilla-wow" / ".venv" / "bin" / "coworld"
  let (rc, output) =
    if fileExists(coworldBin):
      runCommandCapture(lane, "env",
        @["COWORLD_BIN=" & coworldBin, "make", "traverse-field"],
        timeoutMs = 300_000)
    else:
      runCommandCapture(lane, "make", @["traverse-field"],
        timeoutMs = 300_000)
  if rc != 0:
    raise newException(IOError, "make traverse-field failed rc=" & $rc &
      ": " & output[max(0, output.len - 400) .. ^1])
  let historyPath = lane / "local_data/traverse/episodes_history.json"
  if not fileExists(historyPath):
    raise newException(IOError, "no " & historyPath & " after traverse-field")
  var scores: seq[float]
  var newest = ""
  var newestCreated = ""
  let history = parseJson(readFile(historyPath))
  let entries =
    if history.kind == JArray: history
    else: history{"entries"}
  if entries.isNil or entries.kind != JArray:
    raise newException(ValueError,
      "episodes_history.json has no entries array")
  for e in entries:
    if e{"status"}.getStr() != "completed":
      continue
    let scoresNode = e{"scores"}
    if scoresNode.isNil or scoresNode.kind != JArray or scoresNode.len == 0:
      continue
    scores.add(scoresNode[0]{"score"}.getFloat())
    let created = e{"created_at"}.getStr()
    if created > newestCreated:
      newestCreated = created
      newest = e{"id"}.getStr()
  if scores.len == 0:
    echo "conductor: hosted — no completed scored episodes yet"
    return
  let hostedPath = hostedLedgerPath(lane, leagueName)
  let rows = readRows(hostedPath)
  if rows.len > 0 and rows[^1]{"newest"}.getStr() == newest:
    echo "conductor: hosted — no new episodes since ", newest
    return
  var floor = scores[0]
  var best = scores[0]
  var total = 0.0
  for s in scores:
    floor = min(floor, s)
    best = max(best, s)
    total += s
  let summary = %*{
    "ts": ledgerNowUtc(),
    "league": leagueName,
    "action": "hosted",
    "newest": newest,
    "episodes": scores.len,
    "floor": floor,
    "mean": total / float(scores.len),
    "best": best,
  }
  appendRow(hostedPath, summary)
  commitLedger(lane,
    "scores: " & leagueName & " hosted ingest — floor " & $floor &
    " mean " & $(total / float(scores.len)) & " best " & $best &
    " over " & $scores.len & " episodes\n\nCo-Authored-By: conductor")
  echo "conductor: hosted — ", scores.len, " episodes, floor ", floor,
    ", mean ", total / float(scores.len), ", best ", best
  let champ = champion(ledgerPath(lane, leagueName))
  if not champ.isNil:
    let localFloor = champ{"report", "max_northing"}.getFloat()
    if localFloor > 0 and floor < localFloor * 0.5:
      echo "conductor: WARN hosted floor ", floor,
        " << local champion northing ", localFloor,
        " — PETREL_SWIM-class divergence, autopsy the hosted replays"

proc cmdRun(leagueName, repo, root: string) =
  ## The daemon: forever { recover -> tick -> pace }. Agent/harness
  ## failures (5xx, timeouts, flock races) are consumed by attempts and
  ## this try — the loop itself never dies from them. Pause by touching
  ## .conductor/pause; stop with SIGTERM (systemd) or ctrl-c.
  if not acquirePidGuard(repo):
    quit "conductor: another conductor owns " &
      conductorDir(repo) / "conductor.pid"
  echo "conductor: daemon up — league ", leagueName,
    "; pause file: ", pausePath(repo)
  var backoff = 30
  var pausedLogged = false
  try:
    while true:
      try:
        let cfgAll = loadConductorConfig(root)
        if leagueName notin cfgAll.leagues:
          raise newException(ValueError,
            "league '" & leagueName & "' missing from conductor.json")
        if isPaused(repo):
          if not pausedLogged:
            echo "conductor: paused — remove ", pausePath(repo), " to resume"
            pausedLogged = true
          sleep(60_000)
          continue
        pausedLogged = false
        discard recoverCrashedTick(cfgAll, leagueName, repo, root)
        let res = runTick(cfgAll, leagueName, repo, root)
        echo "conductor: tick — ", $res.outcome,
          (if res.ticketId.len > 0: " (ticket " & res.ticketId & ")" else: ""),
          (if res.detail.len > 0: ": " & res.detail else: "")
        backoff = 30
        case res.outcome
        of toNoWork:
          try:
            ingestHosted(cfgAll, leagueName, root)
          except CatchableError as e:
            echo "conductor: WARN hosted ingest: ", e.msg
          sleep(600_000)
        of toBusy:
          sleep(max(30, cfgAll.evalLockRetrySeconds) * 1000)
        of toMerged:
          if not res.report.isNil:
            let ship = maybeShip(root, cfgAll.league(leagueName), repo,
              root / cfgAll.league(leagueName).laneCheckout, res.report)
            echo "conductor: ship — ",
              (if ship.shipped: "SHIPPED " else: "held: "), ship.detail
          sleep(30_000)
        else:
          sleep(60_000)
      except CatchableError as e:
        echo "conductor: tick EXCEPTION — ", e.msg,
          " (backing off ", backoff, "s)"
        sleep(backoff * 1000)
        backoff = min(backoff * 2, 600)
  finally:
    releasePidGuard(repo)

proc main() =
  if paramCount() < 2:
    usage()
  let leagueName = paramStr(1)
  let command = paramStr(2)
  let repo = repoRoot()
  let root = monorepoRoot(repo)
  let cfgAll = loadConductorConfig(root)
  if leagueName notin cfgAll.leagues:
    quit "conductor: unknown league '" & leagueName & "' — configured: " &
      toSeq(cfgAll.leagues.keys).join(", ")
  case command
  of "status":
    cmdStatus(cfgAll, leagueName, repo, root)
  of "baseline":
    cmdBaseline(cfgAll, leagueName, root)
  of "hosted":
    ingestHosted(cfgAll, leagueName, root)
  of "once":
    # A stale non-idle state is a killed/crashed tick; unwind it the
    # same way the daemon does (ticket back to open uncharged) instead
    # of demanding manual state surgery.
    discard recoverCrashedTick(cfgAll, leagueName, repo, root)
    let st = loadState(repo)
    if st.phase != tpIdle:
      quit "conductor: a tick is already in flight (phase " & $st.phase &
        ", ticket " & st.ticketId & ") — finish or clear .conductor/state.json"
    if isPaused(repo):
      quit "conductor: paused (" & pausePath(repo) & " exists)"
    let res = runTick(cfgAll, leagueName, repo, root)
    echo "conductor: tick outcome — ", $res.outcome,
      (if res.ticketId.len > 0: " (ticket " & res.ticketId & ")" else: ""),
      (if res.detail.len > 0: ": " & res.detail else: "")
    # once-chained operation ships after gated merges just like the daemon.
    if res.outcome == toMerged and not res.report.isNil:
      let ship = maybeShip(root, cfgAll.league(leagueName), repo,
        root / cfgAll.league(leagueName).laneCheckout, res.report)
      echo "conductor: ship — ",
        (if ship.shipped: "SHIPPED " else: "held: "), ship.detail
  of "gate":
    let st = loadState(repo)
    if st.worktree.len == 0 or not dirExists(st.worktree):
      quit "conductor: no in-flight worktree in state — nothing to gate"
    let lc = cfgAll.league(leagueName)
    echo "conductor: fresh eval of in-flight candidate ", st.branch
    let res = runEval(st.worktree, lc, st.ticketId & "-regate",
      @[("FORK_CLIENT", root / "monofuel-vanilla-wow")])
    if res.outcome != evalOk:
      quit "conductor: eval " & $res.outcome & " — " & res.detail
    let champ = champion(ledgerPath(root / lc.laneCheckout, leagueName))
    let verdict = runGate(res.report,
      (if champ.isNil: nil else: champ{"report"}), lc)
    echo "conductor: gate ", (if verdict.pass: "PASS" else: "FAIL")
    for reason in verdict.reasons:
      echo "  - ", reason
  of "run":
    cmdRun(leagueName, repo, root)
  of "gate-branch":
    if paramCount() < 4:
      quit "usage: conductor <league> gate-branch <branch> <ticketId>" &
        " [--allow-protected]"
    let allowProtected = paramCount() >= 5 and
      paramStr(5) == "--allow-protected"
    let res = runGateBranch(cfgAll, leagueName, repo, root,
      paramStr(3), paramStr(4), allowProtected)
    echo "conductor: gate-branch — ", $res.outcome,
      (if res.detail.len > 0: ": " & res.detail else: "")
    if res.outcome != toMerged:
      quit 1
  of "ship":
    let lc = cfgAll.league(leagueName)
    let lane = laneDir(root, lc)
    let champ = champion(ledgerPath(lane, leagueName))
    if champ.isNil:
      quit "conductor: no champion row — baseline or merge something first"
    let deaths = openDeathTickets(root, lc.ticketLane)
    if deaths.len > 0:
      # Best-of leaderboards cannot go down, so a fragile ship is pure
      # upside there; monofuel may override the death-ticket block
      # explicitly (2026-08-14 ruling for the race board).
      if getEnv("CONDUCTOR_SHIP_OVERRIDE_DEATHS") == "1":
        echo "conductor: WARN shipping past open severity-death tickets (",
          deaths.join(", "), ") — explicit override"
      else:
        quit "conductor: refusing to ship with open severity-death tickets: " &
          deaths.join(", ") & " (CONDUCTOR_SHIP_OVERRIDE_DEATHS=1 to override)"
    let guardArg = if paramCount() >= 3: paramStr(3) else: ""
    if guardArg.len == 0:
      # Full ratchet path — requires a last-shipped row.
      let (ok, why) = shipRatchet(root, lc, lane, champ{"report"})
      if not ok:
        quit "conductor: ship ratchet held: " & why
    echo "conductor: manual ship of champion (", champ{"ts"}.getStr(), ")"
    let outcome = executeShip(root, lc, repo, lane, champ{"report"}, guardArg)
    if outcome.shipped:
      echo "conductor: SHIPPED — ", outcome.detail
    else:
      quit "conductor: ship failed — " & outcome.detail
  else:
    usage()

when isMainModule:
  main()
