## Unit tests for realm lifecycle helpers (Server panel).
## Run: nim r --hints:off --warnings:off system/tests/test_server_ops.nim
## No network, no docker, no realm — pure functions only.

import
  std/[json, strutils, unittest],
  ../system_server

suite "server lifecycle ops":
  test "docker inspect running parse":
    check parseDockerRunning("true\n")
    check parseDockerRunning("  True ")
    check not parseDockerRunning("false\n")
    check not parseDockerRunning("")
    check not parseDockerRunning("Error: No such object: coworld-vmangos-coworld-game-1")

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
      op: "", lastOp: "start", lastOpOk: true, lastOpDetail: "operator up ok")
    let j = serverStatusToJson(s)
    check j["running"].getBool()
    check j["container"].getStr() == "coworld-vmangos-coworld-game-1"
    check j["op"].getStr() == ""
    check j["last_op"].getStr() == "start"
    check j["last_op_ok"].getBool()
    check j["last_op_detail"].getStr() == "operator up ok"

  test "panel offers Start when stopped and idle":
    let html = renderServerPanel(ServerStatus(
      running: false, container: "c", op: ""))
    check "Start server" in html
    check "/server/start" in html
    check "Stop server" notin html
    check "Stopped" in html

  test "panel offers Stop when running and idle":
    let html = renderServerPanel(ServerStatus(
      running: true, container: "c", op: ""))
    check "Stop server" in html
    check "/server/stop" in html
    check "Start server" notin html
    check "Running" in html

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

suite "seat cell":
  test "seat cell is always a terse On/Off (detail in tooltip only)":
    let off = renderSeatCell(Character(
      name: "Tusk", online: false, controlPort: 41118, controlUp: false))
    check "no-ctrl" notin off
    check ">Off<" in off
    let on = renderSeatCell(Character(
      name: "Igris", online: true, controlPort: 41117, controlUp: true))
    check ">On<" in on
    # Port shows up only inside the title attribute, never as cell text.
    check " :41117" notin on
    check "title=" in on

  test "human seat is terse too":
    let html = renderSeatCell(Character(name: "Murist", online: true, controlPort: 0))
    check ">On<" in html
    check "human" in html # tooltip only
    check "· human" notin html

suite "bot seat lifecycle":
  test "seat make targets cover the bot seats only":
    check seatMakeTarget("Shadowfel") == "warlock-bot"
    check seatMakeTarget("Igris") == "igris-bot"
    check seatMakeTarget("Tusk") == "tusk-bot"
    check seatMakeTarget("Beru") == "beru-bot"
    check seatMakeTarget("Murist") == ""
    check seatMakeTarget("Botwarrior") == ""
    check seatMakeTarget("") == ""

  test "seat slots match seatControlPort":
    for seat in SeatMakeTargets:
      check seatControlPort(seat.name) == 41114 + seat.slot

  test "bot cell: Start when seat down, Stop when up, dash for humans":
    let down = renderBotCell(Character(name: "Tusk", controlPort: 41118, controlUp: false))
    check "Start" in down
    check "/bots/start?name=Tusk" in down
    let up = renderBotCell(Character(name: "Tusk", controlPort: 41118, controlUp: true))
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
