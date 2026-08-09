# Petrel ↔ upstream realign inventory

> **Historical (2026-08-09):** this realign targeted the `.so`/`petrel_pilot`
> era, which was superseded by the generic lua-bot host on
> `monofuel-vanilla-wow` `monofuel/master`. Kept for the commit archaeology;
> see [README.md](README.md) for how Petrel is hosted now.

**Policy:** prefer Metta `upstream/main`. Petrel stays a thin client layer on a
feature branch. Rollback tag on the fork: `petrel-pre-realign-20260807` →
`8df20dbd5` (`embedded-lua-client`).

## Fork-only commits (oldest → newest)

| SHA | Subject | Realign action |
|---|---|---|
| `209e14c92` | TRAVERSE_LUA_BRIDGE ClientView Lua pilot | **Drop** (superseded by libpetrel) |
| `6ef440896` | Petrel in-process Lua via libpetrel + RPB navigate | **Port core** into `bot_pilot.nim` |
| `e44a59fc0` | nav status + land recovery; liquid steer w/o ground probe | Port **minimal** status; prefer upstream recovery |
| `903453853` | Petrel causal flight recorder | Port `petrel_debug.nim` |
| `9778dd26e` | evidence-backed coastal swim corridor | Keep only if still needed after cheese beats |
| `8df20dbd5` | validate form casts from observed transitions | Port form admission |

## Files changed vs merge-base `6d2f3def2`

| Path | Role |
|---|---|
| `player/runtime/visual_adapter.nim` | Petrel pilot host (upstream: `bot_pilot.nim`) |
| `player/runtime/petrel_debug.nim` | Durable runs / admin / anomalies |
| `player/runtime/state.nim` | Petrel fields on pilot state |
| `player/player_runtime.nim` | Wire-in |
| `bots/real_playerbot/policy/liquid_corridor.nim` | Short-horizon wet corridor |
| `bots/real_playerbot/policy/navigation_steering.nim` | Small fork deltas — **prefer upstream** |
| `environment/contract/client_types.nim` (+ json/projection/physics) | **Gone on upstream** — do not forever-vendor; re-map |
| Tests under `tests/bots/.../liquid_corridor.nim` etc. | Keep as fork-only |

## Runtime entry (shadow-army)

| Env | Purpose |
|---|---|
| `TRAVERSE_LUA_REPO` | shadow-army root (Lua + beats) |
| `PETREL_LIB` | `tools/libpetrel.so` |
| `PETREL_DEBUG_RUN_DIR` | durable `local_data/traverse-runs/<id>` |

Flow: ClientView → `petrel_decide` → intent → RPB `advanceRouteTo` / cast lower → `ClientInputBatch`.

## Notes

- Desert freeze logs already match upstream-era **regressing route step** handling
  present under the old merge-base; realign is for **later** nav + contract drift.
- Gitea `origin/main` was polluted with Petrel history; realign restores pure
  mirror via `upstream-mirror` and/or force-with-lease of `main` (operator OK).


## Port status (2026-08-07)

| Item | State |
|---|---|
| `upstream-mirror` / pure base | Done — Gitea `origin/upstream-mirror` |
| `monofuel/petrel` | **Petrel re-hosted** on Observation→Action via `player/runtime/petrel_pilot.nim` |
| Working play branch | Use **`monofuel/petrel`** for prefer-upstream Petrel; `embedded-lua-client` is rollback |
| Gitea `main` rewrite | Still needs monofuel OK for force-with-lease |
| Land beads | Removed from shadow-army strategy |
| Flight recorder / liquid_corridor | Not yet ported (optional); cheese + RPB liquid first |
