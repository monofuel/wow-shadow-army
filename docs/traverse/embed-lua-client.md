# Embed Lua into the Nim client (Petrel pathing plan)

**Status:** embedding implemented; land uses RPB navigation, liquid pathfinding
is not implemented (corrected 2026-08-07)  
**Decision bias:** in-process Lua for **strategy**; Nim / RealPlayerBot stack for
**navigation and keys**.  
**Supersedes for feet:** the per-tick `TRAVERSE_LUA_BRIDGE` process-spawn hack
and pure hop lowerer as the long-term path.  
**Related:** [pathing.md](pathing.md) (beats + nav A→B), [petrel-plan.md](petrel-plan.md),
[clientview-migration.md](clientview-migration.md) (historical ClientView pilot;
`/player` is still a valid *external* shape, not how we unlock RPB nav).

---

## Why this plan

### Requirements (locked for the rethink)

| # | Requirement |
|---|---|
| R1 | **Do not reimplement navigation in Lua.** Feet use upstream client navmesh + RPB-style route/steer. |
| R2 | **Sparse major beats only** for course structure (zone / mid / final). No carpet of micro-waypoints as pathing. |
| R3 | **Weekly start/end** and **other competitions** must not require rewrite of the feet stack — only beat lists + thin policy. |
| R4 | Keep **Lua** where it earns its keep: simple logic, fast iterate, addon-era training data, existing `lua/` tools muscle memory. |
| R5 | **Fair play:** ordinary client input only; read-only nav planning; no tele/GM progress. |
| R6 | **Death:** die → reset run (petrel policy). Do not paper pathing failure with ghost recovery. |
| R7 | **Wet legs stay wet** via real liquid/nav mode, not hand-tuned seaward polylines as “pathing.” |
| R8 | **No spawn-a-binary-every-tick.** In-process only for the hot path. |
| R9 | Motion control must not reintroduce **L/R thrash unstick** (motion sickness ban). |

### Why not pure `WS /player` for nav

The rendered contract is only:

```text
ClientView → ClientInputBatch
```

Upstream states that **route/planning state is private to the policy**. RPB’s
`prepareRouteTo` / `advanceRouteTo` / steering live **in-process** on
`RealPlayerBotPolicy` (and client `navmeshes`). An external `/player` peer does
**not** get “call navigation” on the wire — only view in, keys out.

So: `/player` is fine for Python coworkers who own their whole brain. It is
**not** the path to *reuse* Softmax RPB navigation without redoing feet outside
the client.

Coworkers shipping bots **in Nim on the client** sit next to that stack. We
want the same access without throwing away Lua for strategy.

### Why not the bridge

`TRAVERSE_LUA_BRIDGE` was a fork hook that wrote ClientView JSON, **`execCmdEx`
of a full bridge binary every bot tick**, then enqueued keys. It:

- was not the migration plan (`WS /player` host)
- could not call RPB nav
- burned a day on a one-off rail parallel to the other bots

Treat it as **dead-end tech debt**. Salvage: `lua/entry/traverse.lua` ideas
(beats, forms, wet-only prove) — not the process boundary.

---

## Target architecture

```text
                    ┌─────────────────────────────────────┐
                    │  Nim player (fork or upstream bot)  │
                    │                                     │
  ClientView ──────►│  1) Project thin table for Lua      │
                    │  2) Lua decide (in-process VM)      │
                    │       → active beat, form, mode     │
                    │  3) Nim nav A→B (RPB / navmeshes)   │
                    │       → advanceRouteTo(beat)        │
                    │  4) Nim steer → ClientInputBatch    │
                    │       (appendSteering / RPB path)   │
                    └─────────────────────────────────────┘
```

**Ownership**

| Concern | Owner | Language |
|---|---|---|
| Major beats list (weekly course) | config / fixture | data |
| Which beat is active; form; wet-only prove; death hold | policy | **Lua** |
| Mesh + liquid route + progress/failure | navigation | **Nim** (RPB / client) |
| Key/mouse batch | lowering | **Nim** |
| Hot path transport | none | **in-process** (no WS, no exec) |

Lua may call **thin Nim-exported helpers** (e.g. “distance to beat”, “is swimming”)
via registered C closures. Nim calls Lua `decide` each tick (or on a cadence).
**Both directions** — that is the point of embed vs WS.

---

## Reference: decompbound (and noulith)

Do **not** copy Earthbound product code. Copy the **embedding technique**.

| Project | Path (on monofuel’s machines) | What to steal |
|---|---|---|
| **decompbound** | `~/Documents/Projects/Sygnosphere/decompbound` | Lua 5.3 in-process; `src/decompbound/lua53.nim` + `vendor/lua` static `liblua.a`; sandbox (don’t open full `os`/`io` unless needed); Nim registers callbacks; Lua is the **fast policy loop** |
| **noulith** (cited by decompbound) | `~/Documents/Projects/Racha/noulith` | Minimal hand-rolled FFI: static liblua, `newstate` / `loadbuffer` / `pcall` / register Nim as Lua functions |

decompbound’s docs (`docs/llm-plays.md`) describe the shape we want:

- **Fast loop:** Lua policy every frame, no network  
- **Nim owns the host:** memory/API surface, input actuation  
- **Static embed** preferred for self-contained binaries  

For Petrel: Lua does not press movement keys for pathing; it sets **intent**
(beat / form / mode). Nim turns that into RPB route + `ClientInputBatch`.

---

## Initial plan (phased)

### Phase 0 — Align and stop digging

- [x] Treat bridge + hop-only lowerer as **non-goals** for new work  
- [x] Keep [pathing.md](pathing.md) as the feet architecture of record  
- [x] Inventory what of `lua/entry/traverse.lua` is pure strategy (keep) vs geometry (delete/move)

### Phase 1 — Embed spike (empty policy)

- [x] Nim: Lua 5.3 VM in the player/bot path (fork first unless upstream accepts a bot package)  
- [x] Technique: decompbound/noulith-style static liblua + thin FFI  
- [x] Load a trivial script: `return { kind = "hold", reason = "embed_ok" }`  
- [x] Prove: no process spawn; decide runs in-process every tick (or fixed cadence)  
- [x] Sandbox: only the APIs we register (pose read, later nav status) — no host shell

### Phase 2 — Strategy Lua + RPB feet

- [x] Project ClientView → frozen table (reuse ideas from `src/traverse_cv/project.nim`) into Lua  
- [x] Lua returns **high-level intent** only, e.g.:
  - `navigate { x, y, z?, map_id, stop_distance, mode = "land"|"liquid_prefer" }`
  - `cast_form { spell = 783|1066 }`
  - `hold { reason }`
- [x] Nim owns `navigate` state in **RealPlayerBotPolicy** and uses
  `advanceRouteTo` for land  
- [ ] Route liquid intents through real navigation; the current custom
  `appendSteering` corridor is only local steering  
- [x] Forms: lower via existing bar/spellbook patterns (not Lua key simulation for movement)  
- [x] Prove: land hop to water-entry **beat** without beaching on straight-line chord

### Phase 3 — Beats as data

- [x] Config/fixture: ordered major beats `[B0…Bn]` (weekly course)  
- [x] Lua advances beat on arrival (+ wet-only gates for prove points)  
- [x] No seaward track constants as pathing  

### Phase 4 — Wet / coast

- [x] Expose client-owned liquid/collision observations while swimming  
- [ ] Implement real liquid route planning around coastal terrain
  - current RPB liquid lowering is a short-horizon heading chooser, not proven
    pathfinding
  - modeled seafloor depth is telemetry, not a swimmability gate
- [ ] Prove wet merchant (or current week’s end beat) without land-cut victory if rules require wet  

### Phase 5 — Multi-comp reuse

- [x] Same embed host + nav feet; different Lua entry + beat file per competition  
- [x] Document how escort/grind later plug in **without** a second process rail  

### Explicit non-goals (this plan)

- Rebuilding Detour in Lua or in shadow-army  
- Per-tick external bridge / JSON files in `/tmp`  
- Micro-waypoint carpets  
- L/R unstick thrash  
- Ghost recovery as default after death  

---

## Open questions (before heavy code)

1. **Where does the bot package live?** Fork-only player bot vs upstream-contributable bot id under `bots/`?  
2. **Lua version:** 5.3 (decompbound, house) vs 5.1 (classic addon era) vs 5.4 — pick one for embed; unit tests in-repo may stay 5.3 via nix.  
3. **Policy state:** one long-lived `RealPlayerBotPolicy` for nav only, or a thinner wrapper around `navmeshes` + `navigation_steering` without full RPB combat? Prefer **reuse RPB nav modules**, not a third path.  
4. **Cadence:** Lua every view vs every N views (nav can stay every tick).  
5. **Hot reload:** decompbound reloads scripts; nice for iterate, optional for tournament binary.  
6. **Hosted image:** same nav tiles / helper as RPB; embed must not assume bridge machine paths.

---

## Success bar

This architecture is “working” when:

1. No per-tick process spawn.  
2. Changing the week’s start/end is **beat data**, not a movement rewrite.  
3. Land obstacles and open water are handled by **upstream nav/liquid**, not Lua geometry.  
4. Lua scripts remain small: forms, beat index, prove rules.  
5. Other comps can reuse the same Nim feet + embed host.

---

## See also

- Upstream: `bots/real_playerbot/policy/navigation.nim`, `navigation_steering.nim`, `navigation_graph.nim`, `environment/client/navmeshes.nim`  
- Contract: upstream `docs/bot-environment-contract.md` (ClientView → ClientInputBatch; nav private to policy)  
- decompbound: `docs/llm-plays.md`, `src/decompbound/lua53.nim`  
- Dead path (do not extend): `TRAVERSE_LUA_BRIDGE` in fork `player/runtime/visual_adapter.nim`, `tools/traverse_lua_bridge.nim`
