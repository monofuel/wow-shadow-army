# Conductor — automated autoresearch loop over the league lanes.
#
# A dumb, reliable Nim process drives the loop; LLM agents are fallible
# subprocess workers inside it (scriptorium harnesses). The merge gate is
# pure code — floor ratchet + assertions vs the champion run — and the
# reviewer agent can only reject, never approve past a failing gate.
#
#   nim r src/conductor.nim <league> <once|run|status|baseline|gate>
#
# Config: <wow-coworld root>/conductor.json.  Design: docs/conductor.md.

import
  std/[os, sequtils, strutils, tables],
  conductor/cfg,
  conductor/state

proc usage() =
  echo "usage: conductor <league> <command>"
  echo "commands:"
  echo "  status    show config, state, pause/needs-human flags"
  echo "  baseline  evaluate lane HEAD and seed the score ledger"
  echo "  once      run a single tick (ticket -> agent -> gate -> merge)"
  echo "  run       daemon loop (single instance, pause via .conductor/pause)"
  echo "  gate      re-run the gate for the current in-flight candidate"
  quit 1

proc repoRoot(): string =
  ## The wow-shadow-army checkout conductor runs from.
  result = getEnv("CONDUCTOR_REPO", getCurrentDir())
  if not dirExists(result / ".git") and not fileExists(result / ".git"):
    quit "conductor: " & result & " is not a git checkout (set CONDUCTOR_REPO)"

proc monorepoRoot(repo: string): string =
  getEnv("CONDUCTOR_ROOT", repo.parentDir)

proc cmdStatus(cfgAll: ConductorConfig, leagueName, repo: string) =
  let lc = cfgAll.league(leagueName)
  echo "conductor status — league: ", leagueName
  echo "  lane branch:   ", lc.laneBranch
  echo "  eval:          make ", lc.evalMake.target, " (",
    lc.evalMake.vars.len, " vars)"
  echo "  floor metric:  ", lc.floorMetric
  echo "  assertions:    ", lc.assertions.len
  echo "  auto-ship:     ", lc.ship.auto
  echo "  coding agent:  ", $cfgAll.agents.coding.harness, " / ",
    cfgAll.agents.coding.model
  echo "  review agent:  ", $cfgAll.agents.reviewer.harness, " / ",
    cfgAll.agents.reviewer.model
  let st = loadState(repo)
  echo "  tick phase:    ", $st.phase,
    (if st.ticketId.len > 0: " (ticket " & st.ticketId & ")" else: "")
  echo "  paused:        ", isPaused(repo)
  if fileExists(needsHumanPath(repo)):
    echo "  NEEDS-HUMAN:"
    for line in readFile(needsHumanPath(repo)).strip().splitLines():
      echo "    ", line

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
    cmdStatus(cfgAll, leagueName, repo)
  of "baseline", "once", "run", "gate":
    quit "conductor: '" & command & "' lands in a later build phase " &
      "(P2 baseline/gate, P3 once, P4 run)"
  else:
    usage()

when isMainModule:
  main()
