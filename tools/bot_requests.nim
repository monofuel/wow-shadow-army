## Grounded request broker for private home seats.
##
## Reads each running seat's own observation file (chat rows, state), accepts
## only messages the authorized player actually addressed to that seat, asks
## the local model to tell a question from an action request and to choose
## one action from the menu the seat can perform right now, and hands accepted
## actions to the seat as durable jobs. The seat's Lua runs the job with
## ordinary game verbs and appends its own outcome receipts; this broker never
## touches the game, never speaks for the player and runs off the game tick.
##
## Addressing: a whisper to the seat, or a party/say line that starts with
## `@Seat` (direct) or `@all` / `@party` / `@everyone` (deliberate group).
## Anything else is not addressed and produces nothing. Authority is the
## existing one: the configured player's server-reported sender GUID.
##
## A human operator can also enqueue a request with `--to/--text`; it is
## labelled origin=operator end to end and never presented as game chat.

import
  std/[json, os, parseopt, sequtils, sets, strutils, tables, times],
  curly, webby

type
  Scope* = enum
    scopeNone, scopeDirect, scopeGroup

  Addressed* = object
    scope*: Scope
    text*: string

  ChatRow* = object
    sequence*: int64
    kind*, senderGuid*, senderName*, text*: string

  MenuItem* = tuple[key, description: string]

  Decision* = object
    intent*, choice*: string

  SeatState = object
    name, dir: string
    episode: string
    cursor: int64
    lastMtime: Time

  Config = object
    homeDir: string
    seats: seq[string]
    authorityName: string
    authorityGuid: string
    baseUrl, model, apiKey: string
    timeoutMs: int
    poll: float
    once: bool
    operatorTo, operatorText: string

const
  DefaultBaseUrl = "https://switchyard.mle.monofuel.dev/v1"
  DefaultModel = "local"
  ## Routed calls keep Switchyard's normal allowance and deadline (the same
  ## profile the Wayfolk bots use); a typed choice with reasoning none uses a
  ## few tokens of it.
  RoutedOutputTokens = 32768
  RoutedTimeoutMs = 120_000
  DefaultPoll = 1.0
  MaxReplyChars = 120
  GroupWords = ["all", "party", "everyone"]
  JobProtocol = "wow_shadow_army.private_request.v1"

var
  modelClient: Curly ## Shared HTTP client for model calls; opened by the broker loop.

proc lowerName(value: string): string =
  ## Case-folded, trimmed character name.
  value.strip.toLowerAscii

proc address*(row: ChatRow; seat, authorityName, authorityGuid: string): Addressed =
  ## Decide whether one chat row is an authorized request addressed to this
  ## seat. Only the authority's own server-reported sender counts; a whisper
  ## is direct, a party/say line needs an explicit leading @recipient.
  if row.senderGuid != authorityGuid or
      row.senderName.lowerName != authorityName.lowerName:
    return
  let text = row.text.strip
  if row.kind == "whisper":
    return Addressed(scope: scopeDirect, text: text)
  # Only channels the seat can answer on: the client's chat intent speaks
  # party, say and whisper, so a raid line is not taken as a request.
  if row.kind notin ["party", "say"] or not text.startsWith("@"):
    return
  var name = ""
  var i = 1
  while i < text.len and text[i] in {'A'..'Z', 'a'..'z'}:
    name.add text[i]
    inc i
  if name.len == 0 or (i < text.len and text[i] notin {' ', ',', ':'}):
    return
  let rest = text[i ..^ 1].strip(chars = {' ', ',', ':'})
  if name.lowerName == seat.lowerName:
    return Addressed(scope: scopeDirect, text: rest)
  if name.lowerName in GroupWords:
    return Addressed(scope: scopeGroup, text: rest)

proc num(node: JsonNode; key: string; fallback = 0.0): float =
  ## Numeric field that may be absent or encoded as a string.
  let field = node{key}
  if field.isNil: return fallback
  case field.kind
  of JInt: field.getInt.float
  of JFloat: field.getFloat
  of JString:
    try: parseFloat(field.getStr) except ValueError: fallback
  else: fallback

proc unitByGuid(obs: JsonNode; guid: string): JsonNode =
  ## Visible unit row with this GUID, or nil.
  for unit in obs{"units"}.getElems:
    if unit{"guid"}.getStr == guid: return unit

proc knowsSpell(obs: JsonNode; spell: int): bool =
  ## Whether the seat's spellbook holds this spell.
  for value in obs{"known_spells"}.getElems:
    if value.getInt == spell: return true

proc upgradeInBags(obs: JsonNode): bool =
  ## Whether a bag item carries a positive SDK upgrade score at a legal level.
  let level = obs.num("level")
  for item in obs{"inventory_items"}.getElems:
    if item.num("upgrade_score") > 0 and item.num("required_level") <= level:
      return true

proc petOut(obs: JsonNode): bool =
  ## Whether the authoritative pet link names a living pet.
  let guid = obs{"active_pet_guid"}.getStr("0")
  guid != "0" and guid != "" and not obs{"active_pet_dead"}.getBool

proc menu*(obs: JsonNode; requesterVisible, jobActive: bool): seq[MenuItem] =
  ## Actions this seat can perform now, from its own observation.
  result.add ("hold_here", "stop and stay at the current spot until told to resume")
  if requesterVisible:
    result.add ("come_here", "walk over to the player who asked")
    result.add ("follow_me", "follow the player who asked until told to stop")
  if obs.num("class_id") == 9 and obs.knowsSpell(688) and not obs.petOut:
    result.add ("summon_pet", "summon the imp")
  if obs.upgradeInBags:
    result.add ("wear_upgrades", "equip the better gear already in the bags")
  if obs.num("copper") >= 100:
    result.add ("train", "visit the class trainer and learn new ranks")
  if jobActive:
    result.add ("resume", "end the current task and carry on leveling on your own (the player says carry on, go ahead, continue, back to leveling or grinding)")
  result.add ("none", "no offered action fits")

proc stateLine*(obs: JsonNode; activeJob: string): string =
  ## Short factual state the model is grounded on.
  let pet = if obs.petOut: "pet out" else: "no pet out"
  var quests: seq[string]
  for q in obs{"accepted_quests"}.getElems:
    quests.add $q{"quest_id"}.getInt
  result = "level " & $obs.num("level").int & ", " & $obs.num("xp").int & "/" &
    $obs.num("next_level_xp").int & " xp, " & pet & ", " &
    $obs.num("copper").int & " copper, " &
    (if obs{"in_combat"}.getBool: "in combat" else: "not in combat") &
    ", position " & $obs{"location"}.num("x").int & "," & $obs{"location"}.num("y").int &
    ", quests in log: " & (if quests.len == 0: "none" else: quests.join(" ")) &
    ", current task: " & (if activeJob.len == 0: "leveling on its own" else: activeJob)

proc decisionBody*(model, seat, className, state, message: string;
    offered: seq[MenuItem]): JsonNode =
  ## Structured chat-completion request: question vs action vs chatter, and
  ## one offered key.
  var described = ""
  var keys = newJArray()
  for item in offered:
    keys.add %item.key
    described.add "- " & item.key & ": " & item.description & "\n"
  %*{
    "model": model,
    "max_tokens": RoutedOutputTokens,
    "temperature": 0.0,
    "reasoning_effort": "none",
    "messages": [
      {"role": "system", "content":
        "You interpret one chat message sent to " & seat & ", an undead " &
        className & " bot in World of Warcraft, by the player it serves.\n" &
        "intent=action when the player wants " & seat & " to do something now, " &
        "including polite requests phrased as questions (\"can you...\", " &
        "\"could you...\", \"would you mind...\") and go-ahead instructions " &
        "such as \"carry on\", \"go ahead\", \"you can go\" or \"back to leveling\" " &
        "when " & seat & " has a current task.\n" &
        "intent=question when the player asks for information about " & seat &
        " (level, pet, gold, what it is doing, where it is) without asking it to act.\n" &
        "intent=chatter for greetings, jokes and remarks.\n" &
        "choice must be one offered action key that fulfils an action request, " &
        "otherwise none.\nOffered actions:\n" & described},
      {"role": "user", "content": "State: " & state & "\nMessage: " & message}
    ],
    "response_format": {"type": "json_schema", "json_schema": {
      "name": "decision", "strict": true, "schema": {
        "type": "object", "additionalProperties": false,
        "required": ["intent", "choice"],
        "properties": {
          "intent": {"type": "string", "enum": ["question", "action", "chatter"]},
          "choice": {"type": "string", "enum": keys}}}}}
  }

proc parseDecision*(content: string; offered: seq[MenuItem]): Decision =
  ## Validate the model's typed answer; an unoffered key is an error, never
  ## a default.
  let node = parseJson(content)
  result.intent = node{"intent"}.getStr
  result.choice = node{"choice"}.getStr
  if result.intent notin ["question", "action", "chatter"]:
    raise newException(ValueError, "decision has no valid intent: " & content)
  var offeredKey = false
  for item in offered:
    if item.key == result.choice: offeredKey = true
  if not offeredKey:
    raise newException(ValueError, "decision chose an unoffered action: " & result.choice)
  if result.intent != "action":
    result.choice = "none"

proc answerBody*(model, seat, state, question: string): JsonNode =
  ## A one-line factual answer drawn only from the seat's observed state.
  %*{
    "model": model,
    "max_tokens": RoutedOutputTokens,
    "temperature": 0.2,
    "reasoning_effort": "none",
    "messages": [
      {"role": "system", "content":
        "You are " & seat & ", a World of Warcraft bot answering the player you serve. " &
        "Answer in one short plain sentence under 100 characters using only the facts " &
        "in State. If State does not contain the answer, say you do not know. " &
        "No emojis, no quotes."},
      {"role": "user", "content": "State: " & state & "\nQuestion: " & question}
    ]
  }

proc cleanReply*(text: string): string =
  ## Printable single-line reply within the seat's chat limit.
  for c in text:
    if c in {' '..'~'} and c != '"' and c != '\\': result.add c
    elif c in {'\n', '\r', '\t'}: result.add ' '
  result = result.strip
  while result.startsWith("/"): result = result[1 ..^ 1].strip
  if result.len > MaxReplyChars: result = result[0 ..< MaxReplyChars].strip

proc jobKey*(seatGuid, episode: string; sequence: int64; origin: string): string =
  ## Stable request identity: the seat, its session, the chat row.
  origin & "-" & seatGuid & "-" & episode[0 ..< min(8, episode.len)] & "-" & $sequence

proc writeAtomic(path, body: string) =
  ## Same-directory write then rename, so a reader never sees half a file.
  let tmp = path & ".tmp"
  writeFile(tmp, body)
  moveFile(tmp, path)

proc appendLine(path, line: string) =
  ## Append one line, creating the file.
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine(line)

proc logLine(seatDir: string; node: JsonNode) =
  ## Append one broker event to the seat's request log.
  let f = open(seatDir / "jobs" / "broker.jsonl", fmAppend)
  defer: f.close()
  f.writeLine($node)

proc callModel(cfg: Config; body: JsonNode): tuple[content, requestId, served, finish: string,
    usage: JsonNode, seconds: float] =
  ## One blocking routed request through the shared Curly client; failures
  ## raise with their status. The broker makes one call at a time.
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " & cfg.apiKey
  let started = epochTime()
  let response = modelClient.post(cfg.baseUrl & "/chat/completions", headers, $body,
    timeout = cfg.timeoutMs div 1000)
  result.seconds = epochTime() - started
  if response.code < 200 or response.code > 299:
    raise newException(IOError, "model request failed: " & $response.code & " " &
      response.body[0 ..< min(300, response.body.len)])
  let parsed = parseJson(response.body)
  result.content = parsed{"choices"}[0]{"message"}{"content"}.getStr
  result.finish = parsed{"choices"}[0]{"finish_reason"}.getStr
  result.usage = parsed{"usage"}
  result.served = response.headers["x-model-router-selected-model"]
  if result.served.len == 0: result.served = parsed{"model"}.getStr
  result.requestId = response.headers["x-mle-request-id"]

proc readActive(seatDir: string): string =
  ## The choice of the job the seat is running, if any.
  let path = seatDir / "jobs" / "active.json"
  if fileExists(path):
    try: return parseFile(path){"choice"}.getStr
    except CatchableError: discard

proc seenKeys(seatDir: string): HashSet[string] =
  ## Every request key this seat was ever handed (exactly-once ledger).
  let path = seatDir / "jobs" / "ledger.txt"
  if fileExists(path):
    for line in lines(path):
      if line.len > 0: result.incl line.strip

proc handle(cfg: Config; seat: var SeatState; obs: JsonNode; origin, actor,
    actorGuid, text: string; scope: Scope; key: string; seen: var HashSet[string]) =
  ## Interpret one addressed request and hand any accepted action to the seat.
  if key in seen: return
  let jobs = seat.dir / "jobs"
  let requester = if actorGuid.len > 0: obs.unitByGuid(actorGuid) else: nil
  let active = readActive(seat.dir)
  let offered = menu(obs, not requester.isNil, active.len > 0)
  let className = if obs.num("class_id") == 9: "warlock" else: "adventurer"
  let state = stateLine(obs, active)
  var event = %*{"at": epochTime(), "seat": seat.name, "key": key, "origin": origin,
    "actor": actor, "scope": $scope, "text": text, "offered": offered.mapIt(it.key)}
  var decision: Decision
  try:
    let call = callModel(cfg, decisionBody(cfg.model, seat.name, className, state, text, offered))
    event["decision_model"] = %call.served
    event["decision_request_id"] = %call.requestId
    event["decision_seconds"] = %call.seconds
    event["decision_finish"] = %call.finish
    event["decision_usage"] = call.usage
    decision = parseDecision(call.content, offered)
  except CatchableError as error:
    event["error"] = %error.msg
    logLine(seat.dir, event)
    seen.incl key
    appendLine(jobs / "ledger.txt", key)
    return
  event["intent"] = %decision.intent
  event["choice"] = %decision.choice
  var reply = ""
  if decision.intent == "question":
    try:
      let call = callModel(cfg, answerBody(cfg.model, seat.name, state, text))
      reply = cleanReply(call.content)
      event["answer_model"] = %call.served
      event["answer_request_id"] = %call.requestId
      event["answer_seconds"] = %call.seconds
      event["answer_finish"] = %call.finish
    except CatchableError as error:
      event["answer_error"] = %error.msg
  elif decision.intent == "action" and decision.choice == "none":
    reply = "I can't do that right now."
  event["reply"] = %reply
  if decision.choice != "none" or reply.len > 0:
    var job = %*{"protocol": JobProtocol, "key": key, "origin": origin, "actor": actor,
      "actor_guid": actorGuid, "scope": $scope, "text": text, "intent": decision.intent,
      "choice": decision.choice, "reply": reply, "created_at": epochTime()}
    if not requester.isNil:
      let loc = requester{"location"}
      job["x"] = %loc.num("x")
      job["y"] = %loc.num("y")
      job["z"] = %loc.num("z")
      job["map_id"] = %loc.num("map_id")
      job["actor_unit_guid"] = %actorGuid
    # One-slot mailbox: the seat consumes inbox.json; a later request waits
    # in the queue file until then.
    appendLine(jobs / "queue.jsonl", $job)
    event["queued"] = %true
  logLine(seat.dir, event)
  seen.incl key
  appendLine(jobs / "ledger.txt", key)

proc claimOperator*(jobs: string): string =
  ## Claim this seat's pending operator requests for handling and return the
  ## claim file, or "" when none are pending. A claim left by a broker that
  ## stopped mid-handling is returned first; otherwise operator.jsonl is
  ## renamed into the claim. The claim is removed only after every line was
  ## handled, so a crash re-handles it and the per-key ledger and seat
  ## receipts keep each request exactly-once.
  let claim = jobs / "operator.claimed.jsonl"
  let pending = jobs / "operator.jsonl"
  if fileExists(claim):
    result = claim
  elif fileExists(pending):
    moveFile(pending, claim)
    result = claim

proc deliver(seat: SeatState) =
  ## Move the oldest queued job into the seat's empty one-slot inbox.
  let jobs = seat.dir / "jobs"
  let queue = jobs / "queue.jsonl"
  if fileExists(jobs / "inbox.json") or not fileExists(queue): return
  var rows: seq[string]
  for line in lines(queue):
    if line.strip.len > 0: rows.add line
  if rows.len == 0: return
  writeAtomic(jobs / "inbox.json", rows[0] & "\n")
  writeAtomic(queue, (if rows.len > 1: rows[1 ..^ 1].join("\n") & "\n" else: ""))

proc runningSeats(cfg: Config): seq[string] =
  ## Configured seats, or every home seat with a live launcher.
  if cfg.seats.len > 0: return cfg.seats
  for kind, path in walkDir(cfg.homeDir):
    if kind != pcDir: continue
    let pidFile = path / "launcher.pid"
    if not fileExists(pidFile): continue
    let pid = readFile(pidFile).strip
    if pid.len > 0 and dirExists("/proc/" & pid):
      result.add path.lastPathPart

proc tick(cfg: Config; seats: var Table[string, SeatState]) =
  ## One poll over every seat.
  for name in runningSeats(cfg):
    let dir = cfg.homeDir / name
    let obsPath = dir / "observer" / "observation.json"
    if not fileExists(obsPath): continue
    createDir(dir / "jobs")
    if not seats.hasKey(name):
      var s = SeatState(name: name, dir: dir, cursor: -1)
      let cursorPath = dir / "jobs" / "chat_cursor.json"
      if fileExists(cursorPath):
        try:
          let c = parseFile(cursorPath)
          s.episode = c{"episode"}.getStr
          s.cursor = c{"sequence"}.getBiggestInt
        except CatchableError: discard
      seats[name] = s
    var seat = seats[name]
    deliver(seat)
    let mtime = getLastModificationTime(obsPath)
    if mtime == seat.lastMtime: continue
    seat.lastMtime = mtime
    var obs: JsonNode
    try: obs = parseFile(obsPath)
    except CatchableError: continue
    let episode = obs{"episode_id"}.getStr
    let seatGuid = obs{"player_guid"}.getStr
    if episode != seat.episode:
      # A new session restarts chat numbering; rows from before the broker
      # saw this session are history, not requests.
      seat.episode = episode
      seat.cursor = obs{"chat_messages_last_sequence"}.getBiggestInt
    var seen = seenKeys(dir)
    for node in obs{"chat_messages"}.getElems:
      let row = ChatRow(sequence: node{"sequence"}.getBiggestInt, kind: node{"kind"}.getStr,
        senderGuid: node{"sender_guid"}.getStr, senderName: node{"sender_name"}.getStr,
        text: node{"text"}.getStr)
      if row.sequence <= seat.cursor: continue
      seat.cursor = row.sequence
      let a = address(row, name, cfg.authorityName, cfg.authorityGuid)
      if a.scope == scopeNone or a.text.len == 0: continue
      handle(cfg, seat, obs, row.kind, row.senderName, row.senderGuid, a.text, a.scope,
        jobKey(seatGuid, episode, row.sequence, row.kind), seen)
    let claim = claimOperator(dir / "jobs")
    if claim.len > 0:
      for line in readFile(claim).splitLines:
        if line.strip.len == 0: continue
        var req: JsonNode
        try:
          req = parseJson(line)
        except JsonParsingError:
          # A malformed line is set aside instead of failing every tick.
          appendLine(dir / "jobs" / "operator.bad.jsonl", line)
          continue
        handle(cfg, seat, obs, "operator", req{"actor"}.getStr("operator"), "",
          req{"text"}.getStr, scopeDirect, req{"key"}.getStr, seen)
      removeFile(claim)
    writeAtomic(dir / "jobs" / "chat_cursor.json",
      $(%*{"episode": seat.episode, "sequence": seat.cursor}))
    deliver(seat)
    seats[name] = seat

proc enqueueOperator(cfg: Config) =
  ## Record a human-directed operator request for the named seats. It keeps
  ## origin=operator through the job and receipts; nothing is said in game.
  let targets = if cfg.operatorTo.toLowerAscii in GroupWords: runningSeats(cfg)
    else: cfg.operatorTo.split(',')
  let stamp = $int64(epochTime() * 1000)
  for name in targets:
    let jobs = cfg.homeDir / name.strip / "jobs"
    createDir(jobs)
    let f = open(jobs / "operator.jsonl", fmAppend)
    f.writeLine($(%*{"key": "operator-" & name.strip & "-" & stamp,
      "actor": "operator", "text": cfg.operatorText}))
    f.close()
    echo "queued operator request for ", name.strip

proc parseConfig(): Config =
  ## Command line; defaults follow the existing local serving profile.
  result = Config(homeDir: getCurrentDir() / "local_data" / "home-army",
    authorityName: "Murist", authorityGuid: "1000007", baseUrl: DefaultBaseUrl,
    model: DefaultModel, apiKey: "unused", timeoutMs: RoutedTimeoutMs, poll: DefaultPoll)
  for kind, key, value in getopt():
    if kind in {cmdArgument, cmdEnd} or key.len == 0: continue
    case key
    of "home-dir": result.homeDir = value
    of "seats": result.seats = value.split(',')
    of "authority": result.authorityName = value
    of "authority-guid": result.authorityGuid = value
    of "base-url": result.baseUrl = value
    of "model": result.model = value
    of "poll": result.poll = parseFloat(value)
    of "once": result.once = true
    of "to": result.operatorTo = value
    of "text": result.operatorText = value
    else:
      quit("unknown option: " & key, 2)

proc main() =
  ## Enqueue an operator request, or run the broker loop.
  let cfg = parseConfig()
  if cfg.operatorTo.len > 0:
    if cfg.operatorText.strip.len == 0: quit("--text is required with --to", 2)
    enqueueOperator(cfg)
    return
  echo "bot_requests: watching ", cfg.homeDir, " model=", cfg.model, " via ", cfg.baseUrl
  modelClient = newCurly()
  defer: modelClient.close()
  var seats = initTable[string, SeatState]()
  while true:
    tick(cfg, seats)
    if cfg.once: break
    sleep(int(cfg.poll * 1000))

when isMainModule:
  main()
