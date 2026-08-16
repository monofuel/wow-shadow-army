# The System

Management server for the wow-shadow-army: one Nim binary, many interfaces.

| Interface | Path | Role |
|---|---|---|
| Army tab | `GET /` / `GET /army` | roster (offline-safe) |
| Murist tab | `GET /murist` | human seat metrics + Murist events |
| Inventory tab | `GET /inventory` | realm-wide bags, item-centric (characters DB) |
| Advisor tab | `GET /advisor` | addon event tail + reload |
| Admin tab | `GET /admin` | realm Start/Stop + ops buttons |
| Traverse tab | `GET /traverse` | Kalimdor telemetry + PoL + hosted replays |
| Start local traverse | `POST /traverse/pol/start` | desert-checkpoint local bot (`make traverse-pol` + goal) |
| Stop local traverse | `POST /traverse/pol/stop` | kill process tree + traverse containers |


| Seat watch partial | `GET /seats` | htmx fragment (seat babysitter panel) |
| Bags partial | `GET /murist/inventory` | htmx fragment (Murist inventory panel) |
| Inventory partial | `GET /inventory/all` | htmx fragment (Inventory tab body; `?force=1` skips the 30s cache) |
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
| Inventory JSON | `GET /inventory.json` | realm bags as JSON (items + per-character); `?force=1` skips the 30s cache |

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
| `seat_watch` | `seatWatchStatus()` | babysitter view for the whole seat roster (state, heartbeat age, restarts, alerts, `scaled`) |
| `character_inventory` | `characterInventory(name)` | latest-known bags from the chat bus + item join |
| `request_inventory` | `requestInventorySnapshot(name)` | announce `<SYS> inv?` for a fresh snapshot |

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
Army roster degrades to an offline note pointing at the Admin tab, where the
Realm panel **Start server** / **Stop server** call `tools/realm_op.sh` (same
entrypoint as `make start-server` / `make stop-server`), run by an async worker
so the page never blocks. That wrapper discovers `docker_vmangos_server.py`
under the upstream checkout and adds `--build` when the local game image is
missing or lacks VMaNGOS feature-metadata labels — so upstream layout moves and
image rebuilds do not require dashboard code edits. Human workflow: run the
client + this dashboard; realm lifecycle goes through the dashboard.
`make system` / `wow-system` pass `SYSTEM_UPSTREAM_DIR` so the checkout never
depends on cwd guessing.

Optional env:

| Env | Default | Meaning |
|---|---|---|
| `SYSTEM_MYSQL_CONTAINER` | `coworld-vmangos-coworld-game-1` | docker container for MariaDB + SOAP IP |
| `SYSTEM_CHAT_LOG` | `../coworld-vanilla-wow/local_data/coworld-run/logs/Chat.log` (absolute from cwd) | VMaNGOS Chat.log path to tail |
| `SYSTEM_UPSTREAM_DIR` | `../coworld-vanilla-wow` (absolute from cwd) | upstream checkout holding the compose operator |
| `SYSTEM_SOAP_URL` | `http://<game-bridge-ip>:7878/` (via `docker inspect`) | gsoap endpoint |
| `SYSTEM_SOAP_USER` | `system` | SOAP Basic auth user |
| `SYSTEM_SOAP_PASS` | `shadowsoap` | SOAP Basic auth password |
| `SYSTEM_SEAT_BABYSITTER` | `1` | `0`/`off` makes the seat watch observe-only (no auto-restart) |
| `SYSTEM_SEAT_STALE_SEC` | `90` | wedge threshold for a seat's `status.json` |
| `SYSTEM_HTTP_PORT` | `7777` | listen port; only for an isolated test instance beside the live one |

## Dashboard

Open http://127.0.0.1:7777/ (aliases `/army`).

Tabs in the header: **Army** | **Murist** | **Advisor** | **Admin**.

- **Army** (`GET /army`) — roster only (hides foundation `Bot*` / Nightsun / Cowcam). Order: Murist → Shadowfel → Igris → Tusk → Beru, then others. Columns: name · level · XP · **HP/MP** · class · **zone** · **pos** · gold · **life** · **seat** · **bot** Start/Stop. Panel head shows army strip (`N online · alive/ghost/dead · ctrl k/n`). Polls `GET /roster` every few seconds via htmx. MCP `list_characters` still accepts `include_foundation=true` for the full realm.
- **Army → Seat watch** — babysitter row per home seat, **whole fleet**: the four dedicated seats first, then every row of `tools/data/home_army_roster.tsv`. Light (green live / amber starting / grey stopped / **red wedged**), heartbeat age, auto-restarts this hour, last action, wedge evidence file. Panel head counts `N/M live · X wedged`. Polls `GET /seats`; a seat that burned its restart budget shows a persistent red alert banner. See "Seat babysitter" below.
- **Murist** (`GET /murist`) — human seat snapshot (level, class, race, gold, zone, pos, XP, vitals, life/online) + **quest log** (unrewarded: complete/active/failed + objective progress) + **bags** (chat-bus inventory: item, id, qty, vendor sell/value, data age) + Murist-only addon events. Polls `GET /murist/status`, `GET /murist/quests`, `GET /murist/inventory`, `GET /murist/events`.
- **Inventory** (`GET /inventory`) — realm-wide bags from the characters DB. Primary table: item · total · stacks · holders · id, quality-coloured, quality desc then total desc. Summary strip: characters · item types · items · realm gold (per-character tooltip). Secondary **By character** collapsible. Manual Refresh (no poll) with a 30s server cache the Refresh button bypasses.
- **Advisor** (`GET /advisor`) — live ring of parsed `<SA>` / `<ShadowArmy>` lines from Chat.log. Table body polls `GET /events`. **Reload addon** posts to `POST /reload`.
- **Admin** (`GET /admin`) — **Realm** panel (start/stop) + ops buttons (respawn army, tele party to Murist). Local ops only; not fair-play recovery. Realm start/stop runs as a **detached user unit** (`wow-realm-op` via `systemd-run --user`), not as a child of `wow-system`, so restarting the dashboard does not kill a multi-minute image build. Progress is mirrored in `local_data/realm-op.json` + `local_data/realm-op.log`.

## Seat babysitter (ticket 0055)

A home seat can wedge with its launcher PID alive and its Lua heartbeat frozen
(2026-08-15: Tusk hung on a world-asset stream mid-fight; the realm showed him
offline and nothing noticed until a human read the roster). A background thread
samples **every watched seat** every 10s:

- the **original four** (`SeatMakeTargets`) — dedicated Makefile targets;
- every **scale-out seat** in `tools/data/home_army_roster.tsv`
  (`character<TAB>account<TAB>class`) — the parameterized targets. The table is
  re-read whenever its mtime moves, so a growing roster is covered without a
  dashboard restart. Rows naming a protected seat (the four, Kaisel, Murist),
  duplicates, and rows with non-alphanumeric fields are ignored.

Kaisel (quest-QA, different runtime root) and Murist (human) are never watched.

| Seat state | Rule |
|---|---|
| `stopped` | no live `launcher.pid` |
| `starting` | PID alive, no `status/status.json` yet (a cold `nim r` build is slow — never restarted for it) |
| `running` | PID alive, heartbeat younger than the threshold |
| `wedged` | PID alive, heartbeat **older than 90s** (`SYSTEM_SEAT_STALE_SEC`) |

Recovery for a wedged seat, in order:

1. **Evidence first** — the last 50 `launcher.log` lines land in
   `local_data/home-army/<Seat>/wedge-<UTC>.log` **before** anything restarts
   (the start target rotates `launcher.log`, so the postmortem has to be taken
   first).
2. **Event line** — `<SYS> wedge …` goes into the same ring the addon feeds, so
   it shows up in the Advisor tail and `addon_events`.
3. **Auto-restart** — the seat's own Makefile lifecycle, then a 3-minute
   cooldown before the next attempt:
   - original four: `make <seat>-stop` + `make <seat>-start` (identical to the
     roster Bot buttons);
   - roster seats: `make seat-stop SEAT=<n>` +
     `make seat-start SEAT=<n> SEAT_USER=<acct> SEAT_CLASS=<class>`.
4. **Bounded** — max 3 restarts **per seat name** per hour
   (`local_data/seat-watch.json` keeps the window, the alert flag and the last
   action time across dashboard restarts, so the cooldown is not refilled by a
   `wow-system` restart either). Past the budget the seat stops being restarted
   and shows a persistent red alert instead of crash-looping.

Alerts clear themselves when the seat's heartbeat comes back. `SYSTEM_SEAT_BABYSITTER=0`
downgrades the whole thing to observe-only (detection + red light, no restarts).
A 60s grace after The System boots means our own restart never counts against a seat.

## Inventory over the chat bus (ticket 0052)

The realm DB only learns about bags on its save interval, so inventory comes over
the addon's existing outbound channel (`F.emit` → SAY → Chat.log → the tailer).
Wire format is the addon's `ShadowArmy.invModel`:

```
<SA> inv  <seq>/<total> <id>:<count>,<id>:<count>,…    full snapshot (REPLACE)
<SA> invd <seq>/<total> +<id>:<count>,-<id>,…          delta (PATCH, absolute)
<SA> inv  1/1                                          bags are empty (a fact)
```

System-side rules:

- A **snapshot is applied only when every line of the set has arrived** — inv
  lines are droppable under the addon's emit queue, and a set with a hole would
  under-report bags. Parts may arrive in any order inside 20s; an abandoned set
  leaves the previous known bags (and their age) on screen untouched.
- A **delta patches absolute totals** (`+id:count` sets the new total, `-id`
  removes), so replaying one is idempotent. A delta that lands between snapshot
  parts is applied to the in-flight set too, so the commit cannot lose it.
- Item names / vendor prices join `mangos.item_template` (highest `patch <= 10`
  wins), cached in-process — unknown ids still render, just unnamed.
- The Murist tab shows the data **age**; before any line has ever arrived the
  panel stays quiet rather than implying empty bags.
- `request_inventory` (MCP) announces `<SYS> inv?` for an on-demand snapshot;
  the addon suppresses an identical repeat for 30s, so unchanged bags may answer
  with silence.

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
seatWatchStatus()      ──►  htmx GET /seats  / MCP seat_watch
characterInventory()   ──►  htmx GET /murist/inventory / MCP character_inventory
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
