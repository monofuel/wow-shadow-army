# tools/data

## `spawns_kalimdor_40plus.tsv`

Kalimdor (map 1) creature spawn snapshot for offline route lint
(`tools/traverse_route_lint.py`). Columns (tab-separated, no header):

```
x  y  z  level_min  level_max  name
```

### Regeneration (read-only)

Against a running local realm (`make start-server`). **Never write** to the
game DB — SELECT only:

```sh
docker exec coworld-vmangos-coworld-game-1 mysql -umangos -pmangos \
  -N -B mangos -e "
SELECT c.position_x, c.position_y, c.position_z,
       ct.minlevel, ct.maxlevel, ct.name
FROM creature c
JOIN creature_template ct ON ct.entry = c.id
WHERE c.map = 1 AND ct.minlevel >= 40
ORDER BY ct.minlevel, ct.name;
" > tools/data/spawns_kalimdor_40plus.tsv
```

Container name may vary; use `docker ps` if the compose project prefix
differs. Re-export when creature tables change.

## `road_waypoints_<map>.jsonl`

Baked painted-road centerlines (plus optional hand stitches) for a
continent. Line 1 is a meta object (no timestamp — re-bakes are
byte-deterministic). Remaining lines are segments:

```
{"id": "b0001", "source": "baked", "pts": [[x, y, z], ...]}
{"id": "h_something", "source": "hand", "note": "...", "pts": [[x, y, z], ...]}
```

`map_id` is kalimdor=1, azeroth=0. Floats are `round(v, 1)`. Baked ids
are assigned after a stable sort and **renumber every re-bake**.

### Regeneration

From the repo root, with Kalimdor / Azeroth ADTs available
(`VANILLA_WOW_ADT_DIR` or the default flat dump). Kalimdor's bake
runs the Thousand Needles minimap-route pass and needs Pillow;
Azeroth has no `MINIMAP_ROUTE_ZONES` entry and does not:

```sh
nix-shell -p python3Packages.pillow --run \
  'python3 tools/bake_road_waypoints.py --map kalimdor'
python3 tools/bake_road_waypoints.py --map azeroth
```

`--no-minimap` skips the route pass (Kalimdor then needs no Pillow).
Defaults write `tools/data/road_waypoints_<map>.jsonl`. A second run of
the same command must leave `git diff --stat tools/data/` empty.
Current artifacts: kalimdor **179** segments, azeroth **236**.

Bake knobs (see `tools/bake_road_waypoints.py`):

- **Zhang-Suen thinning** (`thin_cells`) always runs before centerline
  extraction — one skeleton regardless of paint width. Not a flag.
- `--min-length` (default `30.0`; `<=0` disables) drops segments whose
  **pre-decimation** planar arclength is below the threshold. Meta
  field: `min_length_yd`. Measuring after decimation would couple
  survival to `--decimate`.
- `--max-water-depth` (default `0.5`; `<=0` disables) skips road cells
  whose MCLQ water depth exceeds the threshold. Meta field:
  `max_water_depth`. Sample stats include `water_skipped`. Roads that
  cross `>0.5` yd of water therefore split at the banks — hand-stitch
  those gaps the same way as bridges.
- `--max-width` (default `28.0`; `<=0` disables) drops whole components
  whose mean paint width (cell area / total centerline arclength)
  exceeds the threshold. Meta field: `max_width_yd`. Bake stats include
  `dropped_wide`. Isolated wide blobs die; a blob 8-connected to a real
  road dilutes into the network mean and survives.
- `--max-grade` (default `0.55`; `<=0` disables) skips lattice cells
  whose local terrain grade (central difference over ±4 yd via
  `ground_z`) exceeds the threshold. Meta field: `max_grade`. Sample
  stats include `grade_skipped`. Walkability guard — kills cliff-face
  paint.
- `--min-component-length` (default `150.0`; `<=0` disables) drops
  whole components whose total centerline arclength is under the
  threshold. Meta field: `min_component_length_yd`. Bake stats include
  `dropped_short`. Network-scale guard — isolated paint scraps die.
- Meta also records `markers` (copy of `ROAD_TEXTURE_MARKERS`),
  `overlay_only_markers` (copy of `OVERLAY_ONLY_MARKERS`), and
  `minimap_route_zones` (copy of the zones actually run; empty under
  `--no-minimap`).
- `--no-minimap` skips `MINIMAP_ROUTE_ZONES`. Without it, a Kalimdor
  bake with no Pillow exits 2 (`nix-shell -p python3Packages.pillow`).

`MINIMAP_ROUTE_ZONES` (Kalimdor only today: zone `thousand_needles`)
is a per-zone dict, not a CLI flag. Fields:

- `bbox` — world box, **STEP-aligned** (lattice keys are global
  integer indices).
- `z_band` — search bound only; cells outside are dropped, not costed.
- `max_grade_wall` (1.8) — hard skip. Mesa tops sit behind cliff-grade
  rings, so they are unreachable from the floor.
- `slope_penalty` (2.0) — extra cost on grade above 0.5:
  `penalty * (grade - 0.5)`.
- `contrast_c0` (25) / `contrast_k` (22) / `block_yd` (64) — contrast
  term is `max(0, c0 - (G - 64yd-block-median-G)) / k`. `G` is the
  minimap green channel.
- `max_water_depth` (0.5) — hard skip, same meaning as the paint gate.
- `legs` — `[name_a, (x, y), name_b, (x, y), options?]`. Each leg
  emits one decimated `"source": "baked"` segment. No path (or a
  1-point decimation) aborts with `minimap route FAILED`. Per-leg
  options (round-6):
  - `z_corridor: (lo, hi, penalty_per_yd)` — cost penalty (not a
    wall) added while the cell's z is outside `[lo, hi]`. Floor legs
    use `(-120, -20, 10.0)`: the Thousand Needles road never leaves
    the canyon bottom, and +10/yd makes any rim detour unaffordable.
  - `max_grade_wall` — per-leg override of the zone wall. Only the
    basin→Tanaris ramp uses it (2.2; the measured ramp pinch is
    1.78–1.79, right at the 1.8 zone wall). Cells between the zone
    wall and a leg override never feed the block-median contrast
    baseline, so one leg's wall cannot drift another leg's path.
  - The bake hard-fails if a corridor leg spends >5% of its length
    outside its corridor (per-leg stderr shows `pct_outside` and the
    max contiguous run) or if any anchor snaps >20 yd — the two
    failure modes that shipped round-5's rim-walking leg.

Dijkstra is deterministic: heap keyed `(cost, cell)`. Shipped legs:
`feralas_junction` → `lift_lower` → `freewind_base` → `canyon_se` →
`basin_entry` → `racetrack_north` → `racetrack_mid` →
`racetrack_south` → `tanaris_road`. The chain descends the measured
low-grade scarp cut into the Shimmering Flats basin, crosses the
salt past the racetrack (three waypoints keep the line off the drag
strip), and climbs the southwest ramp to the painted Tanaris road.

`ROAD_TEXTURE_MARKERS` (substring match, lowercased): `road`,
`elwynncobblestone`, `duskwoodcobblestone`, `tanarisdirtfootprint`.
`OVERLAY_ONLY_MARKERS` is `tanarisdirtfootprint`: it counts as road
only when painted as an overlay layer (alpha > 64), never as a
chunk's base layer. Thousand Needles marker history — three flips,
do not add a fourth: (1) `thousandneedlesdirt` tried and removed —
base blobbed the whole canyon floor; overlay-only painted cliff
faces (median grade 1.02). (2) `thousandneedlesrockhighlight02`
added as overlay-only; looked like the light-brown trail. (3) hl02
removed (round-3's mistake): it paints mesa TOPS at alpha-255
overlay (overlay-only semantics cannot save it; flat tops pass
`--max-grade`) and its canyon-floor footprint is one ~180yd patch.
The floor road has no texture signature; 1kN roads come from the
minimap routing pass.

Dev subset (does not replace the checked-in artifact):

```sh
python3 tools/bake_road_waypoints.py --map kalimdor \
  --bbox 900 -2600 1400 -2000 --out /tmp/road_bake_subset.jsonl
```

### Merge rule

The baker reads the existing file (if any) as raw lines. Every line whose
parsed object has `"source"` other than `"baked"` is kept **byte-identical**
and in its original relative order (hand-curated stitches). The old meta
line and every `"source": "baked"` line are dropped and replaced. Write
order: new meta, preserved hand lines, fresh baked lines. The file ends
with a newline.

### Curation

- **Bridges have no paint.** Add a `"source": "hand"` line whose `pts`
  stitch the two road ends across the gap.
- **Water crossings split at the banks.** Paint under `>0.5` yd of MCLQ
  water is skipped, so a road that fords a river or lake becomes two
  baked ends. Stitch with a `"source": "hand"` line (same as bridges).
- **Tanaris paint is thin.** The extra marker is `tanarisdirtfootprint`
  (a footprint tileset, not a `*road*` tileset); coverage is sparse.
  Overlay-only.
- **Thousand Needles floor is routed, not painted.** `MINIMAP_ROUTE_ZONES`
  legs are re-derived every bake as `"source": "baked"` segments.
  Tune the zone config, do not hand-edit those lines — the next bake
  replaces them. Hand lines still survive **byte-identical**.
- **Isolated scraps under 150 yd never bake.** `--min-component-length`
  drops whole components below that arclength. Roads matter as a
  network — add a `"source": "hand"` line for anything genuinely
  needed.
- **Isolated wide blobs are auto-dropped** by `--max-width`. A blob
  fused (8-connected) to a real road dilutes into the network mean and
  survives — trim those by hand.
- **Town plazas blob.** Deleting or trimming a baked line only lasts
  until the next re-bake — the paint is still there, so the baker
  regenerates it. A trimmed replacement you want to keep must be a
  `"source": "hand"` line, but note the re-bake will ALSO re-emit the
  original blob alongside it; there is no exclusion mechanism yet. In
  practice: re-bake rarely, curate after.
- **Never key other tooling on baked ids** (`b0001`, …). They are
  reassigned every bake after sort.
- **Junctions** produce slightly overlapping segments. That is expected
  and fine for visualization.
