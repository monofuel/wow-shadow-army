# Proper pathfinding plan (Petrel feet)

**Status:** plan of record — implement this fully; half-hooks are banned  
**Audience:** anyone touching traverse movement (Lua strategy or fork feet)  
**Related:**

| Doc | Role |
|---|---|
| [pathing.md](pathing.md) | Architecture: sparse beats vs nav A→B (design lock) |
| [embed-lua-client.md](embed-lua-client.md) | Why Lua is in-process; why `/player` cannot own RPB nav |
| [petrel-plan.md](petrel-plan.md) | Course thesis (coast cheese, death=reset) |
| [obstacle-avoidance.md](obstacle-avoidance.md) | Historical hop-polish notes — **superseded** for architecture |

---

## 1. Goal (one sentence)

Get from sparse strategy beats to the next beat the same way RealPlayerBot
does: **plan → follow → recover → replan**, ordinary keys only — until pose
arrives or we hard-fail with a readable error.

Fair play is **not** “no intermediate goals.” Fair play is **no carpet of
hand waypoints as the path** and **no cheats**. Sparse beats + real feet
between them is the intended shape.

---

## 2. Why shortcuts make everything take longer

We already paid for:

1. In-process Lua (`libpetrel`) so strategy can sit next to RPB policy  
2. A call into `advanceRouteTo`  
3. Sparse wet beats in config  

Then repeatedly undercut that with **half the feet stack**. Each half-hook
looks faster in the moment and burns a day of thrash diagnosis later.

| Shortcut | Immediate feel | Actual cost |
|---|---|---|
| Face+W hop toward continent point | “Moving!” | Cliffs, huts, thrash, motion sickness |
| Call `advanceRouteTo` once; treat `rpUnavailable` as terminal idle | “Nav is wired” | Stuck on first rock while other bots recover and finish |
| Custom “recover-step” after `resetNavigation` instead of RPB recovery | “Unstuck” | Fights safe-descent / floor-mismatch / graph recovery already in RPB |
| One wet goal = merchant thousands of yards away | “Simple swim” | Direct liquid into coast geometry; early freeze; false “nav broken” |
| Stuck-tick replan band-aid only | “Something tries” | Masks missing recovery ownership; never root-cause |
| L/R thrash / jump unstick | “Busy” | Zero pathing value; banned for motion sickness |
| Micro-waypoint carpet in Lua | “It works for this week” | Unmaintainable for weekly start/end and other comps |

**Rule of record:** if a change reintroduces straight-line A→B as *the path*,
or owns recovery outside RPB’s navigation owner without fully replacing that
owner, it is **not done**. Do not claim pathing. Ship the full behavior or
leave the branch unmerged.

**Why this is structural, not moralizing:** RPB navigation is ~3.3k lines
(`navigation.nim` + `navigation_steering.nim` + `navigation_graph.nim`) of
Detour corridors, liquid legs, collision probes, safe descent, and
source-pose recovery. Reimplementing 5% of that in the Petrel pilot creates
a second, worse state machine that cannot use the other 95%.

---

## 3. What RealPlayerBot actually does (source truth)

Do not invent a second feet model. Read and call this stack.

### 3.1 Entry point

**`advanceRouteTo`** (`bots/real_playerbot/policy/navigation.nim`) is the
single feet owner for “go to this world point.” It already branches:

1. **Arrival** — pose inside stop distance → `rpReached`, stop keys  
2. **Safe descent in progress** — continue `advanceSafeDescent`  
3. **Liquid route** — when `continuesLiquidRoute` (swimming + liquid known,
   or retained direct-water key through shoreline interval): install a
   **one-waypoint direct water segment**, `appendSteering` to target, return
   `rpFollowing`. Ground navmesh triangles **do not cover open water**.  
4. **Short direct ground step** — collision-probed proximity when allowed  
5. **`prepareRouteTo`** — Detour corridor request / settle  
6. **`rpUnavailable` recovery graph** — not idle forever:
   - safe descent if armed  
   - source-projection failures → local collision step / `beginSafeDescent`  
   - follow prepared route when corridor exists  
7. **`rpFollowing`** → `followPreparedRoute` (waypoint advance, bearing block)

Progress enum:

| Value | Meaning |
|---|---|
| `rpPlanning` | Route request outstanding; movement held |
| `rpFollowing` | Emitting ordinary keys toward corridor / liquid target |
| `rpReached` | Inside stop envelope |
| `rpUnavailable` | No live corridor **this tick** — RPB may still be recovering next tick |

### 3.2 Liquid reality (critical)

Open water is **not** on ground navmesh tiles. Asking Detour while swimming
for a far wet point produces:

> could not project source or target onto loaded navmesh tiles  

That is not “pathfinding broken.” That is **wrong surface**. RPB’s answer is
the **direct water route** (steering on ordinary swim input), not mesh.

Direct liquid to a **multi-thousand-yard** merchant is still a bad *strategy*
(coast clipping, fatigue, early freeze). The fix is **strategy: sparse
open-water intermediate beats**, not inventing a second swim mesh or a hop
carpet. Each wet leg still uses the same liquid branch of `advanceRouteTo`.

### 3.3 Land recovery reality

When mesh says no path from this pose, stock RPB does **not** stop forever.
It runs bounded recovery (safe descent, local collision-approved step, graph
request, replan from a new source pose). Petrel must **stay inside that
owner**, not `resetNavigation` + DIY face+W and hope.

### 3.4 What RPB does *not* put in `advanceRouteTo`

| Concern | Owner |
|---|---|
| Which continent goal / weekly end | Strategy / world knowledge / activity legs |
| Forms (Travel / Aquatic) | Travel / spell policy + our Lua |
| Death / ghost | Lifecycle — Petrel: **reset run**, not ghost thrash |
| Combat during travel | Combat policy (out of traverse V1 scope unless it blocks feet) |

Continent-scale intermediate **activity legs** live in
`world_knowledge.nim` for stock quests. Petrel’s analogue is **sparse beats
in config**, not a second continent graph in Lua.

---

## 4. Target architecture (locked)

```text
  traverse_beats.json          sparse major goals only
         │
         ▼
  libpetrel / traverse.lua     strategy: active beat, forms, wet-only prove
         │  navigate { x,y,z?, stop, mode, reason }
         ▼
  fork visual_adapter          Petrel pilot host
         │
         ▼
  RPB advanceRouteTo           FULL owner: plan / follow / liquid / recover
         │
         ▼
  ClientInputBatch             ordinary keys only
```

| Layer | Owns | Must not own |
|---|---|---|
| **Beats (data)** | Ordered major checkpoints; wet intermediate open-water points | Hop polylines, rock detours, seaward “pathing” math |
| **Lua strategy** | Which beat is active; Aquatic/Travel gates; death=hold/reset; wet prove | Corridor geometry, recovery, thrash unstick |
| **Nim Petrel host** | Wire view → Lua → **one** feet call; status/logging; cast lowerer | Second recovery state machine that fights RPB |
| **RPB navigation** | Mesh, liquid direct, steering, stuck recovery | Course story / weekly points |

### Intent contract (Lua → host)

```text
navigate {
  x, y, z?, map_id, stop_distance,
  mode: "land" | "liquid_prefer",
  reason, beat_id
}
cast_form { spell }
hold { reason }
```

Host maps `navigate` → `advanceRouteTo` (same target every tick until Lua
advances the beat). Do not invent hop intents as pathing.

---

## 5. Honest current state (2026-08-06)

| Piece | State | Gap |
|---|---|---|
| Embed Lua + libpetrel | Done | Keep; no bridge-exec revival |
| Sparse beats + wet_leg_a–d | In config / Lua | Tune only if legs beach or skip water |
| Host calls `advanceRouteTo` on land | Present | Recovery must remain **inside** RPB, not DIY-only |
| Custom swim branch (`appendSteering` + liquid summary) | Present | Prefer **letting `advanceRouteTo`’s liquid path own it** so shoreline retention (`continuesLiquidRoute`) stays correct |
| DIY recover-step after `resetNavigation` | Present | High risk of fighting safe-descent / failure keys — audit vs RPB `rpUnavailable` branches |
| Stuck-tick periodic replan | Present | Acceptable as **last resort**; not a substitute for recovery ownership |
| Status: planning/following/unavailable + nav error | Partial | Must be always-on and greppable every freeze |
| Land prove rock → recover | Not signed off | Phase B |
| Wet prove → merchant ≤100 yd wet | Not signed off | Phase C–D |
| Hop lowerer / L/R thrash as pathing | Retired / banned | Do not resurrect |

---

## 6. Implementation plan (order is the point)

Do these **in order**. Skipping to “just make it swim” is how we get another
week of thrash.

### Phase 0 — Stop lying to ourselves (instrumentation)

**Done means:**

- [ ] Every navigate tick surfaces: `progress` (`planning` | `following` |
      `reached` | `unavailable`), `routeKey` / beat reason, `navigation.error`
      if any, planar distance to target, swimming flag.  
- [ ] Status file / summary string is enough to diagnose a freeze without
      attaching a debugger.  
- [ ] Unit tests assert status fields exist (structure), not live mesh.  
- [ ] Written rule in this doc (already): `unavailable` with no recovery
      attempt for N ticks is a **bug**.

**Not done:** printing “following” while pose is frozen for minutes with no
error string.

### Phase 1 — One feet owner on land (no DIY recovery fork)

**Done means:**

- [ ] Land `navigate` goes through **`advanceRouteTo` only** as the movement
      emitter (with `bearingProbe` wired the same way other pilots set it).  
- [ ] On `rpUnavailable`, **do not** invent a parallel recovery graph. Prefer
      leaving RPB’s next-tick recovery armed (safe descent / beginRoute).
      If a Petrel-side replan is required, document *why* RPB’s branch was
      insufficient and keep it minimal (e.g. clear only after terminal
      failure reason + new pose).  
- [ ] Delete or gate any recover path that is pure face+W without collision
      probe if it can run *instead of* RPB recovery.  
- [ ] **Prove A:** Tanaris start → `water_entry` region without permanent rock
      freeze; pose advances or error is explicit (mesh helper down / no tiles).  
- [ ] **Prove B:** forced stick near known furniture → recovery motion within
      tens of seconds or hard-fail with error text.

**Not done:** “calls advanceRouteTo” while still freezing on first
`rpUnavailable`.

### Phase 2 — Water: strategy legs + RPB liquid owner

**Done means:**

- [ ] Wet strategy uses **few open-water intermediate beats** (config), not
      merchant-only. Current `wet_leg_a`…`d` pattern is the right *shape*;
      adjust coordinates only with evidence (beaching, inland cut).  
- [ ] While swimming / observed liquid, movement uses **RPB’s liquid path**
      (via `advanceRouteTo` / `continuesLiquidRoute`), not a one-off host
      fork that forgets shoreline retention.  
- [ ] Aquatic Form cast **before** long wet progress; do not re-cast form
      every tick (toggle-off bug).  
- [ ] **Prove C:** from `water_entry` / first wet leg, measurable **northing**
      (world X for this league) while swimming, without freeze in the first
      few hundred yards from mesh projection errors.  
- [ ] No land-cut victory on the wet prove.

**Not done:** one straight swim intent to merchant; mesh calls on open water
as the primary path.

### Phase 3 — Merchant prove

**Done means:**

- [ ] Wet-only arrival ≤ **100 yd** of merchant (or current week end beat).  
- [ ] Status shows wet legs advancing; no tele / GM / ghost thrash.  
- [ ] Death mid-run → reset policy (petrel-plan), not recovery-as-progress.

### Phase 4 — Multi-comp feet freeze

**Done means:**

- [ ] Same host + RPB feet stack; only beat JSON + thin Lua change for a new
      course.  
- [ ] Weekly start/end is data.  
- [ ] No competition-specific recover thrash in the host.

---

## 7. Explicit non-goals

| Non-goal | Why |
|---|---|
| Reimplement Detour / navmesh in shadow-army or Lua | Upstream owns it |
| Per-tick process-spawn bridge | Dead; embed won |
| Hundreds of hand waypoints as the path | Fair-play / maintainability fail |
| L/R thrash, jump-strafe unstick as pathing | Motion sickness ban |
| Ghost / Spirit Healer as default pathing recovery | Death = reset run |
| Tele / GM / memory progress | Hard rules / fair play |
| “Just hop better” as the long-term system | Already proved insufficient |
| Parallel recovery state machine “inspired by” RPB | Will drift and thrash |

---

## 8. Decision record (answer before more code)

| # | Question | Decision |
|---|---|---|
| D1 | Primary wet approach? | **Sparse open-water beats + RPB liquid leg per beat.** Not a waypoint carpet; not one continent chord. |
| D2 | Who owns post-`unavailable` recovery? | **RPB `advanceRouteTo` recovery graph first.** Petrel host may only replan on terminal failure + pose change, with a documented reason. |
| D3 | Custom host liquid branch vs `advanceRouteTo`? | **Prefer full `advanceRouteTo`.** Custom branch only if proven equivalent to `continuesLiquidRoute` + steering; otherwise delete it. |
| D4 | Navmesh helper down? | **Hard fail loud** in status (no silent freeze pretending to follow). |
| D5 | Death? | **Reset run** (petrel-plan). Not in pathfinding scope. |

---

## 9. Code map (where work goes)

| Area | Path |
|---|---|
| Strategy / beats | `lua/entry/traverse.lua`, `lua/config/traverse_beats.json` |
| Lua embed | `tools/petrel_embed.nim` / `tools/libpetrel.so` (build path per Makefile) |
| Feet host | **fork** `player/runtime/visual_adapter.nim` → `runPetrelPilot` |
| RPB nav (read / call, don’t fork logic) | fork/upstream `bots/real_playerbot/policy/navigation.nim` (+ steering, graph) |
| Status / prove | `local_data/traverse-cv-status.json`, `make traverse` / `tools/traverse_cv.sh` |
| Structure tests | `tools/tests/test_pathfinding_structure.nim`, `lua/tests/test_traverse_*.lua` |
| Architecture prose | this file + [pathing.md](pathing.md) |

**Upstream is read-only** for the Softmax pin checkout. Client-side Petrel
host changes live on **the fork** only. Do not reimplement RPB recovery in
shadow-army Nim.

---

## 10. Success bar (when we can stop touching feet)

1. **Land:** desert rocks do not end the run — path around or RPB recovery
   moves the pose; freezes have an error string.  
2. **Water:** not one straight line to merchant; sparse wet legs + liquid
   owner; measurable northing while swimming + Aquatic.  
3. **Honesty:** `unavailable` either recovers or fails loud — never silent
   multi-minute freeze with “following” cosplay.  
4. **Sparsity:** beats stay few; all geometry between beats is nav + RPB
   recovery, not Lua hop math.  
5. **Reuse:** another competition changes beats/policy, not feet.  

Until those five hold, pathfinding is **not done**, regardless of how many
times `advanceRouteTo` appears in a diff.

---

## 11. Agent / engineer operating rules (anti-shortcut)

1. **Read RPB before writing recovery.** If the behavior exists in
   `advanceRouteTo`’s `rpUnavailable` branch, call it; do not re-code it.  
2. **One owner for keys per tick.** Either RPB navigation emits the batch or
   a cast/hold path does — not thrash + nav fighting.  
3. **Strategy vs feet.** Changing course = config. Changing stuck-on-rock =
   feet. Do not fix feet bugs by adding more Lua coordinates unless the bug
   is “leg is on land.”  
4. **Prove with pose, not summary strings.** “following” without delta pose
   is failure.  
5. **No tele to validate pathing.** Checkpoint SOAP for *setup* is operator
   tooling; pathing prove is ordinary movement.  
6. **Tests stay green and instant** for structure; live prove is integration.  

---

## 12. See also (upstream symbols)

- `prepareRouteTo` / `advanceRouteTo` / `followPreparedRoute` /
  `advanceSafeDescent` / `continuesLiquidRoute` / `observedLiquidRoute` /
  `resetNavigation` — `navigation.nim`  
- Steering: `appendSteering` — `navigation_steering.nim`  
- Local graph recovery: `navigation_graph.nim`  
- Activity / intermediate legs pattern (stock quests): `world_knowledge.nim`  
- Travel form speed choice: `travel.nim` (orthogonal to corridor planning)

---

*If you find yourself adding a “temporary” hop, thrash, or DIY recover “just
until merchant works,” stop. That temporary path is how this challenge loses
days. Finish the phase you are on.*
