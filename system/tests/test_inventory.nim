## Unit tests for the inventory chat bus (ticket 0052) — System side.
## Grammar is the addon's `ShadowArmy.invModel` (r49):
##   <SA> inv  <seq>/<total> <id>:<count>,…         full snapshot, REPLACE
##   <SA> invd <seq>/<total> +<id>:<count>,-<id>,…  delta, PATCH (absolute)
## Run: nim r --hints:off --warnings:off system/tests/test_inventory.nim
## No network, no docker, no realm — pure functions on fixture strings.

import
  std/[json, options, os, sets, strutils, tables, times, unittest],
  ../system_server

const
  ChatHead =
    "2026-08-15 09:00:00 [Chat] (acc 100008, ip 172.20.0.1, guid 1000007, name Murist, map 0, pos 1994.96 1559.28 78.2792) [Say] Murist:1000007 : "
  LineInvFull = ChatHead & "<SA> inv 1/2 2589:12,4306:5"
  LineInvDelta = ChatHead & "<SA> invd 1/1 +2589:20,-4306"
  LineInvEmpty = ChatHead & "<SA> inv 1/1"

suite "parseInvPayload — addon grammar":
  test "snapshot header + comma separated pairs":
    let line = parseInvPayload("1/2 2589:12,4306:5", isFull = true)
    check line.isFull
    check line.part == 1 and line.parts == 2
    check line.pairs.len == 2
    check line.pairs[0] == (itemId: 2589, count: 12)
    check line.pairs[1] == (itemId: 4306, count: 5)

  test "delta tokens: +id:count sets an absolute total, -id removes":
    let line = parseInvPayload("1/1 +2589:20,-4306", isFull = false)
    check not line.isFull
    check line.pairs.len == 2
    check line.pairs[0] == (itemId: 2589, count: 20)
    check line.pairs[1] == (itemId: 4306, count: 0)

  test "empty-bags line carries a header and no pairs":
    let line = parseInvPayload("1/1", isFull = true)
    check line.isFull
    check line.part == 1 and line.parts == 1
    check line.pairs.len == 0

  test "kind decides the mode":
    check isInvFullKind("inv")
    check not isInvFullKind("invd")
    check isInvKind("inv") and isInvKind("invd")
    check not isInvKind("loaded")

  test "junk tokens are ignored, not fatal":
    let line = parseInvPayload("1/1 2589:12,garbage,x:y,4306:5", isFull = true)
    check line.pairs.len == 2

  test "optional seq= / bag= hints still parse":
    let line = parseInvPayload("seq=17 bag=4 2589:1")
    check line.seqNo == 17
    check line.bag == 4 and line.hasBag

suite "applyInvLine — snapshots":
  test "a multi-line set is applied only when whole":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/2 2589:12", isFull = true), 1000.0)
    check inv.items.len == 0 # never show a set we know is missing a line
    check invAssembling(inv)
    check inv.updatedAt == 0.0
    applyInvLine(inv, parseInvPayload("2/2 4306:5", isFull = true), 1001.0)
    check not invAssembling(inv)
    check inv.items.len == 2
    check inv.items[2589].count == 12
    check inv.items[4306].count == 5
    check inv.complete
    check inv.updatedAt == 1001.0

  test "parts may arrive out of order":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("2/2 4306:5", isFull = true), 1000.0)
    applyInvLine(inv, parseInvPayload("1/2 2589:12", isFull = true), 1001.0)
    check inv.items.len == 2

  test "an abandoned set does not clobber the last known bags":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12", isFull = true), 1000.0)
    check inv.items.len == 1
    # A new set starts and loses its second line; the old view stays up.
    applyInvLine(inv, parseInvPayload("1/2 4306:5", isFull = true), 1010.0)
    check inv.items.len == 1
    check inv.items[2589].count == 12
    # A later complete set replaces everything.
    applyInvLine(inv, parseInvPayload("1/1 777:3", isFull = true),
      1010.0 + InvSnapshotWindowSec + 1.0)
    check inv.items.len == 1
    check inv.items.hasKey(777)

  test "empty snapshot means empty bags, positively":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12", isFull = true), 1000.0)
    applyInvLine(inv, parseInvPayload("1/1", isFull = true), 1010.0)
    check inv.items.len == 0
    check inv.lines == 2
    check inv.updatedAt == 1010.0 # heard from, and the answer is "nothing"

suite "applyInvLine — deltas":
  test "absolute set and removal":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12,4306:5", isFull = true), 1000.0)
    applyInvLine(inv, parseInvPayload("1/1 +2589:20,-4306"), 1010.0)
    check inv.items[2589].count == 20
    check not inv.items.hasKey(4306)
    check liveInventoryItems(inv).len == 1

  test "replaying the same delta is idempotent":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12", isFull = true), 1000.0)
    applyInvLine(inv, parseInvPayload("1/1 +2589:20"), 1010.0)
    applyInvLine(inv, parseInvPayload("1/1 +2589:20"), 1011.0)
    check inv.items[2589].count == 20

  test "a delta during an in-flight snapshot survives the commit":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/2 2589:12", isFull = true), 1000.0)
    applyInvLine(inv, parseInvPayload("1/1 +999:2"), 1001.0)
    applyInvLine(inv, parseInvPayload("2/2 4306:5", isFull = true), 1002.0)
    check inv.items.hasKey(999)
    check inv.items.len == 3

  test "optional seq guard drops an out-of-order delta":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12", isFull = true), 1000.0)
    applyInvLine(inv, parseInvPayload("seq=9 +2589:20"), 1010.0)
    applyInvLine(inv, parseInvPayload("seq=7 +2589:3"), 1011.0)
    check inv.items[2589].count == 20

  test "line counter and kind track the bus":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12", isFull = true), 1000.0)
    check inv.lastKind == "full"
    applyInvLine(inv, parseInvPayload("1/1 +2589:13"), 1001.0)
    check inv.lastKind == "delta"
    check inv.lines == 2

suite "chat.log → inventory":
  test "inv / invd lines arrive as addon events with the right kind":
    let full = parseAddonEvent(LineInvFull)
    check full.isSome
    check full.get.kind == "inv"
    check full.get.name == "Murist"
    check parseInvPayload(
      full.get.payload, isFull = isInvFullKind(full.get.kind)).pairs.len == 2

    let delta = parseAddonEvent(LineInvDelta)
    check delta.isSome
    check delta.get.kind == "invd"
    let dl = parseInvPayload(
      delta.get.payload, isFull = isInvFullKind(delta.get.kind))
    check not dl.isFull
    check dl.pairs[1] == (itemId: 4306, count: 0)

    let empty = parseAddonEvent(LineInvEmpty)
    check empty.isSome
    check empty.get.kind == "inv"
    check empty.get.payload == "1/1"

suite "item join":
  test "sql lists the requested ids and prefers the highest patch":
    let sql = itemInfoSql(@[2589, 4306])
    check "entry IN (2589,4306)" in sql
    check "ORDER BY entry, patch" in sql
    check "mangos.item_template" in sql

  test "tsv parse":
    let rows = parseItemInfoTsv("2589\tLinen Cloth\t13\t1\n4306\tSilk Cloth\t150\t1\n")
    check rows.len == 2
    check rows[0].itemId == 2589
    check rows[0].name == "Linen Cloth"
    check rows[0].sellPrice == 13
    check rows[1].quality == 1

  test "malformed rows are skipped, not fatal":
    check parseItemInfoTsv("\n\nnot-a-row\n").len == 0

suite "inventory panel":
  test "quiet placeholder before any inv line arrives":
    let body = renderInventoryPanelBody(
      none(CharacterInventory), initTable[int, ItemInfo]())
    check "No inventory on the bus yet." in body
    check "<table" notin body

  test "assembling first snapshot says so instead of showing a hole":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/3 2589:12", isFull = true), epochTime())
    let body = renderInventoryPanelBody(some(inv), initTable[int, ItemInfo]())
    check "assembling" in body
    check "1/3" in body

  test "empty bags render as empty, not as unknown":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1", isFull = true), epochTime())
    let body = renderInventoryPanelBody(some(inv), initTable[int, ItemInfo]())
    check "Bags empty." in body

  test "rows carry id, count and vendor value, richest first":
    var inv = newCharacterInventory("Murist")
    applyInvLine(inv, parseInvPayload("1/1 2589:12,4306:5", isFull = true), epochTime())
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    info[4306] = ItemInfo(itemId: 4306, name: "Silk Cloth", sellPrice: 150, quality: 1)
    let body = renderInventoryPanelBody(some(inv), info)
    check "Silk Cloth" in body
    check "Linen Cloth" in body
    check body.find("Silk Cloth") < body.find("Linen Cloth")
    check "updated" in body
    check "2 stacks" in body

## Realm inventory (Inventory tab) — DB-authoritative bags for every
## character. Fixtures mirror the real TSV:
##   guid name level class money online item_id count stacks
const
  RealmInvTsv = """
1000007	Murist	11	9	4623	1	2589	12	2
1000007	Murist	11	9	4623	1	7073	7	2
1000024	Ashborn	2	5	0	0	159	2	1
1000099	Emptyguy	1	1	0	0	0	0	0
"""
  RealmInvSharedTsv = """
1000007	Murist	11	9	4623	1	2589	12	2
1000024	Ashborn	2	5	100	0	2589	3	1
1000031	Igris	5	1	0	0	2589	5	1
1000031	Igris	5	1	0	0	7073	1	1
"""

suite "parseRealmInventoryTsv — realm bags from the characters DB":
  test "rows group into characters and stack counts sum":
    let chars = parseRealmInventoryTsv(RealmInvTsv)
    check chars.len == 3
    check chars[0].name == "Murist"
    check chars[0].level == 11
    check chars[0].money == 4623
    check chars[0].online
    check chars[0].items.len == 2
    check chars[0].itemTotal == 19
    check chars[0].stackTotal == 4
    check chars[1].name == "Ashborn"
    check not chars[1].online
    check chars[1].itemTotal == 2

  test "item id 0 is the empty-bags placeholder, not an item":
    let chars = parseRealmInventoryTsv(RealmInvTsv)
    check chars[2].name == "Emptyguy"
    check chars[2].items.len == 0
    check chars[2].itemTotal == 0

  test "short and malformed rows are skipped, never fatal":
    let chars = parseRealmInventoryTsv("garbage\n\n1000007\tMurist\t11\n")
    check chars.len == 0

suite "sortRealmInvStacks — quality desc, then name":
  test "epic before common, ties broken by name":
    var info = initTable[int, ItemInfo]()
    info[1] = ItemInfo(itemId: 1, name: "Zulian Stone", sellPrice: 0, quality: 4)
    info[2] = ItemInfo(itemId: 2, name: "Linen Cloth", sellPrice: 0, quality: 1)
    info[3] = ItemInfo(itemId: 3, name: "Copper Bar", sellPrice: 0, quality: 1)
    let sorted = sortRealmInvStacks(@[
      RealmInvStack(itemId: 2, count: 5, stacks: 1),
      RealmInvStack(itemId: 3, count: 5, stacks: 1),
      RealmInvStack(itemId: 1, count: 1, stacks: 1)
    ], info)
    check sorted[0].itemId == 1
    check sorted[1].itemId == 3 # Copper Bar before Linen Cloth
    check sorted[2].itemId == 2

  test "unknown items sort last and keep their id":
    var info = initTable[int, ItemInfo]()
    info[2] = ItemInfo(itemId: 2, name: "Linen Cloth", sellPrice: 0, quality: 0)
    let sorted = sortRealmInvStacks(@[
      RealmInvStack(itemId: 99, count: 1, stacks: 1),
      RealmInvStack(itemId: 2, count: 5, stacks: 1)
    ], info)
    check sorted[0].itemId == 2
    check sorted[1].itemId == 99

suite "renderRealmInventoryBody — Inventory tab body":
  test "characters render with gold, totals and quality-coloured items":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    info[7073] = ItemInfo(itemId: 7073, name: "Broken Fang", sellPrice: 1, quality: 4)
    info[159] = ItemInfo(itemId: 159, name: "Refreshing Spring Water", sellPrice: 1, quality: 1)
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvTsv),
      fetchedAt: epochTime(),
      error: ""
    )
    let body = renderRealmInventoryBody(inv, info)
    check "3 characters" in body
    check "Murist" in body
    check "Ashborn" in body
    check "Linen Cloth" in body
    check "q4" in body # epic colour class on Broken Fang
    check "0g 46s 23c" in body
    check body.find("Broken Fang") < body.find("Linen Cloth")

  test "empty bags say so per character":
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvTsv),
      fetchedAt: epochTime(), error: "")
    let body = renderRealmInventoryBody(inv, initTable[int, ItemInfo]())
    check "Bags empty." in body

  test "DB error with no prior read is an honest empty state, not a crash":
    let inv = RealmInventory(
      characters: @[], fetchedAt: 0.0, error: "mariadb query failed (exit 1)")
    let body = renderRealmInventoryBody(inv, initTable[int, ItemInfo]())
    check "Realm DB unavailable" in body
    check "mariadb query failed" in body
    check "/admin" in body

  test "DB error with a prior read keeps the rows and flags them stale":
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvTsv),
      fetchedAt: epochTime() - 300.0,
      error: "mariadb query failed (exit 1)")
    let body = renderRealmInventoryBody(inv, initTable[int, ItemInfo]())
    check "last good read" in body
    check "Murist" in body
    check "stale" in body

suite "realmInvItemIds — one join for the whole realm":
  test "distinct ids across every character":
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvTsv))
    let ids = realmInvItemIds(inv)
    check ids.len == 3
    check 2589 in ids
    check 7073 in ids
    check 159 in ids

suite "item quality helpers":
  test "class + label per classic quality":
    check itemQualityClass(0) == "q0"
    check itemQualityClass(4) == "q4"
    check itemQualityClass(99) == "q1"
    check itemQualityLabel(5) == "legendary"
    check itemQualityLabel(1) == "common"

suite "realmInvItems — realm-wide aggregation":
  test "the same item across three characters sums into one row":
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvSharedTsv))
    let items = realmInvItems(inv)
    check items.len == 2
    var linen: RealmInvItem
    for it in items:
      if it.itemId == 2589:
        linen = it
    check linen.total == 20
    check linen.stacks == 4
    check linen.holders.len == 3

  test "holders are richest first, then by name":
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvSharedTsv))
    var linen: RealmInvItem
    for it in realmInvItems(inv):
      if it.itemId == 2589:
        linen = it
    check linen.holders[0].name == "Murist"
    check linen.holders[0].count == 12
    check linen.holders[1].name == "Igris"
    check linen.holders[1].count == 5
    check linen.holders[2].name == "Ashborn"
    check linen.holders[2].count == 3

  test "distinct item types counted once":
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvSharedTsv))
    check realmInvItemCount(inv) == 2

suite "sortRealmInvItems — quality desc, then total desc, then name":
  test "epic outranks a bigger pile of common":
    var info = initTable[int, ItemInfo]()
    info[1] = ItemInfo(itemId: 1, name: "Tiny Epic", sellPrice: 0, quality: 4)
    info[2] = ItemInfo(itemId: 2, name: "Huge Common", sellPrice: 0, quality: 1)
    let sorted = sortRealmInvItems(@[
      RealmInvItem(itemId: 2, total: 99, stacks: 5),
      RealmInvItem(itemId: 1, total: 1, stacks: 1)
    ], info)
    check sorted[0].itemId == 1
    check sorted[1].itemId == 2

  test "equal quality falls back to the bigger pile":
    var info = initTable[int, ItemInfo]()
    info[1] = ItemInfo(itemId: 1, name: "Alpha", sellPrice: 0, quality: 1)
    info[2] = ItemInfo(itemId: 2, name: "Beta", sellPrice: 0, quality: 1)
    let sorted = sortRealmInvItems(@[
      RealmInvItem(itemId: 1, total: 3, stacks: 1),
      RealmInvItem(itemId: 2, total: 10, stacks: 2)
    ], info)
    check sorted[0].itemId == 2
    check sorted[1].itemId == 1

  test "unknown items sort last under their id":
    var info = initTable[int, ItemInfo]()
    info[2] = ItemInfo(itemId: 2, name: "Linen Cloth", sellPrice: 0, quality: 1)
    # Negative-cache miss: key present, empty name, quality 0.
    info[99] = ItemInfo(itemId: 99, name: "", sellPrice: 0, quality: 0)
    let sorted = sortRealmInvItems(@[
      RealmInvItem(itemId: 99, total: 50, stacks: 1),
      RealmInvItem(itemId: 2, total: 1, stacks: 1)
    ], info)
    check sorted[0].itemId == 2
    check sorted[1].itemId == 99

suite "renderRealmInvItemTable — the army's pool":
  test "one row per item with total, stacks and holders":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    info[7073] = ItemInfo(itemId: 7073, name: "Broken Fang", sellPrice: 1, quality: 4)
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvSharedTsv))
    let html = renderRealmInvItemTable(realmInvItems(inv), info)
    check "Linen Cloth" in html
    check "Broken Fang" in html
    check "Murist ×12" in html
    check "Igris ×5" in html
    check "Ashborn ×3" in html
    check """<td class="lvl">20</td>""" in html
    check """<td class="lvl">4</td>""" in html

  test "holder names are HTML escaped":
    let it = RealmInvItem(
      itemId: 1, total: 1, stacks: 1,
      holders: @[RealmInvHolder(name: "<script>alert(1)</script>", count: 1)]
    )
    let html = renderRealmInvItemTable(@[it], initTable[int, ItemInfo]())
    check "&lt;script&gt;" in html
    check "<script>" notin html

  test "more than three holders collapse to a count with a full tooltip":
    let it = RealmInvItem(
      itemId: 1, total: 15, stacks: 5,
      holders: @[
        RealmInvHolder(name: "Murist", count: 5),
        RealmInvHolder(name: "Igris", count: 4),
        RealmInvHolder(name: "Beru", count: 3),
        RealmInvHolder(name: "Tusk", count: 2),
        RealmInvHolder(name: "Kaisel", count: 1)
      ]
    )
    let html = renderRealmInvItemTable(@[it], initTable[int, ItemInfo]())
    # The cell body shows the top three and a count; the title carries all five.
    check """title="Murist ×5, Igris ×4, Beru ×3, Tusk ×2, Kaisel ×1"""" in html
    check "+2 more" in html
    let visible = html[html.find("""×1">""") + 4 .. ^1]
    check "Tusk" notin visible
    check "Kaisel" notin visible

  test "an empty pool says so":
    let html = renderRealmInvItemTable(@[], initTable[int, ItemInfo]())
    check "The army is carrying nothing." in html

  test "an unnamed item renders as its id in common white, not as poor":
    var info = initTable[int, ItemInfo]()
    # Negative-cache miss: key present, empty name, quality 0.
    info[4242] = ItemInfo(itemId: 4242, name: "", sellPrice: 0, quality: 0)
    let html = renderRealmInvItemTable(@[
      RealmInvItem(itemId: 4242, total: 3, stacks: 1,
        holders: @[RealmInvHolder(name: "Igris", count: 3)])
    ], info)
    check "Item#4242" in html
    check "q1" in html
    check "q0" notin html

suite "realmInvHoldersText — tooltip source":
  test "holders join as plain text, richest first, empty stays empty":
    check realmInvHoldersText(@[]) == ""
    check realmInvHoldersText(@[
      RealmInvHolder(name: "Murist", count: 12),
      RealmInvHolder(name: "Igris", count: 3)
    ]) == "Murist ×12, Igris ×3"

suite "renderRealmInventoryBody — item-centric tab":
  test "the item table leads and the per-character view is secondary":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    info[7073] = ItemInfo(itemId: 7073, name: "Broken Fang", sellPrice: 1, quality: 4)
    info[159] = ItemInfo(itemId: 159, name: "Refreshing Spring Water", sellPrice: 1, quality: 1)
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvTsv),
      fetchedAt: epochTime(), error: "")
    let body = renderRealmInventoryBody(inv, info)
    check body.find("<th>Holders</th>") < body.find("By character")

  test "summary strip counts item types and totals gold":
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvTsv),
      fetchedAt: epochTime(), error: "")
    let body = renderRealmInventoryBody(inv, initTable[int, ItemInfo]())
    check "item types" in body
    check "0g 46s 23c" in body

  test "gold tooltip lists characters richest first":
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvSharedTsv),
      fetchedAt: epochTime(), error: "")
    let body = renderRealmInventoryBody(inv, initTable[int, ItemInfo]())
    let goldTitle = "Murist 0g 46s 23c, Ashborn 0g 1s 0c"
    check goldTitle in body
    check body.find("Murist 0g 46s 23c") < body.find("Ashborn 0g 1s 0c")

  test "an item held by three characters shows all three holders":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvSharedTsv),
      fetchedAt: epochTime(), error: "")
    let body = renderRealmInventoryBody(inv, info)
    check "Murist ×12" in body
    check "Igris ×5" in body
    check "Ashborn ×3" in body

suite "isTruthyParam — Refresh force flag":
  test "1 / true / yes are yes, empty and junk are no":
    check isTruthyParam("1")
    check isTruthyParam("true")
    check isTruthyParam("yes")
    check isTruthyParam("on")
    check isTruthyParam("TRUE")
    check isTruthyParam(" Yes ")
    check not isTruthyParam("")
    check not isTruthyParam("0")
    check not isTruthyParam("no")
    check not isTruthyParam("junk")

suite "itemAbbrev — cell faces":
  test "initials of significant words":
    check itemAbbrev("Chipped Claw") == "CC"
    check itemAbbrev("Linen Cloth") == "LC"

  test "filler words dropped":
    check itemAbbrev("Cracked Sabre of the Wilds") == "CSW"

  test "single word uses first three letters":
    check itemAbbrev("Hearthstone") == "HEA"

  test "short words uppercase the whole word":
    check itemAbbrev("Ore") == "ORE"
    check itemAbbrev("Xy") == "XY"

  test "punctuation is a word break":
    check itemAbbrev("Ash'ka Blade") == "AKB"

  test "possessive crumbs are dropped, not counted as a word":
    check itemAbbrev("Advisor's Ring") == "AR"
    check itemAbbrev("Hotshot Pilot's Gloves") == "HPG"
    # A one-letter name is all we have, so it survives.
    check itemAbbrev("X") == "X"

  test "five or more words cap at four chars":
    check itemAbbrev("One Two Three Four Five") == "OTTF"

  test "all-filler name keeps the original words":
    check itemAbbrev("The Of") == "TO"

  test "empty and punctuation-only yield a question mark":
    check itemAbbrev("") == "?"
    check itemAbbrev("---") == "?"

suite "renderRealmInvGrid — the army's bag":
  test "one cell per item, quality class and abbreviation present":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    info[7073] = ItemInfo(itemId: 7073, name: "Broken Fang", sellPrice: 1, quality: 4)
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvSharedTsv))
    let html = renderRealmInvGrid(realmInvItems(inv), info)
    check html.count("inv-cell") == 2
    check "q4" in html
    check "q1" in html
    check "LC" in html
    check "BF" in html

  test "count badge shows the realm total only when total > 1":
    var info = initTable[int, ItemInfo]()
    info[1] = ItemInfo(itemId: 1, name: "Solo Thing", sellPrice: 0, quality: 1)
    info[2] = ItemInfo(itemId: 2, name: "Many Things", sellPrice: 0, quality: 1)
    let html = renderRealmInvGrid(@[
      RealmInvItem(itemId: 1, total: 1, stacks: 1,
        holders: @[RealmInvHolder(name: "Igris", count: 1)]),
      RealmInvItem(itemId: 2, total: 7, stacks: 2,
        holders: @[RealmInvHolder(name: "Igris", count: 7)])
    ], info)
    check """class="cell-count"""" in html
    check """class="cell-count">7</span>""" in html
    check html.count("cell-count") == 1
    check """class="cell-count">1</span>""" notin html

  test "tooltip carries name, id, total, stacks and holders richest first":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    let inv = RealmInventory(characters: parseRealmInventoryTsv(RealmInvSharedTsv))
    let html = renderRealmInvGrid(realmInvItems(inv), info)
    check "Linen Cloth" in html
    check "id 2589" in html
    check "20 total · 4 stacks" in html
    check "Murist ×12, Igris ×5, Ashborn ×3" in html

  test "injection probe escapes holder names and item names":
    var info = initTable[int, ItemInfo]()
    info[1] = ItemInfo(
      itemId: 1, name: "<img src=x onerror=alert(1)>", sellPrice: 0, quality: 1)
    info[2] = ItemInfo(itemId: 2, name: "Safe Cloth", sellPrice: 0, quality: 1)
    let html = renderRealmInvGrid(@[
      RealmInvItem(
        itemId: 1, total: 2, stacks: 1,
        holders: @[RealmInvHolder(name: "Igris", count: 2)]),
      RealmInvItem(
        itemId: 2, total: 3, stacks: 1,
        holders: @[RealmInvHolder(name: "<script>alert(1)</script>", count: 3)])
    ], info)
    check "&lt;script&gt;" in html
    check "<script>" notin html
    check "&lt;img" in html
    check "<img src=x onerror=alert" notin html
    var pos = 0
    while true:
      let t = html.find("title=\"", pos)
      if t < 0:
        break
      let start = t + 7
      let stop = html.find("\"", start)
      check stop >= 0
      let content = html[start ..< stop]
      check "<" notin content
      check "\"" notin content
      pos = stop + 1

  test "unknown item (negative-cache) uses raw id, common class, Item# tip":
    var info = initTable[int, ItemInfo]()
    info[4242] = ItemInfo(itemId: 4242, name: "", sellPrice: 0, quality: 0)
    let html = renderRealmInvGrid(@[
      RealmInvItem(itemId: 4242, total: 3, stacks: 1,
        holders: @[RealmInvHolder(name: "Igris", count: 3)])
    ], info)
    check """<span class="cell-face">4242</span>""" in html
    check "q1" in html
    check "q0" notin html
    check "Item#4242" in html

  test "a holderless row says so instead of trailing an empty tooltip line":
    var info = initTable[int, ItemInfo]()
    info[5] = ItemInfo(itemId: 5, name: "Orphan Gem", sellPrice: 0, quality: 3)
    let html = renderRealmInvGrid(@[
      RealmInvItem(itemId: 5, total: 2, stacks: 1, holders: @[])
    ], info)
    check """<span class="tip-line">no holders</span>""" in html
    check "stacks — no holders" in html

  test "empty pool says so":
    let html = renderRealmInvGrid(@[], initTable[int, ItemInfo]())
    check "The army is carrying nothing." in html

  test "grid order matches sortRealmInvItems (epic before a bigger common pile)":
    var info = initTable[int, ItemInfo]()
    info[1] = ItemInfo(itemId: 1, name: "Tiny Epic", sellPrice: 0, quality: 4)
    info[2] = ItemInfo(itemId: 2, name: "Huge Common", sellPrice: 0, quality: 1)
    let html = renderRealmInvGrid(@[
      RealmInvItem(itemId: 2, total: 99, stacks: 5),
      RealmInvItem(itemId: 1, total: 1, stacks: 1)
    ], info)
    check html.find("TE") < html.find("HC")
    check html.find("q4") < html.find("q1")

suite "realmInventoryToJson — items and characters":
  test "top level carries the aggregated items array":
    var info = initTable[int, ItemInfo]()
    info[2589] = ItemInfo(itemId: 2589, name: "Linen Cloth", sellPrice: 13, quality: 1)
    info[7073] = ItemInfo(itemId: 7073, name: "Broken Fang", sellPrice: 1, quality: 4)
    let inv = RealmInventory(
      characters: parseRealmInventoryTsv(RealmInvSharedTsv),
      fetchedAt: epochTime(), error: "")
    let j = realmInventoryToJson(inv, info)
    check j["item_type_count"].getInt == 2
    check j["items"].len == 2
    check j["items"][0].hasKey("item_id")
    check j["items"][0].hasKey("total")
    check j["items"][0].hasKey("stacks")
    check j["items"][0].hasKey("holders")
    check j["items"][0].hasKey("name")
    check j["items"][0].hasKey("quality")
    var linen: JsonNode
    for it in j["items"]:
      if it["item_id"].getInt == 2589:
        linen = it
    check linen["total"].getInt == 20
    check linen["stacks"].getInt == 4
    check linen["holders"].len == 3
    check linen["holders"][0]["name"].getStr == "Murist"
    check linen["holders"][0]["count"].getInt == 12
    check j.hasKey("characters")
    check j["character_count"].getInt == 3
    check j["characters"][0].hasKey("guid")
    check j["characters"][0].hasKey("name")
    check j["characters"][0].hasKey("items")
    check j["characters"][0].hasKey("money_copper")
    check j.hasKey("item_total")
    check j.hasKey("money_copper_total")
    check j.hasKey("age_sec")
    check j.hasKey("error")

suite "renderRealmInvCell — real icons":
  test "an id with a PNG on disk renders the image face":
    var info = initTable[int, ItemInfo]()
    info[6948] = ItemInfo(name: "Hearthstone", quality: 1)
    let it = RealmInvItem(itemId: 6948, total: 1, stacks: 1)
    var icons = initHashSet[int]()
    icons.incl(6948)
    let html = renderRealmInvCell(it, info, icons)
    check "src=\"/icons/item_6948.png\"" in html
    check "cell-icon" in html
    check "<span class=\"cell-face\"" notin html
  test "an id without a PNG keeps the abbreviation face":
    var info = initTable[int, ItemInfo]()
    info[6948] = ItemInfo(name: "Hearthstone", quality: 1)
    let it = RealmInvItem(itemId: 6948, total: 1, stacks: 1)
    let html = renderRealmInvCell(it, info, initHashSet[int]())
    check "cell-face" in html
    check "/icons/" notin html

suite "iconIdsOnDisk — icons generated or removed while serving":
  test "missing -> present -> removed follows the directory":
    # Synthetic fixtures only: the cache keys on file names, not image data.
    let dir = getTempDir() / ("sa_icon_cache_" & $getCurrentProcessId())
    removeDir(dir)
    defer: removeDir(dir)
    let info = {4306: ItemInfo(name: "Silk Cloth", quality: 1)}.toTable
    let silk = RealmInvItem(itemId: 4306, total: 1, stacks: 1)
    check iconIdsOnDisk(dir).len == 0
    createDir(dir)
    check iconIdsOnDisk(dir).len == 0
    check "cell-face" in renderRealmInvCell(silk, info, iconIdsOnDisk(dir))

    writeFile(dir / "item_4306.png", "\x89PNG\r\n\x1a\n")
    writeFile(dir / "item_bogus.png", "")
    writeFile(dir / "manifest.tsv", "")
    check iconIdsOnDisk(dir) == [4306].toHashSet
    let shown = renderRealmInvCell(silk, info, iconIdsOnDisk(dir))
    check "/icons/item_4306.png" in shown
    check "cell-face" notin shown

    removeFile(dir / "item_4306.png")
    check iconIdsOnDisk(dir).len == 0
    check "cell-face" in renderRealmInvCell(silk, info, iconIdsOnDisk(dir))

    removeDir(dir)
    check iconIdsOnDisk(dir).len == 0

  test "a settled directory is served from cache until its mtime moves":
    let dir = getTempDir() / ("sa_icon_settle_" & $getCurrentProcessId())
    removeDir(dir)
    defer: removeDir(dir)
    createDir(dir)
    writeFile(dir / "item_2589.png", "")
    let old = getTime() - initDuration(hours = 1)
    setLastModificationTime(dir, old)
    check iconIdsOnDisk(dir) == [2589].toHashSet
    # Same stamp, settled: the cached set is returned without a rescan.
    writeFile(dir / "item_4306.png", "")
    setLastModificationTime(dir, old)
    check iconIdsOnDisk(dir) == [2589].toHashSet
    # A removal moves the directory mtime, which forces the rescan.
    removeFile(dir / "item_2589.png")
    check iconIdsOnDisk(dir) == [4306].toHashSet
