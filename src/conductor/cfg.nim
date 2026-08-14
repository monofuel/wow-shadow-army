## Conductor configuration: ../conductor.json at the wow-coworld root
## (one file for every league lane). Reuses scriptorium's AgentConfig +
## Harness so harness/model/timeout semantics match the library we run
## agents through. Loading mirrors scriptorium/config.nim: defaults,
## deep-merged under the user's JSON, so partial configs stay valid.

import
  std/[json, os, tables],
  jsony,
  scriptorium/config as sconfig

export sconfig.AgentConfig, sconfig.Harness

const ConductorConfigFile* = "conductor.json"

type
  EvalMake* = object
    target*: string
    vars*: OrderedTable[string, string]

  GateAssertion* = object
    field*: string      ## dot-path into the RunReport ("scorecard.fat_min")
    op*: string         ## "<=" | ">=" | "=="
    vsChampion*: bool   ## compare against champion's value (else `value`)
    value*: float
    perDurationS*: bool ## accumulator axis: compare per-1000-sim-s rates,
                        ## not totals — a run that survives longer must not
                        ## be punished for accumulating over more clock

  ShipConfig* = object
    policy*: string
    leagueId*: string
    image*: string
    auto*: bool
    playerId*: string          ## pinned identity (playbook §5, multi-player accounts)
    overrideDeathTickets*: bool ## best-of boards cannot go down (monofuel 2026-08-14)

  LeagueConfig* = object
    repo*: string             ## repo dir name under the wow-coworld root
    laneCheckout*: string     ## lane worktree dir name under the root
    laneBranch*: string
    ticketLane*: string       ## matches tickets' **Lane:** field
    evalMake*: EvalMake
    floorMetric*: string      ## RunReport field the ratchet applies to
    assertions*: seq[GateAssertion]
    protectedPaths*: seq[string]
    ship*: ShipConfig

  ConductorAgents* = object
    coding*: AgentConfig
    reviewer*: AgentConfig

  ConductorConfig* = object
    agents*: ConductorAgents
    maxAttemptsPerTicket*: int
    evalLockRetrySeconds*: int   ## wait (never steal) when the eval flock is held
    tickBackoffMaxSeconds*: int
    leagues*: OrderedTable[string, LeagueConfig]

proc defaultConductorConfig*(): ConductorConfig =
  ConductorConfig(
    agents: ConductorAgents(
      coding: AgentConfig(harness: harnessClaudeCode, model: "claude-opus-5",
        reasoningEffort: "", hardTimeout: 3_600_000,
        noOutputTimeout: 300_000, progressTimeout: 900_000),
      # Review is a verdict task: grok-4.6's default xhigh reasoning goes
      # silent >300s on large diffs (probed 2026-08-13: 127KB review =
      # 5s at low effort vs >5min with silent gaps at xhigh).
      reviewer: AgentConfig(harness: harnessGrokBuild, model: "grok-4.6",
        reasoningEffort: "low", hardTimeout: 1_800_000,
        noOutputTimeout: 600_000, progressTimeout: 600_000),
    ),
    maxAttemptsPerTicket: 3,
    evalLockRetrySeconds: 120,
    tickBackoffMaxSeconds: 600,
    leagues: initOrderedTable[string, LeagueConfig](),
  )

proc deepMerge(base, overlay: JsonNode): JsonNode =
  ## Overlay wins; objects merge recursively, everything else replaces.
  if base.kind == JObject and overlay.kind == JObject:
    result = base.copy()
    for key, value in overlay:
      if result.hasKey(key):
        result[key] = deepMerge(result[key], value)
      else:
        result[key] = value.copy()
  else:
    result = overlay.copy()

proc conductorConfigPath*(rootPath: string): string =
  rootPath / ConductorConfigFile

proc loadConductorConfig*(rootPath: string): ConductorConfig =
  ## rootPath is the wow-coworld monorepo root (the parent of the league
  ## repos). Missing file returns pure defaults; invalid JSON raises.
  let path = conductorConfigPath(rootPath)
  let defaults = defaultConductorConfig()
  if not fileExists(path):
    return defaults
  let userJson =
    try:
      parseJson(readFile(path))
    except JsonParsingError as e:
      raise newException(ValueError,
        "invalid JSON in " & path & ": " & e.msg)
  let merged = deepMerge(parseJson(defaults.toJson()), userJson)
  result = ($merged).fromJson(ConductorConfig)

proc league*(cfg: ConductorConfig, name: string): LeagueConfig =
  if name notin cfg.leagues:
    raise newException(ValueError,
      "league '" & name & "' not in conductor.json (have: " &
      $cfg.leagues.len & " configured)")
  cfg.leagues[name]
