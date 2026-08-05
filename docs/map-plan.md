# World map browser + waypoint tool — plan

Status: **phase 3d zone view in** — World → continent → zone 2D → bird's-eye
3D terrain (`map_browser_3d` / fork `runMapViewer`). Goal: hierarchical
vanilla world-map art, full zone reveal, 3D bird's-eye, then waypoints.

Terms: `docs/terms.md`. Client imports come from **the fork**
(`../coworld-vanilla-wow-fork`, on `main`) — this tool builds on client
work. Read-only stock upstream is `../coworld-vanilla-wow`.

## Checklist

Track progress here. Use `nix develop` (or `nix develop --command …`) for
every compile/run step.

### Preconditions

- [x] Plan written (`docs/map-plan.md`)
- [x] `nim.cfg` path to `../coworld-vanilla-wow-fork`
- [x] Fork and stock upstream checkouts on `main` (no `shadow-army-fixes`)
- [x] Confirm world-map assets resolve (prepared BLPs under
      `coworld-vanilla-wow/player/assets/interface/worldmap/world`; override
      via `MAP_BROWSER_WORLD_MAP_DIR`)
- [x] `nix develop` shell works on this machine (`nim --version`)

### Phase 0 — spike (first real `src/` tree)

- [x] Create `src/` and `src/tools/`
- [x] Scaffold `src/tools/map_browser.nim` + `src/map_browser/assets.nim`
- [x] Import from the fork under `nix develop` (`environment/client/localpaths`)
- [x] Open a window and draw the **world** mosaic (World 1–12 tiles)
- [x] Exit: compiles and shows art (`make map-browser` / `make map-browser-once`)

### Phase 1 — surfaces

- [x] World → continent drill (click / ProcessMapClick path)
- [x] Continent → zone drill (ZMP masks + WorldMapArea surfaces)
- [x] Zoom-out back to continent / world (Esc / right-click / Backspace)
- [x] Exit: discrete drill works end-to-end (`make map-browser-once` samples)

### Phase 2 — full overlays (no fog)

- [x] Zone surfaces: base fog art + **all** WorldMapOverlay pieces (no
      explored-bit gate). Zone base BLPs alone are the “hidden” maps.
- [x] Continent surfaces: 1.12 DBC has **0** overlays on Kalimdor/Azeroth
      rows (areaMapId 13/14) — continent detail is zone overlays, not
      continent-level. Base continent mosaic is what stock shows unexplored.
- [ ] Optional: paint zone overlays onto the continent view by projecting
      each zone’s revealed art into continent UVs (not stock, authoring only)
- [x] Exit for zone drill: zone map shows full labels/terrain (Teldrassil/
      Durotar verified with overlayCount=11)

### Phase 3 — 3D bird's-eye zone view

- [x] Zone drill from continent opens 3D terrain over zone bounds
- [x] Overhead scaled from WorldMapArea span (bird's-eye)
- [x] Free camera: WASD / mouse / scroll (stock map viewer)
- [x] Esc/Q closes 3D and returns to 2D; Enter/Space/3 re-opens from zone 2D
- [x] Entry: `src/tools/map_browser_3d.nim` + `src/map_browser/view3d.nim`
- [ ] Optional: in-process 3D (no child process) for smoother window flow

### Phase 4 — waypoints

- [ ] Click → world coords (`worldMapSurfaceLocation`)
- [ ] Draw points / polyline (`projectWorldMapPoint`)
- [ ] Select / delete waypoint
- [ ] Exit: placement feels correct on a known zone (e.g. Durotar)

### Phase 5 — I/O

- [ ] JSON schema for a route (`map_id`, `x`, `y`, optional `z`)
- [ ] Save / load file (CLI path or `local_data/waypoints/`)
- [ ] Round-trip test (no network, no sleeps)
- [ ] Exit: reload restores the same route

### Phase 6 — polish (optional)

- [x] Breadcrumbs + thin hover outline
- [ ] Pan within 2D surface
- [ ] Continuous zoom / LOD only if discrete drill is not enough
- [x] Makefile: `map-browser`, `map-browser-once`, `map-browser-3d`

### Hard rules (do not skip)

- [ ] No Python for this tool
- [ ] No GM/SOAP tele for map preview
- [ ] Do not commit into stock `../coworld-vanilla-wow`
- [ ] Client fixes only on the fork if needed; monofuel decides upstream reports
- [ ] Do not write engineering notes into `kb/`
- [ ] `make test` stays green when code lands

## Repo layout note — first real Nim tools under `src/`

Today this repo’s Nim surface is mostly ops/host code under `tools/`
(`army_host.nim`, System, fair-play audit). The map browser is the first
**product Nim tool** meant to live under a proper source tree:

```text
src/                        # exists — first product Nim tools live here
  tools/
    map_browser.nim         # entrypoint (phase 0+)
  map_browser/              # library modules for the tool
    assets.nim              # tile resolve + mosaic compose
    surface.nim             # phase 1: World/continent/zone selection
    projection.nim          # later
    waypoints.nim           # later
    draw.nim                # later
```

- Prefer `src/tools/<name>.nim` for new headed/CLI tools of this kind.
- Leave existing `tools/` host/ops scripts where they are unless we later
  decide to migrate them (out of scope for this plan).
- `nim.cfg` has `--path:"src"`; Makefile: `make map-browser` and
  `make map-browser-once` (both via `nix develop`).

## Build environment — always `nix develop`

Hermetic shell is the flake at repo root (`flake.nix`). It supplies `nim`,
`pkg-config`, OpenSSL/X11/GL runtime libs (windy/silky-class stack), and the
usual ops packages.

**All compile and run of this tool go through the flake shell.** Do not
hand-roll host OpenSSL/lib paths.

```sh
# interactive
nix develop

# one-shot (agents / Makefile)
nix develop --command nim check src/tools/map_browser.nim
nix develop --command nim r src/tools/map_browser.nim
```

Pattern already used elsewhere: `nix develop --command …` so agents and
systemd do not invent library paths (see flake description and
`docs/play-classic.md`). Future Makefile target should wrap the same way,
e.g. `make map-browser` → `nix develop --command nim r src/tools/map_browser.nim`.

## Product goal

Offline/headed **map browser + waypoint authoring**:

1. Fully zoomed out → full vanilla **world** map art.
2. Zoom / drill in → **continent** map with **all zone overlays fully
   visible** (not fog-of-war / exploration-gated).
3. Zoom / drill farther → **zone** map surface.
4. Click to place / edit / delete waypoints; save and load a simple JSON
   route file.

Not bot policy, not the advisor, not a dashboard tutorial, not live GM
teleport.

## Upstream already has the map stack

Do **not** reimplement WorldMapFrame parity from scratch. The nim client
already models stock 1.12 behavior. Primary sources under
`../coworld-vanilla-wow`:

| Concern | Module(s) |
|---|---|
| Surfaces, overlays, projection | `environment/client/world_maps.nim` |
| DBC geometry, explored bits, click | `environment/client/world_catalogs/world_map.nim` |
| Draw path, overlays, frame layout | `environment/client/ui/world_map_frame.nim` |
| 12-tile BLP mosaic → 1002×668 | `environment/client/ui/wow_atlas_assets.nim` (`composeWorldMapSurface`) |
| Asset roots / env | `environment/client/localpaths.nim` (`VANILLA_WOW_CLIENT_DATA_DIR`, …) |
| Selection API | `client_state/world.nim` (`setWorldMapZoom*`, `processWorldMapClick`, world level) |

### Zoom levels ↔ stock WorldMapFrame

| UX level | Stock surface | Art path pattern |
|---|---|---|
| Fully out | world level (`SetMapZoom(0)`) | `Interface\WorldMap\World\World{1..12}.blp` |
| Mid | continent (`Azeroth` / `Kalimdor`) | `Interface\WorldMap\<Continent>\…` + `WorldMapOverlay` tiles |
| Far | zone (`Durotar`, …) | `Interface\WorldMap\<Zone>\<Zone>{1..12}.blp` |

Detail size is stock **1002×668** (`WorldMapDetailWidth` /
`WorldMapDetailHeight`). Assets on high-steel already appear under
upstream’s browser extract, e.g.:

`../coworld-vanilla-wow/local_data/player/browser-assets/delta/interface/worldmap/`

…and/or via client `Data/*.MPQ` when `VANILLA_WOW_CLIENT_DATA_DIR` points at
classic data (`wow-classic-data` / Coworld-WoW-Classic).

### Fog of war vs “fully visible”

Continent detail fills in through `WorldMapOverlay.dbc` rows, gated by
`PLAYER_EXPLORED_ZONES` bits (`worldMapOverlaysFor*`). For this tool we
want **every overlay for the surface**, not exploration-gated art.

Implementation: tool-local list/filter that skips explored checks (or
all-bits-set mask). Do **not** change stock client explored behavior
upstream; this is authoring-tool policy only.

### World ↔ map math (waypoint clicks)

- Place: UV on surface → world via `worldMapSurfaceLocation`.
- Draw: world → UV via `projectWorldMapPoint` / player-map position helpers.
- Drill: `processMapClick` / `setWorldMapZoom` / `setWorldMapToWorldLevel`.

Waypoint schema (draft): `{ map_id, x, y, z? }` points in a named route
file. Persist under something gitignored like `local_data/waypoints/` (or
an explicit CLI path). **Not** `kb/` until a planner exists to read bot
memory.

## What not to build on

| Surface | Why not |
|---|---|
| `viewers/map_viewer` / `runMapViewer` | 3D terrain viewer, wrong product |
| `world_editor` creature waypoints | Patrol / live GM edit path |
| Dashboard map widgets | Wrong surface; dashboard is buttons/metrics |
| GM/SOAP tele for “preview” | Forbidden unless monofuel explicitly orders tele |

## Architecture (proposed)

Thin tool that **imports** client map/catalog/UI helpers from the fork;
does not vendor client source and does not embed a full play session.

```text
src/tools/map_browser.nim
  → src/map_browser/*
  → import fork modules (path via nim.cfg → ../coworld-vanilla-wow-fork)
  → silky (or existing client window stack) for the GUI
```

**Import reality:** the coworld client is a monorepo of modules, not a tidy
`import wow` package. Expect a phase-0 spike to prove which path set
compiles from this repo under `nix develop`. Prefer the smallest import
set (catalog + texture compose + projection); fall back to more of the
WorldMapFrame draw path only if mosaic loading is painful.

**Coupling isolation:** one config module for asset env vars and fork root —
not scattered string paths.

**Checkout:** import from `../coworld-vanilla-wow-fork` on `main`. Stock
`../coworld-vanilla-wow` stays read-only. Do not commit into either from
this tool’s workflow except deliberate fork client work monofuel owns.

### Suggested modules

| Module | Role |
|---|---|
| `assets.nim` | Resolve data roots; load/composemaps via client helpers |
| `surface.nim` | World / continent / zone selection; full overlay list |
| `projection.nim` | Thin wrappers over world ↔ UV |
| `waypoints.nim` | Edit model + JSON load/save |
| `draw.nim` | Blit surface, overlays, waypoint UI |

## Phased delivery

| Phase | Outcome | Exit check |
|---|---|---|
| **0. Spike** | Create `src/`; open a window; draw **world** mosaic from a known asset root under `nix develop` | Compiles and shows art |
| **1. Surfaces** | World → continent → zone drill; zoom-out back up | Click drill works |
| **2. Full overlays** | Continent fully painted (no fog) | Overlays match full zone fill |
| **3. Waypoints** | Click place, select, delete, polyline | UV↔world feels right |
| **4. I/O** | JSON save/load; stable schema | Round-trip file |
| **5. Polish** | Labels, hover names, pan; optional continuous zoom/LOD | Nice-to-have only |

Default zoom model for MVP: **stock discrete drill** (cheap, matches
client). Continuous scroll + LOD crossfade is phase 5 if discrete feels
wrong for authoring.

## Tests and Makefile (when coding starts)

- Unit: projection math + waypoint JSON only — no network, no sleeps
  (repo testing doctrine).
- `make test` stays green; add a focused target if needed for map modules.
- Document one Makefile entry for the tool that always uses
  `nix develop --command …`.

## Hard rules (carry from AGENTS.md)

- No Python for this tool.
- Upstream read-only; client fixes go on the fork only if we discover a
  real client bug (document + monofuel decides).
- No tele / GM position writes for map preview.
- Agents own ops commands; human surface remains play clients.
- Docs for engineers stay in `docs/`; do not refill `kb/` with this plan.

## Open decisions (record when chosen)

1. **Zoom model for v1:** discrete drill (default) vs continuous LOD.
2. **Waypoint consumers:** human-only authoring vs later feed into Lua /
   army host (affects schema stability).
3. **Import depth:** thin catalog+textures vs hitch WorldMapFrame draw
   more heavily (phase 0 decides).

## Related docs

- `docs/terms.md` — vocabulary
- `docs/interfaces.md` — boundaries (nim client vs vanilla client)
- `docs/nim-client.md` — how we compose against the pinned client
- `docs/navmesh.md` — separate; navmesh is not the painted WorldMap
- Upstream: `environment/client/world_maps.nim`, `ui/world_map_frame.nim`
  (read-only checkout)
