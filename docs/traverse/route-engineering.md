# Route engineering cookbook

The unreasonable techniques we use to build and debug traverse routes,
written down so the next leg (and the next AI) doesn't rediscover them.
Everything here came out of the Felwood campaign (2026-08-10/11, ~60 runs).

## The one-sentence doctrines

- **The navmesh lies about walls.** A full Detour corridor is *necessary*,
  never *sufficient*: the client's collision refuses terrain the mmaps call
  walkable (river gorges, waterfalls, switchback faces, doodad snags).
  Corridor-complete + live-verified or it isn't a route.
- **The mesh has no concept of "road".** Corridors between two on-road
  points happily cut cross-country, up cliffs, and through lakes. Roads
  must be imposed by beats; the mesh only fills the gaps between them.
- **Mobs don't kill a moving bot; stops kill.** Every land death traces to
  a stop (collision snag, wall, embed) near spawns. Fix the stop, not the
  mob. Corollary: aggro radius here is 7–11 yd (mobs 47–53 vs a level-60
  seat), so lines threaded closer than that bleed hp even while moving.
- **Progress is not health.** See the observability section in README.md —
  a PASS with unplanned swims, clips, or 20% idle is a lucky failure.

## Technique: offline corridor probing (navmesh helper)

`monofuel-vanilla-wow/tmp/vmangos-navmesh-helper` answers route queries
against the vmangos mmaps in milliseconds — no game boot. One JSON request
on stdin, flat JSON response on stdout (`waypoints`,
`continuation_required`, `partial_path_end`, `max_segment_slope`,
`status/message`). See `tools/traverse_route_lint.py` for the request
shape and helpers. The idioms:

- **Continuation chains**: partial paths are normal — re-probe from
  `partial_path_end` until arrival (cap ~8 hops). The chained corridor is
  the closest thing to "what the client will try to walk".
- **Z-sweeps**: projection failures usually mean the recorded z is off the
  mesh surface — sweep source AND target z by ±30/60/90 before declaring
  no-corridor.
- **Ground-vs-water differential**: probe `include_flags=1` (ground only)
  vs `9` (ground+water). A leg complete only with water is a
  water-crossing land leg — the lake/waterfall class. This is how the lint
  catches them before a run does.
- **Slope literacy**: compute per-segment slope yourself, in travel order.
  Descending steep is walkable; ascending >~1.5 sustained is not. Slopes
  2.5+ are cliffs no matter what the mesh says. Short 2–6 yd ascending
  spikes are usually corridor corner-cuts at switchbacks — fix with a bend
  beat, not by trusting or banning the leg outright.

## Technique: spawn-field analysis (realm DB)

The world DB knows every spawn point. READ-ONLY queries
(`docker exec coworld-vmangos-coworld-game-1 mysql -umangos -pmangos`,
`creature JOIN creature_template`, map 1) drive three moves:

- **Density grids** (50–60 yd cells) to find camps and empty lanes — but
  beware: an empty lane is often empty because it's a cliff. Mesh-verify
  before believing any spawn-optimal line.
- **Exposure scoring**: min point-to-segment distance from every hostile
  spawn to each leg chord; count <15 yd approaches. Grid-search beat
  offsets to minimize them (see the campaign's dodge beats).
- **Friendly filter**: Grazle, Tenell Leafrunner, Taronn Redfeather,
  Nafien, Timbermaw Warder are quest NPCs, not threats.

A snapshot lives at `tools/data/spawns_kalimdor_40plus.tsv` (regeneration
documented in its README; never write to the realm DB).

## Technique: road detection from painted textures (`tools/road_mask.py`)

Roads in 1.12 are literally painted onto the terrain: each ADT tile's MTEX
chunk names its textures (`*road*` tilesets, plus a few named extras —
see below), and each MCNK sub-chunk's MCLY/MCAL layers say where each
texture is painted, at ~yard resolution. `road_mask.py` parses the ADTs
under `local_data/player/assets-flat/world/maps/<kalimdor|azeroth>/` into
`is_road(x,y)`, per-leg on-road fractions, and bbox dumps of
road-positive samples — the ground truth for placing beats on actual
roads and hairpins without anyone manually walking them. The coordinate
transform is calibrated against known road/non-road anchors (see its
tests). Use `dump` over a climb's bbox to extract a hairpin polyline;
use `leg` to score whether a beat chord stays on pavement. This exists
because a replay watch proved "the bot leaves the path" was the root
cause the mesh could never see.

The dump→eyeball workflow still works. There is also a productized path:
`tools/bake_road_waypoints.py` regenerates the checked-in artifacts
`tools/data/road_waypoints_{kalimdor,azeroth}.jsonl`. Two tiers:

- **baked** — regenerable centerlines from the current paint. Replaced
  wholesale on every bake.
- **hand** — curated stitches. The merge rule keeps every non-`baked`
  line **byte-identical** and in original relative order.

Curation rules (bridges have no paint; plaza blobs come back on re-bake;
never key other tooling on baked ids) live in `tools/data/README.md`.

Eastern Kingdoms: `--map azeroth`. `ROAD_TEXTURE_MARKERS` is the `*road*`
substring plus `elwynncobblestone` (Elwynn's paved textures do not
contain `road`), `duskwoodcobblestone` (same for Duskwood), and
`tanarisdirtfootprint` (Tanaris coverage is thin — sparse footprint
paint). `OVERLAY_ONLY_MARKERS` is `tanarisdirtfootprint`: it counts
as road only when painted as an overlay layer (alpha > 64), never as
a chunk's base layer. Thousand Needles is not a texture-marker zone
anymore — see the round-5 section below.

Bake always Zhang-Suen-thins the paint mask first, so a wide road still
yields a single centerline. Road cells whose MCLQ water depth exceeds
`--max-water-depth` (default 0.5 yd) are skipped, so painted lakebeds
like the Pool of Tears no longer bake. `--max-width` (default 28.0 yd;
`<=0` disables) drops whole components whose mean paint width (cell
area / total centerline arclength) exceeds the threshold — isolated
blobs die; a blob 8-connected to a real road survives. `--max-grade`
(default 0.55; `<=0` disables) skips lattice cells whose local terrain
grade (central difference over ±4 yd via `ground_z`) exceeds the
threshold — walkability guard, kills cliff-face paint.
`--min-component-length` (default 150.0 yd; `<=0` disables) drops
whole components whose total centerline arclength is under the
threshold — network-scale guard, kills isolated paint scraps.

## Technique: minimap routing when paint has no signature (round-5)

Texture markers cannot find the Thousand Needles floor road. Marker
history is three flips (do not add a fourth): `thousandneedlesdirt`
blobbed the canyon floor as a base and painted cliff faces as
overlay-only (median grade 1.02); `thousandneedlesrockhighlight02`
was added overlay-only as the supposed light-brown trail, then
removed — it paints mesa TOPS at alpha-255 overlay (overlay-only
semantics cannot save it; those flat tops pass `--max-grade`). Its
canyon-floor footprint was one ~180yd patch. The floor road has no
texture signature. Round-3's verification tested flatness when it
needed elevation and connectivity.

`MINIMAP_ROUTE_ZONES` in `bake_road_waypoints.py` is the replacement:
per zone, a STEP-aligned bbox, a `z_band` used only as a search
bound, hard walls at `max_water_depth` 0.5 and `max_grade_wall` 1.8
(mesa tops sit behind cliff-grade rings, so they are unreachable
from the floor), `slope_penalty` on grade above 0.5, and contrast
cost `max(0, c0 - (G - 64yd-block-median-G)) / k` with `c0=25`,
`k=22`. Deterministic Dijkstra (heap keyed `(cost, cell)`). Each
configured leg emits one decimated `"source": "baked"` segment; a
leg with no path aborts the bake (`minimap route FAILED`). Legs
carry optional round-6 fields: `z_corridor (lo, hi, penalty/yd)` —
an altitude prior (the 1kN road never leaves the canyon bottom;
floor legs pay +10/yd outside −120..−20, so rim detours lose) — and
`max_grade_wall` (only the basin→Tanaris ramp: 2.2 vs measured
pinch 1.78–1.79). The bake hard-fails if a corridor leg exceeds 5%
of its length outside corridor or an anchor snaps >20 yd. Shipped
legs: `feralas_junction` → `lift_lower` → `freewind_base` →
`canyon_se` → `basin_entry` → `racetrack_north` → `racetrack_mid` →
`racetrack_south` → `tanaris_road`: down the measured scarp cut,
across the Shimmering Flats past the racetrack, up the southwest
ramp to the painted Tanaris road — a nav-road line, not a paint
centerline. Routed legs are re-derived every bake; tune the zone
config, not the artifact. Meta records
`minimap_route_zones`. Kalimdor bake needs Pillow
(`nix-shell -p python3Packages.pillow`); Azeroth has no route
zones. `--no-minimap` skips the pass.

The sampler is `tools/minimap_mask.py`: `md5translate.trs` index,
world→pixel transform landmark-pinned at the Great Lift lower dock
(axes read transposed — do not "fix"), native 256px nearest/floor
pixel (no resampling), integer ITU-R 601 luma and RGB. Routing
uses the green channel.

Connectivity doctrine (`tools/tests/test_road_artifacts.py`, now
in `make test-traverse-checkpoint`): if the network is not
connected to the neighboring regions, it is not correct. One
artifact component must reach the Great Lift lower dock, the
Feralas junction, the racetrack (planar 150 yd — the salt crossing
may lawfully drift), and the painted Tanaris road — all in ONE
component, planar-gated AND `|dz|<=40`. The z-gate
exists because a mesa fake at z=86 sat 89 yd XY from the dock
(z=-43.857). Segments are located geometrically, never by baked
id. Barrens connectivity is via the lower dock; the lift itself
is a transport edge.

## Technique: trace-pinning (walked ground is evidence)

Any successful crossing — a human F9 recording (the water ribbon) or a
bot's own passing run (godview capture) — is a *client-verified walkable
line*. Resample it into beats (60–80 yd; keep tight zigzags — smoothing a
"struggle" into a chord re-enters the hazard the struggle avoided; a
sampling gap is permission to leave proven ground). Godview captures:
`~/.coworld/player/launcher_units/runtime/*/leagues/race/captures/godview_*.jsonl`.

## Technique: instrumented autopsies

Order of evidence for any failed run: scorecard WARNs → FLIGHT/EV lines in
`local_data/traverse-status/run.log` → godview hp/position timeline →
offline probes at the failure point. Classify against the failure classes
(collision trap / spawn step-on / water chord / cliff optimum / corridor
corner-cut) before writing any fix; every class has a documented remedy in
the beat-config comments and this file.

## Known client truths (fork-level, ledgered upstream)

- Collision is **nondeterministic run-to-run**: byte-identical routes have
  walked through a point one run and parked on it 150 sim-s the next.
  Route engineering can reduce exposure, never to zero.
- Teleporting a seat flush onto the ground embeds it in geometry — debug
  checkpoints sit ~1 yd above the mesh surface.
- The seat can glitch *through* terrain under sustained collision contact;
  falls are lifted by the server (non-fatal) but cost large time.
