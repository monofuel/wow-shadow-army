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
(`VANILLA_WOW_ADT_DIR` or the default flat dump):

```sh
python3 tools/bake_road_waypoints.py --map kalimdor
python3 tools/bake_road_waypoints.py --map azeroth
```

Defaults write `tools/data/road_waypoints_<map>.jsonl`. A second run of
the same command must leave `git diff --stat tools/data/` empty.

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
- Meta also records `markers`, a copy of `ROAD_TEXTURE_MARKERS`.

`ROAD_TEXTURE_MARKERS` (substring match, lowercased): `road`,
`elwynncobblestone`, `duskwoodcobblestone`, `tanarisdirtfootprint`.
`thousandneedlesdirt` was tried and dropped — the whole canyon floor is
that dirt, so the zone baked into one solid blob. A unit test pins the
marker off.

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
- **Thousand Needles has no baked roads.** `thousandneedlesdirt` stays
  off by decision (canyon-floor blob). Hand lines are the path there.
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
