## One conductor tick: claim a ticket, let the coder work a branch, hold
## it against the reviewer, the diff guards, the static tests, and the
## code gate — then merge on pass or park on fail. Every decision point
## journals state so a crash resumes instead of forgetting.

import
  std/[json, os, strutils],
  scriptorium/git_ops,
  ./agents,
  ./cfg,
  ./evalgate,
  ./ledger,
  ./state,
  ./tickets

type
  TickOutcome* = enum
    toNoWork = "no-work"
    toMerged = "merged"
    toParked = "parked"
    toStuck = "stuck"
    toBusy = "eval-busy"
    toError = "error"

  TickResult* = object
    outcome*: TickOutcome
    ticketId*: string
    detail*: string
    report*: JsonNode   ## the merged candidate's RunReport (toMerged only)

proc forkClientVar(root: string): (string, string) =
  ("FORK_CLIENT", root / "monofuel-vanilla-wow")

proc pinShas(root, laneDir: string): JsonNode =
  proc sha(dir: string): string =
    let (rc, output) = gitRunCapture(dir, @["rev-parse", "--short=9", "HEAD"])
    if rc == 0: output.strip() else: "unknown"
  %*{"wsa": sha(laneDir), "fork": sha(root / "monofuel-vanilla-wow")}

proc unclaim(root: string, inProgressPath, why: string) =
  discard finishTicket(root, inProgressPath, "open",
    "- conductor unclaimed (" & why & ") — no attempt charged")

proc park(root: string, lc: LeagueConfig, repo: string,
    ticket: TicketRef, inProgressPath, worktree, reason: string,
    report: JsonNode, maxAttempts: int): TickResult =
  ## Gate/review/guard failure: branch stays pushed for autopsy, the
  ## ticket carries the falsification note, the attempt is charged.
  let attempt = conductorAttempts(ticket.content) + 1
  let branch = expBranchName(ticket.id, ticket.slug)
  discard gitCheck(root / lc.repo, "push", "origin", branch)
  let laneDirPath = root / lc.laneCheckout
  appendRow(ledgerPath(laneDirPath, lc.ticketLane),
    makeRow(lc.ticketLane, "parked", ticket.id, branch,
      pinShas(root, laneDirPath),
      (if report.isNil: newJObject() else: report),
      %*{"pass": false, "reasons": [reason]}))
  try:
    commitLedger(laneDirPath, "scores: parked " & ticket.id & " — " & reason)
  except IOError as e:
    echo "conductor: WARN ", e.msg
  let note = "- conductor attempt " & $attempt & ": PARKED — " & reason &
    " (branch " & branch & " pushed for autopsy)"
  let dest = if attempt >= maxAttempts: "stuck" else: "open"
  discard finishTicket(root, inProgressPath, dest, note)
  teardownWorktree(root, lc, worktree, ticket.id, ticket.slug,
    keepBranch = true)
  clearState(repo, lc.ticketLane)
  TickResult(
    outcome: (if dest == "stuck": toStuck else: toParked),
    ticketId: ticket.id, detail: reason)

proc findTicketFile(root, ticketId: string): string =
  ## Repo-relative path of a ticket in any lifecycle dir; "" if absent.
  for stateDir in ["open", "in-progress", "stuck", "done"]:
    for file in walkFiles(root / "tickets" / stateDir / (ticketId & "-*.md")):
      return "tickets/" & stateDir & "/" & file.extractFilename()
  ""

proc runGateBranch*(cfgAll: ConductorConfig,
    leagueName, repo, root, branch, ticketId: string,
    allowProtected = false): TickResult =
  ## Recovery path: run an EXISTING branch (e.g. a preserved parked
  ## candidate) through the same static checks + eval + gate + merge as
  ## a tick. No agents involved; ledger + ticket notes stay honest.
  let lc = cfgAll.league(leagueName)
  let laneDirPath = root / lc.laneCheckout
  let repoDir = root / lc.repo
  let worktree = repoDir / WorktreeRelRoot / ("gate-" & ticketId)
  discard gitCheck(repoDir, "worktree", "remove", "--force", worktree)
  discard gitCheck(repoDir, "worktree", "prune")
  gitRun(repoDir, "worktree", "add", "--force", worktree, branch)
  defer:
    discard gitCheck(repoDir, "worktree", "remove", "--force", worktree)
    discard gitCheck(repoDir, "worktree", "prune")
    forceRemoveDir(worktree)
  let sharedData = root / "local_data"
  if dirExists(sharedData) and not symlinkExists(worktree / "local_data"):
    createSymlink(sharedData, worktree / "local_data")

  let violations = diffGuards(worktree, lc, allowProtected)
  if violations.len > 0:
    return TickResult(outcome: toParked, ticketId: ticketId,
      detail: "diff guards: " & violations.join("; "))
  let (rcLua, outLua) = runCommandCapture(worktree, "make", @["test-lua"],
    timeoutMs = 600_000)
  if rcLua != 0:
    return TickResult(outcome: toParked, ticketId: ticketId,
      detail: "make test-lua failed: " & outLua[max(0, outLua.len - 200) .. ^1])
  echo "conductor: gate-branch full-course eval (several minutes)"
  let eval = runEval(worktree, lc, ticketId & "-gatebranch",
    @[forkClientVar(root)])
  if eval.outcome != evalOk:
    return TickResult(outcome: toBusy, ticketId: ticketId,
      detail: $eval.outcome & ": " & eval.detail)
  let champ = champion(ledgerPath(laneDirPath, leagueName))
  let gate = runGate(eval.report,
    (if champ.isNil: nil else: champ{"report"}), lc)
  if not gate.pass:
    appendRow(ledgerPath(laneDirPath, leagueName),
      makeRow(leagueName, "parked", ticketId, branch,
        pinShas(root, laneDirPath), eval.report,
        %*{"pass": false, "reasons": gate.reasons}))
    try:
      commitLedger(laneDirPath, "scores: gate-branch parked " & ticketId)
    except IOError as e:
      echo "conductor: WARN ", e.msg
    return TickResult(outcome: toParked, ticketId: ticketId,
      detail: gate.reasons.join("; "))
  let (rcRebase, outRebase) = gitRunCapture(worktree,
    @["rebase", lc.laneBranch], timeoutMs = 120_000)
  if rcRebase != 0:
    discard gitCheck(worktree, "rebase", "--abort")
    return TickResult(outcome: toParked, ticketId: ticketId,
      detail: "rebase failed: " & outRebase[max(0, outRebase.len - 200) .. ^1])
  var (rcMerge, outMerge) = gitRunCapture(laneDirPath,
    @["merge", "--ff-only", branch], timeoutMs = 60_000)
  if rcMerge != 0:
    (rcMerge, outMerge) = gitRunCapture(laneDirPath,
      @["merge", "--no-ff", branch, "-m",
        "conductor: gate-branch merge " & branch], timeoutMs = 60_000)
  if rcMerge != 0:
    discard gitCheck(laneDirPath, "merge", "--abort")
    return TickResult(outcome: toParked, ticketId: ticketId,
      detail: "merge failed: " & outMerge[max(0, outMerge.len - 200) .. ^1])
  appendRow(ledgerPath(laneDirPath, leagueName),
    makeRow(leagueName, "merged", ticketId, branch,
      pinShas(root, laneDirPath), eval.report,
      %*{"pass": true, "reasons": gate.reasons}))
  try:
    commitLedger(laneDirPath, "scores: " & leagueName & " gate-branch merged " &
      ticketId & " — northing " & $eval.report{"max_northing"}.getFloat())
  except IOError as e:
    echo "conductor: WARN ", e.msg
  discard gitRunCapture(laneDirPath, @["push"], timeoutMs = 120_000)
  let ticketPath = findTicketFile(root, ticketId)
  if ticketPath.len > 0:
    discard finishTicket(root, ticketPath, "done",
      "- conductor: gate-branch MERGED " & branch & " to " & lc.laneBranch &
      " — gate: " & gate.reasons.join("; ") & "; northing " &
      $eval.report{"max_northing"}.getFloat())
  TickResult(outcome: toMerged, ticketId: ticketId,
    detail: "northing " & $eval.report{"max_northing"}.getFloat(),
    report: eval.report)

proc recoverCrashedTick*(cfgAll: ConductorConfig,
    leagueName, repo, root: string): bool =
  ## A non-idle state at loop entry means a previous tick died mid-way.
  ## Unwind honestly: ticket back to open (no attempt charged), worktree
  ## torn down (branch kept for autopsy), state cleared. Returns true
  ## when something was recovered.
  let st = loadState(repo)
  if st.phase == tpIdle:
    return false
  echo "conductor: recovering crashed tick — phase ", $st.phase,
    ", ticket ", st.ticketId
  let lc = cfgAll.league(leagueName)
  if st.ticketPath.len > 0 and fileExists(root / st.ticketPath):
    discard finishTicket(root, st.ticketPath, "open",
      "- conductor: restarted mid-tick (phase " & $st.phase &
      ") — unwound, no attempt charged")
  if st.worktree.len > 0 and dirExists(st.worktree):
    var slug = ""
    let prefix = "monofuel/exp-" & st.ticketId & "-"
    if st.branch.startsWith(prefix):
      slug = st.branch[prefix.len .. ^1]
    teardownWorktree(root, lc, st.worktree, st.ticketId, slug,
      keepBranch = true)
  clearState(repo, leagueName)
  true

proc runTick*(cfgAll: ConductorConfig, leagueName, repo, root: string): TickResult =
  let lc = cfgAll.league(leagueName)
  let laneDirPath = root / lc.laneCheckout

  # 1. Find + claim work.
  let ticket = nextOpenTicket(root, lc.ticketLane)
  if ticket.id.len == 0:
    return TickResult(outcome: toNoWork, detail: "no eligible open tickets")
  if conductorAttempts(ticket.content) >= cfgAll.maxAttemptsPerTicket:
    let moved = claimTicket(root, ticket)
    discard finishTicket(root, moved, "stuck",
      "- conductor: attempt budget exhausted (" &
      $cfgAll.maxAttemptsPerTicket & ") — parking in stuck/")
    return TickResult(outcome: toStuck, ticketId: ticket.id,
      detail: "attempt budget exhausted")
  let inProgressPath = claimTicket(root, ticket)
  saveState(repo, ConductorState(league: leagueName, phase: tpTicketClaimed,
    ticketId: ticket.id, ticketPath: inProgressPath))
  echo "conductor: claimed ", ticket.id, " (", ticket.slug, ")"

  # 2. Worktree on a fresh exp branch.
  let worktree = setupWorktree(root, lc, ticket.id, ticket.slug)
  saveState(repo, ConductorState(league: leagueName, phase: tpCoding,
    ticketId: ticket.id, ticketPath: inProgressPath, worktree: worktree,
    branch: expBranchName(ticket.id, ticket.slug)))

  # 3. Code -> guards -> review, with one revision round on BLOCK.
  var coderSummary = ""
  var feedback = ""
  var reviewed = false
  for round in 1 .. 2:
    echo "conductor: coding agent round ", round
    let coded = runCodingAgent(cfgAll, lc, worktree, ticket.id,
      ticket.content, feedback, round)
    if not coded.ok:
      return park(root, lc, repo, ticket, inProgressPath, worktree,
        "coding agent failed: " & coded.summary, nil,
        cfgAll.maxAttemptsPerTicket)
    coderSummary = coded.summary
    let violations = diffGuards(worktree, lc)
    if violations.len > 0:
      return park(root, lc, repo, ticket, inProgressPath, worktree,
        "diff guards: " & violations.join("; "), nil,
        cfgAll.maxAttemptsPerTicket)
    saveState(repo, ConductorState(league: leagueName, phase: tpReview,
      ticketId: ticket.id, ticketPath: inProgressPath, worktree: worktree,
      branch: expBranchName(ticket.id, ticket.slug), attempt: round))
    echo "conductor: reviewer round ", round
    let verdict = runReviewer(cfgAll, lc, worktree, ticket.id,
      ticket.content, coderSummary)
    if verdict.ship:
      reviewed = true
      break
    feedback = verdict.reason
    echo "conductor: reviewer BLOCK — ", verdict.reason
  if not reviewed:
    return park(root, lc, repo, ticket, inProgressPath, worktree,
      "reviewer blocked twice: " & feedback, nil, cfgAll.maxAttemptsPerTicket)

  # 4. Static tests in the worktree (path-safe tiers only; nim smoke
  # runs against the main checkout's sibling layout, not from here).
  let (rcLua, outLua) = runCommandCapture(worktree, "make", @["test-lua"],
    timeoutMs = 600_000)
  if rcLua != 0:
    return park(root, lc, repo, ticket, inProgressPath, worktree,
      "make test-lua failed: " & outLua[max(0, outLua.len - 300) .. ^1],
      nil, cfgAll.maxAttemptsPerTicket)

  # 5. Eval gate: optional failure-site repro bracket first, then the
  # full-course run against the champion. Tooling-only candidates (no
  # lua/ behavior files) skip the eval — they cannot move it, and
  # demanding a champion-beating roll from them is a dice tax.
  saveState(repo, ConductorState(league: leagueName, phase: tpGate,
    ticketId: ticket.id, ticketPath: inProgressPath, worktree: worktree,
    branch: expBranchName(ticket.id, ticket.slug)))
  let toolingOnly = not isBehaviorChange(changedFiles(worktree, lc))
  var candReport = %*{"tooling_only": true}
  var gateReasons = @["tooling-only diff: tests + review + guards " &
    "(eval skipped — no lua/ behavior files touched)"]
  if toolingOnly:
    echo "conductor: tooling-only diff — eval skipped"
  else:
    let reproVars = parseRepro(ticket.content)
    if reproVars.len > 0:
      echo "conductor: repro bracket ", ticket.content.parseTicketField("Repro")
      let repro = runEval(worktree, lc, ticket.id & "-repro",
        reproVars & @[forkClientVar(root)])
      case repro.outcome
      of evalBusy:
        unclaim(root, inProgressPath, "eval slot busy at repro: " & repro.detail)
        teardownWorktree(root, lc, worktree, ticket.id, ticket.slug, false)
        clearState(repo, leagueName)
        return TickResult(outcome: toBusy, ticketId: ticket.id,
          detail: repro.detail)
      of evalFailed:
        return park(root, lc, repo, ticket, inProgressPath, worktree,
          "repro bracket harness failure: " & repro.detail, nil,
          cfgAll.maxAttemptsPerTicket)
      of evalOk:
        if not repro.report{"ok"}.getBool():
          return park(root, lc, repo, ticket, inProgressPath, worktree,
            "repro bracket still failing: " &
            repro.report{"reason"}.getStr("no reason"), repro.report,
            cfgAll.maxAttemptsPerTicket)
    echo "conductor: full-course eval (several minutes)"
    let eval = runEval(worktree, lc, ticket.id, @[forkClientVar(root)])
    case eval.outcome
    of evalBusy:
      unclaim(root, inProgressPath, "eval slot busy: " & eval.detail)
      teardownWorktree(root, lc, worktree, ticket.id, ticket.slug, false)
      clearState(repo, leagueName)
      return TickResult(outcome: toBusy, ticketId: ticket.id,
        detail: eval.detail)
    of evalFailed:
      flagNeedsHuman(repo, "eval harness failure on " & ticket.id & ": " &
        eval.detail)
      unclaim(root, inProgressPath, "eval harness failure: " & eval.detail)
      teardownWorktree(root, lc, worktree, ticket.id, ticket.slug, false)
      clearState(repo, leagueName)
      return TickResult(outcome: toError, ticketId: ticket.id,
        detail: eval.detail)
    of evalOk:
      discard

    let champ = champion(ledgerPath(laneDirPath, leagueName))
    let champReport = if champ.isNil: nil else: champ{"report"}
    let gate = runGate(eval.report, champReport, lc)
    if not gate.pass:
      return park(root, lc, repo, ticket, inProgressPath, worktree,
        gate.reasons.join("; "), eval.report, cfgAll.maxAttemptsPerTicket)
    candReport = eval.report
    gateReasons = gate.reasons

  # 6. Merge to the lane: rebase the branch, then ff-only with a no-ff
  # fallback, ledger row, ticket -> done, prune.
  saveState(repo, ConductorState(league: leagueName, phase: tpMerge,
    ticketId: ticket.id, ticketPath: inProgressPath, worktree: worktree,
    branch: expBranchName(ticket.id, ticket.slug)))
  let branch = expBranchName(ticket.id, ticket.slug)
  let (rcRebase, outRebase) = gitRunCapture(worktree,
    @["rebase", lc.laneBranch], timeoutMs = 120_000)
  if rcRebase != 0:
    discard gitCheck(worktree, "rebase", "--abort")
    return park(root, lc, repo, ticket, inProgressPath, worktree,
      "rebase onto " & lc.laneBranch & " failed: " &
      outRebase[max(0, outRebase.len - 200) .. ^1], candReport,
      cfgAll.maxAttemptsPerTicket)
  var (rcMerge, outMerge) = gitRunCapture(laneDirPath,
    @["merge", "--ff-only", branch], timeoutMs = 60_000)
  if rcMerge != 0:
    (rcMerge, outMerge) = gitRunCapture(laneDirPath,
      @["merge", "--no-ff", branch, "-m",
        "conductor: merge " & branch & " (gate passed)"], timeoutMs = 60_000)
  if rcMerge != 0:
    discard gitCheck(laneDirPath, "merge", "--abort")
    return park(root, lc, repo, ticket, inProgressPath, worktree,
      "merge into " & lc.laneBranch & " failed: " &
      outMerge[max(0, outMerge.len - 200) .. ^1], candReport,
      cfgAll.maxAttemptsPerTicket)
  appendRow(ledgerPath(laneDirPath, leagueName),
    makeRow(leagueName, "merged", ticket.id, branch,
      pinShas(root, laneDirPath), candReport,
      %*{"pass": true, "reasons": gateReasons}))
  try:
    commitLedger(laneDirPath, "scores: " & leagueName & " merged " &
      ticket.id & (if toolingOnly: " (tooling-only)" else: " — northing " &
      $candReport{"max_northing"}.getFloat()))
  except IOError as e:
    echo "conductor: WARN ", e.msg
  let (rcPush, outPush) = gitRunCapture(laneDirPath, @["push"],
    timeoutMs = 120_000)
  if rcPush != 0:
    echo "conductor: WARN lane push failed: ",
      outPush.strip().splitLines()[^1]
  discard finishTicket(root, inProgressPath, "done",
    "- conductor: MERGED to " & lc.laneBranch & " (" & branch &
    ") — gate: " & gateReasons.join("; ") &
    (if toolingOnly: "" else: "; northing " &
      $candReport{"max_northing"}.getFloat()))
  teardownWorktree(root, lc, worktree, ticket.id, ticket.slug,
    keepBranch = false)
  clearState(repo, leagueName)
  TickResult(outcome: toMerged, ticketId: ticket.id,
    detail: (if toolingOnly: "tooling-only merge" else:
      "northing " & $candReport{"max_northing"}.getFloat()),
    report: (if toolingOnly: nil else: candReport))
