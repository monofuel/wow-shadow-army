## The score ledger: append-only JSONL under scores/<league>.jsonl,
## committed on the league's lane branch. The champion — the run every
## candidate must beat — is simply the last row whose action ratcheted
## (baseline | merged | shipped). Nothing ever edits a row.

import
  std/[json, os, strutils, times]

const ScoresDirName* = "scores"

type LedgerRow* = object
  ts*: string
  league*: string
  action*: string     ## baseline | merged | parked | shipped | hosted
  ticket*: string
  branch*: string
  shas*: JsonNode
  report*: JsonNode
  gate*: JsonNode

proc ledgerPath*(checkoutDir, league: string): string =
  checkoutDir / ScoresDirName / (league & ".jsonl")

proc hostedLedgerPath*(checkoutDir, league: string): string =
  checkoutDir / ScoresDirName / (league & "-hosted.jsonl")

proc ledgerNowUtc*(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc appendRow*(path: string, row: JsonNode) =
  createDir(path.parentDir)
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine($row)

proc makeRow*(league, action, ticket, branch: string,
    shas, report, gate: JsonNode): JsonNode =
  %*{
    "ts": ledgerNowUtc(),
    "league": league,
    "action": action,
    "ticket": ticket,
    "branch": branch,
    "shas": shas,
    "report": report,
    "gate": gate,
  }

proc readRows*(path: string): seq[JsonNode] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    try:
      result.add(parseJson(stripped))
    except JsonParsingError:
      discard  # a torn tail line must never wedge the loop

proc lastRowWithAction(path: string, actions: openArray[string]): JsonNode =
  ## nil when no row matches.
  result = nil
  for row in readRows(path):
    let action = row{"action"}.getStr("")
    if action in actions:
      result = row

proc champion*(path: string): JsonNode =
  lastRowWithAction(path, ["baseline", "merged", "shipped"])

proc lastShipped*(path: string): JsonNode =
  lastRowWithAction(path, ["shipped"])
