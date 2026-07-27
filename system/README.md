# The System

Management server for the wow-shadow-army: one Nim binary, two faces.

| Face | Path | Role |
|---|---|---|
| HTTP dashboard | `GET /` | htmx Status tab (roster + addon events) |
| Admin tab | `GET /admin` | ops escape hatches (GM revive/tele cast) |
| Roster partial | `GET /roster` | htmx fragment (roster table rows) |
| Events partial | `GET /events` | htmx fragment (addon event rows) |
| Reload | `POST /reload` | SOAP `announce <SYS> reload` + wait for `<SA> loaded` |
| Respawn army | `POST /admin/respawn-shadow-army` | SOAP revive + tele Deathknell for bot cast |
| MCP | `POST /mcp` | MCPort JSON-RPC tools (see below) |
| Health | `GET /healthz` | process liveness |
| Info | `GET /server-info` | MCP metadata |

MCP tools (same dispatch procs as the dashboard):

| Tool | Dispatch | Role |
|---|---|---|
| `list_shadows` | `listShadows()` | realm roster + XP (SELECT) |
| `addon_events` | `recentEvents(limit, kind)` | Chat.log ring buffer |
| `reload_addon` | `reloadAddon()` | SOAP reload loop |
| `send_announce` | `announceInGame(text)` | broadcast system message |
| `respawn_shadow_army` | `respawnShadowArmy()` | admin revive + tele Deathknell (ops only) |

Design source: `coworld-playbook/games/solo-leveling.md` → **The System (management server)**.

## Run

From the repo root (`wow-shadow-army`):

```sh
make system
# or:
nim r system/system_server.nim
```

Listens on **http://127.0.0.1:7777** (chosen to avoid realmd 3724, healthz 8080, world 8085, MariaDB 3307).

Requires a running local realm (`make start-server`) so the game container can answer SQL / SOAP.

Optional env:

| Env | Default | Meaning |
|---|---|---|
| `SYSTEM_MYSQL_CONTAINER` | `coworld-vmangos-coworld-game-1` | docker container for MariaDB + SOAP IP |
| `SYSTEM_CHAT_LOG` | `../coworld-vanilla-wow/local_data/coworld-run/logs/Chat.log` (absolute from cwd) | VMaNGOS Chat.log path to tail |
| `SYSTEM_SOAP_URL` | `http://<game-bridge-ip>:7878/` (via `docker inspect`) | gsoap endpoint |
| `SYSTEM_SOAP_USER` | `system` | SOAP Basic auth user |
| `SYSTEM_SOAP_PASS` | `shadowsoap` | SOAP Basic auth password |

## Dashboard

Open http://127.0.0.1:7777/

Tabs in the header: **Status** | **Admin**.

- **Roster** (Status) — cast view by default (hides foundation `Bot*` / Nightsun / Cowcam). Toggle **Show foundation seats** (or `?all=1`) for the full realm. Order: Murist → Shadowfel → Igris → Tusk → Beru, then others. Columns: name · level · XP · **HP/MP** · class · **zone** · **pos** · gold · **life** · **seat** (realm online + nim_control port up/down). Panel head shows army strip (`N online · alive/ghost/dead · ctrl k/n`). Polls `GET /roster` every few seconds via htmx. Zone from `characters.zone` → `area_template`; ghost = `character_flags & 0x2000`. HP/MP from health + class stats + power fields. Pos = `position_x/y`. Seat control probes `127.0.0.1:41114+slot` for bot seats.
- **Addon events** (Status) — live ring of parsed `<SA>` / `<ShadowArmy>` lines from Chat.log. Table body polls `GET /events`. **Reload addon** posts to `POST /reload`.
- **Admin** (`GET /admin`) — local ops only. **Respawn shadow army** runs SOAP `revive` + `tele name … Deathknell` + `repairitems` for Shadowfel, Igris, Tusk, Beru. This is **not** fair-play corpse recovery; use it when ghost/corpse runs stall in testing. Does not restart headless clients or brains.

## Reload loop

Closes the System ↔ addon circuit without out-of-band collusion:

1. System SOAP: `announce <SYS> reload` (GM console command, no leading dot).
2. Every client receives `CHAT_MSG_SYSTEM`; the addon parses the `<SYS>` marker and runs a whitelisted verb (`reload` → `ReloadUI()`).
3. Freshly loaded addon emits `<SA> loaded rev=N` over `/say`.
4. VMaNGOS appends the line to Chat.log; The System's tailer parses it into the ring buffer.
5. `reloadAddon()` returns ok when it sees a new `kind == "loaded"` event after the announce snapshot (6s timeout).

Other whitelisted verbs the addon may accept: `ping`, `status`, `say <text>` (addon-side only; System only sends via `announce`).

## MCP

Same port, MCPort over HTTP. Example: list tools and call `list_shadows`.

```sh
# Initialize (many clients skip this; The System is always ready)
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

# List tools
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call list_shadows
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_shadows","arguments":{}}}'

# Recent addon events
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"addon_events","arguments":{"limit":20}}}'
```

## Scoped write exception

The System is an **observer first**. Roster data is `SELECT`-only against the `characters` DB (no INSERT/UPDATE/DELETE).

Write paths (dedicated SOAP account `SYSTEM_SOAP_USER` / `SYSTEM_SOAP_PASS`):

1. **Announce** — `announce <text>` for system chat / addon `<SYS>` verbs (`reload`, `ping`, `status`, `say …`).
2. **Admin respawn** (explicit Admin tab / `respawn_shadow_army` only) — `revive`, `tele name`, `repairitems` for the fixed cast list. Not available to policy brains; local testing escape hatch when fair-play corpse runs fail.

No free-form GM command surface, no database pokes for progress, no out-of-band seat collusion.

Provision the SOAP account with `make soap-account` (SRP row + `account_access` gmlevel 6 — see docs/the-system-loop.md for why both, and why a realm restart is needed after first creation). SOAP itself is enabled through the operator config overrides in `make server-logging`.

MariaDB credentials match the Makefile `account` target (`mangos`/`mangos` inside the game container).

## One dispatch path, two faces

```
listShadows()          ──►  htmx roster     / MCP list_shadows
recentEvents()         ──►  htmx events     / MCP addon_events
reloadAddon()          ──►  htmx POST /reload / MCP reload_addon
announceInGame()       ──►  MCP send_announce (and reloadAddon internals)
respawnShadowArmy()    ──►  htmx Admin tab  / MCP respawn_shadow_army
```

**Rule for future pages/tools:** add a single data/action proc first; wire the dashboard button and the MCP tool to that same proc. Never let the two faces diverge.

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

`make test` stays Lua-only (no nim required).

Optional Nim unit tests (no network, no docker, no realm):

```sh
for t in system/tests/test_*.nim; do nim r --hints:off --warnings:off "$t"; done
# or:
make test-nim
```
