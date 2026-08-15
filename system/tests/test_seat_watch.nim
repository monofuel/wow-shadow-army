## Unit tests for the seat babysitter (ticket 0055): staleness classification,
## the restart budget, evidence capture, and one full recovery pass driven
## against a THROWAWAY army root.
## Run: nim r --hints:off --warnings:off system/tests/test_seat_watch.nim
##
## No network, no docker, no realm. The recovery pass points SYSTEM_ARMY_DIR at
## a temp dir with a fake Makefile, so the real home seats are never signalled:
## the make targets exercised here only touch files under that temp root.

import
  std/[os, strformat, strutils, times, unittest],
  ../system_server

suite "classifySeat":
  test "no launcher pid is simply stopped":
    check classifySeat(false, false, -1.0) == "stopped"
    check classifySeat(false, true, 999.0) == "stopped"

  test "pid alive with no status file yet is starting, never wedged":
    # A cold `nim r` seat build can take minutes; it must not be restarted.
    check classifySeat(true, false, -1.0) == "starting"

  test "fresh heartbeat is running":
    check classifySeat(true, true, 3.0) == "running"
    check classifySeat(true, true, 89.0) == "running"

  test "stale heartbeat with a live launcher is wedged":
    check classifySeat(true, true, 91.0) == "wedged"
    check classifySeat(true, true, 30.0, staleSec = 10.0) == "wedged"

  test "clock skew reads as starting, not wedged":
    check classifySeat(true, true, -30.0) == "starting"

suite "restart budget":
  test "window prunes old attempts":
    let now = 10_000.0
    let stamps = @[now - 7200.0, now - 100.0, now - 50.0]
    check pruneRestartStamps(stamps, now).len == 2

  test "budget allows up to N per window then stops":
    let now = 10_000.0
    check restartAllowed(@[], now)
    check restartAllowed(@[now - 10.0, now - 20.0], now)
    check not restartAllowed(@[now - 10.0, now - 20.0, now - 30.0], now)
    # Attempts that fell out of the window free the budget again.
    check restartAllowed(@[now - 4000.0, now - 5000.0, now - 6000.0], now)

suite "evidence + display":
  test "evidence file name is timestamp sortable":
    let name = wedgeEvidenceName(fromUnix(1786775642))
    check name.startsWith("wedge-")
    check name.endsWith(".log")

  test "age formatting":
    check formatAgeSec(-1.0) == "—"
    check formatAgeSec(9.0) == "9s"
    check formatAgeSec(300.0) == "5m"
    check formatAgeSec(4500.0) == "1h15m"

  test "wedged seats render a red light and a red row":
    let rows = renderSeatWatchRows(@[
      SeatWatch(name: "Tusk", state: "wedged", pidAlive: true, hasStatus: true,
                statusAgeSec: 240.0, lastActionAgeSec: -1.0),
      SeatWatch(name: "Beru", state: "running", pidAlive: true, hasStatus: true,
                statusAgeSec: 2.0, lastActionAgeSec: -1.0)
    ])
    check "row-dead" in rows
    check "dot bad" in rows
    check "dot on" in rows

  test "budget exhaustion shows a persistent alert banner":
    let body = renderSeatWatchPanelBody(@[
      SeatWatch(name: "Tusk", state: "wedged", alerting: true, pidAlive: true,
                hasStatus: true, statusAgeSec: 900.0, restarts: 3,
                lastActionAgeSec: 12.0)
    ])
    check "Auto-restart paused" in body
    check "Tusk" in body

proc writeFakeRoot(root, seat: string, statusAgeSec: int) =
  ## A disposable army root: fake Makefile targets that only touch files under
  ## `root`, plus a seat dir that looks wedged (live pid, frozen status.json).
  let seatDir = root / "local_data" / "home-army" / seat
  createDir(seatDir / "status")
  writeFile(root / "Makefile", """
shadowfel-start:
	@touch $(CURDIR)/start-called
	@echo fake start

shadowfel-stop:
	@touch $(CURDIR)/stop-called
	@rm -f $(CURDIR)/local_data/home-army/Shadowfel/launcher.pid
	@echo fake stop
""")
  # The test process itself is the "live launcher": guaranteed alive, and the
  # fake stop target only removes a pid FILE — it never signals anything.
  writeFile(seatDir / "launcher.pid", $getCurrentProcessId() & "\n")
  var log = ""
  for i in 1 .. 120:
    log.add(&"launcher line {i}: http fetch failed (Connection was closed)\n")
  writeFile(seatDir / "launcher.log", log)
  let statusPath = seatDir / "status" / "status.json"
  writeFile(statusPath, """{"bot":{"mode":"home"}}""")
  let old = getTime() - initDuration(seconds = statusAgeSec)
  setLastModificationTime(statusPath, old)

suite "babysitSeatsOnce (throwaway army root)":
  test "wedged seat: evidence first, then a bounded restart":
    let root = getTempDir() / "sa-seat-watch-test-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeFakeRoot(root, "Shadowfel", 600)
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "1")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    babysitSeatsOnce()

    let seats = seatWatchStatus()
    check seats.len == 4
    check seats[0].name == "Shadowfel"
    check seats[0].state == "wedged"
    check seats[0].pidAlive
    check seats[0].statusAgeSec > 60.0
    # Seats without a runtime dir stay quiet — no restarts, no alerts.
    for s in seats[1 .. ^1]:
      check s.state == "stopped"
      check s.restarts == 0
      check not s.alerting

    # Evidence landed in the seat dir BEFORE recovery, with the launcher tail.
    let seatDir = root / "local_data" / "home-army" / "Shadowfel"
    check seats[0].evidence.startsWith("wedge-")
    let evidence = readFile(seatDir / seats[0].evidence)
    check "# wedge evidence: Shadowfel" in evidence
    check "launcher line 120" in evidence
    check "launcher line 71" in evidence
    check "launcher line 70" notin evidence # exactly the last 50 lines

    # The restart went through the Makefile lifecycle, in the fake root only.
    check seats[0].restarts == 1
    check fileExists(root / "local_data" / "seat-watch.json")
    if findExe("make").len > 0:
      check fileExists(root / "stop-called")
      check fileExists(root / "start-called")
      check "auto-restart" in seats[0].lastAction

    # The dashboard event tail carries the wedge line.
    var sawWedge = false
    for e in recentEvents(limit = 20):
      if e.name == "Shadowfel" and e.kind == "wedge":
        sawWedge = true
    check sawWedge

  test "observe-only mode detects but never restarts":
    let root = getTempDir() / "sa-seat-watch-obs-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeFakeRoot(root, "Shadowfel", 600)
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "0")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    check not seatBabysitterEnabled()
    babysitSeatsOnce()
    let seats = seatWatchStatus()
    check seats[0].state == "wedged"
    check not fileExists(root / "stop-called")
    check not fileExists(root / "start-called")
