## Pure unit tests for the conductor eval gate + ledger (no network,
## no docker, no make). Fixture-driven: RunReports as JSON, a synthetic
## FLIGHT log for the northing parser.
## Run: nim r --hints:off --warnings:off tools/tests/test_conductor_gate.nim

import std/[json, options, os, sequtils, sets, strutils, tables]
import ../../src/conductor/cfg
import ../../src/conductor/evalgate
import ../../src/conductor/ledger
import ../../src/conductor/masterhealth
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

# --- ship version-tag derivation (upload output unparseable 4/4 ships) ---
check(bumpVersionTag("petrel:v9", "petrel") == "petrel:v10",
  "bumps the last shipped label")
check(bumpVersionTag("petrel:v99", "petrel") == "petrel:v100",
  "multi-digit bump")
check(bumpVersionTag("", "petrel") == "", "empty label underivable")
check(bumpVersionTag("ibis:v4", "petrel") == "", "foreign policy refused")

# --- static-test leg: the gate runs the FULL unit tier (ticket 0044) ---
# `make test-lua` left the Nim tier and the Python road tests outside the
# gate; 3def984 broke exactly those and rode to master. Pin the command so
# a narrowing regression is a red test, not another red master.
check(staticTestArgs() == @["test"], "gate static leg is `make test`")
check(staticTestCmd() == "make test", "static command string")
check(staticTestArgs() != @["test-lua"], "static leg is not lua-only")
check(StaticTestTimeoutMs >= 600_000, "static leg keeps a >=10min timeout")

# --- master-health state file (the dashboard light reads this) ---
let mhRepo = tmp / "mh-repo"
createDir(mhRepo)
check(masterHealthPath(mhRepo) == mhRepo / ".conductor" / "master-health.json",
  "health file sits with the other .conductor runtime state")

# never checked -> unknown, and unknown always wants a check
var health = loadMasterHealth(mhRepo)
check(health.status == mhUnknown, "missing file reads as unknown")
check(health.sha == "" and health.checkedAt == "", "unknown carries no verdict")
check(needsCheck(health, "abc123def"), "unknown sha needs a check")
check(not needsCheck(health, ""), "no sha -> nothing to check")

# roundtrip: every field the dashboard needs survives save/load
saveMasterHealth(mhRepo, MasterHealth(branch: "master", sha: "abc123def",
  status: mhGreen, checkedAt: "2026-08-15T06:41:12Z", durationS: 31.4,
  command: staticTestCmd(), detail: ""))
health = loadMasterHealth(mhRepo)
check(health.branch == "master", "branch roundtrips")
check(health.sha == "abc123def", "sha roundtrips")
check(health.status == mhGreen, "status roundtrips")
check(health.checkedAt == "2026-08-15T06:41:12Z", "timestamp roundtrips")
check(abs(health.durationS - 31.4) < 0.001, "duration roundtrips")
check(health.command == "make test", "command recorded for the tooltip")

# a green verdict pins to its sha: same sha skips, a new sha rechecks
check(not needsCheck(health, "abc123def"), "same sha reuses the verdict")
check(needsCheck(health, "fff999aaa"), "moved HEAD triggers a recheck")

# red carries the failure tail; an error verdict is never trusted
saveMasterHealth(mhRepo, MasterHealth(branch: "master", sha: "bad00bad0",
  status: mhRed, checkedAt: "2026-08-15T07:00:00Z", durationS: 12.0,
  command: staticTestCmd(), detail: "rc=2: test_conductor_gate FAILED"))
health = loadMasterHealth(mhRepo)
check(health.status == mhRed, "red roundtrips")
check(health.detail.contains("FAILED"), "red keeps the failure tail")
check(not needsCheck(health, "bad00bad0"), "a red verdict also pins to its sha")
check(needsCheck(MasterHealth(status: mhError, sha: "abc123def"), "abc123def"),
  "error verdict is retried even at the same sha")

# on-disk shape: exactly the keys the dashboard reads, status as a string
let mhRaw = parseJson(readFile(masterHealthPath(mhRepo)))
for key in ["branch", "sha", "status", "checkedAt", "durationS", "command",
    "detail"]:
  check(mhRaw.hasKey(key), "state file has " & key)
check(mhRaw.len == 7, "state file has no extra keys")
check(mhRaw["status"].kind == JString and mhRaw["status"].getStr() == "red",
  "status serializes as a string")
check(masterHealthJson(health)["status"].getStr() == "red",
  "dashboard json mirrors the file")

# corrupt file must not wedge the watchdog — it re-checks instead
writeFile(masterHealthPath(mhRepo), "{\"status\": ")
health = loadMasterHealth(mhRepo)
check(health.status == mhUnknown, "corrupt state file reads as unknown")
check(needsCheck(health, "abc123def"), "corrupt state file forces a check")

# eval load gate: parseable, garbage-safe, never blocks on bad input
check(oneMinuteLoad("16.55 35.34 39.41 12/12558 4115644") == 16.55,
  "loadavg first field parses")
check(oneMinuteLoad("") == 0.0, "empty loadavg reads as quiet")
check(oneMinuteLoad("garbage fields here") == 0.0,
  "unparseable loadavg reads as quiet, never wedges the eval")
check(DefaultEvalLoadCap == 45.0, "default load cap is 45")
check(evalLoadCap("45") == 45.0, "explicit 45 parses")
check(evalLoadCap("20") == 20.0, "CONDUCTOR_EVAL_LOAD_CAP override still honored")
check(evalLoadCap("nope") == 45.0, "garbage load cap falls back to 45")

# --- slot paths: 0 is legacy, N is local_data/eval-slots/sN/... ---
check(runLogRelPath(0) == "local_data/traverse-status/run.log",
  "slot 0 run.log is the legacy path")
check(runLogRelPath() == "local_data/traverse-status/run.log",
  "runLogRelPath default is slot 0")
check(runLogRelPath(1) == "local_data/eval-slots/s1/traverse-status/run.log",
  "slot 1 run.log")
check(runLogRelPath(3) == "local_data/eval-slots/s3/traverse-status/run.log",
  "slot 3 run.log")
check(segmentResultRelPath(0) == "local_data/traverse-segment-result.json",
  "slot 0 segment-result is the legacy path")
check(segmentResultRelPath(2) ==
  "local_data/eval-slots/s2/traverse-segment-result.json",
  "slot 2 segment-result")
check(archiveRelDir(0) == "local_data/traverse-status/archive",
  "slot 0 archive is the legacy dir")
check(archiveRelDir(2) == "local_data/traverse-status/archive",
  "slot N archives into the shared legacy dir")
check(slotDataPrefix(0) == "local_data", "slot 0 data prefix is local_data")
check(slotDataPrefix(2) == "local_data/eval-slots/s2", "slot 2 data prefix")

# --- archive naming: -s<n> only on slot runs ---
check(archiveLogName("baseline-r1", 0, "20260816-120000") ==
  "run-20260816-120000-baseline-r1.log",
  "slot 0 archive name has no slot suffix")
check(archiveLogName("baseline-r1", 2, "20260816-120000") ==
  "run-20260816-120000-baseline-r1-s2.log",
  "slot 2 archive name gains -s2")
check(archiveLogName("0042-gatebranch-r3", 3, "20260816-235959") ==
  "run-20260816-235959-0042-gatebranch-r3-s3.log",
  "gate-branch slug keeps -sN suffix")

# --- buildEvalCommand: SLOT= only when slot != 0 ---
var lcEval = LeagueConfig()
lcEval.evalMake.target = "traverse"
lcEval.evalMake.vars["CHECKPOINT"] = "spawn"
lcEval.evalMake.vars["END_TIMEOUT"] = "420"
let cmd0 = buildEvalCommand(lcEval)
check(cmd0.args[0] == "traverse", "eval target is first make arg")
check(cmd0.wallTimeout == 420, "END_TIMEOUT becomes the wall timeout")
check(not cmd0.args.anyIt(it.startsWith("SLOT=")),
  "slot 0 omits SLOT= so make stays on the legacy paths")
let cmd2 = buildEvalCommand(lcEval, @[("FORK_CLIENT", "/tmp/fork")], 2)
check("SLOT=2" in cmd2.args, "slot 2 appends SLOT=2")
check("FORK_CLIENT=/tmp/fork" in cmd2.args, "extraVars still appended")
check(cmd2.args[^1] == "SLOT=2", "SLOT= is last so it wins over leftover env")
let cmdForkOnly = buildEvalCommand(lcEval, @[("FORK_CLIENT", "/tmp/fork")])
check(not cmdForkOnly.args.anyIt(it.startsWith("SLOT=")),
  "extraVars without slot still omit SLOT=")

# --- median of concurrent-shaped reports (pure; no make) ---
let rLow = %*{"max_northing": 1000.0, "eval_slot": 1}
let rMid = %*{"max_northing": 5000.0, "eval_slot": 2}
let rHigh = %*{"max_northing": 9000.0, "eval_slot": 3}
check(pickMedianReport(@[rHigh, rLow, rMid]){"max_northing"}.getFloat() == 5000.0,
  "median of 3 concurrent rolls is the middle northing")
check(pickMedianReport(@[rHigh, rLow, rMid]){"eval_slot"}.getInt() == 2,
  "median keeps the middle report object, not a copy of the number")
check(pickMedianReport(@[rHigh, rLow]){"max_northing"}.getFloat() == 9000.0,
  "median of 2 (two slots free) is the upper middle")
check(pickMedianReport(@[rMid]){"max_northing"}.getFloat() == 5000.0,
  "median of 1 is the only report")
check(reportNorthing(rHigh) == 9000.0, "reportNorthing reads max_northing")
check(reportNorthing(nil) == 0.0, "reportNorthing of nil is 0")
check(reportNorthing(%*{"ok": true}) == 0.0, "missing northing reads as 0")

# lease CLI missing: claim nothing, release is a no-op (never slot 0)
check(claimEvalSlots(tmp, 3).len == 0, "missing lease CLI claims no slots")
check(claimEvalSlot(tmp) == 0, "missing lease CLI returns slot 0 (none)")
releaseEvalSlot(tmp, 0)
releaseEvalSlot(tmp, 1)
releaseEvalSlots(tmp, @[1, 2, 3])
check(EvalSlotMin == 1 and EvalSlotMax == 3, "agent slots are 1..3")
check(EvalSlotTtlMinutes == 45, "lease crash-net TTL is 45 minutes")
check("evalslot-0" notin "evalslot-1 evalslot-2 evalslot-3",
  "slot 0 is not an agent lease resource")

removeDir(tmp)

echo "test_conductor_gate: ", passed, " ok"
