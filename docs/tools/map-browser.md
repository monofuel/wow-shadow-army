# map-browser

- `make map-browser` — the interactive viewer
- `make map-browser-once` — headless smoke (no window; catalog + mosaic + graph asserts)
- `make map-browser-debug` — viewer with per-second `[mb-debug]` lines + stats JSON
- `make map-browser-probe` — autopilot: drill a zone, stream, screenshot + stats, exit nonzero on failure

## notes

- do not modify coworld-vanilla-wow (used for server stuff) or coworld-vanilla-wow-fork (used for client stuff)
- we can import them and use functions but do not modify them, there's no reason to be making upstream changes for our map browser.
- the map browser is a local tool for us.

- the upstream nim client now has built-in navigational features. we rely on those in the map viewer: the streamed nav debug layer (`N`), the world_catalog city route graph (`1`), and the DBC taxi network (`2`) all come straight from the fork — nothing nav-related is re-implemented here.

## controls

- 2D: click drill World → continent → zone · `T` enter 3D for the current surface (zone or whole continent) · Esc out
- 3D: WASD pan (velocity-smoothed, speed scales with height) · wheel zoom (eased) · RMB look · `V` toggle real map / nav mesh · `Tab` cycle continent · `M` painted overlay
- Overlays: `1` city waypoint routes (gold walk / purple lift / blue teleport, green city rings) · `2` taxi flight network · `N` navmesh debug surface · `L` traverse runs panel
- Debug: backtick toggles the stats overlay

## debug instrumentation (for AI agents)

- `MAP_BROWSER_DEBUG=1` — per-second `[mb-debug]` stdout line (fps, stream tile counts, AOI rect, camera)
- `MAP_BROWSER_STATS=path.json` — machine-readable stats rewritten every ~2 s and on exit: frame p50/p95, tile counts, `focus_to_terrain_visible_ms`, `focus_to_stream_settled_ms`, per-surface `mosaic_pack_ms`, per-overlay build ms
- `MAP_BROWSER_AUTO="zone=Durotar,seconds=8,screenshot=local_data/mb.png"` — autopilot probe; exits nonzero if terrain never became visible or streaming never settled
- agents: use `make map-browser-probe` for before/after perf numbers instead of watching the GUI (AGENTS.md forbids launching GUI apps unprompted; the probe auto-exits)

## architecture notes

- **Two 3D view modes**, toggled with `V` (`src/map_browser/streaming.nim`):
  - **Real map** (default): textured ADT game terrain streamed around the camera. Only a window near the camera can be resident (whole-map textured terrain does not exist in the fork — `loadSelectedMap` never fills `visualNode`), so detail follows you as you fly. Far plane + fog scale with camera height (`clamp(height × 1.6 + 2600, 3900, 5300)`, fog hugging the far plane) so the ground never fogs out; the 50 ms stream budget stays on while required tiles load, then drops to 3 ms. Camera height ≤ 4000.
  - **Nav mesh** (the upstream whole-map demo): the fork's `loadSelectedMap` / `--all` path loads every tile's navmesh + collision mesh in one blocking pass (progress in the terminal, once per continent), then the whole continent is visible at once with nothing streaming. Far plane 20000, no fog, camera height ≤ 9000. This is literally the bot-walkable world.
- **2D mosaics** compose on a background thread (BLP + pixie off the render thread); atlas upload happens when ready.
- Overlay rendering uses fork primitives only (`setWorldCubes`, `setWorldDebugCubes`, `setWorldTargetRings`); polylines are cube trails, same as the fork's own nav route overlay.
- Run trajectories parse godview JSONL (2 Hz, `~/.coworld/player/launcher_units/runtime/*/leagues/traverse/captures/`) on a background thread, decimated to ≤2000 points.

## known limits

- Continents are separate map files — you cannot pan across the ocean between Kalimdor and Eastern Kingdoms; `Tab` switches.
- Real-map mode cannot show the whole continent textured at once — the fork has no whole-map visual loader, only streamed tiles. Switch to nav-mesh mode (`V`) for the everything-at-once view.
- The nav-mesh whole-map load blocks the window while it runs — watch the terminal for `Processed X/N map tiles`. Once per continent (switching back and forth re-loads).
- Off-world WorldMapAreas (the three battleground instance maps: Alterac Valley, Warsong Gulch, Arathi Basin) are badged "2D only" and never enter 3D. Fork-side wishlist if we ever care: exported route edges, whole-map *textured* terrain loader.

## tasks

- [x] finish implementing a nice pretty map viewer
  - [x] nice camera controls (frameBoundary-driven, velocity smoothing, eased wheel zoom)
  - [x] looks decent (detailed ADT near camera + WDL horizon backdrop, fog-hidden seam)
  - [x] renders the world as one seamless entity per continent (stream follows camera; `T` continent-level 3D; see known limits for cross-continent)
- [x] rudimentary waypoint system between cities
  - reuses fork `world_catalog` routes + `worldRoutePath`; taxi network from the already-loaded WorldCatalog; visualize-only for now
- [x] great lifts / logical connections
  - fork models these as `greatLift` / `travelSpellId` flags on route nodes; rendered as purple/blue edges with LIFT / TELEPORT labels
- [x] zone shenanigans
  - inventory via `make map-browser-once` (off-world = the three battleground maps); such zones stay 2D-only
- [x] visualizer for previous runs
  - `L` lists godview captures newest-first with northing score; click to plot colored trails + beats rings + checkpoints on the 3D map
- [ ] future: click-to-route via `routeNavmeshDebugAsync` (start/end picks → real navmesh path overlay)
- [ ] future: waypoint authoring (click-to-place, saved in `traverse_beats.json` shape)
- [ ] future: run playback scrubbing (marker moving along the trail)
