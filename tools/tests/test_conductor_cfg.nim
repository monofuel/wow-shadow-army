## Pure unit tests for conductor config + state (no network, no docker).
## Run: nim r --hints:off --warnings:off tools/tests/test_conductor_cfg.nim

import std/[os, strutils, tables]
import ../../src/conductor/cfg
import ../../src/conductor/state

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

let tmp = getTempDir() / "conductor-cfg-test-" & $getCurrentProcessId()
createDir(tmp)

# --- defaults when conductor.json is absent ---
let bare = loadConductorConfig(tmp)
check(bare.maxAttemptsPerTicket == 3, "default maxAttemptsPerTicket")
check(bare.agents.coding.harness == harnessClaudeCode, "default coding harness")
check(bare.agents.reviewer.harness == harnessGrokBuild, "default reviewer harness")
check(bare.leagues.len == 0, "no leagues without a config file")

# --- partial config deep-merges over defaults ---
writeFile(tmp / "conductor.json", """
{
  "maxAttemptsPerTicket": 5,
  "agents": { "coding": { "model": "test-model" } },
  "leagues": {
    "traverse": {
      "repo": "wow-shadow-army",
      "laneBranch": "monofuel/traverse",
      "ticketLane": "traverse",
      "evalMake": { "target": "traverse",
        "vars": { "CHECKPOINT": "spawn", "END_TIMEOUT": "420" } },
      "floorMetric": "max_northing",
      "assertions": [
        { "field": "deaths", "op": "<=", "vsChampion": true, "value": 0 }
      ],
      "protectedPaths": ["Makefile", "scores/"],
      "ship": { "policy": "petrel", "leagueId": "league_x",
        "image": "petrel:latest", "auto": false }
    }
  }
}
""")
let merged = loadConductorConfig(tmp)
check(merged.maxAttemptsPerTicket == 5, "user value overrides default")
check(merged.agents.coding.model == "test-model", "nested override merges")
check(merged.agents.coding.hardTimeout == 3_600_000,
  "sibling default survives partial agent override")
check(merged.agents.reviewer.harness == harnessGrokBuild,
  "untouched agent keeps defaults")
check(merged.leagues.len == 1, "league parsed")
let lc = merged.league("traverse")
check(lc.laneBranch == "monofuel/traverse", "league laneBranch")
check(lc.evalMake.vars["END_TIMEOUT"] == "420", "evalMake vars")
check(lc.assertions.len == 1 and lc.assertions[0].vsChampion,
  "assertion parsed")
check(lc.ship.auto == false, "ship.auto parsed")

# --- unknown league raises ---
var raised = false
try:
  discard merged.league("speedrun")
except ValueError:
  raised = true
check(raised, "unknown league raises ValueError")

# --- invalid JSON raises ValueError with path ---
writeFile(tmp / "conductor.json", "{ nope")
raised = false
try:
  discard loadConductorConfig(tmp)
except ValueError as e:
  raised = e.msg.contains("conductor.json")
check(raised, "invalid JSON raises with path in message")

# --- state roundtrip + corrupt reset ---
let repo = tmp / "repo"
createDir(repo)
var st = ConductorState(league: "traverse", phase: tpGate,
  ticketId: "0042", ticketPath: "tickets/in-progress/0042-x.md",
  branch: "monofuel/exp-0042-x", worktree: "/w/0042", attempt: 2)
saveState(repo, st)
let back = loadState(repo)
check(back.phase == tpGate and back.ticketId == "0042" and
  back.attempt == 2, "state roundtrip")
check(back.updatedAt.len > 0, "state stamps updatedAt")
writeFile(statePath(repo), "garbage")
check(loadState(repo).phase == tpIdle, "corrupt state resets to idle")

# --- pause + needs-human flags ---
check(not isPaused(repo), "not paused by default")
writeFile(pausePath(repo), "")
check(isPaused(repo), "pause file pauses")
flagNeedsHuman(repo, "test reason")
check(readFile(needsHumanPath(repo)).contains("test reason"),
  "needs-human appends reason")

# --- pid guard ---
check(acquirePidGuard(repo), "acquire pid guard")
check(acquirePidGuard(repo), "re-acquire own guard is fine")
releasePidGuard(repo)

removeDir(tmp)
echo "test_conductor_cfg: ", passed, " ok"
