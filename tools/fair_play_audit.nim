## Fair-play milestone audit — pure diffs + append-only JSONL.
##
## Answers "did they actually do the quest?" by recording quest-log deltas,
## objective item counts, settled accept/turn_in/loot/cast, and admin markers.
## Not a full frame dump: only state changes that matter for proof.

import std/[json, os, sets, strformat, strutils, tables, times]

const
  ## Rattlecage Skull for quest 1470 (Piercing the Veil).
  ItemRattlecageSkull* = 6281
  ## Summon Imp spell id (quest 1470 reward).
  SpellSummonImp* = 688
  DefaultAuditPath* = "local_data/audit/fair-play.jsonl"

type
  QuestActiveSnap* = object
    complete*: bool
    itemCount*: int ## quest-item progress when known (e.g. skulls for 1470)

  FrameSnapshot* = object
    character*: string
    slot*: int
    questLog*: HashSet[int]
    completed*: HashSet[int]
    rewarded*: HashSet[int]
    ## item_id → count (tracked quest items only for now)
    questItems*: Table[int, int]
    knownSpells*: HashSet[int]
    ## Dedup key for previous_transition settlements
    lastSettledKey*: string

  AuditState* = object
    path*: string
    slot*: int
    tool*: string
    sessionOpened*: bool
    prev*: FrameSnapshot
    initialized*: bool

  AuditEvent* = object
    event*: string
    fields*: JsonNode ## extra fields beyond common header

proc isoNow*(): string =
  ## UTC-ish ISO without external deps: epoch + local wall clock label.
  let t = now().utc
  result = t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc ensureAuditDir*(path: string) =
  let dir = parentDir(path)
  if dir.len > 0:
    createDir(dir)

proc appendAuditLine*(path: string; line: string) =
  ## Append one JSON line. Creates parent dirs. Best-effort (no raise on write).
  if path.len == 0:
    return
  try:
    ensureAuditDir(path)
    let f = open(path, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except:
    discard

proc eventJson*(
    state: AuditState;
    character: string;
    event: string;
    extra: JsonNode = nil
): JsonNode =
  result = %*{
    "ts": isoNow(),
    "slot": state.slot,
    "character": character,
    "tool": state.tool,
    "event": event
  }
  if not extra.isNil and extra.kind == JObject:
    for k, v in extra.pairs:
      if k notin result:
        result[k] = v

proc emit*(state: AuditState; character: string; event: string;
    extra: JsonNode = nil) =
  let node = eventJson(state, character, event, extra)
  appendAuditLine(state.path, $node)

proc parseQuestIdSet(n: JsonNode): HashSet[int] =
  result = initHashSet[int]()
  if n.isNil:
    return
  if n.kind == JArray:
    for x in n:
      case x.kind
      of JInt:
        result.incl x.getInt
      of JFloat:
        result.incl x.getFloat.int
      of JString:
        try: result.incl parseInt(x.getStr)
        except: discard
      of JObject:
        # accepted_quests rows: {quest_id: N}
        let q = x{"quest_id"}
        if not q.isNil:
          case q.kind
          of JInt: result.incl q.getInt
          of JFloat: result.incl q.getFloat.int
          else: discard
      else: discard

proc jintNode(n: JsonNode; def = 0): int =
  if n.isNil: return def
  case n.kind
  of JInt: n.getInt
  of JFloat: n.getFloat.int
  of JString:
    try: parseInt(n.getStr)
    except: def
  else: def

proc jstrNode(n: JsonNode; def = ""): string =
  if n.isNil: return def
  case n.kind
  of JString: n.getStr
  of JInt: $n.getInt
  else: def

proc extractSnapshot*(frame: JsonNode; slot: int): FrameSnapshot =
  ## Pull quest / item / spell bits from a nim_control environment frame.
  result = FrameSnapshot(slot: slot)
  result.questLog = initHashSet[int]()
  result.completed = initHashSet[int]()
  result.rewarded = initHashSet[int]()
  result.questItems = initTable[int, int]()
  result.knownSpells = initHashSet[int]()
  if frame.isNil:
    return
  let obs = frame{"observation"}
  if obs.isNil:
    return
  result.character = jstrNode(obs{"name"})
  # Prefer accepted_quests / quest_log_quest_ids
  let accepted = obs{"accepted_quests"}
  let qLog = obs{"quest_log_quest_ids"}
  if not accepted.isNil and accepted.kind == JArray and accepted.len > 0:
    result.questLog = parseQuestIdSet(accepted)
  else:
    result.questLog = parseQuestIdSet(qLog)
  result.completed = parseQuestIdSet(obs{"completed_quest_ids"})
  result.rewarded = parseQuestIdSet(obs{"rewarded_quest_ids"})
  let inv = obs{"inventory_items"}
  if not inv.isNil and inv.kind == JArray:
    for it in inv:
      let iid = jintNode(it{"item_id"})
      if iid == ItemRattlecageSkull:
        result.questItems[iid] = jintNode(it{"count"})
  let known = obs{"known_spells"}
  if not known.isNil and known.kind == JArray:
    for sid in known:
      result.knownSpells.incl jintNode(sid)
  # Settlement dedup from previous_transition
  let pt = frame{"previous_transition"}
  if not pt.isNil and jstrNode(pt{"type"}) == "action_settled":
    let kind = jstrNode(pt{"action_kind"})
    if kind.len == 0:
      let act = pt{"action"}
      if not act.isNil:
        result.lastSettledKey =
          jstrNode(act{"kind"}) & "|" & $jintNode(pt{"settled_tick"}) & "|" &
            jstrNode(pt{"message"})
    else:
      result.lastSettledKey =
        kind & "|" & $jintNode(pt{"settled_tick"}) & "|" & jstrNode(pt{"message"})

const MilestoneKinds = [
  "accept_quest", "turn_in_quest", "loot", "cast", "interact"
]

proc isMilestoneKind*(kind: string): bool =
  let k = kind.toLowerAscii
  for m in MilestoneKinds:
    if k == m: return true
  false

proc settlementExtra*(pt: JsonNode): JsonNode =
  ## Build extra fields from an action_settled previous_transition node.
  result = newJObject()
  if pt.isNil: return
  var kind = jstrNode(pt{"action_kind"})
  let act = pt{"action"}
  if kind.len == 0 and not act.isNil:
    kind = jstrNode(act{"kind"})
  result["action_kind"] = %kind
  result["success"] = %(
    if pt{"success"}.isNil: false else:
      case pt{"success"}.kind
      of JBool: pt{"success"}.getBool
      of JInt: pt{"success"}.getInt != 0
      else: false
  )
  result["message"] = %jstrNode(pt{"message"})
  result["reason_code"] = %jstrNode(pt{"reason_code"})
  result["settled_tick"] = %jintNode(pt{"settled_tick"})
  if not act.isNil:
    let q = jintNode(act{"quest"})
    if q != 0:
      result["quest_factor"] = %q
    let spell = jintNode(act{"spell"})
    if spell != 0:
      result["spell_factor"] = %spell
    let target = jintNode(act{"target"})
    if target != 0:
      result["target"] = %target

proc diffSnapshots*(
    prev: FrameSnapshot;
    cur: FrameSnapshot;
    firstFrame: bool
): seq[AuditEvent] =
  ## Pure: quest enter/leave, objective counts, spell learn, rewarded set.
  result = @[]
  if firstFrame:
    var logArr = newJArray()
    for q in cur.questLog:
      logArr.add %q
    var rewArr = newJArray()
    for q in cur.rewarded:
      rewArr.add %q
    var spellArr = newJArray()
    for s in cur.knownSpells:
      if s == SpellSummonImp:
        spellArr.add %s
    result.add AuditEvent(
      event: "session_open",
      fields: %*{
        "quest_log": logArr,
        "rewarded_quest_ids": rewArr,
        "has_summon_imp": SpellSummonImp in cur.knownSpells,
        "skull_count": cur.questItems.getOrDefault(ItemRattlecageSkull, 0)
      }
    )
    # Still emit current state as baseline enters for easier greps mid-session.
    for q in cur.questLog:
      result.add AuditEvent(
        event: "quest_log_present",
        fields: %*{"quest_id": q, "note": "already_in_log_at_session_open"}
      )
    return

  for q in cur.questLog:
    if q notin prev.questLog:
      result.add AuditEvent(
        event: "quest_log_enter",
        fields: %*{"quest_id": q}
      )
  for q in prev.questLog:
    if q notin cur.questLog:
      let wasRewarded = q in cur.rewarded and q notin prev.rewarded
      result.add AuditEvent(
        event: "quest_log_leave",
        fields: %*{
          "quest_id": q,
          "likely_turn_in": wasRewarded or q in cur.rewarded
        }
      )

  for q in cur.completed:
    if q notin prev.completed:
      result.add AuditEvent(
        event: "quest_objectives_complete",
        fields: %*{"quest_id": q}
      )

  for q in cur.rewarded:
    if q notin prev.rewarded:
      result.add AuditEvent(
        event: "quest_rewarded",
        fields: %*{"quest_id": q}
      )

  # Skull / tracked item counts
  for iid, count in cur.questItems.pairs:
    let prevC = prev.questItems.getOrDefault(iid, 0)
    if count != prevC:
      var fields = %*{
        "item_id": iid,
        "count": count,
        "prev_count": prevC
      }
      if iid == ItemRattlecageSkull:
        fields["quest_id"] = %1470
        fields["label"] = %"rattlecage_skull"
      result.add AuditEvent(event: "objective_item", fields: fields)

  for sid in cur.knownSpells:
    if sid notin prev.knownSpells:
      var fields = %*{"spell_id": sid}
      if sid == SpellSummonImp:
        fields["label"] = %"summon_imp"
      result.add AuditEvent(event: "spell_learned", fields: fields)

proc processFrame*(
    state: var AuditState;
    frame: JsonNode
): seq[string] =
  ## Diff frame against prior state; append audit lines; return emitted JSON lines.
  result = @[]
  if state.path.len == 0:
    return
  let cur = extractSnapshot(frame, state.slot)
  let character = if cur.character.len > 0: cur.character else: &"slot{state.slot}"

  let first = not state.initialized
  let events = diffSnapshots(state.prev, cur, first)
  for ev in events:
    let node = eventJson(state, character, ev.event, ev.fields)
    let line = $node
    appendAuditLine(state.path, line)
    result.add line

  # Settled milestone actions (deduped)
  let pt = if frame.isNil: nil else: frame{"previous_transition"}
  if not pt.isNil and jstrNode(pt{"type"}) == "action_settled":
    var kind = jstrNode(pt{"action_kind"})
    let act = pt{"action"}
    if kind.len == 0 and not act.isNil:
      kind = jstrNode(act{"kind"})
    if isMilestoneKind(kind) and cur.lastSettledKey.len > 0 and
        cur.lastSettledKey != state.prev.lastSettledKey:
      let extra = settlementExtra(pt)
      let node = eventJson(state, character, "action_settled", extra)
      let line = $node
      appendAuditLine(state.path, line)
      result.add line

  state.prev = cur
  state.initialized = true

proc recordSelect*(
    state: AuditState;
    character: string;
    actionKind: string;
    intent: JsonNode = nil;
    success: bool = true
) =
  ## Policy selected a milestone action (before settle). Complements action_settled.
  if state.path.len == 0: return
  if not isMilestoneKind(actionKind) and actionKind != "promote_party":
    return
  var extra = %*{
    "action_kind": actionKind,
    "select_ok": success
  }
  if not intent.isNil and intent.kind == JObject:
    let reason = intent{"reason"}
    if not reason.isNil:
      extra["intent_reason"] = reason
    let qid = intent{"quest_id"}
    if not qid.isNil:
      extra["quest_id"] = qid
    let unit = intent{"unit_id"}
    if not unit.isNil:
      extra["unit_id"] = unit
  emit(state, character, "action_select", extra)

proc recordAdmin*(
    path: string;
    kind: string;
    character: string = "";
    detail: string = "";
    slot: int = -1
) =
  ## System / SOAP / operator setup markers (not policy).
  if path.len == 0: return
  var node = %*{
    "ts": isoNow(),
    "event": "admin",
    "kind": kind,
    "source": "admin_setup"
  }
  if character.len > 0:
    node["character"] = %character
  if detail.len > 0:
    node["detail"] = %detail
  if slot >= 0:
    node["slot"] = %slot
  appendAuditLine(path, $node)
