# The System

Management server for the wow-shadow-army: one Nim binary, many interfaces.

| Interface | Path | Role |
|---|---|---|
| HTTP dashboard | `GET /` | htmx Status tab (roster + addon events; offline-safe) |
| Admin tab | `GET /admin` | realm Server panel (Start/Stop) + ops escape hatches |
| Roster partial | `GET /roster` | htmx fragment (roster table rows) |
| Events partial | `GET /events` | htmx fragment (addon event rows) |
| Server partial | `GET /server` | htmx fragment (realm status + Start/Stop buttons) |
| Start realm | `POST /server/start` | queue upstream operator `up` (async worker) |
| Stop realm | `POST /server/stop` | queue upstream operator `down` (volumes persist) |
| Start bot | `POST /bots/start?name=<seat>` | detached `make <seat>-bot` (roster Bot column) |
| Stop bot | `POST /bots/stop?name=<seat>` | TERM the seat's nim_control holder |
| Reload | `POST /reload` | SOAP `announce <SYS> reload` + wait for `<SA> loaded` |
| Respawn army | `POST /admin/respawn-shadow-army` | SOAP revive + tele Deathknell for bot seats |
| Tele party → Murist | `POST /admin/tele-party-to-murist` | Pin `game_tele` to Murist + tele bot seats |
| Addon admin bus | Chat.log `<SA> admin …` (Murist) | Same write procs as Admin tab / MCP |
| MCP | `POST /mcp` | MCPort JSON-RPC tools (see below) |
| Health | `GET /healthz` | process liveness |
| Info | `GET /server-info` | MCP metadata |

MCP tools (same dispatch procs as the dashboard):

| Tool | Dispatch | Role |
|---|---|---|
| `list_characters` | `listCharacters()` | realm roster + XP (SELECT) |
| `addon_events` | `recentEvents(limit, kind)` | Chat.log ring buffer |
| `reload_addon` | `reloadAddon()` | SOAP reload loop |
| `send_announce` | `announceInGame(text)` | broadcast system message |
| `respawn_shadow_army` | `respawnShadowArmy()` | admin revive + tele Deathknell (ops only) |
| `tele_party_to_murist` | `telePartyToMurist()` | pin meet tele to Murist + tele bot seats (ops only) |
| `server_status` | `serverStatus()` | realm container up/down + lifecycle op state |
| `start_server` | `startServer()` | queue operator `up`; poll `server_status` for done |
| `stop_server` | `stopServer()` | queue operator `down`; characters/accounts persist |
| `start_bot` | `startBotSeat(name)` | launch a bot seat; ready when `control_up` flips |
| `stop_bot` | `stopBotSeat(name)` | stop a bot seat (client logs out) |

Design source: `coworld-playbook/games/solo-leveling.md` → **The System (management server)**.

## Run

From the repo root (`wow-shadow-army`):

```sh
make system
# or:
nim r system/system_server.nim
```

Listens on **http://127.0.0.1:7777** (chosen to avoid realmd 3724, healthz 8080, world 8085, MariaDB 3307).

Works with the realm **up or down**: when the game container is stopped the
Status roster degrades to an offline note pointing at the Admin tab, where the
Server panel offers **Start server** (operator `up` — same path as
`make start-server`, run by an async worker so the page never blocks). Human
workflow: run the client + this dashboard; realm lifecycle goes through the
dashboard. `make system` passes the Makefile's `UPSTREAM` as
`SYSTEM_UPSTREAM_DIR` so the operator checkout never depends on cwd guessing.

Optional env:

| Env | Default | Meaning |
|---|---|---|
| `SYSTEM_MYSQL_CONTAINER` | `coworld-vmangos-coworld-game-1` | docker container for MariaDB + SOAP IP |
| `SYSTEM_CHAT_LOG` | `../coworld-vanilla-wow/local_data/coworld-run/logs/Chat.log` (absolute from cwd) | VMaNGOS Chat.log path to tail |
| `SYSTEM_UPSTREAM_DIR` | `../coworld-vanilla-wow` (absolute from cwd) | upstream checkout holding the compose operator |
| `SYSTEM_SOAP_URL` | `http://<game-bridge-ip>:7878/` (via `docker inspect`) | gsoap endpoint |
| `SYSTEM_SOAP_USER` | `system` | SOAP Basic auth user |
| `SYSTEM_SOAP_PASS` | `shadowsoap` | SOAP Basic auth password |

## Dashboard

Open http://127.0.0.1:7777/

Tabs in the header: **Status** | **Admin**.

- **Realm server** (Admin, top panel) — realm pill (Running / Stopped / Starting… / Stopping…) + **Start server** / **Stop server** buttons. Lifecycle ops run the upstream operator (`up` / `down`) in a background worker; the panel polls `GET /server` and shows the last op's ok/FAIL with output tail on hover. Stop keeps DB volumes (characters/accounts persist).
- **Bot column** (Status roster) — per-seat **Start**/**Stop** buttons for the launchable bot seats (Shadowfel/Igris/Tusk/Beru; Murist and foundation seats show —). Start runs `make <seat>-bot` detached, appending to `local_data/<seat>-bot.log`; the button flips to Stop when the seat's nim_control socket comes up. Stop TERMs the socket holder (clean client logout). Offline seats show a terse "Off" in the Seat column — detail lives in tooltips.
- **Roster** (Status) — main characters view by default (hides foundation `Bot*` / Nightsun / Cowcam). Toggle **Show foundation seats** (or `?all=1`) for the full realm. Order: Murist → Shadowfel → Igris → Tusk → Beru, then others. Columns: name · level · XP · **HP/MP** · class · **zone** · **pos** · gold · **life** · **seat** (realm online + nim_control port up/down). Panel head shows army strip (`N online · alive/ghost/dead · ctrl k/n`). Polls `GET /roster` every few seconds via htmx. Zone from `characters.zone` → `area_template`; ghost = `character_flags & 0x2000`. HP/MP from health + class stats + power fields. Pos = `position_x/y`. Seat control probes `127.0.0.1:41114+slot` for bot seats.
- **Addon events** (Status) — live ring of parsed `<SA>` / `<ShadowArmy>` lines from Chat.log. Table body polls `GET /events`. **Reload addon** posts to `POST /reload`.
- **Admin** (`GET /admin`) — local ops only. **Respawn shadow army** runs SOAP `revive` + `tele name … Deathknell` + `repairitems` for Shadowfel, Igris, Tusk, Beru. This is **not** fair-play corpse recovery; use it when ghost/corpse runs stall in testing. Does not restart headless clients or brains. The vanilla advisor **Admin** panel requests the same action via `/say` (`<SA> admin respawn_shadow_army`); only **Murist** is accepted.

## Reload loop

Closes the System ↔ addon circuit without out-of-band collusion:

1. System SOAP: `announce <SYS> reload` (GM console command, no leading dot).
2. Every client receives `CHAT_MSG_SYSTEM`; the addon parses the `<SYS>` marker and runs a whitelisted verb (`reload` → `ReloadUI()`).
3. Freshly loaded addon emits `<SA> loaded rev=N` over `/say`.
4. VMaNGOS appends the line to Chat.log; The System's tailer parses it into the ring buffer.
5. `reloadAddon()` returns ok when it sees a new `kind == "loaded"` event after the announce snapshot (6s timeout).

Other whitelisted verbs the addon may accept: `ping`, `status`, `say <text>` (addon-side only; System only sends via `announce`).

## MCP

Same port, MCPort over HTTP. Example: list tools and call `list_characters`.

```sh
# Initialize (many clients skip this; The System is always ready)
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

# List tools
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call list_characters
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_characters","arguments":{}}}'

# Recent addon events
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"addon_events","arguments":{"limit":20}}}'
```

## Scoped write exception

The System is an **observer first**. Roster data is `SELECT`-only against the `characters` DB (no INSERT/UPDATE/DELETE).

Write paths (dedicated SOAP account `SYSTEM_SOAP_USER` / `SYSTEM_SOAP_PASS`):

1. **Announce** — `announce <text>` for system chat / addon `<SYS>` verbs (`reload`, `ping`, `status`, `say …`).
2. **Admin respawn** (Admin tab / MCP `respawn_shadow_army` / Murist `<SA> admin respawn_shadow_army`) — `revive`, `tele name`, `repairitems` for the fixed bot seats. Not available to policy brains; local testing escape hatch when fair-play corpse runs fail.
3. **Admin tele party to Murist** (Admin tab / MCP `tele_party_to_murist` / Murist `<SA> admin tele_party_to_murist`) — upsert `game_tele` `SA_MURIST_MEET` from Murist's DB coords, `reload game_tele`, `tele name` each bot seat. Ops regroup only.

No free-form GM command surface, no database pokes for progress, no out-of-band seat collusion.

Provision the SOAP account with `make soap-account` (SRP row + `account_access` gmlevel 6 — see docs/the-system-loop.md for why both, and why a realm restart is needed after first creation). SOAP itself is enabled through the operator config overrides in `make server-logging`.

MariaDB credentials match the Makefile `account` target (`mangos`/`mangos` inside the game container).

## One dispatch path, many interfaces

```
listCharacters()       ──►  htmx roster     / MCP list_characters
recentEvents()         ──►  htmx events     / MCP addon_events
reloadAddon()          ──►  htmx POST /reload / MCP reload_addon
announceInGame()       ──►  MCP send_announce (and reloadAddon internals)
respawnShadowArmy()    ──►  htmx Admin tab / MCP / Murist admin chat
telePartyToMurist()    ──►  htmx Admin tab / MCP / Murist admin chat
reloadAddon()          ──►  htmx Reload / MCP / Murist admin chat
```

**Rule for future pages/tools:** add a single data/action proc first; wire the dashboard button, the MCP tool, and (if human-seat useful) the addon admin chat verb to that same proc. Never let the interfaces diverge.

## Stack choices

| Piece | Choice |
|---|---|
| HTTP | mummy (shared router for dashboard + MCP) |
| MCP | MCPort (`McpServer.handleRequest` on `POST /mcp`) |
| UI | htmx (CDN) + server-rendered HTML |
| nimponents | on the path for future custom elements; Roster is SSR fragments for now |
| DB access | **`docker exec … mariadb`** — same reliable path as `make account`. No host mysql client; avoids a Nim MySQL driver. Documented intentional tradeoff. |
| Chat.log | background `Thread` tailer → ring buffer (cap 1000) |
| SOAP | `std/httpclient` POST to gsoap `urn:MaNGOS` / `executeCommand` |

## Deps / nimby footgun

Paths come from this repo's `nim.cfg` + Softmax parent `nim.cfg` (mummy, jsony, …) and `~/.nimby/pkgs/MCPort`.

**Do not** run plain `nimby sync` from Softmax workspace mode — it mutates sibling checkouts. Deps are already present.

## Tests

`make test` = Lua unit suite + Nim unit tier + compile/parse smoke
(`make test-smoke`: `luac -p` all addon/tool Lua, `nim check` all Nim
entrypoints). Nim legs soft-skip on hosts without nim, so lua-only CI stays
green.

Nim unit tests directly (no network, no docker, no realm):

```sh
for t in system/tests/test_*.nim; do nim r --hints:off --warnings:off "$t"; done
# or:
make test-nim
```
