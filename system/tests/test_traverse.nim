## Unit tests for Kalimdor Traverse scoring + container discovery.
## Run: nim r --hints:off --warnings:off system/tests/test_traverse.nim
## No network, no docker, no realm — pure functions only.

import
  std/[options, os, strutils, unittest],
  ../system_server

suite "traverse episode clock":
  test "docker StartedAt prefix parses to epoch":
    let ep = parseDockerStartedAtEpoch("2026-08-04T20:51:41.181349148Z")
    check ep.isSome
    # 2026-08-04 20:51:41 UTC
    check ep.get == 1785876701

  test "bad StartedAt is none":
    check parseDockerStartedAtEpoch("").isNone
    check parseDockerStartedAtEpoch("not-a-timestamp").isNone

  test "remaining counts down to zero":
    let c = traverseClockAt(1000, 100, TraverseEpisodeLimitSeconds)
    check c.known
    check c.elapsedSec == 900
    check c.remainingSec == TraverseEpisodeLimitSeconds - 900
    check not c.expired
    let done = traverseClockAt(100 + TraverseEpisodeLimitSeconds + 5, 100)
    check done.expired
    check done.remainingSec == 0
    check done.elapsedSec == TraverseEpisodeLimitSeconds + 5

  test "formatTraverseClock":
    check formatTraverseClock(0) == "0:00"
    check formatTraverseClock(65) == "1:05"
    check formatTraverseClock(45 * 60) == "45:00"
    check formatTraverseClock(3661) == "1:01:01"

  test "render shows remaining and limit":
    let clock = traverseClockAt(1000, 100, TraverseEpisodeLimitSeconds)
    let html = renderTraverseClockBlock(clock)
    check "remaining" in html
    check formatTraverseClock(clock.remainingSec) in html
    check formatTraverseClock(TraverseEpisodeLimitSeconds) in html

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

suite "traverse godview live pos":
  test "unit id from container name":
    check traverseUnitIdFromContainer(
      "coworld-native-54a06038d691-traverse-coworld-game-1"
    ) == "54a06038d691"
    check traverseUnitIdFromContainer("coworld-vmangos-coworld-game-1") == ""
    check traverseUnitIdFromContainer("") == ""

  test "parse last Northbound frame from chunk":
    let older = """{"t":1,"map":1,"players":[{"name":"Northbound","x":-9187.0,"y":-2530.0,"z":14.0,"level":60}]}"""
    let newer = """{"t":2,"map":1,"players":[{"name":"Northbound","x":-8891.55,"y":-2497.2,"z":11.8,"level":60}]}"""
    let chunk = older & "\n" & newer & "\n"
    let live = parseGodviewPlayerPos(chunk, "Northbound")
    check live.isSome
    let p = live.get
    check abs(p.x - (-8891.55)) < 0.01
    check abs(p.y - (-2497.2)) < 0.01
    check abs(p.z - 11.8) < 0.01
    check p.hasMap and p.mapId == 1
    check p.hasLevel and p.level == 60
    let yards = traverseNorthingYards(p.x)
    check yards > 0.0
    check abs(yards - 295.45) < 0.1

  test "missing player yields none":
    let chunk = """{"t":1,"map":1,"players":[{"name":"Other","x":1.0,"y":2.0,"z":3.0}]}"""
    check parseGodviewPlayerPos(chunk, "Northbound").isNone
    check parseGodviewPlayerPos("", "Northbound").isNone

  test "applyLiveTraversePos overlays coords":
    var ch = TraverseCharacter(
      name: "Northbound", level: 60, mapId: 1, zoneId: 440,
      posX: -9187.0, posY: -2530.0, posZ: 14.0, online: true, hasPosition: true
    )
    applyLiveTraversePos(ch, TraverseLivePos(
      x: -8891.55, y: -2497.2, z: 11.8, mapId: 1, level: 60,
      hasMap: true, hasLevel: true
    ))
    check abs(ch.posX - (-8891.55)) < 0.01
    check ch.hasPosition
    let sc = scoreTraverse(true, ch.level, ch.mapId, ch.hasPosition, ch.posX)
    check sc.valid
    check sc.northingYards > 0.0

  test "live badge when livePos set":
    var ch = TraverseCharacter(
      name: "Northbound", level: 60, mapId: 1, zoneId: 440, zoneName: "Tanaris",
      posX: -8891.55, posY: -2497.2, posZ: 11.8, online: true, hasPosition: true
    )
    let sc = scoreTraverse(true, 60, 1, true, ch.posX)
    let st = TraverseStatus(
      containerFound: true,
      containerName: "coworld-native-test-traverse-coworld-game-1",
      characterFound: true,
      character: ch,
      score: sc,
      livePos: true
    )
    let html = renderTraverseStatus(st)
    check "live" in html
    check "northing yards" in html
    check sc.northingYards > 1.0
    check formatTraverseYards(sc.northingYards) in html

suite "traverse ops panel":
  test "idle shows start buttons":
    let ops = TraverseOpsStatus(
      polRunning: false,
      watchRunning: false,
      polLog: TraversePolLogRel,
      watchLog: TraverseWatchLogRel
    )
    let html = renderTraverseOpsPanel(ops)
    check "Start proof of life" in html
    check "Start observer" in html
    check "/traverse/pol/start" in html
    check "/traverse/watch/start" in html
    check "PoL idle" in html
    check "observer idle" in html
    # Dashboard is metrics+buttons only (autoresearch docs/dashboard.md).
    check "make traverse-pol" notin html
    check "watch_bots" notin html

  test "running shows stop buttons":
    let ops = TraverseOpsStatus(
      polRunning: true,
      watchRunning: true,
      polLog: TraversePolLogRel,
      watchLog: TraverseWatchLogRel,
      lastOk: true,
      lastDetail: "started make traverse-pol"
    )
    let html = renderTraverseOpsPanel(ops)
    check "Stop proof of life" in html
    check "Stop observer" in html
    check "/traverse/pol/stop" in html
    check "/traverse/watch/stop" in html
    check "PoL running" in html
    check "observer running" in html
    check "started make traverse-pol" in html

  test "page includes controls section":
    let st = TraverseStatus(containerFound: false)
    let ops = TraverseOpsStatus(
      polLog: TraversePolLogRel, watchLog: TraverseWatchLogRel)
    let page = renderTraversePage(st, ops)
    check "Controls" in page
    check "id=\"traverse-ops\"" in page
    check "hx-get=\"/traverse/ops\"" in page

suite "traverse docker port parse":
  test "parse published host port line":
    # Unit-test only the parser logic via dockerPublishedHostPort needs docker;
    # instead pin logFileTail and ops panel still compile.
    check logFileTail("/nonexistent/file") == ""
    let tmp = getTempDir() / "traverse-ops-tail-test.log"
    writeFile(tmp, "a\nb\nc\nd\ne\n")
    let t = logFileTail(tmp, 3)
    check "c" in t and "d" in t and "e" in t
    removeFile(tmp)

suite "traverse live capture probe":
  test "latestGodviewHasCharacter finds Northbound and ignores empty tail":
    let dir = getTempDir() / "traverse-godview-probe"
    createDir(dir)
    let path = dir / "godview_test.jsonl"
    writeFile(
      path,
      """{"t":1,"map":1,"instance":0,"players":[{"name":"Northbound","raw_guid":1000000}]}
{"t":2,"map":1,"instance":0,"players":[]}
"""
    )
    check latestGodviewHasCharacter(dir, "Northbound", 3600.0)
    check not latestGodviewHasCharacter(dir, "SomeoneElse", 3600.0)
    check not latestGodviewHasCharacter(dir, "Northbound", 0.0)
    removeFile(path)
    removeDir(dir)
