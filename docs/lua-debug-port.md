# Lua debug port (home seats)

Live debugging for the home lane: ask a running seat what it is doing, pause
it, and hot-swap its Lua brain **without reconnecting the seat**. Revives the
surface that `tools/petrel_debug_admin.nim` provided before the petrel embed
transport was deleted (`docs/traverse/army-debug.md` at `0068d43`), re-hosted
against the fork's `bots/lua_bot/` embed.

Ticket: `../tickets/in-progress/0053-bot-lua-debug-port.md`. Phase 1 only —
`/status`, `/hold`, `/resume`, `/lua/reload`. Home seats only; league and
traverse launch paths get nothing.

## Why it is split in two

Petrel's admin was **never** in the client process. It was a sidecar that wrote
atomic control-request files; the player picked them up at simulation cadence
and wrote acks back. That shape is still the right one, for three reasons:

1. **The fork has no HTTP dependency and should not gain one.** `mummy` is not
   in the fork's dependency set; this repo already runs it (`system/system_server.nim`).
   Client customizations only, and an HTTP server is not a client customization.
2. **A Lua VM is single-threaded and the decide loop is latency critical.** An
   in-process listener would have to hand requests to the decide thread anyway
   — which *is* the control-file protocol, only with a lock and a worker thread
   inside the render process. The process boundary buys the same semantics for
   less risk.
3. **Fair play.** The shipped client never opens a socket. Nothing to strip out
   of a hosted or league policy image, and nothing to accidentally leave on.

So: the fork gains a **file-backed control channel**; this repo owns the
**HTTP listener**.

## What lives where

### The fork (`../monofuel-vanilla-wow`, branch `monofuel/lua-debug-port`)

| File | Role |
|---|---|
| `bots/lua_bot/control.nim` | New. Request/ack file channel. Knows nothing about `LuaBotState` — it polls, parses, dedupes, and acks. No sockets, no new deps. |
| `bots/lua_bot/pilot.nim` | Applies ops between decide ticks; adds the `held` gate and a few status fields. |
| `proof/lua_bot_control_check.nim` | New. Standalone proof, matching `proof/lua_bot_embed_check.nim`. |

The embed already exposed VM construction as a callable unit
(`embed.openVm` / `embed.reloadVm`), and `reloadVm` was **already
transactional** — it boots a candidate VM and swaps only on success. Nothing in
the VM layer had to change. The admin really is mostly plumbing, exactly as the
keep-embed-thin rule predicts.

Gate: the channel is inert unless **`VANILLA_WOW_LUA_DEBUG_DIR`** names a
directory. Unset (the default, and every league/traverse path) means the poll
proc returns immediately and no control files are ever read or written.

### This repo (`shadow-army-home`)

| File | Role |
|---|---|
| `tools/lua_debug_admin.nim` | New. mummy HTTP on `127.0.0.1:<port>`; translates HTTP to control files and waits for the ack. |
| `Makefile` | Env wiring: `launch_home_seat` exports the control dir; `start_home_seat` starts/stops the sidecar next to the seat. |
| `docs/lua-debug-port.md` | This file. |

## Control protocol (`wow_shadow_army.lua_bot_control.v1`)

Control dir defaults to `<seat_dir>/control`.

- `<dir>/request.json` — written atomically (temp + rename) by the admin:

  ```json
  {"protocol": "wow_shadow_army.lua_bot_control.v1",
   "id": "1755300000123-4", "kind": "lua_reload",
   "requested_at_unix_seconds": 1755300000.123}
  ```

- `<dir>/acks/<id>.json` — written atomically by the seat once applied:

  ```json
  {"protocol": "wow_shadow_army.lua_bot_ack.v1", "ok": true,
   "command_id": "1755300000123-4", "kind": "lua_reload",
   "detail": "reloaded", "state": { ... }}
  ```

`kind` is one of `status`, `hold`, `resume`, `lua_reload`. The seat dedupes on
`id`, so a request file that is re-read (same mtime granularity, restart) is
applied exactly once. Acks are retained; the admin polls for its own id.

## HTTP surface

Bound to `127.0.0.1` only. Default port `7788 + seat index`
(`HOME_DEBUG_PORT_BASE`).

| Method | Path | Behaviour |
|---|---|---|
| `GET` | `/healthz` | Sidecar liveness plus the seat's control dir. Never touches the seat. |
| `GET` | `/status` | Issues a `status` command and returns the seat's ack, merged with the last `status.json`. |
| `POST` | `/hold` | Seat stops and emits `hold` intents until resumed. |
| `POST` | `/resume` | Seat returns to running `decide`. |
| `POST` | `/lua/reload` | Transactional VM rebuild (below). |

Every command responds with the seat's ack, or `504` with
`{"ok": false, "error": "seat_timeout"}` when the seat does not ack inside
`?timeout_ms` (default 3000). A timeout means the seat is wedged or stopped —
it does **not** mean the command was rejected.

## `/lua/reload` semantics

This is the transactional one, and it is genuinely transactional — the property
comes from `embed.reloadVm`, which predates this work:

1. A **candidate** `LuaVm` is opened from the live seat's `--lua-repo` /
   `--lua-entry`. This re-reads every Lua file from disk: `openlibs`,
   `registerWowApi`, `package.path`, `require(entry)`, and a check that
   `entry.decide` is a function.
2. **On failure** — a syntax error, a missing `require`, a runtime error at
   file scope, a table without `decide` — the candidate is closed, **the live
   VM is never touched**, and the ack is
   `{"ok": false, "detail": "boot: lua/entry/home.lua:42: '=' expected near ..."}`.
   The seat keeps playing on the old brain. It is not held, not stopped, not
   degraded. Re-running `/lua/reload` after fixing the file succeeds.
3. **On success** the old VM is closed and the candidate takes its place.

The swap happens **between decide ticks by construction**: the control poll runs
on the decide thread, at the top of `luaBotDecide`, before that tick calls into
Lua. There is no window in which a half-swapped VM can be asked to decide.

Lua-side state does not survive a reload — a fresh VM means fresh module state.
That is the same contract the existing mtime auto-reload has always had.

### Why an explicit reload, when mtime auto-reload exists

`pilot.maybeReloadEntry` already watches the **entry file** and reloads on
mtime change. It does not watch anything the entry `require`s — edit
`lua/tools/foo.lua` and the live seat keeps the stale module forever.
`/lua/reload` is unconditional, so it picks up the whole tree, and unlike the
mtime path it reports the boot error back to the caller instead of only to the
seat's stderr.

## `/hold` semantics

A held seat is a **live, connected, deliberately idle** seat:

- The hold gate sits after the in-flight form-cast and chat-cast sequences, so a
  cast already driving the chat box finishes rather than leaving the edit box
  open eating movement keys.
- Each held tick releases bound movement (`appendStoppedBoundMovement`) and
  publishes `intent_kind = "hold"`, `intent_reason = "debug_hold"`,
  `nav_progress = "held"` — the same shape as a Lua-authored `hold` intent, so
  `status.json` readers and the observer need no changes.
- The no-route escape timer is cleared on hold, matching the `libHold` arm, so
  a deliberate hold cannot leave the escape latched and serpentine the first
  navigate after resume.
- `decide` is not called while held, so the Lua brain sees no ticks and cannot
  advance its own state machine.

Hold is **not** persisted. A seat restart comes up running.

## Operating it

**Seats need a restart to gain the port** — the control dir is read from the
environment at launch, and the sidecar is started by the seat's start target.
A seat that is already running when this lands has no debug surface, and
nothing about it changes. Roll out at the next natural
`make home-army-restart`, not mid-session.

Enable by setting `HOME_DEBUG_PORT_BASE` when starting the army:

```
make home-army-start HOME_DEBUG_PORT_BASE=7788
```

Unset (the default) means the seat env carries an EMPTY
`VANILLA_WOW_LUA_DEBUG_DIR` (which disables the channel forever at boot)
and no sidecar process exists: the feature is absent, not merely idle.

Ports are assigned by seat index, in the order the army starts:

| Seat | Port |
|---|---|
| Shadowfel (warlock) | 7788 |
| Igris | 7789 |
| Tusk | 7790 |
| Beru | 7791 |

The home dogfood loop becomes: edit `lua/entry/home.lua`, then
`curl -X POST 127.0.0.1:7789/lua/reload`, and read the boot error from the
response if the edit was broken. No `home-army-restart`, no reconnect, no lost
position.

## Deliberately not in phase 1

`/timeline`, `/transitions`, `/anomalies`, `/dump`, `/stop`, the WebSocket
stream, and the durable per-run artifact tree from the petrel era. Those were
built for scored traverse runs; the home lane's persistent seats want live
introspection, not run forensics. `/status` plus `status.json` plus `observer/`
covers the read side today.

Arbitrary Lua eval (the ticket's original `debug.lua` sketch) is also out.
`/lua/reload` covers the iteration loop that motivated the ticket, and an eval
endpoint is a much larger surface to gate correctly.
