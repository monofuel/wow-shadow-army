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
{"id": "v0001", "source": "minimap_ribbon", "network_role": "trunk", "confidence": 1.0, "pts": [[x, y, z], ...]}
{"id": "v0002", "source": "terrain_medial", "network_role": "trunk", "confidence": 0.55, "pts": [[x, y, z], ...]}
{"id": "v0003", "source": "visual_gap_bridge", "network_role": "great_lift_spur", "confidence": 0.0, "pts": [[x, y, z], ...]}
{"id": "h_something", "source": "hand", "note": "...", "pts": [[x, y, z], ...]}
```

`map_id` is kalimdor=1, azeroth=0. Floats are `round(v, 1)`. Baked ids
are assigned after a stable sort and **renumber every re-bake**.

### Regeneration

The generic ADT paint bake remains the first pass. The agent-owned
`road-ribbons` target then replaces Thousand Needles/Shimmering Flats with the
visual detector output:

```sh
python3 tools/bake_road_waypoints.py --map kalimdor --no-minimap
make road-ribbons
python3 tools/bake_road_waypoints.py --map azeroth
```

Defaults write `tools/data/road_waypoints_<map>.jsonl`. A second run of
the same command must leave `git diff --stat tools/data/` empty.
Current artifacts: kalimdor **176** segments, azeroth **236**.

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
- Meta also records `markers` (copy of `ROAD_TEXTURE_MARKERS`) and
  `overlay_only_markers` (copy of `OVERLAY_ONLY_MARKERS`).

Thousand Needles and the Shimmering Flats are composed by the Nim visual
ribbon detector (`src/tools/detect_road_ribbons.nim`) after the generic ADT
paint bake. It reads the full-resolution minimap atlas, discovers the three
terminals: the Feralas and Great Lift crossings from minimap evidence, plus a
broad Gadgetzan destination region localized from canonical in-game town-guard
spawns. It writes `minimap_ribbon`, `terrain_medial`, and separately labelled
`visual_gap_bridge` segments. It has no interior route anchors. The detector
requires a broad bilateral ribbon response across several widths, rejects
mesa-top and terrain-discontinuity strata, recognizes the darker track polarity
on pale salt, and follows maximum walkable-floor clearance where the painted
ribbon loses contrast. It extracts one Feralas-to-Gadgetzan trunk before
attaching the Great Lift as a short spur; it never computes a second route
across the canyon. Any unsupported run over 24 yards hard-fails the bake.
Diagnostics under `local_data/` show accepted evidence, the final red route,
and an evaluation-only blue-reference overlay when the detector test runs.

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
The floor road has no ADT layer signature; its visible minimap ribbon is the
authoritative signal.

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
- **Thousand Needles uses visual detection.** The Nim ribbon detector replaces
  every old zone segment; tune its generic visual/terrain gates, never add
  interior route points. Hand lines remain unrelated legacy data.
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
