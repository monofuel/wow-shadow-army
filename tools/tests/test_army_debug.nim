## Unit tests for army_debug ring + snapshot + reload dry-run (no live port).
## Run: nim r --hints:off --warnings:off tools/tests/test_army_debug.nim

import std/[json, os, strutils]
import ../army_debug

template check(cond: bool, name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  echo "  [OK] ", name

echo "== army_debug =="

resetDebugStateForTest()
configureMeta("traverse", "", "Northbound", "ws", 0, getCurrentDir())

check(ringLenForTest() == 0, "ring empty after reset")
ringPushForTest("policy", "intent move:water_entry")
ringPushForTest("host", "heartbeat")
check(ringLenForTest() == 2, "ring len 2")

let st = statusJson()
check(st{"ok"}.getBool == true, "status ok")
check(st{"character"}.getStr == "Northbound", "character")
check(st{"lua"}{"entry"}.getStr == "traverse", "lua entry traverse")
check(st{"lua"}{"gen"}.getInt == 1, "lua gen starts 1")
check(st{"session"}{"slot"}.getInt == 0, "slot 0")

updateLoop(
  DebugSelf(
    x: -9000.0, y: -2500.0, z: 14.0, mapId: 1, hpPct: 100.0,
    formId: 3, formSpellId: 783, isSwimming: false, hasPos: true),
  DebugIntent(
    kind: "move", reason: "water_entry", spell: 0,
    x: -8900.0, y: -2600.0, z: 0.7, hasXy: true),
  pathYards = 100.0,
  acceptedMoves = 10,
  goalX = -6784.5, goalY = -4833.9, goalRadius = 50.0, goalDist = 2000.0,
  hasGoal = true,
  frameId = 42,
  pending = true,
  actionState = "pending"
)
let st2 = statusJson()
check(st2{"self"}{"shapeshift_form_id"}.getInt == 3, "form id 3")
check(st2{"last_intent"}{"reason"}.getStr == "water_entry", "intent reason")
check(st2{"progress"}{"path_yards"}.getFloat == 100.0, "path yards")
check(st2{"goal"}{"radius"}.getFloat == 50.0, "goal radius")
check(st2{"control"}{"frame_id"}.getInt == 42, "frame id")

setHeld(true)
check(isHeld(), "held true")
setHeld(false)
check(not isHeld(), "held false")

# Reload dry-run against real traverse entry (disk already "hot" each frame).
let r = doReload()
check(r{"ok"}.getBool == true, "reload ok for traverse")
check(r{"lua_gen"}.getInt == 2, "gen bumped to 2")
check(statusJson(){"lua"}{"gen"}.getInt == 2, "status reflects gen")

# Dry-run helper rejects missing entry.
let bad = dryRunLuaLoad(getCurrentDir(), "no_such_entry_xyz", true)
check(not bad.ok, "dry-run fails missing entry")

echo "test_army_debug: all ok"
