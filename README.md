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
- `lua/tests/` — fast unit tests, run by `make test` (must stay instant)
- `tools/` — party promote, fair-play audit, traverse/replay tooling
- `kb/` — bot memory for the future LLM planner (map facts, quest ids, tool
  reliability). **Empty on purpose** — see `kb/README.md`
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

# Terminal B — native client at the normal login screen
make play
```

| Item | Value |
|---|---|
| Account | `monofuel` |
| Password | `password` |
| realmd | `127.0.0.1:3724` |
| world | `127.0.0.1:8085` |
| healthz | `http://127.0.0.1:8080` |

- **Login screen:** `make play` passes `--login-screen` only (plus local
  realm ports). Type `monofuel` / `password` yourself. Do **not** pass
  `--username`/`--password` with this flow: with `--login-screen` the
  launcher does not forward credentials to the player; without
  `--login-screen`, a local realm falls back to the seeded
  `COWORLD`/`Nightsun` direct-world path.
- **Stop:** `make stop-server` (compose stop/rm of `coworld-game`). Never
  `docker kill`. Ctrl-C on `make start-server` only detaches log follow —
  containers keep running until `make stop-server`.
- **Persistence:** MariaDB lives in a docker named volume
  (`vmangos-coworld-db`). Accounts and characters survive `stop-server` /
  restarts. Only `docker_vmangos_server.py down --volumes` or `up --fresh`
  wipes state (not exposed by these targets).
- **Unit tests:** `make test` stays instant (no docker): Lua tools under
  `lua/tests/` + Nim tiers (`system/tests/`, `tools/tests/`). No Python.
  Live seats run through `make escort-army` / `make grind` (Nim host).

## Rules

See `AGENTS.md`. Highlights: fair play (no cross-seat collusion — party
cooperation only through the game's typed assignment), never modify
upstream, `make test` green before every commit.
