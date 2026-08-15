## The static-test leg of the gate, plus the master-health watchdog.
##
## Two jobs, one command string on purpose (`StaticTestCmd`):
##
## 1. `tick.nim` runs it in the candidate worktree — that is the gate's
##    static leg. It was `make test-lua` until ticket 0044, which left the
##    Nim tier and the Python road tests OUTSIDE the gate; `3def984` broke
##    exactly those and rode to master green.
## 2. The daemon runs the SAME command against the checkout it lives in
##    (master) whenever master HEAD moved since the last check. The gate
##    can only stop candidates the loop itself produced — a hand commit
##    pushed straight to master never sees it. This watchdog cannot block
##    such a commit, but it names it within one tick.
##
## Result lands in `.conductor/master-health.json` (runtime state, like
## state.json — gitignored, never committed). The System dashboard reads
## that file for a master-health light; see docs/conductor.md.

import
  std/[json, os, strutils, times],
  jsony,
  scriptorium/git_ops

const
  StaticTestTarget* = "test"
    ## make target for the gate's static leg — the FULL unit tier
    ## (test-lua + test-nim-soft + test-smoke + the Python checkpoint /
    ## soap tiers + traverse-lint-soft), not just `test-lua`.
  StaticTestTimeoutMs* = 600_000
  MasterHealthFileName* = "master-health.json"

type
  MasterHealthStatus* = enum
    mhUnknown = "unknown"   ## never checked (or the state file is corrupt)
    mhGreen = "green"       ## StaticTestCmd exited 0 at this sha
    mhRed = "red"           ## StaticTestCmd failed at this sha
    mhError = "error"       ## could not run the check (no sha, harness fault)

  MasterHealth* = object
    branch*: string         ## branch the checked-out HEAD is on
    sha*: string            ## short sha the verdict belongs to
    status*: MasterHealthStatus
    checkedAt*: string      ## UTC ISO-8601, "" when never checked
    durationS*: float       ## wall seconds the command took
    command*: string        ## exact command run, for the dashboard tooltip
    detail*: string         ## tail of the failure output on red, else ""

proc staticTestArgs*(): seq[string] =
  ## Args for `make` — one definition so the gate and the watchdog can
  ## never drift apart (and so a test can pin the string).
  @[StaticTestTarget]

proc staticTestCmd*(): string =
  "make " & staticTestArgs().join(" ")

proc masterHealthPath*(repoPath: string): string =
  repoPath / ".conductor" / MasterHealthFileName

proc loadMasterHealth*(repoPath: string): MasterHealth =
  ## Missing or corrupt file reads as "never checked" — the watchdog then
  ## checks on the next pass rather than wedging.
  let path = masterHealthPath(repoPath)
  if not fileExists(path):
    return MasterHealth(status: mhUnknown)
  try:
    result = readFile(path).fromJson(MasterHealth)
  except CatchableError:
    result = MasterHealth(status: mhUnknown)

proc saveMasterHealth*(repoPath: string, health: MasterHealth) =
  createDir(repoPath / ".conductor")
  atomicWriteFile(masterHealthPath(repoPath), health.toJson())

proc needsCheck*(prev: MasterHealth, sha: string): bool =
  ## Re-run only when the verdict does not already cover this exact sha.
  ## An unknown/error verdict is never trusted, however fresh it looks.
  if sha.len == 0:
    return false
  prev.sha != sha or prev.status notin {mhGreen, mhRed}

proc headSha(dir: string): string =
  let (rc, output) = gitRunCapture(dir, @["rev-parse", "--short=9", "HEAD"])
  if rc == 0: output.strip() else: ""

proc headBranch(dir: string): string =
  let (rc, output) = gitRunCapture(dir, @["rev-parse", "--abbrev-ref", "HEAD"])
  if rc == 0: output.strip() else: ""

proc checkMasterHealth*(repoPath, checkoutDir: string,
    force = false): MasterHealth =
  ## Run the gate's static command against checkoutDir HEAD when that HEAD
  ## has moved since the last verdict (or `force`). Cheap no-op otherwise:
  ## the stored verdict comes straight back, so this is safe to call at
  ## the top of every tick. Emits one log line on red.
  let prev = loadMasterHealth(repoPath)
  let sha = headSha(checkoutDir)
  if sha.len == 0:
    result = MasterHealth(branch: headBranch(checkoutDir), sha: "",
      status: mhError, checkedAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
      command: staticTestCmd(),
      detail: "no HEAD sha for " & checkoutDir)
    saveMasterHealth(repoPath, result)
    echo "conductor: master-health ERROR — ", result.detail
    return
  if not force and not needsCheck(prev, sha):
    return prev

  echo "conductor: master-health check — ", checkoutDir, " @ ", sha,
    " (", staticTestCmd(), ")"
  let started = epochTime()
  var rc = 0
  var output = ""
  try:
    (rc, output) = runCommandCapture(checkoutDir, "make", staticTestArgs(),
      timeoutMs = StaticTestTimeoutMs)
  except CatchableError as e:
    rc = -1
    output = e.msg
  result = MasterHealth(
    branch: headBranch(checkoutDir),
    sha: sha,
    status: (if rc == 0: mhGreen else: mhRed),
    checkedAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    durationS: epochTime() - started,
    command: staticTestCmd(),
    detail: (if rc == 0: "" else:
      "rc=" & $rc & ": " & output[max(0, output.len - 600) .. ^1]))
  saveMasterHealth(repoPath, result)
  if result.status == mhRed:
    echo "conductor: MASTER RED — ", result.branch, " @ ", sha, " fails ",
      staticTestCmd(), " — ", result.detail
  else:
    echo "conductor: master-health green — ", sha, " in ",
      result.durationS.formatFloat(ffDecimal, 1), "s"

proc masterHealthJson*(health: MasterHealth): JsonNode =
  ## Dashboard shape (The System reads the file directly; this is the same
  ## object, handy for status output and tests).
  %*{
    "branch": health.branch,
    "sha": health.sha,
    "status": $health.status,
    "checkedAt": health.checkedAt,
    "durationS": health.durationS,
    "command": health.command,
    "detail": health.detail,
  }
