# Navigation data systems

Every waypoint / coordinate system in play across this repo and the forks,
who owns each one, and which ones the map-browser actually draws. All of
them share VMaNGOS world coordinates (`mapId` 0 = Azeroth / Eastern
Kingdoms, 1 = Kalimdor; +X north, +Y west), so any of them *can* overlay on
the same map — the differences are ownership and purpose, not geometry.

## The systems

| # | System | Ours / upstream | Lives at | Purpose | On map-browser? |
|---|--------|-----------------|----------|---------|-----------------|
| 1 | City-route graph | **Upstream** | `coworld-vanilla-wow/bots/real_playerbot/policy/world_catalog.nim` | real_playerbot city-to-city travel (walk / Great Lift / teleport) | **Yes** — gold/purple/blue edges + nodes, green activity rings (keys `1`) |
| 2 | DBC taxi network | Game data | DBC via world catalog (`VANILLA_WOW_EXTRACTED_DATA_DIR/dbc`) | Flight-master paths | **Yes** — cyan polylines (key `2`) |
| 3 | Traverse beats | **Ours** | `lua/config/traverse{,_land,_coast,_connector_wet,_connector_land,_finale,_finale_interior}_beats.json` (7 files; JSON is source of record, `.lua` mirrors regenerated) | The actual Petrel route: dense ribbons, many trace-pinned from monofuel's manual F9 recordings | **Partial** — only `traverse_beats.json` (+ checkpoints), and only after the runs panel (`L`) first opens |
| 4 | Traverse checkpoints | **Ours** | `tools/traverse_checkpoints.json` | Run scoring / progress gates | Same partial path as beats |
| 5 | Godview run trails | **Ours** (captured) | `~/.coworld/player/launcher_units/runtime/*/leagues/traverse/captures/godview_*.jsonl` | What a bot actually walked (2 Hz) | **Yes** — per-run, click rows in the `L` panel |
| 6 | Navmesh corridors | Generated | Not stored — fork navigate intents live, or offline via `monofuel-vanilla-wow/tmp/vmangos-navmesh-helper` (mmaps) | Fills the gaps *between* beats | **No** |
| 7 | Road mask | **Ours** | `tools/road_mask.py` + `tools/bake_road_waypoints.py` + `tools/data/road_waypoints_<map>.jsonl` | `is_road(x,y)` from painted ADT textures (MTEX/MCLY/MCAL) — ground truth for placing beats on pavement | **Yes** — red lines + dots, key `3` (both continents) |
| 8 | Server terrain truth | vmangos extract | `coworld-vanilla-wow/local_data/vmangos-5875-data/{maps,mmaps,vmaps}` | What the server/mesh believes | **No** (viewer terrain is client WDL instead) |

The viewer's terrain itself is the client **WDL** heightmesh (see
[tools/map-browser.md](tools/map-browser.md)) — a display backdrop, not a
navigation source.

## How they relate

- **The gold overlay is not traverse.** System 1 is upstream's city-travel
  graph; Petrel never touches it. It looks authoritative on the map but is
  irrelevant to traverse debugging. Its edges are also *reconstructed* (the
  fork keeps them private; `src/map_browser/waypoints.nim` probes
  `worldRoutePath` for adjacent pairs), so treat the drawn edges as a good
  guess, not fork truth.
- **Traverse = beats + mesh + doctrine.** The 7 beat files impose the route
  (roads, hairpins, water ribbons); navmesh corridors fill between beats;
  `docs/traverse/route-engineering.md` holds the doctrine ("the navmesh
  lies about walls", "the mesh has no concept of road", trace-pinning).
- **Roads are paint, not data.** 1.12 has no road records; `road_mask.py`
  recovers them from texture alpha layers. Its coordinate transform is
  calibrated — do not re-derive it.
- **Roads are now also a persisted artifact.** Baked centerlines in
  `tools/data/road_waypoints_<map>.jsonl`, hand-curated over time
  (bridges have no paint; see `tools/data/README.md`).
- **Trails are evidence.** Godview captures are client-verified walkable
  lines; beats get resampled *from* them (`tools/resample_human_ribbon.py`,
  `tools/resample_trace_beats.py`).

## Map-browser gaps (what should be added)

For traverse/waypoint debugging the viewer currently emphasizes the wrong
system (1) and hides most of the right one (3). Candidates, in usefulness
order:

- [ ] Draw **all seven** beat configs as a first-class always-available
  layer (distinct color per file, beat radius rings), not gated behind the
  runs panel.
- [ ] Checkpoints as their own toggle, independent of the runs panel.
- [x] Road-mask layer (raster or sampled dots from `road_mask.py dump`)
  under the beat ribbons — makes "beat off pavement" visible at a glance.
  (shipped as the checked-in road-waypoints artifact, key 3)
- [ ] Navmesh corridor preview: click two points → chained
  navmesh-helper corridor drawn (the offline probing loop from
  route-engineering, on the map).
- [ ] A legend keyed by system number so the overlay colors stop needing
  tribal knowledge.

## Related docs

- [tools/map-browser.md](tools/map-browser.md) — the viewer itself
- [traverse/README.md](traverse/README.md) — Petrel doctrine + status
- [traverse/route-engineering.md](traverse/route-engineering.md) — beat
  placement techniques (corridor probing, spawn fields, road mask,
  trace-pinning, autopsies)
- [wow/world-and-travel.md](wow/world-and-travel.md) — travel lore
  (flight points, roads-as-safety)
