## Unit tests for Kalimdor Traverse scoring + container discovery.
## Run: nim r --hints:off --warnings:off system/tests/test_traverse.nim
## No network, no docker, no realm — pure functions only.

import
  std/[options, strutils, unittest],
  ../system_server

suite "traverse scoring":
  test "northing at start is zero":
    check abs(traverseNorthingYards(TraverseStartWorldX) - 0.0) < 0.001
    check abs(traverseCoursePct(0.0) - 0.0) < 0.001

  test "northing at goal is full course":
    let yards = traverseNorthingYards(TraverseGoalWorldX)
    check abs(yards - TraverseCourseYards) < 0.001
    check abs(traverseCoursePct(yards) - 100.0) < 0.001

  test "northing clamps below start and above goal":
    check abs(traverseNorthingYards(TraverseStartWorldX - 1000.0) - 0.0) < 0.001
    let over = traverseNorthingYards(TraverseGoalWorldX + 5000.0)
    check abs(over - TraverseCourseYards) < 0.001

  test "verified start position scores zero yards":
    # Live fixture snapshot: x=-9187 at Tanaris start.
    let yards = traverseNorthingYards(-9187.0)
    check abs(yards - 0.0) < 0.001
    let sc = scoreTraverse(true, 60, 1, true, -9187.0)
    check sc.valid
    check sc.invalidReason.len == 0
    check abs(sc.northingYards - 0.0) < 0.001
    check abs(sc.coursePct - 0.0) < 0.001

  test "mid-course northing percent":
    # Halfway world X between start and goal.
    let midX = TraverseStartWorldX + TraverseCourseYards / 2.0
    let yards = traverseNorthingYards(midX)
    check abs(yards - TraverseCourseYards / 2.0) < 0.01
    check abs(traverseCoursePct(yards) - 50.0) < 0.05

suite "traverse validity":
  test "character not found":
    check traverseInvalidReason(false, 60, 1, true) == "character_not_found"
    let sc = scoreTraverse(false, 60, 1, true, 0.0)
    check not sc.valid
    check sc.invalidReason == "character_not_found"
    check abs(sc.northingYards - 0.0) < 0.001

  test "level not 60":
    check traverseInvalidReason(true, 59, 1, true) == "character_not_level_60"
    check traverseInvalidReason(true, 61, 1, true) == "character_not_level_60"
    let sc = scoreTraverse(true, 39, 1, true, 1000.0)
    check not sc.valid
    check sc.invalidReason == "character_not_level_60"
    check abs(sc.northingYards - 0.0) < 0.001

  test "left Kalimdor (map != 1)":
    check traverseInvalidReason(true, 60, 0, true) == "character_left_kalimdor"
    check traverseInvalidReason(true, 60, 530, true) == "character_left_kalimdor"

  test "position unavailable":
    check traverseInvalidReason(true, 60, 1, false) == "character_position_unavailable"

  test "valid level 60 map 1 with position":
    check traverseInvalidReason(true, 60, 1, true) == ""
    let sc = scoreTraverse(true, 60, 1, true, 0.0)
    check sc.valid
    check sc.invalidReason == ""
    # x=0 is past start: 0 - (-9187) = 9187 yards
    check abs(sc.northingYards - 9187.0) < 0.001

  test "reason priority: not found before level":
    # Missing character wins even if other fields look wrong.
    check traverseInvalidReason(false, 1, 0, false) == "character_not_found"

suite "traverse container discovery":
  test "env override wins":
    let names = "coworld-vmangos-coworld-game-1\ncoworld-native-abc-traverse-coworld-game-1\n"
    check findTraverseContainerName(names, "my-override") == "my-override"
    check findTraverseContainerName("", "  forced  ") == "forced"

  test "picks suffix match from docker ps output":
    let names =
      "coworld-vmangos-coworld-game-1\n" &
      "coworld-native-54a06038d691-traverse-coworld-game-1\n" &
      "open-webui\n"
    check findTraverseContainerName(names) ==
      "coworld-native-54a06038d691-traverse-coworld-game-1"

  test "empty when no match":
    let names = "coworld-vmangos-coworld-game-1\nopen-webui\n"
    check findTraverseContainerName(names) == ""
    check findTraverseContainerName("") == ""
    check findTraverseContainerName("  \n\n") == ""

  test "suffix must be exact end":
    # Nearly-matching names must not false-positive.
    let names = "something-traverse-coworld-game-12\nfoo-traverse-coworld-game\n"
    check findTraverseContainerName(names) == ""

suite "traverse TSV parse":
  test "full 9-column row with zone name":
    let tsv = "Northbound\t60\t1\t440\t-9187\t-2530.25\t14.0935\t1\tTanaris\n"
    let chOpt = parseTraverseTsv(tsv)
    check chOpt.isSome
    let ch = chOpt.get
    check ch.name == "Northbound"
    check ch.level == 60
    check ch.mapId == 1
    check ch.zoneId == 440
    check ch.zoneName == "Tanaris"
    check ch.online == true
    check ch.hasPosition
    check abs(ch.posX - (-9187.0)) < 0.01
    check abs(ch.posY - (-2530.25)) < 0.01
    check abs(ch.posZ - 14.0935) < 0.01

  test "8-column row falls back to Zone#N":
    let tsv = "Northbound\t60\t1\t440\t-9187\t-2530.25\t14.0935\t0\n"
    let ch = parseTraverseTsv(tsv).get
    check ch.online == false
    check ch.zoneName == "Zone#440"

  test "empty and short rows yield none":
    check parseTraverseTsv("").isNone
    check parseTraverseTsv("a\tb\tc\n").isNone
    check parseTraverseTsv("\n\n").isNone

  test "bad position marks hasPosition false":
    let tsv = "Northbound\t60\t1\t440\t?\t?\t?\t1\tTanaris\n"
    let ch = parseTraverseTsv(tsv).get
    check ch.name == "Northbound"
    check not ch.hasPosition
    let sc = scoreTraverse(true, ch.level, ch.mapId, ch.hasPosition, ch.posX)
    check not sc.valid
    check sc.invalidReason == "character_position_unavailable"

  test "render not-running state is clean":
    let st = TraverseStatus(
      containerFound: false,
      score: scoreTraverse(false, 0, 0, false, 0.0)
    )
    let html = renderTraverseStatus(st)
    check "Scenario not running" in html
    check "Northbound" notin html or "not found" in html
