# Road data — turning baked road polylines into an addon data file

Roads are freeways. A vanilla road is patrolled by almost nothing, the mobs
that matter are off to either side, and a level 4 who walks the road from
Deathknell to Brill arrives; the one who walks the diagonal fights four
darkhounds and does a corpse run. That makes "where are the roads" a routing
input, not a map decoration — the advisor's dotted path to the top quest
(`docs/advisor.md`) and, later, the bots' quest pathing.

The ground truth already exists. The map-browser experiment baked every
visible road on both continents out of the terrain and minimap art into
world-coordinate polylines: `tools/data/road_waypoints_azeroth.jsonl` (236
segments / 5224 points) and `road_waypoints_kalimdor.jsonl` (176 / 4987), with
`tools/data/README.md` describing the bake and `src/map_browser/roads.nim` as
the reference loader.

What the addon cannot use is a world coordinate. 1.12 gives an addon nothing
but zone-normalized percent (`GetPlayerMapPosition`), which is the space
`QuestData.lua` already speaks. So `tools/gen_road_data.py` does exactly one
job: replay those polylines through the **verified** world→zone converter and
re-emit them per zone as `addons/ShadowArmy/RoadData.lua`.

## How to regenerate

No realm, no DB, no network — the JSONL artifacts and two DBCs are the whole
input.

```sh
make road-data
```

or directly:

```sh
python3 tools/gen_road_data.py \
  --dbc-dir ../coworld-vanilla-wow/local_data/vmangos-5875-data/dbc
```

stdlib only, no venv, under a second. Output is **deterministic** — sorted by
zone and then by the segment's own coordinates, no timestamps — so a rerun
against unchanged inputs leaves the file byte-identical and the diff stays
honest.

This is a host-side data generator in the pre-existing `gen_quest_data.py`
mold, sanctioned by ticket 0039 — the AGENTS.md no-Python rule scopes to the
bot army itself, and host generators stay monofuel's call.

## Shape of the file

```lua
ShadowArmyRoadData = {
[85] = {
{30.7,70.6,31.2,69.8,31.5,69.1,31.8,68.3,31.9,67.5},
{32.0,65.1,32.0,64.4,32.1,63.4,32.3,62.7},
},
}
```

- Keys are `AreaTable` zone ids, the same ids `QuestData.lua` uses.
- Each entry is an array of polylines; each polyline is a **flat** run of
  `x, y, x, y, …` numbers in zone-normalized percent (`GetPlayerMapPosition`
  × 100). Flat pairs instead of `{x=,y=}` tables because this file is read
  once per zone into a graph and never indexed by name — it cuts the file by
  more than half and the loader is two array reads.
- Zone **names** are not emitted. The addon already has the
  `ShadowArmyQuestZones` id→name bridge from `QuestData.lua`, and a route only
  exists where the quest enrichment that produced its target exists anyway.

## The conversion (borrowed, deliberately not rewritten)

`gen_road_data.py` imports `MapAreas` straight out of `gen_quest_data.py`. The
axis convention is the one trap in this whole pipeline and it fails *quietly*:
taking `locTop/locBottom` for the map's x produces coordinates that are
individually in range and therefore look fine — every road lands somewhere
plausible and wrong. `docs/quest-data.md` documents the formula and how it was
verified against `WorldMapOverlay.dbc`; there is exactly one copy of it and
this tool calls that copy.

Zone resolution is likewise inherited: a point belongs to the **smallest**
`WorldMapArea` box containing it, so a road through Undercity's tunnels
resolves to Undercity rather than to Tirisfal above it.

## What the tool actually does

1. Read each JSONL (meta line first for `map_id`, then one segment per line).
2. Convert every point world→(zone, x%, y%).
3. **Split on zone change.** A continent road crosses zone borders constantly,
   and per-zone percent is a different coordinate system on each side, so a
   crossing is a segment break rather than a very long edge. Points with no
   zone map at all (open sea, unmapped strips) also end a run.
4. **Decimate to ≥0.7% spacing**, endpoints always kept. The bake thinned to
   ~10 yards in *world* units, which is far denser than a routing graph needs;
   a vanilla zone is roughly 3500 × 2333 yards, so 0.7% is ~20 yards. This is
   where 10211 input points become 4532.
5. Emit, sorted, with a stats header.

Runs left with fewer than two points are dropped — one point is not an edge.

## Coverage

412 input segments / 10211 points become **462 segments / 4532 points across
39 zones**, ~46 KiB. The split is why the segment count goes *up*.

Tirisfal Glades (zone 85) carries 13 segments / 94 points — the Deathknell
road, the ring through Brill, and the north-east run toward the Bulwark. The
capitals are in there too (Undercity 1497, Ironforge 1537, Orgrimmar 1637,
Thunder Bluff 1638, Darnassus 1657), which is a free win: city "roads" are
exactly the corridors a courier wants.

Zones with no row simply have no roads baked, and the addon falls back to the
straight line it drew before this file existed.

## How the addon uses it

`RouteModel` (in `ShadowArmy.lua`, above the WoW-UI guard so `make test`
exercises it on host Lua):

- `RouteModel.build(zoneSegments)` turns one zone's polylines into a graph —
  nodes are points, edges chain each polyline, and points from **different**
  polylines within 1.5% of each other are joined as a junction. Without that
  join the network is a pile of disconnected sticks, because the bake cuts a
  road at every bridge, crossing and border. A spatial hash keeps the join
  near-linear; Tirisfal builds in 0.3 ms and the worst zone in the file is
  under 1 ms, so a zone change is not a hitch. Built once per zone, cached.
- `RouteModel.route(graph, start, goal)` returns waypoints: an off-road entry
  leg, Dijkstra along the road graph, an off-road exit leg. **Off-road legs
  are charged 1.6×** — that multiplier is the whole thesis, the number that
  says a road yard is safer than a field yard, and it is why the router
  accepts a longer path. It bails to a plain two-point straight line whenever
  roads cannot help: the goal is nearer than the nearest road, the two off-road
  legs already cost more than the whole trip, the road network is
  disconnected, the node budget blew, or the finished road route simply costs
  more than walking straight. That fallback is not an error path — it is the
  correct answer most of the time, and it is exactly what r44 did.

The advisor draws the result as a trail of small dim dots under the objective
pins on the world map, and points the panel's `>>` compass at the next route
waypoint instead of straight at the objective. Distances on the panel stay
crow-flies estimates; only the bearing follows the road.

`RoadData.lua` is registered in the `.toc` **after** `QuestData.lua` and every
read of it is guarded, so a file that fails to load costs the route and
nothing else.

## Known gaps

- **Only what the bake saw.** These polylines come from road textures and the
  minimap ribbon, not from a road table (vanilla has none). A road hidden
  under a bridge texture, or one the mask scored as too steep/too wide, is not
  here. `tools/data/README.md` has the bake's thresholds.
- **No cross-zone routing.** Segments stop at the border and the graph is
  per-zone, so a route to a target in another zone does not exist — the quest
  model only produces same-zone targets today, so nothing asks for one yet.
  Joining zones needs a border-adjacency pass and a multi-zone map surface.
- **Percent space is anisotropic.** Distances inside the model are
  percent-space euclidean, and a zone is wider than it is tall, so the router
  slightly prefers north-south road legs. It cancels out of every comparison
  that decides *whether* to use a road; it only nudges *which* road.
- **No direction, no cost surface.** Every road is a two-way edge with
  distance as its only weight. Elevation, water crossings and known mob
  density along a segment are all things a later rev could weight.
