# Item data — vendor prices and item facts the 1.12 client will not tell you

Vanilla 1.12 has **no API for an item's vendor sell price** (no
`GetItemSellPrice`, no `GetSellValue` — the retail-era addons that show one
either crowdsource it or scrape merchant frames), and `GetItemInfo` returns
`nil` for anything the client has not cached this session, which is most of
what a bot's bags fill up with. We own the realm, so "what is this thing and
what is it worth" is a `SELECT`, not guesswork — the same
`docs/advisor.md` "ground truth in mariadb" thesis as `docs/quest-data.md`,
pointed at bags instead of quests.

`tools/gen_item_data.py` reads `item_template` from the VMaNGOS world DB and
writes `addons/ShadowArmy/ItemData.lua`: a pure data file (no logic, Lua 5.0
loadable) covering **every item in the game**.

**Registered in the `.toc`, not yet read.** Ticket 0040 added `ItemData.lua`
(and `RoadData.lua`) to `addons/ShadowArmy/ShadowArmy.toc` in one go, so the
table is loaded and `ShadowArmyItemData` is there for the taking — but no
addon code reads it yet. The shadow-bags disposition feature is the first
consumer. Registering it costs one client restart (the TOC file list is
cached for the whole client session), which is why it was bundled rather than
paid twice.

## How to regenerate

Realm must be up (`make start-server`); DB access is **read-only**.

```sh
make item-data
```

or directly:

```sh
python3 tools/gen_item_data.py
```

stdlib only, no venv, no DBCs, a couple of seconds. Output is
**deterministic** — sorted by item id, no timestamps — so a rerun against an
unchanged DB leaves the file byte-identical and the diff stays honest.

`tools/play_classic.sh` symlinks `addons/*` into the client, so a regenerate
plus a reload picks up new data without restarting the client.

## Shape of the file

```lua
ShadowArmyItemData = {
[182] = { q = 1, lvl = 1, class = 12 },
[727] = { sell = 244, q = 2, lvl = 10, req = 5, slot = 13, class = 2, sub = 7 },
[7073] = { sell = 6, lvl = 1, class = 15 },
}
```

| field   | source column            | meaning                                   | default |
|---------|--------------------------|-------------------------------------------|---------|
| `sell`  | `sell_price`             | vendor sell price, **copper**             | 0       |
| `q`     | `quality`                | 0 poor … 5 legendary (6 = artifact exists)| 0       |
| `lvl`   | `item_level`             | item level                                | 0       |
| `req`   | `required_level`         | required character level                  | 0       |
| `slot`  | `inventory_type`         | `InventoryType` **numeric id**, not a name| 0       |
| `class` | `class`                  | item class id (2 weapon, 4 armor, 12 quest…)| 0     |
| `sub`   | `subclass`               | item subclass id                          | 0       |

**A field is omitted when it equals its default**, which is what keeps a
whole-game file at ~1.1 MiB instead of triple that. Read every field as
`row.sell or 0` — absent means default, never "unknown". An item whose every
field is default would still get a row (`[123] = {},`) so
`ShadowArmyItemData[id]` always answers "does this item exist for our patch";
no item in the current DB is that empty, but the emitter never drops a key.

**Keys are item ids, not names.** Every bag slot yields an item link and every
link carries `item:ID` (`GetContainerItemLink` →
`|cff...|Hitem:2589:0:0:0|h[Linen Cloth]|h|r`), so the addon can always key by
id — names are deliberately not stored. They would be the single biggest thing
in the file for a lookup nothing performs, and the client already has the
localized name in the link it just parsed.

This is a host-side data generator in the pre-existing `gen_quest_data.py`
mold, sanctioned by ticket 0039 — the AGENTS.md no-Python rule scopes to the
bot army itself, and host generators stay monofuel's call.

VMaNGOS is a progression core, so `item_template` rows carry a `patch` column
and an item may have several. The query filters `patch <= 10` (`WowPatch = 10`
== 1.12 in `mangosd.conf`) and the highest such row wins — same rule as
`gen_quest_data.py`'s `load_template`. 20034 rows collapse to 17707 items;
e.g. Robes of Insight (940) sells for 12565 at patch 0 and 12566 at patch 9,
and the file emits 12566.

## Size

17707 entries, ~1.14 MiB, 17724 lines. 13775 items have a nonzero sell price;
the other ~3900 (quest items, most containers of bound junk, deprecated rows)
are worth nothing to a vendor, which is itself the signal the disposition
feature wants.

## What the disposition feature will use it for

The shadow-bags feature tags every bag item with a disposition — sell to
vendor, equip, keep for a quest, destroy when full — and each of those calls
needs a fact the client cannot supply for an uncached item. `sell` ranks what
to unload at the next merchant and prices the decision to drop something when
bags are full (gray with the lowest copper-per-slot loses). `class = 12`
(quest) and `q` flag what must never be auto-sold regardless of price. `slot`,
`req`, `lvl` and `q` decide whether a drop is an upgrade worth equipping
versus vendor fodder — `slot` says which equipment slot it even competes for,
`req` says whether the character can wear it yet. Because the table is keyed by
id and covers the whole game, the addon answers all of that the instant a link
appears, with no `GetItemInfo` cache miss and no server round trip.
