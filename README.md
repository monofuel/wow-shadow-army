# wow-shadow-army

Solo-leveling bot army for `coworld-vanilla-wow`. One human (monofuel) plus
a population of persona bots — combat shadows and industry shadows — built
on the game's typed control boundary.

Plan and doctrine: `coworld-playbook/games/solo-leveling.md`.
Architecture target: racha_notes `AI/game_bots/architecture.md` (three
layers: knowledgebase / Lua tool library / LLM planner).

## Where this sits

We do NOT fork the game client. The upstream repo-owned Nim client handles
the WoW 1.12 protocol, perception (typed environment frames), and execution
(pathing, combat, looting) via its `BotController`. Our layer speaks the
sole mutable out-of-process boundary, `vanilla_wow.nim_control.v2`:
typed goals (leader/party/roster) + hold/resume/cancel directives in,
control status + MessagePack environment frames out. **v2 has no external
action selection** — per-frame policy runs in-process upstream
(`kb/nim-control-v2-no-select.md`); our host installs goals, observes,
watchdogs, and audits.

```
knowledgebase (kb/)          <- what the army has learned
LLM planner (later)          <- goal selection, toolsmithing
Lua tool library (lua/)      <- named intents (dormant until upstream re-exposes a select surface)
Nim host (tools/army_host)   <- goal install + watchdogs + fair-play audit
────────── nim_control.v2 socket ──────────
upstream Nim client          <- perception + policy + execution (pinned; fixes via ../coworld-vanilla-wow-fork)
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
- `tools/` — Nim host (`army_host.nim`), party promote, fair-play audit
- `kb/` — the bot-readable/writable knowledgebase (map facts, tool notes,
  postmortems)
- `docs/` — design notes; start with `docs/v2.md` (`docs/control-plane.md`
  is the v1-era design, kept as history)

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
