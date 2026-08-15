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
    races = 178, classes = 256,   -- omitted when the quest gates nobody
    objectives = {
      { label = "Mindless Zombie", kind = "mob", count = 8,
        spots = { {zone = 85, x = 43.2, y = 61.7}, ... } },
      { label = "Darkhound Blood", kind = "item", count = 5,
        from = { "Cursed Darkhound", "Decrepit Darkhound" },
        spots = { {zone = 85, x = 62.8, y = 38.1}, ... } },
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
- `races` / `classes` are `quest_template.RequiredRaces` /
  `RequiredClasses` — bitmasks of `1 << (id - 1)`, tabulated in
  `docs/world-db-queries.md`. **Both are omitted when the DB stores 0**
  ("anyone"), so a reader must treat a missing field as "no gate" and never as
  "matches nothing". They ride on the primary entry *and* on every `alts`
  variant, because their whole reason for existing is telling variants apart
  (see title collisions below). 1221 of 4394 emitted variants carry at least
  one; the other 3173 are open to everybody.
- `from` names who to hunt for an item objective — the densest in-zone
  sources (up to 4, selected by spawn-point count, NOT drop rate), emitted
  alphabetically for a stable file; do not read `from[1]` as "best".
  Omitted when it would add nothing: mob-kill objectives never carry it (their
  `label` *is* the enemy), nor does an item whose only source shares its name.
- Quests with nothing locatable are omitted entirely rather than emitted empty.
- Same-title quests carry their other variants in an `alts` list on the
  primary entry (same shape, nested once) — see title collisions below.

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
  boards, chain steps like Fields of Grief 365→407, class quests keyed by
  race). The lower-level quest is the primary entry and every other variant is
  emitted under its `alts` list (same shape, nested once). The addon's
  `QuestModel.resolve` picks the variant whose objective labels match the live
  leaderboard text — a variant scores +2 per matched label and -1 per label
  the log does not show, so a delivery sequel with no tracked objectives beats
  a gather part 1 once the log stops showing gather lines. Ties keep the
  primary.

  Labels alone are not enough, which is what the `races`/`classes` masks are
  for (ticket 0045). Measured over the whole file with the audit method from
  `wow-coworld/quest-alts-ambiguity-report.md`: 590 titles carry alts and
  **503 of them are ambiguous** to a label-only resolver — 336 because every
  variant has zero objectives (the score is always 0, so the primary wins
  forever) and 167 because two variants share the same nonempty label set.
  240 of the 503 have a colliding group holding **two or more different
  turn-in NPCs**, i.e. a wrong pick puts the marker on the wrong person.

  Filtering variants by player identity before scoring labels cuts that
  substantially. For an undead warlock (`races` bit 16, `classes` bit 256):

  | | label-only | + identity filter |
  |---|---|---|
  | variants offered | 1934 | 1418 |
  | titles that vanish entirely | 0 | 113 |
  | titles resolved outright (one survivor) | 0 | 46 |
  | ambiguous titles | 503 | **350** |
  | … with differing turn-ins | 240 | **188** |
  | zero-objective alts whose turn-in differs from the primary | 470 | 335 |

  What it does **not** fix is the headline offenders. The eight-city cloth
  donations (*A Donation of Wool/Silk/Mageweave/Runecloth*), both commendation
  signet families and *The Missing Diplomat* all store `RequiredRaces = 0` and
  `RequiredClasses = 0`: the game gates those by **reputation with the city
  faction**, not by identity, so no mask can separate them and they stay at
  the top of the remaining list. They need the turn-in-zone tiebreak (step 3
  of ticket 0045). The groups that do collapse are the ones actually keyed to
  identity — Deliana/Mokvar (`races` 77 vs 178 plus a class bit), race-specific
  class chains, Alliance/Horde mirrors.

  This file only **emits** the masks. Choosing a variant with them is
  `QuestModel.resolve`'s job in the addon.
- **Same entry emitted twice.** `quest_template` is patch-ranged like every
  other template table, and unlike `item_template` the quest read does not
  collapse a quest's rows to the highest `patch <= 10` — it takes them all. So
  a quest with two patch rows appears twice in its own `alts` list (visible as
  the duplicated `id@Llevel` pairs in the ambiguity audit). Harmless to the
  label resolver, since duplicates agree on everything, but it inflates the
  variant counts above and it is the obvious next cleanup.
- **Items with no locatable source** (~1103 objectives): crafted, vendor-bought,
  handed out by scripts/spells, or produced by quest-object interactions that
  do not go through a loot template.
- **`SrcItem` objectives** (~803) are intentionally skipped — that item is
  handed to you on accept, so there is nothing to go find.
- **Escort quests** are represented only by their start/turn-in NPC. The route
  the escort walks lives in `creature_movement` / scripts and is not modelled.
- **"Explore area" objectives** (`ReqSpellCast` / area triggers with no
  creature) have no spawn to point at.
- **Class and race gates are data, not a filter.** Every quest is emitted
  whoever it is for; `races`/`classes` ride along so a *reader* can filter.
  For drawing a quest the player already holds this changes nothing (the log
  is the filter); it matters only when several quests share a title and the
  file has to say which one this player is holding.
- **One zone per objective.** A mob spread evenly across two zones is reduced
  to the denser one. The per-spot `zone` field is still emitted, so relaxing
  this later needs no contract change.
