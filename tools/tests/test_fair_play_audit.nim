## Pure unit tests for fair_play_audit (no network, no sockets).
## Run: nim r --hints:off --warnings:off tools/tests/test_fair_play_audit.nim

import std/[json, os, sets, strutils, tables]
import ../fair_play_audit

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

# --- isMilestoneKind ---
check(isMilestoneKind("accept_quest"), "accept is milestone")
check(isMilestoneKind("turn_in_quest"), "turn_in is milestone")
check(isMilestoneKind("loot"), "loot is milestone")
check(isMilestoneKind("cast"), "cast is milestone")
check(not isMilestoneKind("move"), "move not milestone")

# --- diff: first frame session_open ---
var empty = FrameSnapshot()
empty.questLog = initHashSet[int]()
empty.completed = initHashSet[int]()
empty.rewarded = initHashSet[int]()
empty.questItems = initTable[int, int]()
empty.knownSpells = initHashSet[int]()

var openSnap = FrameSnapshot()
openSnap.character = "Shadowfel"
openSnap.questLog = toHashSet([1470])
openSnap.completed = initHashSet[int]()
openSnap.rewarded = initHashSet[int]()
openSnap.questItems = {ItemRattlecageSkull: 2}.toTable
openSnap.knownSpells = initHashSet[int]()

let openEvents = diffSnapshots(empty, openSnap, firstFrame = true)
check(openEvents.len >= 2, "session_open + quest_log_present")
check(openEvents[0].event == "session_open", "first is session_open")
check(openEvents[0].fields["skull_count"].getInt == 2, "session skull count")
var foundPresent = false
for ev in openEvents:
  if ev.event == "quest_log_present" and ev.fields["quest_id"].getInt == 1470:
    foundPresent = true
check(foundPresent, "1470 present at open")

# --- diff: accept enter ---
var prev = openSnap
var cur = openSnap
cur.questLog = toHashSet([1470, 367])
let enterEvents = diffSnapshots(prev, cur, firstFrame = false)
check(enterEvents.len == 1 and enterEvents[0].event == "quest_log_enter",
  "quest enter")
check(enterEvents[0].fields["quest_id"].getInt == 367, "entered 367")

# --- skull progress ---
prev = cur
cur.questItems = {ItemRattlecageSkull: 3}.toTable
let skullEvents = diffSnapshots(prev, cur, firstFrame = false)
check(skullEvents.len == 1 and skullEvents[0].event == "objective_item",
  "skull objective")
check(skullEvents[0].fields["count"].getInt == 3, "skull count 3")
check(skullEvents[0].fields["quest_id"].getInt == 1470, "skull quest id")

# --- leave + rewarded (turn-in path) ---
prev = cur
cur.questLog = toHashSet([367])
cur.rewarded = toHashSet([1470])
cur.knownSpells = toHashSet([SpellSummonImp])
let turnEvents = diffSnapshots(prev, cur, firstFrame = false)
var leave, rewarded, spell: bool
for ev in turnEvents:
  if ev.event == "quest_log_leave" and ev.fields["quest_id"].getInt == 1470:
    leave = true
    check(ev.fields["likely_turn_in"].getBool, "leave likely turn-in")
  if ev.event == "quest_rewarded" and ev.fields["quest_id"].getInt == 1470:
    rewarded = true
  if ev.event == "spell_learned" and ev.fields["spell_id"].getInt == 688:
    spell = true
check(leave and rewarded and spell, "turn-in bundle leave+rewarded+spell")

# --- extractSnapshot from synthetic frame ---
let frame = %*{
  "observation": {
    "name": "Igris",
    "quest_log_quest_ids": [1470],
    "accepted_quests": [],
    "completed_quest_ids": [],
    "rewarded_quest_ids": [],
    "inventory_items": [
      {"item_id": 6281, "count": 1},
      {"item_id": 4604, "count": 5}
    ],
    "known_spells": [686, 687]
  },
  "previous_transition": {
    "type": "action_settled",
    "action_kind": "loot",
    "success": true,
    "message": "looted 0xABC",
    "reason_code": "ok",
    "settled_tick": 99,
    "action": {"kind": "loot", "target": 12, "quest": 0, "spell": 0}
  }
}
let snap = extractSnapshot(frame, 3)
check(snap.character == "Igris", "extract name")
check(1470 in snap.questLog, "extract quest log")
check(snap.questItems.getOrDefault(6281) == 1, "extract skull")
check(686 in snap.knownSpells, "extract spell")
check(snap.lastSettledKey.contains("loot"), "settled key has loot")

# --- processFrame append to temp file ---
let tmp = getTempDir() / "fair-play-audit-test.jsonl"
if fileExists(tmp):
  removeFile(tmp)
var state = AuditState(path: tmp, slot: 3, tool: "warlock_imp_quest")
let lines1 = processFrame(state, frame)
check(lines1.len >= 1, "session lines emitted")
check(fileExists(tmp), "audit file created")
# Second frame: skull 2 + turn_in settled
let frame2 = %*{
  "observation": {
    "name": "Igris",
    "quest_log_quest_ids": [1470],
    "accepted_quests": [],
    "completed_quest_ids": [1470],
    "rewarded_quest_ids": [],
    "inventory_items": [{"item_id": 6281, "count": 2}],
    "known_spells": [686, 687]
  },
  "previous_transition": {
    "type": "action_settled",
    "action_kind": "turn_in_quest",
    "success": true,
    "message": "turned in quest 1470 for 190 xp",
    "reason_code": "ok",
    "settled_tick": 100,
    "action": {"kind": "turn_in_quest", "target": 5, "quest": 1, "spell": 0}
  }
}
let lines2 = processFrame(state, frame2)
var hasObj, hasSettled, hasComplete: bool
for line in lines2:
  let n = parseJson(line)
  if n["event"].getStr == "objective_item": hasObj = true
  if n["event"].getStr == "action_settled": hasSettled = true
  if n["event"].getStr == "quest_objectives_complete": hasComplete = true
check(hasObj and hasSettled and hasComplete, "obj+settled+complete")

# Same settlement key must not re-emit
let lines3 = processFrame(state, frame2)
var settledAgain = false
for line in lines3:
  if parseJson(line)["event"].getStr == "action_settled":
    settledAgain = true
check(not settledAgain, "settlement deduped")

# admin helper
recordAdmin(tmp, kind = "teleport", character = "Shadowfel", detail = "tele name Shadowfel Deathknell")
let body = readFile(tmp)
check(body.contains("\"admin\""), "admin event in file")
check(body.contains("admin_setup"), "admin_setup source")

removeFile(tmp)
echo "OK: ", passed, " checks passed"
