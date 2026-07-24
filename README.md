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
sole mutable out-of-process boundary, `vanilla_wow.nim_control.v1`:
typed `GoalRequest` / `ActionSelectionRequest` in, typed settlements +
MessagePack environment frames out.

```
knowledgebase (kb/)          <- what the army has learned
LLM planner (brain/)         <- goal selection, toolsmithing (later phase)
Lua tool library (lua/)      <- named intents: follow_leader(), support_party_tank(), ...
────────── nim_control.v1 socket ──────────
upstream Nim client          <- perception + execution (pinned, unmodified)
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
- `brain/` — strategist harness that owns the control socket + embeds Lua
- `kb/` — the bot-readable/writable knowledgebase (map facts, tool notes,
  postmortems)
- `docs/` — design notes; start with `docs/control-plane.md`

## Rules

See `AGENTS.md`. Highlights: fair play (no cross-seat collusion — party
cooperation only through the game's typed assignment), never modify
upstream, `make test` green before every commit.
