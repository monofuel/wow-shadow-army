# wow-shadow-army

Solo-leveling bot army for `coworld-vanilla-wow`. One human (monofuel) plus
a population of persona bots — combat shadows and industry shadows — built
on the game's typed control boundary.

Plan and doctrine: `coworld-playbook/games/solo-leveling.md`.
Architecture target: racha_notes `AI/game_bots/architecture.md` (three
layers: knowledgebase / Lua tool library / LLM planner).

## Where this sits

Our bots run inside `../monofuel-vanilla-wow` — a thin fork of the upstream
Nim client kept as close to upstream as possible. The fork adds one generic
**lua-bot** identity (`bots/lua_bot/`, gated behind `-d:luaBotVm`) that
embeds a Lua 5.3 VM, mirrors the typed Observation into a snake_case view,
and executes declarative intents through upstream capabilities (the
RealPlayerBot route engine does all pathing). The brains live here, in
`lua/entry/*.lua`; flexibility belongs in the Lua, not the host.

```
knowledgebase (kb/)          <- bot memory: reserved, empty, unbuilt
LLM planner (later)          <- goal selection, toolsmithing
Lua brains (lua/entry/)      <- decide(view) -> typed intents, per league
────────── embedded Lua 5.3 VM (-d:luaBotVm) ──────────
lua-bot host                 <- ../monofuel-vanilla-wow bots/lua_bot/: view, intent, execution
────────── WoW 1.12 protocol over ws bridge ──────────
VMaNGOS realm
```

## Upstream pin

`upstream.lock` records the `coworld-vanilla-wow` commit we build/test
against. The upstream checkout lives as a sibling:
`../coworld-vanilla-wow`. Move the pin deliberately; upstream moves fast.

## Layout

- `lua/tools/` — named-intent tool library (the LLM-facing language)
- `lua/entry/home.lua` — persistent-realm party/role/recovery policy
- `lua/tests/` — fast unit tests, run by `make test` (must stay instant)
- `tools/` — party promote, fair-play audit, traverse/replay tooling
- `kb/` — bot memory for the future LLM planner (map facts, quest ids, tool
  reliability). **Empty on purpose** — see `kb/README.md`
- `bot_notes/` — Watcher field log: every death, live pathing/combat bugs.
  See `bot_notes/README.md`. Not bot memory.
- `docs/` — everything written for humans/agents on this repo: design notes,
  protocol and upstream notes, postmortems (`docs/postmortems/`). Start with
  `docs/interfaces.md` (the map of every boundary), then `docs/nim-client.md`
  (the upstream client interface we code against), then `docs/v2.md`
  (`docs/control-plane.md` is the v1-era design, kept as history)

## Human quickstart

Play the local docker realm as a normal human (create level-1 characters,
etc.). Full bring-up detail: `coworld-playbook/games/vanilla-wow.md`.

Prereqs (one-time, already done on high-steel): upstream checkout at
`../coworld-vanilla-wow`, extracted VMaNGOS data + mysql dumps under its
`local_data/`, and a built `coworld-vmangos:local` image.

```sh
# Terminal A — start realm (foreground logs; Ctrl-C detaches logs only)
make start-server

# Once (or after a fresh DB wipe) — ensure the playtest account
make account

# Terminal B — native human client
make play

# Separately, when the four bot seats should be online
make home-army-start
make home-army-status
```

| Item | Value |
|---|---|
| Account | `monofuel` |
| Password | `password` |
| realmd | `127.0.0.1:3724` |
| world | `127.0.0.1:8085` |
| healthz | `http://127.0.0.1:8080` |

- **Bot lifecycle:** realm start/stop and bot start/stop are intentionally
  separate. `make home-army-start`, `home-army-status`, `home-army-stop`, and
  `home-army-restart` manage only Shadowfel, Igris, Tusk, and Beru. They do not
  create accounts or alter persistent realm data.
- **Bot policy:** each headless client runs the embedded `lua-bot` with
  `lua/entry/home.lua`. It accepts Murist's invite, promotes Murist when
  necessary, follows/assists him, performs its class role, and recovers from
  death. Without an observable grouped Murist it safely uses the solo
  `accelerated` policy.
- **Runtime state:** each seat writes under
  `local_data/home-army/<Character>/` (`launcher.pid`, `launcher.log`,
  `status/status.json`, and `observer/`). The System uses PID plus the fresh
  Lua status heartbeat for liveness.
- **Stop:** `make stop-server` (compose stop/rm of `coworld-game`). Never
  `docker kill`. Ctrl-C on `make start-server` only detaches log follow —
  containers keep running until `make stop-server`.
- **Persistence:** MariaDB lives in a docker named volume
  (`vmangos-coworld-db`). Accounts and characters survive `stop-server` /
  restarts. Only `docker_vmangos_server.py down --volumes` or `up --fresh`
  wipes state (not exposed by these targets).
- **Unit tests:** `make test` stays local (no realm mutation): Lua tools under
  `lua/tests/` + Nim tiers (`system/tests/`, `tools/tests/`) and existing
  operator-script checks.
  All build/test/run commands belong inside this repo's `nix develop` shell.

## Rules

See `AGENTS.md`. Highlights: fair play (party cooperation only through facts
the client observes), keep generic client-interface changes in
`../monofuel-vanilla-wow`, and keep `make test` green before every commit.
