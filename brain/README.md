# brain

Strategist harness: owns the `nim_control` socket, projects frames for the
Lua tools, translates intents into typed requests.

## Modules

| Module | Role |
|---|---|
| `upstream.py` | Sole adapter: puts `../coworld-vanilla-wow` on `sys.path`, re-exports `NimControlClient` + wire models. Pin move = edit this file / `WOW_SHADOW_UPSTREAM`. |
| `frame_projection.py` | `EnvironmentFrame` → plain tables for `lua/tools` (follow_leader shape). |
| `intent_mapping.py` | Lua intent → `FactorizedAction` recipe (`hold` skips select). |
| `lua_runner.py` | Real Lua via `lua5.3` subprocess (not lupa). Zero new Python deps. |
| `shadow.py` | Supervisor CLI: goal install → frame loop → Lua → select. |

## Runtime deps

Unit tests (`make test-python`) are **stdlib-only** and operate on plain
dicts. Live runtime needs upstream's pydantic + msgpack:

```sh
# From wow-shadow-army root; uses upstream's uv project as the interpreter env.
uv run --project ../coworld-vanilla-wow python -m brain.shadow \
  --slot 0 \
  --leader-name Botpriest \
  --party-members Botpriest,Botwarrior \
  --move-fallback \
  --max-seconds 60 \
  --capture-frames 5
```

Or `make shadow EXTRA='--move-fallback --max-seconds 60'`.

JSONL logs append under `local_data/brain-logs/` (gitignored).

## Lua runner choice

**Subprocess `lua5.3`** with a generated script that embeds the projected
frame as a Lua table literal and prints the intent as JSON (tiny pure-Lua
encoder). Avoids lupa (C extension) and cjson. Same binary preference as
`make test` (`lua5.3` then `lua`).

## First shadow loop

See `docs/control-plane.md` § Milestone 1 runbook. No follow goal exists:
install `leveling` + `selection_mode=external`, then drive
`ActionSelectionRequest` each decision window. Without a party, use
`--move-fallback` so `move_to_unit` becomes `kind=move` near the leader
unit until invite/accept formation is wired.
