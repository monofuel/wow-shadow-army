# Traverse (Kalimdor league) — Petrel

Home for **Kalimdor Traverse** notes, plans, and version labels. Point new
traverse writeups here instead of scattering under `docs/`.

**Petrel** is our traverse bot. Same bot across every hosting era — the
brain is `lua/entry/traverse.lua`, today running on the generic **lua-bot**
host in `monofuel-vanilla-wow` (`--bot=lua-bot --lua-entry=traverse`),
which replaced the earlier libpetrel `.so` / ClientView bridge plumbing.

## Speedrun doctrine (non-negotiable)

Traverse is a **speedrun**: run and swim north, nothing else. From
monofuel's manual run of the course:

1. **Never fight.** No attack intents, ever. Mobs cannot kill a bot that
   keeps moving; outrunning them is the entire defense.
2. **Never corpse-run.** Death means the run is over — the brain holds with
   `run_over` and stops. Do **not** implement corpse recovery: past agents
   burned hours building corpse-run behavior when the bot got stuck and
   died, and every one of those hours belonged on the *underlying*
   pathfinding/streaming bug that let the bot stop moving. That is how
   speedruns work: you don't recover a dead run, you fix the run.
3. **Keep moving; treat a stall as evidence.** The brain logs a loud
   `STALL` line (position + nav state) and holds its goal. It never
   thrashes destinations to escape a stall — a healthy route with a frozen
   seat is a host/client bug to diagnose, not a brain state to farm.
4. **Never heal, never defensive-cast.** Casting means standing still, and
   standing still is the only way this bot dies. In-combat heals are
   strictly worse than running: vanilla spell pushback rewinds the cast bar
   on every hit while the mob keeps swinging. Travel Form + motion is the
   entire defense; the only casts the brain may ever emit are the two
   forms. (Cautionary tale: GPT 5.6 Sol's Felwood heal stack, 2026-08-10 —
   Nature's Grasp/Barkskin/Rejuv/Healing Touch on four timers turned the
   run into stop-cast-die. Third AI to try some form of this. The lua test
   suite now carries a doctrine guard that fails on any heal/defensive
   spell ID in the brain.)
5. **`/cancelform` does not exist in 1.12.** At least three AIs have now
   hallucinated this command; typing it does nothing and the host machinery
   built around it stands the bot still until a timeout. Forms drop
   automatically when relevant (Travel Form on entering water) and toggle
   by recasting — nothing on this run ever needs a form canceled. Any plan
   containing `/cancelform` or mid-run healing is wrong by construction;
   the doctrine guard in `lua/tests/test_traverse.lua` fails on the string.

## Mission facts

- League `kalimdor-south-to-north`: one isolated **level-60 tauren druid**
  (39-twink kit), spawn Tanaris `(-9187.0, -2530.25, 14.09)`.
- Goal: **Everlook, Winterspring** `(6687.33, -4647.67, 721.68)`, radius
  300. Course length 15,874 yd.
- Score: `max(0, min(final_x, 6687.333) - (-9187))` — **pure X-northing**
  (Kalimdor +X is north). Every yard north pays; nothing else does.
- Episode: `max_ticks 2700 / tick_rate 10` at 10× sim = **270 wall
  seconds** (~45 sim minutes).
- Proof-of-life criteria: level 60, map 1, ≥50 yd movement, ≥6 accepted
  inputs (`player/launch/proof_of_life.py`).
- Fair play: no mounts, no relocation, no hand-authored continent route;
  sparse strategy beats + shared mesh navigation are allowed
  ([traverse_wow.md](traverse_wow.md)).

## Route status by segment

| Segment | Beats | Status |
|---|---|---|
| Land approach: spawn → desert ocean coast | `land_approach`, `water_entry` | **Proven** — `make traverse-desert` (2 consecutive PASSes 2026-08-09) |
| Fatigue swim: wet start → Dustwallow coast | `ribbon_001..N`, `duskwallow_coast` | **Active** — packaged-liquid regression fixed; latest run died 257.2 yd short after late park/flag churn |
| Coastal swim: Dustwallow → Merchant Bay | `coast_01..N`, `merchant_coast` | **Proven** — 2 consecutive passes |
| Barrens connector: Merchant Bay → top Barrens | connector wet + land beats | **Proven** — 2 consecutive passes; terrain-fall quality warning remains |
| Northern roads: top Barrens → Timbermaw cave | `traverse_land_beats` | **Proven** — painted-road route through Ashenvale and Felwood |
| Finale: Timbermaw cave → Everlook | `traverse_finale_beats` | **Partial** — north tunnel exit and Winterspring-to-Everlook pass; southern Timbermaw WMO/MMAP transition blocked |

Each route lives as a synchronized Lua/JSON pair under `lua/config/`:
`traverse_beats`, `traverse_coast_beats`, `traverse_connector_wet_beats`,
`traverse_connector_land_beats`, `traverse_land_beats`, and
`traverse_finale_beats`. JSON is the map-browser/lint source; Lua is the
brain's copy. Keep each pair in sync when editing the route.

## Nav/water truth for the swim pass

Learned from the route engine source; do not rediscover it the hard way:

- **No route profile paths over water.** `ground`, `prefer_ground`, and
  `safe_ground` all exclude `NAV_WATER` — a navigate across a bay returns
  `unavailable`. Getting *into* the water is the brain's job (a shoreline
  beat with a small stop distance).
- Swimming is a separate **direct-water mode** inside `advanceMove` that
  engages only once the client is already `is_swimming`, then bee-lines to
  the goal. Sparse wet beats keep the bee-line hugging the coast.
- **Omit `z` on swim legs**: an unknown target Z makes the host
  surface-ride (held JUMP) instead of pitching toward the seabed.
- Fatigue offshore was the dominant historical death. The manual run's
  min fatigue remaining was 0.592 — the ribbon works, but only if the path
  does not bow seaward ([duskwallow-plan.md](duskwallow-plan.md) §1b).

## Running Petrel

| Target | What it does |
|---|---|
| `make traverse-pol` | Headless proof-of-life (fast regression) |
| `make traverse-desert` | Land-leg proof: spawn → coast, with client CPU sampling |
| `make traverse` | Headless full run |
| `make traverse-headed` | Headed run (human use — agents stay headless) |
| `make traverse-checkpoints` | List SOAP tele checkpoints (local debug) |

Readback: `local_data/traverse-status/status.json` (traverse-private —
the shared `lua-bot-status.json` is written by every lua-bot league and
gets clobbered under concurrent runs); run + CPU logs in
`local_data/health-logs/`.

## Observability: progress is not health

A run that reaches its endpoint while swimming off-plan, clipping through
terrain, or idling 20% of its time is a failing run that got lucky — and
monofuel's headed replay watches kept catching exactly those failures while
the pass/fail verdicts looked fine. Three instruments now make them loud in
headless runs:

- **Flight recorder** (brain): `FLIGHT {json}` telemetry every 5 sim-s
  (1 sim-s while anomalous) with position, hp, form, swim/combat flags,
  nav state, active beat, and cross-track distance from the beat chord —
  plus edge-triggered `EV` lines: `unplanned_swim` (land phase + swim flag:
  the lake-chord failure), `form_lost`/`form_gained`, `clip` (z jump while
  dry: terrain glitch-through), `off_line` (>35 yd off the chord for 5 s).
- **Per-run scorecard** (`tools/traverse_scorecard.py`, auto-run by the
  segment waiter): stopped seconds BY REASON, cross-track p50/p95/max,
  swim/clip/form events, hp loss per 100-yd bin (the damage map), snag
  clusters. `WARN` lines fire on: idle fraction > 0.15, cross-track
  p95 > 25 yd, any unplanned swim, any clip, any bin losing > 800 hp.
  Verdicts stay pass/fail; WARNs are the "a human would wince" channel —
  treat a WARN-heavy PASS as a bug report, not a success.
- **Route lint** (`make traverse-lint`, in `make test`): offline navmesh
  check of every land-beat leg — broken corridors, slopes the client
  cannot climb (>1.5), and water-crossing land legs (probed ground-only vs
  ground+water: the class that produced the lake and waterfall incidents)
  FAIL before any live run; hostile spawns within 12 yd of the chord WARN
  (aggro floor here is ~7–11 yd, mobs 47–53 vs a level-60 seat).

Raw feed: `local_data/traverse-status/run.log` (tee'd from every
`make traverse` / `traverse-headed` launch).

### Known issues — room for improvement (monofuel's watch, 2026-08-11)

The felwood segment gate is met (2x clean PASS), but the bot is not yet
competitive:

1. **Move -> wait -> move -> wait.** The bot still spends real time paused
   between movements. A speedrun bot should NEVER be idle — a competitor's
   bot does not pause at all and finishes the run faster than ours. The
   scorecard's idle numbers (3.7-4.1%) understate what the eye sees; the
   stop-time-by-reason taxonomy is the tool for hunting the remaining
   pauses (suspects: per-beat corridor replans, form-cast holds, the
   pilot's settle-before-cast waits).
2. **Beside the road, not on it.** The route beats sit on the painted
   road, but between beats the seat runs alongside the road or cuts
   through the woods whenever the road bends — mesh corridors are
   straight-ish chords, so every bend gets shortcut. Cross-track p95 is
   still 60-80 yd on passing runs. Getting ON the road consistently
   probably means denser bend beats from the road mask (`road_mask.py
   dump` the bends, beat the apexes) or corridor-vs-paint scoring in the
   lint — the road-following is "close-ish", not faithful.

Suspected prior blocker, still under investigation: RPB logic pegging a
core and starving world streaming, so the bot outruns terrain loading and
sticks. `traverse-desert` samples client CPU alongside bot status to catch
it in the act. Evidence first; no guess-fixes.

## Doc index

| Doc | What it is |
|---|---|
| [segment-status.md](segment-status.md) | LIVING: per-segment verdicts, failure diagnoses, next actions (Petrel battery) |
| [route-engineering.md](route-engineering.md) | The cookbook: offline corridor probing, spawn-field analysis, road detection from painted textures, trace-pinning, autopsy order |
| [reference-logs.md](reference-logs.md) | Manual F9 recordings: the Great Lift rides (both platforms, up+down) and the 77 MB coast-swim run |
| [petrel-plan.md](petrel-plan.md) | Plan of record — legs, fatigue, swim-north, weekend contender thesis |
| [duskwallow-plan.md](duskwallow-plan.md) | Isolated swim segment — water entry → Dustwallow; scoreboard + gates |
| [traverse-2026-08-07.md](traverse-2026-08-07.md) | Real goal (Everlook) + bird variants (Petrel/Skua/Gannet) |
| [traverse_wow.md](traverse_wow.md) | League scouting: rules, scoring, fixture, submission gates |
| [realign-runs-2026-08-07.md](realign-runs-2026-08-07.md) | Realign run log — per-run progress, wedges, root causes |
| [current-issues-2026-08-07.md](current-issues-2026-08-07.md) | Open issues as of 08-07 — stall class, swim corner-cutting, mob deaths, infra footguns |
| [pathing.md](pathing.md) | Layers: sparse beats + nav A→B (fair play, multi-comp) |
| [checkpointing.md](checkpointing.md) | Local wet debug: SOAP tele; Northbound2 free play |
| [merchant-bay-progress-2026-08-07.md](merchant-bay-progress-2026-08-07.md) | Swim-run evidence + fatigue findings |
| [traverse-2026-08-05.md](traverse-2026-08-05.md) / [traverse-2026-08-06.md](traverse-2026-08-06.md) | Day notes; manual-route learnings |
| [petrel-upstream-realign.md](petrel-upstream-realign.md) | *Historical* — prefer-upstream realign of the `.so`-era fork |
| [clientview-migration.md](clientview-migration.md) | *Historical* — ClientView bridge pilot (deleted in `1454caa`) |
| [embed-lua-client.md](embed-lua-client.md) | *Historical* — libpetrel embed strategy (deleted in `1454caa`) |
| [army-debug.md](army-debug.md) | *Historical* — embedded flight recorder / admin port |
| [pathfinding-plan.md](pathfinding-plan.md) | *Historical* — Nim RPB feet plan (feet now live upstream) |
| [obstacle-avoidance.md](obstacle-avoidance.md) | *Historical* — land polish notes; stuck-spot knowledge still useful |
| [traverse-2026-08-04.md](traverse-2026-08-04.md) | *Historical* — V1 `/env` PoL plan |
| [versions.md](versions.md) | `ibis:vN` engineer notes (not on the dashboard) |

*Historical* = describes plumbing deleted in commit `1454caa` (libpetrel,
ClientView bridge, army_host). The route/terrain knowledge inside those
docs is still valid; the hosting details are not.

Related elsewhere (not traverse-only):

- `../lua_architecture.md` — the lua-bot host contract
- System dashboard: http://127.0.0.1:7777/traverse
