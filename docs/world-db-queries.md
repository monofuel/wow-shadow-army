# Answering game questions from the world DB

We own the realm, so "where do I get gear," "who gives the level-10 class
quest," "who drops this item" are joins against ground truth, not wiki
guesses — the same unfair advantage that powers `docs/quest-data.md` and
`docs/item-data.md`, usable interactively. monofuel asks these while
playing; bots will ask the same shapes through the planner later. Answer
from the DB, then consider whether the QUERY PATTERN belongs here. The
raw game facts themselves are `kb/`-shaped — do not refill `kb/` until
the planner exists (AGENTS.md "Docs vs knowledgebase").

## Access

```sh
docker exec coworld-vmangos-coworld-game-1 mariadb -umangos -pmangos mangos -e "SQL"
```

Read-only by doctrine. Two coworld-game containers may be up (the
conductor's race lane runs its own); the home realm is
`coworld-vmangos-coworld-game-1` — a bare `name=coworld-game` docker
filter is ambiguous.

## Schema gotchas (each cost a failed query once)

- **Column-case split:** `quest_template` is CamelCase (`Title`,
  `QuestLevel`, `ZoneOrSort`, `RewChoiceItemId1`), `item_template` is
  snake_case (`name`, `quality`, `item_level`, `required_level`,
  `buy_price`, `sell_price`, `inventory_type`). Mixing conventions =
  ERROR 1054.
- **Progression patches:** most template tables carry a `patch` column
  (PK `(entry, patch)`, full rows not deltas). Filter `patch <= 10`
  (WowPatch 10 == 1.12) and take the highest row per entry — see
  `gen_item_data.py` for the canonical resolution.
- **Quest relations:** starters in `creature_questrelation`
  (`gameobject_questrelation` for GOs), enders in
  `creature_involvedrelation` (no underscore before `relation`).
- **Class masks:** `RequiredClasses` / `AllowableClass` are bitmasks of
  `1 << (classId - 1)`: warrior 1, paladin 2, hunter 4, rogue 8,
  priest 16, shaman 64, mage 128, warlock 256, druid 1024.
  `AllowableClass = -1` means everyone.
- **Race masks:** `RequiredRaces` / `AllowableRace` are bitmasks of
  `1 << (raceId - 1)`: human 1, orc 2, dwarf 4, night elf 8, undead 16,
  tauren 32, gnome 64, troll 128. The two combinations worth recognising on
  sight are **77 = Alliance** (1+4+8+64) and **178 = Horde** (2+16+32+128);
  255 is everyone spelled out. `UnitRace()`/`UnitClass()` in the addon give a
  localized *name*, not an id, so a consumer needs its own name→bit table.
- **`0` means "no gate", not "nobody".** `RequiredRaces = 0` /
  `RequiredClasses = 0` is the DB's "anyone may take this", and it is the
  common case (3408 of 4727 quest rows have both zero). Treating 0 as a mask
  and `AND`-ing it fails every quest in the game. Note also that a quest with
  no race gate can still be faction-gated in practice: the eight capital-city
  cloth donations are `0/0` and separated only by reputation with the city,
  which is why identity masks cannot tell them apart
  (`docs/quest-data.md`, title collisions).
- **Item class/subclass:** weapons class 2 (sub: 10 staff, 15 dagger,
  19 wand), armor class 4 (sub 0 misc, 1 cloth), quest items class 12.
  `inventory_type` is the equip slot family.
- **Spawn locations:** `creature` rows have `map, position_x,
  position_y` but no zone id — bound by coordinate box, or convert
  properly via `WorldMapArea.dbc` (`gen_quest_data.py`'s `MapAreas`,
  axis convention verified in `docs/quest-data.md`).

## Worked patterns

Gear upgrades reachable at level L in zone Z (2026-08-14 worked example,
level-9 warlock in Tirisfal):

```sql
SELECT q.Title, q.QuestLevel, i.name, i.quality, i.item_level
FROM quest_template q
JOIN item_template i ON i.entry IN
  (q.RewChoiceItemId1,q.RewChoiceItemId2,q.RewChoiceItemId3,
   q.RewChoiceItemId4,q.RewItemId1,q.RewItemId2)
WHERE q.ZoneOrSort IN (85,154) AND q.QuestLevel BETWEEN 5 AND 14
  AND ((i.class=4 AND i.subclass IN (0,1)) OR (i.class=2 AND i.subclass IN (10,15,19)))
GROUP BY i.entry ORDER BY q.QuestLevel;
```

Class quests at a level (who gives the warlock Voidwalker chain):

```sql
SELECT q.entry, q.Title, q.MinLevel, ct.name
FROM quest_template q
JOIN creature_questrelation qr ON qr.quest=q.entry
JOIN creature_template ct ON ct.entry=qr.id
WHERE q.RequiredClasses=256 AND q.MinLevel BETWEEN 8 AND 12;
```

Vendor inventory near a place (coordinate-box the spawns):

```sql
SELECT DISTINCT ct.name, i.name, i.required_level
FROM npc_vendor v
JOIN creature_template ct ON ct.entry=v.entry
JOIN item_template i ON i.entry=v.item
WHERE i.class=2 AND i.subclass=19 AND i.required_level<=14
  AND v.entry IN (SELECT id FROM creature WHERE map=0
    AND position_x BETWEEN 1300 AND 2500 AND position_y BETWEEN 100 AND 500);
```

Negative results are answers too: that vendor query returning empty is
how we know no low-level wand vendor exists near Brill/Undercity — so
"buy a wand" is not advice the advisor should ever generate there.
