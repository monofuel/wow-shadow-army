## Unit tests for the inventory chat bus (ticket 0052) — System side.
## Grammar is the addon's `ShadowArmy.invModel` (r49):
##   <SA> inv  <seq>/<total> <id>:<count>,…         full snapshot, REPLACE
##   <SA> invd <seq>/<total> +<id>:<count>,-<id>,…  delta, PATCH (absolute)
## Run: nim r --hints:off --warnings:off system/tests/test_inventory.nim
## No network, no docker, no realm — pure functions on fixture strings.

import
  std/[options, strutils, tables, times, unittest],
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
