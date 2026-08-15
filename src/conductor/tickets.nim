## Ticket lifecycle against the wow-coworld root repo's tickets/ tree.
## Format + rules: tickets/README.md — `**Field:**` headers, git mv IS
## the assignment, IDs never reused, notes are append-only. The
## conductor is the ONLY party that moves its tickets; coding agents
## work in a wsa worktree and never see the tickets repo.

import
  std/[algorithm, os, strutils],
  scriptorium/git_ops

type TicketRef* = object
  id*: string        ## "0042"
  slug*: string      ## "parallel-eval-runs"
  relPath*: string   ## "tickets/open/0042-parallel-eval-runs.md"
  content*: string

proc parseTicketField*(content, field: string): string =
  ## "**Lane:** traverse | fork" -> "traverse | fork" (first match).
  let marker = "**" & field & ":**"
  for line in content.splitLines():
    let stripped = line.strip()
    if stripped.startsWith(marker):
      return stripped[marker.len .. ^1].strip()
  ""

proc laneMatches*(content, lane: string): bool =
  ## Lane fields may list alternatives ("traverse | fork"); any hit counts.
  let laneField = parseTicketField(content, "Lane")
  for part in laneField.split('|'):
    if part.strip() == lane:
      return true
  false

proc parseRepro*(content: string): seq[(string, string)] =
  ## "**Repro:** CHECKPOINT=felwood_cave_entrance END_CHECKPOINT=everlook"
  ## -> make vars for the failure-site bracket. Empty when absent.
  let repro = parseTicketField(content, "Repro")
  for token in repro.splitWhitespace():
    let eq = token.find('=')
    if eq > 0:
      result.add((token[0 ..< eq], token[eq + 1 .. ^1]))

proc conductorAttempts*(content: string): int =
  ## Attempts are counted from the append-only notes. Only the park
  ## charge format counts — analysis prose mentioning attempts must not
  ## burn budget (that phantom-charged 0014 to stuck on 2026-08-13).
  for line in content.splitLines():
    if line.contains("conductor attempt ") and line.contains(": PARKED"):
      inc result

proc dependsSatisfied(ticketsRepo, content: string): bool =
  ## Every ID in **Depends:** must live in tickets/done/.
  let depends = parseTicketField(content, "Depends")
  if depends.len == 0:
    return true
  for token in depends.replace(",", " ").splitWhitespace():
    var id = ""
    for ch in token:
      if ch in '0'..'9':
        id.add(ch)
    if id.len == 0:
      continue
    var found = false
    for file in walkFiles(ticketsRepo / "tickets" / "done" / (id & "-*.md")):
      found = true
      break
    if not found:
      return false
  true

proc nextOpenTicket*(ticketsRepo, lane: string): TicketRef =
  ## Oldest open ticket for the lane with satisfied deps and no
  ## Blocked-on. Empty id when the lane has no eligible work.
  var candidates: seq[string]
  for file in walkFiles(ticketsRepo / "tickets" / "open" / "*.md"):
    candidates.add(file)
  candidates.sort()
  for file in candidates:
    let content = readFile(file)
    if not laneMatches(content, lane):
      continue
    if parseTicketField(content, "Blocked-on").len > 0:
      continue
    if not dependsSatisfied(ticketsRepo, content):
      continue
    let base = file.extractFilename()
    let dash = base.find('-')
    if dash < 0 or not base.endsWith(".md"):
      continue
    return TicketRef(
      id: base[0 ..< dash],
      slug: base[dash + 1 .. ^4],
      relPath: "tickets/open/" & base,
      content: content)
  TicketRef()

proc commitTickets(ticketsRepo, message: string) =
  let (rcCommit, outCommit) = gitRunCapture(ticketsRepo,
    @["commit", "-m", message & "\n\nCo-Authored-By: conductor"])
  if rcCommit != 0 and "nothing to commit" notin outCommit:
    raise newException(IOError, "tickets commit failed: " & outCommit)
  let (rcPush, outPush) = gitRunCapture(ticketsRepo, @["push"],
    timeoutMs = 120_000)
  if rcPush != 0:
    # A push race with another session is survivable; rebase and retry once.
    discard gitRunCapture(ticketsRepo, @["pull", "--rebase"],
      timeoutMs = 120_000)
    let (rc2, out2) = gitRunCapture(ticketsRepo, @["push"],
      timeoutMs = 120_000)
    if rc2 != 0:
      raise newException(IOError, "tickets push failed twice: " & out2)

proc claimTicket*(ticketsRepo: string, ticket: TicketRef): string =
  ## open -> in-progress; returns the new repo-relative path. Pull first
  ## so a concurrent session's claim loses cleanly, not silently.
  discard gitRunCapture(ticketsRepo, @["pull", "--rebase"],
    timeoutMs = 120_000)
  if not fileExists(ticketsRepo / ticket.relPath):
    raise newException(IOError,
      "ticket vanished before claim (raced): " & ticket.relPath)
  let dest = "tickets/in-progress/" & ticket.relPath.extractFilename()
  gitRun(ticketsRepo, "mv", ticket.relPath, dest)
  commitTickets(ticketsRepo,
    "tickets: conductor claims " & ticket.id & " (" & ticket.slug & ")")
  dest

proc appendTicketNote*(ticketsRepo, relPath, note: string) =
  let path = ticketsRepo / relPath
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine("")
  f.writeLine(note)

proc finishTicket*(ticketsRepo, relPath, destState, note: string): string =
  ## destState: "done" | "open" | "stuck". Appends the note, moves the
  ## file, commits + pushes. Returns the new repo-relative path.
  appendTicketNote(ticketsRepo, relPath, note)
  let dest = "tickets/" & destState & "/" & relPath.extractFilename()
  gitRun(ticketsRepo, "mv", relPath, dest)
  commitTickets(ticketsRepo,
    "tickets: conductor -> " & destState & " " & relPath.extractFilename())
  dest
