# map-browser

Standalone bird's-eye 3D viewer of a whole continent. Terrain is a low-res
WDL heightmesh read from the classic client MPQs; waypoint graph, taxi
network, and traverse-run trails are overlaid for nav-data debugging.

**Not** the fork's `runMapViewer` render-test shell. This tool has its own
OpenGL + windy window (`src/map_browser/gl_view.nim`,
`src/tools/map_browser.nim`). Fork imports are **data-only**:

- `environment/client/formats/*` (WDL / MPQ)
- `environment/client/world_catalogs/*` (DBC taxi)
- `bots/real_playerbot/policy/world_catalog` (city routes, lifts, spells)

## Make targets

| Target | What it does |
|---|---|
| `make map-browser` | Interactive GL window |
| `make map-browser-once` | Headless smoke (`MAP_BROWSER_ONCE=1`): catalog + waypoint graph + Kalimdor WDL mesh asserts; no window |
| `make map-browser-probe` | Autopilot window: N seconds, screenshot + stats JSON, exit nonzero if mesh/overlays never ready |

## Env vars

| Var | Role |
|---|---|
| `VANILLA_WOW_CLIENT_DATA_DIR` | Classic client root or its `Data/` dir (MPQs). Makefile defaults to `../wow-classic-data/.../client`, else upstream bundle client. |
| `VANILLA_WOW_EXTRACTED_DATA_DIR` | Extracted data; DBC catalog loaded from `<dir>/dbc`. Makefile defaults to upstream `local_data/vmangos-5875-data`. |
| `MAP_BROWSER_ONCE=1` | Headless smoke path (see above). |
| `MAP_BROWSER_STATS=path.json` | Rewrite stats every ~2s and on exit (fps, frame p50/p95, camera, tile/vertex counts, overlay counts). |
| `MAP_BROWSER_AUTO="seconds=N,screenshot=path.png"` | Autopilot; default probe uses `seconds=8` and `local_data/map_browser_probe.png`. |

## Controls

From `gl_view.nim` / `map_browser.nim` (defaults: waypoints on, taxi on, xray on):

| Input | Action |
|---|---|
| `1` | Toggle waypoint graph (city routes) |
| `2` | Toggle taxi flight network |
| `L` | Toggle traverse-runs panel (click a row to load/plot) |
| `X` | Toggle xray (overlays ignore depth) |
| `WASD` | Pan target (speed scales with camera height) |
| LMB drag | Pan target |
| RMB drag | Orbit yaw / pitch |
| Wheel | Zoom (cursor-anchored on the target plane) |
| `Tab` | Switch continent mesh (Kalimdor ↔ Eastern Kingdoms / Azeroth) |
| `Home` | Reset camera to frame the whole active continent |

Header line mirrors the same hints (ASCII `|` separators).

## Data sources

| Data | Where |
|---|---|
| WDL heightmesh | Client MPQs via fork resolver: logical path `World\Maps\<Azeroth\|Kalimdor>\<name>.wdl` under `VANILLA_WOW_CLIENT_DATA_DIR` (or default client Data/). Outer grid 17×17 heights per present tile; cell step ≈ `GridSize/16` ≈ **33.3 yd**. |
| DBC world catalog | `VANILLA_WOW_EXTRACTED_DATA_DIR/dbc` (taxi paths/nodes); falls back to `loadDefaultWorldCatalog()` if missing. |
| Waypoint graph | Fork `real_playerbot` world catalog routes. Edges are **reconstructed** by probing `worldRoutePath` for adjacent pairs (a direct edge is a 2-node path) — not read from a public edge list. Lift / teleport kinds from `greatLift` / `travelSpellId`. |
| Taxi polylines | Catalog `taxiPaths` / `taxiPathNodes`, decimated (every 4th node, ends kept). |
| Traverse runs | Godview JSONL at `~/.coworld/player/launcher_units/runtime/*/leagues/traverse/captures/godview_*.jsonl` (2 Hz captures; parse on a background thread; decimated ≤2000 points). |
| Beats / checkpoints | Repo `lua/config/traverse_beats.json` and `tools/traverse_checkpoints.json` (loaded when the runs panel opens). |

Supported continent map ids: `0` Azeroth, `1` Kalimdor. Startup loads Kalimdor.

See [../navigation.md](../navigation.md) for every navigation data system
(ours vs upstream) and which ones this viewer draws.

## Known limits

- WDL is coarse (~33 yd cells) — fine for whole-continent nav debug, not close-up terrain.
- No textures: elevation + slope shading only (vertex colors).
- No doodads / objects by design.
- Continents are separate meshes; no ocean pan between them — `Tab` switches.
- Waypoint edges are reconstructed by `worldRoutePath` probing, not exported from the fork.
- Run list is load/plot only — no timeline scrubbing.

## Follow-ups

- [ ] Minimap BLP texture drape (fork `minimaps.nim` has md5translate parsing)
- [ ] vmangos `.map` higher-res heights
- [ ] Click-to-inspect node
- [ ] Run playback scrubbing

## Gotchas for hackers

- Silky UI must run with `GL_DEPTH_TEST` disabled — all silky quads share depth 0; with depth on, the first quad wins and overlapping UI is discarded (see comment in `src/tools/map_browser.nim` before `sk.beginUI`).
- Silky atlas is ASCII-only — use `|` in header/panel strings, not `·` or other unicode.

## Layout

```
src/tools/map_browser.nim     # entry: once / window / silky header + runs panel
src/map_browser/wdl_terrain.nim
src/map_browser/gl_view.nim
src/map_browser/overlay_gl.nim
src/map_browser/waypoints.nim
src/map_browser/runs.nim
src/map_browser/debug.nim      # MAP_BROWSER_STATS / AUTO
```
