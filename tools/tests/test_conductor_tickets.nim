## Pure unit tests for conductor ticket parsing + selection (no git,
## no network — claim/finish are exercised in the supervised tick).
## Run: nim r --hints:off --warnings:off tools/tests/test_conductor_tickets.nim

import std/os
import ../../src/conductor/tickets

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

const sample = """
# 0042: fix the thing

**Lane:** traverse | fork
**Priority:** high
**Depends:** 0017
**Repro:** CHECKPOINT=felwood_cave_entrance END_CHECKPOINT=everlook

body text

## Notes

- conductor attempt 1: PARKED — floor regress
- conductor attempt 2: PARKED — new warning class
"""

check(parseTicketField(sample, "Lane") == "traverse | fork", "lane field")
check(parseTicketField(sample, "Priority") == "high", "priority field")
check(parseTicketField(sample, "Missing") == "", "absent field empty")
check(laneMatches(sample, "traverse"), "lane matches first alt")
check(laneMatches(sample, "fork"), "lane matches second alt")
check(not laneMatches(sample, "home"), "lane mismatch")
let repro = parseRepro(sample)
check(repro.len == 2 and repro[0] == ("CHECKPOINT", "felwood_cave_entrance") and
  repro[1] == ("END_CHECKPOINT", "everlook"), "repro vars parsed")
check(parseRepro("no repro here") .len == 0, "no repro -> empty")
check(conductorAttempts(sample) == 2, "attempts counted from notes")
check(conductorAttempts(sample &
  "\n- conductor attempt 1 rate-fair analysis: prose, not a charge\n") == 2,
  "analysis prose mentioning attempts does not charge budget")

# --- nextOpenTicket against a fixture tree ---
let tmp = getTempDir() / "conductor-tickets-test-" & $getCurrentProcessId()
createDir(tmp / "tickets" / "open")
createDir(tmp / "tickets" / "done")
writeFile(tmp / "tickets" / "open" / "0007-other-lane.md",
  "# 0007: x\n\n**Lane:** fork\n")
writeFile(tmp / "tickets" / "open" / "0009-blocked.md",
  "# 0009: y\n\n**Lane:** traverse\n**Blocked-on:** fork feature\n")
writeFile(tmp / "tickets" / "open" / "0011-dep-missing.md",
  "# 0011: z\n\n**Lane:** traverse\n**Depends:** 0999\n")
writeFile(tmp / "tickets" / "open" / "0013-dep-done.md",
  "# 0013: w\n\n**Lane:** traverse\n**Depends:** 0004\n")
writeFile(tmp / "tickets" / "done" / "0004-old.md", "# 0004: old\n")
writeFile(tmp / "tickets" / "open" / "0015-plain.md",
  "# 0015: v\n\n**Lane:** traverse\n")

let picked = nextOpenTicket(tmp, "traverse")
check(picked.id == "0013", "oldest eligible wins (blocked/dep-missing skipped)")
check(picked.slug == "dep-done", "slug parsed")
check(picked.relPath == "tickets/open/0013-dep-done.md", "relPath")
check(nextOpenTicket(tmp, "speedrun").id == "", "no work for empty lane")

removeDir(tmp)
echo "test_conductor_tickets: ", passed, " ok"
