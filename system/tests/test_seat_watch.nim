## Unit tests for the seat babysitter (ticket 0055): staleness classification,
## the restart budget, evidence capture, roster (scale-out) coverage, and full
## recovery passes driven against a THROWAWAY army root.
## Run: nim r --hints:off --warnings:off system/tests/test_seat_watch.nim
##
## No network, no docker, no realm. The recovery pass points SYSTEM_ARMY_DIR at
## a temp dir with a fake Makefile, so the real home seats are never signalled:
## the make targets exercised here only touch files under that temp root.

import
  std/[json, os, strformat, strutils, times, unittest],
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

  test "stale status with fresh chatter is starting":
    check classifySeat(true, true, 91.0, chatterAgeSec = 3.0) == "starting"

  test "stale status with stale chatter is wedged":
    check classifySeat(true, true, 91.0, chatterAgeSec = 91.0) == "wedged"

  test "stale status with missing chatter is wedged":
    check classifySeat(true, true, 91.0, chatterAgeSec = -1.0) == "wedged"

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

  test "a stalled watch thread is called out, not papered over":
    # The sampler runs recoveries inline, so one hung child stops the whole
    # watch. Silence there is what produced a panel full of confident green
    # rows while nothing was being restarted.
    let seats = @[
      SeatWatch(name: "Beru", state: "running", pidAlive: true, hasStatus: true,
                statusAgeSec: 0.0, lastActionAgeSec: -1.0)
    ]
    check "STALLED" notin seatWatchSummary(seats)
    check "STALLED" notin seatWatchSummary(seats, passAgeSec = 12.0)
    let stalled = seatWatchSummary(seats, passAgeSec = SeatWatchStallSec + 600.0)
    check "STALLED" in stalled
    let body = renderSeatWatchPanelBody(seats, SeatWatchStallSec + 600.0)
    check "Seat watch STALLED" in body
    check "seat-alert" in body
    check "Seat watch STALLED" notin renderSeatWatchPanelBody(seats)

  test "budget exhaustion shows a persistent alert banner":
    let body = renderSeatWatchPanelBody(@[
      SeatWatch(name: "Tusk", state: "wedged", alerting: true, pidAlive: true,
                hasStatus: true, statusAgeSec: 900.0, restarts: 3,
                lastActionAgeSec: 12.0)
    ])
    check "Auto-restart paused" in body
    check "Tusk" in body

proc writeWedgedSeat(root, seat: string, statusAgeSec: int) =
  ## A seat dir that looks wedged: live pid, frozen status.json, frozen log.
  let seatDir = root / "local_data" / "home-army" / seat
  createDir(seatDir / "status")
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
  setLastModificationTime(seatDir / "launcher.log", old)

proc seatNamed(seats: seq[SeatWatch], name: string): SeatWatch =
  ## Pick one seat out of the babysitter view by name (order-independent).
  for w in seats:
    if w.name == name:
      return w
  result = SeatWatch(name: "")

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
  writeWedgedSeat(root, seat, statusAgeSec)

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

# ---------------------------------------------------------------------------
# Scale-out roster coverage: the 15 roster seats wedge with the same signature
# as the original four, and recover through the PARAMETERIZED make targets.
# ---------------------------------------------------------------------------

suite "parseSeatRoster":
  test "tab rows become scaled targets, comments and blanks skipped":
    let targets = parseSeatRoster("""
# Columns: character	account	class
Bellion	shadow5	mage

Iron	shadow10	warrior
""")
    check targets.len == 2
    check targets[0].name == "Bellion"
    check targets[0].account == "shadow5"
    check targets[0].class == "mage"
    check targets[0].scaled
    check targets[1].name == "Iron"

  test "protected seats are never roster-driven":
    # The original four keep their dedicated targets; Kaisel/Murist are never
    # watched at all. A roster row naming one of them is ignored, not obeyed.
    let targets = parseSeatRoster(
      "Shadowfel\tshadow1\twarrior\nKaisel\tshadow9\trogue\n" &
      "Murist\tmurist\tmage\nIron\tshadow10\twarrior\n")
    check targets.len == 1
    check targets[0].name == "Iron"

  test "malformed and unsafe rows are dropped":
    let targets = parseSeatRoster(
      "NoTabsHere\n" &
      "Short\tshadow5\n" &
      "Rm -rf\tshadow5\tmage\n" &
      "Evil;touch pwned\tshadow5\tmage\n" &
      "Iron\tshadow10\twarrior\n" &
      "Iron\tshadow99\tmage\n")
    check targets.len == 1
    check targets[0].name == "Iron"

proc writeScaledRoot(root: string, rosterRows: string) =
  ## Throwaway army root with the PARAMETERIZED seat targets. They only append
  ## to a log file under `root` and delete a pid FILE — nothing is signalled.
  createDir(root / "tools" / "data")
  writeFile(root / "tools" / "data" / "home_army_roster.tsv", rosterRows)
  writeFile(root / "Makefile", """
seat-start:
	@echo "$(SEAT) $(SEAT_USER) $(SEAT_CLASS)" >> $(CURDIR)/seat-start-called

seat-stop:
	@echo "$(SEAT)" >> $(CURDIR)/seat-stop-called
	@rm -f $(CURDIR)/local_data/home-army/$(SEAT)/launcher.pid
""")

proc calledLines(path: string): seq[string] =
  result = @[]
  if fileExists(path):
    for line in readFile(path).strip().splitLines():
      if line.len > 0:
        result.add(line)

suite "roster seats (throwaway army root)":
  test "wedged roster seat: evidence first, then a parameterized restart":
    let root = getTempDir() / "sa-seat-watch-scaled-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeScaledRoot(root, "Ironx\tshadow10\twarrior\n")
    writeWedgedSeat(root, "Ironx", 600)
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "1")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    babysitSeatsOnce()

    let seats = seatWatchStatus()
    # Four dedicated seats + every roster row.
    check seats.len == 5
    let iron = seatNamed(seats, "Ironx")
    check iron.state == "wedged"
    check iron.scaled
    check iron.pidAlive
    check iron.restarts == 1

    # Evidence landed in the seat dir BEFORE recovery rotated launcher.log.
    check iron.evidence.startsWith("wedge-")
    let evidence = readFile(
      root / "local_data" / "home-army" / "Ironx" / iron.evidence)
    check "# wedge evidence: Ironx" in evidence
    check "launcher line 120" in evidence
    check "launcher line 70" notin evidence # exactly the last 50 lines

    # Recovery went through `seat-stop SEAT=…` then
    # `seat-start SEAT=… SEAT_USER=… SEAT_CLASS=…`, in the fake root only.
    if findExe("make").len > 0:
      check calledLines(root / "seat-stop-called") == @["Ironx"]
      check calledLines(root / "seat-start-called") == @["Ironx shadow10 warrior"]
      check "auto-restart" in iron.lastAction

    # The dashboard event tail carries the wedge line for the roster seat.
    var sawWedge = false
    for e in recentEvents(limit = 40):
      if e.name == "Ironx" and e.kind == "wedge":
        sawWedge = true
    check sawWedge

  test "roster is re-read when its mtime moves (seats added mid-run)":
    let root = getTempDir() / "sa-seat-watch-reload-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeScaledRoot(root, "Onex\tshadow21\tmage\n")
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "1")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    babysitSeatsOnce()
    check scaledSeatTargets().len == 1
    check seatWatchStatus().len == 5
    check seatNamed(seatWatchStatus(), "Twox").name == ""

    # The roster grows (a new seat provisioned) — no dashboard restart.
    let rosterPath = root / "tools" / "data" / "home_army_roster.tsv"
    writeFile(rosterPath, "Onex\tshadow21\tmage\nTwox\tshadow22\trogue\n")
    setLastModificationTime(rosterPath, getTime() + initDuration(seconds = 5))

    babysitSeatsOnce()
    check scaledSeatTargets().len == 2
    let seats = seatWatchStatus()
    check seats.len == 6
    let two = seatNamed(seats, "Twox")
    check two.name == "Twox"
    check two.scaled
    check two.state == "stopped" # no launcher pid → nothing to do
    check two.restarts == 0
    check not fileExists(root / "seat-start-called") # nobody was touched

  test "restart budget and cooldown are per seat, and survive a restart":
    let root = getTempDir() / "sa-seat-watch-budget-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeScaledRoot(root,
      "Spentx\tshadow23\tmage\nFreshx\tshadow24\trogue\nCooldx\tshadow25\tpriest\n")
    for seat in ["Spentx", "Freshx", "Cooldx"]:
      writeWedgedSeat(root, seat, 600)
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "1")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    # Persisted state from a previous dashboard life: Spentx burned its budget,
    # Cooldx has a restart still landing (lastActionAt inside the cooldown).
    let now = epochTime()
    createDir(root / "local_data")
    writeFile(root / "local_data" / "seat-watch.json", $ %*{
      "seats": {
        "Spentx": {
          "restarts": [now - 30.0, now - 60.0, now - 90.0],
          "alerting": false, "last_action_at": 0.0, "last_action": ""
        },
        "Cooldx": {
          "restarts": [], "alerting": false,
          "last_action_at": now - 20.0, "last_action": "restarting (wedged)"
        }
      }
    })

    babysitSeatsOnce()

    let seats = seatWatchStatus()
    let
      spent = seatNamed(seats, "Spentx")
      fresh = seatNamed(seats, "Freshx")
      cool = seatNamed(seats, "Cooldx")
    check spent.state == "wedged"
    check fresh.state == "wedged"
    check cool.state == "wedged"
    # Budget is per seat name: a spent neighbour never blocks a healthy one.
    check spent.alerting
    check spent.restarts == 3
    check not fresh.alerting
    check fresh.restarts == 1
    # Persisted lastActionAt still holds the cooldown across the restart.
    check not cool.alerting
    check cool.restarts == 0
    if findExe("make").len > 0:
      check calledLines(root / "seat-start-called") == @["Freshx shadow24 rogue"]
      check calledLines(root / "seat-stop-called") == @["Freshx"]
    # The budget window is re-persisted, including the cooldown stamp.
    let saved = parseJson(readFile(root / "local_data" / "seat-watch.json"))
    check saved["seats"]["Freshx"]["restarts"].len == 1
    check saved["seats"]["Freshx"]["last_action_at"].getFloat(0.0) > 0
    check saved["seats"]["Spentx"]["alerting"].getBool(false)

# ---------------------------------------------------------------------------
# Field defect (0055 v2, first night): the panel showed seats "running 0s"
# while their status.json mtime was minutes stale — dedicated AND scaled, a
# scattered subset — so classifySeat never said wedged and nothing recovered.
# Cause: the babysitter samples on a background thread and the panel served
# whatever that thread last stored. When the thread stalled (a detached
# `make seat-start` held the capture pipe open, so runShell never returned),
# every stored age froze at its last-good value and the panel reported healthy
# forever. These tests pin the two invariants that make that unrepresentable.
# ---------------------------------------------------------------------------

proc restampSeat(root, seat: string, ageSec: int) =
  ## Re-date status.json and launcher.log to look `ageSec` old.
  let seatDir = root / "local_data" / "home-army" / seat
  let old = getTime() - initDuration(seconds = ageSec)
  setLastModificationTime(seatDir / "status" / "status.json", old)
  setLastModificationTime(seatDir / "launcher.log", old)

suite "heartbeat age is read live, never served from a stale snapshot":
  test "a seat that goes stale AFTER the last pass still reads wedged":
    # This is the field defect exactly: no further sampling pass runs (the
    # watch thread is hung), yet the panel must report what is on disk NOW.
    let root = getTempDir() / "sa-seat-watch-live-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeScaledRoot(root,
      "Livealphax\tshadow31\tmage\nLivebravox\tshadow32\trogue\n" &
      "Livecharlx\tshadow33\tpriest\n")
    for seat in ["Livealphax", "Livebravox", "Livecharlx"]:
      writeWedgedSeat(root, seat, 0) # live pid, FRESH status.json
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "0") # observe only: no restarts to race
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    babysitSeatsOnce()
    for seat in ["Livealphax", "Livebravox", "Livecharlx"]:
      check seatNamed(seatWatchStatus(), seat).state == "running"

    # The MIDDLE seat's client wedges. No sampling pass follows — the watch
    # thread is stuck — so the only thing that can save us is reading the
    # file at render time.
    restampSeat(root, "Livebravox", 600)

    let seats = seatWatchStatus()
    let bravo = seatNamed(seats, "Livebravox")
    check bravo.state == "wedged"
    check bravo.statusAgeSec > 60.0
    check bravo.hasStatus
    # Its neighbours are untouched: the stale read is attributed to one seat.
    check seatNamed(seats, "Livealphax").state == "running"
    check seatNamed(seats, "Livealphax").statusAgeSec < 60.0
    check seatNamed(seats, "Livecharlx").state == "running"
    check seatNamed(seats, "Livecharlx").statusAgeSec < 60.0

    # And the panel the human reads says so, in the row and in the summary.
    let body = renderSeatWatchPanelBody(seats)
    check "row-dead" in body
    check "1 wedged" in body

  test "seatHeartbeatAge reports the seat named, missing files included":
    let root = getTempDir() / "sa-seat-watch-hb-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeScaledRoot(root, "Hbonex\tshadow34\tmage\n")
    writeWedgedSeat(root, "Hbonex", 300)
    putEnv("SYSTEM_ARMY_DIR", root)
    defer: delEnv("SYSTEM_ARMY_DIR")

    let hit = seatHeartbeatAge("Hbonex")
    check hit.hasStatus
    check hit.ageSec > 290.0
    check hit.ageSec < 400.0
    let miss = seatHeartbeatAge("Nobodyx")
    check not miss.hasStatus
    check miss.ageSec == -1.0

suite "roster reload never shifts age attribution":
  test "a seat inserted at the FRONT does not move the stale read":
    # Every seat's index changes; the wedged seat must stay the wedged seat.
    # An index-keyed age would blame its neighbour instead — the "scattered,
    # intermittent" misread the field notes describe.
    let root = getTempDir() / "sa-seat-watch-shift-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let rosterPath = root / "tools" / "data" / "home_army_roster.tsv"
    writeScaledRoot(root,
      "Shiftalphax\tshadow41\tmage\nShiftbravox\tshadow42\trogue\n" &
      "Shiftcharlx\tshadow43\tpriest\n")
    for seat in ["Shiftalphax", "Shiftbravox", "Shiftcharlx"]:
      writeWedgedSeat(root, seat, 0)
    restampSeat(root, "Shiftbravox", 600) # the middle seat is the wedged one
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "0")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    babysitSeatsOnce()
    var seats = seatWatchStatus()
    check seatNamed(seats, "Shiftalphax").state == "running"
    check seatNamed(seats, "Shiftbravox").state == "wedged"
    check seatNamed(seats, "Shiftcharlx").state == "running"

    # The roster is rewritten with a new seat FIRST — every later index moves.
    writeFile(rosterPath,
      "Shiftzerox\tshadow40\twarrior\nShiftalphax\tshadow41\tmage\n" &
      "Shiftbravox\tshadow42\trogue\nShiftcharlx\tshadow43\tpriest\n")
    setLastModificationTime(rosterPath, getTime() + initDuration(seconds = 5))
    writeWedgedSeat(root, "Shiftzerox", 0)

    babysitSeatsOnce()
    seats = seatWatchStatus()
    check seats.len == 8 # four dedicated + four roster seats
    check seatNamed(seats, "Shiftzerox").state == "running"
    check seatNamed(seats, "Shiftalphax").state == "running"
    check seatNamed(seats, "Shiftbravox").state == "wedged"
    check seatNamed(seats, "Shiftcharlx").state == "running"
    # Exactly one seat is wedged — no neighbour inherited the stale age.
    var wedged: seq[string] = @[]
    for w in seats:
      if w.state == "wedged":
        wedged.add(w.name)
    check wedged == @["Shiftbravox"]

suite "runShell survives a child that detaches and keeps stdout":
  test "a backgrounded grandchild holding stdout does not block the caller":
    # The exact hang that froze the babysitter: `make seat-start` detaches a
    # long-lived launcher which inherits the capture handle. Reading a PIPE
    # that child still holds never sees EOF, so runShell blocked until the
    # SEAT exited. Capturing through a file makes the wait bounded by the
    # direct child only. A sleeping grandchild outlives this call by design.
    let root = getTempDir() / "sa-seat-watch-detach-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeScaledRoot(root, "Detachx\tshadow44\tmage\n")
    # seat-start that behaves like the real one: it leaves a detached child
    # running long past the make invocation, and that child INHERITS the
    # capture handle (no redirection) exactly as the real launcher does.
    writeFile(root / "Makefile", """
seat-start:
	@echo "$(SEAT) $(SEAT_USER) $(SEAT_CLASS)" >> $(CURDIR)/seat-start-called
	@sleep 45 &

seat-stop:
	@echo "$(SEAT)" >> $(CURDIR)/seat-stop-called
	@rm -f $(CURDIR)/local_data/home-army/$(SEAT)/launcher.pid
""")
    writeWedgedSeat(root, "Detachx", 600)
    putEnv("SYSTEM_ARMY_DIR", root)
    putEnv("SYSTEM_SEAT_STALE_SEC", "60")
    putEnv("SYSTEM_SEAT_BABYSITTER", "1")
    defer:
      delEnv("SYSTEM_ARMY_DIR")
      delEnv("SYSTEM_SEAT_STALE_SEC")
      delEnv("SYSTEM_SEAT_BABYSITTER")

    if findExe("make").len == 0:
      skip()
    else:
      let began = epochTime()
      babysitSeatsOnce()
      let elapsed = epochTime() - began
      # Before the fix this waited on the detached `sleep 45` (readAll on a
      # pipe the grandchild still held); now it returns when `make` exits.
      check elapsed < 20.0
      # The recovery really ran both halves — it did not just time out.
      check calledLines(root / "seat-stop-called") == @["Detachx"]
      check calledLines(root / "seat-start-called") == @["Detachx shadow44 mage"]
      let seat = seatNamed(seatWatchStatus(), "Detachx")
      check seat.restarts == 1
      check "auto-restart" in seat.lastAction

      # And a completed pass is stamped, so the panel knows the watch is alive.
      check seatWatchPassAgeSec() >= 0.0
      check seatWatchPassAgeSec() < SeatWatchStallSec
