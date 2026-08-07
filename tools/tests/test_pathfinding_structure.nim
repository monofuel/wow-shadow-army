## Structural gates for pathfinding-plan.md (shipped sources, not stubs).
import std/[os, strutils, unittest]

let repo = getCurrentDir()
let forkAdapter =
  repo / ".." / "coworld-vanilla-wow-fork" / "player" / "runtime" / "visual_adapter.nim"
let forkDebug =
  repo / ".." / "coworld-vanilla-wow-fork" / "player" / "runtime" / "petrel_debug.nim"
let traverseLua = repo / "lua" / "entry" / "traverse.lua"
let beatsJson = repo / "lua" / "config" / "traverse_beats.json"

suite "pathfinding structure":
  test "Petrel input sequence has one client-owned allocator":
    let
      cApi = readFile(repo / "src" / "petrel" / "c_api.nim")
      adapter = readFile(forkAdapter)
    check "castSeq" notin cApi
    check "reservePetrelSequence" in adapter
    check "activeClientInput.lastSequence + 1" in adapter
    check "petrelFormPendingSpell" in adapter

  test "fork pilot recovers instead of freeze-only on unavailable":
    check fileExists(forkAdapter)
    check fileExists(forkDebug)
    let src = readFile(forkAdapter) & readFile(forkDebug)
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
    # A level liquid segment must not be lowered as unknown-Z: canonical
    # steering treats unknown swim depth as a request to jump to the surface.
    check "pilot.policy.navigation.targetZKnown = true" in src
    # Proximity to a surface is not proof that liquid movement owns the body.
    check "swimNow or view.player.liquidSubmerged" in src
    check "pilot.petrelLiquidUnknownSince = 0" in src
    check "liquid" in src

  test "wet strategy uses the scoped manual route":
    let lua = readFile(traverseLua)
    check "next_wet_beat" in lua
    check "route_reference" in lua
    let beats = readFile(beatsJson)
    check "coast_01" in beats
    check "coast_11" in beats
    check "duskwallow_coast" in beats
    check beats.count("liquid_prefer") >= 12

  test "no L/R thrash unstick in strategy":
    let lua = readFile(traverseLua)
    check "unstick" notin lua.toLowerAscii
    check "_unstick" notin lua
