## The System — management server for the shadow army.
##
## One Nim binary, two faces on one mummy server:
##   HTTP dashboard (htmx)  GET /  GET /roster
##   MCP endpoint (MCPort)  POST /mcp
##
## Critical design rule: one dispatch path. `listShadows()` is the sole data
## producer; the htmx handlers render it and the MCP tool serializes it.

import
  std/[
    json, options, os, osproc, streams, strformat, strutils, times
  ],
  mummy, mummy/routers,
  jsony,
  mcport/mcp_core

const
  Version = "0.1.0"
  ServerName = "TheSystem"
  ## Dashboard + MCP share this port (not 8080 healthz / 8085 world / 3724 realmd).
  HttpPort = 7777
  ## htmx auto-refresh interval for the roster table body.
  PollSeconds = 3
  ## VMaNGOS credentials match Makefile `account` target (manage_coworld_accounts).
  DbUser = "mangos"
  DbPass = "mangos"
  DbName = "characters"
  ## Default compose container name for coworld-game. Override with SYSTEM_MYSQL_CONTAINER.
  DefaultGameContainer = "coworld-vmangos-coworld-game-1"
  ## SELECT-only projection of characters (VMaNGOS schema).
  RosterSql = "SELECT name, level, class, race, money, online FROM characters ORDER BY name"

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
  ## Resolve the coworld-game MariaDB container name.
  result = getEnv("SYSTEM_MYSQL_CONTAINER", DefaultGameContainer)

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

proc renderRosterPage*(shadows: seq[Shadow]): string =
  ## Full Roster Status Window (htmx + auto-poll).
  let rows = renderRosterRows(shadows)
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
    }}
    .panel-head {{
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
    }}
    .panel-head h2 {{ margin: 0; font-size: 1rem; }}
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
    .status {{
      display: inline-block;
      padding: 0.15rem 0.5rem;
      border-radius: 999px;
      font-size: 0.75rem;
      font-weight: 600;
    }}
    .status.online {{ background: color-mix(in srgb, var(--online) 20%, transparent); color: var(--online); }}
    .status.offline {{ background: color-mix(in srgb, var(--offline) 25%, transparent); color: var(--offline); }}
    .empty {{ color: var(--muted); text-align: center; padding: 2rem; }}
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
    <p>Shadow army Status Window — local realm roster (read-only)</p>
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
  </main>
  <footer>
    One dispatch path: <code>listShadows()</code> feeds this page and MCP tool
    <code>list_shadows</code>. MCP: <code>POST /mcp</code> on this port.
    DB: SELECT only via docker exec.
  </footer>
</body>
</html>
"""

proc htmlHeaders(): HttpHeaders =
  result = default(HttpHeaders)
  result["Content-Type"] = "text/html; charset=utf-8"

proc jsonHeaders(): HttpHeaders =
  result = default(HttpHeaders)
  result["Content-Type"] = "application/json; charset=utf-8"

proc indexHandler(request: Request) {.gcsafe.} =
  ## GET / — full Roster page.
  try:
    var shadows: seq[Shadow]
    {.gcsafe.}:
      shadows = listShadows()
    request.respond(200, htmlHeaders(), renderRosterPage(shadows))
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
        "jsonrpc": "/mcp",
        "healthz": "/healthz"
      },
      "tools": ["list_shadows"],
      "read_only": true
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

  # registerRichTool: plain registerTool only surfaces getStr() on JsonNode
  # (arrays become empty text). Monky uses the rich path for the same reason.
  server.registerRichTool(listTool, listShadowsHandler)

proc main() =
  ## Boot The System: one mummy server, dashboard + MCP faces.
  gMcpServer = newMcpServer(ServerName, Version)
  registerMcpTools(gMcpServer)

  var router: Router
  router.get("/", indexHandler)
  router.get("/roster", rosterPartialHandler)
  router.get("/healthz", healthHandler)
  router.get("/server-info", serverInfoHandler)
  router.post("/mcp", mcpHandler)

  let server = newServer(router)
  echo &"{ServerName} v{Version} listening on http://127.0.0.1:{HttpPort}"
  echo &"  Roster:      GET  http://127.0.0.1:{HttpPort}/"
  echo &"  MCP:         POST http://127.0.0.1:{HttpPort}/mcp"
  echo &"  container:   {gameContainer()} (SYSTEM_MYSQL_CONTAINER to override)"
  echo "  DB access:   docker exec + mariadb SELECT (read-only)"
  server.serve(Port(HttpPort), "127.0.0.1")

when isMainModule:
  main()
