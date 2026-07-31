## The System — management server for the shadow army.
##
## One Nim binary, two faces on one mummy server:
##   HTTP dashboard (htmx)  GET /  GET /roster  GET /events  GET /server
##                          POST /reload  POST /server/start  POST /server/stop
##                          GET /admin  POST /admin/respawn-shadow-army
##   MCP endpoint (MCPort)  POST /mcp
##
## Critical design rule: one dispatch path. Each capability is one data/action
## proc; the htmx handlers render it and the MCP tools serialize it.
##   listShadows()           — roster (SELECT via docker exec)
##   recentEvents()          — addon Chat.log ring buffer
##   reloadAddon()           — SOAP announce <SYS> reload + wait for <SA> loaded
##   announceInGame()        — SOAP announce <text>
##   respawnShadowArmy()     — admin SOAP revive + tele (ops escape hatch)
##   serverStatus()          — realm container up/down + lifecycle op state
##   startServer()/stopServer() — queue operator `up`/`down` (async worker)
##
## The dashboard stays useful with the realm DOWN: roster degrades to an
## offline note; the Admin tab's Server panel offers Start/Stop. The human
## only runs the client and this dashboard; realm lifecycle goes through here.
##
## Admin faces (same procs): HTTP /admin, MCP tools, and human-seat addon
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
  Version = "0.10.0"
  ServerName = "TheSystem"
  ## Only this character may request admin actions via `<SA> admin …` (human seat).
  AdminRequesterName* = "Murist"
  ## Min seconds between chat-triggered admin actions (double-click / say dedupe).
  AdminChatCooldownSec = 8.0
  ## World DB (game_tele lives here; characters DB is separate).
  WorldDbName = "mangos"
  ## Scratch game_tele name: upserted to Murist's live coords, then used by
  ## `tele name <cast> SA_MURIST_MEET`. Console SOAP cannot `go xyz` another player.
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
  ## VMaNGOS CHARACTER_FLAG_GHOST — set while spirit-running / unreleased corpse.
  CharacterFlagGhost = 0x2000
  ## Fixed 5-man bot cast (party-army seats). Admin respawn only touches these.
  ## Murist is the human leader and is intentionally not in this list.
  ShadowArmyCast* = ["Shadowfel", "Igris", "Tusk", "Beru"]
  ## Display order for the Murist party (human first, then bot seats).
  CastDisplayOrder* = ["Murist", "Shadowfel", "Igris", "Tusk", "Beru"]
  ## Named game_tele destination (mangos.game_tele / `lookup tele death`).
  ## Safe valley floor near Deathknell undead start — not NightWebsHollow.
  ShadowArmyRespawnTele* = "Deathknell"
  ## Base nim_control port: slot N listens on 41114 + N (docs/control-plane.md).
  NimControlBasePort = 41114
  ## Bot seat launch map: cast name → Makefile seat target (slot = control
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
  ## Realm lifecycle operator, run with cwd = upstream (same as Makefile OPERATOR).
  OperatorScriptRel = "server/scripts/docker_vmangos_server.py"
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
  Shadow* = object
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
    container*: string
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

proc gameContainer(): string =
  ## Resolve the coworld-game MariaDB / world container name.
  result = getEnv("SYSTEM_MYSQL_CONTAINER", DefaultGameContainer)

proc chatLogPath*(): string =
  ## Absolute path to VMaNGOS Chat.log (SYSTEM_CHAT_LOG wins).
  let env = getEnv("SYSTEM_CHAT_LOG", "")
  if env.len > 0:
    return absolutePath(env)
  result = absolutePath(DefaultChatLogRel)

proc fetchRosterTsv(): string =
  ## Read character roster via docker exec + mariadb (SELECT only).
  ##
  ## Choice: shell out to docker exec (same path as Makefile `account`), not a
  ## native MySQL driver. Host has no mysql client; port 3307 is open but
  ## docker exec is already proven and needs zero new deps.
  ##
  ## Args are passed without a shell so the SELECT string stays intact. stderr
  ## is left alone (mariadb prints a "password on CLI" warning there) so TSV
  ## stdout stays clean.
  let container = gameContainer()
  let process = startProcess(
    "docker",
    args = [
      "exec", container,
      "mariadb",
      &"-u{DbUser}",
      &"-p{DbPass}",
      DbName,
      "-N", "-B",
      "-e", RosterSql
    ],
    options = {poUsePath}
  )
  let output = process.outputStream.readAll()
  let err = process.errorStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(IOError,
      &"roster query failed (exit {exitCode}) via docker exec {container}: {err}\n{output}")
  result = output

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

proc parseRosterTsv*(tsv: string): seq[Shadow] =
  ## Parse mariadb -N -B TSV into Shadow rows.
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
    result.add(Shadow(
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

proc enrichControlPlane*(shadows: var seq[Shadow]) =
  ## Fill controlPort / controlUp for known bot seats (local sockets only).
  for i in 0 ..< shadows.len:
    let port = seatControlPort(shadows[i].name)
    shadows[i].controlPort = port
    if port > 0:
      shadows[i].controlUp = isTcpPortOpen("127.0.0.1", port)
    else:
      shadows[i].controlUp = false

proc castSortRank*(name: string): int =
  ## Stable party order: Murist → Shadowfel → Igris → Tusk → Beru → rest A–Z.
  for i, n in CastDisplayOrder:
    if n == name:
      return i
  result = 100 + name.len # keep non-cast stable-ish by name length then cmp

proc sortShadowsForDisplay*(shadows: var seq[Shadow]) =
  ## Cast-first ordering for the Status Window.
  shadows.sort(proc (a, b: Shadow): int =
    let ra = castSortRank(a.name)
    let rb = castSortRank(b.name)
    if ra != rb:
      return cmp(ra, rb)
    return cmp(a.name, b.name)
  )

proc listShadows*(): seq[Shadow] =
  ## Single dispatch path: all faces (htmx + MCP) get roster data from here.
  result = parseRosterTsv(fetchRosterTsv())
  enrichControlPlane(result)
  sortShadowsForDisplay(result)

proc isFoundationSeat*(name: string): bool =
  ## Pre-built coworld tournament / foundation seats (not the Murist cast).
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

proc filterShadows*(shadows: seq[Shadow], includeFoundation = false): seq[Shadow] =
  ## Cast-first view: drop foundation seats unless includeFoundation.
  if includeFoundation:
    return shadows
  result = @[]
  for s in shadows:
    if not isFoundationSeat(s.name):
      result.add(s)

proc shadowsToJson*(shadows: seq[Shadow]): JsonNode =
  ## Serialize the roster for the MCP face (and any future JSON API).
  result = %*[]
  for s in shadows:
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

# Defined with SOAP section; admin worker reuses the same faces.
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
# ---------------------------------------------------------------------------

proc upstreamDir*(): string =
  ## Upstream coworld-vanilla-wow checkout (SYSTEM_UPSTREAM_DIR wins).
  let env = getEnv("SYSTEM_UPSTREAM_DIR", "")
  if env.len > 0:
    return absolutePath(env)
  result = absolutePath(DefaultUpstreamRel)

proc parseDockerRunning*(output: string): bool =
  ## Interpret `docker inspect -f {{.State.Running}}` stdout.
  result = output.strip().toLowerAscii() == "true"

proc containerRunning(): bool =
  ## True when the coworld-game container exists and is running.
  ## Missing container / docker error = down (that IS the stopped state:
  ## the operator's `down` does compose rm, so the container disappears).
  let container = gameContainer()
  try:
    let process = startProcess(
      "docker",
      args = ["inspect", "-f", "{{.State.Running}}", container],
      options = {poUsePath}
    )
    let output = process.outputStream.readAll()
    discard process.errorStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      return false
    result = parseDockerRunning(output)
  except CatchableError:
    result = false

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

proc tailForDisplay*(s: string, maxLen = 600): string =
  ## Keep the tail of operator output (the interesting part) for status lines.
  let clean = s.strip()
  if clean.len <= maxLen:
    return clean
  result = "…" & clean[clean.len - maxLen .. ^1]

proc runServerOperator(op: ServerLifecycleOp): tuple[ok: bool, detail: string] =
  ## Run the upstream compose operator (`up`/`down`) with cwd = upstream —
  ## the exact path Makefile start-server / stop-server uses. Blocking; only
  ## the server-op worker thread calls this.
  let verb = serverOpVerb(op)
  let dir = upstreamDir()
  if not fileExists(dir / OperatorScriptRel):
    return (ok: false,
      detail: &"operator script missing: {dir / OperatorScriptRel} — set SYSTEM_UPSTREAM_DIR to a real coworld-vanilla-wow checkout")
  try:
    let process = startProcess(
      "uv",
      args = ["run", "python", OperatorScriptRel, verb],
      workingDir = dir,
      options = {poUsePath, poStdErrToStdOut}
    )
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      return (ok: false, detail: &"operator {verb} exit {exitCode}: {tailForDisplay(output)}")
    result = (ok: true, detail: tailForDisplay(output))
  except CatchableError as e:
    result = (ok: false, detail: &"operator {verb} failed to launch: {e.msg}")

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
  withLock gServerOpLock:
    if gRunningServerOp != sloNone or gPendingServerOp != sloNone:
      let busy = serverOpLabel(
        if gRunningServerOp != sloNone: gRunningServerOp else: gPendingServerOp)
      return (accepted: false, reason: &"busy: {busy} in progress")
    gPendingServerOp = op
    result = (accepted: true, reason: "")

proc serverStatus*(): ServerStatus =
  ## Single dispatch path for realm lifecycle state (Server panel + MCP).
  result.container = gameContainer()
  result.running = containerRunning()
  withLock gServerOpLock:
    result.op = serverOpLabel(
      if gRunningServerOp != sloNone: gRunningServerOp else: gPendingServerOp)
    result.lastOp = gLastServerOp
    result.lastOpOk = gLastServerOpOk
    result.lastOpDetail = gLastServerOpDetail

proc startServer*(): ServerStatus =
  ## Queue realm start (operator `up`). Returns fresh status either way.
  discard requestServerOp(sloStart)
  result = serverStatus()

proc stopServer*(): ServerStatus =
  ## Queue realm stop (operator `down` — compose rm, volumes kept).
  discard requestServerOp(sloStop)
  result = serverStatus()

proc serverStatusToJson*(s: ServerStatus): JsonNode =
  ## Serialize lifecycle status for the MCP face.
  result = %*{
    "running": s.running,
    "container": s.container,
    "op": s.op,
    "last_op": s.lastOp,
    "last_op_ok": s.lastOpOk,
    "last_op_detail": s.lastOpDetail
  }

proc serverOpWorkerLoop() {.thread.} =
  ## Runs queued lifecycle ops. Same worker-thread pattern as adminWorkerLoop:
  ## HTTP handlers stay fast; compose up/down (minutes) happens here.
  while true:
    sleep(200)
    var op = sloNone
    {.gcsafe.}:
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

proc armyRoot(): string =
  ## wow-shadow-army repo root holding the Makefile (SYSTEM_ARMY_DIR wins;
  ## default cwd — `make system` runs from the repo root).
  let env = getEnv("SYSTEM_ARMY_DIR", "")
  if env.len > 0:
    return absolutePath(env)
  result = getCurrentDir()

proc seatMakeTarget*(name: string): string =
  ## Makefile seat target for a cast bot, or "" (human / unknown).
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
  ## Launch one cast bot seat: detached `make <seat>-bot` appending to its
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
  ## Stop one cast bot seat: TERM whoever holds the seat's nim_control port.
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

proc isShadowArmyCastName*(name: string): bool =
  ## True when `name` is exactly one of the fixed bot cast seats.
  for n in ShadowArmyCast:
    if n == name:
      return true
  result = false

proc respawnCommandsFor*(name: string, teleDest: string = ShadowArmyRespawnTele): seq[string] =
  ## Ordered SOAP commands to revive and place one cast member.
  ## Names are fixed-cast only; callers must not pass free text.
  if not isShadowArmyCastName(name):
    raise newException(ValueError, &"not a shadow-army cast name: {name}")
  # teleDest is a fixed constant in production; reject path-ish junk in tests.
  if teleDest.len == 0 or ' ' in teleDest or '/' in teleDest or ';' in teleDest:
    raise newException(ValueError, &"invalid tele destination: {teleDest}")
  result = @[
    &"revive {name}",
    &"tele name {name} {teleDest}",
    &"repairitems {name}",
  ]

proc teleToMuristCommandsFor*(name: string, teleDest: string = MuristMeetTeleName): seq[string] =
  ## SOAP command to pull one cast seat to the Murist-meet game_tele pin.
  if not isShadowArmyCastName(name):
    raise newException(ValueError, &"not a shadow-army cast name: {name}")
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

proc findShadowByName*(shadows: seq[Shadow], name: string): Option[Shadow] =
  ## Linear lookup by exact character name.
  for s in shadows:
    if s.name == name:
      return some(s)
  result = none(Shadow)

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
    "cast": ShadowArmyCast,
    "tele": ShadowArmyRespawnTele
  }

proc respawnShadowArmy*(): AdminActionResult =
  ## Ops escape hatch: SOAP-revive each bot cast seat and tele to Deathknell.
  ##
  ## This is **not** fair-play recovery. It is an admin-only testing reset when
  ## corpse runs stall (ghost masks, elevated death pockets, etc.). Policy
  ## brains must never call this; only The System admin faces (HTTP / MCP /
  ## human-seat `<SA> admin respawn_shadow_army`).
  result = AdminActionResult(ok: true, action: "respawn_shadow_army", steps: @[])
  recordAdmin(
    DefaultAuditPath,
    kind = "respawn_shadow_army_begin",
    detail = "revive+tele+repair for cast seats"
  )
  for name in ShadowArmyCast:
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
      &"respawned {ShadowArmyCast.len} cast seats → {ShadowArmyRespawnTele} ({okCount} SOAP steps ok)"
    else:
      &"respawn partial/fail ({okCount}/{result.steps.len} SOAP steps ok) — see steps"

proc telePartyToMurist*(): AdminActionResult =
  ## Ops escape hatch: pin game_tele to Murist's coords, reload, tele cast seats.
  ##
  ## Console SOAP only supports `tele name <player> <game_tele>` (not free xyz).
  ## So we upsert `SA_MURIST_MEET` in mangos.game_tele from characters.position_*,
  ## `reload game_tele`, then `tele name` each fixed cast seat. Not fair-play.
  result = AdminActionResult(ok: true, action: "tele_party_to_murist", steps: @[])
  recordAdmin(
    DefaultAuditPath,
    kind = "tele_party_to_murist_begin",
    detail = "pin SA_MURIST_MEET + tele cast seats"
  )

  var muristOpt: Option[Shadow]
  try:
    muristOpt = findShadowByName(listShadows(), AdminRequesterName)
  except Exception as e:
    result.ok = false
    result.summary = "failed to read roster: " & e.msg
    result.steps.add(AdminStepResult(
      name: AdminRequesterName, command: "listShadows", ok: false, detail: e.msg))
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

  # 3) Tele each cast seat to the pin.
  for name in ShadowArmyCast:
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
      &"teleported {ShadowArmyCast.len} cast seats → Murist {where} ({okCount} steps ok)"
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
# HTML faces
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
    return """<tr><td colspan="4" class="empty">No addon events yet (tailing Chat.log live).</td></tr>"""
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
    pill = """<span class="status busy">Starting…</span>"""
  elif s.op == "stop":
    pill = """<span class="status busy">Stopping…</span>"""
  elif s.running:
    pill = """<span class="status alive">Running</span>"""
  else:
    pill = """<span class="status offline">Stopped</span>"""

  var action: string
  if s.op.len > 0:
    let verb = if s.op == "start": "compose up (image + db healthcheck)" else: "compose stop/rm"
    action = &"""<span class="meta">operator {escapeHtml(s.op)} running — {escapeHtml(verb)}; this can take a few minutes</span>"""
  elif s.running:
    action = &"""
      <button class="admin danger"
              hx-post="/server/stop"
              hx-target="#server-panel"
              hx-swap="innerHTML"
              hx-confirm="Stop the realm? (compose stop/rm — characters and accounts persist)">
        Stop server
      </button>"""
  else:
    action = &"""
      <button class="reload"
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

  result = &"""
    <div class="server-line">
      <span class="server-label">Realm</span>
      {pill}
      <span class="meta server-container">{escapeHtml(s.container)}</span>
      <span class="server-action">{action}</span>
    </div>
    {lastLine}"""

proc renderXpCell*(s: Shadow): string =
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

proc renderVitalsCell*(s: Shadow): string =
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

proc renderPosCell*(s: Shadow): string =
  ## Compact map position for corpse-run / regroup awareness.
  if abs(s.posX) + abs(s.posY) < 0.01:
    return """<span class="xp-muted">—</span>"""
  let label = &"{s.posX:.0f}, {s.posY:.0f}"
  let title = &"map {s.mapId} · x={s.posX:.1f} y={s.posY:.1f} z={s.posZ:.1f}"
  result = &"""<span class="pos" title="{escapeHtml(title)}">{escapeHtml(label)}</span>"""

proc renderSeatCell*(s: Shadow): string =
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

proc renderBotCell*(s: Shadow): string =
  ## Per-seat Start/Stop button for launchable cast bots ("—" otherwise).
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

proc armySummary*(shadows: seq[Shadow]): string =
  ## One-line cast health strip for the roster panel head.
  var online, alive, ghost, dead, ctrlUp, ctrlKnown = 0
  for s in shadows:
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

proc renderRosterRows*(shadows: seq[Shadow]): string =
  ## htmx partial: `<tr>` rows for the roster table body.
  if shadows.len == 0:
    return """<tr><td colspan="11" class="empty">No characters in this view (toggle foundation seats, or empty realm).</td></tr>"""
  result = ""
  for s in shadows:
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
  result = """<tr><td colspan="11" class="empty">Realm is offline — start it from the <a href="/admin">Admin</a> tab and the roster will fill in here.</td></tr>"""

proc renderRosterPage*(
    shadows: seq[Shadow],
    events: seq[AddonEvent],
    includeFoundation = false,
    rosterOffline = false
): string =
  ## Full Status Window (htmx + auto-poll): roster + addon events.
  ## Realm lifecycle controls live on the Admin tab (renderAdminPage).
  let rows = if rosterOffline: renderRosterOfflineRow() else: renderRosterRows(shadows)
  let eventRows = renderEventRows(events)
  let summary = armySummary(shadows)
  let stamped = now().format("yyyy-MM-dd HH:mm:ss")
  let rosterUrl = if includeFoundation: "/roster?all=1" else: "/roster"
  let checked = if includeFoundation: " checked" else: ""
  result = &"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>The System — Roster</title>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <style>
    :root {{
      --bg: #0d1117;
      --panel: #161b22;
      --border: #30363d;
      --text: #e6edf3;
      --muted: #8b949e;
      --accent: #58a6ff;
      --online: #3fb950;
      --offline: #6e7681;
      --alive: #3fb950;
      --ghost: #a371f7;
      --dead: #f85149;
      --gold: #d4a017;
      --err: #f85149;
      --loaded: #3fb950;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
    }}
    header {{
      padding: 1.25rem 1.5rem;
      border-bottom: 1px solid var(--border);
      background: var(--panel);
    }}
    header h1 {{
      margin: 0;
      font-size: 1.25rem;
      letter-spacing: 0.04em;
      color: var(--accent);
    }}
    header p {{
      margin: 0.35rem 0 0;
      color: var(--muted);
      font-size: 0.9rem;
    }}
    main {{ padding: 1.5rem; max-width: 1280px; margin: 0 auto; }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
      margin-bottom: 1.25rem;
    }}
    .table-scroll {{ overflow-x: auto; }}
    .panel-head {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.75rem;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
      flex-wrap: wrap;
    }}
    .panel-head h2 {{ margin: 0; font-size: 1rem; }}
    .panel-actions {{
      display: flex;
      align-items: center;
      gap: 0.75rem;
      flex-wrap: wrap;
    }}
    .meta {{ color: var(--muted); font-size: 0.8rem; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{
      text-align: left;
      padding: 0.55rem 0.7rem;
      border-bottom: 1px solid var(--border);
      font-size: 0.9rem;
    }}
    th {{ color: var(--muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; }}
    tr:last-child td {{ border-bottom: none; }}
    td.name {{ font-weight: 600; }}
    td.lvl {{ font-variant-numeric: tabular-nums; font-weight: 600; }}
    td.gold {{ color: var(--gold); font-variant-numeric: tabular-nums; }}
    td.zone {{ color: var(--text); font-size: 0.9rem; max-width: 10rem; }}
    td.conn {{ color: var(--muted); font-size: 0.8rem; font-variant-numeric: tabular-nums; }}
    td.payload {{ color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem; }}
    td.xp-cell {{ min-width: 9.5rem; }}
    td.vitals-cell {{ min-width: 8rem; }}
    .xp-bar {{
      height: 6px;
      background: #21262d;
      border-radius: 999px;
      overflow: hidden;
      margin-bottom: 0.25rem;
    }}
    .xp-fill {{
      height: 100%;
      background: linear-gradient(90deg, #1f6feb, #58a6ff);
      border-radius: 999px;
    }}
    .xp-meta {{
      font-size: 0.75rem;
      font-variant-numeric: tabular-nums;
      color: var(--text);
    }}
    .xp-muted {{ color: var(--muted); font-weight: 400; }}
    .vitals {{ display: flex; flex-direction: column; gap: 0.2rem; }}
    .vitals-line {{
      display: grid;
      grid-template-columns: 2.4rem 1fr auto;
      align-items: center;
      gap: 0.35rem;
      font-size: 0.72rem;
      font-variant-numeric: tabular-nums;
    }}
    .vitals-tag {{ color: var(--muted); font-weight: 600; }}
    .vitals-bar {{
      height: 5px;
      background: #21262d;
      border-radius: 999px;
      overflow: hidden;
    }}
    .vitals-fill {{ height: 100%; border-radius: 999px; }}
    .vitals-fill.hp {{ background: linear-gradient(90deg, #238636, #3fb950); }}
    .vitals-fill.hp.low {{ background: linear-gradient(90deg, #a40e26, #f85149); }}
    .vitals-fill.mana {{ background: linear-gradient(90deg, #1f6feb, #58a6ff); }}
    .vitals-fill.rage {{ background: linear-gradient(90deg, #a40e26, #f85149); }}
    .vitals-fill.energy {{ background: linear-gradient(90deg, #9e6a03, #d4a017); }}
    .vitals-num {{ color: var(--text); white-space: nowrap; }}
    .vitals-muted {{ color: var(--muted); }}
    td.pos-cell, .pos {{
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.8rem;
      font-variant-numeric: tabular-nums;
      color: var(--muted);
      white-space: nowrap;
    }}
    td.seat {{ font-size: 0.8rem; white-space: nowrap; }}
    td.bot-cell {{ white-space: nowrap; }}
    .bot-btn {{
      border: none;
      border-radius: 5px;
      padding: 0.2rem 0.55rem;
      font-size: 0.72rem;
      font-weight: 600;
      cursor: pointer;
    }}
    .bot-btn.start {{ background: var(--accent); color: #0d1117; }}
    .bot-btn.stop {{ background: color-mix(in srgb, var(--dead) 85%, #000); color: #fff; }}
    .bot-btn:hover {{ filter: brightness(1.1); }}
    .seat-net.online {{ color: var(--alive); font-weight: 600; }}
    .seat-net.offline {{ color: var(--offline); }}
    .seat-ctrl.ctrl-up {{ color: var(--accent); }}
    .seat-ctrl.ctrl-down {{ color: var(--err); }}
    tr.foundation td.name {{ color: var(--muted); }}
    tr.row-ghost {{ background: color-mix(in srgb, var(--ghost) 8%, transparent); }}
    tr.row-dead {{ background: color-mix(in srgb, var(--dead) 8%, transparent); }}
    .army-summary {{
      font-size: 0.8rem;
      color: var(--muted);
      font-variant-numeric: tabular-nums;
    }}
    .toggle {{
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      font-size: 0.8rem;
      color: var(--muted);
      cursor: pointer;
      user-select: none;
    }}
    .toggle input {{ accent-color: var(--accent); cursor: pointer; }}
    .status {{
      display: inline-block;
      padding: 0.15rem 0.5rem;
      border-radius: 999px;
      font-size: 0.75rem;
      font-weight: 600;
    }}
    .status.online, .status.alive {{ background: color-mix(in srgb, var(--alive) 20%, transparent); color: var(--alive); }}
    .status.offline {{ background: color-mix(in srgb, var(--offline) 25%, transparent); color: var(--offline); }}
    .status.busy {{ background: color-mix(in srgb, var(--accent) 20%, transparent); color: var(--accent); }}
    .server-line {{
      display: flex;
      align-items: center;
      gap: 0.75rem;
      flex-wrap: wrap;
    }}
    .server-label {{ font-weight: 600; font-size: 0.9rem; }}
    .server-container {{
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.75rem;
    }}
    .server-action {{ margin-left: auto; }}
    .server-last {{ margin-top: 0.5rem; font-size: 0.8rem; }}
    .status.ghost {{ background: color-mix(in srgb, var(--ghost) 22%, transparent); color: var(--ghost); }}
    .status.dead {{ background: color-mix(in srgb, var(--dead) 20%, transparent); color: var(--dead); }}
    .kind {{
      display: inline-block;
      padding: 0.15rem 0.5rem;
      border-radius: 999px;
      font-size: 0.75rem;
      font-weight: 600;
    }}
    .kind-err {{ background: color-mix(in srgb, var(--err) 20%, transparent); color: var(--err); }}
    .kind-loaded {{ background: color-mix(in srgb, var(--loaded) 20%, transparent); color: var(--loaded); }}
    .kind-muted {{ background: color-mix(in srgb, var(--muted) 20%, transparent); color: var(--muted); }}
    .empty {{ color: var(--muted); text-align: center; padding: 2rem; }}
    button.reload, button.admin {{
      background: var(--accent);
      color: #0d1117;
      border: none;
      border-radius: 6px;
      padding: 0.35rem 0.75rem;
      font-size: 0.8rem;
      font-weight: 600;
      cursor: pointer;
    }}
    button.reload:hover, button.admin:hover {{ filter: brightness(1.08); }}
    button.admin.danger {{
      background: #f85149;
      color: #fff;
    }}
    .reload-ok, .admin-ok {{ color: var(--loaded); font-size: 0.85rem; }}
    .reload-timeout, .admin-err {{ color: var(--err); font-size: 0.85rem; }}
    .nav {{
      display: flex;
      gap: 0.5rem;
      margin-top: 0.85rem;
    }}
    .nav a {{
      color: var(--muted);
      text-decoration: none;
      font-size: 0.85rem;
      font-weight: 600;
      padding: 0.3rem 0.7rem;
      border-radius: 6px;
      border: 1px solid transparent;
    }}
    .nav a:hover {{ color: var(--text); background: #21262d; }}
    .nav a.active {{
      color: var(--accent);
      border-color: var(--border);
      background: #21262d;
    }}
    .admin-note {{
      color: var(--muted);
      font-size: 0.9rem;
      line-height: 1.45;
      margin: 0 0 1rem;
    }}
    .admin-cast {{
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.85rem;
      color: var(--text);
    }}
    .admin-steps {{
      margin-top: 0.75rem;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.8rem;
      color: var(--muted);
      white-space: pre-wrap;
    }}
    .panel-body {{ padding: 1rem; }}
    footer {{
      max-width: 1100px;
      margin: 1rem auto;
      padding: 0 1.5rem;
      color: var(--muted);
      font-size: 0.8rem;
    }}
    code {{ background: var(--panel); padding: 0.1rem 0.35rem; border-radius: 4px; }}
  </style>
</head>
<body>
  <header>
    <h1>THE SYSTEM</h1>
    <p>Shadow army Status Window — local realm roster + addon telemetry</p>
    <nav class="nav">
      <a class="active" href="/">Status</a>
      <a href="/admin">Admin</a>
    </nav>
  </header>
  <main>
    <div class="panel">
      <div class="panel-head">
        <h2>Roster</h2>
        <div class="panel-actions">
          <span class="army-summary" id="army-summary">{escapeHtml(summary)}</span>
          <label class="toggle" title="Botmage/Botpriest/… and Nightsun/Cowcam">
            <input type="checkbox" id="show-foundation"{checked}
              onchange="window.sysSetFoundation(this.checked)">
            Show foundation seats
          </label>
          <span class="meta" id="stamp">as of {escapeHtml(stamped)} · refresh every {PollSeconds}s</span>
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
               hx-get="{rosterUrl}"
               hx-trigger="every {PollSeconds}s"
               hx-swap="innerHTML">
{rows}
        </tbody>
      </table>
      </div>
    </div>
    <script>
      window.sysSetFoundation = function(on) {{
        var tb = document.getElementById('roster');
        if (!tb) return;
        var url = on ? '/roster?all=1' : '/roster';
        tb.setAttribute('hx-get', url);
        if (window.htmx) {{
          htmx.process(tb);
          htmx.ajax('GET', url, {{target: '#roster', swap: 'innerHTML'}});
        }}
        try {{ history.replaceState(null, '', on ? '/?all=1' : '/'); }} catch (e) {{}}
      }};
    </script>
    <div class="panel">
      <div class="panel-head">
        <h2>Addon events</h2>
        <div class="panel-actions">
          <button class="reload"
                  hx-post="/reload"
                  hx-target="#reload-result"
                  hx-swap="innerHTML">Reload addon</button>
          <span id="reload-result" class="meta"></span>
          <span class="meta">live tail · every {PollSeconds}s</span>
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
               hx-swap="innerHTML">
{eventRows}
        </tbody>
      </table>
      </div>
    </div>
  </main>
  <footer>
    One dispatch path per capability:
    <code>listShadows()</code>, <code>recentEvents()</code>, <code>reloadAddon()</code>,
    <code>respawnShadowArmy()</code>, <code>serverStatus()</code>,
    <code>startServer()</code>/<code>stopServer()</code>
    feed both faces. MCP: <code>POST /mcp</code>.
    Write path: SOAP <code>announce</code> + admin revive/tele + realm lifecycle (local ops only).
  </footer>
</body>
</html>
"""

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
  ## Admin tab: realm lifecycle + ops escape hatches (not fair-play policy).
  let castList = ShadowArmyCast.join(", ")
  let stamped = now().format("yyyy-MM-dd HH:mm:ss")
  let serverPanel = renderServerPanel(server)
  result = &"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>The System — Admin</title>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <style>
    :root {{
      --bg: #0d1117; --panel: #161b22; --border: #30363d; --text: #e6edf3;
      --muted: #8b949e; --accent: #58a6ff; --loaded: #3fb950; --err: #f85149;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      background: var(--bg); color: var(--text); min-height: 100vh;
    }}
    header {{
      padding: 1.25rem 1.5rem; border-bottom: 1px solid var(--border); background: var(--panel);
    }}
    header h1 {{ margin: 0; font-size: 1.25rem; letter-spacing: 0.04em; color: var(--accent); }}
    header p {{ margin: 0.35rem 0 0; color: var(--muted); font-size: 0.9rem; }}
    .nav {{ display: flex; gap: 0.5rem; margin-top: 0.85rem; }}
    .nav a {{
      color: var(--muted); text-decoration: none; font-size: 0.85rem; font-weight: 600;
      padding: 0.3rem 0.7rem; border-radius: 6px; border: 1px solid transparent;
    }}
    .nav a:hover {{ color: var(--text); background: #21262d; }}
    .nav a.active {{ color: var(--accent); border-color: var(--border); background: #21262d; }}
    main {{ padding: 1.5rem; max-width: 1100px; margin: 0 auto; }}
    .panel {{
      background: var(--panel); border: 1px solid var(--border); border-radius: 8px;
      overflow: hidden; margin-bottom: 1.25rem;
    }}
    .panel-head {{
      display: flex; justify-content: space-between; align-items: center; gap: 0.75rem;
      padding: 0.75rem 1rem; border-bottom: 1px solid var(--border); flex-wrap: wrap;
    }}
    .panel-head h2 {{ margin: 0; font-size: 1rem; }}
    .panel-body {{ padding: 1rem; }}
    .admin-note {{ color: var(--muted); font-size: 0.9rem; line-height: 1.45; margin: 0 0 1rem; }}
    .admin-cast {{
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem;
    }}
    button.admin {{
      background: #f85149; color: #fff; border: none; border-radius: 6px;
      padding: 0.45rem 0.9rem; font-size: 0.85rem; font-weight: 600; cursor: pointer;
    }}
    button.admin:hover {{ filter: brightness(1.08); }}
    button.reload {{
      background: var(--accent); color: #0d1117; border: none; border-radius: 6px;
      padding: 0.45rem 0.9rem; font-size: 0.85rem; font-weight: 600; cursor: pointer;
    }}
    button.reload:hover {{ filter: brightness(1.08); }}
    .status {{
      display: inline-block; padding: 0.15rem 0.5rem; border-radius: 999px;
      font-size: 0.75rem; font-weight: 600;
    }}
    .status.alive {{ background: color-mix(in srgb, var(--loaded) 20%, transparent); color: var(--loaded); }}
    .status.offline {{ background: color-mix(in srgb, var(--muted) 25%, transparent); color: var(--muted); }}
    .status.busy {{ background: color-mix(in srgb, var(--accent) 20%, transparent); color: var(--accent); }}
    .server-line {{ display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }}
    .server-label {{ font-weight: 600; font-size: 0.9rem; }}
    .server-container {{
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.75rem;
    }}
    .server-action {{ margin-left: auto; }}
    .server-last {{ margin-top: 0.5rem; font-size: 0.8rem; }}
    .admin-ok {{ color: var(--loaded); font-size: 0.85rem; }}
    .admin-err {{ color: var(--err); font-size: 0.85rem; }}
    .admin-steps {{
      margin-top: 0.75rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.8rem; color: var(--muted); white-space: pre-wrap;
    }}
    .meta {{ color: var(--muted); font-size: 0.8rem; }}
    footer {{
      max-width: 1100px; margin: 1rem auto; padding: 0 1.5rem; color: var(--muted); font-size: 0.8rem;
    }}
    code {{ background: #21262d; padding: 0.1rem 0.35rem; border-radius: 4px; }}
  </style>
</head>
<body>
  <header>
    <h1>THE SYSTEM</h1>
    <p>Admin — local ops escape hatches (not fair-play policy)</p>
    <nav class="nav">
      <a href="/">Status</a>
      <a class="active" href="/admin">Admin</a>
    </nav>
  </header>
  <main>
    <div class="panel">
      <div class="panel-head">
        <h2>Realm server</h2>
        <span class="meta">operator up/down · characters and accounts persist across stop</span>
      </div>
      <div class="panel-body"
           id="server-panel"
           hx-get="/server"
           hx-trigger="every {PollSeconds}s"
           hx-swap="innerHTML">
{serverPanel}
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">
        <h2>Respawn shadow army</h2>
        <span class="meta">as of {escapeHtml(stamped)}</span>
      </div>
      <div class="panel-body">
        <p class="admin-note">
          Hard-reset the bot cast when corpse runs stall (ghost move masks, elevated death
          pockets, frozen frames). Runs SOAP <code>revive</code> +
          <code>tele name … {escapeHtml(ShadowArmyRespawnTele)}</code> +
          <code>repairitems</code> per seat. <strong>Not</strong> fair-play recovery —
          testing / ops only. Does not restart headless clients or brains.
          Same action from in-game advisor <strong>Admin → Respawn army</strong>
          (Murist only: <code>&lt;SA&gt; admin respawn_shadow_army</code>).
        </p>
        <p class="admin-note">
          Cast:
          <span class="admin-cast">{escapeHtml(castList)}</span>
          → <code>{escapeHtml(ShadowArmyRespawnTele)}</code>
        </p>
        <button class="admin"
                hx-post="/admin/respawn-shadow-army"
                hx-target="#admin-result"
                hx-swap="innerHTML"
                hx-confirm="Respawn Shadowfel, Igris, Tusk, Beru at Deathknell? (GM revive + tele)">
          Respawn shadow army
        </button>
      </div>
    </div>
    <div class="panel" style="margin-top:1rem;">
      <div class="panel-head">
        <h2>Teleport party to Murist</h2>
        <span class="meta">ops</span>
      </div>
      <div class="panel-body">
        <p class="admin-note">
          Pulls the bot cast to Murist's current DB position. Upserts
          <code>{escapeHtml(MuristMeetTeleName)}</code> in
          <code>game_tele</code>, reloads it, then
          <code>tele name &lt;cast&gt; {escapeHtml(MuristMeetTeleName)}</code>.
          <strong>Not</strong> fair-play. Same as MCP
          <code>tele_party_to_murist</code> and advisor
          <strong>Admin → Tele party to me</strong>.
        </p>
        <p class="admin-note">
          Cast:
          <span class="admin-cast">{escapeHtml(castList)}</span>
          → Murist live pos
        </p>
        <button class="admin"
                hx-post="/admin/tele-party-to-murist"
                hx-target="#admin-result"
                hx-swap="innerHTML"
                hx-confirm="Teleport Shadowfel, Igris, Tusk, Beru to Murist's position?">
          Teleport party to Murist
        </button>
        <div id="admin-result" style="margin-top:1rem;"></div>
      </div>
    </div>
  </main>
  <footer>
    Dispatch: <code>respawnShadowArmy()</code> /
    <code>telePartyToMurist()</code>
    · HTTP <code>/admin/*</code>
    · MCP · Murist <code>&lt;SA&gt; admin …</code>
  </footer>
</body>
</html>
"""

proc htmlHeaders(): mummyheaders.HttpHeaders =
  ## mummy/webby headers (not std/httpclient's HttpHeaders).
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = "text/html; charset=utf-8"

proc jsonHeaders(): mummyheaders.HttpHeaders =
  ## mummy/webby headers (not std/httpclient's HttpHeaders).
  result = mummyheaders.emptyHttpHeaders()
  result["Content-Type"] = "application/json; charset=utf-8"

proc queryWantsAll*(request: Request): bool =
  ## True when ?all=1 / all=true is present (show foundation seats).
  let v = request.queryParams["all"].toLowerAscii()
  result = v == "1" or v == "true" or v == "yes"

proc indexHandler(request: Request) {.gcsafe.} =
  ## GET / — full Status Window (server panel + roster + addon events).
  ## Renders with the realm DOWN too: roster degrades to an offline note and
  ## the Server panel offers Start (the whole point of the panel).
  try:
    var shadows: seq[Shadow] = @[]
    var events: seq[AddonEvent]
    var status: ServerStatus
    var rosterOffline = false
    let showAll = queryWantsAll(request)
    {.gcsafe.}:
      status = serverStatus()
      if status.running:
        try:
          shadows = filterShadows(listShadows(), includeFoundation = showAll)
        except CatchableError:
          # Container up but DB not answering yet (mid-boot): offline view.
          rosterOffline = true
      else:
        rosterOffline = true
      events = recentEvents(limit = 30)
    request.respond(200, htmlHeaders(),
      renderRosterPage(shadows, events,
        includeFoundation = showAll, rosterOffline = rosterOffline))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"<!DOCTYPE html><html><body><h1>Roster error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc rosterPartialHandler(request: Request) {.gcsafe.} =
  ## GET /roster — htmx fragment (table rows only). ?all=1 includes foundation.
  ## Realm down / DB unreachable → friendly offline row, not a red error.
  try:
    var shadows: seq[Shadow]
    let showAll = queryWantsAll(request)
    {.gcsafe.}:
      shadows = filterShadows(listShadows(), includeFoundation = showAll)
    request.respond(200, htmlHeaders(), renderRosterRows(shadows))
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
    var shadows: seq[Shadow]
    {.gcsafe.}:
      shadows = filterShadows(listShadows())
    request.respond(200, htmlHeaders(), renderRosterRows(shadows))
  except CatchableError:
    request.respond(200, htmlHeaders(), renderRosterOfflineRow())

proc botStartHandler(request: Request) {.gcsafe.} =
  ## POST /bots/start?name=<cast> — launch that seat, return roster rows.
  let name = request.queryParams["name"]
  {.gcsafe.}:
    discard startBotSeat(name)
  respondRosterRows(request)

proc botStopHandler(request: Request) {.gcsafe.} =
  ## POST /bots/stop?name=<cast> — stop that seat, return roster rows.
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
  ## POST /admin/respawn-shadow-army — GM revive + tele the bot cast.
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
  ## POST /admin/tele-party-to-murist — pin game_tele to Murist + tele cast.
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
        "dashboard": "/",
        "admin": "/admin",
        "roster_partial": "/roster",
        "events_partial": "/events",
        "server_partial": "/server",
        "server_start": "/server/start",
        "server_stop": "/server/stop",
        "bot_start": "/bots/start?name=<cast>",
        "bot_stop": "/bots/stop?name=<cast>",
        "reload": "/reload",
        "respawn_shadow_army": "/admin/respawn-shadow-army",
        "tele_party_to_murist": "/admin/tele-party-to-murist",
        "jsonrpc": "/mcp",
        "healthz": "/healthz"
      },
      "tools": [
        "list_shadows", "addon_events", "reload_addon", "send_announce",
        "respawn_shadow_army", "tele_party_to_murist",
        "server_status", "start_server", "stop_server",
        "start_bot", "stop_bot"
      ],
      "write_scope": "SOAP announce + admin revive/tele/tele-to-murist for fixed cast + realm lifecycle up/down + bot seat start/stop (local ops)"
    }
  request.respond(200, jsonHeaders(), $info)

proc registerMcpTools(server: McpServer) =
  ## Register MCP tools. Handlers call the same dispatch procs as the dashboard.
  let listTool = McpTool(
    name: "list_shadows",
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

  proc listShadowsHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same roster as the dashboard; returned as text + structuredContent.
    var includeFoundation = false
    if arguments != nil and arguments.kind == JObject and arguments.hasKey("include_foundation"):
      includeFoundation = arguments["include_foundation"].getBool(false)
    var shadows: seq[Shadow]
    {.gcsafe.}:
      shadows = filterShadows(listShadows(), includeFoundation = includeFoundation)
    # structuredContent must be a JObject per MCP/MCPort (not a bare array).
    let payload = %*{
      "shadows": shadowsToJson(shadows),
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
        "description": "Cast bot seat name: Shadowfel, Igris, Tusk, or Beru"
      }
    },
    "required": ["name"],
    "additionalProperties": false,
    "$schema": "http://json-schema.org/draft-07/schema#"
  }

  let startBotTool = McpTool(
    name: "start_bot",
    description: "Launch one cast bot seat (detached `make <seat>-bot`). Seat is ready when its nim_control socket (41114+slot) listens; check list_shadows control_up.",
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
    description: "Stop one cast bot seat (TERM the nim_control socket holder; the client logs out).",
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
  server.registerRichTool(listTool, listShadowsHandler)
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
  router.get("/", indexHandler)
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
  echo &"  Status:      GET  http://127.0.0.1:{HttpPort}/"
  echo &"  Admin:       GET  http://127.0.0.1:{HttpPort}/admin"
  echo &"  Events:      GET  http://127.0.0.1:{HttpPort}/events"
  echo &"  Server:      GET  http://127.0.0.1:{HttpPort}/server (POST /server/start /server/stop)"
  echo &"  Reload:      POST http://127.0.0.1:{HttpPort}/reload"
  echo &"  Respawn:     POST http://127.0.0.1:{HttpPort}/admin/respawn-shadow-army"
  echo &"  Tele party:  POST http://127.0.0.1:{HttpPort}/admin/tele-party-to-murist"
  echo &"  MCP:         POST http://127.0.0.1:{HttpPort}/mcp"
  echo &"  container:   {gameContainer()} (SYSTEM_MYSQL_CONTAINER to override)"
  echo &"  Chat.log:    {chatLogPath()} (SYSTEM_CHAT_LOG to override)"
  echo &"  upstream:    {upstreamDir()} (SYSTEM_UPSTREAM_DIR to override)"
  echo "  DB access:   docker exec + mariadb SELECT (read-only)"
  echo "  SOAP write:  announce + admin revive/tele (SYSTEM_SOAP_* )"
  echo "  lifecycle:   operator up/down via uv (async worker; Server panel)"
  server.serve(Port(HttpPort), "127.0.0.1")

when isMainModule:
  main()
