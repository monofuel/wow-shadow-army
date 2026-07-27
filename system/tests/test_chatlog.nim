## Unit tests for Chat.log addon-event parsing and the ring buffer.
## Run: nim r --hints:off --warnings:off system/tests/test_chatlog.nim
## No network, no docker, no realm — pure functions on fixture strings.

import
  std/[options, unittest],
  ../system_server

const
  LineLegacy =
    "2026-07-25 14:19:19 [Chat] (acc 100008, ip 172.20.0.1, guid 1000007, name Murist, map 0, pos 1994.96 1559.28 78.2792) [Say] Murist:1000007 : <ShadowArmy> auto-combat ON"
  LineNonAddon =
    "2026-07-24 17:25:27 [Chat] (acc 100003, ip 172.20.0.1, guid 1000002, name Botwarrior, map 1, pos -618.518 -4251.67 38.718) [Say] Botwarrior:1000002 : external factorized policy action"
  LineLoaded =
    "2026-07-25 18:00:00 [Chat] (acc 100008, ip 172.20.0.1, guid 1000007, name Murist, map 0, pos 1994.96 1559.28 78.2792) [Say] Murist:1000007 : <SA> loaded rev=r1"
  LineErr =
    "2026-07-25 18:00:05 [Chat] (acc 100008, ip 172.20.0.1, guid 1000007, name Murist, map 0, pos 1994.96 1559.28 78.2792) [Say] Murist:1000007 : <SA> err rotation: attempt to compare nil with number"
  LineExtraColons =
    "2026-07-25 19:00:00 [Chat] (acc 1, ip 10.0.0.1, guid 42, name Tester, map 0, pos 1.0 2.0 3.0) [Say] Tester:42 : <SA> status hp:100/100 mana:50:25"
  LineAdminRespawn =
    "2026-07-27 16:00:00 [Chat] (acc 100008, ip 172.20.0.1, guid 1000007, name Murist, map 0, pos 1994.96 1559.28 78.2792) [Say] Murist:1000007 : <SA> admin respawn_shadow_army #1"

suite "parseAddonEvent":
  test "legacy <ShadowArmy> prefix":
    let ev = parseAddonEvent(LineLegacy)
    check ev.isSome
    let e = ev.get
    check e.time == "2026-07-25 14:19:19"
    check e.name == "Murist"
    check e.guid == 1000007
    check e.map == 0
    check e.pos[0] == 1994.96
    check e.pos[1] == 1559.28
    check e.pos[2] == 78.2792
    check e.kind == "legacy"
    check e.payload == "auto-combat ON"
    check e.raw == LineLegacy

  test "non-addon line → none":
    check parseAddonEvent(LineNonAddon).isNone

  test "<SA> loaded":
    let ev = parseAddonEvent(LineLoaded)
    check ev.isSome
    let e = ev.get
    check e.time == "2026-07-25 18:00:00"
    check e.name == "Murist"
    check e.guid == 1000007
    check e.map == 0
    check e.kind == "loaded"
    check e.payload == "rev=r1"

  test "<SA> err with colons in payload":
    let ev = parseAddonEvent(LineErr)
    check ev.isSome
    let e = ev.get
    check e.kind == "err"
    check e.payload == "rotation: attempt to compare nil with number"
    check e.name == "Murist"
    check e.guid == 1000007

  test "message containing extra colons parses intact":
    let ev = parseAddonEvent(LineExtraColons)
    check ev.isSome
    let e = ev.get
    check e.kind == "status"
    check e.payload == "hp:100/100 mana:50:25"
    check e.name == "Tester"
    check e.guid == 42
    check e.pos[0] == 1.0
    check e.pos[1] == 2.0
    check e.pos[2] == 3.0

  test "empty / garbage → none":
    check parseAddonEvent("").isNone
    check parseAddonEvent("not a chat log line").isNone

  test "<SA> admin respawn request":
    let ev = parseAddonEvent(LineAdminRespawn)
    check ev.isSome
    let e = ev.get
    check e.name == "Murist"
    check e.kind == "admin"
    check e.payload == "respawn_shadow_army #1"
    check adminActionFromAddonEvent(e) == "respawn_shadow_army"

suite "ring buffer":
  test "append assigns ids and drops oldest at cap":
    var buf: seq[AddonEvent]
    var nextId = 0
    let cap = 3
    for i in 0 .. 4:
      var base = parseAddonEvent(LineLoaded).get
      base.payload = $i
      discard appendAddonEvent(buf, nextId, base, cap = cap)
    check buf.len == 3
    check buf[0].id == 2
    check buf[0].payload == "2"
    check buf[1].id == 3
    check buf[2].id == 4
    check nextId == 5

  test "selectRecentEvents newest first + kind filter":
    var buf: seq[AddonEvent]
    var nextId = 0
    discard appendAddonEvent(buf, nextId, parseAddonEvent(LineLoaded).get)
    discard appendAddonEvent(buf, nextId, parseAddonEvent(LineErr).get)
    discard appendAddonEvent(buf, nextId, parseAddonEvent(LineLegacy).get)
    let all = selectRecentEvents(buf, limit = 10)
    check all.len == 3
    check all[0].kind == "legacy"
    check all[1].kind == "err"
    check all[2].kind == "loaded"
    let errs = selectRecentEvents(buf, limit = 10, kind = "err")
    check errs.len == 1
    check errs[0].kind == "err"
    let limited = selectRecentEvents(buf, limit = 1)
    check limited.len == 1
    check limited[0].kind == "legacy"
