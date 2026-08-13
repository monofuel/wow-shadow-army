## Conductor runtime state under <wsa repo>/.conductor/ (gitignored):
## crash-only journal of the current tick, a PID guard so only one
## conductor runs per repo, and a pause file monofuel can touch to halt
## the loop without killing it. Every transition is written atomically
## (scriptorium git_ops.atomicWriteFile) so a restart resumes cleanly.

import
  std/[json, os, posix, strutils, times],
  jsony,
  scriptorium/git_ops

const
  ConductorDirName* = ".conductor"
  StateFileName = "state.json"
  PidFileName = "conductor.pid"
  PauseFileName = "pause"
  NeedsHumanFileName* = "NEEDS-HUMAN"

type
  TickPhase* = enum
    tpIdle = "idle"
    tpTicketClaimed = "ticket-claimed"
    tpCoding = "coding"
    tpReview = "review"
    tpGate = "gate"
    tpMerge = "merge"
    tpShip = "ship"

  ConductorState* = object
    league*: string
    phase*: TickPhase
    ticketId*: string
    ticketPath*: string     ## repo-relative path in the tickets repo
    branch*: string
    worktree*: string
    attempt*: int
    updatedAt*: string

proc conductorDir*(repoPath: string): string =
  repoPath / ConductorDirName

proc statePath*(repoPath: string): string =
  conductorDir(repoPath) / StateFileName

proc pausePath*(repoPath: string): string =
  conductorDir(repoPath) / PauseFileName

proc needsHumanPath*(repoPath: string): string =
  conductorDir(repoPath) / NeedsHumanFileName

proc ensureConductorDir*(repoPath: string) =
  createDir(conductorDir(repoPath))

proc isPaused*(repoPath: string): bool =
  fileExists(pausePath(repoPath))

proc flagNeedsHuman*(repoPath, reason: string) =
  ## Append-only: multiple stops accumulate until monofuel clears the file.
  ensureConductorDir(repoPath)
  let f = open(needsHumanPath(repoPath), fmAppend)
  defer: f.close()
  f.writeLine(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & " " & reason)

proc saveState*(repoPath: string, state: ConductorState) =
  ensureConductorDir(repoPath)
  var s = state
  s.updatedAt = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  atomicWriteFile(statePath(repoPath), s.toJson())

proc loadState*(repoPath: string): ConductorState =
  ## Missing or corrupt state resets to idle — the loop treats that as
  ## "no tick in flight" and re-derives everything from git + tickets.
  let path = statePath(repoPath)
  if not fileExists(path):
    return ConductorState(phase: tpIdle)
  try:
    result = readFile(path).fromJson(ConductorState)
  except CatchableError:
    result = ConductorState(phase: tpIdle)

proc clearState*(repoPath: string, league: string) =
  saveState(repoPath, ConductorState(league: league, phase: tpIdle))

proc pidAlive(pid: int): bool =
  pid > 0 and kill(Pid(pid), cint(0)) == 0

proc acquirePidGuard*(repoPath: string): bool =
  ## True if we now hold the guard; false if a live conductor owns it.
  ensureConductorDir(repoPath)
  let path = conductorDir(repoPath) / PidFileName
  if fileExists(path):
    let prev = try: parseInt(readFile(path).strip()) except ValueError: 0
    if pidAlive(prev) and prev != int(getCurrentProcessId()):
      return false
  atomicWriteFile(path, $getCurrentProcessId())
  true

proc releasePidGuard*(repoPath: string) =
  let path = conductorDir(repoPath) / PidFileName
  if fileExists(path):
    let owner = try: parseInt(readFile(path).strip()) except ValueError: 0
    if owner == int(getCurrentProcessId()):
      removeFile(path)
