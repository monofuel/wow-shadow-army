## The System — management server for the shadow army.
##
## One Nim binary, HTTP + MCP interfaces on one mummy server:
##   HTTP dashboard (htmx)  GET /  GET /army  GET /murist  GET /advisor
##                          GET /traverse  GET /admin
##                          GET /roster  GET /murist/status  GET /murist/quests
##                          GET /murist/events  GET /traverse/status
##                          GET /events  GET /server
##                          POST /reload  POST /server/start  POST /server/stop
##                          POST /admin/respawn-shadow-army
##   MCP endpoint (MCPort)  POST /mcp
##
## Critical design rule: one dispatch path. Each capability is one data/action
## proc; the htmx handlers render it and the MCP tools serialize it.
##   listCharacters()           — roster (SELECT via docker exec)
##   traverseStatus()        — Kalimdor Traverse telemetry (SELECT-only)
##   recentEvents()          — addon Chat.log ring buffer
##   reloadAddon()           — SOAP announce <SYS> reload + wait for <SA> loaded
##   announceInGame()        — SOAP announce <text>
##   respawnShadowArmy()     — admin SOAP revive + tele (ops escape hatch)
##   serverStatus()          — realm container up/down + lifecycle op state
##   startServer()/stopServer() — queue operator `up`/`down` (async worker)
##
## Tabs: Army (roster), Murist (human seat), Advisor (events + reload),
## Traverse (league telemetry), Admin (realm + ops). The dashboard stays
## useful with the realm DOWN: roster/Murist degrade to offline notes;
## Admin's Server panel offers Start/Stop. The human only runs the client
## and this dashboard.
##
## Admin interfaces (same procs): HTTP /admin, MCP tools, and human-seat addon
## chat (`<SA> admin <action>` from Murist → Chat.log tailer).

import
  std/[
    algorithm, base64, httpclient, json, locks, net, options, os, osproc,
    streams, strformat, strutils, times
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
  ## Kalimdor Traverse fixture character (docs/traverse_wow.md).
  TraverseCharacterName* = "Northbound"
  ## Course anchors from upstream game/scoring.py (X is north/south).
  TraverseStartWorldX* = -9187.0
  TraverseGoalWorldX* = 6687.333052
  ## goal - start; full course length in yards.
  TraverseCourseYards* = 15874.333052
  ## docker ps name suffix for the traverse scenario game container.
  TraverseContainerSuffix* = "-traverse-coworld-game-1"
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
  ## Base nim_control port: slot N listens on 41114 + N (docs/control-plane.md).
  NimControlBasePort = 41114
  ## Bot seat launch map: seat name → Makefile seat target (slot = control
  ## port offset, matching seatControlPort). Murist is human — never listed.
  SeatMakeTargets* = [
    (name: "Shadowfel", target: "warlock-bot", slot: 2),
    (name: "Igris", target: "igris-bot", slot: 3),
    (name: "Tusk", target: "tusk-bot", slot: 4),
    (name: "Beru", target: "beru-bot", slot: 5)
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
    ## nim_control socket for known bot seats (0 = none / human / unknown).
    controlPort*: int
    ## True when controlPort is listening on 127.0.0.1 (seat client up).
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

  TraverseStatus* = object
    ## Dashboard snapshot for the Traverse tab (read-only telemetry).
    containerFound*: bool
    containerName*: string
    characterFound*: bool
    character*: TraverseCharacter
    score*: TraverseScore

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

proc traverseStatus*(): TraverseStatus =
  ## Single dispatch path for Traverse tab telemetry (SELECT-only, no docker lifecycle).
  result = TraverseStatus(
    containerFound: false,
    containerName: "",
    characterFound: false,
    character: TraverseCharacter(),
    score: scoreTraverse(false, 0, 0, false, 0.0)
  )
  let container = resolveTraverseContainer()
  if container.len == 0:
    return
  result.containerFound = true
  result.containerName = container
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
  let ch = chOpt.get
  result.characterFound = true
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
  ## nim_control port for a known bot seat, or 0 if none.
  ## Slot map: 2=Shadowfel, 3=Igris, 4=Tusk, 5=Beru (Makefile / control-plane).
  case name
  of "Shadowfel": NimControlBasePort + 2
  of "Igris": NimControlBasePort + 3
  of "Tusk": NimControlBasePort + 4
  of "Beru": NimControlBasePort + 5
  else: 0

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

proc enrichControlPlane*(characters: var seq[Character]) =
  ## Fill controlPort / controlUp for known bot seats (local sockets only).
  for i in 0 ..< characters.len:
    let port = seatControlPort(characters[i].name)
    characters[i].controlPort = port
    if port > 0:
      characters[i].controlUp = isTcpPortOpen("127.0.0.1", port)
    else:
      characters[i].controlUp = false

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
  ## Makefile seat target for a bot seat, or "" (human / unknown).
  for seat in SeatMakeTargets:
    if seat.name == name:
      return seat.target
  result = ""

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

proc startBotSeat*(name: string): JsonNode =
  ## Launch one bot seat: detached `make <seat>-bot` appending to its
  ## local_data log (the documented nohup pattern). Ready when the seat's
  ## nim_control socket (41114+slot) starts listening — the roster poll
  ## flips the button on its own.
  let target = seatMakeTarget(name)
  if target.len == 0:
    return %*{"ok": false, "name": name, "action": "start",
              "detail": "not a launchable bot seat"}
  let port = seatControlPort(name)
  if isTcpPortOpen("127.0.0.1", port):
    return %*{"ok": true, "name": name, "action": "start",
              "detail": &"already running (ctrl :{port})"}
  let root = armyRoot()
  if not fileExists(root / "Makefile"):
    return %*{"ok": false, "name": name, "action": "start",
              "detail": &"Makefile missing in {root} — set SYSTEM_ARMY_DIR"}
  let log = root / "local_data" / (target & ".log")
  # The ( … & ) subshell orphans the seat to init immediately — without it the
  # launching shell lives as make's parent holding our output pipe open, which
  # blocks the HTTP worker for the bot's entire lifetime.
  let r = runShell(
    &"mkdir -p '{root}/local_data' && ( setsid nohup make -C '{root}' {target} >> '{log}' 2>&1 < /dev/null & )")
  if not r.ok:
    return %*{"ok": false, "name": name, "action": "start", "detail": r.detail}
  result = %*{"ok": true, "name": name, "action": "start",
              "detail": &"launched make {target} (log: local_data/{target}.log; ctrl :{port} when ready)"}

proc stopBotSeat*(name: string): JsonNode =
  ## Stop one bot seat: TERM whoever holds the seat's nim_control port.
  ## The reference_player logs out; its parent make/nohup exits with it.
  let target = seatMakeTarget(name)
  if target.len == 0:
    return %*{"ok": false, "name": name, "action": "stop",
              "detail": "not a launchable bot seat"}
  let port = seatControlPort(name)
  if not isTcpPortOpen("127.0.0.1", port):
    return %*{"ok": true, "name": name, "action": "stop",
              "detail": "already stopped (no ctrl listener)"}
  let r = runShell(&"lsof -ti tcp:{port} | xargs -r kill")
  if not r.ok:
    return %*{"ok": false, "name": name, "action": "stop", "detail": r.detail}
  result = %*{"ok": true, "name": name, "action": "stop",
              "detail": &"sent TERM to ctrl :{port} holder"}

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
  ## Realm connection as a terse On/Off. Port/ctrl detail lives in the
  ## tooltip only — it blew out table rows and duplicated the Bot column.
  let net = if s.online: "On" else: "Off"
  let netCls = if s.online: "online" else: "offline"
  let title =
    if s.controlPort <= 0:
      "human seat"
    elif s.controlUp:
      &"nim_control listening on 127.0.0.1:{s.controlPort}"
    else:
      &"seat slot port {s.controlPort} (not listening)"
  result = &"""<span class="seat-net {netCls}" title="{escapeHtml(title)}">{escapeHtml(net)}</span>"""

proc renderBotCell*(s: Character): string =
  ## Per-seat Start/Stop button for launchable bot seats ("—" otherwise).
  ## controlUp is the truth signal: socket up = seat process alive.
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
  var online, alive, ghost, dead, ctrlUp, ctrlKnown = 0
  for s in characters:
    if s.online: inc online
    case s.life
    of "alive": inc alive
    of "ghost": inc ghost
    of "dead": inc dead
    else: discard
    if s.controlPort > 0:
      inc ctrlKnown
      if s.controlUp: inc ctrlUp
  result = &"{online} online · {alive} alive · {ghost} ghost · {dead} dead"
  if ctrlKnown > 0:
    result.add(&" · ctrl {ctrlUp}/{ctrlKnown}")

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
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--bad); box-shadow: 0 0 0 transparent; flex-shrink: 0;
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

proc renderArmyPage*(characters: seq[Character], rosterOffline = false): string =
  ## Army tab: roster only. Foundation seats always hidden.
  let rows = if rosterOffline: renderRosterOfflineRow() else: renderRosterRows(characters)
  let summary = armySummary(characters)
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
    realmOffline = false
): string =
  ## Murist tab: human seat snapshot + quest log + addon events.
  let statusBody = renderMuristStatus(murist, realmOffline = realmOffline)
  let questRows = renderQuestRows(quests, realmOffline = realmOffline)
  let eventRows = renderMuristEventRows(events)
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

proc renderTraverseStatus*(st: TraverseStatus): string =
  ## Traverse panel body: container + Northbound telemetry + score bar.
  if not st.containerFound:
    return """
    <p class="empty">Scenario not running — no *-traverse-coworld-game-1 container.</p>"""
  let containerPill =
    """<span class="pill"><span class="dot on"></span> running</span>"""
  let containerLabel = escapeHtml(st.containerName)
  if not st.characterFound:
    return &"""
    <div class="panel-actions" style="margin-bottom:0.75rem">
      {containerPill}
      <span class="server-container">{containerLabel}</span>
    </div>
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
  result = &"""
    <div class="panel-actions" style="margin-bottom:0.75rem">
      {containerPill}
      <span class="server-container">{containerLabel}</span>
      {onlinePill}
      {validityBadge}
    </div>
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

proc renderTraversePage*(st: TraverseStatus): string =
  ## Traverse tab: league telemetry only (no viewport, no launch controls).
  let statusBody = renderTraverseStatus(st)
  let body = &"""
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
    request.respond(200, htmlHeaders(),
      renderArmyPage(characters, rosterOffline = rosterOffline))
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
    request.respond(200, htmlHeaders(),
      renderMuristPage(murist, events, quests, realmOffline = realmOffline))
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

proc traversePageHandler(request: Request) {.gcsafe.} =
  ## GET /traverse — Traverse tab (Kalimdor course telemetry).
  try:
    var st: TraverseStatus
    {.gcsafe.}:
      st = traverseStatus()
    request.respond(200, htmlHeaders(), renderTraversePage(st))
  except Exception as e:
    # Never surface a hard failure for a missing scenario — soft empty page.
    try:
      let soft = TraverseStatus(
        containerFound: false,
        score: scoreTraverse(false, 0, 0, false, 0.0)
      )
      request.respond(200, htmlHeaders(), renderTraversePage(soft))
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
    description: "Launch one bot seat (detached `make <seat>-bot`). Seat is ready when its nim_control socket (41114+slot) listens; check list_characters control_up.",
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
    description: "Stop one bot seat (TERM the nim_control socket holder; the client logs out).",
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
  server.registerRichTool(startBotTool, startBotMcpHandler)
  server.registerRichTool(stopBotTool, stopBotMcpHandler)

proc main() =
  ## Boot The System: Chat.log tailer + one mummy server (dashboard + MCP).
  gMcpServer = newMcpServer(ServerName, Version)
  registerMcpTools(gMcpServer)
  startChatLogTailer()
  startAdminWorker()
  startServerOpWorker()

  var router: Router
  router.get("/", armyPageHandler)
  router.get("/army", armyPageHandler)
  router.get("/murist", muristPageHandler)
  router.get("/murist/status", muristStatusHandler)
  router.get("/murist/quests", muristQuestsHandler)
  router.get("/murist/events", muristEventsHandler)
  router.get("/advisor", advisorPageHandler)
  router.get("/traverse", traversePageHandler)
  router.get("/traverse/status", traverseStatusHandler)
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

  let server = newServer(router)
  echo &"{ServerName} v{Version} listening on http://127.0.0.1:{HttpPort}"
  echo &"  Army:        GET  http://127.0.0.1:{HttpPort}/army"
  echo &"  Murist:      GET  http://127.0.0.1:{HttpPort}/murist"
  echo &"  Advisor:     GET  http://127.0.0.1:{HttpPort}/advisor"
  echo &"  Traverse:    GET  http://127.0.0.1:{HttpPort}/traverse"
  echo &"  Admin:       GET  http://127.0.0.1:{HttpPort}/admin"
  echo &"  Events:      GET  http://127.0.0.1:{HttpPort}/events"
  echo &"  Server:      GET  http://127.0.0.1:{HttpPort}/server (POST /server/start /server/stop)"
  echo &"  Reload:      POST http://127.0.0.1:{HttpPort}/reload"
  echo &"  Respawn:     POST http://127.0.0.1:{HttpPort}/admin/respawn-shadow-army"
  echo &"  Tele party:  POST http://127.0.0.1:{HttpPort}/admin/tele-party-to-murist"
  echo &"  MCP:         POST http://127.0.0.1:{HttpPort}/mcp"
  echo &"  container:   {gameContainer()} (SYSTEM_MYSQL_CONTAINER to override)"
  echo &"  traverse:    {resolveTraverseContainer()} (SYSTEM_TRAVERSE_CONTAINER to override)"
  echo &"  Chat.log:    {chatLogPath()} (SYSTEM_CHAT_LOG to override)"
  echo &"  upstream:    {upstreamDir()} (SYSTEM_UPSTREAM_DIR to override)"
  echo "  DB access:   docker exec + mariadb SELECT (read-only)"
  echo "  SOAP write:  announce + admin revive/tele (SYSTEM_SOAP_* )"
  echo "  lifecycle:   operator up/down via uv (async worker; Server panel)"
  server.serve(Port(HttpPort), "127.0.0.1")

when isMainModule:
  main()
