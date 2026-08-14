## Pure unit tests for the conductor eval gate + ledger (no network,
## no docker, no make). Fixture-driven: RunReports as JSON, a synthetic
## FLIGHT log for the northing parser.
## Run: nim r --hints:off --warnings:off tools/tests/test_conductor_gate.nim

import std/[json, options, os, sequtils, sets, strutils]
import ../../src/conductor/cfg
import ../../src/conductor/evalgate
import ../../src/conductor/ledger
import ../../src/conductor/shiplib

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

let tmp = getTempDir() / "conductor-gate-test-" & $getCurrentProcessId()
createDir(tmp)

# --- computeMaxNorthing from FLIGHT lines ---
let logPath = tmp / "run.log"
writeFile(logPath, """
noise line
FLIGHT {"t":1.0,"x":-9187.0,"y":-2530.0,"hp":2754}
FLIGHT {"t":2.0,"x":-6784.5,"y":-4833.9,"hp":2700}
petrel: FLIGHT {"t":3.0,"x":-1081.4,"y":-3000.0,"hp":2000}
FLIGHT {"t":4.0,"x":-4000.0,"y":-4000.0,"hp":1500}
FLIGHT not-json
FLIGHT {"t":5.0,"y":-1.0}
""")
let northing = computeMaxNorthing(logPath)
check(abs(northing - 8105.6) < 0.01, "max northing from best sample")
check(computeMaxNorthing(tmp / "missing.log") == 0.0, "missing log -> 0")
check(countFlightSamples(logPath) == 4, "valid FLIGHT samples counted")
check(countFlightSamples(tmp / "missing.log") == 0, "missing log -> 0 samples")

# --- jsonNumber dot paths ---
let report = parseJson("""
{"ok": true, "deaths": 0, "max_northing": 10204.0,
 "scorecard": {"fat_min": 0.8, "fatigue_s": 12.5,
   "events": {"counts": {"form_lost": 3}},
   "snags": {"total": 2},
   "warnings": ["WARN pace: 0.61 of expected", "WARN hp: worst bin 900"]}}
""")
check(jsonNumber(report, "max_northing").get() == 10204.0, "top-level number")
check(jsonNumber(report, "scorecard.events.counts.form_lost").get() == 3.0,
  "deep dot path")
check(jsonNumber(report, "scorecard.nope").isNone, "missing path -> none")
check(jsonNumber(report, "ok").isNone, "bool -> none")

# --- warning classes ---
check(warningClasses(report) ==
  toHashSet(["WARN pace", "WARN hp"]), "warning classes strip detail")

# --- gate: league config used by all gate cases ---
var lc = LeagueConfig(floorMetric: "max_northing")
lc.assertions = @[
  GateAssertion(field: "deaths", op: "<=", vsChampion: true),
  GateAssertion(field: "scorecard.fat_min", op: ">=", vsChampion: true),
]

# no champion -> pass (baseline seeding)
var verdict = runGate(report, nil, lc)
check(verdict.pass, "nil champion passes for seeding")

# candidate == champion -> pass
verdict = runGate(report, report, lc)
check(verdict.pass, "self-comparison passes")

# floor regress -> fail
var worse = report.copy()
worse["max_northing"] = %9000.0
verdict = runGate(worse, report, lc)
check(not verdict.pass, "floor regress fails")
check(verdict.reasons.anyIt(it.contains("floor regress")),
  "floor reason recorded")

# assertion fail: more deaths than champion
var deadly = report.copy()
deadly["deaths"] = %2
verdict = runGate(deadly, report, lc)
check(not verdict.pass, "deaths regress fails")

# new warning class without floor progress -> fail
var noisy = report.copy()
noisy["scorecard"]["warnings"].add(%"WARN fatigue: [DEATH-BAND] min bar 0.1")
verdict = runGate(noisy, report, lc)
check(not verdict.pass, "new warning class fails")
check(verdict.reasons.anyIt(it.contains("WARN fatigue")),
  "new class named in reasons")

# new warning class WITH strict floor progress -> tolerated (extent bias:
# further runs meet new terrain and its warnings)
var explorer = noisy.copy()
explorer["max_northing"] = %13000.0
verdict = runGate(explorer, report, lc)
check(verdict.pass, "new class tolerated when floor strictly improves")
check(verdict.reasons.anyIt(it.contains("note: new warning class")),
  "tolerated class still noted")

# champion missing an assertion field -> falls back to fixed value
var oldChampion = report.copy()
oldChampion["scorecard"].delete("fat_min")
var candGood = report.copy()
verdict = runGate(candGood, oldChampion, lc)
check(verdict.pass, "champion missing field falls back to assertion value")

# candidate missing floor metric -> fail
var blind = report.copy()
blind.delete("max_northing")
verdict = runGate(blind, report, lc)
check(not verdict.pass, "candidate missing floor fails")

# improvement passes
var better = report.copy()
better["max_northing"] = %12000.0
verdict = runGate(better, report, lc)
check(verdict.pass, "strict improvement passes")

# duration normalization: a run surviving 2x as long with the same RATE
# of form losses must pass a perDurationS assertion, and fail without it.
var lcRate = LeagueConfig(floorMetric: "max_northing")
lcRate.assertions = @[GateAssertion(field: "scorecard.events.counts.form_lost",
  op: "<=", vsChampion: true, perDurationS: true)]
var champShort = report.copy()
champShort["scorecard"]["duration_s"] = %1000.0   # 3 losses / ks
var candLong = report.copy()
candLong["scorecard"]["duration_s"] = %2000.0
candLong["scorecard"]["events"]["counts"]["form_lost"] = %5  # 2.5 / ks
candLong["max_northing"] = %12000.0
verdict = runGate(candLong, champShort, lcRate)
check(verdict.pass, "longer run with better rate passes perDurationS")
var lcAbs = lcRate
lcAbs.assertions[0].perDurationS = false
verdict = runGate(candLong, champShort, lcAbs)
check(not verdict.pass, "absolute comparison still fails (duration bias)")

# --- ledger ---
let lpath = tmp / "scores" / "traverse.jsonl"
check(champion(lpath).isNil, "empty ledger has no champion")
appendRow(lpath, makeRow("traverse", "baseline", "", "monofuel/traverse",
  %*{"wsa": "abc"}, report, %*{"pass": true}))
appendRow(lpath, makeRow("traverse", "parked", "0042", "exp",
  %*{"wsa": "def"}, worse, %*{"pass": false}))
var champ = champion(lpath)
check(not champ.isNil and champ{"action"}.getStr() == "baseline",
  "parked rows never become champion")
appendRow(lpath, makeRow("traverse", "merged", "0043", "exp2",
  %*{"wsa": "ghi"}, better, %*{"pass": true}))
champ = champion(lpath)
check(champ{"action"}.getStr() == "merged", "merged row becomes champion")
check(champ{"report", "max_northing"}.getFloat() == 12000.0,
  "champion carries its report")
check(lastShipped(lpath).isNil, "no shipped row yet")
# tooling-only merges (no run telemetry) never become champion
appendRow(lpath, makeRow("traverse", "merged", "0099", "tool",
  %*{"wsa": "jkl"}, %*{"tooling_only": true}, %*{"pass": true}))
check(champion(lpath){"report", "max_northing"}.getFloat() == 12000.0,
  "tooling-only merge does not steal the champion pointer")
# torn tail line must not wedge reads
let f = open(lpath, fmAppend)
f.write("{\"torn\": ")
f.close()
check(champion(lpath){"action"}.getStr() == "merged",
  "torn tail line ignored")

# --- ship ratchet: absolute minNorthing mode (monofuel's 8.6k rule) ---
# Fixture: empty ticket tree (no death tickets), a lane ledger with one
# shipped row carrying a policy_version_id for the guard chain.
let shipRoot = tmp / "ship-root"
createDir(shipRoot / "tickets" / "open")
createDir(shipRoot / "tickets" / "in-progress")
let shipLane = shipRoot / "lane"
createDir(shipLane)
var shippedRow = makeRow("traverse", "shipped", "", "monofuel/traverse",
  %*{"wsa": "aaa"}, report, %*{"pass": true})
shippedRow["ship"] = %*{"policy_version_id": "ver-123"}
appendRow(ledgerPath(shipLane, "traverse"), shippedRow)
var lcShip = LeagueConfig(floorMetric: "max_northing",
  ticketLane: "traverse")
lcShip.ship.minNorthing = 8600.0
var candidate9k = report.copy()
candidate9k["max_northing"] = %9000.0
var ratchet = shipRatchet(shipRoot, lcShip, shipLane, candidate9k)
check(ratchet.ok, "minNorthing mode ships a 9k candidate (guard vs " &
  "last-shipped axes bypassed)")
var candidate8k = report.copy()
candidate8k["max_northing"] = %8100.0
ratchet = shipRatchet(shipRoot, lcShip, shipLane, candidate8k)
check(not ratchet.ok, "minNorthing mode refuses below the absolute floor")
check(ratchet.why.contains("minNorthing"), "refusal names the floor")
# without minNorthing the old vs-last-shipped gate applies (9k < shipped
# 10204 floor -> refused)
lcShip.ship.minNorthing = 0.0
ratchet = shipRatchet(shipRoot, lcShip, shipLane, candidate9k)
check(not ratchet.ok, "legacy mode still gates vs last-shipped floor")

removeDir(tmp)
echo "test_conductor_gate: ", passed, " ok"
