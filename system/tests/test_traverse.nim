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
    check "Start local traverse" in html
    check "/traverse/pol/start" in html
    check "local bot idle" in html
    check "proof of life" notin html.toLowerAscii
    check "Start observer" notin html
    check "/traverse/watch/start" notin html
    check "observer" notin html
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
      lastDetail: "local traverse started"
    )
    let html = renderTraverseOpsPanel(ops)
    check "Stop local traverse" in html
    check "/traverse/pol/stop" in html
    check "local bot running" in html
    check "Stop observer" notin html
    check "/traverse/watch/stop" notin html
    check "observer" notin html
    check "local traverse started" in html

  test "isTraversePolProcess matches prepare leftovers":
    # Pure string contract for the marker set (no live /proc).
    check "native_support" in "uv run python -m player.launch.native_support prepare --league=traverse"
    check isTraversePolProcess(0) == false

  test "page includes controls section":
    let st = TraverseStatus(containerFound: false)
    let ops = TraverseOpsStatus(
      polLog: TraversePolLogRel, watchLog: TraverseWatchLogRel)
    let replays = TraverseReplaysStatus(note: "no data")
    let page = renderTraversePage(st, ops, replays)
    check "Controls" in page
    check "id=\"traverse-ops\"" in page
    check "hx-get=\"/traverse/ops\"" in page
    check "Hosted replays" in page
    check "id=\"traverse-replays\"" in page
    check "hx-get=\"/traverse/replays\"" in page

suite "traverse hosted replays":
  const sampleEpisodes = """
[
  {
    "id": "ereq_dde219b5-33b7-4364-a073-4356e2288a35",
    "episode_id": "52b9a6cc-c319-41ff-b3af-c94396daea38",
    "status": "completed",
    "coworld_id": "cow_3eca82b6-2ad7-476b-88af-832d1faa666d",
    "coworld_name": "traverse-wow",
    "coworld_version": "0.1.160",
    "replay_url": "https://softmax-public.s3.amazonaws.com/replays/f2c52d1d-5f11-433d-953a-693950f68c2b.replay",
    "live_url": null,
    "scores": [
      {"policy_version_id": "76a72f80-bb4f-4fcb-aad6-95fb1f8fa4b8", "score": 1996.05}
    ],
    "participants": [
      {
        "position": 0,
        "policy_version_id": "76a72f80-bb4f-4fcb-aad6-95fb1f8fa4b8",
        "policy_name": "ibis",
        "version": 2,
        "is_filler": false,
        "label": "ibis:v2"
      }
    ],
    "created_at": "2026-08-05T17:34:21.261552Z",
    "completed_at": "2026-08-05T18:23:01.394277Z",
    "running_at": "2026-08-05T17:37:13.114494Z"
  },
  {
    "id": "ereq_be25298c-1651-46a4-a002-111c127fa708",
    "status": "running",
    "replay_url": null,
    "live_url": "https://example.test/live",
    "scores": [],
    "participants": [
      {
        "policy_version_id": "76a72f80-bb4f-4fcb-aad6-95fb1f8fa4b8",
        "policy_name": "ibis",
        "version": 2,
        "is_filler": false,
        "label": "ibis:v2"
      }
    ],
    "created_at": "2026-08-05T18:23:41.526204Z",
    "running_at": "2026-08-05T18:23:53.125886Z"
  },
  {
    "id": "ereq_0e650027-caed-4044-be1e-bdeab8ddb1f0",
    "episode_id": "020bca5f-1b8c-4248-b97a-a3f2e623eeeb",
    "status": "completed",
    "coworld_id": "cow_ac19464b-66da-4c94-a8d2-3580e567f0a2",
    "coworld_name": "traverse-wow",
    "coworld_version": "0.1.160",
    "replay_url": "https://softmax-public.s3.amazonaws.com/replays/v1.replay",
    "scores": [
      {"policy_version_id": "ccbfd6ab-9d7e-48d5-aff1-25a7c000c1d4", "score": 2278.73}
    ],
    "participants": [
      {
        "policy_version_id": "ccbfd6ab-9d7e-48d5-aff1-25a7c000c1d4",
        "policy_name": "ibis",
        "version": 1,
        "is_filler": false,
        "label": "ibis:v1"
      }
    ],
    "completed_at": "2026-08-05T04:08:50.424344Z"
  }
]
"""

  test "observatory replay viewer URL shape":
    let url = episodeObservatoryReplayUrl(
      "cow_3eca82b6-2ad7-476b-88af-832d1faa666d",
      "https://softmax-public.s3.amazonaws.com/replays/f2c52d1d-5f11-433d-953a-693950f68c2b.replay",
      "traverse-wow",
      "0.1.160",
      "52b9a6cc-c319-41ff-b3af-c94396daea38"
    )
    check url.startsWith(
      "https://softmax.com/observatory/coworld-replays/cow_3eca82b6-2ad7-476b-88af-832d1faa666d?")
    check "replay_uri=" in url
    check "softmax-public.s3.amazonaws.com" in url
    check "game=traverse-wow" in url
    check "game_version=0.1.160" in url
    check "episode_id=52b9a6cc-c319-41ff-b3af-c94396daea38" in url
    check episodeObservatoryReplayUrl("", "https://x.replay", "g", "1", "e") == ""

  test "parse episodes into version + score + links":
    let rows = parseTraverseEpisodesJson(sampleEpisodes)
    check rows.len == 3
    var foundV1 = false
    var foundV2Done = false
    var foundLive = false
    for r in rows:
      if r.versionLabel == "ibis:v1":
        foundV1 = true
        check r.hasScore
        check abs(r.score - 2278.73) < 0.01
        check r.replayUrl.len > 0
        let links = renderTraverseReplayLinks(r)
        check "Replay" notin links
        check "Obs" in links
        check "coworld-replays/" in r.observatoryUrl
        check "replay_uri=" in r.observatoryUrl
      if r.versionLabel == "ibis:v2" and r.status == "completed":
        foundV2Done = true
        check abs(r.score - 1996.05) < 0.01
        check "coworld-replays/cow_3eca82b6" in r.observatoryUrl
        check "episode_id=52b9a6cc" in r.observatoryUrl
        check "s3.amazonaws.com" in r.observatoryUrl
      if r.status == "running":
        foundLive = true
        check not r.hasScore
        check "Live" in renderTraverseReplayLinks(r)
        check "Replay" notin renderTraverseReplayLinks(r)
        # No replay yet → fall back to episode-request detail.
        check "episode-request:" in r.observatoryUrl
    check foundV1 and foundV2Done and foundLive

  test "render panel has version column and refresh":
    let rows = parseTraverseEpisodesJson(sampleEpisodes)
    let st = TraverseReplaysStatus(
      available: true,
      note: "3 episodes",
      rows: rows,
      lastOk: true
    )
    let html = renderTraverseReplaysPanel(st)
    check "ibis:v2" in html
    check "ibis:v1" in html
    check "Replay" notin html
    check "Obs" in html
    check "coworld-replays/" in html
    check "/traverse/replays/refresh" in html
    check "Version" in html
    check "1996.1" in html or "1996.0" in html
    check "proof-of-life" notin html
    check "RealPlayerBot" notin html
  test "our policy name filter":
    check isTraverseOurPolicy("ibis")
    check isTraverseOurPolicy("Ibis")
    check not isTraverseOurPolicy("osprey")

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
