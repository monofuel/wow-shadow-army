## Worktree lifecycle + the two LLM workers (coder, reviewer) + the
## structural diff guards. Agents are fallible subprocesses run through
## scriptorium's agent_runner (timeouts + retries inside); everything
## that decides anything here is plain code.

import
  std/[os, strutils],
  scriptorium/agent_runner,
  scriptorium/config as sconfig,
  scriptorium/git_ops,
  scriptorium/prompt_catalog,
  ./cfg

const
  CodingAgentTemplate = staticRead("prompts/coding_agent.md")
  ReviewAgentTemplate = staticRead("prompts/review_agent.md")
  WorktreeRelRoot* = ".conductor/worktrees"

type ReviewVerdict* = object
  ship*: bool
  reason*: string

proc expBranchName*(ticketId, slug: string): string =
  "monofuel/exp-" & ticketId & "-" & slug

proc worktreePath*(repoDir, ticketId, slug: string): string =
  repoDir / WorktreeRelRoot / (ticketId & "-" & slug)

proc setupWorktree*(root: string, lc: LeagueConfig,
    ticketId, slug: string): string =
  ## Fresh worktree on a fresh exp branch off the lane branch, with the
  ## shared local_data symlinked in (every checkout's convention).
  let repoDir = root / lc.repo
  let branch = expBranchName(ticketId, slug)
  result = worktreePath(repoDir, ticketId, slug)
  if dirExists(result):
    discard gitCheck(repoDir, "worktree", "remove", "--force", result)
    forceRemoveDir(result)
  discard gitCheck(repoDir, "worktree", "prune")
  discard gitCheck(repoDir, "branch", "-D", branch)
  createDir(result.parentDir)
  gitRun(repoDir, "worktree", "add", "-b", branch, result, lc.laneBranch)
  let sharedData = root / "local_data"
  if dirExists(sharedData) and not symlinkExists(result / "local_data"):
    createSymlink(sharedData, result / "local_data")
  # The Makefile resolves sibling checkouts relative to CURDIR
  # (UPSTREAM := ../coworld-vanilla-wow, FORK_CLIENT := ../monofuel-
  # vanilla-wow); from a nested worktree those walks land inside
  # .conductor/worktrees/. Symlink the real siblings in once so the
  # layout holds (first live eval died on missing vmangos data here).
  for sibling in ["coworld-vanilla-wow", "monofuel-vanilla-wow",
      "wow-classic-data"]:
    let target = root / sibling
    let link = result.parentDir / sibling
    if dirExists(target) and not symlinkExists(link):
      createSymlink(target, link)

proc teardownWorktree*(root: string, lc: LeagueConfig,
    worktree, ticketId, slug: string, keepBranch: bool) =
  let repoDir = root / lc.repo
  discard gitCheck(repoDir, "worktree", "remove", "--force", worktree)
  discard gitCheck(repoDir, "worktree", "prune")
  forceRemoveDir(worktree)
  if not keepBranch:
    discard gitCheck(repoDir, "branch", "-D", expBranchName(ticketId, slug))

proc runWorker(agent: AgentConfig, prompt, workingDir, ticketId: string,
    attempt: int): AgentRunResult =
  # Logs must OUTLIVE the worktree (default logRoot lives inside it and
  # dies at teardown, orphaning every parked-tick autopsy). Worktrees sit
  # at <repo>/.conductor/worktrees/<slug>, so hop up to .conductor/logs.
  let logRoot = workingDir.parentDir.parentDir / "logs"
  runAgent(AgentRunRequest(
    prompt: prompt,
    workingDir: workingDir,
    logRoot: logRoot,
    harness: agent.harness,
    model: agent.model,
    reasoningEffort: agent.reasoningEffort,
    ticketId: ticketId,
    attempt: attempt,
    hardTimeoutMs: agent.hardTimeout,
    noOutputTimeoutMs: agent.noOutputTimeout,
    progressTimeoutMs: agent.progressTimeout,
    maxAttempts: 2,
  ))

proc runCodingAgent*(cfgAll: ConductorConfig, lc: LeagueConfig,
    worktree, ticketId, ticketContent, reviewFeedback: string,
    attempt: int): tuple[ok: bool, summary: string] =
  let feedback =
    if reviewFeedback.len > 0:
      "PREVIOUS REVIEW FEEDBACK (address this):\n" & reviewFeedback
    else:
      ""
  let prompt = renderPromptTemplate(CodingAgentTemplate, {
    "WORKTREE_PATH": worktree,
    "LANE_BRANCH": lc.laneBranch,
    "TICKET_CONTENT": ticketContent,
    "REVIEW_FEEDBACK": feedback,
  })
  let res = runWorker(cfgAll.agents.coding, prompt, worktree, ticketId,
    attempt)
  # Belt and braces: a worker that edited but forgot to commit still
  # yields a reviewable candidate.
  let (rcStatus, status) = gitRunCapture(worktree, @["status", "--porcelain"])
  if rcStatus == 0 and status.strip().len > 0:
    discard gitCheck(worktree, "add", "-A")
    discard gitCheck(worktree, "commit", "-m",
      "conductor: auto-commit uncommitted agent work")
  let (rcCount, countOut) = gitRunCapture(worktree,
    @["rev-list", "--count", lc.laneBranch & "..HEAD"])
  let commits = if rcCount == 0: countOut.strip() else: "0"
  if res.exitCode != 0 and res.timeoutKind != "none":
    return (false, "coding agent timeout (" & res.timeoutKind & ")")
  if commits == "0":
    return (false, "coding agent produced no commits")
  (true, res.lastMessage)

proc candidateDiff*(worktree: string, lc: LeagueConfig): string =
  let (rc, output) = gitRunCapture(worktree,
    @["diff", lc.laneBranch & "...HEAD"], timeoutMs = 120_000)
  if rc == 0: output else: ""

proc runReviewer*(cfgAll: ConductorConfig, lc: LeagueConfig,
    worktree, ticketId, ticketContent, coderSummary: string): ReviewVerdict =
  let diff = candidateDiff(worktree, lc)
  if diff.strip().len == 0:
    return ReviewVerdict(ship: false, reason: "empty diff")
  let prompt = renderPromptTemplate(ReviewAgentTemplate, {
    "TICKET_CONTENT": ticketContent,
    "DIFF_CONTENT": diff,
    "CODER_SUMMARY": coderSummary,
  })
  let res = runWorker(cfgAll.agents.reviewer, prompt, worktree, ticketId, 1)
  var verdictLine = ""
  for line in res.lastMessage.splitLines():
    if line.strip().startsWith("VERDICT:"):
      verdictLine = line.strip()
  if verdictLine.startsWith("VERDICT: SHIP"):
    ReviewVerdict(ship: true, reason: "")
  elif verdictLine.startsWith("VERDICT: BLOCK"):
    ReviewVerdict(ship: false,
      reason: verdictLine["VERDICT: BLOCK".len .. ^1].strip())
  else:
    # Reject-only power: an unreadable reviewer never green-lights.
    ReviewVerdict(ship: false,
      reason: "reviewer verdict unparseable (exit " & $res.exitCode & ")")

proc changedFiles*(worktree: string, lc: LeagueConfig): seq[string] =
  let (rc, output) = gitRunCapture(worktree,
    @["diff", "--name-only", lc.laneBranch & "...HEAD"])
  if rc != 0:
    return @[]
  for line in output.splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

proc countTestAssertions(worktree, rev: string): int =
  ## `check(` occurrences across the test trees at a given rev. -1 when
  ## the count is unavailable (never fail the guard on tooling noise).
  let (rc, output) = gitRunCapture(worktree,
    @["grep", "-c", "check(", rev, "--", "lua/tests", "tools/tests"],
    timeoutMs = 60_000)
  if rc notin {0, 1}:  # 1 = no matches, still a valid zero
    return -1
  for line in output.splitLines():
    let parts = line.rsplit(':', maxsplit = 1)
    if parts.len == 2:
      try:
        result += parseInt(parts[1])
      except ValueError:
        discard

proc isBehaviorChange*(files: seq[string]): bool =
  ## Bot behavior lives under lua/ (brain + beat configs). A candidate
  ## that touches none of it cannot move the eval, so forcing it to
  ## out-roll the champion is pure dice tax — tooling-only diffs merge
  ## on tests + review + guards.
  for f in files:
    if f.startsWith("lua/"):
      return true
  false

proc diffGuards*(worktree: string, lc: LeagueConfig,
    allowProtected = false): seq[string] =
  ## Structural rejections no agent can argue with. Empty = clean.
  ## allowProtected is the HUMAN-lane escape hatch (gate-branch
  ## --allow-protected): protected paths exist to stop agents from
  ## touching the eval fixture, not to stop reviewed human work — the
  ## eval + floor gate still applies either way. Never reachable from
  ## the agent tick path.
  if not allowProtected:
    for file in changedFiles(worktree, lc):
      for protected in lc.protectedPaths:
        if file == protected or
            (protected.endsWith("/") and file.startsWith(protected)) or
            file.startsWith(protected & "/"):
          result.add("protected path touched: " & file)
  let before = countTestAssertions(worktree, lc.laneBranch)
  let after = countTestAssertions(worktree, "HEAD")
  if before >= 0 and after >= 0 and after < before:
    result.add("test assertions decreased: " & $before & " -> " & $after)
