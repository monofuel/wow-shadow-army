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
contain `road`), `duskwoodcobblestone` (same for Duskwood),
`tanarisdirtfootprint` (Tanaris coverage is thin — sparse footprint
paint), and `thousandneedlesrockhighlight02`. The last two are
overlay-only (`OVERLAY_ONLY_MARKERS`): they count as road only when
painted as an overlay layer (alpha > 64), never as a chunk's base
layer. `thousandneedlesdirt` was tried twice and removed: as a base
marker it blobbed the canyon floor; as overlay-only it painted cliff
faces. The actual light-brown Thousand Needles road paint is
`thousandneedlesrockhighlight02` — identified by correlating minimap
BLP luminance with ADT paint signatures, a trick worth repeating on
new zones. Overlay-only because mesa tops carry it as a base layer;
dual-use on mesa rims is killed by the grade gate.

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
