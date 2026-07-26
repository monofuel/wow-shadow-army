# Quest waypoint data — turning the world DB into an addon data file

Vanilla 1.12 ships no quest markers. Blizzard-era players solved that by
crowdsourcing (Questie, wowhead, Joana's guide). We own the realm, so
"where is this objective" is a join, not guesswork — the
`docs/advisor.md` "unfair advantage: ground truth in mariadb" thesis, cashed
out as the first shippable artifact.

`tools/gen_quest_data.py` reads the VMaNGOS world DB plus the client's
`WorldMapArea.dbc` and writes `addons/ShadowArmy/QuestData.lua`: a pure data
file (no logic, Lua 5.0 loadable) that the ShadowArmy addon consumes to draw
waypoints.

## How to regenerate

Realm must be up (`make start-server`); DB access is **read-only**.

```sh
make quest-data                                        # whole game (default)
make quest-data QUEST_DATA_ARGS="--max-level 20"       # level-scoped
make quest-data QUEST_DATA_ARGS="--zones 85,130,12"    # zone-scoped
```

or directly:

```sh
python3 tools/gen_quest_data.py \
  --dbc-dir ../coworld-vanilla-wow/local_data/vmangos-5875-data/dbc
```

stdlib only, no venv, ~10 s for the full game. Output is **deterministic** — no
timestamps, every collection sorted before emit — so a rerun against an
unchanged DB leaves the file byte-identical and the diff stays honest.

`tools/play_classic.sh` symlinks `addons/*` into the client, so a regenerate
followed by `/reload` in-game picks up new data without restarting the client
(the live iteration loop in `docs/advisor.md`).

## Shape of the file

```lua
ShadowArmyQuestData = {
  ["Rude Awakening"] = {
    id = 363, level = 1, minLevel = 1, zone = 85,
    objectives = {
      { label = "Mindless Zombie", kind = "mob", count = 8,
        spots = { {zone = 85, x = 43.2, y = 61.7}, ... } },
    },
    turnIn    = { label = "Shadow Priest Sarvis", zone = 85, x = 30.8, y = 66.2 },
    startedBy = { label = "Undertaker Mordo",     zone = 85, x = 30.2, y = 71.7 },
  },
}
```

- **Keys are quest titles, not ids**, because 1.12's quest log only exposes
  titles (`GetQuestLogTitle`). See the collision gap below.
- `zone` is an `AreaTable` zone id; `x`/`y` are zone-normalized percent — the
  same space `GetPlayerMapPosition` returns, multiplied by 100.
- `kind` is `"mob"`, `"object"` or `"item"`.
- Quests with nothing locatable are omitted entirely rather than emitted empty.

## Coordinate conversion (verified, not assumed)

DB spawns are world coords (`map`, `position_x`, `position_y`). The addon needs
zone-normalized percent. The mapping comes from `WorldMapArea.dbc`
(8 fields / 32-byte records: `id, mapId, areaId, areaName, locLeft, locRight,
locTop, locBottom`).

The trap is the axis convention. WoW world coords are **north-positive X,
west-positive Y**, while the map is drawn with **x running west→east and y
running north→south**. So the map axes are the *swapped* pair:

```
mapX = (locLeft - worldY) / (locLeft - locRight) * 100    -- uses world Y
mapY = (locTop  - worldX) / (locTop  - locBottom) * 100   -- uses world X
```

Taking `locTop/locBottom` for the map's *x* (the intuitive reading) produces
coordinates that are individually in range and therefore look fine — they are
just transposed, and every waypoint lands somewhere plausible but wrong.

### How it was verified

`WorldMapOverlay.dbc` is an independent ground truth from the same client
build: for each sub-area it stores where that sub-area sits on the zone map
image, in texture pixels (17 fields: `id, mapAreaId, areaId[4], mapPointX,
mapPointY, textureName, textureWidth, textureHeight, offsetX, offsetY,
hitRectTop, hitRectLeft, hitRectBottom, hitRectRight`). The 1.12 zone map is
1002x668 logical pixels, so `hitRect` centers convert straight to percent.

Pick NPCs whose sub-area is unambiguous, run the formula, compare to the
client's own overlay placement:

| landmark NPC (world x, y)                  | formula        | overlay hitRect center | delta        |
|--------------------------------------------|----------------|------------------------|--------------|
| Gunther Arcanus — Brightwater Lake tower    | (68.2, 41.9)   | (68.3, 42.1)           | (-0.1, -0.2) |
| High Executor Derrington — The Bulwark      | (83.1, 68.9)   | (83.6, 69.6)           | (-0.5, -0.7) |
| Rot Hide Gnoll — Garren's Haunt             | (58.4, 38.7)   | (57.8, 38.2)           | (+0.6, +0.5) |
| Innkeeper Renee — Brill                     | (61.7, 52.0)   | (59.6, 55.2)           | (+2.1, -3.2) |
| Deathguard Saltain — Deathknell             | (31.6, 65.6)   | (34.4, 63.9)           | (-2.8, +1.7) |

Sub-percent agreement on the first three (single-point landmarks); the last two
sit a couple of percent off the *center* of a village-sized overlay box, which
is exactly what a specific NPC inside a village should do. The transposed
formula puts Gunther Arcanus at (41.9, 68.2) — in the sea south of Brill.

Both `Deathguard Saltain (31.6, 65.6)` and `Deathknell`'s overlay box
(x 27.8–41.0, y 54.8–73.1) are reproducible from the DBCs alone, so this check
can be re-run whenever the client data pin moves.

## Zone resolution

`WorldMapArea.dbc` has 51 rows for this build: the two continent overviews
(`areaId = 0`, always skipped — we want a zone map) and 49 zone/city maps. A
spawn's zone is the **smallest bounding box containing the point**, so city
maps (nested inside their zone's box) correctly win for NPCs inside them.

Two refinements on top:

- The quest's own zone wins ties. A bounding box cannot separate the Ruins of
  Lordaeron (surface, Tirisfal) from Undercity directly below it, so an
  explicit hint from `quest_template.ZoneOrSort` is preferred whenever it also
  contains the point.
- `ZoneOrSort` is sometimes a *sub*-area (quest 363 "Rude Awakening" sorts to
  154 Deathknell, not 85 Tirisfal), so it is walked up the `AreaTable`
  parent chain until a mappable zone appears. Negative values are sort buckets
  (class / profession / dungeon) with no zone at all; those quests borrow a
  zone from their turn-in, starter, or first objective.

## Objective spot selection

Raw spawn tables are useless as waypoints — one mob can have 400 rows. Each
objective is reduced to at most 12 spots:

1. Resolve every spawn to (zone, x%, y%); drop what has no zone map.
2. Keep the **densest single zone** (quest zone breaking ties) — a HUD arrow
   wants one place to go, not a scatter across continents.
3. Grid-bucket in normalized percent, starting at a 3% bin and growing it 1.5x
   until the bucket count fits the budget.
4. Emit the **medoid** of each bucket — a real spawn point, never a centroid
   that could land in the middle of a lake.

## The two loot-id indirections

Worth writing down because getting either wrong fails *silently* — the join
returns nothing rather than erroring:

- **Loot templates are keyed by loot id, not by spawnable entry.**
  `gameobject_loot_template.entry` is `gameobject_template.data1` (for types
  3 CHEST and 25 FISHINGHOLE). In this DB only **14 of 562** GO loot ids happen
  to equal the object entry, so joining on entry loses essentially every chest
  in the game — including the "Scavenged Goods" objective of *Scavenging
  Deathknell*. Creatures go through `creature_template.loot_id` /
  `skinning_loot_id` / `pickpocket_loot_id` (usually `== entry`, `0` for the
  9501 creatures with no loot, and genuinely different for 21).
- **`mincountOrRef < 0` is a reference**, not a count: it points at
  `reference_loot_template` entry `-mincountOrRef`, and those nest. 28364 of
  232486 creature loot rows are references; they are flattened recursively
  before the item→source map is built.

VMaNGOS is a progression core, so template, spawn, relation and loot rows all
carry patch ranges. `mangosd.conf` has `WowPatch = 10` (1.12); every query
filters on it, and templates with several patch rows resolve to the highest
`patch <= 10`.

## Known gaps

- **Instanced content has no coordinates at all.** 1.12 `WorldMapArea.dbc`
  covers only outdoor zones and the five capitals — dungeon maps have no row,
  so a Deadmines or Scarlet Monastery objective cannot be expressed in the
  zone-normalized space the addon uses. ~830 item objectives and ~79 mob/GO
  objectives are instance-only. A future rev could fall back to the *dungeon
  entrance* coordinates.
- **Title collisions.** The quest log gives titles, not ids, and 1344 locatable
  quests share a title with an earlier one (faction mirrors, "Wanted!" bounty
  boards, class quests keyed by race). The lower-level quest wins, so the
  Alliance twin of a shared title can shadow the Horde one. Fix path: the addon
  *can* see zone headers while walking the quest log, so a later contract rev
  could key on `(title, zone)`.
- **Items with no locatable source** (~1103 objectives): crafted, vendor-bought,
  handed out by scripts/spells, or produced by quest-object interactions that
  do not go through a loot template.
- **`SrcItem` objectives** (~803) are intentionally skipped — that item is
  handed to you on accept, so there is nothing to go find.
- **Escort quests** are represented only by their start/turn-in NPC. The route
  the escort walks lives in `creature_movement` / scripts and is not modelled.
- **"Explore area" objectives** (`ReqSpellCast` / area triggers with no
  creature) have no spawn to point at.
- **Class and race-gated quests** are emitted like any other; the file carries
  no `RequiredRaces` / `RequiredClasses`, so the addon shows whatever the player
  actually has in their log — harmless, since the log is the filter.
- **One zone per objective.** A mob spread evenly across two zones is reduced
  to the denser one. The per-spot `zone` field is still emitted, so relaxing
  this later needs no contract change.
