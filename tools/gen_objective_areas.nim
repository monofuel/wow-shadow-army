## Generates the bot-side objective-area table from the addon's generated
## QuestData.lua and the client's WorldMapArea.dbc.
##
## QuestData.lua already carries, per quest objective, its kind, the creature
## names that drop an item, and clustered spots in zone-normalized percent.
## The bot lives in world yards, so each spot is mapped back through the
## owning WorldMapArea box:
##
##   worldY = locLeft - mapX/100 * (locLeft - locRight)
##   worldX = locTop  - mapY/100 * (locTop  - locBottom)
##
## Output shape (Lua, required as "data.bot_objective_areas"):
##
##   return {
##   [questId] = {level = L, objectives = {
##     {kind = "item", from = {"Name", ...}, spots = {{map,x,y}, ...}},
##     ...}},
##   }
##
## Objective order is QuestData's order. Spots in zones without a
## WorldMapArea box (instances) are dropped; a quest with no surviving spot
## is omitted. Deterministic: sorted by quest id, no timestamps.
##
## Typed objective identities (opt-in, --objective-ids=PATH)
## ---------------------------------------------------------
## QuestData.lua does not carry the quest_template ids its objectives came
## from, and live credit rows do not arrive in definition order, so a quest
## with two objectives of one class cannot be paired from the guide alone.
## --objective-ids reads the quest_template requirement columns as a
## tab-separated file with a header row (column order free; each name once,
## every row exactly as many cells as the header):
##
##   entry patch SrcItemId ReqCreatureOrGOId1..4 ReqCreatureOrGOCount1..4
##   ReqItemId1..4 ReqItemCount1..4
##
## Rows with patch > --max-patch (default 10 == WowPatch 1.12) are ignored and
## each entry collapses to its highest remaining patch, the same rule the
## QuestData producer applies. Two rows of one (entry, patch) that disagree
## mark the entry conflicting.
##
## The producer emits, in this order and at most once per slot: one row per
## nonzero ReqCreatureOrGOId1..4 (kind "mob" when > 0, "object" when < 0),
## then one row per nonzero ReqItemId1..4 that is not SrcItemId (kind "item"
## or "object"). Slots without sources or spots are dropped. So a quest's
## rows correspond one-to-one, in order, to its eligible slots exactly when
## the row count equals the eligible slot count; the per-row kind and count
## are then checked against the slot. Only then is each objective given its
## typed id: `entry` (creature), `object_entry` (game object) or `item_id`.
## Anything else -- no definition, a dropped slot, a kind or count mismatch,
## a repeated id, a conflicting definition -- leaves the WHOLE quest without
## ids, which keeps the consumer's conservative class-only pairing. Names and
## live row order are never used to assign an id.
##
## Without --objective-ids the output is byte-identical to the legacy tool.
##
## Usage: gen_objective_areas --quest-data=PATH --dbc=PATH --out=PATH
##          [--objective-ids=PATH [--max-patch=N]]

import std/[parseopt, strutils, strformat, tables, algorithm, streams]

type
  Box* = object
    map: int
    left, right, top, bottom: float32
  Spot = object
    zone: int
    x, y: float
  Objective* = object
    kind*: string
    count*: int             ## -1 when the QuestData line has no count
    fromNames*: seq[string]
    spots*: seq[Spot]
    idField*: string        ## "entry", "object_entry", "item_id" or ""
    id*: int
  Quest* = object
    level*: int
    objectives*: seq[Objective]
  ObjectiveDef* = object
    patch*: int
    srcItem*: int
    cgIds*, cgCounts*, itemIds*, itemCounts*: array[4, int]
    conflict*: bool
  IdStats* = object
    defs*, attributed*, noDefinition*, dropped*, mismatch*, duplicate*,
      conflict*: int

const IdColumns = block:
  var cols = @["entry", "patch", "SrcItemId"]
  for prefix in ["ReqCreatureOrGOId", "ReqCreatureOrGOCount", "ReqItemId",
                 "ReqItemCount"]:
    for i in 1 .. 4: cols.add prefix & $i
  cols

proc readBoxes*(path: string): Table[int, Box] =
  ## Reads WorldMapArea.dbc: areaId -> (mapId, locLeft/Right/Top/Bottom).
  var s = newFileStream(path, fmRead)
  if s.isNil: quit("cannot open " & path)
  defer: s.close()
  if s.readStr(4) != "WDBC": quit("not a WDBC file: " & path)
  let records = s.readInt32()
  let fields = s.readInt32()
  let recordSize = s.readInt32()
  discard s.readInt32()
  if fields != 8 or recordSize != 32: quit("unexpected WorldMapArea layout")
  for i in 0 ..< records:
    discard s.readInt32()
    let map = s.readInt32()
    let area = s.readInt32()
    discard s.readInt32()
    let b = Box(map: map, left: s.readFloat32(), right: s.readFloat32(),
                top: s.readFloat32(), bottom: s.readFloat32())
    if area != 0 and not result.hasKey(area):
      result[area] = b

proc between(s, a, b: string, start = 0): tuple[val: string, next: int] =
  ## Returns the text between the first `a` at/after `start` and the next `b`.
  let i = s.find(a, start)
  if i < 0: return ("", -1)
  let j = s.find(b, i + a.len)
  if j < 0: return ("", -1)
  (s[i + a.len ..< j], j + b.len)

proc parseQuests*(path: string): Table[int, Quest] =
  ## Line-oriented reader for the generator-owned QuestData.lua layout.
  var current = -1
  for line in lines(path):
    if line.startsWith("id = ") and ", level = " in line:
      let id = parseInt(line.between("id = ", ",").val)
      let level = parseInt(line.between(", level = ", ",").val)
      if not result.hasKey(id):
        current = id
        result[id] = Quest(level: level)
      else:
        current = -1
    elif current >= 0 and line.startsWith("{ label = ") and ", kind = \"" in line:
      let kindPart = line.between(", kind = \"", "\"")
      var o = Objective(kind: kindPart.val, count: -1)
      # count follows kind in the producer layout; searching from there keeps
      # a label containing ", count = " from being read as the count.
      let countPart =
        if kindPart.next < 0: kindPart
        else: line.between(", count = ", ",", kindPart.next)
      if countPart.next > 0:
        try: o.count = parseInt(countPart.val.strip())
        except ValueError: o.count = -1
      let fromPart = line.between("from = { ", " }")
      if fromPart.next > 0:
        var pos = 0
        while true:
          let n = fromPart.val.between("\"", "\"", pos)
          if n.next < 0: break
          o.fromNames.add n.val
          pos = n.next
      var pos = 0
      while true:
        let sp = line.between("{zone = ", "}", pos)
        if sp.next < 0: break
        let zone = parseInt(sp.val.split(",")[0])
        let x = parseFloat(sp.val.between("x = ", ",").val)
        let y = parseFloat((sp.val & "|").between("y = ", "|").val)
        o.spots.add Spot(zone: zone, x: x, y: y)
        pos = sp.next
      result[current].objectives.add o

proc sameDef(a, b: ObjectiveDef): bool =
  a.srcItem == b.srcItem and a.cgIds == b.cgIds and a.cgCounts == b.cgCounts and
    a.itemIds == b.itemIds and a.itemCounts == b.itemCounts

proc parseObjectiveDefs*(text: string, maxPatch: int): Table[int, ObjectiveDef] =
  ## quest_template requirement columns (tab-separated, header row) ->
  ## entry -> definition at its highest patch <= maxPatch. Malformed input
  ## is fatal rather than partially read: a missing or duplicate (after
  ## trimming) header column, any row whose cell count differs from the
  ## header's (extra cells included, even on an ignored patch), a
  ## non-integer cell, or no header at all.
  var header: Table[string, int]
  var lineNo = 0
  for raw in text.splitLines():
    inc lineNo
    let line = raw.strip(leading = false, chars = {'\r'})
    if line.len == 0: continue
    let cells = line.split('\t')
    if header.len == 0:
      for i, name in cells:
        let col = name.strip()
        if header.hasKey(col):
          raise newException(ValueError, "objective ids: duplicate column " & col)
        header[col] = i
      for col in IdColumns:
        if not header.hasKey(col):
          raise newException(ValueError, "objective ids: missing column " & col)
      continue
    if cells.len != header.len:
      raise newException(ValueError,
        &"objective ids line {lineNo}: {cells.len} cells, header has {header.len}")
    proc cell(col: string): int =
      let i = header[col]
      if i >= cells.len:
        raise newException(ValueError, &"objective ids line {lineNo}: short row")
      try: parseInt(cells[i].strip())
      except ValueError:
        raise newException(ValueError,
          &"objective ids line {lineNo}: {col} is not an integer")
    let entry = cell("entry")
    var d = ObjectiveDef(patch: cell("patch"), srcItem: cell("SrcItemId"))
    if d.patch > maxPatch: continue
    for i in 0 .. 3:
      d.cgIds[i] = cell("ReqCreatureOrGOId" & $(i + 1))
      d.cgCounts[i] = cell("ReqCreatureOrGOCount" & $(i + 1))
      d.itemIds[i] = cell("ReqItemId" & $(i + 1))
      d.itemCounts[i] = cell("ReqItemCount" & $(i + 1))
    if not result.hasKey(entry) or d.patch > result[entry].patch:
      result[entry] = d
    elif d.patch == result[entry].patch and not sameDef(d, result[entry]):
      result[entry].conflict = true
  if header.len == 0:
    raise newException(ValueError, "objective ids: empty input")

proc attributeIds*(q: var Quest, d: ObjectiveDef): string =
  ## Gives every objective of `q` its typed id from `d`, or none of them.
  ## Returns "" on success, else the refusal reason.
  if d.conflict: return "conflict"
  type Slot = tuple[field: string, id, count: int, kinds: seq[string]]
  var slots: seq[Slot]
  for i in 0 .. 3:
    let raw = d.cgIds[i]
    if raw > 0:
      slots.add ("entry", raw, max(d.cgCounts[i], 1), @["mob"])
    elif raw < 0:
      slots.add ("object_entry", -raw, max(d.cgCounts[i], 1), @["object"])
  for i in 0 .. 3:
    let item = d.itemIds[i]
    if item != 0 and item != d.srcItem:
      slots.add ("item_id", item, max(d.itemCounts[i], 1), @["item", "object"])
  if slots.len != q.objectives.len: return "dropped"
  for a in 0 ..< slots.len:
    if slots[a].id <= 0: return "mismatch"
    for b in a + 1 ..< slots.len:
      if slots[a].field == slots[b].field and slots[a].id == slots[b].id:
        return "duplicate"
  for i, o in q.objectives:
    if o.kind notin slots[i].kinds or o.count != slots[i].count:
      return "mismatch"
  for i in 0 ..< slots.len:
    q.objectives[i].idField = slots[i].field
    q.objectives[i].id = slots[i].id
  ""

proc applyIds*(quests: var Table[int, Quest],
               defs: Table[int, ObjectiveDef]): IdStats =
  ## Attributes ids quest by quest; counts outcomes for the run summary.
  result.defs = defs.len
  for id, q in quests.mpairs:
    if not defs.hasKey(id):
      inc result.noDefinition
      continue
    case attributeIds(q, defs[id])
    of "": inc result.attributed
    of "dropped": inc result.dropped
    of "duplicate": inc result.duplicate
    of "conflict": inc result.conflict
    else: inc result.mismatch

proc idSummary*(stats: IdStats, questCount, maxPatch: int): string =
  ## The provenance line the CLI writes after attributing ids.
  &"objective ids: quest_template requirement columns, patch <= {maxPatch}; " &
    &"attributed {stats.attributed}/{questCount}, refused dropped " &
    &"{stats.dropped} mismatch {stats.mismatch} duplicate {stats.duplicate} " &
    &"conflict {stats.conflict}, no definition {stats.noDefinition}"

proc luaStr(s: string): string =
  ## Quotes a string as a Lua literal.
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc render*(quests: Table[int, Quest], boxes: Table[int, Box],
             idHeader = ""): tuple[body: string, emitted, dropped: int] =
  ## Emits the Lua table. `idHeader` != "" adds one provenance comment line.
  var ids: seq[int]
  for id in quests.keys: ids.add id
  ids.sort()
  var body = newStringOfCap(1 shl 20)
  body.add "-- generated by gen_objective_areas; do not edit by hand\n"
  body.add "-- source: QuestData.lua objective spots + WorldMapArea.dbc\n"
  body.add "-- spots are WORLD yards {map,x,y}; objective order = QuestData order\n"
  if idHeader != "": body.add "-- " & idHeader & "\n"
  body.add "return {\n"
  var emitted, dropped = 0
  for id in ids:
    let q = quests[id]
    var parts: seq[string]
    var any = false
    for o in q.objectives:
      var spots: seq[string]
      for s in o.spots:
        if not boxes.hasKey(s.zone):
          inc dropped
          continue
        let b = boxes[s.zone]
        let wy = b.left.float - s.x / 100.0 * (b.left.float - b.right.float)
        let wx = b.top.float - s.y / 100.0 * (b.top.float - b.bottom.float)
        spots.add &"{{{b.map},{wx:.1f},{wy:.1f}}}"
      if spots.len > 0: any = true
      var names: seq[string]
      for n in o.fromNames: names.add luaStr(n)
      let fromList = names.join(",")
      let spotList = spots.join(",")
      let ident = if o.idField != "": &"{o.idField} = {o.id}, " else: ""
      parts.add &"{{kind = {luaStr(o.kind)}, {ident}from = {{{fromList}}}, spots = {{{spotList}}}}}"
    if any:
      inc emitted
      let objList = parts.join(", ")
      body.add &"[{id}] = {{level = {q.level}, objectives = {{{objList}}}}},\n"
  body.add "}\n"
  (body, emitted, dropped)

proc main() =
  ## Command-line entry point.
  var questData, dbc, outPath, idsPath = ""
  var maxPatch = 10
  for kind, key, val in getopt():
    if kind == cmdLongOption:
      case key
      of "quest-data": questData = val
      of "dbc": dbc = val
      of "out": outPath = val
      of "objective-ids": idsPath = val
      of "max-patch": maxPatch = parseInt(val)
      else: quit("unknown option " & key)
  if questData == "" or dbc == "" or outPath == "":
    quit("usage: gen_objective_areas --quest-data=PATH --dbc=PATH --out=PATH" &
         " [--objective-ids=PATH [--max-patch=N]]")
  let boxes = readBoxes(dbc)
  var quests = parseQuests(questData)
  var idHeader = ""
  var stats: IdStats
  if idsPath != "":
    let defs =
      try: parseObjectiveDefs(readFile(idsPath), maxPatch)
      except ValueError as e: quit(e.msg)
    stats = applyIds(quests, defs)
    idHeader = idSummary(stats, quests.len, maxPatch)
  let r = render(quests, boxes, idHeader)
  writeFile(outPath, r.body)
  stderr.writeLine &"quests parsed {quests.len}, emitted {r.emitted}, spots without box {r.dropped}"
  if idsPath != "":
    stderr.writeLine idHeader & &", definitions read {stats.defs}"

when isMainModule:
  main()
