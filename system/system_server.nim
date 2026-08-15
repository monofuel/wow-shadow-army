## The System — management server for the shadow army.
##
## One Nim binary, HTTP + MCP interfaces on one mummy server:
##   HTTP dashboard (htmx)  GET /  GET /army  GET /murist  GET /advisor
##                          GET /traverse  GET /admin
##                          GET /roster  GET /murist/status  GET /murist/quests
##                          GET /murist/events  GET /traverse/status
##                          GET /traverse/ops  GET /traverse/replays
##                          GET /events  GET /server
##                          POST /reload  POST /server/start  POST /server/stop
##                          POST /traverse/pol/start|/stop
##                          POST /traverse/watch/start|/stop
##                          POST /traverse/replays/refresh
##                          POST /admin/respawn-shadow-army
##   MCP endpoint (MCPort)  POST /mcp
##
## Critical design rule: one dispatch path. Each capability is one data/action
## proc; the htmx handlers render it and the MCP tools serialize it.
##   listCharacters()           — roster (SELECT via docker exec)
##   traverseStatus()        — Kalimdor Traverse telemetry (DB + live godview)
##   startTraversePol()/startTraverseWatch() — detached PoL + live observer
##   traverseReplays()       — hosted league episodes (version + replay links)
##   recentEvents()          — addon Chat.log ring buffer
##   reloadAddon()           — SOAP announce <SYS> reload + wait for <SA> loaded
##   announceInGame()        — SOAP announce <text>
##   respawnShadowArmy()     — admin SOAP revive + tele (ops escape hatch)
##   serverStatus()          — realm container up/down + lifecycle op state
##   startServer()/stopServer() — queue operator `up`/`down` (async worker)
##
## Tabs: Army (roster), Murist (human seat), Advisor (events + reload),
## Traverse (league telemetry + PoL/observer + hosted replays), Admin.
## The dashboard stays useful with the realm DOWN: roster/Murist degrade to
## offline notes; Admin's Server panel offers Start/Stop. The human only runs
## the client and this dashboard.
##
## Admin interfaces (same procs): HTTP /admin, MCP tools, and human-seat addon
## chat (`<SA> admin <action>` from Murist → Chat.log tailer).

import
  std/[
    algorithm, base64, httpclient, json, locks, net, options, os, osproc,
    streams, strformat, strutils, tables, times, uri
  ],
  mummy, mummy/routers,
  webby/httpheaders as mummyheaders,
  jsony,
  mcport/mcp_core,
  ../tools/fair_play_audit

const
  Version = "0.11.0"
  ServerName = "TheSystem"
  ## Only this character may request admin actions via `<SA> admin …` (human seat).
  AdminRequesterName* = "Murist"
  ## Min seconds between chat-triggered admin actions (double-click / say dedupe).
  AdminChatCooldownSec = 8.0
  ## World DB (game_tele lives here; characters DB is separate).
  WorldDbName = "mangos"
  ## Scratch game_tele name: upserted to Murist's live coords, then used by
  ## `tele name <seat> SA_MURIST_MEET`. Console SOAP cannot `go xyz` another player.
  MuristMeetTeleName* = "SA_MURIST_MEET"
  ## Dashboard + MCP share this port (not 8080 healthz / 8085 world / 3724 realmd).
  HttpPort = 7777
  ## htmx auto-refresh interval for the roster / events table bodies.
  PollSeconds = 3
  ## VMaNGOS credentials match Makefile `account` target (manage_coworld_accounts).
  DbUser = "mangos"
  DbPass = "mangos"
  DbName = "characters"
  ## Default compose container name for coworld-game. Override with SYSTEM_MYSQL_CONTAINER.
  DefaultGameContainer = "coworld-vmangos-coworld-game-1"
  ## Kalimdor Traverse fixture character (docs/traverse/traverse_wow.md).
  TraverseCharacterName* = "Northbound"
  ## Course anchors from upstream game/scoring.py (X is north/south).
  TraverseStartWorldX* = -9187.0
  TraverseGoalWorldX* = 6687.333052
  ## goal - start; full course length in yards.
  TraverseCourseYards* = 15874.333052
  ## League wall clock: max_ticks 27000 / tick_rate 10 → 2700s (45 minutes).
  TraverseEpisodeLimitSeconds* = 45 * 60
  ## docker ps name suffix for the traverse scenario game container.
  TraverseContainerSuffix* = "-traverse-coworld-game-1"
  ## Host path under ~/.coworld for league runtime captures (godview JSONL).
  TraverseCapturesRel* = ".coworld/player/launcher_units/runtime"
  ## Detached traverse ops (dashboard Start PoL / observer).
  TraversePolLogRel* = "local_data/brain-logs/traverse-pol.log"
  TraversePolPidRel* = "local_data/brain-logs/traverse-pol.pid"
  TraverseWatchLogRel* = "local_data/brain-logs/traverse-watch.log"
  TraverseWatchPidRel* = "local_data/brain-logs/traverse-watch.pid"
  ## Hosted league episodes cache (ctf-bots runs/field pattern).
  TraverseEpisodesHistoryRel* = "local_data/traverse/episodes_history.json"
  TraverseFieldPullLogRel* = "local_data/brain-logs/traverse-field-pull.log"
  TraverseFieldPullPidRel* = "local_data/brain-logs/traverse-field-pull.pid"
  ## Softmax league / division for Kalimdor Traverse (docs/traverse/traverse_wow.md).
  TraverseLeagueId* = "league_0f38d762-930a-41d3-9979-1858dd52c1ae"
  TraverseDivisionId* = "div_b50e0091-514d-4406-837a-420ef9c372ca"
  ## Policy names we own on the traverse ladder (version labels ibis:vN).
  TraverseOurPolicyNames* = ["ibis"]
  ObservatoryV2Base* = "https://softmax.com/observatory/v2"
  ## In-browser coworld replay viewer (not raw S3 .replay).
  ObservatoryCoworldReplaysBase* = "https://softmax.com/observatory/coworld-replays"
  ## Replays panel poll (file-backed; slower than live telemetry).
  TraverseReplaysPollSeconds* = 15
  ## Observer needs a live army_host session (PoL exits after 50 yd).
  ## Long run: full episode wall clock, no pol-min-yards early exit.
  TraverseWatchAgentMaxSeconds* = TraverseEpisodeLimitSeconds
  ## Godview must show Northbound within this age for follow to work.
  TraverseWatchCaptureMaxAgeSec* = 20.0
  ## How long Start observer waits for Northbound to appear in godview.
  TraverseWatchCaptureWaitMs* = 90_000
  ## Tail window when reading the latest godview shard (live pos, not full history).
  GodviewTailBytes* = 256 * 1024
  ## VMaNGOS CHARACTER_FLAG_GHOST — set while spirit-running / unreleased corpse.
  CharacterFlagGhost = 0x2000
  ## Fixed bot seats (party-army seats). Admin respawn only touches these.
  ## Murist is the human leader and is intentionally not in this list.
  BotSeats* = ["Shadowfel", "Igris", "Tusk", "Beru"]
  ## Display order for the Murist party (human first, then bot seats).
  RosterDisplayOrder* = ["Murist", "Shadowfel", "Igris", "Tusk", "Beru"]
  ## Named game_tele destination (mangos.game_tele / `lookup tele death`).
  ## Safe valley floor near Deathknell undead start — not NightWebsHollow.
  ShadowArmyRespawnTele* = "Deathknell"
  ## A seat heartbeat older than this is not considered a live policy.
  HomeBotStatusMaxAgeSec = 30.0
  ## Bot seat lifecycle maps to the canonical Makefile targets. Murist is
  ## human-controlled and is intentionally never listed.
  SeatMakeTargets* = [
    (name: "Shadowfel", startTarget: "shadowfel-start", stopTarget: "shadowfel-stop"),
    (name: "Igris", startTarget: "igris-start", stopTarget: "igris-stop"),
    (name: "Tusk", startTarget: "tusk-start", stopTarget: "tusk-stop"),
    (name: "Beru", startTarget: "beru-start", stopTarget: "beru-stop")
  ]
  ## SELECT-only projection of characters (VMaNGOS schema) + xp bar + life/zone + HP/MP + pos.
  ## `xp` is progress into the current level; next-level threshold joins
  ## `mangos.player_xp_for_level` (world DB on the same MariaDB).
  ## Zone display name joins `mangos.area_template` on characters.zone (AreaTable id).
  ## basehp/basemana come from player_classlevelstats (level+class base, no gear).
  ## power1=mana, power2=rage, power4=energy (classic UNIT_FIELD_POWER layout).
  RosterSql = """SELECT c.name, c.level, c.class, c.race, c.money, c.online, c.xp,
COALESCE(x.xp_for_next_level, 0),
c.character_flags, c.health, c.zone, c.map,
COALESCE(NULLIF(a.name, ''), CONCAT('Zone#', c.zone)),
c.power1, c.power2, c.power4,
COALESCE(s.basehp, 0), COALESCE(s.basemana, 0),
c.position_x, c.position_y, c.position_z
FROM characters c
LEFT JOIN mangos.player_xp_for_level x ON x.lvl = c.level
LEFT JOIN mangos.area_template a ON a.entry = c.zone
LEFT JOIN mangos.player_classlevelstats s ON s.class = c.class AND s.level = c.level
ORDER BY c.name"""
  ## Kalimdor Traverse fixture row + zone display name (same area_template join).
  TraverseSql = """SELECT c.name, c.level, c.map, c.zone,
c.position_x, c.position_y, c.position_z, c.online,
COALESCE(NULLIF(a.name, ''), CONCAT('Zone#', c.zone))
FROM characters c
LEFT JOIN mangos.area_template a ON a.entry = c.zone
WHERE c.name='Northbound'"""
  ## Active quest log for one character (unrewarded only).
  ## VMaNGOS status: 1=complete (turn-in ready), 3=incomplete/active, 5=failed.
  ## quest_template is multi-patch — take MAX(patch) per entry for Title/reqs.
  ## Name is substituted safely by questLogSqlFor (alphanumeric only).
  QuestLogSqlTemplate = """SELECT cq.quest, cq.status,
cq.mob_count1, cq.mob_count2, cq.mob_count3, cq.mob_count4,
cq.item_count1, cq.item_count2, cq.item_count3, cq.item_count4,
COALESCE(NULLIF(qt.Title, ''), CONCAT('Quest#', cq.quest)),
COALESCE(qt.QuestLevel, 0),
COALESCE(qt.ReqCreatureOrGOCount1, 0), COALESCE(qt.ReqCreatureOrGOCount2, 0),
COALESCE(qt.ReqCreatureOrGOCount3, 0), COALESCE(qt.ReqCreatureOrGOCount4, 0),
COALESCE(qt.ReqItemCount1, 0), COALESCE(qt.ReqItemCount2, 0),
COALESCE(qt.ReqItemCount3, 0), COALESCE(qt.ReqItemCount4, 0),
COALESCE(qt.ObjectiveText1, ''), COALESCE(qt.ObjectiveText2, ''),
COALESCE(qt.ObjectiveText3, ''), COALESCE(qt.ObjectiveText4, '')
FROM character_queststatus cq
INNER JOIN characters c ON c.guid = cq.guid AND c.name = '$$NAME$$'
LEFT JOIN mangos.quest_template qt ON qt.entry = cq.quest
  AND qt.patch = (SELECT MAX(p.patch) FROM mangos.quest_template p WHERE p.entry = cq.quest)
WHERE cq.rewarded = 0 AND cq.status IN (1, 3, 5)
ORDER BY FIELD(cq.status, 1, 3, 5), qt.QuestLevel, cq.quest"""
  ## Live addon events only; history stays in the log file.
  EventRingCap = 1000
  ## How often the Chat.log tailer polls for new bytes.
  TailerPollMs = 500
  ## SOAP HTTP timeout (gsoap can be slow on a cold container).
  SoapTimeoutMs = 10_000
  ## Default relative path to VMaNGOS Chat.log (resolved absolute from cwd).
  DefaultChatLogRel = "../coworld-vanilla-wow/local_data/coworld-run/logs/Chat.log"
  ## Upstream checkout holding the compose operator (same as Makefile UPSTREAM).
  DefaultUpstreamRel = "../coworld-vanilla-wow"
  ## Shared realm lifecycle entry (discovers upstream operator + auto --build).
  ## Single path for dashboard + Makefile so upstream layout churn is one fix.
  RealmOpWrapperRel = "tools/realm_op.sh"
  ## Detached user unit for realm start/stop — NOT a child of wow-system, so
  ## dashboard restarts cannot kill a multi-minute image build / compose up.
  RealmOpUnit = "wow-realm-op"
  ## Marker line the detached wrapper appends so we can read exit after collect.
  RealmOpExitMarker = "SYSTEM_REALM_OP_EXIT="
  ## Prefix the addon emits over /say (structured telemetry).
  SaPrefix = "<SA> "
  ## Older addon banner still seen in the wild.
  LegacyPrefix = "<ShadowArmy> "
  ## Seat babysitter (ticket 0055). A home seat whose Lua status heartbeat is
  ## older than this while its launcher PID is still alive is WEDGED: the
  ## client process exists but the policy has stopped ticking.
  SeatWedgeStaleSec* = 90.0
  ## How often the babysitter samples every seat's status file.
  SeatWatchPollMs = 10_000
  ## Recovery budget: no more than this many auto-restarts per seat per window
  ## before the dashboard escalates to a persistent alert instead of looping.
  SeatRestartBudget* = 3
  SeatRestartWindowSec* = 3600.0
  ## Ignore staleness for this long after The System boots (`nim r` recompiles
  ## on restart; seats must not be blamed for the dashboard's own downtime).
  SeatWatchStartupGraceSec = 60.0
  ## Minimum spacing between two recovery attempts on the same seat — a restart
  ## needs longer than one poll to bring a heartbeat back.
  SeatRecoveryCooldownSec = 180.0
  ## Launcher.log lines captured into the wedge evidence file before recovery.
  SeatWedgeEvidenceLines* = 50
  ## Bytes of launcher.log read to find those lines (tail only; logs get big).
  SeatWedgeEvidenceBytes = 256 * 1024
  ## Durable babysitter state (restart budget survives a dashboard restart).
  SeatWatchStateRel = "local_data/seat-watch.json"
  ## Inventory over the chat bus (ticket 0052): parts of one snapshot arriving
  ## inside this window belong to the same snapshot; a later `full` line starts
  ## a new one.
  InvSnapshotWindowSec* = 20.0
  ## Inventory rows rendered on a seat panel (highest vendor value first).
  InvPanelRows = 40
  ## How long reloadAddon waits for a fresh <SA> loaded event. The human
  ## path is announce → panel button lights up → click, so this needs to
  ## cover human reaction time, not just a programmatic reload.
  ReloadWaitMs = 25_000
  ReloadStepMs = 200

type
  Character* = object
    ## One realm character as seen by The System (read-only observer).
    name*: string
    level*: int
    classId*: int
    className*: string
    raceId*: int
    raceName*: string
    money*: int ## copper
    gold*: string ## human display (Ng Ns Nc)
    online*: bool
    xp*: int ## XP into current level (characters.xp)
    nextLevelXp*: int ## XP required for next level (0 if unknown / max)
    xpToLevel*: int ## max(0, nextLevelXp - xp)
    xpPct*: int ## 0..100 progress into current level
    ## Life state for the dashboard: "alive" | "ghost" | "dead" | "offline"
    life*: string
    isGhost*: bool ## character_flags & CHARACTER_FLAG_GHOST
    health*: int ## characters.health (0 while dead/ghost is common)
    maxHealth*: int ## class/level basehp (no gear); 0 if unknown
    ## Primary resource for the class (mana / rage / energy).
    power*: int
    maxPower*: int ## basemana, or 100 for rage/energy; 0 if unknown / none
    powerKind*: string ## "mana" | "rage" | "energy" | ""
    zoneId*: int ## characters.zone (AreaTable id)
    zoneName*: string ## mangos.area_template.name, or Zone#N fallback
    mapId*: int ## characters.map (0 EK, 1 Kalimdor, …)
    posX*, posY*, posZ*: float ## characters.position_*
    ## Retained API field. Embedded home bots do not expose a TCP control port.
    controlPort*: int
    ## True when the seat PID is alive and its Lua status heartbeat is fresh.
    controlUp*: bool

  AddonEvent* = object
    ## One structured line from the addon via Chat.log (/say).
    id*: int ## monotonic, assigned when appended to the buffer
    time*: string ## "2026-07-25 18:00:00" (server-local, taken from the line)
    name*: string ## character name
    guid*: int
    map*: int
    pos*: array[3, float]
    kind*: string ## first word after the prefix: "loaded", "err", "auto", ...
    payload*: string ## remainder of the message
    raw*: string ## full original line

  QuestLogEntry* = object
    ## One unrewarded quest on a character's log (read-only DB observer).
    questId*: int
    title*: string
    level*: int
    status*: string ## "complete" | "active" | "failed"
    statusCode*: int ## raw VMaNGOS QuestStatus
    progress*: string ## short objective progress ("3/10 · 1/5")

  TraverseCharacter* = object
    ## Northbound fixture row from the traverse scenario characters DB.
    name*: string
    level*: int
    mapId*: int
    zoneId*: int
    zoneName*: string
    posX*, posY*, posZ*: float
    online*: bool
    hasPosition*: bool ## false when x/y/z could not be parsed

  TraverseScore* = object
    ## Upstream scoring.py northing result for the traverse course.
    northingYards*: float
    coursePct*: float ## 0..100 of TraverseCourseYards
    valid*: bool
    invalidReason*: string ## empty when valid; else scoring reason code

  TraverseClock* = object
    ## Wall-clock progress against the 45-minute traverse episode limit.
    known*: bool
    elapsedSec*: int
    limitSec*: int
    remainingSec*: int
    expired*: bool

  TraverseStatus* = object
    ## Dashboard snapshot for the Traverse tab (read-only telemetry).
    containerFound*: bool
    containerName*: string
    characterFound*: bool
    character*: TraverseCharacter
    score*: TraverseScore
    ## True when pos/score used godview capture (not just characters DB).
    livePos*: bool
    clock*: TraverseClock

  TraverseOpsStatus* = object
    ## Detached PoL / observer controls on the Traverse tab.
    polRunning*: bool
    polPid*: int
    polLog*: string
    watchRunning*: bool
    watchPid*: int
    watchLog*: string
    lastDetail*: string
    lastOk*: bool

  TraverseReplayRow* = object
    ## One hosted traverse episode for the dashboard replays table.
    id*: string
    episodeId*: string
    status*: string
    versionLabel*: string ## e.g. ibis:v2
    version*: int
    policyName*: string
    policyVersionId*: string
    score*: float
    hasScore*: bool
    whenText*: string
    replayUrl*: string
    liveUrl*: string
    observatoryUrl*: string

  TraverseReplaysStatus* = object
    ## File-backed hosted episode list (pulled via tools/pull_traverse_field.sh).
    available*: bool
    path*: string
    note*: string
    rows*: seq[TraverseReplayRow]
    pullRunning*: bool
    lastDetail*: string
    lastOk*: bool

  TraverseLivePos* = object
    ## One godview snapshot of the fixture character (in-world, not DB save).
    x*, y*, z*: float
    mapId*: int
    level*: int
    hasMap*: bool
    hasLevel*: bool

  AdminStepResult* = object
    ## One SOAP command outcome for an admin action.
    name*: string
    command*: string
    ok*: bool
    detail*: string

  AdminActionResult* = object
    ## Aggregate admin action (dashboard + MCP).
    ok*: bool
    action*: string
    steps*: seq[AdminStepResult]
    summary*: string

  ## Queued chat-bus admin op (no GC'd string — tailer thread is GC-safe).
  AdminChatAction* = enum
    acaNone = 0
    acaRespawnShadowArmy = 1
    acaReloadAddon = 2
    acaTelePartyToMurist = 3

  ## Realm lifecycle op queued for the server-op worker thread.
  ServerLifecycleOp* = enum
    sloNone = 0
    sloStart = 1
    sloStop = 2

  ServerStatus* = object
    ## Realm container + lifecycle state for the Server panel / MCP.
    running*: bool ## coworld-game container is up
    container*: string ## compose name (e.g. coworld-vmangos-coworld-game-1)
    containerId*: string ## short docker id (12 hex), "" if missing
    op*: string ## "" | "start" | "stop" — queued or executing right now
    lastOp*: string ## "" until a lifecycle op has finished
    lastOpOk*: bool
    lastOpDetail*: string ## tail of operator output / error message

# Classic 1.12 race/class IDs are stable enums; hardcode the small tables.
const
  RaceNames = [
    (1, "Human"),
    (2, "Orc"),
    (3, "Dwarf"),
    (4, "Night Elf"),
    (5, "Undead"),
    (6, "Tauren"),
    (7, "Gnome"),
    (8, "Troll")
  ]
  ClassNames = [
    (1, "Warrior"),
    (2, "Paladin"),
    (3, "Hunter"),
    (4, "Rogue"),
    (5, "Priest"),
    (7, "Shaman"),
    (8, "Mage"),
    (9, "Warlock"),
    (11, "Druid")
  ]

var
  gMcpServer: McpServer
  gEventLock: Lock
  gEvents: seq[AddonEvent]
  gNextEventId: int
  gTailerThread: Thread[void]
  gAdminChatLock: Lock
  gLastAdminChatAt: float ## epoch seconds; debounce chat-triggered admin
  gPendingAdminAction: AdminChatAction ## acaNone when idle
  gAdminWorkerThread: Thread[void]
  gServerOpLock: Lock
  gPendingServerOp: ServerLifecycleOp ## queued, not yet picked up
  gRunningServerOp: ServerLifecycleOp ## executing in the worker right now
  gLastServerOp: string ## "start" | "stop" after first completed op
  gLastServerOpOk: bool
  gLastServerOpDetail: string
  gServerOpWorkerThread: Thread[void]

initLock(gEventLock)
initLock(gAdminChatLock)
initLock(gServerOpLock)

proc raceName*(raceId: int): string =
  ## Map a classic 1.12 race ID to a display name.
  for (id, name) in RaceNames:
    if id == raceId:
      return name
  return &"Race#{raceId}"

proc className*(classId: int): string =
  ## Map a classic 1.12 class ID to a display name.
  for (id, name) in ClassNames:
    if id == classId:
      return name
  return &"Class#{classId}"

proc formatGold*(copper: int): string =
  ## Format copper as gold/silver/copper for the Status Window.
  let g = copper div 10000
  let s = (copper mod 10000) div 100
  let c = copper mod 100
  result = &"{g}g {s}s {c}c"

proc parseDockerStartedAtEpoch*(s: string): Option[int64] =
  ## Parse docker inspect StartedAt (RFC3339; fractional seconds optional).
  ## Returns UTC unix seconds, or none when the prefix is not parseable.
  result = none(int64)
  let t = s.strip()
  if t.len < 19:
    return
  try:
    let core = t[0 .. 18] # yyyy-MM-ddTHH:mm:ss
    let dt = parse(core, "yyyy-MM-dd'T'HH:mm:ss", utc())
    result = some(dt.toTime.toUnix)
  except TimeParseError, ValueError:
    result = none(int64)

proc traverseClockAt*(
    nowUnix, startUnix: int64,
    limitSec = TraverseEpisodeLimitSeconds
): TraverseClock =
  ## Build clock state from wall-clock epochs (pure; testable).
  let limit = max(1, limitSec)
  let elapsed = max(0, int(nowUnix - startUnix))
  let remaining = max(0, limit - elapsed)
  result = TraverseClock(
    known: true,
    elapsedSec: elapsed,
    limitSec: limit,
    remainingSec: remaining,
    expired: elapsed >= limit
  )

proc formatTraverseClock*(sec: int): string =
  ## Compact mm:ss (or h:mm:ss when ≥ 1 hour).
  let s = max(0, sec)
  let h = s div 3600
  let m = (s mod 3600) div 60
  let r = s mod 60
  if h > 0:
    result = &"{h}:{m:02}:{r:02}"
  else:
    result = &"{m}:{r:02}"

proc traverseNorthingYards*(worldX: float): float =
  ## Yards of northing along the Kalimdor course (X is north/south).
  result = max(0.0, min(worldX, TraverseGoalWorldX) - TraverseStartWorldX)

proc traverseCoursePct*(northingYards: float): float =
  ## Percent of the traverse course completed (0..100).
  if TraverseCourseYards <= 0.0:
    return 0.0
  let pct = (northingYards / TraverseCourseYards) * 100.0
  result = max(0.0, min(pct, 100.0))

proc traverseInvalidReason*(
    found: bool, level: int, mapId: int, hasPosition: bool
): string =
  ## Upstream invalid_reason codes; empty string means a valid result.
  if not found:
    return "character_not_found"
  if level != 60:
    return "character_not_level_60"
  if mapId != 1:
    return "character_left_kalimdor"
  if not hasPosition:
    return "character_position_unavailable"
  result = ""

proc scoreTraverse*(
    found: bool, level: int, mapId: int, hasPosition: bool, worldX: float
): TraverseScore =
  ## Score one fixture snapshot; invalid runs get score 0 and a reason.
  let reason = traverseInvalidReason(found, level, mapId, hasPosition)
  if reason.len > 0:
    return TraverseScore(
      northingYards: 0.0,
      coursePct: 0.0,
      valid: false,
      invalidReason: reason
    )
  let yards = traverseNorthingYards(worldX)
  result = TraverseScore(
    northingYards: yards,
    coursePct: traverseCoursePct(yards),
    valid: true,
    invalidReason: ""
  )

proc findTraverseContainerName*(
    dockerPsOutput: string, envOverride = ""
): string =
  ## Pick *-traverse-coworld-game-1 from docker ps names, or env override.
  let env = envOverride.strip()
  if env.len > 0:
    return env
  for line in dockerPsOutput.splitLines():
    let name = line.strip()
    if name.len == 0:
      continue
    if name.endsWith(TraverseContainerSuffix):
      return name
  result = ""

proc parseTraverseTsv*(tsv: string): Option[TraverseCharacter] =
  ## Parse one Northbound TSV row (9 cols with zone name, or 8 without).
  result = none(TraverseCharacter)
  for line in tsv.splitLines():
    if line.len == 0:
      continue
    let cols = line.split('\t')
    if cols.len < 8:
      continue
    try:
      var ch: TraverseCharacter
      ch.name = cols[0]
      ch.level = parseInt(cols[1])
      ch.mapId = parseInt(cols[2])
      ch.zoneId = parseInt(cols[3])
      ch.online = cols[7] == "1"
      ch.hasPosition = true
      try:
        ch.posX = parseFloat(cols[4])
        ch.posY = parseFloat(cols[5])
        ch.posZ = parseFloat(cols[6])
      except ValueError:
        ch.hasPosition = false
      if cols.len >= 9 and cols[8].len > 0:
        ch.zoneName = cols[8]
      elif ch.zoneId > 0:
        ch.zoneName = &"Zone#{ch.zoneId}"
      return some(ch)
    except ValueError:
      continue

proc traverseUnitIdFromContainer*(containerName: string): string =
  ## Extract launcher unit id from coworld-native-<unit>-traverse-coworld-game-1.
  result = ""
  const prefix = "coworld-native-"
  if not containerName.startsWith(prefix):
    return
  if not containerName.endsWith(TraverseContainerSuffix):
    return
  let mid = containerName[prefix.len .. ^(TraverseContainerSuffix.len + 1)]
  if mid.len == 0 or mid.contains('/'):
    return
  result = mid

proc parseGodviewPlayerPos*(jsonlChunk, playerName: string): Option[TraverseLivePos] =
  ## Last godview JSONL frame that contains playerName. Pure: chunk in, pos out.
  result = none(TraverseLivePos)
  if jsonlChunk.len == 0 or playerName.len == 0:
    return
  let lines = jsonlChunk.splitLines()
  var i = lines.len - 1
  while i >= 0:
    let line = lines[i]
    dec i
    if line.len == 0 or playerName notin line:
      continue
    try:
      let root = parseJson(line)
      if root.kind != JObject or not root.hasKey("players"):
        continue
      let players = root["players"]
      if players.kind != JArray:
        continue
      for p in players:
        if p.kind != JObject:
          continue
        if p{"name"}.getStr() != playerName:
          continue
        if not p.hasKey("x") or not p.hasKey("y") or not p.hasKey("z"):
          continue
        var live = TraverseLivePos(
          x: p["x"].getFloat(),
          y: p["y"].getFloat(),
          z: p["z"].getFloat(),
          mapId: 0,
          level: 0,
          hasMap: false,
          hasLevel: false
        )
        if root.hasKey("map") and root["map"].kind == JInt:
          live.mapId = root["map"].getInt()
          live.hasMap = true
        if p.hasKey("level") and p["level"].kind == JInt:
          live.level = p["level"].getInt()
          live.hasLevel = true
        return some(live)
    except CatchableError:
      continue

proc readFileTail*(path: string, maxBytes: int): string =
  ## Last maxBytes of a file (UTF-8 best-effort). Empty on error.
  result = ""
  if maxBytes <= 0 or path.len == 0 or not fileExists(path):
    return
  try:
    var f = open(path, fmRead)
    defer:
      f.close()
    let size = f.getFileSize()
    if size <= 0:
      return
    if size <= maxBytes:
      result = f.readAll()
      return
    f.setFilePos(size - maxBytes)
    result = f.readAll()
    let nl = result.find('\n')
    if nl >= 0 and nl + 1 < result.len:
      result = result[nl + 1 .. ^1]
  except CatchableError:
    result = ""

proc latestGodviewFile*(capturesDir: string): string =
  ## Newest godview_*.jsonl under capturesDir by filename (timestamp in name).
  result = ""
  if capturesDir.len == 0 or not dirExists(capturesDir):
    return
  var bestName = ""
  for kind, path in walkDir(capturesDir):
    if kind != pcFile:
      continue
    let base = path.extractFilename()
    if not base.startsWith("godview_") or not base.endsWith(".jsonl"):
      continue
    if bestName.len == 0 or base > bestName:
      bestName = base
      result = path

proc resolveTraverseCapturesDir*(containerName: string): string =
  ## Host captures dir for a traverse container (SYSTEM_TRAVERSE_CAPTURES wins).
  let env = getEnv("SYSTEM_TRAVERSE_CAPTURES", "").strip()
  if env.len > 0:
    return absolutePath(env)
  let unit = traverseUnitIdFromContainer(containerName)
  if unit.len == 0:
    return ""
  result = getHomeDir() / TraverseCapturesRel / unit / "leagues/traverse/captures"

proc liveTraversePosFromCaptures*(
    capturesDir: string, playerName = TraverseCharacterName
): Option[TraverseLivePos] =
  ## Live fixture position from the latest godview shard tail.
  result = none(TraverseLivePos)
  let path = latestGodviewFile(capturesDir)
  if path.len == 0:
    return
  let chunk = readFileTail(path, GodviewTailBytes)
  result = parseGodviewPlayerPos(chunk, playerName)

proc applyLiveTraversePos*(
    ch: var TraverseCharacter, live: TraverseLivePos
) =
  ## Overlay godview x/y/z (and map/level when present) onto a DB row.
  ch.posX = live.x
  ch.posY = live.y
  ch.posZ = live.z
  ch.hasPosition = true
  if live.hasMap:
    ch.mapId = live.mapId
  if live.hasLevel and live.level > 0:
    ch.level = live.level

proc gameContainer(): string =
  ## Resolve the coworld-game MariaDB / world container name.
  result = getEnv("SYSTEM_MYSQL_CONTAINER", DefaultGameContainer)

proc chatLogPath*(): string =
  ## Absolute path to VMaNGOS Chat.log (SYSTEM_CHAT_LOG wins).
  let env = getEnv("SYSTEM_CHAT_LOG", "")
  if env.len > 0:
    return absolutePath(env)
  result = absolutePath(DefaultChatLogRel)

proc dockerMariadbSelectIn(container, sql: string): string =
  ## Run a SELECT via docker exec + mariadb on a named container (TSV).
  let process = startProcess(
    "docker",
    args = [
      "exec", container,
      "mariadb",
      &"-u{DbUser}",
      &"-p{DbPass}",
      DbName,
      "-N", "-B",
      "-e", sql
    ],
    options = {poUsePath}
  )
  let output = process.outputStream.readAll()
  let err = process.errorStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(IOError,
      &"mariadb query failed (exit {exitCode}) via docker exec {container}: {err}\n{output}")
  result = output

proc dockerMariadbSelect(sql: string): string =
  ## Run a SELECT via docker exec + mariadb (TSV stdout). SELECT-only path.
  result = dockerMariadbSelectIn(gameContainer(), sql)

proc fetchRosterTsv(): string =
  ## Read character roster via docker exec + mariadb (SELECT only).
  result = dockerMariadbSelect(RosterSql)

proc listDockerContainerNames(): string =
  ## docker ps names (one per line). Empty on error — never raises.
  try:
    let process = startProcess(
      "docker",
      args = ["ps", "--format", "{{.Names}}"],
      options = {poUsePath}
    )
    let output = process.outputStream.readAll()
    discard process.errorStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      return ""
    result = output
  except CatchableError:
    result = ""

proc resolveTraverseContainer*(): string =
  ## Live discovery: SYSTEM_TRAVERSE_CONTAINER or docker ps suffix match.
  result = findTraverseContainerName(
    listDockerContainerNames(),
    getEnv("SYSTEM_TRAVERSE_CONTAINER", "")
  )

proc dockerContainerStartedAt*(container: string): string =
  ## docker inspect StartedAt for one container. Empty on error.
  result = ""
  if container.len == 0:
    return
  try:
    let process = startProcess(
      "docker",
      args = ["inspect", "--format", "{{.State.StartedAt}}", container],
      options = {poUsePath}
    )
    let output = process.outputStream.readAll().strip()
    discard process.errorStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      return ""
    result = output
  except CatchableError:
    result = ""

proc traverseClockForContainer*(container: string, nowUnix: int64): TraverseClock =
  ## Episode wall clock from container start → now (league 45:00 limit).
  result = TraverseClock(known: false, limitSec: TraverseEpisodeLimitSeconds)
  let started = parseDockerStartedAtEpoch(dockerContainerStartedAt(container))
  if started.isNone:
    return
  result = traverseClockAt(nowUnix, started.get, TraverseEpisodeLimitSeconds)

proc traverseStatus*(): TraverseStatus =
  ## Traverse tab telemetry: characters DB identity + godview live position.
  ## VMaNGOS only flushes position_x on save/logout, so yard score must come
  ## from the league godview capture while Northbound is online.
  result = TraverseStatus(
    containerFound: false,
    containerName: "",
    characterFound: false,
    character: TraverseCharacter(),
    score: scoreTraverse(false, 0, 0, false, 0.0),
    livePos: false,
    clock: TraverseClock(known: false, limitSec: TraverseEpisodeLimitSeconds)
  )
  let container = resolveTraverseContainer()
  if container.len == 0:
    return
  result.containerFound = true
  result.containerName = container
  result.clock = traverseClockForContainer(container, getTime().toUnix)
  var tsv = ""
  try:
    tsv = dockerMariadbSelectIn(container, TraverseSql)
  except CatchableError:
    # Container listed but DB unreachable — keep found=true, no character.
    return
  let chOpt = parseTraverseTsv(tsv)
  if chOpt.isNone:
    result.score = scoreTraverse(false, 0, 0, false, 0.0)
    return
  var ch = chOpt.get
  result.characterFound = true
  let live = liveTraversePosFromCaptures(resolveTraverseCapturesDir(container))
  if live.isSome:
    applyLiveTraversePos(ch, live.get)
    result.livePos = true
  result.character = ch
  result.score = scoreTraverse(
    true, ch.level, ch.mapId, ch.hasPosition, ch.posX
  )

proc isSafeSqlName*(name: string): bool =
  ## Character names we embed in SQL: letters/digits only (classic names).
  if name.len == 0 or name.len > 12:
    return false
  for c in name:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'}:
      return false
  result = true

proc questLogSqlFor*(name: string): string =
  ## Quest-log SELECT for one character. Rejects unsafe names.
  if not isSafeSqlName(name):
    raise newException(ValueError, &"unsafe character name for quest log: {name}")
  result = QuestLogSqlTemplate.replace("$$NAME$$", name)

proc questStatusLabel*(status: int): string =
  ## VMaNGOS QuestStatus → short dashboard label.
  case status
  of 1: "complete"
  of 3: "active"
  of 5: "failed"
  else: "other"

proc formatQuestProgress*(
    mobCur, mobNeed, itemCur, itemNeed: array[4, int]
): string =
  ## Compact objective progress: "3/10 · 1/5" from mob/item slots with needs.
  var bits: seq[string] = @[]
  for i in 0 .. 3:
    if mobNeed[i] > 0:
      bits.add(&"{mobCur[i]}/{mobNeed[i]}")
  for i in 0 .. 3:
    if itemNeed[i] > 0:
      bits.add(&"{itemCur[i]}/{itemNeed[i]}")
  result = bits.join(" · ")

proc parseQuestLogTsv*(tsv: string): seq[QuestLogEntry] =
  ## Parse quest-log TSV rows (22 columns) into entries.
  result = @[]
  for line in tsv.splitLines():
    if line.len == 0:
      continue
    let cols = line.split('\t')
    if cols.len < 22:
      continue
    try:
      let questId = parseInt(cols[0])
      let statusCode = parseInt(cols[1])
      var mobCur, mobNeed, itemCur, itemNeed: array[4, int]
      for i in 0 .. 3:
        mobCur[i] = parseInt(cols[2 + i])
        itemCur[i] = parseInt(cols[6 + i])
        mobNeed[i] = parseInt(cols[12 + i])
        itemNeed[i] = parseInt(cols[16 + i])
      result.add(QuestLogEntry(
        questId: questId,
        statusCode: statusCode,
        status: questStatusLabel(statusCode),
        title: cols[10],
        level: parseInt(cols[11]),
        progress: formatQuestProgress(mobCur, mobNeed, itemCur, itemNeed)
      ))
    except ValueError:
      discard

proc listCharacterQuests*(name: string): seq[QuestLogEntry] =
  ## Active (unrewarded) quest log for one character. SELECT only.
  result = parseQuestLogTsv(dockerMariadbSelect(questLogSqlFor(name)))

proc xpProgress*(xp, nextLevelXp: int): tuple[toLevel, pct: int] =
  ## Derive remaining XP and 0..100 percent into the current level.
  if nextLevelXp <= 0:
    return (toLevel: 0, pct: 0)
  let clamped = max(0, min(xp, nextLevelXp))
  let toLevel = max(0, nextLevelXp - clamped)
  let pct = (clamped * 100) div nextLevelXp
  result = (toLevel: toLevel, pct: pct)

proc lifeState*(online: bool, characterFlags: int, health: int): string =
  ## Derive a single life label for the Status Window.
  ## Ghost bit wins over online (corpses persist offline). Dead = online,
  ## not ghost, health 0 (release-spirit popup still up).
  if (characterFlags and CharacterFlagGhost) != 0:
    return "ghost"
  if online and health <= 0:
    return "dead"
  if online:
    return "alive"
  return "offline"

proc lifeLabel*(life: string): string =
  ## Title-case label for life state tokens.
  case life
  of "alive": "Alive"
  of "ghost": "Ghost"
  of "dead": "Dead"
  of "offline": "Offline"
  else: life

proc primaryPower*(
    classId: int,
    power1, power2, power4, baseMana: int
): tuple[kind: string, cur: int, max: int] =
  ## Pick the class's primary resource from classic power fields.
  ## Warrior → rage (cap 100), Rogue → energy (cap 100), else mana.
  case classId
  of 1: # Warrior
    result = (kind: "rage", cur: power2, max: 100)
  of 4: # Rogue
    result = (kind: "energy", cur: power4, max: 100)
  else:
    let mx = if baseMana > 0: baseMana else: 0
    result = (kind: "mana", cur: power1, max: mx)

proc parseRosterTsv*(tsv: string): seq[Character] =
  ## Parse mariadb -N -B TSV into Character rows.
  ## Columns (current, 21):
  ##   name level class race money online xp next_level_xp
  ##   character_flags health zone_id map_id zone_name
  ##   power1 power2 power4 basehp basemana
  ##   position_x position_y position_z
  ## Older fixtures with 6, 8, 11, 13, or 18 columns still parse (defaults).
  result = @[]
  for line in tsv.splitLines():
    let row = line.strip()
    if row.len == 0:
      continue
    let cols = row.split('\t')
    if cols.len < 6:
      raise newException(ValueError, &"expected >=6 TSV columns, got {cols.len}: {row}")
    let classId = cols[2].parseInt()
    let raceId = cols[3].parseInt()
    let money = cols[4].parseInt()
    let online = cols[5].parseInt() != 0
    var xp = 0
    var nextLevelXp = 0
    var characterFlags = 0
    var health = 1 ## unknown → treat as not-dead for legacy rows
    var zoneId = 0
    var mapId = 0
    var zoneName = ""
    var power1 = 0
    var power2 = 0
    var power4 = 0
    var baseHp = 0
    var baseMana = 0
    var posX = 0.0
    var posY = 0.0
    var posZ = 0.0
    if cols.len >= 8:
      xp = cols[6].parseInt()
      nextLevelXp = cols[7].parseInt()
    elif cols.len == 7:
      xp = cols[6].parseInt()
    if cols.len >= 13:
      characterFlags = cols[8].parseInt()
      health = cols[9].parseInt()
      zoneId = cols[10].parseInt()
      mapId = cols[11].parseInt()
      zoneName = cols[12]
    elif cols.len >= 11:
      # flags health zone without map/name
      characterFlags = cols[8].parseInt()
      health = cols[9].parseInt()
      zoneId = cols[10].parseInt()
      zoneName = if zoneId > 0: &"Zone#{zoneId}" else: ""
    if cols.len >= 18:
      power1 = cols[13].parseInt()
      power2 = cols[14].parseInt()
      power4 = cols[15].parseInt()
      baseHp = cols[16].parseInt()
      baseMana = cols[17].parseInt()
    if cols.len >= 21:
      posX = cols[18].parseFloat()
      posY = cols[19].parseFloat()
      posZ = cols[20].parseFloat()
    let life = lifeState(online, characterFlags, health)
    let prog = xpProgress(xp, nextLevelXp)
    let pow = primaryPower(classId, power1, power2, power4, baseMana)
    # When live vitals exceed class base (gear/buffs), surface that as max so
    # bars never read past 100% / "cur/max" never looks inverted.
    let maxHp =
      if baseHp > 0: max(baseHp, health)
      elif health > 0: health
      else: 0
    let maxPow =
      if pow.max > 0: max(pow.max, pow.cur)
      elif pow.cur > 0: pow.cur
      else: 0
    result.add(Character(
      name: cols[0],
      level: cols[1].parseInt(),
      classId: classId,
      className: className(classId),
      raceId: raceId,
      raceName: raceName(raceId),
      money: money,
      gold: formatGold(money),
      online: online,
      xp: xp,
      nextLevelXp: nextLevelXp,
      xpToLevel: prog.toLevel,
      xpPct: prog.pct,
      life: life,
      isGhost: (characterFlags and CharacterFlagGhost) != 0,
      health: health,
      maxHealth: maxHp,
      power: pow.cur,
      maxPower: maxPow,
      powerKind: pow.kind,
      zoneId: zoneId,
      zoneName: zoneName,
      mapId: mapId,
      posX: posX,
      posY: posY,
      posZ: posZ
    ))

proc seatControlPort*(name: string): int =
  ## Compatibility field for API consumers. The embedded Lua seats have no
  ## control socket; their liveness comes from PID + status heartbeat files.
  discard name
  result = 0

proc isTcpPortOpen*(host: string, port: int, timeoutMs = 80): bool =
  ## True when a TCP connect to host:port succeeds within timeoutMs.
  if port <= 0:
    return false
  var sock: Socket
  try:
    sock = newSocket()
    sock.connect(host, Port(port), timeout = timeoutMs)
    result = true
  except CatchableError:
    result = false
  finally:
    if sock != nil:
      sock.close()

proc seatRuntimeUp*(name: string): bool

proc enrichControlPlane*(characters: var seq[Character]) =
  ## Fill compatibility control fields from the embedded Lua seat runtime.
  for i in 0 ..< characters.len:
    characters[i].controlPort = 0
    characters[i].controlUp = seatRuntimeUp(characters[i].name)

proc rosterSortRank*(name: string): int =
  ## Stable party order: Murist → Shadowfel → Igris → Tusk → Beru → rest A–Z.
  for i, n in RosterDisplayOrder:
    if n == name:
      return i
  result = 100 + name.len # keep non-bot-seat stable-ish by name length then cmp

proc sortCharactersForDisplay*(characters: var seq[Character]) =
  ## Main characters first ordering for the Status Window.
  characters.sort(proc (a, b: Character): int =
    let ra = rosterSortRank(a.name)
    let rb = rosterSortRank(b.name)
    if ra != rb:
      return cmp(ra, rb)
    return cmp(a.name, b.name)
  )

proc listCharacters*(): seq[Character] =
  ## Single dispatch path: HTTP + MCP interfaces get roster data from here.
  result = parseRosterTsv(fetchRosterTsv())
  enrichControlPlane(result)
  sortCharactersForDisplay(result)

proc isFoundationSeat*(name: string): bool =
  ## Pre-built coworld tournament / foundation seats (not Murist + bot seats).
  ## Hide by default on the dashboard; toggle shows them again.
  let n = name.strip()
  if n.len == 0:
    return false
  let lower = n.toLowerAscii()
  # Botmage, Botpriest, Botwarrior, …
  if lower.startsWith("bot"):
    return true
  # Explicit extras from the coworld foundation roster.
  case lower
  of "nightsun", "cowcam":
    return true
  else:
    return false

proc filterCharacters*(characters: seq[Character], includeFoundation = false): seq[Character] =
  ## Main characters first view: drop foundation seats unless includeFoundation.
  if includeFoundation:
    return characters
  result = @[]
  for s in characters:
    if not isFoundationSeat(s.name):
      result.add(s)

proc charactersToJson*(characters: seq[Character]): JsonNode =
  ## Serialize the roster for the MCP JSON view (and any future JSON API).
  result = %*[]
  for s in characters:
    result.add(%*{
      "name": s.name,
      "level": s.level,
      "class_id": s.classId,
      "class": s.className,
      "race_id": s.raceId,
      "race": s.raceName,
      "money": s.money,
      "gold": s.gold,
      "online": s.online,
      "xp": s.xp,
      "next_level_xp": s.nextLevelXp,
      "xp_to_level": s.xpToLevel,
      "xp_pct": s.xpPct,
      "life": s.life,
      "is_ghost": s.isGhost,
      "health": s.health,
      "max_health": s.maxHealth,
      "power": s.power,
      "max_power": s.maxPower,
      "power_kind": s.powerKind,
      "zone_id": s.zoneId,
      "zone": s.zoneName,
      "map_id": s.mapId,
      "x": s.posX,
      "y": s.posY,
      "z": s.posZ,
      "control_port": s.controlPort,
      "control_up": s.controlUp
    })

proc escapeHtml(s: string): string =
  ## Minimal HTML escape for character names and labels.
  result = s.multiReplace([
    ("&", "&amp;"),
    ("<", "&lt;"),
    (">", "&gt;"),
    ("\"", "&quot;")
  ])

proc escapeXml*(s: string): string =
  ## Escape text for a SOAP command element (& < > at minimum).
  result = s.multiReplace([
    ("&", "&amp;"),
    ("<", "&lt;"),
    (">", "&gt;")
  ])

# ---------------------------------------------------------------------------
# Chat.log parser + ring buffer (outbound telemetry: addon → System)
# ---------------------------------------------------------------------------

proc extractHeaderField(header, key: string): string =
  ## Pull `key VALUE` from the Chat.log paren header (value ends at comma or ')').
  let needle = key & " "
  let i = header.find(needle)
  if i < 0:
    return ""
  let start = i + needle.len
  var j = start
  while j < header.len and header[j] != ',' and header[j] != ')':
    inc j
  result = header[start ..< j].strip()

proc parseAddonEvent*(line: string): Option[AddonEvent] =
  ## Parse one Chat.log line into an AddonEvent if it carries an addon prefix.
  ##
  ## Header format (vmangos): timestamp, `[Chat]`,
  ## `(acc %u, ip %s, guid %u, name %s, map %u, pos %g %g %g)`, then a type
  ## tag like `[Say]`, then `Name:guid : message`. The message is everything
  ## after the first `" : "` that follows the chat-type tag (messages may
  ## contain colons).
  let stripped = line.strip(leading = false, trailing = true)
  if stripped.len == 0:
    return none(AddonEvent)

  const chatTag = " [Chat] "
  let chatIdx = stripped.find(chatTag)
  if chatIdx < 0:
    return none(AddonEvent)
  let timeStr = stripped[0 ..< chatIdx]

  let typeOpen = stripped.find(") [", chatIdx)
  if typeOpen < 0:
    return none(AddonEvent)
  let typeClose = stripped.find("] ", typeOpen + 3)
  if typeClose < 0:
    return none(AddonEvent)

  const msgSep = " : "
  let sepIdx = stripped.find(msgSep, typeClose)
  if sepIdx < 0:
    return none(AddonEvent)
  let message = stripped[sepIdx + msgSep.len .. ^1]

  var kind, payload: string
  if message.startsWith(SaPrefix):
    let rest = message[SaPrefix.len .. ^1]
    let sp = rest.find(' ')
    if sp < 0:
      kind = rest
      payload = ""
    else:
      kind = rest[0 ..< sp]
      payload = rest[sp + 1 .. ^1]
  elif message.startsWith(LegacyPrefix):
    kind = "legacy"
    payload = message[LegacyPrefix.len .. ^1]
  else:
    return none(AddonEvent)

  # Header through the closing paren before the type tag.
  let header = stripped[0 .. typeOpen]
  let guidStr = extractHeaderField(header, "guid")
  let nameStr = extractHeaderField(header, "name")
  let mapStr = extractHeaderField(header, "map")
  let posRaw = extractHeaderField(header, "pos")
  var pos: array[3, float]
  let posParts = posRaw.splitWhitespace()
  if posParts.len >= 3:
    pos[0] = posParts[0].parseFloat()
    pos[1] = posParts[1].parseFloat()
    pos[2] = posParts[2].parseFloat()

  var guid = 0
  var mapId = 0
  if guidStr.len > 0:
    guid = guidStr.parseInt()
  if mapStr.len > 0:
    mapId = mapStr.parseInt()

  result = some(AddonEvent(
    id: 0,
    time: timeStr,
    name: nameStr,
    guid: guid,
    map: mapId,
    pos: pos,
    kind: kind,
    payload: payload,
    raw: stripped
  ))

proc appendAddonEvent*(
    buf: var seq[AddonEvent],
    nextId: var int,
    event: AddonEvent,
    cap = EventRingCap
): AddonEvent =
  ## Assign a monotonic id, append, and drop oldest when over cap.
  ## Pure-ish (no lock) so unit tests can exercise the ring without threads.
  var e = event
  e.id = nextId
  inc nextId
  buf.add(e)
  while buf.len > cap:
    buf.delete(0)
  result = e

proc selectRecentEvents*(
    buf: seq[AddonEvent],
    limit = 50,
    kind = ""
): seq[AddonEvent] =
  ## Newest-first view of a buffer, optional kind filter.
  result = @[]
  if buf.len == 0 or limit <= 0:
    return
  for i in countdown(buf.high, 0):
    let e = buf[i]
    if kind.len > 0 and e.kind != kind:
      continue
    result.add(e)
    if result.len >= limit:
      break

proc recentEvents*(limit = 50, kind = ""): seq[AddonEvent] =
  ## Newest first, optional kind filter — single dispatch for dashboard + MCP.
  withLock gEventLock:
    result = selectRecentEvents(gEvents, limit, kind)

proc eventToJson*(e: AddonEvent): JsonNode =
  ## Serialize one addon event for MCP / JSON APIs.
  result = %*{
    "id": e.id,
    "time": e.time,
    "name": e.name,
    "guid": e.guid,
    "map": e.map,
    "pos": [e.pos[0], e.pos[1], e.pos[2]],
    "kind": e.kind,
    "payload": e.payload,
    "raw": e.raw
  }

proc eventsToJson*(events: seq[AddonEvent]): JsonNode =
  ## Serialize a list of addon events.
  result = %*[]
  for e in events:
    result.add(eventToJson(e))

proc pushSystemEvent*(name, kind, payload: string) {.gcsafe.} =
  ## Append a System-generated line to the same ring the addon feeds, so
  ## babysitter actions show up in the dashboard event tail / MCP addon_events.
  let ev = AddonEvent(
    time: now().format("yyyy-MM-dd HH:mm:ss"),
    name: name,
    kind: kind,
    payload: payload,
    raw: &"<SYS> {kind} {name} {payload}"
  )
  {.gcsafe.}:
    withLock gEventLock:
      discard appendAddonEvent(gEvents, gNextEventId, ev)

# ---------------------------------------------------------------------------
# Inventory over the chat bus (ticket 0052)
#
# The addon emits compact ASCII over /say, VMaNGOS writes it to Chat.log, and
# the tailer above already delivers it here. Wire format (addon-side encoder:
# `ShadowArmy.invModel`, addons/ShadowArmy/ShadowArmy.lua):
#
#   <SA> inv  <seq>/<total> <id>:<count>,<id>:<count>,…   full snapshot
#   <SA> invd <seq>/<total> +<id>:<count>,-<id>,…         delta
#
# `inv` REPLACES the known bags, but only once every line of the set is in
# hand — inv lines are droppable under emit-queue pressure, so a set with a
# hole must never be applied as if it were the whole inventory (that would
# silently under-report bags, which is worse than showing older data). Parts
# are assembled in any order inside InvSnapshotWindowSec.
# `invd` PATCHES it: `+id:count` is the item's new TOTAL count (absolute, so
# it is idempotent and self-heals a dropped line) and `-id` removes the id.
# Counts are summed across bags, so an id appears once per line set.
#
# The parser is deliberately loose: unknown tokens are ignored, `id:count`
# without a sign works, separators may be spaces or commas, and the optional
# `seq=<n>` guard drops a delta that lost a race for one item id.
# ---------------------------------------------------------------------------

type
  InvPair* = tuple[itemId, count: int]

  InvLine* = object
    ## One parsed `<SA> inv|invd …` payload (pure; no state).
    isFull*: bool
    part*: int ## 0 when the emitter sent no `<seq>/<total>` header
    parts*: int
    seqNo*: int ## 0 when the emitter sent no sequence
    bag*: int
    hasBag*: bool
    pairs*: seq[InvPair] ## count 0 = remove this id

  InventoryItem* = object
    ## Latest known total count of one item id for one character.
    itemId*: int
    count*: int
    seqNo*: int
    updatedAt*: float ## epoch seconds when this line was applied

  CharacterInventory* = object
    ## Latest-known bags for one character, assembled from chat-bus lines.
    name*: string
    items*: Table[int, InventoryItem] ## committed view (what the panel shows)
    pending*: Table[int, InventoryItem] ## snapshot still assembling
    updatedAt*: float ## epoch the committed view last CHANGED (0 = never)
    lastLineAt*: float ## epoch of the newest inv line, applied or not
    snapshotAt*: float ## epoch the in-flight snapshot started (0 = none)
    partsTotal*: int ## `<total>` of the in-flight snapshot
    partsSeen*: seq[int]
    lines*: int ## inv lines seen since boot
    lastKind*: string ## "full" | "delta"
    complete*: bool ## a whole snapshot has been committed at least once

  ItemInfo* = object
    ## World DB facts for one item id (names / vendor price join).
    itemId*: int
    name*: string
    sellPrice*: int ## copper, vendor sell
    quality*: int

var
  gInvLock: Lock
  gInventories: Table[string, CharacterInventory]
  gItemInfoLock: Lock
  gItemInfoCache: Table[int, ItemInfo]

initLock(gInvLock)
initLock(gItemInfoLock)

proc isAllDigits(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if c notin {'0' .. '9'}:
      return false
  result = true

proc parseIntOr(s: string, fallback = 0): int =
  try:
    result = parseInt(s)
  except ValueError:
    result = fallback

proc isInvFullKind*(kind: string): bool =
  ## `inv` is the full-snapshot channel; `invd` carries deltas.
  kind == "inv"

proc isInvKind*(kind: string): bool =
  kind == "inv" or kind == "invd"

proc parseInvPayload*(payload: string, isFull = false): InvLine =
  ## Tolerant parse of one inventory payload. Never raises; unknown tokens are
  ## ignored so the emitter can grow fields without breaking The System.
  result = InvLine(isFull: isFull, pairs: @[])
  let flat = payload.multiReplace([(",", " "), (";", " ")])
  for rawTok in flat.splitWhitespace():
    if rawTok.len == 0:
      continue
    let lower = rawTok.toLowerAscii()
    case lower
    of "full", "snap", "snapshot", "all":
      result.isFull = true
      continue
    of "delta", "upd", "update", "diff":
      result.isFull = false
      continue
    else:
      discard
    if lower.startsWith("seq="):
      result.seqNo = parseIntOr(lower[4 .. ^1])
      continue
    if lower.startsWith("bag="):
      result.bag = parseIntOr(lower[4 .. ^1])
      result.hasBag = true
      continue
    # `-<id>` removes an id outright (delta form).
    if rawTok.len > 1 and rawTok[0] == '-' and isAllDigits(rawTok[1 .. ^1]):
      result.pairs.add((itemId: parseIntOr(rawTok[1 .. ^1]), count: 0))
      continue
    # `+<id>:<count>` / `<id>:<count>` — the count is an absolute total.
    var tok = rawTok
    if tok.len > 1 and tok[0] == '+':
      tok = tok[1 .. ^1]
    let colon = tok.find(':')
    if colon > 0:
      let idPart = tok[0 ..< colon]
      var countPart = tok[colon + 1 .. ^1]
      let neg = countPart.startsWith("-")
      if neg:
        countPart = countPart[1 .. ^1]
      if isAllDigits(idPart) and isAllDigits(countPart):
        let count = if neg: 0 else: parseIntOr(countPart)
        result.pairs.add((itemId: parseIntOr(idPart), count: count))
      continue
    let slash = tok.find('/')
    if slash > 0:
      let a = tok[0 ..< slash]
      let b = tok[slash + 1 .. ^1]
      if isAllDigits(a) and isAllDigits(b):
        result.part = parseIntOr(a)
        result.parts = parseIntOr(b)
      continue
    if lower.len > 1 and lower[0] == 's' and isAllDigits(lower[1 .. ^1]):
      result.seqNo = parseIntOr(lower[1 .. ^1])
      continue
    if lower.len > 1 and lower[0] == 'b' and isAllDigits(lower[1 .. ^1]):
      result.bag = parseIntOr(lower[1 .. ^1])
      result.hasBag = true
      continue

proc newCharacterInventory*(name: string): CharacterInventory =
  ## Empty inventory record for one character.
  CharacterInventory(
    name: name,
    items: initTable[int, InventoryItem](),
    pending: initTable[int, InventoryItem](),
    partsSeen: @[]
  )

proc applyInvPairs(
    dest: var Table[int, InventoryItem], line: InvLine, now: float,
    guardSeq: bool
) =
  ## Fold `id:count` pairs into one map. count 0 removes the id.
  for p in line.pairs:
    if p.itemId <= 0:
      continue
    if guardSeq and line.seqNo > 0 and dest.hasKey(p.itemId) and
        dest[p.itemId].seqNo > line.seqNo:
      continue # a newer delta already moved this id
    if p.count <= 0:
      dest.del(p.itemId)
    else:
      dest[p.itemId] = InventoryItem(
        itemId: p.itemId, count: p.count, seqNo: line.seqNo, updatedAt: now)

proc invAssembling*(inv: CharacterInventory): bool =
  ## True while a multi-line snapshot is still missing parts.
  inv.snapshotAt > 0.0

proc applyInvLine*(inv: var CharacterInventory, line: InvLine, now: float) =
  ## Fold one parsed line into the latest-known inventory.
  ## Full lines assemble into `pending` and only replace `items` when the whole
  ## set has landed; delta lines patch `items` (and any in-flight snapshot) now.
  inc inv.lines
  inv.lastLineAt = now
  if line.isFull:
    inv.lastKind = "full"
    let sameBatch =
      inv.snapshotAt > 0.0 and
      (now - inv.snapshotAt) <= InvSnapshotWindowSec and
      line.parts == inv.partsTotal
    if not sameBatch:
      inv.pending.clear()
      inv.partsSeen = @[]
      inv.partsTotal = line.parts
      inv.snapshotAt = now
    applyInvPairs(inv.pending, line, now, guardSeq = false)
    let partIdx = if line.part > 0: line.part else: inv.partsSeen.len + 1
    if partIdx notin inv.partsSeen:
      inv.partsSeen.add(partIdx)
    if inv.partsTotal <= 0 or inv.partsSeen.len >= inv.partsTotal:
      # Whole set in hand: this is now the truth about the bags.
      inv.items = inv.pending
      inv.pending = initTable[int, InventoryItem]()
      inv.partsSeen = @[]
      inv.snapshotAt = 0.0
      inv.complete = true
      inv.updatedAt = now
  else:
    if line.pairs.len == 0:
      return
    inv.lastKind = "delta"
    applyInvPairs(inv.items, line, now, guardSeq = true)
    if invAssembling(inv):
      # Keep an in-flight snapshot honest: the delta is newer than its parts.
      applyInvPairs(inv.pending, line, now, guardSeq = true)
    inv.updatedAt = now

proc recordInventoryEvent*(e: AddonEvent) {.gcsafe.} =
  ## Chat.log hook: fold one `<SA> inv|invd …` event into the per-character store.
  if not isInvKind(e.kind) or e.name.len == 0:
    return
  let line = parseInvPayload(e.payload, isFull = isInvFullKind(e.kind))
  let nowSec = epochTime()
  {.gcsafe.}:
    withLock gInvLock:
      var inv =
        if gInventories.hasKey(e.name): gInventories[e.name]
        else: newCharacterInventory(e.name)
      applyInvLine(inv, line, nowSec)
      gInventories[e.name] = inv

proc characterInventory*(name: string): Option[CharacterInventory] =
  ## Latest-known inventory for one character — single dispatch (HTTP + MCP).
  withLock gInvLock:
    if gInventories.hasKey(name):
      result = some(gInventories[name])
    else:
      result = none(CharacterInventory)

proc inventoryCharacters*(): seq[string] =
  ## Names that have ever reported inventory over the chat bus.
  result = @[]
  withLock gInvLock:
    for name in gInventories.keys:
      result.add(name)
  result.sort()

proc liveInventoryItems*(inv: CharacterInventory): seq[InventoryItem] =
  ## Committed stacks (the panel/MCP view); ordering is the caller's business.
  result = @[]
  for _, item in inv.items:
    if item.count > 0:
      result.add(item)

proc itemInfoSql*(ids: seq[int]): string =
  ## World DB join for item names / vendor prices. `patch` is multi-row per
  ## item, so ORDER BY entry,patch lets the highest patch win on ingest.
  var idList = ""
  for i, id in ids:
    if i > 0:
      idList.add(",")
    idList.add($id)
  result = "SELECT entry, name, sell_price, quality FROM mangos.item_template " &
    &"WHERE patch <= 10 AND entry IN ({idList}) ORDER BY entry, patch"

proc parseItemInfoTsv*(tsv: string): seq[ItemInfo] =
  ## Parse the item join TSV (entry, name, sell_price, quality).
  result = @[]
  for rawLine in tsv.splitLines():
    let line = rawLine.strip(leading = false)
    if line.len == 0:
      continue
    let cols = line.split('\t')
    if cols.len < 4:
      continue
    let entry = parseIntOr(cols[0].strip())
    if entry <= 0:
      continue
    result.add(ItemInfo(
      itemId: entry,
      name: cols[1].strip(),
      sellPrice: parseIntOr(cols[2].strip()),
      quality: parseIntOr(cols[3].strip())
    ))

proc lookupItemInfo*(ids: seq[int]): Table[int, ItemInfo] =
  ## Cached world-DB lookup: item facts never change under a running realm, so
  ## a poll only pays for ids it has not seen before (and stays useful when the
  ## realm is down — unknown ids simply render as their id).
  result = initTable[int, ItemInfo]()
  var missing: seq[int] = @[]
  withLock gItemInfoLock:
    for id in ids:
      if gItemInfoCache.hasKey(id):
        result[id] = gItemInfoCache[id]
      else:
        missing.add(id)
  if missing.len == 0:
    return
  var rows: seq[ItemInfo] = @[]
  try:
    rows = parseItemInfoTsv(dockerMariadbSelect(itemInfoSql(missing)))
  except CatchableError:
    return # realm down / DB busy: ids stay unnamed, panel still renders
  var found = initTable[int, ItemInfo]()
  for row in rows:
    found[row.itemId] = row
  withLock gItemInfoLock:
    for id in missing:
      let info =
        if found.hasKey(id): found[id]
        else: ItemInfo(itemId: id, name: "", sellPrice: 0, quality: 0)
      gItemInfoCache[id] = info
      result[id] = info

proc inventoryToJson*(inv: CharacterInventory, info: Table[int, ItemInfo]): JsonNode =
  ## Serialize one character's latest-known inventory (MCP + JSON APIs).
  var items = %*[]
  var totalSell = 0
  for item in liveInventoryItems(inv):
    let known = info.hasKey(item.itemId)
    let sell = if known: info[item.itemId].sellPrice else: 0
    totalSell += sell * item.count
    items.add(%*{
      "item_id": item.itemId,
      "count": item.count,
      "name": if known: info[item.itemId].name else: "",
      "sell_price": sell,
      "quality": if known: info[item.itemId].quality else: 0
    })
  result = %*{
    "name": inv.name,
    "items": items,
    "item_count": items.len,
    "total_sell_copper": totalSell,
    "age_sec": (if inv.updatedAt > 0: epochTime() - inv.updatedAt else: -1.0),
    "lines": inv.lines,
    "last_kind": inv.lastKind,
    "assembling": invAssembling(inv),
    "parts_seen": inv.partsSeen.len,
    "parts_total": inv.partsTotal,
    "complete": inv.complete
  }

proc isAdminRequester*(name: string): bool =
  ## True when `name` may trigger System admin actions from the addon chat bus.
  result = name == AdminRequesterName

proc adminActionFromAddonEvent*(e: AddonEvent): string =
  ## Map a parsed `<SA> admin …` event to a dispatch action name, or "".
  ##
  ## Payload forms (first token is the action; trailing tokens ignored):
  ##   respawn_shadow_army
  ##   respawn_shadow_army #3
  ##   respawn
  ##   reload_addon
  ##   reload_addon #1
  ##   tele_party_to_murist
  ##   tele_to_murist #2
  if e.kind != "admin":
    return ""
  if not isAdminRequester(e.name):
    return ""
  let parts = e.payload.strip().splitWhitespace()
  if parts.len == 0:
    return ""
  case parts[0].toLowerAscii()
  of "respawn_shadow_army", "respawn":
    result = "respawn_shadow_army"
  of "reload_addon", "reload":
    result = "reload_addon"
  of "tele_party_to_murist", "tele_to_murist", "tele_party":
    result = "tele_party_to_murist"
  else:
    result = ""

proc tryClaimAdminChatSlot*(): bool =
  ## Debounce: true if this process may run a chat-triggered admin action now.
  let now = epochTime()
  withLock gAdminChatLock:
    if now - gLastAdminChatAt < AdminChatCooldownSec:
      return false
    gLastAdminChatAt = now
    return true

proc adminChatActionFromName*(action: string): AdminChatAction =
  ## Map dispatch name → queue enum (empty / unknown → acaNone).
  case action
  of "respawn_shadow_army": acaRespawnShadowArmy
  of "reload_addon": acaReloadAddon
  of "tele_party_to_murist": acaTelePartyToMurist
  else: acaNone

proc queueAdminFromAddon*(e: AddonEvent) {.gcsafe.} =
  ## Enqueue an admin action for the worker thread (tailer stays GC-safe).
  ## Actual SOAP runs in `adminWorkerLoop` via the same procs as HTTP/MCP.
  let op = adminChatActionFromName(adminActionFromAddonEvent(e))
  if op == acaNone:
    return
  if not tryClaimAdminChatSlot():
    return
  withLock gAdminChatLock:
    # Coalesce: latest wins if the worker is still busy.
    gPendingAdminAction = op

proc pushParsedLine(line: string) {.gcsafe.} =
  ## Parse a complete Chat.log line and append if it is an addon event.
  ## Admin requests (`<SA> admin …`) are queued for the admin worker thread.
  let parsed = parseAddonEvent(line)
  if parsed.isNone:
    return
  let ev = parsed.get
  {.gcsafe.}:
    withLock gEventLock:
      discard appendAddonEvent(gEvents, gNextEventId, ev)
    recordInventoryEvent(ev)
    queueAdminFromAddon(ev)

proc processTailChunk(chunk: string, partial: var string) {.gcsafe.} =
  ## Split a newly-read chunk into complete lines; keep a trailing partial.
  partial.add(chunk)
  while true:
    let nl = partial.find('\n')
    if nl < 0:
      break
    var line = partial[0 ..< nl]
    if line.endsWith("\r"):
      line.setLen(line.len - 1)
    partial = partial[nl + 1 .. ^1]
    if line.len > 0:
      pushParsedLine(line)

proc tailerLoop() {.thread, gcsafe.} =
  ## Poll Chat.log for new bytes; seek to end on first open; reset on truncate.
  var offset: int64 = -1
  var partial = ""
  while true:
    sleep(TailerPollMs)
    var path: string
    {.gcsafe.}:
      path = chatLogPath()
    if not fileExists(path):
      continue
    try:
      let size = getFileSize(path)
      if offset < 0:
        # First open: live events only; do not ingest history.
        offset = size
        partial = ""
        continue
      if size < offset:
        # Rotation or truncation.
        offset = 0
        partial = ""
      if size == offset:
        continue
      let fs = newFileStream(path, fmRead)
      if fs == nil:
        continue
      try:
        fs.setPosition(int(offset))
        let toRead = int(size - offset)
        let chunk = fs.readStr(toRead)
        offset = size
        processTailChunk(chunk, partial)
      finally:
        fs.close()
    except CatchableError:
      # Quiet: missing mid-read is fine; next tick retries.
      discard

proc startChatLogTailer() =
  ## Spawn the Chat.log tailer thread (call once from main before serve).
  createThread(gTailerThread, tailerLoop)

# Defined with SOAP section; admin worker reuses the same interfaces.
proc respawnShadowArmy*(): AdminActionResult
proc reloadAddon*(): JsonNode
proc telePartyToMurist*(): AdminActionResult

proc adminWorkerLoop() {.thread.} =
  ## Runs queued chat-bus admin actions with the same procs as HTTP/MCP.
  ## Kept off the GC-safe Chat.log tailer so SOAP/HTTP is allowed here.
  while true:
    sleep(200)
    var op = acaNone
    {.gcsafe.}:
      withLock gAdminChatLock:
        op = gPendingAdminAction
        gPendingAdminAction = acaNone
    if op == acaNone:
      continue
    # SOAP/HTTP clients are not GC-safe; this worker exists so the tailer can be.
    try:
      {.cast(gcsafe).}:
        case op
        of acaRespawnShadowArmy:
          discard respawnShadowArmy()
        of acaReloadAddon:
          discard reloadAddon()
        of acaTelePartyToMurist:
          discard telePartyToMurist()
        of acaNone:
          discard
    except Exception:
      discard

proc startAdminWorker() =
  ## Spawn the admin chat-bus worker (call once from main before serve).
  createThread(gAdminWorkerThread, adminWorkerLoop)

# ---------------------------------------------------------------------------
# Realm lifecycle (Server panel): status + start/stop via the upstream operator
#
# Operator runs as a detached user systemd unit (wow-realm-op), not as a child
# of system_server. Dashboard restarts must not kill multi-minute compose builds.
# Op status is mirrored to local_data/realm-op.json so a restarted dashboard
# still shows Starting… and can record the exit when the unit finishes.
# ---------------------------------------------------------------------------

proc armyRoot*(): string =
  ## wow-shadow-army repo root holding the Makefile (SYSTEM_ARMY_DIR wins;
  ## default cwd — `make system` / wow-system.service run from the repo root).
  let env = getEnv("SYSTEM_ARMY_DIR", "")
  if env.len > 0:
    return absolutePath(env)
  result = getCurrentDir()

proc realmOpStatePath*(): string =
  ## Durable lifecycle state (survives dashboard restart).
  armyRoot() / "local_data" / "realm-op.json"

proc realmOpLogPath*(): string =
  ## Detached operator stdout/stderr + exit marker.
  armyRoot() / "local_data" / "realm-op.log"

proc upstreamDir*(): string =
  ## Upstream coworld-vanilla-wow checkout (SYSTEM_UPSTREAM_DIR wins).
  let env = getEnv("SYSTEM_UPSTREAM_DIR", "")
  if env.len > 0:
    return absolutePath(env)
  result = absolutePath(DefaultUpstreamRel)

proc parseDockerRunning*(output: string): bool =
  ## Interpret `docker inspect -f {{.State.Running}}` stdout.
  result = output.strip().toLowerAscii() == "true"

proc shortContainerId*(fullId: string): string =
  ## Docker short id: first 12 hex chars of the full Id.
  let id = fullId.strip()
  if id.len == 0:
    return ""
  result = if id.len >= 12: id[0 .. 11] else: id

proc parseDockerInspectProbe*(output: string): tuple[running: bool, id: string] =
  ## Parse `Running\\tId` from docker inspect -f. Missing/garbage → down, no id.
  let line = output.strip()
  if line.len == 0:
    return (false, "")
  let parts = line.split('\t')
  if parts.len < 1:
    return (false, "")
  let running = parseDockerRunning(parts[0])
  let id = if parts.len >= 2: shortContainerId(parts[1]) else: ""
  result = (running, id)

proc probeGameContainer(): tuple[running: bool, id: string] =
  ## One docker inspect: running flag + short container id.
  ## Missing container / docker error = down with empty id (compose rm).
  let container = gameContainer()
  try:
    let process = startProcess(
      "docker",
      args = ["inspect", "-f", "{{.State.Running}}\t{{.Id}}", container],
      options = {poUsePath}
    )
    let output = process.outputStream.readAll()
    discard process.errorStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      return (false, "")
    result = parseDockerInspectProbe(output)
  except CatchableError:
    result = (false, "")

proc containerRunning(): bool =
  ## True when the coworld-game container exists and is running.
  result = probeGameContainer().running

proc serverOpVerb*(op: ServerLifecycleOp): string =
  ## Operator subcommand for a lifecycle op ("" for sloNone).
  case op
  of sloStart: "up"
  of sloStop: "down"
  of sloNone: ""

proc serverOpLabel*(op: ServerLifecycleOp): string =
  ## Short human label for a lifecycle op ("" for sloNone).
  case op
  of sloStart: "start"
  of sloStop: "stop"
  of sloNone: ""

proc serverOpFromLabel*(label: string): ServerLifecycleOp =
  ## Inverse of serverOpLabel for disk state.
  case label
  of "start": sloStart
  of "stop": sloStop
  else: sloNone

proc tailForDisplay*(s: string, maxLen = 600): string =
  ## Keep the tail of operator output (the interesting part) for status lines.
  let clean = s.strip()
  if clean.len <= maxLen:
    return clean
  result = "…" & clean[clean.len - maxLen .. ^1]

proc parseRealmOpExit*(logText: string): int =
  ## Last SYSTEM_REALM_OP_EXIT=N in a log, or -1 if missing.
  result = -1
  for line in logText.splitLines():
    let t = line.strip()
    if t.startsWith(RealmOpExitMarker):
      let raw = t[RealmOpExitMarker.len .. ^1].strip()
      try:
        result = parseInt(raw)
      except ValueError:
        discard

proc runCmdCapture(cmd: string, args: openArray[string]): tuple[exitCode: int, output: string] =
  ## Run a short command; capture combined stdout (stderr merged when possible).
  try:
    let process = startProcess(
      cmd, args = @args, options = {poUsePath, poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    result = (exitCode, output)
  except CatchableError as e:
    result = (1, e.msg)

proc realmOpUnitActive*(): bool =
  ## True while the detached user unit is still running.
  let r = runCmdCapture("systemctl", ["--user", "is-active", "--quiet", RealmOpUnit])
  result = r.exitCode == 0

proc writeRealmOpState(node: JsonNode) =
  ## Persist lifecycle state under local_data/.
  let path = realmOpStatePath()
  createDir(parentDir(path))
  writeFile(path, node.pretty())

proc readRealmOpState(): JsonNode =
  ## Load durable lifecycle state, or empty object.
  let path = realmOpStatePath()
  if not fileExists(path):
    return newJObject()
  try:
    result = parseJson(readFile(path))
  except CatchableError:
    result = newJObject()

proc readRealmOpLog(): string =
  ## Full operator log text (may be empty).
  let path = realmOpLogPath()
  if not fileExists(path):
    return ""
  try:
    result = readFile(path)
  except CatchableError:
    result = ""

proc finalizeRealmOpFromDisk() =
  ## Unit finished (or vanished): record last_op from log + state file.
  let st = readRealmOpState()
  if st{"status"}.getStr() != "running":
    return
  let opLabel = st{"op"}.getStr("")
  if opLabel.len == 0:
    return
  let logText = readRealmOpLog()
  let exitCode = parseRealmOpExit(logText)
  let ok = exitCode == 0
  let detail =
    if exitCode >= 0:
      &"operator {serverOpVerb(serverOpFromLabel(opLabel))} exit {exitCode}: {tailForDisplay(logText)}"
    else:
      &"operator finished (no exit marker): {tailForDisplay(logText)}"
  let done = %*{
    "status": "done",
    "op": opLabel,
    "ok": ok,
    "detail": detail,
    "finished_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  }
  writeRealmOpState(done)
  withLock gServerOpLock:
    gRunningServerOp = sloNone
    gLastServerOp = opLabel
    gLastServerOpOk = ok
    gLastServerOpDetail = detail

proc refreshRealmOpState*() =
  ## Reconcile memory + disk with the detached unit (call from status paths).
  ## Survives dashboard restart: if unit still active, show Starting…/Stopping…
  let st = readRealmOpState()
  let status = st{"status"}.getStr("")
  if status == "running":
    if realmOpUnitActive():
      let op = serverOpFromLabel(st{"op"}.getStr(""))
      withLock gServerOpLock:
        if gRunningServerOp == sloNone and gPendingServerOp == sloNone:
          gRunningServerOp = op
      return
    # Unit gone while we were mid-op (or dashboard was down) → finalize.
    finalizeRealmOpFromDisk()
    return
  if status == "done":
    withLock gServerOpLock:
      if gLastServerOp.len == 0:
        gLastServerOp = st{"op"}.getStr("")
        gLastServerOpOk = st{"ok"}.getBool(false)
        gLastServerOpDetail = st{"detail"}.getStr("")

proc stopRealmOpUnit() =
  ## Best-effort clear of a leftover unit before starting a new one.
  discard runCmdCapture("systemctl", ["--user", "stop", RealmOpUnit])
  discard runCmdCapture("systemctl", ["--user", "reset-failed", RealmOpUnit])

proc realmOpWrapperPath*(): string =
  ## Absolute path to tools/realm_op.sh under the army checkout.
  armyRoot() / RealmOpWrapperRel

proc spawnDetachedRealmOperator(op: ServerLifecycleOp): tuple[ok: bool, detail: string] =
  ## Launch realm_op.sh in user unit `wow-realm-op` (independent of wow-system).
  ## Wrapper owns operator discovery + rebuild preflight; The System only queues.
  let verb = serverOpVerb(op)
  let army = armyRoot()
  let wrapper = realmOpWrapperPath()
  if not fileExists(wrapper):
    return (ok: false,
      detail: &"realm op wrapper missing: {wrapper} — set SYSTEM_ARMY_DIR")
  let logPath = realmOpLogPath()
  createDir(parentDir(logPath))
  try:
    writeFile(logPath, &"# realm op {serverOpLabel(op)} started {now().utc}\n")
  except CatchableError as e:
    return (ok: false, detail: &"cannot write op log: {e.msg}")

  stopRealmOpUnit()
  # bash wrapper: keep full log + exit marker for post-mortem after --collect.
  # trap EXIT so a SIGTERM (dashboard stop / manual kill) still leaves a marker
  # instead of a sticky "no exit marker" FAIL on the panel.
  # Pass SYSTEM_* so a detached unit inherits the same pins as wow-system.
  let shell = &"""
set -o pipefail
export SYSTEM_ARMY_DIR={army.quoteShell}
export SYSTEM_UPSTREAM_DIR={upstreamDir().quoteShell}
ec=1
on_exit() {{ echo {RealmOpExitMarker}$ec >> {logPath.quoteShell}; }}
trap on_exit EXIT
{wrapper.quoteShell} {verb.quoteShell} >> {logPath.quoteShell} 2>&1
ec=$?
exit $ec
"""
  let r = runCmdCapture("systemd-run", [
    "--user",
    &"--unit={RealmOpUnit}",
    &"--working-directory={army}",
    "--collect",
    "--",
    "bash", "-c", shell
  ])
  if r.exitCode != 0:
    return (ok: false,
      detail: &"systemd-run failed (exit {r.exitCode}): {tailForDisplay(r.output)}")
  writeRealmOpState(%*{
    "status": "running",
    "op": serverOpLabel(op),
    "unit": RealmOpUnit,
    "log": logPath,
    "started_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  })
  result = (ok: true, detail: &"detached unit {RealmOpUnit}")

proc waitDetachedRealmOperator(): tuple[ok: bool, detail: string] =
  ## Poll the user unit until it exits, then finalize from log.
  while realmOpUnitActive():
    sleep(500)
  # Small grace so the wrapper can flush the exit marker.
  sleep(200)
  finalizeRealmOpFromDisk()
  withLock gServerOpLock:
    result = (ok: gLastServerOpOk, detail: gLastServerOpDetail)

proc runServerOperator(op: ServerLifecycleOp): tuple[ok: bool, detail: string] =
  ## Spawn detached operator unit, wait for it (worker thread only).
  ## The operator process tree lives under user systemd, not wow-system.
  let spawned = spawnDetachedRealmOperator(op)
  if not spawned.ok:
    writeRealmOpState(%*{
      "status": "done",
      "op": serverOpLabel(op),
      "ok": false,
      "detail": spawned.detail,
      "finished_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    })
    return spawned
  result = waitDetachedRealmOperator()

proc currentServerOp(): ServerLifecycleOp =
  ## Queued-or-executing lifecycle op (sloNone when idle).
  withLock gServerOpLock:
    if gRunningServerOp != sloNone:
      return gRunningServerOp
    return gPendingServerOp

proc requestServerOp*(op: ServerLifecycleOp): tuple[accepted: bool, reason: string] =
  ## Queue a lifecycle op for the worker. One op at a time; busy = rejected.
  if op == sloNone:
    return (accepted: false, reason: "no-op")
  {.gcsafe.}:
    refreshRealmOpState()
  withLock gServerOpLock:
    if gRunningServerOp != sloNone or gPendingServerOp != sloNone:
      let busy = serverOpLabel(
        if gRunningServerOp != sloNone: gRunningServerOp else: gPendingServerOp)
      return (accepted: false, reason: &"busy: {busy} in progress")
    if realmOpUnitActive():
      return (accepted: false, reason: "busy: detached realm op still active")
    gPendingServerOp = op
    result = (accepted: true, reason: "")

proc serverStatus*(): ServerStatus =
  ## Single dispatch path for realm lifecycle state (Server panel + MCP).
  {.gcsafe.}:
    refreshRealmOpState()
  let probe = probeGameContainer()
  result.container = gameContainer()
  result.running = probe.running
  result.containerId = probe.id
  withLock gServerOpLock:
    result.op = serverOpLabel(
      if gRunningServerOp != sloNone: gRunningServerOp else: gPendingServerOp)
    result.lastOp = gLastServerOp
    result.lastOpOk = gLastServerOpOk
    result.lastOpDetail = gLastServerOpDetail

proc startServer*(): ServerStatus =
  ## Queue realm start (operator `up`). Returns fresh status either way.
  ## If rejected (busy / leftover unit), surface that on last_op so the panel
  ## does not look like a no-op.
  let req = requestServerOp(sloStart)
  result = serverStatus()
  if not req.accepted:
    result.lastOp = "start"
    result.lastOpOk = false
    result.lastOpDetail = req.reason
    withLock gServerOpLock:
      gLastServerOp = "start"
      gLastServerOpOk = false
      gLastServerOpDetail = req.reason

proc stopServer*(): ServerStatus =
  ## Queue realm stop (operator `down` — compose rm, volumes kept).
  let req = requestServerOp(sloStop)
  result = serverStatus()
  if not req.accepted:
    result.lastOp = "stop"
    result.lastOpOk = false
    result.lastOpDetail = req.reason
    withLock gServerOpLock:
      gLastServerOp = "stop"
      gLastServerOpOk = false
      gLastServerOpDetail = req.reason

proc serverStatusToJson*(s: ServerStatus): JsonNode =
  ## Serialize lifecycle status for the MCP JSON view.
  result = %*{
    "running": s.running,
    "container": s.container,
    "container_id": s.containerId,
    "op": s.op,
    "last_op": s.lastOp,
    "last_op_ok": s.lastOpOk,
    "last_op_detail": s.lastOpDetail
  }

proc serverOpWorkerLoop() {.thread.} =
  ## Runs queued lifecycle ops. Spawns a detached user unit then waits;
  ## the unit outlives this process if the dashboard restarts mid-op.
  while true:
    sleep(200)
    var op = sloNone
    {.gcsafe.}:
      refreshRealmOpState()
      withLock gServerOpLock:
        if gPendingServerOp != sloNone and gRunningServerOp == sloNone:
          op = gPendingServerOp
          gPendingServerOp = sloNone
          gRunningServerOp = op
    if op == sloNone:
      continue
    var opOk = false
    var opDetail = ""
    try:
      {.cast(gcsafe).}:
        let r = runServerOperator(op)
        opOk = r.ok
        opDetail = r.detail
    except Exception as e:
      opOk = false
      opDetail = e.msg
    {.gcsafe.}:
      withLock gServerOpLock:
        gRunningServerOp = sloNone
        gLastServerOp = serverOpLabel(op)
        gLastServerOpOk = opOk
        gLastServerOpDetail = opDetail

proc startServerOpWorker() =
  ## Spawn the realm lifecycle worker (call once from main before serve).
  createThread(gServerOpWorkerThread, serverOpWorkerLoop)

# ---------------------------------------------------------------------------
# Bot seat lifecycle: per-seat Start/Stop (roster buttons + MCP)
# ---------------------------------------------------------------------------

proc seatMakeTarget*(name: string): string =
  ## Makefile start target for a bot seat, or "" (human / unknown).
  for seat in SeatMakeTargets:
    if seat.name == name:
      return seat.startTarget
  result = ""

proc seatStopTarget*(name: string): string =
  ## Makefile stop target for a bot seat, or "" (human / unknown).
  for seat in SeatMakeTargets:
    if seat.name == name:
      return seat.stopTarget
  result = ""

proc seatRuntimeDir*(name: string): string =
  armyRoot() / "local_data" / "home-army" / name

proc seatPidPath*(name: string): string =
  seatRuntimeDir(name) / "launcher.pid"

proc seatStatusPath*(name: string): string =
  seatRuntimeDir(name) / "status" / "status.json"

proc seatPidAlive*(name: string): bool =
  if seatMakeTarget(name).len == 0:
    return false
  var pid = 0
  try:
    if fileExists(seatPidPath(name)):
      pid = parseInt(readFile(seatPidPath(name)).strip().splitLines()[0])
  except CatchableError:
    pid = 0
  result = pid > 0 and dirExists("/proc/" & $pid)

proc seatRuntimeUp*(name: string): bool =
  ## A live home policy needs both its launcher process and a current per-frame
  ## heartbeat. This detects wedged clients that a PID-only check would miss.
  if not seatPidAlive(name):
    return false
  try:
    let statusPath = seatStatusPath(name)
    if not fileExists(statusPath):
      return false
    let age = epochTime() - getLastModificationTime(statusPath).toUnixFloat()
    result = age >= -2.0 and age <= HomeBotStatusMaxAgeSec
  except CatchableError:
    result = false

proc runShell(cmd: string): tuple[ok: bool, detail: string] =
  ## Run one shell line, capture combined output (short admin ops only).
  try:
    let process = startProcess(
      "sh", args = ["-c", cmd], options = {poUsePath, poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    result = (ok: exitCode == 0, detail: tailForDisplay(output, 200))
  except CatchableError as e:
    result = (ok: false, detail: e.msg)

proc runShellDetached(cmd: string): tuple[ok: bool, detail: string] =
  ## Fire-and-forget shell for long-lived children (setsid nohup … &).
  ## Must NOT use poStdErrToStdOut + readAll — that blocks forever when a
  ## background job still holds the pipe (see startBotSeat comment).
  try:
    let process = startProcess(
      "sh",
      args = ["-c", cmd],
      options = {poUsePath})
    # Close pipes so a noisy child cannot fill buffers; wait only for the
    # short-lived launcher shell, not the orphaned setsid session.
    try:
      process.inputStream.close()
    except CatchableError:
      discard
    try:
      process.outputStream.close()
    except CatchableError:
      discard
    try:
      process.errorStream.close()
    except CatchableError:
      discard
    let exitCode = process.waitForExit()
    process.close()
    result = (ok: exitCode == 0, detail: "")
  except CatchableError as e:
    result = (ok: false, detail: e.msg)

proc startBotSeat*(name: string): JsonNode =
  ## Request one embedded Lua seat through the Makefile lifecycle. The target
  ## detaches the launcher and records its PID/log/status under home-army/.
  let target = seatMakeTarget(name)
  if target.len == 0:
    return %*{"ok": false, "name": name, "action": "start",
              "detail": "not a launchable bot seat"}
  if seatRuntimeUp(name):
    return %*{"ok": true, "name": name, "action": "start",
              "detail": "already running (fresh Lua heartbeat)"}
  if seatPidAlive(name):
    return %*{"ok": true, "name": name, "action": "start",
              "detail": "launcher is already starting or its Lua heartbeat is stale; stop it before retrying"}
  let root = armyRoot()
  if not fileExists(root / "Makefile"):
    return %*{"ok": false, "name": name, "action": "start",
              "detail": &"Makefile missing in {root} — set SYSTEM_ARMY_DIR"}
  let r = runShell(&"make -C {quoteShell(root)} {quoteShell(target)}")
  if not r.ok:
    return %*{"ok": false, "name": name, "action": "start", "detail": r.detail}
  result = %*{"ok": true, "name": name, "action": "start",
              "detail": &"requested {target}; ready when the Lua heartbeat is fresh"}

proc stopBotSeat*(name: string): JsonNode =
  ## Stop one embedded Lua seat through the same Makefile lifecycle.
  let target = seatStopTarget(name)
  if target.len == 0:
    return %*{"ok": false, "name": name, "action": "stop",
              "detail": "not a launchable bot seat"}
  if not seatPidAlive(name):
    return %*{"ok": true, "name": name, "action": "stop",
              "detail": "already stopped"}
  let root = armyRoot()
  if not fileExists(root / "Makefile"):
    return %*{"ok": false, "name": name, "action": "stop",
              "detail": &"Makefile missing in {root} — set SYSTEM_ARMY_DIR"}
  let r = runShell(&"make -C {quoteShell(root)} {quoteShell(target)}")
  if not r.ok:
    return %*{"ok": false, "name": name, "action": "stop", "detail": r.detail}
  result = %*{"ok": true, "name": name, "action": "stop",
              "detail": &"requested {target}"}

# ---------------------------------------------------------------------------
# Traverse detached ops: Lua proof-of-life + local watch_bots observer
# ---------------------------------------------------------------------------

proc traversePolLogPath*(): string =
  armyRoot() / TraversePolLogRel

proc traversePolPidPath*(): string =
  armyRoot() / TraversePolPidRel

proc traverseWatchLogPath*(): string =
  armyRoot() / TraverseWatchLogRel

proc traverseWatchPidPath*(): string =
  armyRoot() / TraverseWatchPidRel

proc traverseEpisodesHistoryPath*(): string =
  armyRoot() / TraverseEpisodesHistoryRel

proc traverseFieldPullLogPath*(): string =
  armyRoot() / TraverseFieldPullLogRel

proc traverseFieldPullPidPath*(): string =
  armyRoot() / TraverseFieldPullPidRel

proc readPidFile*(path: string): int =
  ## Best-effort PID from a file; 0 when missing/invalid.
  try:
    if not fileExists(path):
      return 0
    result = parseInt(readFile(path).strip().splitLines()[0])
    if result <= 0:
      result = 0
  except CatchableError:
    result = 0

proc pidAlive*(pid: int): bool =
  ## True when /proc/<pid> exists (Linux).
  if pid <= 0:
    return false
  result = dirExists("/proc/" & $pid)

proc pidCmdline*(pid: int): string =
  ## /proc/<pid>/cmdline with NULs as spaces (empty if unreadable).
  if pid <= 0:
    return ""
  try:
    result = readFile("/proc/" & $pid & "/cmdline").replace('\0', ' ').strip()
  except CatchableError:
    result = ""

proc clearPidFile(path: string) =
  try:
    if fileExists(path):
      removeFile(path)
  except CatchableError:
    discard

proc isTraversePolProcess*(pid: int): bool =
  ## True when pid belongs to a local traverse bot session (launcher or worker).
  ## Keep markers tight: agent shells that merely *mention* make targets in a
  ## long `bash -c` script must not match (that blocked Start as "running").
  let cmd = pidCmdline(pid)
  if cmd.len == 0:
    return false
  # Coding-agent / interactive wrappers embed our commands in huge -c scripts.
  if "snap=$(command cat" in cmd or "builtin eval" in cmd or cmd.len > 400:
    return false
  if ("army_host" in cmd) and ("mode=traverse" in cmd or "--mode=traverse" in cmd):
    return true
  if "tools/traverse_pol.sh" in cmd or "tools/run_local_traverse.sh" in cmd:
    return true
  # `make … traverse-pol` / `make traverse-desert` as the actual process.
  if (cmd.startsWith("make ") or " make " in cmd) and
      ("traverse-pol" in cmd or "traverse-desert" in cmd):
    return true
  if "native_support" in cmd and "prepare" in cmd and "league=traverse" in cmd:
    return true
  if "vanilla-wow-env-host" in cmd and "local_data/bin/vanilla-wow-env-host" in cmd:
    return true
  result = false

proc isTraverseWatchProcess*(pid: int): bool =
  ## True when pid is the watch launcher tree or the native viewer it started.
  let cmd = pidCmdline(pid)
  if cmd.len == 0:
    return false
  # Live admin viewer (path under watch-bots/) with a live-pov URL.
  if "global-viewer" in cmd and "live-pov=" in cmd:
    return true
  if "watch-bots/live-pov" in cmd or ("live-pov" in cmd and "--capture-dir=" in cmd):
    return true
  # uv/python watch_bots.py (or nix develop wrapper that still has the path).
  if "watch_bots.py" notin cmd:
    return false
  result =
    ("uv" in cmd) or ("python" in cmd) or ("nix develop" in cmd) or
    ("nix" in cmd)

proc findProcessByMarker*(marker: string): int =
  ## Scan /proc for a cmdline containing marker; return first pid or 0.
  try:
    for kind, path in walkDir("/proc", relative = false):
      if kind != pcDir:
        continue
      let base = path.extractFilename
      var pid = 0
      try:
        pid = parseInt(base)
      except CatchableError:
        continue
      if pid <= 1:
        continue
      let cmd = pidCmdline(pid)
      if marker in cmd:
        return pid
  except CatchableError:
    discard
  result = 0

proc traverseOpsStatus*(): TraverseOpsStatus =
  ## Whether PoL / observer detaches are live (pid files + process probe).
  result = TraverseOpsStatus(
    polLog: TraversePolLogRel,
    watchLog: TraverseWatchLogRel
  )
  let polPid = readPidFile(traversePolPidPath())
  if isTraversePolProcess(polPid):
    result.polRunning = true
    result.polPid = polPid
  else:
    let found = findProcessByMarker("army_host --mode=traverse")
    if found > 0:
      result.polRunning = true
      result.polPid = found
    elif polPid > 0:
      clearPidFile(traversePolPidPath())
  let watchPid = readPidFile(traverseWatchPidPath())
  if isTraverseWatchProcess(watchPid):
    result.watchRunning = true
    result.watchPid = watchPid
  else:
    var found = findProcessByMarker("watch_bots.py")
    if found == 0:
      found = findProcessByMarker("global-viewer")
    if found == 0:
      found = findProcessByMarker("watch-bots/live-pov")
    if found > 0 and isTraverseWatchProcess(found):
      result.watchRunning = true
      result.watchPid = found
    elif watchPid > 0:
      clearPidFile(traverseWatchPidPath())

proc dockerPublishedHostPort*(container, containerPort: string): int =
  ## Parse `docker port <container> <port>/tcp` → host port (0 on failure).
  if container.len == 0 or containerPort.len == 0:
    return 0
  try:
    let process = startProcess(
      "docker",
      args = ["port", container, containerPort & "/tcp"],
      options = {poUsePath, poStdErrToStdOut})
    let output = process.outputStream.readAll().strip()
    let code = process.waitForExit()
    process.close()
    if code != 0 or output.len == 0:
      return 0
    let line = output.splitLines()[0].strip()
    let colon = line.rfind(':')
    if colon < 0 or colon + 1 >= line.len:
      return 0
    result = parseInt(line[colon + 1 .. ^1])
  except CatchableError:
    result = 0

proc logFileTail*(path: string; maxLines = 8): string =
  ## Last N lines of a log file (empty if missing).
  try:
    if not fileExists(path):
      return ""
    let lines = readFile(path).strip().splitLines()
    let n = min(maxLines, lines.len)
    if n <= 0:
      return ""
    result = lines[lines.len - n .. ^1].join(" | ")
  except CatchableError:
    result = ""

proc nixDevelopCmd*(root, inner: string): string =
  ## Run `inner` inside this repo's flake (`nix develop --command …`).
  ## Prefer this over nix-shell -p hand-rolls.
  &"cd {quoteShell(root)} && nix develop --command bash -lc {quoteShell(inner)}"

proc termPidTree*(pid: int): bool =
  ## TERM the process group (setsid leaders) and the pid. True if signal sent.
  if pid <= 0 or not pidAlive(pid):
    return false
  discard runShell(
    &"kill -TERM -{pid} 2>/dev/null || kill -TERM {pid} 2>/dev/null || true")
  result = true

proc killPidTree*(pid: int): bool =
  ## KILL the process group and pid (after a prior TERM). True if signal sent.
  if pid <= 0 or not pidAlive(pid):
    return false
  discard runShell(
    &"kill -KILL -{pid} 2>/dev/null || kill -KILL {pid} 2>/dev/null || true")
  result = true

proc cleanupTraverseBackend*(): bool =
  ## Tear down local --league=traverse unit (*-traverse-coworld-game-1 + lease).
  ## Used when a run finishes or the operator hits Stop — not on Start restart
  ## (prepare reuses a healthy unit and full teardown made Start feel broken).
  let upstream = upstreamDir()
  if not dirExists(upstream):
    return false
  let inner =
    &"cd {quoteShell(upstream)} && " &
    "uv run python -m player.launch.native_support cleanup --league=traverse"
  let r = runShell(
    &"bash -lc {quoteShell(inner)} >/dev/null 2>&1 || true")
  result = r.ok

proc stopTraversePol*(cleanupBackend = false): TraverseOpsStatus =
  ## Kill every local traverse-bot process (launcher, prepare, env-host, army_host).
  ## Fast: one TERM sweep, short wait, one KILL sweep — no per-pid sleeps.
  ## cleanupBackend=true (dashboard Stop) also drops the traverse container;
  ## leave false for Start's force-restart so prepare can reuse a live unit.
  var bits: seq[string] = @[]
  var targets: seq[int] = @[]
  let pid = readPidFile(traversePolPidPath())
  if pid > 0:
    targets.add(pid)
  try:
    let envPidPath = armyRoot() / "local_data" / "env-host-traverse.pid"
    let envPid = readPidFile(envPidPath)
    if envPid > 0:
      targets.add(envPid)
    clearPidFile(envPidPath)
  except CatchableError:
    discard
  for kind, path in walkDir("/proc", relative = false):
    if kind != pcDir:
      continue
    var p = 0
    try:
      p = parseInt(path.extractFilename)
    except CatchableError:
      continue
    if p <= 1:
      continue
    if isTraversePolProcess(p) and p notin targets:
      targets.add(p)
  for p in targets:
    discard termPidTree(p)
  if targets.len > 0:
    sleep(100)
    for p in targets:
      if pidAlive(p):
        discard killPidTree(p)
    bits.add("kill " & targets.join(","))
  if cleanupBackend:
    if cleanupTraverseBackend():
      bits.add("cleanup traverse backend")
    else:
      bits.add("cleanup traverse backend (attempted)")
  clearPidFile(traversePolPidPath())
  result = traverseOpsStatus()
  result.lastOk = true
  result.lastDetail = if bits.len > 0: bits.join("; ") else: "nothing to stop"

proc stopTraverseWatch*(): TraverseOpsStatus =
  ## TERM the watch_bots observer process tree (and leftover live-pov/viewer).
  var bits: seq[string] = @[]
  let root = armyRoot()
  let upstream = upstreamDir()
  let owner = getEnv("USER", "monofuel")
  # Official stop path releases unit record + leases when possible.
  if fileExists(upstream / "observe" / "watch_bots.py"):
    let stopInner =
      &"cd {quoteShell(upstream)} && " &
      &"uv run python observe/watch_bots.py --stop || true; " &
      &"uv run python agents/agent_lease.py release seat --owner {quoteShell(owner)} || true; " &
      &"uv run python agents/agent_lease.py release backend --owner {quoteShell(owner)} || true"
    discard runShell(
      &"bash -lc {quoteShell(nixDevelopCmd(root, stopInner))} >/dev/null 2>&1 || true")
    bits.add("watch_bots --stop + lease release")
  let pid = readPidFile(traverseWatchPidPath())
  if pid > 0 and pidAlive(pid):
    discard runShell(&"kill -TERM -{pid} 2>/dev/null || kill {pid} 2>/dev/null || true")
    bits.add(&"kill pid {pid}")
  for kind, path in walkDir("/proc", relative = false):
    if kind != pcDir:
      continue
    var p = 0
    try:
      p = parseInt(path.extractFilename)
    except CatchableError:
      continue
    let cmd = pidCmdline(p)
    if isTraverseWatchProcess(p) or
        ("live-pov" in cmd and "watch-bots" in cmd) or
        ("global-viewer" in cmd and "live-pov=" in cmd):
      discard runShell(&"kill {p} 2>/dev/null || true")
      bits.add(&"kill {p}")
  clearPidFile(traverseWatchPidPath())
  result = traverseOpsStatus()
  result.lastOk = true
  result.lastDetail = if bits.len > 0: bits.join("; ") else: "nothing to stop"

# ---------------------------------------------------------------------------
# Hosted traverse replays (ctf-bots field history pattern)
# ---------------------------------------------------------------------------

proc isTraverseOurPolicy*(name: string): bool =
  ## True when the policy name is one we ship (ibis today).
  let n = name.strip().toLowerAscii()
  for owned in TraverseOurPolicyNames:
    if n == owned:
      return true
  result = false

proc formatTraverseWhen*(iso: string): string =
  ## Compact UTC stamp for table cells (YYYY-MM-DD HH:MM).
  if iso.len < 16:
    return iso
  result = iso[0..9] & " " & iso[11..15]

proc episodeObservatoryUrl*(id: string): string =
  ## Softmax Observatory episode-request (or episode) detail URL.
  if id.len == 0:
    return ""
  let detail =
    if id.startsWith("ereq_"):
      "episode-request:" & id
    else:
      "episode:" & id
  result = ObservatoryV2Base & "?tab=episodes&detail=" & detail

proc episodeObservatoryReplayUrl*(
    coworldId, replayUrl, game, gameVersion, episodeId: string
): string =
  ## Observatory in-browser coworld replay viewer for a hosted .replay URI.
  if coworldId.len == 0 or replayUrl.len == 0:
    return ""
  var q = "replay_uri=" & encodeUrl(replayUrl)
  if game.len > 0:
    q.add("&game=" & encodeUrl(game))
  if gameVersion.len > 0:
    q.add("&game_version=" & encodeUrl(gameVersion))
  if episodeId.len > 0:
    q.add("&episode_id=" & encodeUrl(episodeId))
  result = ObservatoryCoworldReplaysBase & "/" & coworldId & "?" & q

proc parseTraverseReplayRow*(node: JsonNode): Option[TraverseReplayRow] =
  ## Map one Softmax episode-request JSON object to a table row.
  if node.isNil or node.kind != JObject:
    return none(TraverseReplayRow)
  var row: TraverseReplayRow
  row.id = node{"id"}.getStr("")
  if row.id.len == 0:
    row.id = node{"episode_id"}.getStr("")
  row.episodeId = node{"episode_id"}.getStr("")
  row.status = node{"status"}.getStr("").toLowerAscii()
  row.replayUrl = node{"replay_url"}.getStr("")
  row.liveUrl = node{"live_url"}.getStr("")
  let coworldId = node{"coworld_id"}.getStr("")
  let game = node{"coworld_name"}.getStr("")
  let gameVersion = node{"coworld_version"}.getStr("")
  let whenRaw =
    node{"completed_at"}.getStr("")
  let whenFallback =
    if whenRaw.len > 0: whenRaw
    else:
      let r = node{"running_at"}.getStr("")
      if r.len > 0: r else: node{"created_at"}.getStr("")
  row.whenText = formatTraverseWhen(whenFallback)
  var our: JsonNode = nil
  let participants = node{"participants"}
  if not participants.isNil and participants.kind == JArray:
    for p in participants:
      if p.kind != JObject:
        continue
      if p{"is_filler"}.getBool(false):
        continue
      let pname = p{"policy_name"}.getStr("")
      if isTraverseOurPolicy(pname):
        our = p
        break
    if our.isNil:
      for p in participants:
        if p.kind != JObject:
          continue
        if p{"is_filler"}.getBool(false):
          continue
        our = p
        break
  if not our.isNil:
    row.policyName = our{"policy_name"}.getStr("")
    row.version = our{"version"}.getInt(0)
    row.policyVersionId = our{"policy_version_id"}.getStr("")
    row.versionLabel = our{"label"}.getStr("")
    if row.versionLabel.len == 0 and row.policyName.len > 0:
      row.versionLabel = &"{row.policyName}:v{row.version}"
  if row.versionLabel.len == 0:
    row.versionLabel = "—"
  let scores = node{"scores"}
  if not scores.isNil and scores.kind == JArray:
    for s in scores:
      if s.kind != JObject:
        continue
      let pvid = s{"policy_version_id"}.getStr("")
      if row.policyVersionId.len > 0 and pvid.len > 0 and pvid != row.policyVersionId:
        continue
      if s.hasKey("score") and s["score"].kind in {JFloat, JInt}:
        row.score = s["score"].getFloat()
        row.hasScore = true
        break
  if not row.hasScore:
    let ps = node{"participant_scores"}
    if not ps.isNil and ps.kind == JArray and ps.len > 0:
      let s0 = ps[0]
      if s0.kind == JObject and s0.hasKey("score") and
          s0["score"].kind in {JFloat, JInt}:
        row.score = s0["score"].getFloat()
        row.hasScore = true
  let replayViewer = episodeObservatoryReplayUrl(
    coworldId, row.replayUrl, game, gameVersion, row.episodeId)
  if replayViewer.len > 0:
    row.observatoryUrl = replayViewer
  else:
    row.observatoryUrl = episodeObservatoryUrl(row.id)
  if row.id.len == 0 and row.versionLabel == "—":
    return none(TraverseReplayRow)
  result = some(row)

proc parseTraverseEpisodesJson*(text: string): seq[TraverseReplayRow] =
  ## Parse a JSON array of episode requests into table rows (newest first).
  result = @[]
  let node = parseJson(text)
  if node.kind != JArray:
    return
  for item in node:
    let rowOpt = parseTraverseReplayRow(item)
    if rowOpt.isSome:
      result.add(rowOpt.get)
  result.sort(proc(a, b: TraverseReplayRow): int =
    cmp(b.whenText, a.whenText))

proc isTraverseFieldPullProcess*(pid: int): bool =
  ## True when pid is tools/pull_traverse_field.sh or its make target.
  if not pidAlive(pid):
    return false
  let cmd = pidCmdline(pid)
  result =
    ("pull_traverse_field" in cmd) or
    ("make" in cmd and "traverse-field" in cmd)

proc traverseFieldPullRunning*(): bool =
  ## Detached field-pull process still alive.
  let pid = readPidFile(traverseFieldPullPidPath())
  if pid > 0 and isTraverseFieldPullProcess(pid):
    return true
  result = false

proc traverseReplays*(): TraverseReplaysStatus =
  ## Load durable hosted episodes for the Traverse replays table.
  result = TraverseReplaysStatus(
    path: TraverseEpisodesHistoryRel,
    pullRunning: traverseFieldPullRunning()
  )
  let path = traverseEpisodesHistoryPath()
  if not fileExists(path):
    result.available = false
    result.note =
      "No hosted episodes yet — click Refresh (or run make traverse-field)."
    return
  try:
    result.rows = parseTraverseEpisodesJson(readFile(path))
    result.available = result.rows.len > 0
    if result.rows.len == 0:
      result.note = "episodes_history.json is empty"
    else:
      result.note = &"{result.rows.len} episodes"
      result.lastOk = true
  except CatchableError as e:
    result.available = false
    result.note = &"failed to read episodes: {e.msg}"
    result.lastOk = false
    result.lastDetail = e.msg

proc startTraverseFieldPull*(): TraverseReplaysStatus =
  ## Detached `make traverse-field` to refresh hosted episode cache.
  result = traverseReplays()
  if result.pullRunning:
    result.lastOk = true
    result.lastDetail = "pull already running"
    result.pullRunning = true
    return
  let root = armyRoot()
  if not fileExists(root / "Makefile"):
    result.lastOk = false
    result.lastDetail = &"Makefile missing in {root}"
    return
  let logPath = traverseFieldPullLogPath()
  let pidPath = traverseFieldPullPidPath()
  createDir(parentDir(logPath))
  try:
    writeFile(logPath, "")
  except CatchableError:
    discard
  let cmd =
    &"cd {quoteShell(root)} && " &
    &"( setsid nohup make traverse-field >> {quoteShell(logPath)} 2>&1 < /dev/null & " &
    &"echo $! > {quoteShell(pidPath)} )"
  let r = runShell(&"bash -lc {quoteShell(cmd)}")
  if not r.ok:
    result.lastOk = false
    result.lastDetail = r.detail
    return
  result = traverseReplays()
  result.lastOk = true
  result.lastDetail = "field pull started"
  result.pullRunning = true

proc latestGodviewHasCharacter*(
    capturesDir, character: string; maxAgeSec: float): bool =
  ## True when the newest godview shard was written recently and names the character.
  if capturesDir.len == 0 or not dirExists(capturesDir):
    return false
  var bestPath = ""
  var bestMtime = 0.0
  try:
    for kind, path in walkDir(capturesDir):
      if kind != pcFile:
        continue
      let base = path.extractFilename
      if not base.startsWith("godview_") or not base.endsWith(".jsonl"):
        continue
      let mt = getLastModificationTime(path).toUnixFloat()
      if mt >= bestMtime:
        bestMtime = mt
        bestPath = path
  except CatchableError:
    return false
  if bestPath.len == 0:
    return false
  let age = epochTime() - bestMtime
  if age > maxAgeSec:
    return false
  let want = character.toLowerAscii()
  try:
    let raw = readFile(bestPath)
    let lines = raw.strip().splitLines()
    # Scan last frames first; empty final frame (disconnect) must not win alone.
    var i = lines.len - 1
    while i >= 0 and i >= lines.len - 40:
      let line = lines[i].strip()
      dec i
      if line.len == 0:
        continue
      try:
        let node = parseJson(line)
        if node.kind != JObject or not node.hasKey("players"):
          continue
        let players = node["players"]
        if players.kind != JArray:
          continue
        for p in players:
          if p.kind != JObject or not p.hasKey("name"):
            continue
          if p["name"].getStr().toLowerAscii() == want:
            return true
      except CatchableError:
        continue
  except CatchableError:
    return false
  result = false

proc startTraverseAgentSession*(
    minYards: float;
    maxSeconds: int;
    detailPrefix: string;
    goalRadius = 0.0;
    goalX = 0.0;
    goalY = 0.0;
    forceRestart = true
): TraverseOpsStatus =
  ## Detached local traverse bot (`make traverse-pol` / desert). No nested nix
  ## develop (The System already runs inside the flake). forceRestart clears
  ## leftovers from a prior manual or dashboard run so start stays reliable.
  ##
  ## Launch uses the same orphaning pattern as startBotSeat: the HTTP worker
  ## must not hold a pipe open to the child (that blocked the dashboard for
  ## the whole run).
  result = traverseOpsStatus()
  if result.polRunning:
    if not forceRestart:
      result.lastOk = true
      result.lastDetail = "already running"
      return
    discard stopTraversePol()
    result = traverseOpsStatus()
    if result.polRunning:
      # Race / stubborn orphan — KILL and proceed with launch anyway.
      discard killPidTree(result.polPid)
      clearPidFile(traversePolPidPath())
  let root = armyRoot()
  if not fileExists(root / "Makefile"):
    result.lastOk = false
    result.lastDetail = &"Makefile missing in {root}"
    return
  let logPath = traversePolLogPath()
  let pidPath = traversePolPidPath()
  createDir(parentDir(logPath))
  try:
    writeFile(logPath, "")
  except CatchableError:
    discard
  let launcher = root / "tools" / "run_local_traverse.sh"
  if not fileExists(launcher):
    result.lastOk = false
    result.lastDetail = &"missing {launcher}"
    return
  # Defaults live in run_local_traverse.sh (desert checkpoint). Optional overrides
  # via env for special sessions (observer long-run, short PoL, etc.).
  var envAssign: seq[string] = @[]
  envAssign.add(&"TRAVERSE_POL_LOG={quoteShell(logPath)}")
  envAssign.add(&"TRAVERSE_POL_MIN_YARDS={minYards.formatFloat(ffDecimal, 1)}")
  envAssign.add(&"TRAVERSE_POL_MAX_SECONDS={maxSeconds}")
  if goalRadius > 0:
    envAssign.add(&"TRAVERSE_POL_GOAL_RADIUS={goalRadius.formatFloat(ffDecimal, 1)}")
    envAssign.add(&"TRAVERSE_POL_GOAL_X={goalX.formatFloat(ffDecimal, 1)}")
    envAssign.add(&"TRAVERSE_POL_GOAL_Y={goalY.formatFloat(ffDecimal, 1)}")
  let envPrefix = envAssign.join(" ")
  # Same orphaning as startBotSeat — HTTP worker must not wait on the child.
  let cmd =
    &"mkdir -p {quoteShell(parentDir(logPath))} && " &
    &"( {envPrefix} setsid nohup {quoteShell(launcher)} " &
    &">> {quoteShell(logPath)} 2>&1 < /dev/null & " &
    &"echo $! > {quoteShell(pidPath)} )"
  let r = runShellDetached(cmd)
  # Let the setsid child appear in /proc before we sample status.
  sleep(80)
  result = traverseOpsStatus()
  result.lastOk = r.ok
  if r.ok:
    result.lastDetail =
      if result.polRunning: detailPrefix
      else: detailPrefix & " (starting…)"
  else:
    result.lastDetail = r.detail

proc startTraversePol*(): TraverseOpsStatus =
  ## Detached local desert-checkpoint traverse run (Lua bot + army_host).
  ## Stops at the Gadgetzan-area checkpoint (~50 yd), not a 50-yard PoL smoke.
  const
    # Keep in sync with lua/entry/traverse.lua CHECKPOINT_* and traverse_pol.sh.
    # V4 leg 1: north-desert water entry (docs/traverse/traverse-2026-08-05.md).
    DesertGoalX = -6784.5
    DesertGoalY = -4833.9
    DesertGoalRadius = 50.0
    DesertMaxSeconds = 1200
  startTraverseAgentSession(
    minYards = 0.0,
    maxSeconds = DesertMaxSeconds,
    detailPrefix = "local traverse started",
    goalRadius = DesertGoalRadius,
    goalX = DesertGoalX,
    goalY = DesertGoalY,
    forceRestart = true
  )

proc ensureTraverseAgentForWatch*(capturesDir: string): TraverseOpsStatus =
  ## Observer follow needs live godview for Northbound. Short PoL exits too soon;
  ## start a full-episode army_host when nothing is producing captures.
  result = traverseOpsStatus()
  if latestGodviewHasCharacter(
      capturesDir, TraverseCharacterName, TraverseWatchCaptureMaxAgeSec):
    result.lastOk = true
    result.lastDetail = "live capture"
    return
  if not result.polRunning:
    result = startTraverseAgentSession(
      minYards = 0.0,
      maxSeconds = TraverseWatchAgentMaxSeconds,
      detailPrefix = "agent started"
    )
    if not result.lastOk:
      return
  # Wait for Northbound to appear in a fresh godview shard.
  let deadline = epochTime() + (TraverseWatchCaptureWaitMs.float / 1000.0)
  while epochTime() < deadline:
    if latestGodviewHasCharacter(
        capturesDir, TraverseCharacterName, TraverseWatchCaptureMaxAgeSec):
      result = traverseOpsStatus()
      result.lastOk = true
      result.lastDetail = "live capture"
      return
    if not traverseOpsStatus().polRunning and
        epochTime() + 2.0 < deadline:
      # Agent died early; one restart attempt.
      let again = startTraverseAgentSession(
        minYards = 0.0,
        maxSeconds = TraverseWatchAgentMaxSeconds,
        detailPrefix = "agent restarted"
      )
      if not again.lastOk:
        result = again
        return
    sleep(1000)
  result = traverseOpsStatus()
  result.lastOk = false
  result.lastDetail =
    &"no live {TraverseCharacterName} capture under {capturesDir}"

proc graphicalSessionEnvExports*(): string =
  ## DISPLAY / XAUTHORITY / WAYLAND for systemd-launched GUI children.
  let display = getEnv("DISPLAY", ":0")
  let xauth = getEnv("XAUTHORITY", "")
  let wayland = getEnv("WAYLAND_DISPLAY", "")
  result = &"export DISPLAY={quoteShell(display)}; "
  if xauth.len > 0:
    result.add &"export XAUTHORITY={quoteShell(xauth)}; "
  if wayland.len > 0:
    result.add &"export WAYLAND_DISPLAY={quoteShell(wayland)}; "

proc startTraverseWatch*(): TraverseOpsStatus =
  ## Detached watch_bots live POV under `nix develop` (openssl/nginx/uv in flake).
  ## Ensures a long-running traverse agent so live-pov can follow Northbound.
  result = traverseOpsStatus()
  let root = armyRoot()
  let upstream = upstreamDir()
  let watchPy = upstream / "observe" / "watch_bots.py"
  if not fileExists(watchPy):
    result.lastOk = false
    result.lastDetail = &"watch_bots.py missing under {upstream}"
    return
  let container = resolveTraverseContainer()
  if container.len == 0:
    result.lastOk = false
    result.lastDetail = "no traverse container"
    return
  let captures = resolveTraverseCapturesDir(container)
  if captures.len == 0 or not dirExists(captures):
    result.lastOk = false
    result.lastDetail = "no traverse captures"
    return
  let realmPort = dockerPublishedHostPort(container, "3724")
  let worldPort = dockerPublishedHostPort(container, "8085")
  if realmPort <= 0 or worldPort <= 0:
    result.lastOk = false
    result.lastDetail = "realm/world ports unmapped"
    return
  let existingViewer = findProcessByMarker("global-viewer")
  let liveCapture = latestGodviewHasCharacter(
    captures, TraverseCharacterName, TraverseWatchCaptureMaxAgeSec)
  if result.watchRunning and existingViewer > 0 and
      isTraverseWatchProcess(existingViewer) and liveCapture:
    result.lastOk = true
    result.lastDetail = "already running"
    return
  # Clear prior watch unit + stale seat lease. watch_bots will NOT open a
  # window if seat.json is still held (even by the same monofuel owner).
  discard stopTraverseWatch()
  let agent = ensureTraverseAgentForWatch(captures)
  if not agent.lastOk:
    result = agent
    result.watchRunning = false
    return
  let logPath = traverseWatchLogPath()
  let pidPath = traverseWatchPidPath()
  createDir(parentDir(logPath))
  try:
    writeFile(logPath, "")
  except CatchableError:
    discard
  let owner = getEnv("USER", "monofuel")
  # Inside flake shell: uv + openssl + nginx. Pre-release seat so the native
  # viewer can claim the GUI seat and actually open a window.
  let watchInner =
    graphicalSessionEnvExports() &
    &"export VMANGOS_CAPTURES_DIR={quoteShell(captures)}; " &
    &"cd {quoteShell(upstream)}; " &
    &"uv run python agents/agent_lease.py release seat --owner {quoteShell(owner)} || true; " &
    &"uv run python agents/agent_lease.py release backend --owner {quoteShell(owner)} || true; " &
    &"exec uv run python observe/watch_bots.py " &
    &"--watch {TraverseCharacterName} " &
    &"--owner {quoteShell(owner)} " &
    &"--no-bring-up --no-provision " &
    &"--realm-host 127.0.0.1 --realm-port {realmPort} --world-port {worldPort}"
  let cmd =
    &"mkdir -p {quoteShell(parentDir(logPath))} && (" &
    &"setsid nohup bash -lc {quoteShell(nixDevelopCmd(root, watchInner))} " &
    &">> {quoteShell(logPath)} 2>&1 < /dev/null & " &
    &"echo $! > {quoteShell(pidPath)} )"
  let r = runShell(cmd)
  sleep(8000)
  result = traverseOpsStatus()
  if not r.ok:
    result.lastOk = false
    result.lastDetail = r.detail
    return
  let tail = logFileTail(logPath, 14)
  # watch_bots prints the viewer command even when the seat blocks the window.
  if "window is blocked" in tail:
    result.watchRunning = false
    result.lastOk = false
    result.lastDetail = "GUI seat blocked — click Stop observer then Start again"
    return
  let pid = readPidFile(pidPath)
  let pyPid = findProcessByMarker("watch_bots.py")
  let viewerPid = findProcessByMarker("global-viewer")
  let livePid = findProcessByMarker("watch-bots/live-pov")
  let stillLive = latestGodviewHasCharacter(
    captures, TraverseCharacterName, TraverseWatchCaptureMaxAgeSec)
  # Success requires the native viewer process, not only live-pov / broker.
  if viewerPid > 0 and isTraverseWatchProcess(viewerPid):
    result.watchRunning = true
    result.watchPid = viewerPid
    result.lastOk = stillLive
    result.lastDetail =
      if stillLive: &"started following {TraverseCharacterName}"
      else: &"viewer up but no live {TraverseCharacterName} capture"
    return
  if pidAlive(pid) or pyPid > 0 or livePid > 0:
    # Still starting, or failed to open window — treat missing viewer as fail
    # once the log has finished the "starting native live admin viewer" step.
    if "starting native live admin viewer" in tail and viewerPid == 0:
      result.watchRunning = false
      result.lastOk = false
      result.lastDetail =
        if tail.len > 0: tail
        else: "viewer did not open"
      return
    result.watchRunning = true
    result.watchPid =
      if pyPid > 0: pyPid
      elif livePid > 0: livePid
      elif pidAlive(pid): pid
      else: 0
    result.lastOk = true
    result.lastDetail = &"starting (log {TraverseWatchLogRel})"
    return
  result.lastOk = false
  result.lastDetail =
    if tail.len > 0: tail
    else: "exited early"

# ---------------------------------------------------------------------------
# SOAP GM command client (inbound: System → addon via announce)
# ---------------------------------------------------------------------------

proc resolveGameBridgeIp(): string =
  ## Docker bridge IP of the game container (first network address).
  let container = gameContainer()
  let process = startProcess(
    "docker",
    args = [
      "inspect", "-f",
      "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
      container
    ],
    options = {poUsePath}
  )
  let output = process.outputStream.readAll().strip()
  let err = process.errorStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0 or output.len == 0:
    raise newException(IOError,
      &"docker inspect IP failed for {container} (exit {exitCode}): {err}\n{output}")
  result = output

proc soapUrl*(): string =
  ## SOAP base URL. SYSTEM_SOAP_URL wins; else http://<game-bridge-ip>:7878/.
  let env = getEnv("SYSTEM_SOAP_URL", "")
  if env.len > 0:
    return env
  let ip = resolveGameBridgeIp()
  result = &"http://{ip}:7878/"

proc buildSoapBody*(cmd: string): string =
  ## Build a urn:MaNGOS executeCommand envelope with XML-escaped command text.
  let escaped = escapeXml(cmd)
  result = &"""<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:MaNGOS">
  <SOAP-ENV:Body>
    <ns1:executeCommand>
      <command>{escaped}</command>
    </ns1:executeCommand>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>"""

proc extractSoapResult*(body: string): Option[string] =
  ## Extract `<result>...</result>` text from a SOAP response body if present.
  const startTag = "<result>"
  const endTag = "</result>"
  let i = body.find(startTag)
  if i < 0:
    return none(string)
  let contentStart = i + startTag.len
  let j = body.find(endTag, contentStart)
  if j < 0:
    return none(string)
  result = some(body[contentStart ..< j])

proc gmCommand*(cmd: string): string =
  ## POST a GM console command via VMaNGOS SOAP (no leading dot on the command).
  let user = getEnv("SYSTEM_SOAP_USER", "system")
  let pass = getEnv("SYSTEM_SOAP_PASS", "shadowsoap")
  let auth = encode(user & ":" & pass)
  let client = newHttpClient(timeout = SoapTimeoutMs)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/xml",
    "Authorization": "Basic " & auth
  })
  let response = client.request(
    soapUrl(),
    httpMethod = HttpPost,
    body = buildSoapBody(cmd)
  )
  if response.code != Http200:
    raise newException(IOError,
      &"SOAP HTTP {response.code}: {response.body}")
  let extracted = extractSoapResult(response.body)
  if extracted.isSome:
    # gsoap encodes CR as &#xD; inside the result text.
    return extracted.get.multiReplace(
      ("&#xD;", ""), ("&#xA;", "\n"), ("&amp;", "&"),
      ("&lt;", "<"), ("&gt;", ">"), ("\r", "")
    ).strip()
  result = response.body

proc announceInGame*(text: string): string =
  ## Broadcast a system message to all players (`announce <text>`).
  result = gmCommand("announce " & text)

proc isBotSeatName*(name: string): bool =
  ## True when `name` is exactly one of the fixed bot seats.
  for n in BotSeats:
    if n == name:
      return true
  result = false

proc respawnCommandsFor*(name: string, teleDest: string = ShadowArmyRespawnTele): seq[string] =
  ## Ordered SOAP commands to revive and place one bot seat.
  ## Names are fixed bot seats only; callers must not pass free text.
  if not isBotSeatName(name):
    raise newException(ValueError, &"not a bot seat name: {name}")
  # teleDest is a fixed constant in production; reject path-ish junk in tests.
  if teleDest.len == 0 or ' ' in teleDest or '/' in teleDest or ';' in teleDest:
    raise newException(ValueError, &"invalid tele destination: {teleDest}")
  result = @[
    &"revive {name}",
    &"tele name {name} {teleDest}",
    &"repairitems {name}",
  ]

proc teleToMuristCommandsFor*(name: string, teleDest: string = MuristMeetTeleName): seq[string] =
  ## SOAP command to pull one bot seat to the Murist-meet game_tele pin.
  if not isBotSeatName(name):
    raise newException(ValueError, &"not a bot seat name: {name}")
  if teleDest != MuristMeetTeleName:
    raise newException(ValueError, &"tele-to-murist only allows {MuristMeetTeleName}")
  result = @[&"tele name {name} {teleDest}"]

proc muristMeetDeleteSql*(): string =
  ## DELETE scratch game_tele row (fixed name — no user input).
  result = &"DELETE FROM game_tele WHERE name = '{MuristMeetTeleName}'"

proc muristMeetInsertSql*(mapId: int, x, y, z: float): string =
  ## INSERT scratch game_tele at Murist's coords (next free id).
  if mapId < 0 or mapId > 10000:
    raise newException(ValueError, &"invalid map id: {mapId}")
  # Floats only — never interpolate free text.
  let xs = formatFloat(x, ffDecimal, 4)
  let ys = formatFloat(y, ffDecimal, 4)
  let zs = formatFloat(z, ffDecimal, 4)
  result = &"INSERT INTO game_tele (id, position_x, position_y, position_z, orientation, map, name) SELECT COALESCE(MAX(id),0)+1, {xs}, {ys}, {zs}, 0, {mapId}, '{MuristMeetTeleName}' FROM game_tele"

proc findCharacterByName*(characters: seq[Character], name: string): Option[Character] =
  ## Linear lookup by exact character name.
  for s in characters:
    if s.name == name:
      return some(s)
  result = none(Character)

proc execMariadbSql*(db, sql: string) =
  ## Run one SQL statement via docker exec + mariadb (admin path; not policy).
  let container = gameContainer()
  let process = startProcess(
    "docker",
    args = [
      "exec", container,
      "mariadb",
      &"-u{DbUser}",
      &"-p{DbPass}",
      db,
      "-e", sql
    ],
    options = {poUsePath}
  )
  let output = process.outputStream.readAll()
  let err = process.errorStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(IOError,
      &"SQL failed (exit {exitCode}) db={db}: {err}\n{output}\nSQL: {sql}")

proc soapStepOk(detail: string): bool =
  ## Heuristic: VMaNGOS SOAP success text vs denial.
  let low = detail.toLowerAscii()
  result = not (
    low.contains("not available") or low.contains("not found") or
    low.contains("no such") or low.contains("incorrect syntax") or
    low.contains("does not exist")
  )

proc adminActionToJson*(r: AdminActionResult): JsonNode =
  ## Serialize an admin action for MCP / JSON APIs.
  var steps = newJArray()
  for s in r.steps:
    steps.add(%*{
      "name": s.name,
      "command": s.command,
      "ok": s.ok,
      "detail": s.detail
    })
  result = %*{
    "ok": r.ok,
    "action": r.action,
    "summary": r.summary,
    "steps": steps,
    "seats": BotSeats,
    "tele": ShadowArmyRespawnTele
  }

proc respawnShadowArmy*(): AdminActionResult =
  ## Ops escape hatch: SOAP-revive each bot seat and tele to Deathknell.
  ##
  ## This is **not** fair-play recovery. It is an admin-only testing reset when
  ## corpse runs stall (ghost masks, elevated death pockets, etc.). Policy
  ## brains must never call this; only The System admin interfaces (HTTP / MCP /
  ## human-seat `<SA> admin respawn_shadow_army`).
  result = AdminActionResult(ok: true, action: "respawn_shadow_army", steps: @[])
  recordAdmin(
    DefaultAuditPath,
    kind = "respawn_shadow_army_begin",
    detail = "revive+tele+repair for bot seats"
  )
  for name in BotSeats:
    for cmd in respawnCommandsFor(name):
      var step = AdminStepResult(name: name, command: cmd, ok: true, detail: "")
      try:
        step.detail = gmCommand(cmd).strip()
        # VMaNGOS often returns success text; treat obvious denial as failure.
        let low = step.detail.toLowerAscii()
        if low.contains("not available") or low.contains("not found") or
            low.contains("no such") or low.contains("incorrect syntax"):
          step.ok = false
          result.ok = false
      except Exception as e:
        step.ok = false
        step.detail = e.msg
        result.ok = false
      result.steps.add(step)
      # Fair-play audit: mark each SOAP step as admin_setup (not policy).
      let kind =
        if cmd.startsWith("tele "): "teleport"
        elif cmd.startsWith("repairitems"): "repair"
        elif cmd.startsWith("revive"): "revive"
        else: "soap"
      recordAdmin(
        DefaultAuditPath,
        kind = kind,
        character = name,
        detail = cmd & (if step.ok: " ok" else: " FAIL " & step.detail)
      )
  try:
    discard announceInGame(
      "<SYS> admin respawned shadow army (revive+tele " &
      ShadowArmyRespawnTele & ")"
    )
  except Exception as e:
    result.ok = false
    result.steps.add(AdminStepResult(
      name: "(announce)",
      command: "announce …",
      ok: false,
      detail: e.msg
    ))
  var okCount = 0
  for s in result.steps:
    if s.ok:
      inc okCount
  result.summary =
    if result.ok:
      &"respawned {BotSeats.len} bot seats → {ShadowArmyRespawnTele} ({okCount} SOAP steps ok)"
    else:
      &"respawn partial/fail ({okCount}/{result.steps.len} SOAP steps ok) — see steps"

proc telePartyToMurist*(): AdminActionResult =
  ## Ops escape hatch: pin game_tele to Murist's coords, reload, tele bot seats.
  ##
  ## Console SOAP only supports `tele name <player> <game_tele>` (not free xyz).
  ## So we upsert `SA_MURIST_MEET` in mangos.game_tele from characters.position_*,
  ## `reload game_tele`, then `tele name` each fixed bot seat. Not fair-play.
  result = AdminActionResult(ok: true, action: "tele_party_to_murist", steps: @[])
  recordAdmin(
    DefaultAuditPath,
    kind = "tele_party_to_murist_begin",
    detail = "pin SA_MURIST_MEET + tele bot seats"
  )

  var muristOpt: Option[Character]
  try:
    muristOpt = findCharacterByName(listCharacters(), AdminRequesterName)
  except Exception as e:
    result.ok = false
    result.summary = "failed to read roster: " & e.msg
    result.steps.add(AdminStepResult(
      name: AdminRequesterName, command: "listCharacters", ok: false, detail: e.msg))
    return

  if muristOpt.isNone:
    result.ok = false
    result.summary = &"{AdminRequesterName} not found in characters DB"
    result.steps.add(AdminStepResult(
      name: AdminRequesterName, command: "find Murist", ok: false,
      detail: "missing from roster"))
    return

  let murist = muristOpt.get
  let where =
    &"map={murist.mapId} ({murist.posX:.1f}, {murist.posY:.1f}, {murist.posZ:.1f})"

  # 1) Upsert scratch game_tele at Murist's last DB position.
  try:
    execMariadbSql(WorldDbName, muristMeetDeleteSql())
    execMariadbSql(WorldDbName, muristMeetInsertSql(
      murist.mapId, murist.posX, murist.posY, murist.posZ))
    result.steps.add(AdminStepResult(
      name: MuristMeetTeleName,
      command: "game_tele upsert",
      ok: true,
      detail: where
    ))
    recordAdmin(
      DefaultAuditPath,
      kind = "teleport",
      character = AdminRequesterName,
      detail = "upsert " & MuristMeetTeleName & " " & where
    )
  except Exception as e:
    result.ok = false
    result.steps.add(AdminStepResult(
      name: MuristMeetTeleName, command: "game_tele upsert",
      ok: false, detail: e.msg))
    result.summary = "game_tele upsert failed: " & e.msg
    return

  # 2) Reload ObjectMgr game_tele cache.
  try:
    let detail = gmCommand("reload game_tele").strip()
    let ok = soapStepOk(detail)
    if not ok:
      result.ok = false
    result.steps.add(AdminStepResult(
      name: "(world)", command: "reload game_tele", ok: ok, detail: detail))
    if not ok:
      result.summary = "reload game_tele failed"
      return
  except Exception as e:
    result.ok = false
    result.steps.add(AdminStepResult(
      name: "(world)", command: "reload game_tele", ok: false, detail: e.msg))
    result.summary = "reload game_tele failed: " & e.msg
    return

  # 3) Tele each bot seat to the pin.
  for name in BotSeats:
    for cmd in teleToMuristCommandsFor(name):
      var step = AdminStepResult(name: name, command: cmd, ok: true, detail: "")
      try:
        step.detail = gmCommand(cmd).strip()
        if not soapStepOk(step.detail):
          step.ok = false
          result.ok = false
      except Exception as e:
        step.ok = false
        step.detail = e.msg
        result.ok = false
      result.steps.add(step)
      recordAdmin(
        DefaultAuditPath,
        kind = "teleport",
        character = name,
        detail = cmd & (if step.ok: " ok" else: " FAIL " & step.detail)
      )

  try:
    discard announceInGame(
      "<SYS> admin teleported party to Murist (" & where & ")"
    )
  except Exception as e:
    result.ok = false
    result.steps.add(AdminStepResult(
      name: "(announce)", command: "announce …", ok: false, detail: e.msg))

  var okCount = 0
  for s in result.steps:
    if s.ok:
      inc okCount
  result.summary =
    if result.ok:
      &"teleported {BotSeats.len} bot seats → Murist {where} ({okCount} steps ok)"
    else:
      &"tele-to-murist partial/fail ({okCount}/{result.steps.len} steps ok) — see steps"

proc newestEventIdSnapshot(): int =
  ## Newest assigned event id, or -1 when the ring is empty.
  withLock gEventLock:
    if gEvents.len == 0:
      return -1
    return gEvents[^1].id

proc reloadAddon*(): JsonNode =
  ## Announce `<SYS> reload`, then wait up to 6s for a fresh `<SA> loaded` event.
  let snapshot = newestEventIdSnapshot()
  discard announceInGame("<SYS> reload")
  let steps = ReloadWaitMs div ReloadStepMs
  for _ in 0 ..< steps:
    sleep(ReloadStepMs)
    let events = recentEvents(limit = 20, kind = "loaded")
    for e in events:
      if e.id > snapshot:
        return %*{"ok": true, "loaded": eventToJson(e)}
  result = %*{
    "ok": false,
    "timeout": true,
    "hint": "no <SA> loaded seen in 25s — client logged out, on a loading screen, or the panel button is still unclicked (check addon_events for reload-click)"
  }

proc requestInventorySnapshot*(name = AdminRequesterName): JsonNode =
  ## Announce `<SYS> inv?` so logged-in addons re-emit a full `<SA> inv` set.
  ## Push is the normal path (login snapshot + BAG_UPDATE deltas); this is the
  ## on-demand poke. The addon drops identical outbound lines for 30s, so
  ## unchanged bags may answer with silence — the panel age stays the truth.
  let before = characterInventory(name)
  let detail = announceInGame("<SYS> inv?")
  result = %*{
    "ok": true,
    "name": name,
    "announce": detail,
    "age_sec_before": (
      if before.isSome and before.get.updatedAt > 0:
        epochTime() - before.get.updatedAt
      else: -1.0)
  }

# ---------------------------------------------------------------------------
# Seat babysitter (ticket 0055): watch → evidence → bounded auto-restart
#
# A home seat can wedge with its launcher PID alive and its Lua status file
# frozen (2026-08-15: Tusk hung on a world-asset stream mid-fight and nobody
# noticed until a human read the roster). The truth already exists on disk —
# status.json mtime — so The System owns the watch: sample every seat, capture
# the launcher.log evidence BEFORE recovery clobbers it, then restart through
# the same Makefile targets the roster buttons use. Bounded to
# SeatRestartBudget per SeatRestartWindowSec so a genuinely broken build turns
# into one persistent red alert instead of a restart loop.
# ---------------------------------------------------------------------------

type
  SeatWatch* = object
    ## One seat's liveness as the babysitter sees it (dashboard + MCP view).
    name*: string
    ## "running" | "starting" | "stopped" | "wedged"
    state*: string
    pidAlive*: bool
    hasStatus*: bool
    statusAgeSec*: float ## -1 when no status file exists yet
    restarts*: int ## auto-restarts inside the trailing window
    alerting*: bool ## budget spent — recovery paused, needs a human
    wedges*: int ## wedges observed since boot
    lastAction*: string ## last babysitter action line ("" when idle)
    lastActionAgeSec*: float ## -1 when nothing has happened yet
    evidence*: string ## basename of the last wedge evidence file

  SeatWatchRec = object
    ## Internal record: public view + the restart timestamps behind the budget.
    watch: SeatWatch
    stamps: seq[float]
    lastActionAt: float

var
  gSeatWatchLock: Lock
  gSeatWatch: seq[SeatWatchRec]
  gSeatWatchThread: Thread[void]
  gSystemBootAt: float

initLock(gSeatWatchLock)

proc seatBabysitterEnabled*(): bool =
  ## On by default; SYSTEM_SEAT_BABYSITTER=0 makes the watch observe-only.
  let env = getEnv("SYSTEM_SEAT_BABYSITTER", "1").strip().toLowerAscii()
  result = env notin ["0", "false", "off", "no"]

proc seatWedgeStaleSec*(): float =
  ## Staleness threshold; SYSTEM_SEAT_STALE_SEC overrides (test rigs).
  let env = getEnv("SYSTEM_SEAT_STALE_SEC", "").strip()
  if env.len > 0:
    try:
      let v = parseFloat(env)
      if v > 0:
        return v
    except ValueError:
      discard
  result = SeatWedgeStaleSec

proc classifySeat*(
    pidAlive, hasStatus: bool,
    statusAgeSec: float,
    staleSec = SeatWedgeStaleSec
): string =
  ## Pure liveness rule. A seat only counts as WEDGED when its launcher is
  ## alive AND a status file exists AND that file has stopped moving: a seat
  ## with no status file yet is still booting (a cold `nim r` build is slow),
  ## and must never be restarted for it.
  if not pidAlive:
    return "stopped"
  if not hasStatus:
    return "starting"
  if statusAgeSec < -2.0:
    return "starting" # clock skew / file written in the future
  if statusAgeSec > staleSec:
    return "wedged"
  result = "running"

proc pruneRestartStamps*(
    stamps: seq[float], now: float, windowSec = SeatRestartWindowSec
): seq[float] =
  ## Drop restart timestamps that fell out of the rate-limit window.
  result = @[]
  for t in stamps:
    if now - t <= windowSec:
      result.add(t)

proc restartAllowed*(
    stamps: seq[float], now: float,
    budget = SeatRestartBudget, windowSec = SeatRestartWindowSec
): bool =
  ## True while the seat still has recovery budget in the trailing window.
  result = pruneRestartStamps(stamps, now, windowSec).len < budget

proc seatWatchStatePath*(): string =
  armyRoot() / SeatWatchStateRel

proc tailLogLines*(path: string, maxLines: int): seq[string] =
  ## Last maxLines lines of a (possibly large) log file. Empty when missing.
  result = @[]
  let chunk = readFileTail(path, SeatWedgeEvidenceBytes)
  if chunk.len == 0:
    return
  let lines = chunk.strip(leading = false).splitLines()
  let n = min(maxLines, lines.len)
  if n <= 0:
    return
  result = lines[lines.len - n .. ^1]

proc wedgeEvidenceName*(stamp: Time): string =
  ## wedge-<UTC timestamp>.log — sorts chronologically next to launcher.log.
  "wedge-" & stamp.utc().format("yyyyMMdd'T'HHmmss'Z'") & ".log"

proc captureWedgeEvidence*(
    name: string, statusAgeSec: float, stamp = getTime()
): string =
  ## Write the launcher.log tail into the seat dir BEFORE recovery rotates it.
  ## Returns the file basename, or "" when nothing could be written.
  try:
    let dir = seatRuntimeDir(name)
    if not dirExists(dir):
      return ""
    let fileName = wedgeEvidenceName(stamp)
    var body = &"# wedge evidence: {name}\n"
    body.add(&"# captured: {stamp.utc().format(\"yyyy-MM-dd HH:mm:ss\")}Z\n")
    body.add(&"# status.json age: {statusAgeSec.int}s (threshold {seatWedgeStaleSec().int}s)\n")
    body.add(&"# launcher pid alive: yes\n")
    body.add(&"# last {SeatWedgeEvidenceLines} launcher.log lines:\n")
    for line in tailLogLines(dir / "launcher.log", SeatWedgeEvidenceLines):
      body.add(line & "\n")
    writeFile(dir / fileName, body)
    result = fileName
  except CatchableError:
    result = ""

proc loadSeatWatchState() =
  ## Restore restart stamps so a dashboard restart cannot refill the budget.
  var node: JsonNode = nil
  try:
    if fileExists(seatWatchStatePath()):
      node = parseJson(readFile(seatWatchStatePath()))
  except CatchableError:
    node = nil
  withLock gSeatWatchLock:
    gSeatWatch = @[]
    for seat in SeatMakeTargets:
      var rec = SeatWatchRec(
        watch: SeatWatch(
          name: seat.name, state: "stopped", statusAgeSec: -1.0,
          lastActionAgeSec: -1.0),
        stamps: @[]
      )
      if node != nil and node.kind == JObject and node.hasKey("seats") and
          node["seats"].hasKey(seat.name):
        let s = node["seats"][seat.name]
        if s.hasKey("restarts") and s["restarts"].kind == JArray:
          for t in s["restarts"]:
            rec.stamps.add(t.getFloat(0.0))
        if s.hasKey("alerting"):
          rec.watch.alerting = s["alerting"].getBool(false)
      gSeatWatch.add(rec)

proc saveSeatWatchState() =
  ## Persist the rate-limit window (best effort; never fails a recovery).
  try:
    var seats = newJObject()
    withLock gSeatWatchLock:
      for rec in gSeatWatch:
        var stamps = %*[]
        for t in rec.stamps:
          stamps.add(%t)
        seats[rec.watch.name] = %*{
          "restarts": stamps,
          "alerting": rec.watch.alerting
        }
    let path = seatWatchStatePath()
    createDir(path.parentDir)
    writeFile(path, pretty(%*{"seats": seats}))
  except CatchableError:
    discard

proc seatWatchStatus*(): seq[SeatWatch] =
  ## Current babysitter view — single dispatch for the dashboard + MCP.
  let nowSec = epochTime()
  result = @[]
  withLock gSeatWatchLock:
    for rec in gSeatWatch:
      var w = rec.watch
      w.restarts = pruneRestartStamps(rec.stamps, nowSec).len
      w.lastActionAgeSec =
        if rec.lastActionAt > 0: nowSec - rec.lastActionAt else: -1.0
      result.add(w)

proc seatWatchToJson*(seats: seq[SeatWatch]): JsonNode =
  ## Serialize the babysitter view for MCP / JSON APIs.
  result = %*[]
  for w in seats:
    result.add(%*{
      "name": w.name,
      "state": w.state,
      "pid_alive": w.pidAlive,
      "has_status": w.hasStatus,
      "status_age_sec": w.statusAgeSec,
      "restarts_last_hour": w.restarts,
      "alerting": w.alerting,
      "wedges": w.wedges,
      "last_action": w.lastAction,
      "last_action_age_sec": w.lastActionAgeSec,
      "evidence": w.evidence
    })

proc recoverWedgedSeat(idx: int, name: string, statusAgeSec: float) =
  ## Evidence first, then a bounded stop+start through the Makefile targets.
  let nowSec = epochTime()
  let evidence = captureWedgeEvidence(name, statusAgeSec)
  var allowed = false
  var used = 0
  withLock gSeatWatchLock:
    inc gSeatWatch[idx].watch.wedges
    gSeatWatch[idx].watch.evidence = evidence
    gSeatWatch[idx].stamps = pruneRestartStamps(gSeatWatch[idx].stamps, nowSec)
    allowed = gSeatWatch[idx].stamps.len < SeatRestartBudget
    used = gSeatWatch[idx].stamps.len
  pushSystemEvent(name, "wedge",
    &"status stale {statusAgeSec.int}s with launcher alive; evidence {evidence}")
  if not allowed:
    withLock gSeatWatchLock:
      gSeatWatch[idx].watch.alerting = true
      gSeatWatch[idx].lastActionAt = nowSec
      gSeatWatch[idx].watch.lastAction =
        &"auto-restart paused after {used} restarts in the last hour"
    pushSystemEvent(name, "alert",
      &"wedged again after {used} auto-restarts in the last hour — recovery paused")
    saveSeatWatchState()
    return
  withLock gSeatWatchLock:
    gSeatWatch[idx].stamps.add(nowSec)
    gSeatWatch[idx].lastActionAt = nowSec
    gSeatWatch[idx].watch.lastAction = "restarting (wedged)"
  saveSeatWatchState()
  var detail = ""
  try:
    let stopped = stopBotSeat(name)
    detail = stopped{"detail"}.getStr("")
    let started = startBotSeat(name)
    detail.add(" · " & started{"detail"}.getStr(""))
  except CatchableError as e:
    detail = "restart failed: " & e.msg
  withLock gSeatWatchLock:
    gSeatWatch[idx].watch.lastAction = "auto-restart: " & tailForDisplay(detail, 160)
  pushSystemEvent(name, "restart", &"auto-restart {used + 1}/{SeatRestartBudget} this hour: {detail}")

proc babysitSeatsOnce*() =
  ## One sampling pass over every home seat: classify, then recover if wedged.
  ## Safe to call from a test — it only ever touches SeatMakeTargets seats
  ## under armyRoot().
  let nowSec = epochTime()
  let staleSec = seatWedgeStaleSec()
  var initialized = false
  withLock gSeatWatchLock:
    initialized = gSeatWatch.len == SeatMakeTargets.len
  if not initialized:
    loadSeatWatchState()
  for idx, seat in SeatMakeTargets:
    let name = seat.name
    let pidAlive = seatPidAlive(name)
    let statusPath = seatStatusPath(name)
    let hasStatus = fileExists(statusPath)
    var age = -1.0
    if hasStatus:
      try:
        age = nowSec - getLastModificationTime(statusPath).toUnixFloat()
      except CatchableError:
        age = -1.0
    let state = classifySeat(pidAlive, hasStatus, age, staleSec)
    var lastActionAt = 0.0
    withLock gSeatWatchLock:
      gSeatWatch[idx].watch.name = name
      gSeatWatch[idx].watch.state = state
      gSeatWatch[idx].watch.pidAlive = pidAlive
      gSeatWatch[idx].watch.hasStatus = hasStatus
      gSeatWatch[idx].watch.statusAgeSec = age
      lastActionAt = gSeatWatch[idx].lastActionAt
      if state == "running" and gSeatWatch[idx].watch.alerting:
        # Healthy again: clear the alert, keep the restart history honest.
        gSeatWatch[idx].watch.alerting = false
        gSeatWatch[idx].watch.lastAction = "recovered"
        gSeatWatch[idx].lastActionAt = nowSec
    if state != "wedged":
      continue
    if not seatBabysitterEnabled():
      continue
    if nowSec - gSystemBootAt < SeatWatchStartupGraceSec:
      continue # our own restart, not the seat's fault
    if lastActionAt > 0 and nowSec - lastActionAt < SeatRecoveryCooldownSec:
      continue # a restart is still landing
    recoverWedgedSeat(idx, name, age)

proc seatWatchLoop() {.thread.} =
  ## Babysitter thread: sample every SeatWatchPollMs, forever.
  while true:
    sleep(SeatWatchPollMs)
    try:
      {.cast(gcsafe).}:
        babysitSeatsOnce()
    except Exception:
      discard

proc startSeatWatch() =
  ## Spawn the seat babysitter (call once from main before serve).
  gSystemBootAt = epochTime()
  loadSeatWatchState()
  createThread(gSeatWatchThread, seatWatchLoop)

# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

proc kindClass(kind: string): string =
  ## CSS class for an event kind cell.
  case kind
  of "err": "kind-err"
  of "loaded": "kind-loaded"
  else: "kind-muted"

proc renderEventRows*(events: seq[AddonEvent]): string =
  ## htmx partial: `<tr>` rows for the addon events table (newest first).
  if events.len == 0:
    return """<tr><td colspan="4" class="empty">No addon events yet.</td></tr>"""
  result = ""
  for e in events:
    result.add(&"""
      <tr>
        <td class="meta">{escapeHtml(e.time)}</td>
        <td class="name">{escapeHtml(e.name)}</td>
        <td><span class="kind {kindClass(e.kind)}">{escapeHtml(e.kind)}</span></td>
        <td class="payload">{escapeHtml(e.payload)}</td>
      </tr>
""")

proc renderReloadResult*(node: JsonNode): string =
  ## Small HTML span summarizing a reloadAddon() outcome.
  let ok = node{"ok"}.getBool(false)
  if ok:
    let loaded = node{"loaded"}
    let name = if loaded != nil: loaded{"name"}.getStr("?") else: "?"
    let rev = if loaded != nil: loaded{"payload"}.getStr("") else: ""
    result = &"""<span class="reload-ok">ok — {escapeHtml(name)} {escapeHtml(rev)}</span>"""
  else:
    let hint = node{"hint"}.getStr("timeout")
    result = &"""<span class="reload-timeout">timeout — {escapeHtml(hint)}</span>"""

proc renderServerPanel*(s: ServerStatus): string =
  ## htmx partial: inner content of the Server panel (status pill + lifecycle
  ## buttons). Rendered whether the realm is up, down, or mid-op — this is
  ## what keeps the dashboard useful with the server offline.
  var pill: string
  if s.op == "start":
    pill = """<span class="pill"><span class="dot warn"></span> Starting…</span>"""
  elif s.op == "stop":
    pill = """<span class="pill"><span class="dot warn"></span> Stopping…</span>"""
  elif s.running:
    pill = """<span class="pill"><span class="dot on"></span> Running</span>"""
  else:
    # Exited containers still have a docker id — call that out so "Stopped + id"
    # is not misread as a live instance.
    if s.containerId.len > 0:
      pill = """<span class="pill"><span class="dot off"></span> Stopped (exited)</span>"""
    else:
      pill = """<span class="pill"><span class="dot off"></span> Stopped</span>"""

  var action: string
  if s.op.len > 0:
    action = """<span class="meta">in progress…</span>"""
  elif s.running:
    action = """
      <button class="btn danger"
              hx-post="/server/stop"
              hx-target="#server-panel"
              hx-swap="innerHTML"
              hx-confirm="Stop the realm?">
        Stop server
      </button>"""
  else:
    action = """
      <button class="btn primary"
              hx-post="/server/start"
              hx-target="#server-panel"
              hx-swap="innerHTML">
        Start server
      </button>"""

  var lastLine = ""
  if s.lastOp.len > 0:
    let cls = if s.lastOpOk: "admin-ok" else: "admin-err"
    let mark = if s.lastOpOk: "ok" else: "FAIL"
    lastLine = &"""
      <div class="server-last {cls}" title="{escapeHtml(s.lastOpDetail)}">
        last {escapeHtml(s.lastOp)}: {mark}
      </div>"""

  # Name + short id. When not running, label the id as exited so it is not
  # mistaken for a live handle (docker keeps the container object after crash).
  var containerLabel = escapeHtml(s.container)
  if s.containerId.len > 0:
    if s.running or s.op.len > 0:
      containerLabel.add(&""" <span class="server-id">{escapeHtml(s.containerId)}</span>""")
    else:
      containerLabel.add(
        &""" <span class="server-id muted">exited {escapeHtml(s.containerId)}</span>""")
  else:
    containerLabel.add(""" <span class="server-id muted">no container</span>""")

  result = &"""
    <div class="server-line">
      {pill}
      <span class="meta server-container">{containerLabel}</span>
      <span class="server-action">{action}</span>
    </div>
    {lastLine}"""

proc renderXpCell*(s: Character): string =
  ## Level progress cell: bar + "cur/need (N to go)".
  if s.nextLevelXp <= 0:
    return """<span class="xp-muted">—</span>"""
  let label = &"{s.xp}/{s.nextLevelXp} · {s.xpToLevel} to go"
  result = &"""
    <div class="xp" title="{escapeHtml(label)}">
      <div class="xp-bar"><div class="xp-fill" style="width:{s.xpPct}%"></div></div>
      <div class="xp-meta">{s.xp}<span class="xp-muted">/{s.nextLevelXp}</span> · <strong>{s.xpToLevel}</strong> to go</div>
    </div>"""

proc vitalsPct(cur, maxv: int): int =
  ## 0..100 fill for a vitals bar; empty when max unknown.
  if maxv <= 0:
    return 0
  result = max(0, min(100, (cur * 100) div maxv))

proc renderVitalsCell*(s: Character): string =
  ## HP + primary power (mana/rage/energy) with mini bars.
  let hpMaxLabel = if s.maxHealth > 0: $s.maxHealth else: "?"
  let hpPct = vitalsPct(s.health, s.maxHealth)
  let hpLow = s.life == "alive" and s.maxHealth > 0 and hpPct <= 35
  let hpClass = if hpLow: "hp low" else: "hp"
  let hpTitle = &"HP {s.health}/{hpMaxLabel}"
  var powerBlock = """<div class="vitals-line vitals-muted">—</div>"""
  if s.powerKind.len > 0:
    let pMaxLabel = if s.maxPower > 0: $s.maxPower else: "?"
    let pPct = vitalsPct(s.power, s.maxPower)
    let pLabel =
      case s.powerKind
      of "mana": "MP"
      of "rage": "Rage"
      of "energy": "Energy"
      else: s.powerKind
    let pClass =
      case s.powerKind
      of "mana": "mana"
      of "rage": "rage"
      of "energy": "energy"
      else: "mana"
    let pTitle = &"{pLabel} {s.power}/{pMaxLabel}"
    powerBlock = &"""
      <div class="vitals-line" title="{escapeHtml(pTitle)}">
        <span class="vitals-tag">{escapeHtml(pLabel)}</span>
        <div class="vitals-bar"><div class="vitals-fill {pClass}" style="width:{pPct}%"></div></div>
        <span class="vitals-num">{s.power}<span class="xp-muted">/{escapeHtml(pMaxLabel)}</span></span>
      </div>"""
  result = &"""
    <div class="vitals">
      <div class="vitals-line" title="{escapeHtml(hpTitle)}">
        <span class="vitals-tag">HP</span>
        <div class="vitals-bar"><div class="vitals-fill {hpClass}" style="width:{hpPct}%"></div></div>
        <span class="vitals-num">{s.health}<span class="xp-muted">/{escapeHtml(hpMaxLabel)}</span></span>
      </div>
      {powerBlock}
    </div>"""

proc renderPosCell*(s: Character): string =
  ## Compact map position for corpse-run / regroup awareness.
  if abs(s.posX) + abs(s.posY) < 0.01:
    return """<span class="xp-muted">—</span>"""
  let label = &"{s.posX:.0f}, {s.posY:.0f}"
  let title = &"map {s.mapId} · x={s.posX:.1f} y={s.posY:.1f} z={s.posZ:.1f}"
  result = &"""<span class="pos" title="{escapeHtml(title)}">{escapeHtml(label)}</span>"""

proc renderSeatCell*(s: Character): string =
  ## Realm connection as a terse On/Off. Bot runtime detail stays in the
  ## tooltip so it does not duplicate the Bot column.
  let net = if s.online: "On" else: "Off"
  let netCls = if s.online: "online" else: "offline"
  let title =
    if seatMakeTarget(s.name).len == 0:
      "human seat"
    elif s.controlUp:
      "embedded Lua policy heartbeat is fresh"
    else:
      "embedded Lua policy is stopped, starting, or stale"
  result = &"""<span class="seat-net {netCls}" title="{escapeHtml(title)}">{escapeHtml(net)}</span>"""

proc renderBotCell*(s: Character): string =
  ## Per-seat Start/Stop button for launchable bot seats ("—" otherwise).
  ## controlUp is the truth signal: PID alive + Lua heartbeat fresh.
  if seatMakeTarget(s.name).len == 0:
    return """<span class="xp-muted">—</span>"""
  if s.controlUp:
    result = &"""
      <button class="bot-btn stop"
              hx-post="/bots/stop?name={escapeHtml(s.name)}"
              hx-target="#roster"
              hx-swap="innerHTML"
              hx-confirm="Stop {escapeHtml(s.name)}'s seat? (client logs out)">
        Stop
      </button>"""
  else:
    result = &"""
      <button class="bot-btn start"
              hx-post="/bots/start?name={escapeHtml(s.name)}"
              hx-target="#roster"
              hx-swap="innerHTML">
        Start
      </button>"""

proc armySummary*(characters: seq[Character]): string =
  ## One-line army health strip for the roster panel head.
  var online, alive, ghost, dead, botsUp, botsKnown = 0
  for s in characters:
    if s.online: inc online
    case s.life
    of "alive": inc alive
    of "ghost": inc ghost
    of "dead": inc dead
    else: discard
    if seatMakeTarget(s.name).len > 0:
      inc botsKnown
      if s.controlUp: inc botsUp
  result = &"{online} online · {alive} alive · {ghost} ghost · {dead} dead"
  if botsKnown > 0:
    result.add(&" · bots {botsUp}/{botsKnown}")

proc renderRosterRows*(characters: seq[Character]): string =
  ## htmx partial: `<tr>` rows for the roster table body.
  if characters.len == 0:
    return """<tr><td colspan="11" class="empty">No characters.</td></tr>"""
  result = ""
  for s in characters:
    let life = if s.life.len > 0: s.life else: (if s.online: "alive" else: "offline")
    let lifeText = lifeLabel(life)
    let zoneText = if s.zoneName.len > 0: s.zoneName else: "—"
    let connNote = if life == "ghost" and not s.online: " · offline" else: ""
    var rowClass = ""
    if isFoundationSeat(s.name):
      rowClass.add(" foundation")
    if life == "ghost":
      rowClass.add(" row-ghost")
    elif life == "dead":
      rowClass.add(" row-dead")
    result.add(&"""
      <tr class="{rowClass.strip()}">
        <td class="name">{escapeHtml(s.name)}</td>
        <td class="lvl">{s.level}</td>
        <td class="xp-cell">{renderXpCell(s)}</td>
        <td class="vitals-cell">{renderVitalsCell(s)}</td>
        <td>{escapeHtml(s.className)}</td>
        <td class="zone" title="zone id {s.zoneId} · map {s.mapId}">{escapeHtml(zoneText)}</td>
        <td class="pos-cell">{renderPosCell(s)}</td>
        <td class="gold">{escapeHtml(s.gold)}</td>
        <td><span class="status {escapeHtml(life)}">{escapeHtml(lifeText)}{escapeHtml(connNote)}</span></td>
        <td class="seat">{renderSeatCell(s)}</td>
        <td class="bot-cell">{renderBotCell(s)}</td>
      </tr>
""")

proc formatAgeSec*(sec: float): string =
  ## Compact "how old is this" label ("4s", "3m", "1h12m", "—").
  if sec < 0:
    return "—"
  if sec < 90:
    return &"{sec.int}s"
  if sec < 3600:
    return &"{(sec / 60).int}m"
  let hours = (sec / 3600).int
  let mins = ((sec - hours.float * 3600.0) / 60).int
  result = &"{hours}h{mins}m"

proc seatStateDotClass*(w: SeatWatch): string =
  ## Seat light: red for wedged/alerting, green running, amber starting, grey off.
  if w.alerting or w.state == "wedged":
    return "dot bad"
  case w.state
  of "running": "dot on"
  of "starting": "dot warn"
  else: "dot off"

proc renderSeatWatchRows*(seats: seq[SeatWatch]): string =
  ## Babysitter table body: one line per home seat, red when wedged.
  if seats.len == 0:
    return """<tr><td colspan="6" class="empty">No home seats configured.</td></tr>"""
  result = ""
  for w in seats:
    let stateText = if w.alerting: "ALERT" else: w.state
    let stateCls =
      if w.alerting or w.state == "wedged": "status dead"
      elif w.state == "running": "status alive"
      elif w.state == "starting": "status warn"
      else: "status offline"
    let rowCls = if w.alerting or w.state == "wedged": " class=\"row-dead\"" else: ""
    let age = if w.hasStatus: formatAgeSec(w.statusAgeSec) else: "—"
    let restarts =
      if w.restarts > 0: &"{w.restarts}/{SeatRestartBudget}"
      else: "0"
    var last = w.lastAction
    if last.len > 0 and w.lastActionAgeSec >= 0:
      last = &"{last} · {formatAgeSec(w.lastActionAgeSec)} ago"
    if last.len == 0:
      last = "—"
    let evidence = if w.evidence.len > 0: escapeHtml(w.evidence) else: "—"
    result.add(&"""
      <tr{rowCls}>
        <td class="name"><span class="{seatStateDotClass(w)}"></span> {escapeHtml(w.name)}</td>
        <td><span class="{stateCls}">{escapeHtml(stateText)}</span></td>
        <td class="conn">{age}</td>
        <td class="conn">{restarts}</td>
        <td class="payload">{escapeHtml(last)}</td>
        <td class="payload">{evidence}</td>
      </tr>
""")

proc seatWatchSummary*(seats: seq[SeatWatch]): string =
  ## One-line babysitter strip for the panel head.
  var running, wedged, alerting, stopped = 0
  for w in seats:
    if w.alerting: inc alerting
    case w.state
    of "running": inc running
    of "wedged": inc wedged
    of "stopped": inc stopped
    else: discard
  result = &"{running}/{seats.len} live · {wedged} wedged"
  if alerting > 0:
    result.add(&" · {alerting} alert")

proc renderSeatWatchPanelBody*(seats: seq[SeatWatch]): string =
  ## Full babysitter panel body (summary + table) — one htmx swap target.
  let alerts = block:
    var names: seq[string] = @[]
    for w in seats:
      if w.alerting:
        names.add(w.name)
    names
  var banner = ""
  if alerts.len > 0:
    banner = &"""
      <p class="seat-alert">Auto-restart paused: {escapeHtml(alerts.join(", "))}
        ({SeatRestartBudget} restarts/hour spent)</p>"""
  result = &"""
      <div class="panel-actions" style="margin-bottom:0.6rem">
        <span class="army-summary">{escapeHtml(seatWatchSummary(seats))}</span>
        <span class="meta">wedge = status stale &gt; {seatWedgeStaleSec().int}s with launcher alive</span>
      </div>
{banner}
      <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Seat</th>
            <th>Watch</th>
            <th>Heartbeat</th>
            <th>Restarts/h</th>
            <th>Last action</th>
            <th>Evidence</th>
          </tr>
        </thead>
        <tbody>
{renderSeatWatchRows(seats)}
        </tbody>
      </table>
      </div>"""

proc renderInventoryPanelBody*(
    inv: Option[CharacterInventory], info: Table[int, ItemInfo]
): string =
  ## Compact bags panel body: value-sorted stacks + data age (one htmx swap).
  if inv.isNone or inv.get.lines == 0:
    return """
      <p class="empty">No inventory on the bus yet.</p>"""
  let c = inv.get
  if c.updatedAt <= 0:
    # Lines are arriving but no whole snapshot has landed yet: say so rather
    # than render a set we know is missing parts.
    return &"""
      <p class="empty">Inventory snapshot assembling ({c.partsSeen.len}/{c.partsTotal})…</p>"""
  var items = liveInventoryItems(c)
  proc sellOf(id: int): int =
    if info.hasKey(id): info[id].sellPrice else: 0
  items.sort(proc (a, b: InventoryItem): int =
    let va = sellOf(a.itemId) * a.count
    let vb = sellOf(b.itemId) * b.count
    if va != vb:
      return cmp(vb, va)
    return cmp(a.itemId, b.itemId)
  )
  var totalSell = 0
  for it in items:
    totalSell += sellOf(it.itemId) * it.count
  let age = if c.updatedAt > 0: epochTime() - c.updatedAt else: -1.0
  let ageCls = if age >= 0 and age <= 60: "army-summary" else: "army-summary stale"
  var partsNote = ""
  if invAssembling(c):
    partsNote = &"""<span class="badge warn">new snapshot {c.partsSeen.len}/{c.partsTotal}</span>"""
  var rows = ""
  var shown = 0
  for it in items:
    if shown >= InvPanelRows:
      break
    inc shown
    let known = info.hasKey(it.itemId)
    let name = if known and info[it.itemId].name.len > 0: info[it.itemId].name else: "—"
    let sell = sellOf(it.itemId)
    let value = sell * it.count
    rows.add(&"""
        <tr>
          <td class="conn">{it.itemId}</td>
          <td class="name">{escapeHtml(name)}</td>
          <td class="lvl">{it.count}</td>
          <td class="gold">{escapeHtml(formatGold(sell))}</td>
          <td class="gold">{escapeHtml(formatGold(value))}</td>
        </tr>
""")
  if rows.len == 0:
    # `<SA> inv 1/1` with no payload is a positive "bags are empty", which is
    # not the same as never having heard from this character.
    rows = """<tr><td colspan="5" class="empty">Bags empty.</td></tr>"""
  var more = ""
  if items.len > shown:
    more = &"""<span class="meta">+{items.len - shown} more</span>"""
  result = &"""
      <div class="panel-actions" style="margin-bottom:0.6rem">
        <span class="{ageCls}">updated {formatAgeSec(age)} ago</span>
        <span class="army-summary">{items.len} stacks · {escapeHtml(formatGold(totalSell))} vendor</span>
        {partsNote}
        {more}
      </div>
      <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Id</th>
            <th>Item</th>
            <th>Qty</th>
            <th>Sell</th>
            <th>Value</th>
          </tr>
        </thead>
        <tbody>
{rows}
        </tbody>
      </table>
      </div>"""

proc inventoryPanelFor*(name: string): string =
  ## Single dispatch for the bags panel: latest-known inventory + world-DB join.
  let inv = characterInventory(name)
  if inv.isNone:
    return renderInventoryPanelBody(inv, initTable[int, ItemInfo]())
  var ids: seq[int] = @[]
  for item in liveInventoryItems(inv.get):
    ids.add(item.itemId)
  result = renderInventoryPanelBody(inv, lookupItemInfo(ids))

proc renderRosterOfflineRow*(): string =
  ## Roster body when the realm is down: friendly nudge, not a red error.
  result = """<tr><td colspan="11" class="empty">Realm offline — <a href="/admin">Admin</a> to start.</td></tr>"""

## Shared dashboard CSS for Army / Advisor / Admin (plain string — no strformat braces).
## Visual language tracks the FFXIV Racha dashboard (navy/gold, sticky chrome, cards);
## content rules stay autoresearch/docs/dashboard.md: metrics and buttons only.
const DashboardCss = """
    :root {
      --bg: #0a0c12;
      --panel: #121826;
      --panel2: #0e1320;
      --border: #243049;
      --text: #e8eef8;
      --muted: #8b9bb4;
      --accent: #d4af37;
      --accent2: #6cb6ff;
      --good: #3dd68c;
      --warn: #f0c14b;
      --bad: #ff6b6b;
      --ghost: #c792ea;
      --ink: #0a0f18;
      --alive: var(--good);
      --dead: var(--bad);
      --err: var(--bad);
      --loaded: var(--good);
      --offline: #6e7681;
      --gold: var(--accent);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif;
      background:
        radial-gradient(900px 480px at 8% -8%, #1c2744 0%, transparent 55%),
        radial-gradient(700px 400px at 95% 0%, #2a1f12 0%, transparent 50%),
        var(--bg);
      color: var(--text);
      min-height: 100vh;
    }
    header.top {
      display: flex; flex-wrap: wrap; align-items: center; gap: 0.75rem 1rem;
      padding: 0.9rem 1.4rem;
      border-bottom: 1px solid var(--border);
      background: rgba(10,12,18,0.88);
      backdrop-filter: blur(10px);
      position: sticky; top: 0; z-index: 20;
    }
    header.top h1 {
      margin: 0; font-size: 1.2rem; font-weight: 650; letter-spacing: 0.03em;
    }
    header.top h1 span { color: var(--accent); }
    nav.tabs {
      display: flex; gap: 0.35rem; padding: 0.65rem 1.4rem 0;
      border-bottom: 1px solid var(--border);
      background: rgba(10,12,18,0.5);
    }
    nav.tabs a {
      appearance: none; border: 1px solid transparent; border-bottom: none;
      background: transparent; color: var(--muted); text-decoration: none;
      padding: 0.55rem 1rem; border-radius: 10px 10px 0 0;
      font-size: 0.85rem; font-weight: 600; letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    nav.tabs a:hover { color: var(--text); background: rgba(108,182,255,0.06); }
    nav.tabs a.active {
      color: var(--accent); background: var(--panel);
      border-color: var(--border); border-bottom-color: var(--panel);
      margin-bottom: -1px;
    }
    main {
      padding: 1rem 1.4rem 2.5rem;
      max-width: 1400px; margin: 0 auto;
      display: grid; gap: 1rem;
    }
    .panel {
      background: linear-gradient(180deg, var(--panel) 0%, var(--panel2) 100%);
      border: 1px solid var(--border);
      border-radius: 14px;
      min-width: 0;
      box-shadow: 0 10px 30px rgba(0,0,0,0.22);
      overflow: hidden;
    }
    /* Polls must not dim/flicker. Only intentional button actions show a
       load cue; htmx settle/swap classes stay fully opaque. */
    .htmx-swapping, .htmx-settling { opacity: 1 !important; }
    .btn.htmx-request { opacity: 0.72; transition: opacity 0.12s ease; }
    .table-scroll { overflow-x: auto; }
    .panel-head {
      display: flex; justify-content: space-between; align-items: center; gap: 0.75rem;
      padding: 0.9rem 1.1rem 0.55rem; flex-wrap: wrap;
    }
    .panel-head h2 {
      margin: 0; font-size: 0.78rem; text-transform: uppercase;
      letter-spacing: 0.09em; color: var(--muted); font-weight: 650;
    }
    .panel-actions {
      display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap;
    }
    .panel-body { padding: 0.75rem 1.1rem 1.1rem; }
    .meta { color: var(--muted); font-size: 0.8rem; }
    .muted { color: var(--muted); font-size: 0.85rem; line-height: 1.45; }
    a { color: var(--accent2); }
    table { width: 100%; border-collapse: collapse; font-size: 0.84rem; }
    th, td {
      text-align: left; padding: 0.42rem 0.55rem;
      border-bottom: 1px solid rgba(36,48,73,0.75);
    }
    th {
      color: var(--muted); font-weight: 550; font-size: 0.72rem;
      text-transform: uppercase; letter-spacing: 0.05em;
    }
    tr:hover td { background: rgba(108,182,255,0.04); }
    tr:last-child td { border-bottom: none; }
    td.name { font-weight: 600; }
    td.lvl { font-variant-numeric: tabular-nums; font-weight: 600; }
    td.gold { color: var(--accent); font-variant-numeric: tabular-nums; font-weight: 650; }
    td.zone { color: var(--text); font-size: 0.9rem; max-width: 10rem; }
    td.conn { color: var(--muted); font-size: 0.8rem; font-variant-numeric: tabular-nums; }
    td.payload {
      color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.82rem;
    }
    td.xp-cell { min-width: 9.5rem; }
    td.vitals-cell { min-width: 8rem; }
    .xp-bar {
      height: 7px; background: var(--ink); border-radius: 4px; overflow: hidden;
      border: 1px solid var(--border); margin-bottom: 0.25rem;
    }
    .xp-fill {
      height: 100%; border-radius: 3px;
      background: linear-gradient(90deg, var(--accent2), var(--good));
    }
    .xp-meta { font-size: 0.72rem; font-variant-numeric: tabular-nums; color: var(--text); }
    .xp-muted { color: var(--muted); font-weight: 400; }
    .vitals { display: flex; flex-direction: column; gap: 0.2rem; }
    .vitals-line {
      display: grid; grid-template-columns: 2.4rem 1fr auto; align-items: center;
      gap: 0.35rem; font-size: 0.72rem; font-variant-numeric: tabular-nums;
    }
    .vitals-tag { color: var(--muted); font-weight: 600; }
    .vitals-bar {
      height: 5px; background: var(--ink); border-radius: 4px; overflow: hidden;
      border: 1px solid var(--border);
    }
    .vitals-fill { height: 100%; border-radius: 3px; }
    .vitals-fill.hp { background: linear-gradient(90deg, #238636, var(--good)); }
    .vitals-fill.hp.low { background: linear-gradient(90deg, #a40e26, var(--bad)); }
    .vitals-fill.mana { background: linear-gradient(90deg, #1f6feb, var(--accent2)); }
    .vitals-fill.rage { background: linear-gradient(90deg, #a40e26, var(--bad)); }
    .vitals-fill.energy { background: linear-gradient(90deg, #9e6a03, var(--accent)); }
    .vitals-num { color: var(--text); white-space: nowrap; }
    .vitals-muted { color: var(--muted); }
    td.pos-cell, .pos {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8rem;
      font-variant-numeric: tabular-nums; color: var(--muted); white-space: nowrap;
    }
    td.seat { font-size: 0.8rem; white-space: nowrap; }
    td.bot-cell { white-space: nowrap; }
    .bot-btn {
      border: 1px solid var(--border); border-radius: 8px; padding: 0.2rem 0.55rem;
      font-size: 0.72rem; font-weight: 600; cursor: pointer; background: var(--ink);
      color: var(--accent2);
    }
    .bot-btn.start { color: var(--accent2); }
    .bot-btn.stop { color: var(--bad); border-color: rgba(255,107,107,0.4); }
    .bot-btn:hover { border-color: var(--accent2); }
    .seat-net.online { color: var(--good); font-weight: 600; }
    .seat-net.offline { color: var(--offline); }
    .seat-ctrl.ctrl-up { color: var(--accent2); }
    .seat-ctrl.ctrl-down { color: var(--bad); }
    tr.row-ghost { background: color-mix(in srgb, var(--ghost) 8%, transparent); }
    tr.row-dead { background: color-mix(in srgb, var(--bad) 8%, transparent); }
    .army-summary {
      font-size: 0.78rem; color: var(--muted); font-variant-numeric: tabular-nums;
      padding: 0.22rem 0.7rem; border-radius: 999px;
      border: 1px solid var(--border); background: var(--ink);
    }
    .stat-row {
      display: flex; flex-wrap: wrap; gap: 0.6rem; margin: 0 0 0.85rem;
    }
    .stat {
      flex: 1 1 100px;
      background: var(--ink);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 0.55rem 0.7rem;
      min-width: 0;
    }
    .stat .n {
      font-size: 1.15rem; font-weight: 700; color: var(--accent);
      letter-spacing: 0.01em; font-variant-numeric: tabular-nums;
    }
    .stat .n.sm { font-size: 0.95rem; }
    .stat .l { font-size: 0.7rem; color: var(--muted); margin-top: 0.1rem; }
    .murist-bars { margin-top: 0.5rem; }
    .murist-bars .xp-cell, .murist-bars .vitals-cell { display: block; margin-top: 0.45rem; }
    .pill {
      display: inline-flex; align-items: center; gap: 0.4rem;
      padding: 0.22rem 0.7rem; border-radius: 999px; font-size: 0.78rem;
      border: 1px solid var(--border); background: var(--panel);
    }
    .dot {
      display: inline-block;
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--bad); box-shadow: 0 0 0 transparent; flex-shrink: 0;
    }
    .dot.bad { background: var(--bad); box-shadow: 0 0 10px var(--bad); }
    .army-summary.stale { color: var(--warn); border-color: rgba(240,193,75,0.45); }
    .seat-alert {
      margin: 0 0 0.6rem; padding: 0.5rem 0.75rem; border-radius: 10px;
      font-size: 0.85rem; font-weight: 600; color: var(--bad);
      border: 1px solid rgba(255,107,107,0.45);
      background: linear-gradient(180deg, #2a1414 0%, var(--ink) 100%);
    }
    .dot.on { background: var(--good); box-shadow: 0 0 10px var(--good); }
    .dot.warn { background: var(--warn); box-shadow: 0 0 8px var(--warn); }
    .dot.off { background: var(--offline); }
    .status, .kind, .badge {
      display: inline-block; font-size: 0.68rem; font-weight: 600;
      padding: 0.12rem 0.45rem; border-radius: 4px;
      border: 1px solid var(--border); color: var(--muted); background: var(--ink);
    }
    .status.online, .status.alive, .kind-loaded, .badge.ok {
      color: var(--good); border-color: rgba(61,214,140,0.35);
    }
    .status.offline, .kind-muted {
      color: var(--muted); border-color: var(--border);
    }
    .status.busy {
      color: var(--accent2); border-color: rgba(108,182,255,0.35);
    }
    .status.ghost {
      color: var(--ghost); border-color: rgba(199,146,234,0.35);
    }
    .status.dead, .kind-err, .badge.bad {
      color: var(--bad); border-color: rgba(255,107,107,0.35);
    }
    .badge.warn, .status.warn {
      color: var(--warn); border-color: rgba(240,193,75,0.35);
    }
    .badge.accent { color: var(--accent); border-color: rgba(212,175,55,0.4); }
    .server-line { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
    .server-label { font-weight: 650; font-size: 0.9rem; }
    .server-container {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.75rem;
      color: var(--muted);
    }
    .server-id {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--accent2); font-size: 0.75rem; font-weight: 600;
    }
    .server-action { margin-left: auto; }
    .server-last { margin-top: 0.55rem; font-size: 0.8rem; }
    .empty { color: var(--muted); text-align: center; padding: 2rem 1rem; font-size: 0.9rem; }
    button.btn, button.reload, button.admin {
      display: inline-block; padding: 0.4rem 0.85rem; border-radius: 8px;
      border: 1px solid var(--border); background: var(--ink); color: var(--accent2);
      font-size: 0.8rem; font-weight: 600; cursor: pointer; font-family: inherit;
    }
    button.btn:hover, button.reload:hover { border-color: var(--accent2); }
    button.btn.primary, button.reload {
      background: linear-gradient(180deg, #2a2410 0%, var(--ink) 100%);
      color: var(--accent); border-color: rgba(212,175,55,0.45);
    }
    button.btn.primary:hover, button.reload:hover { border-color: var(--accent); }
    button.btn.danger, button.admin, button.admin.danger {
      color: var(--bad); border-color: rgba(255,107,107,0.45);
      background: linear-gradient(180deg, #2a1414 0%, var(--ink) 100%);
    }
    button.btn.danger:hover, button.admin:hover { border-color: var(--bad); }
    .reload-ok, .admin-ok { color: var(--good); font-size: 0.85rem; }
    .reload-timeout, .admin-err { color: var(--bad); font-size: 0.85rem; }
    .admin-actions { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; }
    .admin-steps {
      margin-top: 0.75rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.8rem; color: var(--muted); white-space: pre-wrap;
    }
"""

proc navTabClass(active, tab: string): string =
  ## ` class="active"` when this tab is selected; empty otherwise.
  if active == tab: " class=\"active\"" else: ""

proc renderNav*(active: string): string =
  ## Tab strip: Army | Murist | Advisor | Traverse | Admin.
  let army = navTabClass(active, "army")
  let murist = navTabClass(active, "murist")
  let advisor = navTabClass(active, "advisor")
  let traverse = navTabClass(active, "traverse")
  let admin = navTabClass(active, "admin")
  result = &"""
<nav class="tabs" role="tablist">
  <a{army} href="/army" role="tab">Army</a>
  <a{murist} href="/murist" role="tab">Murist</a>
  <a{advisor} href="/advisor" role="tab">Advisor</a>
  <a{traverse} href="/traverse" role="tab">Traverse</a>
  <a{admin} href="/admin" role="tab">Admin</a>
</nav>"""

proc renderDashboard*(title, active, body: string): string =
  ## Full HTML shell shared by Army / Advisor / Admin tabs.
  ## Metrics and buttons only — no tutorial or implementation copy.
  result = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>The System — """ & escapeHtml(title) & """</title>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <style>
""" & DashboardCss & """
  </style>
</head>
<body>
  <header class="top">
    <h1>The System · <span>""" & escapeHtml(title) & """</span></h1>
  </header>
""" & renderNav(active) & """
  <main>
""" & body & """
  </main>
</body>
</html>
"""

proc renderArmyPage*(
    characters: seq[Character],
    seats: seq[SeatWatch] = @[],
    rosterOffline = false
): string =
  ## Army tab: roster + seat babysitter. Foundation seats always hidden.
  let rows = if rosterOffline: renderRosterOfflineRow() else: renderRosterRows(characters)
  let summary = armySummary(characters)
  let seatBody = renderSeatWatchPanelBody(seats)
  let body = &"""
    <section class="panel">
      <div class="panel-head">
        <h2>Roster</h2>
        <div class="panel-actions">
          <span class="army-summary" id="army-summary">{escapeHtml(summary)}</span>
        </div>
      </div>
      <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Lvl</th>
            <th>XP</th>
            <th>HP / MP</th>
            <th>Class</th>
            <th>Zone</th>
            <th>Pos</th>
            <th>Gold</th>
            <th>Life</th>
            <th>Seat</th>
            <th>Bot</th>
          </tr>
        </thead>
        <tbody id="roster"
               hx-get="/roster"
               hx-trigger="every {PollSeconds}s"
               hx-swap="innerHTML settle:0s swap:0s">
{rows}
        </tbody>
      </table>
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Seat watch</h2>
      </div>
      <div class="panel-body"
           id="seat-watch"
           hx-get="/seats"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{seatBody}
      </div>
    </section>"""
  result = renderDashboard("Army", "army", body)

proc filterEventsByName*(events: seq[AddonEvent], name: string): seq[AddonEvent] =
  ## Keep events for one character name (case-sensitive DB/chat name).
  result = @[]
  for e in events:
    if e.name == name:
      result.add(e)

proc renderMuristStatus*(murist: Option[Character], realmOffline = false): string =
  ## Human-seat status panel body (metrics only).
  if realmOffline:
    return """
    <p class="empty">Realm offline — start on <a href="/admin">Admin</a>.</p>"""
  if murist.isNone:
    return """
    <p class="empty">Murist not in characters DB.</p>"""
  let c = murist.get
  let life = if c.life.len > 0: c.life else: (if c.online: "alive" else: "offline")
  let lifeText = lifeLabel(life)
  let zoneText = if c.zoneName.len > 0: c.zoneName else: "—"
  let onlinePill =
    if c.online:
      """<span class="pill"><span class="dot on"></span> online</span>"""
    else:
      """<span class="pill"><span class="dot off"></span> offline</span>"""
  result = &"""
    <div class="panel-actions" style="margin-bottom:0.75rem">
      {onlinePill}
      <span class="status {escapeHtml(life)}">{escapeHtml(lifeText)}</span>
    </div>
    <div class="stat-row">
      <div class="stat"><div class="n">{c.level}</div><div class="l">level</div></div>
      <div class="stat"><div class="n sm">{escapeHtml(c.className)}</div><div class="l">class</div></div>
      <div class="stat"><div class="n sm">{escapeHtml(c.raceName)}</div><div class="l">race</div></div>
      <div class="stat"><div class="n sm">{escapeHtml(c.gold)}</div><div class="l">gold</div></div>
      <div class="stat"><div class="n sm">{escapeHtml(zoneText)}</div><div class="l">zone</div></div>
      <div class="stat"><div class="n sm">{renderPosCell(c)}</div><div class="l">pos</div></div>
    </div>
    <div class="murist-bars">
      <div class="xp-cell">{renderXpCell(c)}</div>
      <div class="vitals-cell">{renderVitalsCell(c)}</div>
    </div>"""

proc renderMuristEventRows*(events: seq[AddonEvent]): string =
  ## Event rows for Murist only (same columns as Advisor).
  let mine = filterEventsByName(events, AdminRequesterName)
  if mine.len == 0:
    return """<tr><td colspan="4" class="empty">No Murist addon events yet.</td></tr>"""
  result = renderEventRows(mine)

proc renderQuestRows*(quests: seq[QuestLogEntry], realmOffline = false): string =
  ## Quest log table body (active / complete / failed, unrewarded only).
  if realmOffline:
    return """<tr><td colspan="5" class="empty">Realm offline — start on <a href="/admin">Admin</a>.</td></tr>"""
  if quests.len == 0:
    return """<tr><td colspan="5" class="empty">No active quests.</td></tr>"""
  result = ""
  for q in quests:
    let statusCls =
      case q.status
      of "complete": "badge ok"
      of "failed": "badge bad"
      of "active": "badge accent"
      else: "badge"
    let progress = if q.progress.len > 0: escapeHtml(q.progress) else: "—"
    result.add(&"""
      <tr>
        <td class="lvl">{q.level}</td>
        <td class="name">{escapeHtml(q.title)}</td>
        <td class="meta">#{q.questId}</td>
        <td><span class="{statusCls}">{escapeHtml(q.status)}</span></td>
        <td class="payload">{progress}</td>
      </tr>
""")

proc renderMuristPage*(
    murist: Option[Character],
    events: seq[AddonEvent],
    quests: seq[QuestLogEntry] = @[],
    realmOffline = false,
    inventoryBody = ""
): string =
  ## Murist tab: human seat snapshot + quest log + bags + addon events.
  let statusBody = renderMuristStatus(murist, realmOffline = realmOffline)
  let questRows = renderQuestRows(quests, realmOffline = realmOffline)
  let eventRows = renderMuristEventRows(events)
  let invBody =
    if inventoryBody.len > 0: inventoryBody
    else: renderInventoryPanelBody(none(CharacterInventory), initTable[int, ItemInfo]())
  let questSummary =
    if realmOffline: ""
    else: &"""<span class="army-summary">{quests.len} open</span>"""
  let body = &"""
    <section class="panel">
      <div class="panel-head">
        <h2>Murist</h2>
        <div class="panel-actions">
          <span class="badge accent">human seat</span>
        </div>
      </div>
      <div class="panel-body"
           id="murist-status"
           hx-get="/murist/status"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{statusBody}
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Quests</h2>
        <div class="panel-actions">{questSummary}</div>
      </div>
      <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Lvl</th>
            <th>Title</th>
            <th>Id</th>
            <th>Status</th>
            <th>Progress</th>
          </tr>
        </thead>
        <tbody id="murist-quests"
               hx-get="/murist/quests"
               hx-trigger="every {PollSeconds}s"
               hx-swap="innerHTML settle:0s swap:0s">
{questRows}
        </tbody>
      </table>
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Bags</h2>
      </div>
      <div class="panel-body"
           id="murist-inventory"
           hx-get="/murist/inventory"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{invBody}
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Addon events</h2>
      </div>
      <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Time</th>
            <th>Character</th>
            <th>Kind</th>
            <th>Payload</th>
          </tr>
        </thead>
        <tbody id="murist-events"
               hx-get="/murist/events"
               hx-trigger="every {PollSeconds}s"
               hx-swap="innerHTML settle:0s swap:0s">
{eventRows}
        </tbody>
      </table>
      </div>
    </section>"""
  result = renderDashboard("Murist", "murist", body)

proc formatTraverseYards*(yards: float): string =
  ## Compact yard display for the Traverse panel.
  result = &"{yards:.1f}"

proc formatTraversePct*(pct: float): string =
  ## Course percent with one decimal place.
  result = &"{pct:.1f}"

proc renderTraverseClockBlock*(clock: TraverseClock): string =
  ## Elapsed / remaining stats + thin time bar (empty when unknown).
  if not clock.known:
    return ""
  let remText = formatTraverseClock(clock.remainingSec)
  let elText = formatTraverseClock(clock.elapsedSec)
  let limText = formatTraverseClock(clock.limitSec)
  let usedPct =
    if clock.limitSec <= 0: 0.0
    else: min(100.0, (clock.elapsedSec.float * 100.0) / clock.limitSec.float)
  let usedPctText = formatTraversePct(usedPct)
  let timeBadge =
    if clock.expired:
      """<span class="badge bad">time up</span>"""
    elif clock.remainingSec <= 5 * 60:
      """<span class="badge bad">≤5 min</span>"""
    elif clock.remainingSec <= 10 * 60:
      """<span class="badge accent">≤10 min</span>"""
    else:
      ""
  result = &"""
    <div class="stat-row">
      <div class="stat"><div class="n">{escapeHtml(remText)}</div><div class="l">remaining / {escapeHtml(limText)}</div></div>
      <div class="stat"><div class="n sm">{escapeHtml(elText)}</div><div class="l">elapsed</div></div>
      <div class="stat">{timeBadge}<div class="l">episode clock</div></div>
    </div>
    <div class="murist-bars" style="margin-bottom:0.75rem">
      <div class="xp-cell">
        <div class="xp" title="{escapeHtml(elText)} elapsed · {escapeHtml(remText)} left of {escapeHtml(limText)}">
          <div class="xp-bar"><div class="xp-fill" style="width:{usedPctText}%"></div></div>
          <div class="xp-meta">{escapeHtml(elText)} <span class="xp-muted">/ {escapeHtml(limText)} · {escapeHtml(remText)} left</span></div>
        </div>
      </div>
    </div>"""

proc renderTraverseStatus*(st: TraverseStatus): string =
  ## Traverse panel body: container + Northbound telemetry + score bar.
  if not st.containerFound:
    return """
    <p class="empty">Scenario not running — no *-traverse-coworld-game-1 container.</p>"""
  let containerPill =
    """<span class="pill"><span class="dot on"></span> running</span>"""
  let containerLabel = escapeHtml(st.containerName)
  let clockBlock = renderTraverseClockBlock(st.clock)
  if not st.characterFound:
    return &"""
    <div class="panel-actions" style="margin-bottom:0.75rem">
      {containerPill}
      <span class="server-container">{containerLabel}</span>
    </div>
{clockBlock}
    <p class="empty">Character {escapeHtml(TraverseCharacterName)} not found in scenario DB.</p>"""
  let ch = st.character
  let sc = st.score
  let onlinePill =
    if ch.online:
      """<span class="pill"><span class="dot on"></span> online</span>"""
    else:
      """<span class="pill"><span class="dot off"></span> offline</span>"""
  let validityBadge =
    if sc.valid:
      """<span class="badge ok">valid</span>"""
    else:
      &"""<span class="badge bad">invalid</span> <span class="meta">{escapeHtml(sc.invalidReason)}</span>"""
  let zoneText = if ch.zoneName.len > 0: ch.zoneName else: "—"
  let posText =
    if ch.hasPosition:
      &"{ch.posX:.1f}, {ch.posY:.1f}, {ch.posZ:.1f}"
    else:
      "—"
  let yardsText = formatTraverseYards(sc.northingYards)
  let pctText = formatTraversePct(sc.coursePct)
  let pctWidth = formatTraversePct(sc.coursePct)
  let livePill =
    if st.livePos:
      """<span class="badge accent">live</span>"""
    else:
      """<span class="badge">db save</span>"""
  result = &"""
    <div class="panel-actions" style="margin-bottom:0.75rem">
      {containerPill}
      <span class="server-container">{containerLabel}</span>
      {onlinePill}
      {livePill}
      {validityBadge}
    </div>
{clockBlock}
    <div class="stat-row">
      <div class="stat"><div class="n sm">{escapeHtml(ch.name)}</div><div class="l">character</div></div>
      <div class="stat"><div class="n">{ch.level}</div><div class="l">level</div></div>
      <div class="stat"><div class="n sm">{ch.mapId}</div><div class="l">map</div></div>
      <div class="stat"><div class="n sm">{escapeHtml(zoneText)}</div><div class="l">zone ({ch.zoneId})</div></div>
      <div class="stat"><div class="n sm pos">{escapeHtml(posText)}</div><div class="l">pos x / y / z</div></div>
    </div>
    <div class="stat-row">
      <div class="stat"><div class="n">{escapeHtml(yardsText)}</div><div class="l">northing yards</div></div>
      <div class="stat"><div class="n">{escapeHtml(pctText)}%</div><div class="l">course</div></div>
    </div>
    <div class="murist-bars">
      <div class="xp-cell">
        <div class="xp" title="{escapeHtml(yardsText)} yd · {escapeHtml(pctText)}% of {formatTraverseYards(TraverseCourseYards)} yd">
          <div class="xp-bar"><div class="xp-fill" style="width:{pctWidth}%"></div></div>
          <div class="xp-meta">{escapeHtml(yardsText)} <span class="xp-muted">yd · {escapeHtml(pctText)}%</span></div>
        </div>
      </div>
    </div>"""

proc renderTraverseOpsPanel*(ops: TraverseOpsStatus): string =
  ## Controls for detached local traverse bot (desert checkpoint run).
  let polPill =
    if ops.polRunning:
      """<span class="pill"><span class="dot on"></span> local bot running</span>"""
    else:
      """<span class="pill"><span class="dot off"></span> local bot idle</span>"""
  let polBtn =
    if ops.polRunning:
      """
      <button class="btn danger"
              hx-post="/traverse/pol/stop"
              hx-target="#traverse-ops"
              hx-swap="innerHTML">Stop local traverse</button>"""
    else:
      """
      <button class="btn primary"
              hx-post="/traverse/pol/start"
              hx-target="#traverse-ops"
              hx-swap="innerHTML">Start local traverse</button>"""
  var lastLine = ""
  if ops.lastDetail.len > 0:
    # Short status only — never dump policy/army_host log spam on the panel.
    let cls = if ops.lastOk: "admin-ok" else: "admin-err"
    let mark = if ops.lastOk: "ok" else: "FAIL"
    let detail = ops.lastDetail
    let short =
      if detail.len > 80: detail[0 .. 79] & "…"
      else: detail
    lastLine = &"""
      <div class="server-last {cls}" title="{escapeHtml(detail)}">
        last: {mark} — {escapeHtml(short)}
      </div>"""
  result = &"""
    <div class="panel-actions" style="margin-bottom:0.75rem;flex-wrap:wrap;gap:0.5rem">
      {polPill}
      {polBtn}
    </div>
{lastLine}"""

proc formatTraverseScoreCell*(row: TraverseReplayRow): string =
  ## Score column: northing yards when present.
  if not row.hasScore:
    return "—"
  result = formatTraverseYards(row.score)

proc renderTraverseReplayLinks*(row: TraverseReplayRow): string =
  ## Live + Observatory replay viewer (no raw S3 .replay link).
  var bits: seq[string] = @[]
  if row.liveUrl.len > 0:
    bits.add(&"""<a href="{escapeHtml(row.liveUrl)}" target="_blank" rel="noopener">Live</a>""")
  if row.observatoryUrl.len > 0:
    bits.add(&"""<a href="{escapeHtml(row.observatoryUrl)}" target="_blank" rel="noopener">Obs</a>""")
  if bits.len == 0:
    return """<span class="meta">—</span>"""
  result = bits.join(" · ")

proc renderTraverseReplayRows*(rows: seq[TraverseReplayRow]): string =
  ## Table body for hosted traverse episodes.
  if rows.len == 0:
    return """<tr><td colspan="6" class="empty">No episodes yet.</td></tr>"""
  result = ""
  for row in rows:
    let statusBadge =
      case row.status
      of "completed", "complete", "succeeded":
        """<span class="badge ok">done</span>"""
      of "running", "dispatched", "in_progress":
        """<span class="badge accent">live</span>"""
      of "failed", "error":
        """<span class="badge bad">fail</span>"""
      else:
        &"""<span class="badge">{escapeHtml(row.status)}</span>"""
    result.add(&"""
      <tr>
        <td><code>{escapeHtml(row.versionLabel)}</code></td>
        <td>{escapeHtml(formatTraverseScoreCell(row))}</td>
        <td>{statusBadge}</td>
        <td class="meta" style="white-space:nowrap">{escapeHtml(row.whenText)}</td>
        <td>{renderTraverseReplayLinks(row)}</td>
        <td class="meta" style="font-size:0.75rem">{escapeHtml(row.id)}</td>
      </tr>""")

proc renderTraverseReplaysPanel*(st: TraverseReplaysStatus): string =
  ## Hosted league episodes: version + score + replay links.
  let pullPill =
    if st.pullRunning:
      """<span class="pill"><span class="dot on"></span> refreshing</span>"""
    else:
      """<span class="pill"><span class="dot off"></span> cache</span>"""
  let summary =
    if st.note.len > 0: escapeHtml(st.note) else: "—"
  var lastLine = ""
  if st.lastDetail.len > 0:
    let cls = if st.lastOk: "admin-ok" else: "admin-err"
    let mark = if st.lastOk: "ok" else: "FAIL"
    lastLine = &"""
      <div class="server-last {cls}" title="{escapeHtml(st.lastDetail)}">
        last: {mark} — {escapeHtml(st.lastDetail)}
      </div>"""
  let rowsHtml = renderTraverseReplayRows(st.rows)
  result = &"""
    <div class="panel-actions" style="margin-bottom:0.75rem;flex-wrap:wrap;gap:0.5rem">
      {pullPill}
      <span class="meta">{summary}</span>
      <button class="btn primary"
              hx-post="/traverse/replays/refresh"
              hx-target="#traverse-replays"
              hx-swap="innerHTML">Refresh</button>
    </div>
{lastLine}
    <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Version</th>
            <th>Score</th>
            <th>Status</th>
            <th>When</th>
            <th>Links</th>
            <th>Episode</th>
          </tr>
        </thead>
        <tbody>
{rowsHtml}
        </tbody>
      </table>
    </div>"""
proc renderTraversePage*(
    st: TraverseStatus; ops: TraverseOpsStatus; replays: TraverseReplaysStatus
): string =
  ## Traverse tab: league telemetry + PoL / observer + hosted replays.
  let statusBody = renderTraverseStatus(st)
  let opsBody = renderTraverseOpsPanel(ops)
  let replaysBody = renderTraverseReplaysPanel(replays)
  let body = &"""
    <section class="panel">
      <div class="panel-head">
        <h2>Controls</h2>
        <div class="panel-actions">
          <span class="badge accent">ops</span>
        </div>
      </div>
      <div class="panel-body"
           id="traverse-ops"
           hx-get="/traverse/ops"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{opsBody}
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Kalimdor Traverse</h2>
        <div class="panel-actions">
          <span class="badge accent">telemetry</span>
        </div>
      </div>
      <div class="panel-body"
           id="traverse-status"
           hx-get="/traverse/status"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{statusBody}
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Hosted replays</h2>
        <div class="panel-actions">
          <span class="badge accent">league</span>
        </div>
      </div>
      <div class="panel-body"
           id="traverse-replays"
           hx-get="/traverse/replays"
           hx-trigger="every {TraverseReplaysPollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{replaysBody}
      </div>
    </section>"""
  result = renderDashboard("Traverse", "traverse", body)

proc renderAdvisorPage*(events: seq[AddonEvent]): string =
  ## Advisor tab: addon event tail + reload control.
  let eventRows = renderEventRows(events)
  let body = &"""
    <section class="panel">
      <div class="panel-head">
        <h2>Addon events</h2>
        <div class="panel-actions">
          <button class="btn primary"
                  hx-post="/reload"
                  hx-target="#reload-result"
                  hx-swap="innerHTML">Reload addon</button>
          <span id="reload-result" class="meta"></span>
        </div>
      </div>
      <div class="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Time</th>
            <th>Character</th>
            <th>Kind</th>
            <th>Payload</th>
          </tr>
        </thead>
        <tbody id="events"
               hx-get="/events"
               hx-trigger="every {PollSeconds}s"
               hx-swap="innerHTML settle:0s swap:0s">
{eventRows}
        </tbody>
      </table>
      </div>
    </section>"""
  result = renderDashboard("Advisor", "advisor", body)

proc renderAdminResult*(r: AdminActionResult): string =
  ## HTML fragment for an admin action outcome (htmx target).
  let cls = if r.ok: "admin-ok" else: "admin-err"
  var lines = newSeq[string]()
  for s in r.steps:
    let mark = if s.ok: "ok" else: "FAIL"
    lines.add(&"[{mark}] {s.command} → {s.detail}")
  let body = escapeHtml(lines.join("\n"))
  result = &"""
    <div class="{cls}"><strong>{escapeHtml(r.summary)}</strong></div>
    <div class="admin-steps">{body}</div>
"""

proc renderAdminPage*(server: ServerStatus): string =
  ## Admin tab: realm lifecycle + ops buttons.
  let serverPanel = renderServerPanel(server)
  let body = &"""
    <section class="panel">
      <div class="panel-head">
        <h2>Realm</h2>
      </div>
      <div class="panel-body"
           id="server-panel"
           hx-get="/server"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML settle:0s swap:0s">
{serverPanel}
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Actions</h2>
      </div>
      <div class="panel-body">
        <div class="admin-actions">
          <button class="btn danger"
                  hx-post="/admin/respawn-shadow-army"
                  hx-target="#admin-result"
                  hx-swap="innerHTML"
                  hx-confirm="Respawn Shadowfel, Igris, Tusk, Beru at Deathknell?">
            Respawn shadow army
          </button>
          <button class="btn danger"
                  hx-post="/admin/tele-party-to-murist"
                  hx-target="#admin-result"
                  hx-swap="innerHTML"
                  hx-confirm="Teleport Shadowfel, Igris, Tusk, Beru to Murist's position?">
            Teleport party to Murist
          </button>
        </div>
        <div id="admin-result" style="margin-top:1rem;"></div>
      </div>
    </section>"""
  result = renderDashboard("Admin", "admin", body)

proc htmlHeaders(): mummyheaders.HttpHeaders =
  ## mummy/webby headers (not std/httpclient's HttpHeaders).
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = "text/html; charset=utf-8"

proc jsonHeaders(): mummyheaders.HttpHeaders =
  ## mummy/webby headers (not std/httpclient's HttpHeaders).
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = "application/json; charset=utf-8"

proc armyPageHandler(request: Request) {.gcsafe.} =
  ## GET / and GET /army — Army tab (roster only).
  ## Realm down: roster degrades to an offline note. Foundation seats hidden.
  try:
    var characters: seq[Character] = @[]
    var status: ServerStatus
    var rosterOffline = false
    {.gcsafe.}:
      status = serverStatus()
      if status.running:
        try:
          characters = filterCharacters(listCharacters())
        except CatchableError:
          # Container up but DB not answering yet (mid-boot): offline view.
          rosterOffline = true
      else:
        rosterOffline = true
    var seats: seq[SeatWatch] = @[]
    {.gcsafe.}:
      seats = seatWatchStatus()
    request.respond(200, htmlHeaders(),
      renderArmyPage(characters, seats, rosterOffline = rosterOffline))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"<!DOCTYPE html><html><body><h1>Army error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc advisorPageHandler(request: Request) {.gcsafe.} =
  ## GET /advisor — Advisor tab (addon event tail + reload).
  try:
    var events: seq[AddonEvent]
    {.gcsafe.}:
      events = recentEvents(limit = 30)
    request.respond(200, htmlHeaders(), renderAdvisorPage(events))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"<!DOCTYPE html><html><body><h1>Advisor error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc muristPageHandler(request: Request) {.gcsafe.} =
  ## GET /murist — human seat tab (status + quests + Murist addon events).
  try:
    var murist = none(Character)
    var events: seq[AddonEvent] = @[]
    var quests: seq[QuestLogEntry] = @[]
    var realmOffline = false
    {.gcsafe.}:
      let status = serverStatus()
      if status.running:
        try:
          murist = findCharacterByName(listCharacters(), AdminRequesterName)
          quests = listCharacterQuests(AdminRequesterName)
        except CatchableError:
          realmOffline = true
      else:
        realmOffline = true
      events = recentEvents(limit = 40)
    var invBody = ""
    {.gcsafe.}:
      invBody = inventoryPanelFor(AdminRequesterName)
    request.respond(200, htmlHeaders(),
      renderMuristPage(murist, events, quests, realmOffline = realmOffline,
                       inventoryBody = invBody))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"<!DOCTYPE html><html><body><h1>Murist error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc muristStatusHandler(request: Request) {.gcsafe.} =
  ## GET /murist/status — htmx fragment for Murist metrics.
  try:
    var murist = none(Character)
    var realmOffline = false
    {.gcsafe.}:
      let status = serverStatus()
      if status.running:
        try:
          murist = findCharacterByName(listCharacters(), AdminRequesterName)
        except CatchableError:
          realmOffline = true
      else:
        realmOffline = true
    request.respond(200, htmlHeaders(),
      renderMuristStatus(murist, realmOffline = realmOffline))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<p class="empty">error: {escapeHtml(e.msg)}</p>""")

proc muristQuestsHandler(request: Request) {.gcsafe.} =
  ## GET /murist/quests — htmx fragment: Murist active quest log rows.
  try:
    var quests: seq[QuestLogEntry] = @[]
    var realmOffline = false
    {.gcsafe.}:
      let status = serverStatus()
      if status.running:
        try:
          quests = listCharacterQuests(AdminRequesterName)
        except CatchableError:
          realmOffline = true
      else:
        realmOffline = true
    request.respond(200, htmlHeaders(),
      renderQuestRows(quests, realmOffline = realmOffline))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<tr><td colspan="5" class="empty">error: {escapeHtml(e.msg)}</td></tr>""")

proc muristEventsHandler(request: Request) {.gcsafe.} =
  ## GET /murist/events — htmx fragment: Murist-only addon event rows.
  try:
    var events: seq[AddonEvent]
    {.gcsafe.}:
      events = recentEvents(limit = 40)
    request.respond(200, htmlHeaders(), renderMuristEventRows(events))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<tr><td colspan="4" class="empty">error: {escapeHtml(e.msg)}</td></tr>""")

proc muristInventoryHandler(request: Request) {.gcsafe.} =
  ## GET /murist/inventory — htmx fragment: Murist's latest-known bags.
  try:
    var body = ""
    {.gcsafe.}:
      body = inventoryPanelFor(AdminRequesterName)
    request.respond(200, htmlHeaders(), body)
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<p class="empty">error: {escapeHtml(e.msg)}</p>""")

proc seatsPartialHandler(request: Request) {.gcsafe.} =
  ## GET /seats — htmx fragment: seat babysitter panel body.
  try:
    var seats: seq[SeatWatch]
    {.gcsafe.}:
      seats = seatWatchStatus()
    request.respond(200, htmlHeaders(), renderSeatWatchPanelBody(seats))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<p class="empty">error: {escapeHtml(e.msg)}</p>""")

proc traversePageHandler(request: Request) {.gcsafe.} =
  ## GET /traverse — Traverse tab (telemetry + PoL / observer + replays).
  try:
    var st: TraverseStatus
    var ops: TraverseOpsStatus
    var replays: TraverseReplaysStatus
    {.gcsafe.}:
      st = traverseStatus()
      ops = traverseOpsStatus()
      replays = traverseReplays()
    request.respond(200, htmlHeaders(), renderTraversePage(st, ops, replays))
  except Exception as e:
    # Never surface a hard failure for a missing scenario — soft empty page.
    try:
      let soft = TraverseStatus(
        containerFound: false,
        score: scoreTraverse(false, 0, 0, false, 0.0)
      )
      let ops = TraverseOpsStatus(
        polLog: TraversePolLogRel, watchLog: TraverseWatchLogRel)
      var replays: TraverseReplaysStatus
      {.gcsafe.}:
        replays = traverseReplays()
      request.respond(200, htmlHeaders(), renderTraversePage(soft, ops, replays))
    except Exception:
      request.respond(500, htmlHeaders(),
        &"<!DOCTYPE html><html><body><h1>Traverse error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc traverseStatusHandler(request: Request) {.gcsafe.} =
  ## GET /traverse/status — htmx fragment for Traverse metrics.
  try:
    var st: TraverseStatus
    {.gcsafe.}:
      st = traverseStatus()
    request.respond(200, htmlHeaders(), renderTraverseStatus(st))
  except Exception:
    request.respond(200, htmlHeaders(),
      """<p class="empty">Scenario not running — no *-traverse-coworld-game-1 container.</p>""")

proc traverseOpsHandler(request: Request) {.gcsafe.} =
  ## GET /traverse/ops — htmx fragment for PoL / observer controls.
  try:
    var ops: TraverseOpsStatus
    {.gcsafe.}:
      ops = traverseOpsStatus()
    request.respond(200, htmlHeaders(), renderTraverseOpsPanel(ops))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">ops error: {escapeHtml(e.msg)}</span>""")

proc traversePolStartHandler(request: Request) {.gcsafe.} =
  ## POST /traverse/pol/start — detached local desert-checkpoint traverse run.
  try:
    var ops: TraverseOpsStatus
    {.gcsafe.}:
      ops = startTraversePol()
    request.respond(200, htmlHeaders(), renderTraverseOpsPanel(ops))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">start local traverse failed: {escapeHtml(e.msg)}</span>""")

proc traversePolStopHandler(request: Request) {.gcsafe.} =
  ## POST /traverse/pol/stop — kill bot tree and tear down traverse container.
  try:
    var ops: TraverseOpsStatus
    {.gcsafe.}:
      ops = stopTraversePol(cleanupBackend = true)
    request.respond(200, htmlHeaders(), renderTraverseOpsPanel(ops))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">stop local traverse failed: {escapeHtml(e.msg)}</span>""")

proc traverseWatchStartHandler(request: Request) {.gcsafe.} =
  ## POST /traverse/watch/start — detached watch_bots observer.
  try:
    var ops: TraverseOpsStatus
    {.gcsafe.}:
      ops = startTraverseWatch()
    request.respond(200, htmlHeaders(), renderTraverseOpsPanel(ops))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">start observer failed: {escapeHtml(e.msg)}</span>""")

proc traverseWatchStopHandler(request: Request) {.gcsafe.} =
  ## POST /traverse/watch/stop — kill watch_bots.
  try:
    var ops: TraverseOpsStatus
    {.gcsafe.}:
      ops = stopTraverseWatch()
    request.respond(200, htmlHeaders(), renderTraverseOpsPanel(ops))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">stop observer failed: {escapeHtml(e.msg)}</span>""")

proc traverseReplaysHandler(request: Request) {.gcsafe.} =
  ## GET /traverse/replays — htmx fragment for hosted episode table.
  try:
    var st: TraverseReplaysStatus
    {.gcsafe.}:
      st = traverseReplays()
    request.respond(200, htmlHeaders(), renderTraverseReplaysPanel(st))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<p class="empty">replays error: {escapeHtml(e.msg)}</p>""")

proc traverseReplaysRefreshHandler(request: Request) {.gcsafe.} =
  ## POST /traverse/replays/refresh — pull hosted episodes into local cache.
  try:
    var st: TraverseReplaysStatus
    {.gcsafe.}:
      st = startTraverseFieldPull()
    request.respond(200, htmlHeaders(), renderTraverseReplaysPanel(st))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<p class="empty">refresh failed: {escapeHtml(e.msg)}</p>""")

proc rosterPartialHandler(request: Request) {.gcsafe.} =
  ## GET /roster — htmx fragment (table rows only). Foundation seats hidden.
  ## Realm down / DB unreachable → friendly offline row, not a red error.
  try:
    var characters: seq[Character]
    {.gcsafe.}:
      characters = filterCharacters(listCharacters())
    request.respond(200, htmlHeaders(), renderRosterRows(characters))
  except Exception as e:
    var offline = false
    {.gcsafe.}:
      offline = not serverStatus().running
    if offline:
      request.respond(200, htmlHeaders(), renderRosterOfflineRow())
    else:
      request.respond(500, htmlHeaders(),
        &"""<tr><td colspan="11" class="empty">error: {escapeHtml(e.msg)}</td></tr>""")

proc serverPartialHandler(request: Request) {.gcsafe.} =
  ## GET /server — htmx fragment: Server panel content (status + buttons).
  try:
    var status: ServerStatus
    {.gcsafe.}:
      status = serverStatus()
    request.respond(200, htmlHeaders(), renderServerPanel(status))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">server status error: {escapeHtml(e.msg)}</span>""")

proc serverStartHandler(request: Request) {.gcsafe.} =
  ## POST /server/start — queue operator `up`; returns the refreshed panel.
  try:
    var status: ServerStatus
    {.gcsafe.}:
      status = startServer()
    request.respond(200, htmlHeaders(), renderServerPanel(status))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">start failed: {escapeHtml(e.msg)}</span>""")

proc serverStopHandler(request: Request) {.gcsafe.} =
  ## POST /server/stop — queue operator `down`; returns the refreshed panel.
  try:
    var status: ServerStatus
    {.gcsafe.}:
      status = stopServer()
    request.respond(200, htmlHeaders(), renderServerPanel(status))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="admin-err">stop failed: {escapeHtml(e.msg)}</span>""")

proc respondRosterRows(request: Request) {.gcsafe.} =
  ## Shared bot-handler response: fresh roster rows (offline row on failure).
  try:
    var characters: seq[Character]
    {.gcsafe.}:
      characters = filterCharacters(listCharacters())
    request.respond(200, htmlHeaders(), renderRosterRows(characters))
  except CatchableError:
    request.respond(200, htmlHeaders(), renderRosterOfflineRow())

proc botStartHandler(request: Request) {.gcsafe.} =
  ## POST /bots/start?name=<seat> — launch that seat, return roster rows.
  let name = request.queryParams["name"]
  {.gcsafe.}:
    discard startBotSeat(name)
  respondRosterRows(request)

proc botStopHandler(request: Request) {.gcsafe.} =
  ## POST /bots/stop?name=<seat> — stop that seat, return roster rows.
  let name = request.queryParams["name"]
  {.gcsafe.}:
    discard stopBotSeat(name)
  respondRosterRows(request)

proc eventsPartialHandler(request: Request) {.gcsafe.} =
  ## GET /events — htmx fragment (addon event rows).
  try:
    var events: seq[AddonEvent]
    {.gcsafe.}:
      events = recentEvents(limit = 30)
    request.respond(200, htmlHeaders(), renderEventRows(events))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<tr><td colspan="4" class="empty">error: {escapeHtml(e.msg)}</td></tr>""")

proc reloadHandler(request: Request) {.gcsafe.} =
  ## POST /reload — SOAP reload loop; returns a small HTML outcome span.
  try:
    var node: JsonNode
    {.gcsafe.}:
      node = reloadAddon()
    request.respond(200, htmlHeaders(), renderReloadResult(node))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<span class="reload-timeout">error: {escapeHtml(e.msg)}</span>""")

proc adminPageHandler(request: Request) {.gcsafe.} =
  ## GET /admin — Admin tab (realm lifecycle + ops escape hatches).
  try:
    var status: ServerStatus
    {.gcsafe.}:
      status = serverStatus()
    request.respond(200, htmlHeaders(), renderAdminPage(status))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"<!DOCTYPE html><html><body><h1>Admin error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc respawnShadowArmyHandler(request: Request) {.gcsafe.} =
  ## POST /admin/respawn-shadow-army — GM revive + tele the bot seats.
  try:
    var r: AdminActionResult
    {.gcsafe.}:
      r = respawnShadowArmy()
    let code = if r.ok: 200 else: 207
    request.respond(code, htmlHeaders(), renderAdminResult(r))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<div class="admin-err">error: {escapeHtml(e.msg)}</div>""")

proc telePartyToMuristHandler(request: Request) {.gcsafe.} =
  ## POST /admin/tele-party-to-murist — pin game_tele to Murist + tele bot seats.
  try:
    var r: AdminActionResult
    {.gcsafe.}:
      r = telePartyToMurist()
    let code = if r.ok: 200 else: 207
    request.respond(code, htmlHeaders(), renderAdminResult(r))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<div class="admin-err">error: {escapeHtml(e.msg)}</div>""")

proc healthHandler(request: Request) {.gcsafe.} =
  ## GET /healthz — process liveness (does not hit the realm DB).
  request.respond(200, jsonHeaders(), """{"ok":true,"service":"the-system"}""")

proc mcpHandler(request: Request) {.gcsafe.} =
  ## POST /mcp — MCP JSON-RPC (MCPort core over the shared mummy router).
  if request.httpMethod != "POST":
    request.respond(405, body = "Method not allowed — use POST for JSON-RPC")
    return

  var contentType = ""
  for (key, value) in request.headers:
    if key.toLowerAscii() == "content-type":
      contentType = value
      break
  let ct = contentType.toLowerAscii().strip()
  if ct.len == 0 or not ct.startsWith("application/json"):
    request.respond(400, body = "Content-Type must start with application/json")
    return

  try:
    var mcpResult: McpResult
    {.gcsafe.}:
      mcpResult = gMcpServer.handleRequest(request.body)
    if mcpResult.isError:
      request.respond(200, jsonHeaders(), mcpResult.error.toJson())
    elif mcpResult.response.result == %*{}:
      request.respond(204)
    else:
      request.respond(200, jsonHeaders(), mcpResult.response.toJson())
  except Exception as e:
    let err = createError(0, -32603, "Internal error: " & e.msg)
    request.respond(500, jsonHeaders(), err.toJson())

proc serverInfoHandler(request: Request) {.gcsafe.} =
  ## GET /server-info — lightweight MCP metadata for debugging.
  var info: JsonNode
  {.gcsafe.}:
    info = %*{
      "name": gMcpServer.serverInfo.name,
      "version": gMcpServer.serverInfo.version,
      "endpoints": {
        "army": "/army",
        "murist": "/murist",
        "advisor": "/advisor",
        "traverse": "/traverse",
        "admin": "/admin",
        "dashboard": "/",
        "roster_partial": "/roster",
        "murist_status": "/murist/status",
        "murist_quests": "/murist/quests",
        "murist_events": "/murist/events",
        "traverse_status": "/traverse/status",
        "traverse_ops": "/traverse/ops",
        "traverse_pol_start": "/traverse/pol/start",
        "traverse_pol_stop": "/traverse/pol/stop",
        "traverse_watch_start": "/traverse/watch/start",
        "traverse_watch_stop": "/traverse/watch/stop",
        "events_partial": "/events",
        "server_partial": "/server",
        "server_start": "/server/start",
        "server_stop": "/server/stop",
        "bot_start": "/bots/start?name=<seat>",
        "bot_stop": "/bots/stop?name=<seat>",
        "reload": "/reload",
        "respawn_shadow_army": "/admin/respawn-shadow-army",
        "tele_party_to_murist": "/admin/tele-party-to-murist",
        "jsonrpc": "/mcp",
        "healthz": "/healthz"
      },
      "tools": [
        "list_characters", "addon_events", "reload_addon", "send_announce",
        "respawn_shadow_army", "tele_party_to_murist",
        "server_status", "start_server", "stop_server",
        "start_bot", "stop_bot"
      ],
      "write_scope": "SOAP announce + admin revive/tele/tele-to-murist for fixed bot seats + realm lifecycle up/down + bot seat start/stop (local ops)"
    }
  request.respond(200, jsonHeaders(), $info)

proc registerMcpTools(server: McpServer) =
  ## Register MCP tools. Handlers call the same dispatch procs as the dashboard.
  let listTool = McpTool(
    name: "list_characters",
    description: "List characters on the local VMaNGOS realm (name, level, xp, class, race, gold, online, life/ghost, zone). Read-only. By default hides foundation seats (Bot*, Nightsun, Cowcam); set include_foundation=true for full realm roster.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "include_foundation": {
          "type": "boolean",
          "description": "Include Botmage/Botpriest/… and Nightsun/Cowcam (default false)"
        }
      },
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc listCharactersHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same roster as the dashboard; returned as text + structuredContent.
    var includeFoundation = false
    if arguments != nil and arguments.kind == JObject and arguments.hasKey("include_foundation"):
      includeFoundation = arguments["include_foundation"].getBool(false)
    var characters: seq[Character]
    {.gcsafe.}:
      characters = filterCharacters(listCharacters(), includeFoundation = includeFoundation)
    # structuredContent must be a JObject per MCP/MCPort (not a bare array).
    let payload = %*{
      "characters": charactersToJson(characters),
      "include_foundation": includeFoundation
    }
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let eventsTool = McpTool(
    name: "addon_events",
    description: "Recent addon telemetry events from Chat.log (newest first). Optional limit and kind filter.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "limit": {
          "type": "integer",
          "description": "Max events to return (default 50)"
        },
        "kind": {
          "type": "string",
          "description": "Optional kind filter (e.g. loaded, err, legacy)"
        }
      },
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc addonEventsHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same ring buffer as the dashboard Addon events panel.
    var limit = 50
    var kind = ""
    if arguments != nil and arguments.kind == JObject:
      if arguments.hasKey("limit"):
        limit = arguments["limit"].getInt(50)
      if arguments.hasKey("kind"):
        kind = arguments["kind"].getStr("")
    var events: seq[AddonEvent]
    {.gcsafe.}:
      events = recentEvents(limit = limit, kind = kind)
    let payload = %*{"events": eventsToJson(events)}
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let reloadTool = McpTool(
    name: "reload_addon",
    description: "Broadcast <SYS> reload via SOAP announce, then wait up to 6s for a fresh <SA> loaded event in Chat.log.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc reloadAddonHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same reload loop as the dashboard Reload addon button.
    discard arguments
    var node: JsonNode
    {.gcsafe.}:
      node = reloadAddon()
    result = ToolResult(
      content: @[textContent($node)],
      structuredContent: some(node),
      isError: false
    )

  let announceTool = McpTool(
    name: "send_announce",
    description: "Broadcast a system message to all players on the local realm (the human sees it in their chat frame).",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "text": {
          "type": "string",
          "description": "Message text (sent as GM announce; no leading dot)"
        }
      },
      "required": ["text"],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc sendAnnounceHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## SOAP announce; same path as announceInGame used by reload.
    let text = if arguments != nil: arguments{"text"}.getStr("") else: ""
    if text.len == 0:
      let errPayload = %*{"ok": false, "error": "text is required"}
      return ToolResult(
        content: @[textContent($errPayload)],
        structuredContent: some(errPayload),
        isError: true
      )
    var body: string
    {.gcsafe.}:
      body = announceInGame(text)
    let payload = %*{"ok": true, "result": body}
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let respawnTool = McpTool(
    name: "respawn_shadow_army",
    description: "ADMIN ops escape hatch (not fair-play): SOAP revive + tele name … Deathknell + repairitems for Shadowfel, Igris, Tusk, Beru. Use when corpse runs stall. Does not restart clients.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc respawnShadowArmyMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the Admin tab Respawn button.
    discard arguments
    var r: AdminActionResult
    {.gcsafe.}:
      r = respawnShadowArmy()
    let payload = adminActionToJson(r)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: not r.ok
    )

  let telePartyTool = McpTool(
    name: "tele_party_to_murist",
    description: "ADMIN ops escape hatch (not fair-play): upsert game_tele SA_MURIST_MEET at Murist's DB position, reload game_tele, tele name Shadowfel/Igris/Tusk/Beru there.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc telePartyToMuristMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the Admin tab Teleport party to Murist button.
    discard arguments
    var r: AdminActionResult
    {.gcsafe.}:
      r = telePartyToMurist()
    let payload = adminActionToJson(r)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: not r.ok
    )

  let serverStatusTool = McpTool(
    name: "server_status",
    description: "Realm lifecycle state: coworld-game container up/down, any start/stop op in progress, and the last op's outcome. Read-only.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc serverStatusMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the dashboard Server panel.
    discard arguments
    var s: ServerStatus
    {.gcsafe.}:
      s = serverStatus()
    let payload = serverStatusToJson(s)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let startServerTool = McpTool(
    name: "start_server",
    description: "Queue realm start (upstream operator `up` — compose up + db healthcheck; can take minutes). Returns immediately with status; poll server_status for completion.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc startServerMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the dashboard Start server button.
    discard arguments
    var s: ServerStatus
    {.gcsafe.}:
      s = startServer()
    let payload = serverStatusToJson(s)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let stopServerTool = McpTool(
    name: "stop_server",
    description: "Queue realm stop (upstream operator `down` — compose stop/rm; characters and accounts persist). Returns immediately with status; poll server_status for completion.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc stopServerMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the dashboard Stop server button.
    discard arguments
    var s: ServerStatus
    {.gcsafe.}:
      s = stopServer()
    let payload = serverStatusToJson(s)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let botNameSchema = %*{
    "type": "object",
    "properties": {
      "name": {
        "type": "string",
        "description": "Bot seat name: Shadowfel, Igris, Tusk, or Beru"
      }
    },
    "required": ["name"],
    "additionalProperties": false,
    "$schema": "http://json-schema.org/draft-07/schema#"
  }

  let startBotTool = McpTool(
    name: "start_bot",
    description: "Launch one embedded Lua home bot. The Make lifecycle detaches it; list_characters control_up becomes true when its PID is alive and status heartbeat is fresh.",
    inputSchema: botNameSchema
  )

  proc startBotMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the roster Start button.
    let name = if arguments != nil: arguments{"name"}.getStr("") else: ""
    var payload: JsonNode
    {.gcsafe.}:
      payload = startBotSeat(name)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: not payload{"ok"}.getBool(false)
    )

  let stopBotTool = McpTool(
    name: "stop_bot",
    description: "Stop one embedded Lua home bot through its Make lifecycle target; the client receives TERM and logs out.",
    inputSchema: botNameSchema
  )

  proc stopBotMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the roster Stop button.
    let name = if arguments != nil: arguments{"name"}.getStr("") else: ""
    var payload: JsonNode
    {.gcsafe.}:
      payload = stopBotSeat(name)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: not payload{"ok"}.getBool(false)
    )

  let seatWatchTool = McpTool(
    name: "seat_watch",
    description: "Seat babysitter view: per home seat liveness (running/starting/stopped/wedged), status heartbeat age, auto-restarts in the last hour, persistent alert flag, and the last wedge evidence file.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc seatWatchMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the Army tab Seat watch panel.
    discard arguments
    var seats: seq[SeatWatch]
    {.gcsafe.}:
      seats = seatWatchStatus()
    let payload = %*{
      "seats": seatWatchToJson(seats),
      "stale_threshold_sec": seatWedgeStaleSec(),
      "restart_budget_per_hour": SeatRestartBudget,
      "enabled": seatBabysitterEnabled()
    }
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let inventoryTool = McpTool(
    name: "character_inventory",
    description: "Latest-known bags for one character, assembled from `<SA> inv` chat-bus lines (item id, count, world-DB name / vendor sell price) plus the age of the data. Empty until that character has emitted inventory.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Character name (default Murist)"
        }
      },
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc characterInventoryMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same dispatch as the Murist tab Bags panel.
    var name = AdminRequesterName
    if arguments != nil and arguments{"name"}.getStr("").len > 0:
      name = arguments{"name"}.getStr("")
    var payload: JsonNode
    {.gcsafe.}:
      let inv = characterInventory(name)
      if inv.isNone:
        payload = %*{
          "name": name,
          "items": [],
          "item_count": 0,
          "age_sec": -1.0,
          "lines": 0,
          "known": false,
          "reported": inventoryCharacters()
        }
      else:
        var ids: seq[int] = @[]
        for item in liveInventoryItems(inv.get):
          ids.add(item.itemId)
        payload = inventoryToJson(inv.get, lookupItemInfo(ids))
        payload["known"] = %true
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: false
    )

  let requestInventoryTool = McpTool(
    name: "request_inventory",
    description: "Announce `<SYS> inv?` so logged-in clients re-emit a full `<SA> inv` snapshot over the chat bus. Push is the normal path (login + BAG_UPDATE deltas); the addon suppresses an identical repeat for 30s, so unchanged bags may answer with silence.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Character whose inventory age is reported back (default Murist)"
        }
      },
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc requestInventoryMcpHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same announce path as reload_addon, different verb.
    var name = AdminRequesterName
    if arguments != nil and arguments{"name"}.getStr("").len > 0:
      name = arguments{"name"}.getStr("")
    var payload: JsonNode
    {.gcsafe.}:
      payload = requestInventorySnapshot(name)
    result = ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: not payload{"ok"}.getBool(false)
    )

  # registerRichTool: plain registerTool only surfaces getStr() on JsonNode
  # (arrays become empty text). Monky uses the rich path for the same reason.
  server.registerRichTool(listTool, listCharactersHandler)
  server.registerRichTool(eventsTool, addonEventsHandler)
  server.registerRichTool(reloadTool, reloadAddonHandler)
  server.registerRichTool(announceTool, sendAnnounceHandler)
  server.registerRichTool(respawnTool, respawnShadowArmyMcpHandler)
  server.registerRichTool(telePartyTool, telePartyToMuristMcpHandler)
  server.registerRichTool(serverStatusTool, serverStatusMcpHandler)
  server.registerRichTool(startServerTool, startServerMcpHandler)
  server.registerRichTool(stopServerTool, stopServerMcpHandler)
  server.registerRichTool(seatWatchTool, seatWatchMcpHandler)
  server.registerRichTool(inventoryTool, characterInventoryMcpHandler)
  server.registerRichTool(requestInventoryTool, requestInventoryMcpHandler)
  server.registerRichTool(startBotTool, startBotMcpHandler)
  server.registerRichTool(stopBotTool, stopBotMcpHandler)

proc httpPort*(): int =
  ## Listen port. SYSTEM_HTTP_PORT exists so an isolated instance (fake
  ## SYSTEM_ARMY_DIR / SYSTEM_CHAT_LOG) can be exercised beside the live
  ## dashboard without taking 7777 or touching real seats.
  let env = getEnv("SYSTEM_HTTP_PORT", "").strip()
  if env.len > 0:
    let p = parseIntOr(env, 0)
    if p > 0 and p < 65536:
      return p
  result = HttpPort

proc main() =
  ## Boot The System: Chat.log tailer + one mummy server (dashboard + MCP).
  gMcpServer = newMcpServer(ServerName, Version)
  registerMcpTools(gMcpServer)
  startChatLogTailer()
  startAdminWorker()
  startServerOpWorker()
  startSeatWatch()

  var router: Router
  router.get("/", armyPageHandler)
  router.get("/army", armyPageHandler)
  router.get("/murist", muristPageHandler)
  router.get("/murist/status", muristStatusHandler)
  router.get("/murist/quests", muristQuestsHandler)
  router.get("/murist/events", muristEventsHandler)
  router.get("/murist/inventory", muristInventoryHandler)
  router.get("/seats", seatsPartialHandler)
  router.get("/advisor", advisorPageHandler)
  router.get("/traverse", traversePageHandler)
  router.get("/traverse/status", traverseStatusHandler)
  router.get("/traverse/ops", traverseOpsHandler)
  router.get("/traverse/replays", traverseReplaysHandler)
  router.post("/traverse/pol/start", traversePolStartHandler)
  router.post("/traverse/pol/stop", traversePolStopHandler)
  router.post("/traverse/watch/start", traverseWatchStartHandler)
  router.post("/traverse/watch/stop", traverseWatchStopHandler)
  router.post("/traverse/replays/refresh", traverseReplaysRefreshHandler)
  router.get("/admin", adminPageHandler)
  router.get("/roster", rosterPartialHandler)
  router.get("/events", eventsPartialHandler)
  router.get("/server", serverPartialHandler)
  router.post("/server/start", serverStartHandler)
  router.post("/server/stop", serverStopHandler)
  router.post("/bots/start", botStartHandler)
  router.post("/bots/stop", botStopHandler)
  router.post("/reload", reloadHandler)
  router.post("/admin/respawn-shadow-army", respawnShadowArmyHandler)
  router.post("/admin/tele-party-to-murist", telePartyToMuristHandler)
  router.get("/healthz", healthHandler)
  router.get("/server-info", serverInfoHandler)
  router.post("/mcp", mcpHandler)

  let port = httpPort()
  let server = newServer(router)
  echo &"{ServerName} v{Version} listening on http://127.0.0.1:{port}"
  echo &"  Army:        GET  http://127.0.0.1:{port}/army"
  echo &"  Murist:      GET  http://127.0.0.1:{port}/murist"
  echo &"  Advisor:     GET  http://127.0.0.1:{port}/advisor"
  echo &"  Traverse:    GET  http://127.0.0.1:{port}/traverse"
  echo &"  Traverse ops POST /traverse/pol/start|/stop  /traverse/watch/start|/stop"
  echo &"  Admin:       GET  http://127.0.0.1:{port}/admin"
  echo &"  Events:      GET  http://127.0.0.1:{port}/events"
  echo &"  Server:      GET  http://127.0.0.1:{port}/server (POST /server/start /server/stop)"
  echo &"  Reload:      POST http://127.0.0.1:{port}/reload"
  echo &"  Respawn:     POST http://127.0.0.1:{port}/admin/respawn-shadow-army"
  echo &"  Tele party:  POST http://127.0.0.1:{port}/admin/tele-party-to-murist"
  echo &"  MCP:         POST http://127.0.0.1:{port}/mcp"
  echo &"  container:   {gameContainer()} (SYSTEM_MYSQL_CONTAINER to override)"
  echo &"  traverse:    {resolveTraverseContainer()} (SYSTEM_TRAVERSE_CONTAINER to override)"
  echo &"  Chat.log:    {chatLogPath()} (SYSTEM_CHAT_LOG to override)"
  echo &"  upstream:    {upstreamDir()} (SYSTEM_UPSTREAM_DIR to override)"
  echo &"  seat watch:  babysitter {(if seatBabysitterEnabled(): \"on\" else: \"observe-only\")}" &
    &" · wedge > {seatWedgeStaleSec().int}s · {SeatRestartBudget} restarts/h/seat"
  echo "  DB access:   docker exec + mariadb SELECT (read-only)"
  echo "  SOAP write:  announce + admin revive/tele (SYSTEM_SOAP_* )"
  echo "  lifecycle:   operator up/down via uv (async worker; Server panel)"
  server.serve(Port(port), "127.0.0.1")

when isMainModule:
  main()
