## The System — management server for the shadow army.
##
## One Nim binary, two faces on one mummy server:
##   HTTP dashboard (htmx)  GET /  GET /roster  GET /events  POST /reload
##   MCP endpoint (MCPort)  POST /mcp
##
## Critical design rule: one dispatch path. Each capability is one data/action
## proc; the htmx handlers render it and the MCP tools serialize it.
##   listShadows()      — roster (SELECT via docker exec)
##   recentEvents()     — addon Chat.log ring buffer
##   reloadAddon()      — SOAP announce <SYS> reload + wait for <SA> loaded
##   announceInGame()   — SOAP announce <text>

import
  std/[
    base64, httpclient, json, locks, options, os, osproc, streams,
    strformat, strutils, times
  ],
  mummy, mummy/routers,
  webby/httpheaders as mummyheaders,
  jsony,
  mcport/mcp_core

const
  Version = "0.2.0"
  ServerName = "TheSystem"
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
  ## SELECT-only projection of characters (VMaNGOS schema).
  RosterSql = "SELECT name, level, class, race, money, online FROM characters ORDER BY name"
  ## Live addon events only; history stays in the log file.
  EventRingCap = 1000
  ## How often the Chat.log tailer polls for new bytes.
  TailerPollMs = 500
  ## SOAP HTTP timeout (gsoap can be slow on a cold container).
  SoapTimeoutMs = 10_000
  ## Default relative path to VMaNGOS Chat.log (resolved absolute from cwd).
  DefaultChatLogRel = "../coworld-vanilla-wow/local_data/coworld-run/logs/Chat.log"
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

initLock(gEventLock)

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

proc parseRosterTsv*(tsv: string): seq[Shadow] =
  ## Parse mariadb -N -B TSV into Shadow rows.
  result = @[]
  for line in tsv.splitLines():
    let row = line.strip()
    if row.len == 0:
      continue
    let cols = row.split('\t')
    if cols.len < 6:
      raise newException(ValueError, &"expected 6 TSV columns, got {cols.len}: {row}")
    let classId = cols[2].parseInt()
    let raceId = cols[3].parseInt()
    let money = cols[4].parseInt()
    let online = cols[5].parseInt() != 0
    result.add(Shadow(
      name: cols[0],
      level: cols[1].parseInt(),
      classId: classId,
      className: className(classId),
      raceId: raceId,
      raceName: raceName(raceId),
      money: money,
      gold: formatGold(money),
      online: online
    ))

proc listShadows*(): seq[Shadow] =
  ## Single dispatch path: all faces (htmx + MCP) get roster data from here.
  result = parseRosterTsv(fetchRosterTsv())

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
      "online": s.online
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

proc pushParsedLine(line: string) {.gcsafe.} =
  ## Parse a complete Chat.log line and append if it is an addon event.
  let parsed = parseAddonEvent(line)
  if parsed.isNone:
    return
  {.gcsafe.}:
    withLock gEventLock:
      discard appendAddonEvent(gEvents, gNextEventId, parsed.get)

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
    return extracted.get
  result = response.body

proc announceInGame*(text: string): string =
  ## Broadcast a system message to all players (`announce <text>`).
  result = gmCommand("announce " & text)

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

proc renderRosterRows*(shadows: seq[Shadow]): string =
  ## htmx partial: `<tr>` rows for the roster table body.
  if shadows.len == 0:
    return """<tr><td colspan="6" class="empty">No characters on the local realm.</td></tr>"""
  result = ""
  for s in shadows:
    let statusClass = if s.online: "online" else: "offline"
    let statusText = if s.online: "Online" else: "Offline"
    result.add(&"""
      <tr>
        <td class="name">{escapeHtml(s.name)}</td>
        <td>{s.level}</td>
        <td>{escapeHtml(s.className)}</td>
        <td>{escapeHtml(s.raceName)}</td>
        <td class="gold">{escapeHtml(s.gold)}</td>
        <td><span class="status {statusClass}">{statusText}</span></td>
      </tr>
""")

proc renderRosterPage*(shadows: seq[Shadow], events: seq[AddonEvent]): string =
  ## Full Status Window (htmx + auto-poll): roster + addon events.
  let rows = renderRosterRows(shadows)
  let eventRows = renderEventRows(events)
  let stamped = now().format("yyyy-MM-dd HH:mm:ss")
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
    main {{ padding: 1.5rem; max-width: 960px; margin: 0 auto; }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
      margin-bottom: 1.25rem;
    }}
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
      padding: 0.65rem 1rem;
      border-bottom: 1px solid var(--border);
      font-size: 0.95rem;
    }}
    th {{ color: var(--muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; }}
    tr:last-child td {{ border-bottom: none; }}
    td.name {{ font-weight: 600; }}
    td.gold {{ color: var(--gold); font-variant-numeric: tabular-nums; }}
    td.payload {{ color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem; }}
    .status {{
      display: inline-block;
      padding: 0.15rem 0.5rem;
      border-radius: 999px;
      font-size: 0.75rem;
      font-weight: 600;
    }}
    .status.online {{ background: color-mix(in srgb, var(--online) 20%, transparent); color: var(--online); }}
    .status.offline {{ background: color-mix(in srgb, var(--offline) 25%, transparent); color: var(--offline); }}
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
    button.reload {{
      background: var(--accent);
      color: #0d1117;
      border: none;
      border-radius: 6px;
      padding: 0.35rem 0.75rem;
      font-size: 0.8rem;
      font-weight: 600;
      cursor: pointer;
    }}
    button.reload:hover {{ filter: brightness(1.08); }}
    .reload-ok {{ color: var(--loaded); font-size: 0.8rem; }}
    .reload-timeout {{ color: var(--err); font-size: 0.8rem; }}
    footer {{
      max-width: 960px;
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
  </header>
  <main>
    <div class="panel">
      <div class="panel-head">
        <h2>Roster</h2>
        <span class="meta" id="stamp">as of {escapeHtml(stamped)} · refresh every {PollSeconds}s</span>
      </div>
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Level</th>
            <th>Class</th>
            <th>Race</th>
            <th>Gold</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody id="roster"
               hx-get="/roster"
               hx-trigger="every {PollSeconds}s"
               hx-swap="innerHTML">
{rows}
        </tbody>
      </table>
    </div>
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
  </main>
  <footer>
    One dispatch path per capability:
    <code>listShadows()</code>, <code>recentEvents()</code>, <code>reloadAddon()</code>
    feed both faces. MCP: <code>POST /mcp</code>.
    Write path: SOAP <code>announce</code> only (whitelisted addon verbs).
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

proc indexHandler(request: Request) {.gcsafe.} =
  ## GET / — full Status Window (roster + addon events).
  try:
    var shadows: seq[Shadow]
    var events: seq[AddonEvent]
    {.gcsafe.}:
      shadows = listShadows()
      events = recentEvents(limit = 30)
    request.respond(200, htmlHeaders(), renderRosterPage(shadows, events))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"<!DOCTYPE html><html><body><h1>Roster error</h1><pre>{escapeHtml(e.msg)}</pre></body></html>")

proc rosterPartialHandler(request: Request) {.gcsafe.} =
  ## GET /roster — htmx fragment (table rows only).
  try:
    var shadows: seq[Shadow]
    {.gcsafe.}:
      shadows = listShadows()
    request.respond(200, htmlHeaders(), renderRosterRows(shadows))
  except Exception as e:
    request.respond(500, htmlHeaders(),
      &"""<tr><td colspan="6" class="empty">error: {escapeHtml(e.msg)}</td></tr>""")

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
        "roster_partial": "/roster",
        "events_partial": "/events",
        "reload": "/reload",
        "jsonrpc": "/mcp",
        "healthz": "/healthz"
      },
      "tools": ["list_shadows", "addon_events", "reload_addon", "send_announce"],
      "write_scope": "SOAP announce only (whitelisted addon verbs via <SYS>)"
    }
  request.respond(200, jsonHeaders(), $info)

proc registerMcpTools(server: McpServer) =
  ## Register MCP tools. Handlers call the same dispatch procs as the dashboard.
  let listTool = McpTool(
    name: "list_shadows",
    description: "List characters on the local VMaNGOS realm (name, level, class, race, gold, online). Read-only.",
    inputSchema: %*{
      "type": "object",
      "properties": newJObject(),
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc listShadowsHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
    ## Same roster as the dashboard; returned as text + structuredContent.
    discard arguments
    var shadows: seq[Shadow]
    {.gcsafe.}:
      shadows = listShadows()
    # structuredContent must be a JObject per MCP/MCPort (not a bare array).
    let payload = %*{"shadows": shadowsToJson(shadows)}
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

  # registerRichTool: plain registerTool only surfaces getStr() on JsonNode
  # (arrays become empty text). Monky uses the rich path for the same reason.
  server.registerRichTool(listTool, listShadowsHandler)
  server.registerRichTool(eventsTool, addonEventsHandler)
  server.registerRichTool(reloadTool, reloadAddonHandler)
  server.registerRichTool(announceTool, sendAnnounceHandler)

proc main() =
  ## Boot The System: Chat.log tailer + one mummy server (dashboard + MCP).
  gMcpServer = newMcpServer(ServerName, Version)
  registerMcpTools(gMcpServer)
  startChatLogTailer()

  var router: Router
  router.get("/", indexHandler)
  router.get("/roster", rosterPartialHandler)
  router.get("/events", eventsPartialHandler)
  router.post("/reload", reloadHandler)
  router.get("/healthz", healthHandler)
  router.get("/server-info", serverInfoHandler)
  router.post("/mcp", mcpHandler)

  let server = newServer(router)
  echo &"{ServerName} v{Version} listening on http://127.0.0.1:{HttpPort}"
  echo &"  Roster:      GET  http://127.0.0.1:{HttpPort}/"
  echo &"  Events:      GET  http://127.0.0.1:{HttpPort}/events"
  echo &"  Reload:      POST http://127.0.0.1:{HttpPort}/reload"
  echo &"  MCP:         POST http://127.0.0.1:{HttpPort}/mcp"
  echo &"  container:   {gameContainer()} (SYSTEM_MYSQL_CONTAINER to override)"
  echo &"  Chat.log:    {chatLogPath()} (SYSTEM_CHAT_LOG to override)"
  echo "  DB access:   docker exec + mariadb SELECT (read-only)"
  echo "  SOAP write:  announce only (SYSTEM_SOAP_URL / USER / PASS)"
  server.serve(Port(HttpPort), "127.0.0.1")

when isMainModule:
  main()
