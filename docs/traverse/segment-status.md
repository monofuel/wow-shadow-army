# Petrel segment status

Living doc: the per-segment state of the Petrel route (long-swim bird),
updated per battery. Battery fixture:
`make traverse CHECKPOINT=<start> END_CHECKPOINT=<end>` — verdict JSON +
scorecard per run; `best_endpoint_distance_yards` = how far a failing run
got. See [route-engineering.md](route-engineering.md) for the tooling.

## Battery of 2026-08-11 (post coast-ribbon build, post upstream merges)

| # | Segment | Checkpoints | Verdict | Detail |
|---|---|---|---|---|
| A | Tanaris desert | `spawn → water_entry` | **PASS** | `traverse-desert`: coast reached, no stalls |
| B | Fatigue swim | `wet_start → duskwallow_coast` | **FAIL — late-run blocker** | The packaged-liquid shoreline regression is fixed in the client fork (`22c612006`): the standard already-wet fixture enters swimming and Aquatic Form normally again. The current run reached 257.2 yd from Dustwallow, then late park/flag churn left it taking fatigue damage until death. See B analysis below |
| C | Coastal swim (new) | `duskwallow_coast → merchant_coast` | **GATE MET** (2× consecutive) | 55/57 s, 36.4/32.8 yd, zero idle both. Three hazards found and fixed: two shallow sandbar legs (beats nudged via the water mask) and a sunken-ship doodad at (-3830,-4745) that dragged the seat 12 yd down and cleared the swim flag — deterministic across two runs, dodged 57 yd seaward (`coast_03b`). Wade machinery observed self-recovering surface-level flag desyncs (`nav=wading`) |
| D | Barrens connector | `merchant_coast → top_barrens` | **GATE MET** (2× consecutive) | 55.0/51.5 s, 49.4/27.0 yd, zero deaths and zero snags. The swim-to-shore handoff, Travel Form transition, Ratchet climb, Crossroads, and northern road all complete. Quality warning: p95 cross-track was ~62 yd; run 2 recovered one brief terrain fall near (-570,-3000) |
| E | Northern land run | `top_barrens → felwood_cave_entrance` | **PASS** | 110.6 s, 23.7 yd, idle 4.5% — the painted-road route |
| F | Winterspring finale | `felwood_cave_entrance → everlook` | **PARTIAL — Timbermaw south blocked** | The route is built through Everlook. `timbermaw_north_tunnel → winterspring_west_entry` passes in 5.0 s with zero idle/deaths/snags. `winterspring_west_entry → everlook` reaches town with zero deaths/snags after dodging the Winterfall camp and a permanent collision trap. The remaining southern Timbermaw transition is a client/MMAP mismatch; see F analysis below |

`wet_start` is the standard B fixture: it lands already swimming and avoids
testing a deliberately unsupported dry shoreline entry. The latest run proved
that packaged liquid and Aquatic Form engage correctly, but did not restore
the segment gate because the later park/fatigue failure killed the run.

## Why B still fails: entry fixed, late park/fatigue remains

WETSTATEDBG had shown `liquid_surface_z = -500.0` even though terrain was
above that packaged liquid plane. The fork now rejects a packaged liquid
sample below decoded terrain, matching VMaNGOS water truth; the focused swim
physics proof and Nim check pass. With that fix, `wet_start` immediately
reports swimming, casts Aquatic Form, and advances normally.

The latest correct fixture then failed much later: near the end of the
fatigue ribbon the seat entered the known park/flag-churn class, stopped
making useful progress, and died with no combat flag after health fell
2754 → 1586 → 490 → 0. Best remaining distance was 257.2 yd. This is no
longer the old shoreline/sentinel regression, and B is not signed off until
the late failure is fixed and two consecutive runs pass.

## Why F is partial: southern Timbermaw is not the Detour surface

The finale route is complete on both sides of Timbermaw. A focused
`timbermaw_north_tunnel → winterspring_west_entry` run passes, and the
Winterspring corridor reaches Everlook while avoiding the dense Winterfall
camp, a hostile spawn at the old lake beat, and the deterministic
(6757,-4489) collision trap.

The unresolved leg is `timbermaw_hold → timbermaw_north_tunnel`. VMaNGOS
Detour returns an exterior terrain route that climbs from the hold to about
z692 (`ascending_slope=2.187`) while the rendered character is inside the
Timbermaw WMO. Live, the client follows that incompatible corridor, wedges,
then falls through collision until the server failsafe relocates it. Finale
ownership now remains monotonic after that failsafe, so the failure stays
visible instead of silently sending the bot south on segment E.

The downstream Winterspring pass is functional but not yet a clean quality
gate: it recorded 22 clip events and p95 cross-track 103.6 yd while recovering
from two client falls. Endpoint result was 39.0 s, 39.0 yd, zero deaths, zero
snags.

## Why C failed (now GATE MET): grounding + wreck doodad, both fixed

The seat swam ~800 yd in Aquatic Form (WETDBG: speed 7.08, submerged,
surface 0.0), threw a form_lost/form_gained flicker, and then hung
suspended at z -9 — in water 32 yd deep per the MCLQ water mask, so NOT
grounded — with `is_swimming=false`, `nav planning→unavailable`
("source projection unavailable": a non-swimming seat can't ground-plan
from mid-ocean). Nothing recovers this state: the park detector requires
the swim flag UP; the wade band is surface-relative; the snag hop is
land-phase only. This is the known swim-flag flicker class (ledgered
upstream) in a new, stickier form. Candidate brain-side recovery: a
"sunk seat" detector (wet chain + submerged + not swimming + frozen) —
but what input actually moves that seat is a fork-physics question;
evidence first via WETSTATEDBG.

Ribbon depth audit (water mask): two beats sat near shallow sandbars
(1.4 yd / 2.4 yd legs) — `coast_04`/`coast_09` nudged to ≥3.9 yd minimum
leg depth. Unrelated to the z -9 freeze (that water is 32 yd deep) but
removes future grounding risk.

## Segment history (gates met before this battery)

- B (fatigue swim): gate met 2026-08-10 pre-merge (2× consecutive PASS,
  24.6/23.7 yd) — the regression is environmental, not route.
- E (painted road): gate met 2026-08-11 (2× consecutive PASS, zero deaths,
  zero unplanned swims) — reconfirmed by this battery.

## Next actions

1. Fix B's late park/flag-churn without changing the proven water ribbon,
   then rerun the two-pass gate from `wet_start`.
2. Add a narrowly scoped client-side WMO-interior steering solution for the
   southern Timbermaw leg once the existing dirty lua-bot interface work is
   safely integrated; do not route over the exterior z692 Detour surface.
3. Remove the recovered terrain falls in D and downstream F, then require two
   clean consecutive F passes before signing off the complete route.
