## Structural gates for pathfinding-plan.md (shipped sources, not stubs).
import std/[os, strutils, unittest]

let repo = getCurrentDir()
let forkAdapter =
  repo / ".." / "coworld-vanilla-wow-fork" / "player" / "runtime" / "visual_adapter.nim"
let traverseLua = repo / "lua" / "entry" / "traverse.lua"
let beatsJson = repo / "lua" / "config" / "traverse_beats.json"

suite "pathfinding structure":
  test "fork pilot recovers instead of freeze-only on unavailable":
    check fileExists(forkAdapter)
    let src = readFile(forkAdapter)
    check "advanceRouteTo" in src
    check "recover-step" in src
    check "replan" in src
    check "petrelStuckTicks" in src
    check "resetNavigation" in src
    check "nav_progress" in src
    check "nav_error" in src
    check "nav_surface" in src
    check "target_dist" in src
    # Liquid legs must not use ground collision probe (open-water freeze bug).
    check "useCollisionBearing = false" in src
    check "directWaterRoute" in src
    check "liquid" in src

  test "wet strategy has intermediate wet beats not merchant-only":
    let lua = readFile(traverseLua)
    check "next_wet_beat" in lua or "wet_leg" in lua
    check "swim_merchant" in lua  # final only
    let beats = readFile(beatsJson)
    check "wet_leg_a" in beats
    check "wet_leg_b" in beats
    check "merchant" in beats
    # More than one wet target besides merchant.
    check beats.count("liquid_prefer") >= 3

  test "no L/R thrash unstick in strategy":
    let lua = readFile(traverseLua)
    check "unstick" notin lua.toLowerAscii
    check "_unstick" notin lua
