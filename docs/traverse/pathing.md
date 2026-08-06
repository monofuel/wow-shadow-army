# Traverse pathing architecture

**Status:** design locked for V1+ (not fully implemented)  
**Audience:** engineers on Petrel / ClientView traverse and any later league that
reuses the same feet.  
**Related:** [embed-lua-client.md](embed-lua-client.md) (**integration plan** —
Lua in-process + Nim nav; not WS/bridge),
[obstacle-avoidance.md](obstacle-avoidance.md) (older polish notes),
[petrel-plan.md](petrel-plan.md) (course thesis),
[clientview-migration.md](clientview-migration.md) (historical pilot stack).

---

## Why this exists

Long-term, **start and end points change every week**. We also ship **multiple
competitions**, not only Kalimdor Traverse. Pathing must not be a one-scenario
polyline of hand-tuned hops.

The current ClientView pilot is **stupid for a good reason**: Lua picks a
geometric point → hop → lowerer face+W. That is **not navigation**. It beaches,
clips cliffs, and cannot scale.

---

## Two layers (non-negotiable)

| Layer | Job | Density | Changes when course changes |
|---|---|---|---|
| **Beats** | Course story: major checkpoints only | **Few** (zone / leg / final) | Yes — config/fixture |
| **Nav A→B** | Get from current pose to the active beat | Continuous mesh pathing | **No** — shared system |

### Beats (strategy)

Examples for a given week (illustrative, not hard-coded forever):

1. Land approach / water entry region  
2. Mid-course prove or zone gate (if any)  
3. Final checkpoint / merchant / score bound  

V1 **may** use a short ordered list of major beats (“go to this zone, then that
zone, then the final point”).

V1 **must not** grow into **hundreds of small waypoints** to fake pathing. If
you need that many points, you are papering over a missing nav system.

Beat data lives in **config / fixture / env**, not as permanent magic numbers
scattered through policy. Hard-coded coordinates in Lua are acceptable only as
temporary defaults while the beat list is wired to the league config.

### Nav A→B (feet)

A single shared capability:

```text
navigate(current_pose → active_beat, mode) → next steer point (or short corridor)
```

- **mode** examples: land, prefer liquid, ghost (as needed later)
- Plans on the **client navmesh** (Detour-style corridor), same family of APIs
  RealPlayerBot already uses
- Moves only via ordinary input (`ClientInputBatch` keys) — fair play
- Lowerer steers to **nav’s next point**, never to a raw continent-scale chord

This layer is what **scales** to weekly start/end and to other competitions.
Only the beat list (and thin policy: forms, wet-only prove) is game-specific.

---

## Target control flow

```text
fixture / config
    major beats [B0, B1, …, Bend]
         │
         ▼
Lua (or thin planner)
    which beat is active
    forms / wet-dry / prove rules
         │
         ▼
Nav A→B  (Nim / client / RPB helpers — not pure Lua geometry)
    next walkable or swimmable point toward active beat
         │
         ▼
Lowerer
    face-then-go on that point only
    no L/R thrash “unstick” dances
```

**Lua owns strategy. Nav owns geometry. Lowerer owns keys.**

---

## What we refuse

| Forbidden | Why |
|---|---|
| Carpet of micro-waypoints as the “path” | Does not survive weekly courses; unmaintainable across comps |
| Straight-line continent hops as pathing | Beaches, cliffs, huts — observed failure mode |
| Timed left/right thrash / jump-strafe unstick | Motion sickness; zero pathing value (see traverse day notes) |
| Reimplement Detour in-repo | Upstream already has navmesh + RPB navigation |
| Death ghost recovery as the default after bad pathing | Reset the run; fix nav/policy (petrel death policy) |

---

## Implementation direction

Prefer reuse over invention:

| Source | Role |
|---|---|
| Upstream `bots/real_playerbot/policy/navigation.nim` | Corridor, water vs ground, stuck/route failure semantics |
| Client `environment/client/navmeshes` | Read-only mesh queries |
| Our `src/traverse_cv/lower.nim` | Keys only; consume **nav next point**, not raw beat |
| Our `lua/entry/traverse.lua` | Active beat + forms + prove gates; **not** dense geometry |

### Phases (when we code)

1. **Beat list API** — ordered major checkpoints from config; Lua advances when
   within arrival radius (and wet-only constraints if any).
2. **Nav next-step in the player/bridge path** — for each move tick, query
   next mesh point toward active beat; feed lowerer.
3. **Liquid mode** — swim legs prefer liquid route so we stay wet without a
   hand-drawn seaward polyline.
4. **Shared package** — same A→B used by other competitions (escort legs,
   grind camp approaches, etc.) with different beat lists only.

Detail options and RPB mapping for land polish still live in
[obstacle-avoidance.md](obstacle-avoidance.md) (options B/C/D). **This file
wins** on architecture: sparse beats + real A→B, not hop tuning forever.

### Open integration questions

- Can navmesh queries run in the `TRAVERSE_LUA_BRIDGE` process, or only inside
  the player next to the bridge hook?
- Hosted image: same nav tiles / helper as RPB.
- Swim: liquid route first-class for wet legs; land mesh alone is not enough
  for coast cheese.

---

## Current pilot (honest)

| Piece | Today |
|---|---|
| Beats | Implicit hard-coded points (water entry, merchant, land approach, …) |
| Nav A→B | **Missing** — hop toward goal + face+W |
| Forms | Travel / Aquatic gates in Lua |
| Prove | Wet-only merchant (policy), not pathing |

Shipping progress on Petrel is fine; **do not deepen the hop pilot** as if it
were the long-term pathing system. New work goes into beats + nav A→B.

---

## Success bar

Pathing is “done enough” for multi-comp / multi-week use when:

1. Changing start/end is **data** (beat list), not a rewrite of movement code.
2. A→B handles ordinary terrain without a human laying intermediate waypoints.
3. Wet legs stay in water because **nav mode** prefers liquid, not because we
   tuned a seaward offset constant.
4. Other competitions call the **same** navigate API with their own beats.

---

## See also

- Pilot code: `lua/entry/traverse.lua`, `src/traverse_cv/lower.nim`,
  `tools/traverse_lua_bridge.nim`
- Launch: `make traverse` / `make traverse-headed`
- Upstream: `bots/real_playerbot/policy/navigation.nim`, client navmeshes
- League rules / scoring: [traverse_wow.md](traverse_wow.md)
