# Petrel segment status

Living doc: the per-segment state of the Petrel route (long-swim bird),
updated per battery. Battery fixture:
`make traverse CHECKPOINT=<start> END_CHECKPOINT=<end>` — verdict JSON +
scorecard per run; `best_endpoint_distance_yards` = how far a failing run
got. See [route-engineering.md](route-engineering.md) for the tooling.

## Battery of 2026-08-11 (post GPT-mess cleanup — all rows OUR verified runs)

| # | Segment | Checkpoints | Verdict | Detail |
|---|---|---|---|---|
| A | Tanaris desert | `spawn → water_entry` | **PASS** | Stable; reconfirmed inside the stitched run |
| B | Fatigue swim | `wet_start → duskwallow_coast` | **HARDENED + FORK-GATED** (3 PASSes: 39.0/37.5/33.5 s) | Route rebuilt on corrected terrain data (see B analysis); remaining failures are post-merge client flag desyncs whose sites move run to run. Gate pending the fork stability fix |
| C | Coastal swim | `duskwallow_coast → merchant_coast` | **GATE MET** | Reconfirmed post-fix: PASS 53.0 s / 39.0 yd |
| D | Barrens connector | `merchant_coast → top_barrens` | **GATE MET (3× consecutive)** | 84.5 / 50.0 / 53.0 s, zero deaths, zero snags — after killing GPT 5.6 Sol's wet-z "shore" bypass (see D analysis) |
| E | Northern land run | `top_barrens → felwood_cave_entrance` | **PASS** | Painted-road route, stable |
| F | Winterspring finale | `felwood_cave_entrance → everlook` | **FORK-BLOCKED (route ready)** | The cave is now a 37-beat walked-ground interior chain resampled from monofuel's manual F9 logs; the exterior over-mountain node is deleted. Live navigation waits on two fork features (see F analysis) |

## Why D failed before (now GATE MET): the wet-z "shore" bypass

GPT 5.6 Sol's `barrens_shore` beat carried `shore = true` + z = +9.5,
bypassing the -2.5 yd draft clamp. A swimming seat commanded above the
surface holds swim-ascent JUMP and launches clear of the water (Aquatic
auto-cancel, breath panic) — the exact documented failure the clamp was
built against; monofuel watched it drown repeatedly. Fixes, live-proven:

1. Draft clamp unconditional again; the `shore` flag is gone from the
   schema (schema-level test forbids it).
2. The exit beat's PLANAR target sits up the beach so the engine's 8 yd
   stop ring lands on dry sand. Live-run evidence forced this: a waterline
   target was "reached" at depth 1.4 with the swim flag still up — parked
   wet forever. The swimmer must ground (stock client clears swimming on
   the rising floor) before it can stop; the land connector owns the run
   from there.
3. `connector_swim_02` swung seaward off a sandbar 1.9 yd proud of the
   surface that the old chord crossed (water-mask audit; C's sandbar
   lesson, applied offline this time).

Residual (non-blocking, upstream class): 1–6 transient mid-water Aquatic
flickers per run, all self-recovered at the surface. Depth is what makes
them lethal — see B.

## Why B is fork-gated: the route is at its structural ceiling

The 2026-08-11/12 hardening campaign (11 instrumented runs) fixed every
terrain hazard the corrected sampler could see: the -5675 wall re-cut,
the -5150 spur, the -5480 headland, two guard beats, the y=-4800
chunk-seam freeze (three swimmers froze AT the seam — crossing removed),
and a fatigue-ladder truth pass (042's refill flag was a phantom; 043's
chunk is genuinely safe; 040 centered for real dwell). The road_mask
MCVT/MCLQ axis transpose was found and fixed in the process — all prior
slope depths were fiction. Three PASSes with improving times followed —
but a 16-yd wander-band audit shows 26 of 49 legs under band: a coastal
ribbon cannot out-route the 10x controller's ±18 yd wander. B gated 2×
pre-merge on a TIGHTER route; the post-merge mid-swim flag desync is the
sole remaining blocker (ledgered with statistics).

## Older B analysis: flag desync at depth + unknown shoreline liquid

Instrumented repro (2026-08-11): four Aquatic/swim-flag drops in one run
(x -6692, -6263, -5961, -5653). Three self-recovered at the surface. The
fourth hit the -5675 wall under-gap dive — the one deep point on the
ribbon — and a deep seat with no swim flag has no water physics: it fell
through the column (EV clip chain z -235 → -602) until the server
failsafe relocated it 1,500 yd back. `FLIGHT` shows `nav=following` with
the correct commanded dive profile — nothing brain-side to fix, and the
seaward bypass around the wall costs a full fatigue bar (unaffordable).

Second blocker: after the failsafe the seat parked at the beach
(-6776,-4828) with `WETSTATEDBG lk=false` — the fork's `22c612006`
REJECTS the below-terrain liquid sample instead of correcting it, so
`liquid_known=false` at the shoreline and the wade entry gate can never
open. Dry entry (`water_entry` fixture) stays blocked; this replaces the
old -500 sentinel as the entry blocker. Both ledgered with asks in
`~/src/wow-coworld/upstream-health.md`.

History: B gated 2× on 2026-08-10 pre-merge — the desync frequency is a
post-merge regression, not a route problem.

## Why F waits on the fork: no steering, no jumping inside the WMO

Committed-contract research (2026-08-11): the lua-bot contract's only
movement kind is Detour `navigate`; the sole bearing-steer is hard-gated
on liquid; and NO call site can emit a jump. VMaNGOS Detour serves an
exterior z692 over-the-mountain corridor inside Timbermaw that the client
wedges on and falls through — and monofuel's manual walk proved the
Felwood cave lip REJECTS plain forward walking (a jump is required; the
1 Hz F9 log sampled between jump frames, see
[reference-logs.md](reference-logs.md)).

Ready and waiting traverse-side:
- 37-beat walked-ground interior chain
  (`lua/config/traverse_finale_interior_beats.*`) resampled from the
  manual logs by `tools/resample_trace_beats.py`; all `hook = true`
  (galleries double back in x), all declaring
  `navigation_mode = local_steer` + `allow_jump` (forward-safe: the
  committed parser ignores unknown intent keys).
- Brain wiring: INTERIOR owns the run from the cave mouth until its last
  beat retires, then the Winterspring finale line (exterior hold node
  deleted; `timbermaw_north_tunnel → winterspring_west_entry` bridges the
  unwalked exit tunnel — mesh probes REACH both targets at interior floor
  z ≤ 588, worst slope 1.03, so the bridge is plausible pending the
  encore walk).

Fork asks (ledgered; monofuel assigned ownership to the fork agent):
land `local_steer` (GPT draft on branch `gpt-sol-local-steer-wip`, needs
trim + review) and intent-requestable `allow_jump`
(`navigation_steering.nim:603` already supports advertised jumps behind a
flag every lua-bot call site leaves false).

Known walked-coverage gaps (encore F9 targets, ~60 s each): the mouth
passage (6517 → 6579) including the jump lip, and the exit tunnel.

## Next actions

1. Fork agent: B's flag-stability + shoreline-liquid fixes; F's
   local_steer + allow_jump. Everything else integrates the moment they
   land.
2. Stitched A–E gate (spawn → felwood_cave_entrance): attempted 2026-08-11
   and HARD-BLOCKED at the A→B seam — the seat parks at the water's edge
   (-6776,-4841) with `lk=false`, so the wade gate never opens and the run
   cannot even reach the fatigue ribbon. Same course passed 3× pre-merge.
   The shoreline-liquid fix is therefore the highest-priority fork ask:
   it unblocks segment B's dry entry AND the whole stitched course.
3. monofuel (optional, ~2 min total): encore F9 walks of the cave mouth
   passage and the exit tunnel.
