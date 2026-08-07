# Traverse: obstacle avoidance (Petrel movement polish)

**Status:** planning (not implemented)  
**Scope:** Kalimdor Traverse ClientView Lua pilot only — look less dumb on
minor terrain; still fair-play ordinary input.  
**Related:** [clientview-migration.md](clientview-migration.md) (working pilot),
upstream RealPlayerBot `bots/real_playerbot/policy/navigation.nim`.

---

## Problem

Petrel **reaches** the water-entry checkpoint (`-6784.5, -4833.9`, r≈50) with
Travel Form + hop moves, but motion often **looks wrong**:

| Observed | What’s going on |
|---|---|
| Runs **into a hut**, then **slides** past | Lowerer aims at a straight hop; client physics slides off the collider |
| Climbs a **short mountain** it *can* walk, but **slides around** | Same: no walkable mesh preference, just face + hold W |
| Nothing **fully** blocks the run | Goal still works; this is **polish / efficiency**, not a hard fail |

Lua is not the bottleneck. The bridge **move lowerer** is: face goal hop +
`MOVEFORWARD` / turn keys. There is **no path query** around solids.

```text
lua/entry/traverse.lua     decide: hop toward checkpoint, forms
        │
        ▼
tools/traverse_lua_bridge  project → decide → lower
        │
        └── lower move:  bearing to (x,y) + hold W   ← no obstacle plan
```

---

## What RealPlayerBot already has

RPB is built for this. Rough map:

| Piece | Role |
|---|---|
| `policy/navigation.nim` | Client **navmesh** corridors (Detour-style), waypoints, water vs ground, stuck/recovery, collision bearing |
| `policy/travel.nim` | When to use travel form / speed |
| `policy/world_knowledge.nim` | Larger road/activity graph (continent-scale; overkill for “hut next door”) |
| Client navmesh / collision | **Read-only** planning; still moves only via `ClientInputBatch` |

RPB does **not** teleports or bypass collision. It **plans** a walkable corridor,
then steers with ordinary keys. That is the reference for “walk around the hut.”

Fair-play note (league): read-only navigation may propose routes; it must not
move the character out of band. Same rule we already follow.

---

## Options (easiest → hardest)

### A. Hop tuning only (Lua)

- Shorter `HOP_YARDS`, maybe lateral offset when hop fails.
- **Feel:** slightly fewer face-plants; still slides.
- **Effort:** hours. **No navmesh.**

### B. Stuck / slide recovery (bridge or Lua)

- Detect **no progress** (pose delta small while moving) or long contact.
- Temporary **strafe / turn** then resume goal.
- **Feel:** less “mashing into hut”; still reactive, not true pathing.
- **Effort:** hours–1 day.

### C. Navmesh-backed hops (recommended polish)

- For each hop (or each tick while moving): ask the **same client navmesh helpers
  RPB uses** for a short walkable next point toward the goal (or a short corridor).
- Lowerer steers to **that** point, not raw checkpoint bearing.
- **Feel:** curves around the hut; prefers mesh over sliding on bumps.
- **Effort:** few focused days if we **reuse** RPB/client APIs; weeks if we
  reimplement Detour ourselves (don’t).

### D. Hand movement off to RPB navigation wholesale

- Lua only picks high-level goals (checkpoint / swim / form); RPB nav owns feet.
- **Feel:** best.
- **Effort:** hard integration (state machine ownership, who casts form, etc.).

---

## Recommendation

| Goal | Do |
|---|---|
| Ship coast strategy first | Leave avoidance as-is; arrival already works |
| “Looks less weird on desert furniture” | **C** (navmesh next-step) after a thin **B** if stuck cases hurt score time |
| Match Softmax coworker polish | Eventually **C** or **D**, not more Lua hop math |

**Default:** keep Lua intent `move` to a point. Put path quality in the
**Nim lowerer / a small nav helper**, not in pure Lua.

```text
goal / hop (Lua)
    → navmesh short route or next waypoint (client/RPB helpers)
    → ClientInputBatch steer (existing key lowerer)
```

---

## Suggested implementation slices (when we code)

1. **Instrument** stuck frames: log pose delta, intent hop, whether moving.
2. **B:** if stuck N seconds, strafe/turn pulse; clear on progress.
3. **C:** one call path: “next walkable point within R yards toward hop” from
   client navmesh (read RPB `navigation.nim` + `environment/client` navmeshes).
4. Feed that point into existing face+W lowerer (or small corridor of points).
5. Keep forms (spellbook / bar) independent of pathing.
6. Prove on known offenders: hut scrape, short mountain ridge on Tanaris→water run.

Out of scope unless needed later: full continent road graph, jump/climb
recovery, great lifts, perfect fatigue coasting.

---

## Difficulty (honest)

| Outcome | Difficulty |
|---|---|
| Fewer freezes into walls (B) | Easy–medium |
| Actually go **around** the hut (C, reuse RPB nav) | **Medium** — right layer, borrow don’t invent |
| RPB-smooth everywhere (D / full nav port) | Hard |

Lua unit tests stay valid if the frozen table and `move` intent shape stay the same;
new tests belong on “next waypoint given mesh” and stuck recovery.

---

## Open questions (before coding)

- In-process bridge: can we call client navmesh from the bridge process, or only
  from inside the player (hook next to `TRAVERSE_LUA_BRIDGE`)?
- Hosted image: same hook must see nav tiles / navigation service as RPB.
- Swim legs remain a gap: the current custom liquid steering is not an RPB
  route and cannot plan around the first coastal cliff.

---

## See also

- Pilot: `lua/entry/traverse.lua`, `src/traverse_cv/lower.nim`, `tools/traverse_lua_bridge.nim`
- Launch: `make traverse` / `make traverse-headed` (`tools/traverse_cv.sh`)
- Upstream: `bots/real_playerbot/policy/navigation.nim`, `docs/bot-control-guidance.md`
  (movement / retained progress), participate traverse fair-play movement rules
