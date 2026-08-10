# The System ↔ addon loop — telemetry out, commands in

Built 2026-07-25. This closes the live-iteration loop from docs/advisor.md:
edit addon Lua on disk → reload the running client remotely → confirm the new
revision loaded, all without the human touching anything.

## The two transports

A 1.12 addon has no sockets, no HTTP, no file I/O. The only channels that
exist are chat (out) and chat events (in), so the loop is built from both:

```
OUT  addon emit() ──/say──► VMaNGOS Chat.log ──tailer──► The System ring buffer
                                                          ├─► dashboard /events
                                                          └─► MCP addon_events
IN   The System ──SOAP announce──► CHAT_MSG_SYSTEM ──► addon <SYS> parser
     (docker bridge :7878)          (every client)       whitelisted verbs only
```

## Outbound: `emit(kind, text)` (addons/ShadowArmy/ShadowArmy.lua)

`SendChatMessage("<SA> <kind> <text>", "SAY")` with a 30s identical-message
dedupe (rotation errors repeat every frame). Current emitters:

| kind | when | payload |
|---|---|---|
| `loaded` | PLAYER_ENTERING_WORLD | `rev=<REV>` — bump REV on every edit |
| `err` | rotation pcall failure | `rotation: <lua error>` |
| `auto` | auto-combat toggle | `ON` / `OFF` (corpus labeling) |
| `pong` | `<SYS> ping` | `rev=<REV>` |
| `status` | `<SYS> status` | `lvl= hp= zone= xph=` |

Chat.log lines carry guid/map/position for free (server stamps them), so
every telemetry event is also a positional breadcrumb.

## Inbound: SOAP → `announce` → CHAT_MSG_SYSTEM

VMaNGOS ships a gsoap endpoint (urn:MaNGOS, `executeCommand`) that runs GM
console commands. We enabled it in the operator config overrides
(`SOAP.Enabled=1`, `SOAP.IP=0.0.0.0`, port 7878 — docker bridge only, no
published port; The System resolves the container IP via `docker inspect`).

`announce <text>` broadcasts a system message every client receives as
`CHAT_MSG_SYSTEM` (`|cffff0000[System Message]: <text>|r`). The addon strips
color codes, looks for a `<SYS>` marker, and dispatches ONLY whitelisted
verbs: `reload`, `ping`, `status`, `say <text>`. Never eval.

### SOAP auth gotchas (learned the hard way)

- The handler requires the account's security >= SEC_ADMINISTRATOR (6).
- VMaNGOS reads security from **`realmd.account_access`** (id, gmlevel,
  RealmID) — `account.gmlevel` is a dead legacy column. 403 with correct
  password = missing account_access row.
- Security is **cached at startup** (`AccountMgr::LoadAccountData`), so a
  gmlevel change needs a realm restart to take effect.
- `make soap-account` does both steps (SRP account + account_access row).

## The reload loop, end to end

1. Racha edits `addons/ShadowArmy/ShadowArmy.lua` (bump `REV`), parse-checks
   with `luac -p`.
2. MCP tool `reload_addon` (or dashboard button) → SOAP
   `announce <SYS> reload`.
3. Addon sees CHAT_MSG_SYSTEM and tries `ReloadUI()`. There is no retail
   SecureTemplate lockdown, but **wine 5875 still hardware-gates** many
   calls: free `ReloadUI` from a system/chat path often **no-ops**. The
   addon escalates (show **Reload!** / arm next action-bar press) — see
   AGENTS.md and `docs/vanilla-addons/addon-system.md`.
4. After a successful reload, fresh addon fires PLAYER_ENTERING_WORLD →
   `emit("loaded", "rev=rN")`.
5. Tailer sees the line; `reloadAddon()` returns `{ok: true, loaded: {...}}`
   with the new rev — or `{ok: false, timeout: true}` after 6s (client not
   logged in, or the edit broke the addon before emit could run).

A timeout after a reload attempt is itself a signal: if `loaded` never
arrives, the most likely cause is a Lua error at file scope — check
`addon_events kind=err` and the client's local chat.

## Manual test checklist (human at the keyboard)

1. `make start-server` (realm up), `make system` (The System on :7777),
   `make play-classic`, log in as Murist.
2. On login: dashboard http://127.0.0.1:7777/ should show a `loaded rev=r1`
   event within ~2s (addon emits on PLAYER_ENTERING_WORLD).
3. Click **Reload addon** on the dashboard → in-game you see the red
   [System Message] line + the ARISE greeting again; dashboard shows
   `ok — Murist rev=r1`.
4. Toggle auto-combat → `auto ON` event appears.
5. MCP smoke from a shell:
   `curl -sS -X POST http://127.0.0.1:7777/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_announce","arguments":{"text":"<SYS> ping"}}}'`
   → a `pong rev=r1` event lands in /events.

## Admin from the advisor (addon → System)

The vanilla client cannot HTTP. Admin write actions from Murist go out as
`/say` telemetry and The System’s Chat.log worker runs the **same** procs
as the dashboard/MCP:

| Advisor Admin button | Chat bus | Dispatch |
|----------------------|----------|----------|
| **Respawn army** | `<SA> admin respawn_shadow_army #N` | `respawnShadowArmy()` |
| **Tele party to me** | `<SA> admin tele_party_to_murist #N` | `telePartyToMurist()` |
| **Reload addon (via System)** | `<SA> admin reload_addon #N` | `reloadAddon()` |

Only character **Murist** is accepted (`AdminRequesterName`). Debounced
(~8s). Result announce: `<SYS> admin respawned …` (addon displays it).

## Design notes

- Same one-dispatch-path rule as ever: `recentEvents()`, `reloadAddon()`,
  `announceInGame()`, `respawnShadowArmy()` feed htmx, MCP, and (where
  useful) the Murist admin chat bus.
- The System is no longer a pure observer — see system/README.md "Scoped
  write exception". The write surface is exactly: GM `announce` via a
  dedicated SOAP account. No world-state, item, gold, or teleport commands.
- `announce` is a broadcast; with multiple characters online they all see
  `<SYS>` lines and all reload. Fine at our scale (one human + shadows —
  shadows reloading their advisor is a feature). If it ever needs targeting,
  `.send message <name> <text>` delivers per-player but arrives as an area
  trigger message, not CHAT_MSG_SYSTEM — a different addon event to parse.
- Verified live 2026-07-25: SOAP `server info` and `announce` round-trip
  (`<result/>` response), tailer picks up appended Chat.log lines within
  ~1s, simulated reload loop returns `ok` with the loaded event. Pending
  the human seat: real client receiving the announce and reloading.
