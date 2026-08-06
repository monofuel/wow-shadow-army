# Petrel — complete Kalimdor Traverse plan

**Policy name:** Petrel (was Ibis)  
**Plan of record** for this challenge. Day notes and detail docs hang off this
file — do not fork a second strategy elsewhere.

| | |
|---|---|
| **Status** | Stack + water-entry **proven**. Leg 2 **wet-only re-prove in progress** (no land-cut; merchant only while swimming + Aquatic). |
| **Horizon** | Contender before the weekend if leg 2 lands. |
| **V2 notes** | Stay secret until working locally (scratchpad only). |

| Doc | Role |
|---|---|
| **This file** | Full plan: thesis, stack, legs, fatigue, success bar, non-goals |
| [traverse-2026-08-05.md](traverse-2026-08-05.md) | Day checklist / scratchpad (points here) |
| [clientview-migration.md](clientview-migration.md) | ClientView pilot how/why (done) |
| [obstacle-avoidance.md](obstacle-avoidance.md) | Optional land polish (not blocking) |
| [traverse_wow.md](traverse_wow.md) | League rules / scoring / submit gates |
| [army-debug.md](army-debug.md) | Old `/env` army_host debug port (not CV path) |

---

## Competitive thesis

**Score (league):** maximize Kalimdor map-1 **northing** = world **X** within
fixture bounds. **Y is not the gate today.**

**Our bet:** **swim the coast** from Tanaris water north (and beyond), with
**Aquatic Form (+50% swim)** and **Travel Form (+40% land)**, so we **never take
the Thousand Needles great lifts.**

The field is stuck teaching bots the **elevator**. We already clear
**Tanaris land → water entry** on the same ClientView stack coworkers use. If
**swim → merchant coast** finishes cleanly, we have a **real contender** while
everyone else is still on lifts.

Two long-term shapes (same early legs):

1. **Coast cheese (primary):** stay wet as far as rules allow; optionally
   land-cut Azshara or swim around it. Best while score is **X-only**.
2. **Hybrid (if Y is scored later):** swim Tanaris → Barrens, then land
   Ashenvale → Felwood → Winterspring — **still skip the lifts**.

Fair play only: ordinary client movement/input. No tele, no GM, no cheat
northing, no out-of-band collusion.

### Death policy (locked)

**If the bot dies mid-run: stop that run, reset, and try again.** Do **not**
invest in revival recovery.

| Do | Don't |
|---|---|
| Kill the pol / client, relaunch `traverse` / `traverse_cv_pol` from a clean spawn | SOAP / GM `revive` as part of the prove loop |
| Treat fatigue / beach / combat death as a **policy bug** to fix and re-run | Ghost pathing to Spirit Healer, gossip thrash, or long hangouts on corpse |
| Spend agent time on coast hug, form stick, and wet-only progress | Messing with realm SOAP enable races just to unstick a dead seat |

Rationale: leg 2 is a long coast prove; revival ops (SOAP on 7878, ghost
interact headless) burn more time than a clean restart and are not fair-play
gameplay. Ghost / Spirit Healer code in the pilot may still exist for
defensive completeness — it is **not** the recovery plan of record.

---

## Stack (locked)

| Layer | Choice |
|---|---|
| Control | **ClientView → ClientInputBatch** (rendered contract; coworker path) |
| Pilot | `lua/entry/traverse.lua` via `tools/traverse_lua_bridge` |
| Process | Headed/headless **player** + `TRAVERSE_LUA_BRIDGE` (not `/env` army_host) |
| Launch | `make traverse` (headless), `make traverse-headed` |
| Prove loop | `tools/traverse_cv_pol.sh` watches `local_data/traverse-cv-status.json` |
| Forms | **Shapeshift bar**, not main action bar 1–12. Travel **783**, Aquatic **1066** |
| Form gap | **Classic auto-cancels Travel on water entry and Aquatic on exit.** No `/cancelform`, no leave-form cast. Walk in Travel → gap is automatic → Aquatic once swimming. |
| `/env` | Frozen — no further investment for this challenge |

### Code map

| Piece | Path |
|---|---|
| Policy (legs, forms, coast bias) | `lua/entry/traverse.lua` |
| Policy unit tests | `lua/tests/test_traverse_entry.lua` |
| ClientView → Lua table | `src/traverse_cv/project.nim` |
| Intent → ClientInputBatch | `src/traverse_cv/lower.nim` |
| Bridge CLI | `tools/traverse_lua_bridge.nim` |
| Launch / pol | `tools/traverse_cv.sh`, `tools/traverse_cv_pol.sh` |
| Fork hook | player `visual_adapter.nim` when `TRAVERSE_LUA_BRIDGE` is set |

---

## Legs

### Leg 0 — Stack (done)

- ClientView Lua pilot on player (`TRAVERSE_LUA_BRIDGE` → bridge → enqueue batch).
- Operator path: `make traverse` / `make traverse-headed`.

### Leg 1 — Tanaris land → water entry (done, live)

| | |
|---|---|
| Goal | `-6784.5, -4833.9, 0.7` (north desert water) |
| Success | planar dist ≤ **50** yd |
| Land | **Travel Form** always |
| Water | **Aquatic Form** whenever swimming (no breath death) |
| Combat | Prefer outrun; no full combat AI on this strip |
| Pathing | Straight-ish; minor hut/hill slide OK ([obstacle-avoidance.md](obstacle-avoidance.md)) |

### Leg 2 — Swim north → merchant coast (**active — weekend gate**)

| | |
|---|---|
| Goal | water near merchant coast ≈ `-1533.7, -4056.5, -12.3` |
| Success | planar dist ≤ **100** yd; hold intent `merchant_coast` |
| Form | **Aquatic Form** the whole time in water |
| Path | Stay **in water**; prefer not beach-running; avoid shore trash |
| Elevator | **Still skipped** — that is the point of the swim |
| Defaults | Bridge / pol: `TRAVERSE_GOAL_*` merchant, r=100, long max (~3600s) |

**Policy behavior (already in Lua):**

- After water entry / once swimming / once north of entry → chase merchant.
- Segment hops along the goal vector.
- **Coast corridor bias** (geometry proxy for fatigue / deep ocean): soft/hard
  lateral pull toward the water_entry→merchant line; limited pull per hop so
  we do **not** thrash or hunt cliffs every tick.

**Fatigue (critical on this leg):**

The strip between **Tanaris and Dustwallow / open ocean** is partly **not a
“real” game area**. Manual run: **crossable**, but safe fatigue-clear spots
are **sparse**.

| Fatigue band | Behavior |
|---|---|
| 0–~25% | **Ignore** — keep northing |
| ~25–50% | Soft bias toward safer water if easy; **no hard detours** |
| ~50–60%+ | **One** deliberate correction (angle to coast / cliff touch), then resume |
| Near death | Any shoreline contact |

**Speedrun rules:**

- **1/4–1/2 fatigue is OK.** Race, not full clear.
- **No thrash / oscillation** on cliff hunt (hysteresis, max detour, only
  correct when coast is actually near).
- **Do not** ignore fatigue until empty in deep ocean.
- Prefer **continuous northing** with **rare** top-ups.

If ClientView exposes a real fatigue field, project it into the Lua table and
drive the bands above. Until then, **geometry corridor** is the proxy
(already sketched in policy).

### Leg 3 — Merchant coast → further north (after leg 2 green)

- Manual: swim **along the coast**, not open ocean straight to Orgrimmar.
- Direct ocean to Org may be too far (unproven) — prefer coast hug.
- Azshara land cut is nasty (~`2294.7, -5573.0`: slows, hard mobs); swim around
  may be easier for AI.

### Leg 4 — Submit / field (when local leg 2 is green)

- Same ClientView packaging coworkers use for hosted traverse.
- Prefer short leg proofs + **one** long overnight, not infinite 45m thrash.

---

## Swim-north checklist

| Need | Status |
|---|---|
| Aquatic when swimming | **In Lua** (`ensure_aquatic_form` / 1066); shapeshift, not bar 1–12 |
| Travel on land | **Done** (leg 1) |
| Multi-leg goals (leave water-entry hold) | **In Lua** — merchant goal + hold `merchant_coast` |
| Swim hops | Hop-move lowerer; optional liquid/nav later |
| Fatigue / ocean safety | Geometry coast bias in Lua; real fatigue field if/when available |
| No thrash | Soft/hard pull caps; hysteresis rules above |
| Stay off beach trash | Prefer wet lane; outswim; no full combat AI |
| Live watch | status JSON + headed; formal bridge admin port optional |
| Death mid-run | **Reset + re-run** — no SOAP/GM revive, no ghost recovery loop |
| **Live prove ≤100 yd merchant (wet + Aquatic)** | **In progress** — wet-only gate; land-cut prove rejected |

Optional (not blocking contender): land obstacle polish; rehome army_debug onto
the ClientView bridge.

---

## Debug / operator surface

| Surface | Notes |
|---|---|
| Headed | `make traverse-headed` |
| Headless + prove | `tools/traverse_cv_pol.sh` (or `make traverse` + watch status) |
| Live pose | `local_data/traverse-cv-status.json` (dist, intent, form, swimming) |
| Occasional dump | `local_data/traverse-cv-last-view.json` |
| Env overrides | `TRAVERSE_GOAL_X/Y/RADIUS`, `TRAVERSE_WATER_*`, `TRAVERSE_CV_MAX_SECONDS` |
| army_host `:7788` | **`/env` only** — not on ClientView pilot yet |
| Hot Lua | Bridge re-reads disk each decide; formal admin reload = future rehome |

For leg 2, **status JSON + headed** is enough. Small bridge admin port is nice
for LLM live debug on 45m swims, not required for the first prove.

---

## Week shape

| Focus | Outcome |
|---|---|
| **Now** | Prove leg 2 live: water entry → merchant-ish water ≤100 yd, aquatic held |
| **Same window** | Fatigue / coast bias: mid fatigue OK, no thrash, no ocean death |
| **Then** | Coast further north; one long run; package for field if green |
| **Do not** | Rebuild `/env`; solve elevator; full combat AI; perfect navmesh first |

If leg 2 works, strategy is **ahead of the elevator pack** even if land pathing
still looks a bit slidy.

---

## Risks

| Risk | Mitigation |
|---|---|
| Fatigue thrash / cliff hunt | Hysteresis + max detour; accept mid fatigue |
| Deep ocean death | Soft band + rare shore touch; coast-relative geometry; **if dead → reset + re-run** |
| Form drop in water | Aquatic re-cast loop (already in Lua) |
| Coast combat | Stay wet; wide berth to shore; don’t stop for trash |
| Long-run opacity | status JSON; optional bridge admin later |
| Death recovery rabbit-hole | **Do not** — no SOAP revive loop; fix policy and restart |
| Score rule adds Y | Hybrid land route after Barrens — still skip lifts |

---

## Success definitions

**Contender (weekend bar):**

1. Repeatable ClientView run: spawn → Travel Form → water entry → Aquatic Form.
2. Continues north; **planar dist ≤ 100 yd** of `-1533.7, -4056.5` (merchant-coast
   water) without drowning / thrashing to death.
3. **No** Thousand Needles lifts.
4. Operator path stays `make traverse` / `traverse-headed` (+ pol for prove).

**Win later:** full coast / Azshara / northing competitive with field package.

---

## Explicit non-goals (this sprint)

- `/env` army_host feature work  
- Great lifts / elevator pathing  
- Full RPB combat / questing  
- Perfect hut pathing (nice, not required)  
- Gutting Softmax game HTTP  
- Filling `kb/` for a planner that does not exist yet  
- **SOAP / GM revive** as the recovery path for wet-prove deaths  
- Polishing headless ghost → Spirit Healer just to continue a failed run

---

## Helpful coords (quick ref)

| Place | Approx XYZ |
|---|---|
| Water entry (Tanaris north water) | `-6784.5, -4833.9, 0.7` |
| Merchant-coast water | `-1533.7, -4056.5, -12.3` |
| Azshara land sample (nasty) | `2294.7, -5573.0, 24.2` |
