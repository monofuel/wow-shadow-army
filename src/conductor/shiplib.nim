## Auto-ship: build, upload, and submit the league image behind the
## champion guard — but only past the SHIP RATCHET, which is stricter
## than the merge gate: the candidate must beat the LAST-SHIPPED row
## (not just the local champion) and the lane may have no open
## severity-death tickets (never ship with a known dies/stalls class).
## Sequence per playbooks/upload-bot.md: proof -> freeze -> build ->
## upload -> submit -> readback, in that order, never reordered. Any
## ambiguity stops the ship and raises NEEDS-HUMAN — a skipped ship is
## always safe, the current champion keeps competing.

import
  std/[json, os, strutils],
  scriptorium/git_ops,
  ./cfg,
  ./evalgate,
  ./ledger,
  ./state,
  ./tickets

type ShipOutcome* = object
  shipped*: bool
  detail*: string

proc openDeathTickets*(root, lane: string): seq[string] =
  ## Open or in-progress tickets for the lane tagged **Severity:** death.
  for stateDir in ["open", "in-progress"]:
    for file in walkFiles(root / "tickets" / stateDir / "*.md"):
      let content = readFile(file)
      if laneMatches(content, lane) and
          parseTicketField(content, "Severity").toLowerAscii() == "death":
        result.add(file.extractFilename())

proc cleanTree(dir: string): bool =
  let (rc, output) = gitRunCapture(dir, @["status", "--porcelain"])
  rc == 0 and output.strip().len == 0

proc uvRun(forkDir: string, args: seq[string],
    timeoutMs = 300_000): tuple[exitCode: int, output: string] =
  runCommandCapture(forkDir, "uv", @["run"] & args, timeoutMs)

proc parseVersionTag(output, policy: string): string =
  ## Find "<policy>:vN" in upload output; "" when absent.
  var idx = 0
  while true:
    idx = output.find(policy & ":v", idx)
    if idx < 0:
      return ""
    var stop = idx + policy.len + 2
    while stop < output.len and output[stop] in '0'..'9':
      inc stop
    if stop > idx + policy.len + 2:
      return output[idx ..< stop]
    inc idx

proc parseUuid(output: string): string =
  ## First 8-4-4-4-12 hex UUID in the text; "" when absent.
  const hex = {'0'..'9', 'a'..'f', 'A'..'F'}
  for i in 0 .. output.len - 36:
    var ok = true
    for j in 0 ..< 36:
      let ch = output[i + j]
      if j in [8, 13, 18, 23]:
        if ch != '-': ok = false; break
      elif ch notin hex:
        ok = false; break
    if ok:
      return output[i ..< i + 36].toLowerAscii()
  ""

proc shipRatchet*(root: string, lc: LeagueConfig,
    laneDirPath: string, candidateReport: JsonNode): tuple[ok: bool, why: string] =
  ## Stricter than the merge gate; every clause must hold.
  let deaths = openDeathTickets(root, lc.ticketLane)
  if deaths.len > 0:
    if lc.ship.overrideDeathTickets:
      echo "conductor: WARN ship ratchet ignoring open death tickets (",
        deaths.join(", "), ") — best-of board override (config)"
    else:
      return (false, "open severity-death tickets: " & deaths.join(", "))
  let shipped = lastShipped(ledgerPath(laneDirPath, lc.ticketLane))
  if shipped.isNil:
    return (false, "no last-shipped ledger row — seed one (manual ship " &
      "or a hand-written shipped row) before auto-ship can ratchet")
  if shipped{"ship", "policy_version_id"}.getStr() == "":
    return (false, "last-shipped row has no policy_version_id for the guard")
  if lc.ship.minNorthing > 0:
    # Absolute floor mode (best-of board): any candidate at/above the
    # configured northing ships, regardless of the last-shipped run's
    # axes — the board keeps the max, so a 9k ship after an 11k local
    # fluke is pure upside. Guard chain and death-ticket clause above
    # still apply.
    let northing = candidateReport{"max_northing"}.getFloat()
    if northing < lc.ship.minNorthing:
      return (false, "below ship.minNorthing: " & $northing & " < " &
        $lc.ship.minNorthing)
    return (true, "clears ship.minNorthing " & $lc.ship.minNorthing &
      " (northing " & $northing & ")")
  let verdict = runGate(candidateReport, shipped{"report"}, lc)
  if not verdict.pass:
    return (false, "ship ratchet vs last-shipped: " &
      verdict.reasons.join("; "))
  (true, "beats last-shipped on floor + all assertion axes")

proc executeShip*(root: string, lc: LeagueConfig, repo, laneDirPath: string,
    candidateReport: JsonNode, guardOverride = ""): ShipOutcome =
  ## The playbook sequence. Raises nothing — every failure returns
  ## unshipped with the reason (and flags NEEDS-HUMAN where the playbook
  ## demands a stop).
  let forkDir = root / "monofuel-vanilla-wow"

  # Freeze: clean trees, recorded SHAs (proof = the gate's eval run).
  if not cleanTree(laneDirPath):
    return ShipOutcome(detail: "lane tree dirty — refusing to freeze")
  if not cleanTree(forkDir):
    return ShipOutcome(detail: "fork tree dirty — refusing to freeze")

  # Build (amd64 assert lives in the make target).
  let (rcBuild, outBuild) = runCommandCapture(laneDirPath, "make",
    @["petrel-image"], timeoutMs = 2_400_000)
  if rcBuild != 0:
    return ShipOutcome(detail: "make petrel-image failed: " &
      outBuild[max(0, outBuild.len - 300) .. ^1])

  # Identity: exactly one player or STOP (playbook hard rule).
  let (rcList, outList) = uvRun(forkDir, @["coworld", "player", "list",
    "--json"])
  if rcList != 0:
    return ShipOutcome(detail: "coworld player list failed")
  # Identity pinning (playbook §5 on multi-player accounts): config
  # first, then the CONDUCTOR_PLAYER env, then a solo roster.
  var playerId = lc.ship.playerId
  if playerId.len == 0:
    playerId = getEnv("CONDUCTOR_PLAYER")
  if playerId.len == 0:
    try:
      let players = parseJson(outList.strip())
      let arr = if players.kind == JArray: players else: players{"players"}
      if arr.isNil or arr.kind != JArray or arr.len != 1:
        flagNeedsHuman(repo, "ship stopped: player roster is not exactly " &
          "one player — pick identity by hand (playbook §5) or set " &
          "CONDUCTOR_PLAYER")
        return ShipOutcome(detail: "player roster ambiguous — NEEDS-HUMAN")
      playerId = arr[0]{"id"}.getStr(arr[0]{"player_id"}.getStr())
    except CatchableError:
      return ShipOutcome(detail: "player list output unparseable")
  if playerId.len == 0:
    return ShipOutcome(detail: "player id missing from roster")
  discard uvRun(forkDir, @["coworld", "player", "use", playerId])

  # Upload; the returned petrel:vN + immutable version id feed the submit.
  let (rcUp, outUp) = uvRun(forkDir, @["coworld", "upload-policy",
    lc.ship.image, "--name", lc.ship.policy], timeoutMs = 1_200_000)
  if rcUp != 0:
    discard uvRun(forkDir, @["coworld", "player", "unset"])
    return ShipOutcome(detail: "upload-policy failed: " &
      outUp[max(0, outUp.len - 300) .. ^1])
  let versionTag = parseVersionTag(outUp, lc.ship.policy)
  let versionId = parseUuid(outUp)
  if versionTag.len == 0 or versionId.len == 0:
    flagNeedsHuman(repo, "ship stopped after upload: could not parse " &
      "version tag/id from upload-policy output — submit by hand " &
      "(one submit per frozen version!)")
    discard uvRun(forkDir, @["coworld", "player", "unset"])
    return ShipOutcome(detail: "uploaded but version tag/id unparsed — " &
      "NEEDS-HUMAN (do not re-upload)")

  # Submit behind the champion guard.
  let guard =
    if guardOverride.len > 0:
      guardOverride
    else:
      lastShipped(ledgerPath(laneDirPath, lc.ticketLane)){
        "ship", "policy_version_id"}.getStr()
  if guard.len == 0:
    discard uvRun(forkDir, @["coworld", "player", "unset"])
    return ShipOutcome(detail: "no champion guard id — pass one " &
      "explicitly for the first ship")
  let (rcSub, outSub) = uvRun(forkDir, @["--extra", "dev", "vanilla-wow",
    "submit", versionTag,
    "--league", lc.ship.leagueId,
    "--expected-champion-policy-version", guard,
    "--wait-placement-seconds", "120", "--json"], timeoutMs = 600_000)
  var submissionId = ""
  if rcSub == 0:
    submissionId = parseUuid(outSub)
  else:
    flagNeedsHuman(repo, "submit failed for " & versionTag &
      " (guard " & guard & ") — inspect before any retry: " &
      outSub[max(0, outSub.len - 300) .. ^1])
    discard uvRun(forkDir, @["coworld", "player", "unset"])
    return ShipOutcome(detail: "submit failed — NEEDS-HUMAN")

  # Readback + identity hygiene.
  discard uvRun(forkDir, @["coworld", "memberships", "--policy", versionTag,
    "--active-only", "--json"])
  discard uvRun(forkDir, @["coworld", "player", "unset"])

  # Ledger: the shipped row is the next ratchet's reference.
  var row = makeRow(lc.ticketLane, "shipped", "", lc.laneBranch,
    %*{"wsa": "", "fork": ""}, candidateReport,
    %*{"pass": true, "reasons": ["ship ratchet passed"]})
  row["ship"] = %*{
    "version": versionTag,
    "policy_version_id": versionId,
    "submission_id": submissionId,
    "guard_over": guard,
  }
  appendRow(ledgerPath(laneDirPath, lc.ticketLane), row)
  try:
    commitLedger(laneDirPath, "scores: SHIPPED " & versionTag &
      " (guard over " & guard & ") — northing " &
      $candidateReport{"max_northing"}.getFloat())
  except IOError as e:
    echo "conductor: WARN ", e.msg
  ShipOutcome(shipped: true, detail: versionTag & " submitted, guard over " &
    guard & ", sub " & submissionId)

proc maybeShip*(root: string, lc: LeagueConfig, repo, laneDirPath: string,
    candidateReport: JsonNode): ShipOutcome =
  ## The daemon's post-merge hook: ratchet, then execute when auto is on.
  if not lc.ship.auto:
    return ShipOutcome(detail: "ship.auto=false — merge stays local")
  let (ok, why) = shipRatchet(root, lc, laneDirPath, candidateReport)
  if not ok:
    return ShipOutcome(detail: "ship ratchet held: " & why)
  echo "conductor: SHIP — ", why
  executeShip(root, lc, repo, laneDirPath, candidateReport)
