## Unit tests for realm lifecycle helpers (Server panel).
## Run: nim r --hints:off --warnings:off system/tests/test_server_ops.nim
## No network, no docker, no realm — pure functions only.

import
  std/[json, options, os, strutils, unittest],
  ../system_server

suite "server lifecycle ops":
  test "docker inspect running parse":
    check parseDockerRunning("true\n")
    check parseDockerRunning("  True ")
    check not parseDockerRunning("false\n")
    check not parseDockerRunning("")
    check not parseDockerRunning("Error: No such object: coworld-vmangos-coworld-game-1")

  test "docker inspect probe + short id":
    check shortContainerId("abcdef0123456789deadbeef") == "abcdef012345"
    check shortContainerId("abc") == "abc"
    check shortContainerId("") == ""
    let up = parseDockerInspectProbe("true\tabcdef0123456789deadbeef\n")
    check up.running
    check up.id == "abcdef012345"
    let down = parseDockerInspectProbe("false\tabcdef0123456789\n")
    check not down.running
    check down.id == "abcdef012345"
    check not parseDockerInspectProbe("").running
    check parseDockerInspectProbe("").id == ""

  test "op verb / label mapping":
    check serverOpVerb(sloStart) == "up"
    check serverOpVerb(sloStop) == "down"
    check serverOpVerb(sloNone) == ""
    check serverOpLabel(sloStart) == "start"
    check serverOpLabel(sloStop) == "stop"
    check serverOpLabel(sloNone) == ""

  test "tail for display keeps the end of long output":
    check tailForDisplay("short") == "short"
    let long = "x".repeat(1000) & "THE END"
    let tail = tailForDisplay(long)
    check tail.len <= 600 + "…".len # maxLen + multi-byte ellipsis
    check tail.startsWith("…")
    check tail.endsWith("THE END")

  test "realm op exit marker parse":
    check parseRealmOpExit("") == -1
    check parseRealmOpExit("noise\n") == -1
    check parseRealmOpExit("SYSTEM_REALM_OP_EXIT=0\n") == 0
    check parseRealmOpExit("foo\nSYSTEM_REALM_OP_EXIT=1\nbar\nSYSTEM_REALM_OP_EXIT=0\n") == 0
    check serverOpFromLabel("start") == sloStart
    check serverOpFromLabel("stop") == sloStop
    check serverOpFromLabel("") == sloNone

suite "server status views":
  test "json view carries all lifecycle fields":
    let s = ServerStatus(
      running: true, container: "coworld-vmangos-coworld-game-1",
      containerId: "abcdef012345",
      op: "", lastOp: "start", lastOpOk: true, lastOpDetail: "operator up ok")
    let j = serverStatusToJson(s)
    check j["running"].getBool()
    check j["container"].getStr() == "coworld-vmangos-coworld-game-1"
    check j["container_id"].getStr() == "abcdef012345"
    check j["op"].getStr() == ""
    check j["last_op"].getStr() == "start"
    check j["last_op_ok"].getBool()
    check j["last_op_detail"].getStr() == "operator up ok"

  test "panel offers Start when stopped and idle":
    let html = renderServerPanel(ServerStatus(
      running: false, container: "c", containerId: "", op: ""))
    check "Start server" in html
    check "/server/start" in html
    check "Stop server" notin html
    check "Stopped" in html
    check "no container" in html

  test "panel labels exited container id when stopped":
    let html = renderServerPanel(ServerStatus(
      running: false, container: "c", containerId: "deadbeefcafe", op: ""))
    check "Stopped (exited)" in html
    check "exited deadbeefcafe" in html
    check "Start server" in html

  test "panel offers Stop when running and idle":
    let html = renderServerPanel(ServerStatus(
      running: true, container: "c", containerId: "deadbeefcafe", op: ""))
    check "Stop server" in html
    check "/server/stop" in html
    check "Start server" notin html
    check "Running" in html
    check "deadbeefcafe" in html
    check "exited" notin html

  test "panel shows progress (no buttons) during an op":
    let starting = renderServerPanel(ServerStatus(
      running: false, container: "c", op: "start"))
    check "Starting…" in starting
    check "Start server" notin starting
    check "Stop server" notin starting
    let stopping = renderServerPanel(ServerStatus(
      running: true, container: "c", op: "stop"))
    check "Stopping…" in stopping
    check "Start server" notin stopping
    check "Stop server" notin stopping

  test "panel surfaces last op outcome":
    let ok = renderServerPanel(ServerStatus(
      running: true, container: "c", op: "",
      lastOp: "start", lastOpOk: true, lastOpDetail: "fine"))
    check "last start: ok" in ok
    let fail = renderServerPanel(ServerStatus(
      running: false, container: "c", op: "",
      lastOp: "start", lastOpOk: false, lastOpDetail: "compose exploded"))
    check "last start: FAIL" in fail
    check "compose exploded" in fail

  test "offline roster row points at the Admin tab":
    let row = renderRosterOfflineRow()
    check "/admin" in row
    check "error" notin row.toLowerAscii()

  test "murist status panel is metrics-only":
    let offline = renderMuristStatus(none(Character), realmOffline = true)
    check "Realm offline" in offline
    check "/admin" in offline
    let missing = renderMuristStatus(none(Character), realmOffline = false)
    check "not in characters" in missing
    let c = Character(
      name: "Murist", level: 12, className: "Warlock", raceName: "Undead",
      gold: "1g 2s 3c", online: true, life: "alive", zoneName: "Tirisfal Glades",
      posX: 1.0, posY: 2.0, posZ: 3.0, xp: 100, nextLevelXp: 1000, xpToLevel: 900, xpPct: 10,
      health: 50, maxHealth: 100, power: 20, maxPower: 100, powerKind: "mana")
    let html = renderMuristStatus(some(c), realmOffline = false)
    check "level" in html
    check "12" in html
    check "Warlock" in html
    check "Tirisfal" in html
    check "online" in html
    check "listCharacters" notin html

  test "filter events by name":
    let ev = @[
      AddonEvent(id: 1, name: "Murist", kind: "loaded", payload: "rev=1"),
      AddonEvent(id: 2, name: "Igris", kind: "loaded", payload: "rev=1"),
      AddonEvent(id: 3, name: "Murist", kind: "err", payload: "boom"),
    ]
    let mine = filterEventsByName(ev, "Murist")
    check mine.len == 2
    check mine[0].kind == "loaded"
    check mine[1].kind == "err"

  test "quest status labels and progress format":
    check questStatusLabel(1) == "complete"
    check questStatusLabel(3) == "active"
    check questStatusLabel(5) == "failed"
    check isSafeSqlName("Murist")
    check not isSafeSqlName("Mur'; DROP")
    check not isSafeSqlName("")
    check "Murist" in questLogSqlFor("Murist")
    check "character_queststatus" in questLogSqlFor("Murist")
    let prog = formatQuestProgress(
      [3, 0, 0, 0], [10, 0, 0, 0],
      [1, 2, 0, 0], [5, 5, 0, 0])
    check prog == "3/10 · 1/5 · 2/5"
    # TSV: quest status mob1-4 item1-4 title level reqMob1-4 reqItem1-4 obj1-4
    let tsv = "365\t3\t0\t0\t0\t0\t3\t0\t0\t0\tFields of Grief\t7\t0\t0\t0\t0\t10\t0\t0\t0\t\t\t\t"
    let qs = parseQuestLogTsv(tsv)
    check qs.len == 1
    check qs[0].questId == 365
    check qs[0].status == "active"
    check qs[0].title == "Fields of Grief"
    check qs[0].level == 7
    check qs[0].progress == "3/10"
    let rows = renderQuestRows(qs)
    check "Fields of Grief" in rows
    check "active" in rows
    check "3/10" in rows

  test "army quest board parse + bot tally skips Murist":
    check armyQuestState(1, 3) == "rewarded"
    check armyQuestState(0, 1) == "ready"
    check armyQuestState(0, 3) == "active"
    check armyQuestState(0, 5) == "failed"
    check "character_queststatus" in ArmyQuestSql
    check "cq.rewarded" in ArmyQuestSql
    # name quest status rewarded mob1-4 item1-4 title level reqMob1-4 reqItem1-4
    let tsv = "Kargalgan\t1470\t1\t1\t0\t0\t0\t0\t0\t0\t0\t0\tPiercing the Veil\t4\t0\t0\t0\t0\t0\t0\t0\t0\n" &
              "Kargalgan\t376\t1\t0\t6\t6\t0\t0\t0\t0\t0\t0\tThe Damned\t2\t6\t6\t0\t0\t0\t0\t0\t0\n" &
              "Murist\t364\t1\t1\t0\t0\t0\t0\t0\t0\t0\t0\tThe Mindless Ones\t1\t0\t0\t0\t0\t0\t0\t0\t0\n"
    let parsed = parseArmyQuestTsv(tsv)
    check parsed.len == 3
    check parsed[0].state == "rewarded"
    check parsed[0].progress == ""
    check parsed[1].state == "ready"
    check parsed[1].progress == "6/6 · 6/6"
    let board = tallyArmyQuestBoard(parsed)
    check board.rewarded == 1
    check board.ready == 1
    check board.active == 0
    let html = renderArmyQuestRows(board)
    check "Piercing the Veil" in html
    check "rewarded" in html
    check "ready" in html
    let strip = renderArmyQuestSummary(board)
    check "1 rewarded" in strip
    check "50% done" in strip

suite "seat cell":
  test "seat cell is always a terse On/Off (detail in tooltip only)":
    let off = renderSeatCell(Character(
      name: "Tusk", online: false, controlPort: 0, controlUp: false))
    check "no-ctrl" notin off
    check ">Off<" in off
    let on = renderSeatCell(Character(
      name: "Igris", online: true, controlPort: 0, controlUp: true))
    check ">On<" in on
    check "heartbeat is fresh" in on
    check "title=" in on

  test "human seat is terse too":
    let html = renderSeatCell(Character(name: "Murist", online: true, controlPort: 0))
    check ">On<" in html
    check "human" in html # tooltip only
    check "· human" notin html

suite "bot seat lifecycle":
  test "seat make targets cover the bot seats only":
    check seatMakeTarget("Shadowfel") == "shadowfel-start"
    check seatMakeTarget("Igris") == "igris-start"
    check seatMakeTarget("Tusk") == "tusk-start"
    check seatMakeTarget("Beru") == "beru-start"
    check seatStopTarget("Shadowfel") == "shadowfel-stop"
    check seatStopTarget("Beru") == "beru-stop"
    check seatMakeTarget("Murist") == ""
    check seatMakeTarget("Botwarrior") == ""
    check seatMakeTarget("") == ""

  test "embedded seats do not expose retired control ports":
    for seat in SeatMakeTargets:
      check seatControlPort(seat.name) == 0
      check seatRuntimeDir(seat.name).endsWith("local_data/home-army/" & seat.name)

  test "seat liveness requires both a live pid and a fresh heartbeat":
    let
      oldRoot = getEnv("SYSTEM_ARMY_DIR", "")
      scratch = getTempDir() / "shadow_army_seat_runtime_test"
    defer:
      if oldRoot.len > 0: putEnv("SYSTEM_ARMY_DIR", oldRoot)
      else: delEnv("SYSTEM_ARMY_DIR")
      if dirExists(scratch): removeDir(scratch)
    if dirExists(scratch): removeDir(scratch)
    putEnv("SYSTEM_ARMY_DIR", scratch)
    createDir(parentDir(seatStatusPath("Tusk")))
    writeFile(seatPidPath("Tusk"), $getCurrentProcessId() & "\n")
    check not seatRuntimeUp("Tusk")
    writeFile(seatStatusPath("Tusk"), "{}\n")
    check seatRuntimeUp("Tusk")
    writeFile(seatPidPath("Tusk"), "999999999\n")
    check not seatRuntimeUp("Tusk")
    check not seatRuntimeUp("Murist")

  test "bot cell: Start when seat down, Stop when up, dash for humans":
    let down = renderBotCell(Character(name: "Tusk", controlPort: 0, controlUp: false))
    check "Start" in down
    check "/bots/start?name=Tusk" in down
    let up = renderBotCell(Character(name: "Tusk", controlPort: 0, controlUp: true))
    check "Stop" in up
    check "/bots/stop?name=Tusk" in up
    let human = renderBotCell(Character(name: "Murist", controlPort: 0))
    check "Start" notin human
    check "Stop" notin human

  test "lifecycle procs reject non-bot-seat names without side effects":
    let s = startBotSeat("Botwarrior")
    check not s{"ok"}.getBool(true)
    check "not a launchable" in s{"detail"}.getStr("")
    let t = stopBotSeat("nobody")
    check not t{"ok"}.getBool(true)
