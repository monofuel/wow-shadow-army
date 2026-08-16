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

No realm, no DB, no network — the JSONL artifacts, two DBCs and the extracted
terrain grids are the whole input.

```sh
make road-data
```

or directly:

```sh
python3 tools/gen_road_data.py \
  --dbc-dir ../coworld-vanilla-wow/local_data/vmangos-5875-data/dbc
```

`--map-dir` defaults to `maps/` beside `--dbc-dir`, so pointing `--dbc-dir` at
either extracted-data tree gives a byte-identical file. `--no-terrain` files
points by the smallest containing map box alone, which reproduces the pre-0059
assignment.

stdlib only, no venv, a couple of seconds. Output is **deterministic** — sorted by
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
`WorldMapArea` box containing it. That rule is right for nested maps in
general and wrong for the capitals in particular — see the next section.

## What the tool actually does

1. Read each JSONL (meta line first for `map_id`, then one segment per line).
2. Convert every point world→(zone, x%, y%). **Which zone is decided by the
   terrain**, not by the map boxes — ticket 0059, next section but two.
3. **Split on zone change.** A continent road crosses zone borders constantly,
   and per-zone percent is a different coordinate system on each side, so a
   crossing is a segment break rather than a very long edge. Points with no
   zone map at all (open sea, unmapped strips) also end a run.
4. **Re-file capital-box roads** onto the zone the city sits in — ticket 0050,
   next section but one.
5. **Decimate to ≥0.7% spacing**, endpoints always kept. The bake thinned to
   ~10 yards in *world* units, which is far denser than a routing graph needs;
   a vanilla zone is roughly 3500 × 2333 yards, so 0.7% is ~20 yards. This is
   where 10211 input points become ~4500.
6. **Bridge the baker's cuts** and drop the islands no bridge could reach —
   this is the whole of ticket 0046.
7. Emit, sorted, with a stats header that now carries the per-zone
   connectivity numbers.

Runs left with fewer than two points are dropped — one point is not an edge.

## Capital map boxes overlay open ground (ticket 0050)

The five capital city maps (plus Stormwind, which has no baked road) are
axis-aligned rectangles laid over terrain that belongs to somebody else.
Undercity's box covers the Ruins of Lordaeron, Ironforge's covers the mountain
road up to its gates, Orgrimmar's clips a strip of Durotar, Darnassus' clips a
corner of Teldrassil. Under the smallest-box rule every one of those outdoor
roads filed under the city — 78 baked points, invisible to the player actually
walking on them.

**Which boxes are capitals is a DBC lookup, not a hardcoded list.**
`AreaTable.flags & 0x100` partitions this build's 49 zone maps exactly: the 43
outdoor zones are `0x40`/`0x41`, the three battlegrounds are `0x0`, and only
Undercity / Stormwind / Ironforge / Orgrimmar / Thunder Bluff / Darnassus carry
`0x138`.

**Which points move is answered by the bake itself.** These polylines come from
terrain and minimap art, so the baker only ever saw *surface*: it cannot see
Undercity's tunnels or Ironforge's halls. So the question "is this run the
city's own street or the zone's road underneath the box?" reduces to whether
the run is part of a polyline that continues outside the box:

- a run **continuous with points outside** the box — the same baked polyline
  crosses the box edge at walkable terrain height — is one road with the
  outdoor zone, so it moves;
- a polyline that **never leaves the box** is the capital's own network, so it
  stays.

On this bake the separation is total, which is why the rule needs no tuning:

| capital | runs that leave the box | z drift across the crossing | runs wholly inside |
|---|---|---|---|
| Undercity 1497 | 3 (49 + 6 + 2 pts) | 19.0 / 0.8 / 3.2 | none |
| Ironforge 1537 | 1 (11 pts) | 3.2 | 2 (11 pts, z ≈ 495) |
| Orgrimmar 1637 | 1 (9 pts) | 1.0 | none |
| Darnassus 1657 | 1 (1 pt) | 0.8 | 10 (164 pts, z ≈ 1320) |
| Thunder Bluff 1638 | none | — | 9 (148 pts, z 127–165) |

`--capital-z-band` (default 60 world units) is the guard, not the mechanism:
a run stops counting as "the same surface" once it climbs that far from the
point it crossed at. Nothing in this bake comes close to binding it — the worst
genuine surface run drifts 27.2 — but it is what stops a future re-bake that
walks Thunder Bluff's lift ramp up from Mulgore from dragging the whole mesa
network out of the city. Negative disables the pass entirely.

**Where the points land** is the zone the city *sits in*: the smallest
non-capital box that **fully contains** the capital's box. Full containment
matters. Undercity's box is also clipped by Silverpine's and Western
Plaguelands' boxes, both of which are *smaller in area* than Tirisfal's, so a
plain smallest-box relocation cut the 57-point southern road into three pieces
across three zones. Containment picks the one zone that can hold the whole
city, and the road stays one road. Orgrimmar is the exception — its box runs
north past Durotar's — so it falls back to the plain box rule, which puts its
9 points in Durotar anyway.

| capital | sits in |
|---|---|
| Undercity 1497 | Tirisfal 85 |
| Stormwind 1519 | Elwynn 12 |
| Ironforge 1537 | Dun Morogh 1 |
| Thunder Bluff 1638 | Mulgore 215 |
| Darnassus 1657 | Teldrassil 141 |
| Orgrimmar 1637 | *(no containing box — falls back)* |

Result at the time of 0050: Undercity 1497 and Orgrimmar 1637 left the file
entirely, because every road baked inside their boxes was outdoor road.
Ironforge kept 11 points, Thunder Bluff 148, Darnassus 164 — no capital's
interior network leaked into a parent zone. Tirisfal gained the southern road
as one 32-node component running (48.0,82.2) → (61.9,65.2), reaching to within
1.4% of the Undercity entrance, but Brill still could not route to it.

0059 then took most of this pass's work off it — see that section for the
counts as they stand now. The pass is kept because it covers points the terrain
grids cannot answer for, and because it is the guard against a re-bake walking
a lift ramp up into a city.

## Real zone footprints beat map boxes (ticket 0059)

0050 fixed the *nested* overlap (a capital's box sitting inside its zone's) and
in doing so exposed the bigger one: outdoor boxes overlap **each other**.
`WorldMapArea` rectangles are axis-aligned; zones are not. Western Plaguelands'
box (12.33M units²) is smaller in area than Tirisfal's (13.6M) and reaches west
to world Y = 417 — across everything east of Tirisfal x ≈ 57.9, **Brill
included** — so the smallest-box rule filed the whole Brill corridor under
zone 28. Containment cannot help here; neither box contains the other.

**The client does not use boxes to answer "what zone is this".** It reads the
terrain, and vmangos' extractor bakes exactly that into `maps/*.map`: a
per-cell `AreaTable.exploreFlag` grid, 16×16 cells over each 533.33-unit
terrain grid. That is the zone footprint at its real shape. Walk the cell's
area id up `AreaTable.parentAreaId` and you get the zone the client itself
would name. `TerrainAreas` in `gen_road_data.py` is ~60 lines of `struct` over
that file, indexed with vmangos' own arithmetic rather than a re-derivation
(`GridMap.cpp` `TerrainInfo::GetGrid` + `GridMap::getArea`):

```
file  : maps/%03u%02u%02u.map  % (mapId, int(32 - worldX/533.33), int(32 - worldY/533.33))
header: 'MAPS','z1.4', then 8 uint32 offset/size pairs   (40 bytes)
area  : 'AREA', uint16 flags, uint16 gridArea
          flags & 0x1 -> whole grid is gridArea, no table follows
          else        -> uint16[16*16], cell [lx*16 + ly], lx from X, ly from Y
```

Both magics are checked before any offset is trusted, and the local copy of
the format lives at `local_data/reference/vmangos-core/src/game/Maps/GridMapDefines.h`.

**Terrain arbitrates, boxes still project.** The answer still has to be
expressed in some zone's percent space and only a box can do that, so the box
rule runs for every point regardless. What the terrain decides is *which* zone
gets to do the projecting:

- terrain names a zone whose box covers the point → **terrain wins**;
- terrain names a zone whose box does *not* reach the point → the box answer
  stands. A `WorldMapArea` box can be slightly tighter than the terrain it
  describes, and a percent outside 0–100 is not a coordinate the addon can
  draw. **12 points** of 10211 land here;
- terrain resolves to no mappable zone → box rule. **463 points**, all of them
  Hyjal 616 (293 + 106, no world map in 1.12) and The Maul 3217 inside Dire
  Maul (57 + 7). Both are genuinely unmapped, and the neighbouring box the road
  falls back to is the right place to draw it.

**3315 of 10211 points move**, far more than 0050's 78, because the overlap is
much worse than 0050 assumed. That number is only trustworthy because of what
the moves *are*: 87 distinct terrain sub-areas drive them, and every one lands
in its own true parent zone.

| terrain sub-area | → zone | box had said | pts |
|---|---|---|---|
| Zul'Gurub 19 | Stranglethorn 33 | Blasted Lands 4 | 296 |
| Southern Gold Road 1157 | Barrens 17 | Mulgore 215 | 188 |
| Gold Road 458 | Barrens 17 | Durotar 14 | 133 |
| Darkwhisper Gorge 2256 | Winterspring 618 | Azshara 16 | 123 |
| Ruins of Andorhal 193 | W. Plaguelands 28 | Alterac 36 | 114 |
| Nethergarde Keep 1438 | Blasted Lands 4 | Swamp of Sorrows 8 | 99 |
| Darkshire 42 | Duskwood 10 | Deadwind Pass 41 | 82 |
| Jintha'Alor 354 | The Hinterlands 47 | Arathi 45 | 74 |
| Gates of Ironforge 809 | Dun Morogh 1 | Ironforge 1537 | 22 |
| **Brill 159** | **Tirisfal 85** | **W. Plaguelands 28** | **33** |

This is the discriminator that killed `WorldMapOverlay.dbc` as an arbiter. The
overlay rects re-filed a comparable 1858–2854 points, but they included moves
no sub-area justifies, because a big zone's overlay boxes sprawl over its
neighbours. Here the *same* Blasted Lands → Stranglethorn move that looked like
an obvious bulk mistake under overlays turns out to be correct and to have a
name: those 296 points are in **Zul'Gurub**, in southern Stranglethorn, and
Blasted Lands' box merely reaches over them.

**0050 still runs, after the arbiter**, because it answers a question terrain
cannot: it is driven by the polyline's own continuity, so it also covers points
the grids have no area for. It now finds only **22 points** to move instead of
78 — the arbiter got to Ruins of Lordaeron, the Gates of Ironforge and the
Durotar strip first, and by name rather than by height band. Capital interiors
are unaffected: Thunder Bluff 1638 keeps all 148 of its mesa points and
Darnassus 1657 keeps 143, while Ironforge 1537, Undercity 1497 and Orgrimmar
1637 now hold *nothing* — every road baked in their boxes was outdoor road, and
the terrain says so directly (Ironforge and Undercity have **zero** terrain
cells at all; they are pure WMO interiors the grids cannot see).

`--no-terrain` reproduces the pre-0059 assignment, and `--map-dir` overrides
the grid location (it defaults to `maps/` beside `--dbc-dir`). If the grids are
missing the tool warns and carries on with the box rule; the header always
records which rule produced the file.

## Bridging the baker's cuts (ticket 0046)

`RouteModel` can only route *inside one connected component*, and it joins
polylines only when their points land within `junctionDist` (1.5%). The baked
segments cut wider than that — the mask breaks at every bridge deck, tunnel
mouth, town cobblestone and wide crossing — so before this pass **31 of 39
zones had 3+ components** and the router bailed `disconnected` on 43% of random
start/goal pairs. Raising `junctionDist` in the addon was measured and rejected
(1.5→3.0 bought 2.5 points of hit rate) and it also glues roads that merely
pass near each other. The gap is in the data, so it gets closed in the data.

**What gets bridged.** Only *segment endpoints*, never interior points: an
endpoint is where the baker stopped seeing road, an interior point is road it
did see. A bridge is emitted as a plain two-point polyline whose ends sit
exactly on the two existing endpoints, so `RouteModel`'s own junction pass
welds it in — **same flat pair format, no marker field, no addon change**. The
cost is two duplicate nodes per bridge.

**When.** The z coordinate is gone by this stage, so the heading a stub ends on
is the only evidence left that two stubs are one road. A longer bridge is a
bigger claim, so the cone closes as the gap grows:

| gap | test |
|---|---|
| ≤ 2.5% | none — too short to be anything but the same road (T-junctions, hairpins, town paving) |
| ≤ 6.0% | within **40°** of *one* of the two endpoint headings — a bridge, a ford, a wide crossing |
| ≤ 12.0% | within **20°** — only a road that visibly points at the other stub earns a span this long |

12% is the honest ceiling: past that, "aimed at each other" stops being
evidence in a 100×100 space, and the result would be invented roads over water
and cliffs. Candidates are taken greedily shortest-first (deterministic, and a
merge can only ever remove candidates), skipping any pair already in one
component, up to **30 bridges per zone**. A zone that wants more than that is
not suffering from baker cuts, it is missing road, and hiding that behind 100
bridges would defeat the point of the coverage stats.

**Then the islands go.** After bridging, a component smaller than **4 nodes**
that is not the zone's main network is deleted. Such a stub can never produce a
route — `RouteModel` routes inside one component — but it *can* win the
nearest-node lookup away from the road that could, turning that route into a
`disconnected` bail and a straight line. Deleting it strictly increases
coverage. The zone's largest component is never dropped however thin it is: a
zone whose only road is a 3-node stub (Badlands) keeps it and short-hops, which
is honest, where deleting it would silently erase the zone.

All four numbers are flags — `--bridge-tiers 2.5:180,6:40,12:20`,
`--bridge-budget`, `--orphan-min` — so re-tuning against the sampler is a
one-liner, and `--bridge-budget 0 --orphan-min 0 --capital-z-band -1`
reproduces the pre-0046 file.

## Coverage

412 input segments / 10211 points become **519 segments / 4234 points across
34 zones**, ~47 KiB (89 of those segments are bridges). The zone split is why
the segment count goes *up*; 0050 and then 0059 are why the zone count came
*down* from 39.

Six zones lost every point they had at the 0050 state — Westfall 40 (26 pts),
Deadwind Pass 41 (127), Stonetalon 406 (84), Ironforge 1537 (13), Desolace 405
(9), Badlands 3 (4) — and three gained road they never had: **The Barrens 17
(238)**, Winterspring 618 (54), Darkshore 148 (43). None of that is deletion.
Those six zones have thousands of terrain cells each and **not one baked road
point** among them; what they held was their neighbours' road, captured by an
overlapping box. The file now says so instead of drawing a road in the wrong
zone. Tirisfal 85 goes 128 → 194 points, Ashenvale 331 128 → 277, Stranglethorn
33 121 → 263, Dun Morogh 1 94 → 160.

The generated header carries the regression-visible metric, one line per zone,
sorted by zone id:

```
-- coverage (RouteModel junctionDist 1.5%): zones with 3+ components
-- 27 -> 11 of 34; mean largest-component share 54.2% -> 76.6%
-- zone    85: components   3 ->   2, largest  92.7% ->  97.4%, bridges  1
```

`components` and `largest` are counted the way `RouteModel.build` counts them
(chain each polyline, join across polylines within 1.5%) over *distinct
coordinates*, so a bridge's duplicate endpoints do not dilute the share. Before
→ after is bridging + orphan pruning. Any zone whose numbers move in a diff
tells you the bake or the thresholds changed.

Measured with a host-Lua sampler over `RouteModel.route` (50 random pairs per
zone, 1950 total, plus 300 in Tirisfal):

| | before | after |
|---|---|---|
| zones with 3+ components | 31 / 39 | 17 / 39 |
| mean largest-component share | 54.4% | 73.1% |
| global road-route hit rate | 3.5% | 7.5% |
| global `disconnected` bails | 43.3% | 27.0% |
| Tirisfal (85) road / `disconnected`, 300 pairs | 6% / 55% | 21% / **0%** |

Mulgore 215 goes 33/50 `disconnected` → 2/50, Stranglethorn 33 goes 20 → 6,
Wetlands 11 goes 28 → 16, and Hillsbrad 267 / Ashenvale 331 / Eastern
Plaguelands 139 all roughly halve. Elwynn 12 was already one component and
comes out behaviourally identical — bridging cannot regress a zone it does not
bridge, and no zone's hit rate went down.

**What 0050 then cost and bought.** Re-filing the capital boxes moves real road
into zones that had none of it, and some of that road arrives *disconnected*
from the network already there. Same host-Lua sampler, run over the r-0046 file
and the current one (37 zones × 50 pairs, plus 300 in Tirisfal):

| | r-0046 | + 0050 |
|---|---|---|
| global road-route hit rate | 7.0% | 6.8% |
| global `disconnected` bails | 29.4% | 32.0% |
| Tirisfal 85, road | 18% | 14% |
| Tirisfal 85, `disconnected` | 0% | 35% |

That was not a bug in the pass, it was the pass telling the truth: Tirisfal
held the southern road it always had, and that road was a second component
because the piece linking it to Brill was filed under Western Plaguelands. The
metric was what should move once the link was un-hidden, and 0059 is what
un-hid it.

**What 0059 bought.** Same sampler shape (50 uniform random pairs per zone from
a fixed seed, so both files are asked the *same* pairs, plus 300 in Tirisfal).
The zone list changes between the two files, so the honest comparison is both:

| | 0050 state | + 0059 |
|---|---|---|
| all zones in that file | 37 zones / 1850 pairs | 34 zones / 1700 pairs |
| global road-route hit rate | 7.3% | **10.6%** |
| global `disconnected` bails | 33.7% | **24.9%** |
| the 31 zones common to both, road | 8.6% | **9.9%** |
| the 31 zones common to both, `disconnected` | 35.3% | **28.8%** |
| Tirisfal 85, road (300 pairs) | 12% | 14% |
| Tirisfal 85, `disconnected` | 36% | **20%** |
| zones with 3+ components after bridging | 17 / 37 | **11 / 34** |
| mean largest-component share | 70.5% | **76.6%** |

(These are this pass's own sampler, run over both files; they are not the same
draws as the 0046/0050 rows above, so compare within a table, not across.)

The named acceptance routes, host-Lua over zone 85:

| route | 0050 state | + 0059 |
|---|---|---|
| Murist (60.50,38.79) → Cursed Darkhounds (61.45,53.73) | `straight-cheaper` | **`road`**, 13 waypoints, length 17.94 |
| Brill (61.7,52.0) → Undercity entrance (63.0,66.0) | `disconnected` | **`road`**, 20 waypoints, length 17.52 |
| Deathknell (30.0,71.8) → Brill (61.7,52.0) | `road`, 51 waypoints | `road`, 54 waypoints (no regression) |

Zone 85 goes from 128 points with **nothing within 2% of Brill** to 194 points
with the Brill corridor present, in one 97.4% component.

The surviving capitals are Thunder Bluff 1638 and Darnassus 1657, and what they
hold is only city interior: the corridors a courier wants, with none of the
open ground their boxes overlay.

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
  here. `tools/data/README.md` has the bake's thresholds. 0059 made the *size*
  of this gap visible for the first time, because the box rule had been
  papering over it: **Westfall 40, Deadwind Pass 41, Stonetalon 406, Desolace
  405 and Badlands 3 have no baked road at all** and now correctly hold no row,
  where before they held their neighbours' road. (The Barrens 17, which earlier
  revisions of this doc called empty for the same reason, turns out to have
  987 baked points — they were filed under Mulgore, Durotar and Stonetalon.)
- **Zone boxes still steal each other's roads where the terrain cannot
  arbitrate — but that is now 475 points, not thousands.** 0059 replaced the
  smallest-box rule with the terrain's own per-cell area ids for 3315 of 10211
  points; the rest either agreed with the boxes already or fell back:
  - **463 points** whose terrain area has no world map at all — Hyjal 616 and
    The Maul 3217 (Dire Maul) — keep the box answer. Both are genuinely
    unmapped in 1.12, so there is nothing better to file them under, and the
    box they fall back to is a neighbour whose map can at least draw them.
  - **12 points** whose terrain zone has a `WorldMapArea` box that does not
    reach them. Boxes are occasionally *tighter* than the terrain they
    describe, and a percent outside 0–100 is not drawable, so the box answer
    stands. Small enough to leave alone; it would need per-zone box fudging to
    fix, which is a worse trade than 12 points.
  - The arbiter only sees **terrain**. `TerrainAreas` reads the gridmap, where
    the running client would first consult WMO area info from the vmaps. That
    matters for indoor space only, and this bake is surface-only, so nothing
    here depends on it — but a future bake that walks a WMO interior would need
    the vmap leg too.
- **`gen_quest_data.py` still files spawns by the box rule.** It does not
  suffer as badly, because a quest carries an explicit `ZoneOrSort` hint that
  wins ties where a road carries no hint, but a spawn with no hint sitting in
  an overlap is mis-filed for exactly the reason 0059 fixed here.
  `MapAreas.area_by_flag` + `zone_of_area` are the pieces it would need; the
  `TerrainAreas` reader would move up alongside `MapAreas`. Not done, not
  measured — its own ticket.
- **Bridging cannot invent a road that was never baked.** Tirisfal is still the
  worked example, but only one of its two named routes is left:
  - **Brill → Undercity entrance** is **fixed** by 0059. It bailed `short-hop`
    before 0050, `disconnected` after it, and now returns a 20-waypoint road
    route: the missing link was the Brill stretch filed under Western
    Plaguelands, and the terrain arbiter put it back. Note nothing was bridged
    to achieve it — the road was always there, in the wrong zone.
  - **Brill → Agamand Mills** still bails `straight-cheaper`, unchanged by
    0059. The mills branch is connected (an 11.3% bridge from (43.1,49.2) to
    (48.8,39.5), 16° off the stub's own heading), but it leaves the main road
    at x≈43 while Brill is at x≈62, so the road answer runs long against a
    ~20% crow line — at the 1.6× off-road penalty the straight line genuinely
    wins. The missing piece is the direct Brill→mills path, which the bake
    never saw, so no zone-assignment work can reach it.
- **Sharpest remaining endpoint gaps** (measured, so the next pass can argue
  with them rather than guess): globally **24.9%** of sampled pairs still bail
  `disconnected`, down from 33.7%, and it is now concentrated in Duskwood 10
  (36/50), Dun Morogh 1 (34), Felwood 361 and Western Plaguelands 28 (31),
  Arathi 45 / Redridge 44 / Darnassus 1657 / Teldrassil 141 (23). Every one of
  them still shows 3+ components in the header, with the surviving islands too
  big to prune and too far apart to bridge. Those are bake holes, not junction
  gaps, and no further zone-assignment work will touch them.
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
