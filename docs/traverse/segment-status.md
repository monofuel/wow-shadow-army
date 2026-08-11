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
| B | Fatigue swim | `water_entry → duskwallow_coast` | **FAIL — regression** | Bot never left the beach: parked at (-6775,-4829) in `nav=planning`, 67% idle, zero deaths. See B analysis below |
| C | Coastal swim (new) | `duskwallow_coast → merchant_coast` | **GATE MET** (2× consecutive) | 55/57 s, 36.4/32.8 yd, zero idle both. Three hazards found and fixed: two shallow sandbar legs (beats nudged via the water mask) and a sunken-ship doodad at (-3830,-4745) that dragged the seat 12 yd down and cleared the swim flag — deterministic across two runs, dodged 57 yd seaward (`coast_03b`). Wade machinery observed self-recovering surface-level flag desyncs (`nav=wading`) |
| D | Barrens land hop | `merchant_coast → top_barrens` | expected fail (UNBUILT) | Zero progress — the brain has no beats here; seat sits at the merchant wet goal. 3,140 yd unbuilt |
| E | Northern land run | `top_barrens → felwood_cave_entrance` | **PASS** | 110.6 s, 23.7 yd, idle 4.5% — the painted-road route |
| F | Winterspring finale | `felwood_cave_entrance → everlook` | expected fail (UNBUILT) | Zero progress — land goal hold at the cave. 2,590 yd unbuilt, includes the Timbermaw tunnel (indoor-location risk monofuel flagged) |

**Isolation run:** `wet_start → duskwallow_coast` (lands ALREADY swimming,
skipping beach entry) **PASSes perfectly** — 35 s, 20 yd, zero idle, 0.5 s
max stationary. The swim machinery itself is fully healthy.

## Why B fails: dry beach entry lost its liquid observation

The wade-in machinery (fork `pilot.nim`: water goal + dry seat +
`liquidCoverageKnown/liquidKnown/liquidDepth` within the wade band →
`appendWadeSteering`) is intact post-merge — verified line by line. But
the seat stands 10 yd from the surf in `planning` forever, meaning the
client is not reporting observable liquid at the shoreline anymore. The
brain is exonerated: replaying B's exact frozen state through `decide()`
offline yields the correct `navigate enter_water water=true` intent.

CONFIRMED by WETSTATEDBG (2026-08-11 rerun): at the shoreline the client
reports `liquid_known=true, coverage_known=true` but
**`liquid_surface_z = -500.0`** — a sentinel where the real surface
(~0.4) used to be. The wade gate computes depth ≈ -500 and never opens.
Segment B last passed BEFORE the two upstream merges (`91cd8a33b`,
`e641af0fa`); the land gates since never exercise water. **Fork-side
issue — coordinate with the agent doing the upstream realign; do not hack
the lua-bot layer** (prefer-upstream tenet; ledgered in
upstream-health.md with the evidence line). Entry is stochastic, not
absolute: the rerun got 1,300 yd into the swim before a formless
swim-flag desync mid-ocean turned it around — so the sentinel bites at
SOME shoreline poses, always at the water_entry tele pose.

## Why C fails: swim-flag desync with no recovery path

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

1. Read WETSTATEDBG evidence from the B/C reruns; file the fork
   observation report (or brain-side recovery if the data allows one).
2. Build D (Merchant Bay → top of Barrens): open-Barrens road terrain;
   road mask + spawn DB apply directly.
3. Build F (cave → Everlook): Timbermaw tunnel first — expect indoor
   navigation questions; scout with a headed run before route work.
