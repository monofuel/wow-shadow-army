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
## An unprefixed party/say line from the authority is ambient: exactly one
## live seat that shares the authority's party (or, for say, sees the
## authority) handles it with the same authority as an `@Seat` request, so it
## may answer or take one offered action. Group conversation is likewise
## answered once; group actions still reach every seat. Anything else produces nothing. Authority is the existing one:
## the configured player's server-reported sender GUID.
##
## Roles: Kev (System One at the direct Azem endpoint) routes each message to
## question, action or chatter; Lightning (Switchyard `local`) picks the
## offered action and writes replies grounded in the seat's observed state.
## If Kev is unreachable, Lightning's own typed decision routes the message.
##
## A human operator can also enqueue a request with `--to/--text`; it is
## labelled origin=operator end to end and never presented as game chat.
##
## Model admission: each addressed request is one request chain (see
## `broker_admission`). While a hold applies, new chains are not admitted:
## chat rows are kept in the seat's `jobs/deferred.jsonl` and operator files
## stay pending, then both are handled once after release or expiry. The
## deferred file is replaced atomically, so a failed write leaves its earlier
## rows and the chat cursor as they were and the row is deferred again on the
## next tick. Handing a request is at-least-once: a crash after its job is
## queued but before its key reaches the ledger hands it again.

import
  std/[json, os, osproc, parseopt, sequtils, sets, streams, strutils, tables, times],
  curly, webby,
  ./broker_admission

type
  Scope* = enum
    scopeNone, scopeDirect, scopeGroup, scopeAmbient

  Addressed* = object
    scope*: Scope
    text*: string

  ChatRow* = object
    sequence*: int64
    kind*, senderGuid*, senderName*, text*: string

  MenuItem* = tuple[key, description: string]

  Decision* = object
    intent*, choice*: string

  Route* = object
    intent*: string
    confidence*, actionProbability*: float

  SeatState* = object
    name, dir: string
    episode: string
    cursor: int64
    lastMtime: Time
    obs: JsonNode
    pending: bool

  Config* = object
    homeDir: string
    seats*: seq[string]
    authorityName: string
    authorityGuid: string
    baseUrl, model, apiKey: string
    routeBaseUrl, routeModel, routeApiKey: string
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
  ## Kev is reached directly on Azem through System One; it is a decision
  ## model, not a Switchyard chat route.
  DefaultRouteBaseUrl = "http://10.11.2.22:1234/v1"
  DefaultRouteModel = "kev-4b"
  DefaultPoll = 1.0
  MaxReplyChars = 120
  GroupWords = ["all", "party", "everyone"]
  Intents = ["question", "action", "chatter"]
  ## Raw SMSG_QUESTGIVER_STATUS values for a giver with a quest to offer or a
  ## reward to hand over.
  QuestMarkerWork = [5, 6, 7]
  ## A message Kev routes away from action still goes to Lightning's action
  ## decision when Kev gives action at least this probability.
  ActionProbabilityFloor = 0.3
  ## A seat whose observation is older than this is not a live responder.
  LiveObservationSeconds = 30
  JobProtocol = "wow_shadow_army.private_request.v1"
  DeferredFile = "deferred.jsonl"

var
  modelClient: Curly ## Shared HTTP client for model calls; opened by the broker loop.
  postJson*: proc (url, apiKey, body: string; timeoutMs: int): Response =
    proc (url, apiKey, body: string; timeoutMs: int): Response =
      var headers: HttpHeaders
      headers["Content-Type"] = "application/json"
      headers["Authorization"] = "Bearer " & apiKey
      modelClient.post(url, headers, body, timeout = timeoutMs div 1000)
    ## Model HTTP transport; tests replace it with synthetic responses.
  gate*: Gate ## Model admission control; disabled until the broker opens it.

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

proc ambient*(row: ChatRow; authorityName, authorityGuid: string): Addressed =
  ## An unprefixed party/say line from the authority: conversation meant for
  ## whoever is with them. A line starting with `@` names its recipients and
  ## goes through `address` instead; whispers, raid and other senders never
  ## count.
  if row.senderGuid != authorityGuid or
      row.senderName.lowerName != authorityName.lowerName:
    return
  let text = row.text.strip
  if row.kind notin ["party", "say"] or text.len == 0 or text.startsWith("@") or
      text.startsWith("<SA>"):
    return
  Addressed(scope: scopeAmbient, text: text)

proc guidStr(node: JsonNode): string =
  ## A GUID field as text, whether the observation wrote it as string or number.
  if node.isNil: return ""
  case node.kind
  of JString: node.getStr
  of JInt: $node.getBiggestInt
  else: ""

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
    if unit{"guid"}.guidStr == guid: return unit

proc eligible*(obs: JsonNode; channel, authorityGuid: string): bool =
  ## Whether this seat's own observation puts it with the authority for a
  ## line on this channel: party lines need the authority in the seat's
  ## current party; say lines also accept the authority being in view.
  for member in obs{"party"}{"members"}.getElems:
    if member{"guid"}.guidStr == authorityGuid: return true
  channel == "say" and not obs.unitByGuid(authorityGuid).isNil

proc responder*(live: seq[(string, JsonNode)]; channel, authorityGuid: string): string =
  ## The one seat that answers conversation on this channel: the
  ## alphabetically first live seat eligible for it, or "" when none is.
  ## Every broker tick computes the same answer from the same observations.
  for (name, obs) in live:
    if not obs.eligible(channel, authorityGuid): continue
    if result.len == 0 or name.lowerName < result.lowerName:
      result = name

proc knowsSpell(obs: JsonNode; spell: int): bool =
  ## Whether the seat's spellbook holds this spell.
  for value in obs{"known_spells"}.getElems:
    if value.getInt == spell: return true

proc upgradeInBags(obs: JsonNode): bool =
  ## Whether the observation's `equipment_upgrade` summary names a wearable
  ## (non-bag) upgrade that is still a carried bag row at a legal level. The
  ## raw rows carry no per-item score; the seat's Lua makes the final checks.
  let upgrade = obs{"equipment_upgrade"}
  if upgrade.isNil or not upgrade{"found"}.getBool or
      upgrade{"capacity_upgrade"}.getBool:
    return false
  let guid = upgrade{"item_guid"}.guidStr
  if guid.len == 0 or guid == "0": return false
  let level = obs.num("level")
  for item in obs{"inventory_items"}.getElems:
    if item{"item_guid"}.guidStr == guid:
      return item.num("required_level") <= level

proc petOut(obs: JsonNode): bool =
  ## Whether the authoritative pet link names a living pet.
  let guid = obs{"active_pet_guid"}.getStr("0")
  guid != "0" and guid != "" and not obs{"active_pet_dead"}.getBool

proc repairVendorUsable(obs, unit: JsonNode): bool =
  ## Mirror the seat's repair vendor filter: an observed repair service that
  ## is not known dead, not hostile, and on the seat's own observed map.
  var repairs = false
  for service in unit{"services"}.getElems:
    if service.getStr == "repair": repairs = true
  let dead = (unit{"death_known"}.getBool and unit{"is_dead"}.getBool) or
    (unit{"health_known"}.getBool and unit.num("health") <= 0)
  let here = obs{"location"}
  let there = unit{"location"}
  repairs and not dead and not unit{"player_reaction_hostile"}.getBool and
    not here{"map_id"}.isNil and not there{"map_id"}.isNil and
    here.num("map_id") == there.num("map_id")

proc questWork*(obs: JsonNode): bool =
  ## Whether the seat observes ordinary quest work it can act on: an accepted
  ## quest that has not failed, or a visible giver whose server marker offers
  ## a quest or a reward.
  for quest in obs{"accepted_quests"}.getElems:
    if not quest{"failed"}.getBool: return true
  for marker in obs{"quest_markers"}.getElems:
    if marker.num("status").int in QuestMarkerWork: return true

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
  var damaged = false
  for item in obs{"equipment_items"}.getElems:
    if item{"durability_known"}.getBool and item{"max_durability_known"}.getBool and
        item.num("max_durability") > 0 and item.num("durability") < item.num("max_durability"):
      damaged = true
  var repairVendor = false
  for unit in obs{"units"}.getElems:
    if obs.repairVendorUsable(unit): repairVendor = true
  if damaged and repairVendor and obs{"equipped_durability_known"}.getBool:
    result.add ("repair_gear", "visit the observed repair vendor and repair worn gear if the actual quote is affordable")
  if obs.questWork:
    result.add ("do_quests", "quest on its own, handing in whichever quests it can finish and taking up the ones offered next, until it runs out of reachable quest work or the request window ends; it cannot pick a named quest (the player says do quests, go quest)")
  if obs.num("copper") >= 100:
    result.add ("train", "visit the class trainer and learn new ranks")
  if jobActive:
    result.add ("resume", "end the current task and carry on leveling on your own (the player says carry on, go ahead, continue, back to leveling or grinding)")
  result.add ("none", "no offered action fits")

proc stateLine*(obs: JsonNode; activeJob: string): string =
  ## Short factual state the model is grounded on. Only observed facts: the
  ## seat's activity beyond the player's accepted task is not observed here.
  var party: seq[string]
  for member in obs{"party"}{"members"}.getElems:
    party.add member{"name"}.getStr("?")
  let pet = if obs.petOut: "pet out" else: "no pet out"
  var quests: seq[string]
  for q in obs{"accepted_quests"}.getElems:
    quests.add $q{"quest_id"}.getInt
  let health = if obs{"health_known"}.getBool and obs.num("max_health") > 0:
      $obs.num("health").int & "/" & $obs.num("max_health").int
    else: "unobserved"
  var broken = 0
  for item in obs{"equipment_items"}.getElems:
    if item{"durability_known"}.getBool and item{"max_durability_known"}.getBool and
        item.num("max_durability") > 0 and item.num("durability") == 0:
      inc broken
  result = "level " & $obs.num("level").int & ", " & $obs.num("xp").int & "/" &
    $obs.num("next_level_xp").int & " xp, health " & health & ", " & pet & ", " &
    $obs.num("copper").int & " copper, " &
    (if obs{"in_combat"}.getBool: "in combat" else: "not in combat") &
    ", position " & $obs{"location"}.num("x").int & "," & $obs{"location"}.num("y").int &
    ", quests in log: " & (if quests.len == 0: "none" else: quests.join(" ")) &
    ", party: " & (if party.len == 0: "none" else: party.join(" ")) &
    ", task from the player: " & (if activeJob.len == 0: "none" else: activeJob) &
    ", broken worn items: " & (if obs{"equipped_durability_known"}.getBool: $broken else: "unobserved") &
    ", unspent talent points: " & (if obs{"talent_points_known"}.getBool: $obs.num("unspent_talent_points").int else: "unobserved")

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

proc chatterBody*(model, seat, className, state, message: string): JsonNode =
  ## A short natural conversational reply from the seat, grounded in its
  ## observed state. The reply only talks; it never claims an action.
  %*{
    "model": model,
    "max_tokens": RoutedOutputTokens,
    "temperature": 0.6,
    "reasoning_effort": "none",
    "messages": [
      {"role": "system", "content":
        "You are " & seat & ", an undead " & className & " in World of Warcraft, " &
        "chatting with the player you serve and adventure with. Reply naturally " &
        "in one short friendly sentence under 100 characters, the way a party " &
        "member would: answer what they said. Any fact about yourself must come " &
        "from State; do not describe what you are doing, feeling or resting " &
        "beyond State, and do not invent progress, plans or rules. " &
        "This reply is only talk: do not say you will do, are doing or did " &
        "anything that State's task from the player does not show. " &
        "No emojis, no quotes."},
      {"role": "user", "content": "State: " & state & "\nPlayer says: " & message}
    ]
  }

proc routeBody*(model, seat, className, scope, state, message: string): JsonNode =
  ## Kev System One request: one keyed choice question routing the message
  ## to question, action or chatter.
  let audience = if scope == "ambient":
      "The player said this in chat to the group around them, not to " & seat & " by name."
    else: "The player addressed this to " & seat & "."
  %*{
    "model": model,
    "state": seat & " is an undead " & className & " bot in World of Warcraft " &
      "serving the player. " & audience & "\nState: " & state & "\nMessage: " & message,
    "questions": {"intent": {"type": "choice",
      "instructions": "What kind of message is this from the player to " & seat & "?",
      "criteria": {
        "question": "asks for information about " & seat & " (level, pet, gold, what it is doing, where it is) without asking it to act",
        "action": "wants " & seat & " to do something now, including polite requests phrased as questions and go-ahead instructions such as carry on",
        "chatter": "a greeting, joke, thanks or remark that calls for a conversational reply"}}}
  }

proc parseRoute*(body: string): Route =
  ## Validate Kev's System One answer; anything malformed raises.
  let node = parseJson(body)
  if node.kind != JObject or (node.hasKey("error") and node["error"].kind != JNull):
    raise newException(ValueError, "route model failed: " & body[0 ..< min(300, body.len)])
  let answer = node{"answers"}{"intent"}
  if answer.isNil or answer{"type"}.getStr != "choice":
    raise newException(ValueError, "route model omitted its choice answer")
  result.intent = answer{"choice"}.getStr
  if result.intent notin Intents:
    raise newException(ValueError, "route model chose an unknown intent: " & result.intent)
  result.confidence = answer.num("confidence", -1.0)
  if answer.hasKey("confidence") and result.confidence notin 0.0 .. 1.0:
    raise newException(ValueError, "route model returned invalid confidence")
  let probabilities = answer{"probabilities"}
  if not probabilities.isNil:
    var total = 0.0
    for key, value in probabilities.pairs:
      let p = if value.kind in {JInt, JFloat}: value.getFloat else: -1.0
      if key notin Intents or p notin 0.0 .. 1.0:
        raise newException(ValueError, "route model returned invalid probabilities")
      total += p
    if probabilities.len != Intents.len or abs(total - 1.0) > 0.001:
      raise newException(ValueError, "route model probabilities are incomplete")
    result.actionProbability = probabilities["action"].getFloat
  elif result.intent == "action":
    result.actionProbability = 1.0

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
  let started = epochTime()
  gate.beginPost()
  defer: gate.endPost()
  let response = postJson(cfg.baseUrl & "/chat/completions", cfg.apiKey, $body, cfg.timeoutMs)
  result.seconds = epochTime() - started
  if response.code < 200 or response.code > 299:
    raise newException(IOError, "model request failed: " & $response.code & " " &
      response.body[0 ..< min(300, response.body.len)])
  let parsed = parseJson(response.body)
  let choices = parsed{"choices"}
  if choices.isNil or choices.kind != JArray or choices.len == 0:
    raise newException(ValueError, "model returned no completion choices")
  result.content = parsed{"choices"}[0]{"message"}{"content"}.getStr
  result.finish = parsed{"choices"}[0]{"finish_reason"}.getStr
  result.usage = if parsed{"usage"}.isNil: newJNull() else: parsed{"usage"}
  result.served = response.headers["x-model-router-selected-model"]
  if result.served.len == 0: result.served = parsed{"model"}.getStr
  result.requestId = response.headers["x-mle-request-id"]

proc callRoute(cfg: Config; body: JsonNode): tuple[route: Route, served: string,
    usage: JsonNode, seconds: float] =
  ## One blocking System One request to Kev on the direct endpoint.
  let started = epochTime()
  gate.beginPost()
  defer: gate.endPost()
  let response = postJson(cfg.routeBaseUrl & "/systemone", cfg.routeApiKey, $body, cfg.timeoutMs)
  result.seconds = epochTime() - started
  if response.code < 200 or response.code > 299:
    raise newException(IOError, "route request failed: " & $response.code & " " &
      response.body[0 ..< min(300, response.body.len)])
  result.route = parseRoute(response.body)
  let parsed = parseJson(response.body)
  result.served = parsed{"model"}.getStr
  result.usage = if parsed{"usage"}.isNil: newJNull() else: parsed{"usage"}

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
    actorGuid, text: string; scope: Scope; key: string; seen: var HashSet[string];
    speaks = true) =
  ## Interpret one addressed request and hand any accepted action to the seat.
  ## `speaks` is false for a group request this seat should act on but not
  ## answer, so conversation gets one reply rather than one per seat.
  if key in seen: return
  let jobs = seat.dir / "jobs"
  let requester = if actorGuid.len > 0: obs.unitByGuid(actorGuid) else: nil
  let active = readActive(seat.dir)
  let offered = menu(obs, not requester.isNil, active.len > 0)
  let className = if obs.num("class_id") == 9: "warlock" else: "adventurer"
  let state = stateLine(obs, active)
  var event = %*{"at": epochTime(), "seat": seat.name, "key": key, "origin": origin,
    "actor": actor, "scope": $scope, "text": text, "offered": offered.mapIt(it.key)}
  var route = ""
  if cfg.routeModel.len > 0:
    try:
      let call = callRoute(cfg, routeBody(cfg.routeModel, seat.name, className,
        (if scope == scopeAmbient: "ambient" else: "addressed"), state, text))
      route = call.route.intent
      event["route_model"] = %call.served
      event["route_intent"] = %route
      event["route_confidence"] = %call.route.confidence
      event["route_action_probability"] = %call.route.actionProbability
      event["route_seconds"] = %call.seconds
      event["route_usage"] = call.usage
      if route != "action" and call.route.actionProbability >= ActionProbabilityFloor:
        route = "action"
    except CatchableError as error:
      event["route_error"] = %error.msg
  var decision = Decision(intent: route, choice: "none")
  if route.len == 0 or route == "action":
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
  if not speaks:
    discard
  elif decision.intent in ["question", "chatter"]:
    let body = if decision.intent == "question": answerBody(cfg.model, seat.name, state, text)
      else: chatterBody(cfg.model, seat.name, className, state, text)
    try:
      let call = callModel(cfg, body)
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

proc runAdmitted(cfg: Config; seat: var SeatState; obs: JsonNode; origin, actor,
    actorGuid, text: string; scope: Scope; key: string; seen: var HashSet[string];
    speaks = true): bool =
  ## Run one request chain if the admission gate admits it now; false means
  ## it was not admitted and the caller keeps the request.
  if key in seen: return true
  if not gate.admit(): return false
  try:
    handle(cfg, seat, obs, origin, actor, actorGuid, text, scope, key, seen, speaks)
  finally:
    gate.finish()
  true

proc deferRow(seat: SeatState; origin, actor, actorGuid, text: string;
    scope: Scope; key: string; speaks: bool) =
  ## Keep an addressed chat row the gate did not admit, so the chat cursor
  ## may pass it without losing it. The file is rewritten whole and renamed
  ## into place: an IO failure raises before the cursor is saved and leaves
  ## the earlier rows byte for byte.
  let path = seat.dir / "jobs" / DeferredFile
  var body = if fileExists(path): readFile(path) else: ""
  if body.len > 0 and not body.endsWith("\n"): body.add "\n"
  body.add $(%*{"key": key, "origin": origin, "actor": actor,
    "actor_guid": actorGuid, "text": text, "scope": $scope, "speaks": speaks}) & "\n"
  writeAtomic(path, body)
  inc gate.deferredByInstanceThisHold
  logLine(seat.dir, %*{"at": epochTime(), "seat": seat.name, "key": key,
    "origin": origin, "deferred": gate.token})

proc replayDeferred(cfg: Config; seat: var SeatState; obs: JsonNode;
    seen: var HashSet[string]): bool =
  ## Handle deferred rows oldest first and report whether none remain. The
  ## file is removed only after every row was handled; the per-key ledger
  ## keeps a row replayed after a crash exactly-once.
  let path = seat.dir / "jobs" / DeferredFile
  if not fileExists(path): return true
  for line in readFile(path).splitLines:
    if line.strip.len == 0: continue
    var row: JsonNode
    try:
      row = parseJson(line)
    except JsonParsingError:
      appendLine(seat.dir / "jobs" / "deferred.bad.jsonl", line)
      continue
    let scope = try: parseEnum[Scope](row{"scope"}.getStr)
      except ValueError: scopeDirect
    if not runAdmitted(cfg, seat, obs, row{"origin"}.getStr, row{"actor"}.getStr,
        row{"actor_guid"}.getStr, row{"text"}.getStr, scope, row{"key"}.getStr,
        seen, row{"speaks"}.getBool(true)):
      return false
  removeFile(path)
  true

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

proc launcherAlive(seatDir: string): bool =
  ## Whether the seat's launcher process is running now.
  let pidFile = seatDir / "launcher.pid"
  if not fileExists(pidFile): return false
  let pid = readFile(pidFile).strip
  pid.len > 0 and dirExists("/proc/" & pid)

proc runningSeats(cfg: Config): seq[string] =
  ## Seats with a live launcher: the configured ones that are running, or
  ## every running home seat when none are configured.
  if cfg.seats.len > 0:
    for name in cfg.seats:
      if launcherAlive(cfg.homeDir / name.strip): result.add name.strip
    return
  for kind, path in walkDir(cfg.homeDir):
    if kind == pcDir and launcherAlive(path):
      result.add path.lastPathPart

proc tick*(cfg: Config; seats: var Table[string, SeatState]) =
  ## One poll over every running seat: refresh observations, choose this
  ## tick's conversation responders, then handle each seat's new chat.
  gate.refresh()
  let names = runningSeats(cfg)
  let now = getTime()
  var live: seq[(string, JsonNode)]
  for name in names:
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
    if mtime != seat.lastMtime:
      seat.lastMtime = mtime
      try:
        seat.obs = parseFile(obsPath)
        seat.pending = true
      except CatchableError: discard
    if not seat.obs.isNil and (now - mtime).inSeconds <= LiveObservationSeconds:
      live.add (name, seat.obs)
    seats[name] = seat
  let partyResponder = responder(live, "party", cfg.authorityGuid)
  let sayResponder = responder(live, "say", cfg.authorityGuid)
  for name in names:
    if not seats.hasKey(name) or seats[name].obs.isNil: continue
    if not seats[name].pending and
        not fileExists(seats[name].dir / "jobs" / DeferredFile): continue
    var seat = seats[name]
    seat.pending = false
    let dir = seat.dir
    let obs = seat.obs
    let episode = obs{"episode_id"}.getStr
    let seatGuid = obs{"player_guid"}.getStr
    if episode != seat.episode:
      # A new session restarts chat numbering; rows from before the broker
      # saw this session are history, not requests.
      seat.episode = episode
      seat.cursor = obs{"chat_messages_last_sequence"}.getBiggestInt
    var seen = seenKeys(dir)
    # Once one row waits, every later row waits behind it in order.
    var backlog = not replayDeferred(cfg, seat, obs, seen)
    for node in obs{"chat_messages"}.getElems:
      let row = ChatRow(sequence: node{"sequence"}.getBiggestInt, kind: node{"kind"}.getStr,
        senderGuid: node{"sender_guid"}.getStr, senderName: node{"sender_name"}.getStr,
        text: node{"text"}.getStr)
      if row.sequence <= seat.cursor: continue
      seat.cursor = row.sequence
      var a = address(row, name, cfg.authorityName, cfg.authorityGuid)
      if a.scope == scopeNone:
        a = ambient(row, cfg.authorityName, cfg.authorityGuid)
      if a.scope == scopeNone or a.text.len == 0: continue
      let chosen = if row.kind == "party": partyResponder else: sayResponder
      let answering = chosen == name
      # An ambient line is handled by the one responder only; a group
      # request is handled everywhere but answered by that responder.
      if a.scope == scopeAmbient and not answering:
        if chosen.len == 0:
          logLine(dir, %*{"at": epochTime(), "seat": name, "origin": row.kind,
            "scope": $a.scope, "sequence": row.sequence,
            "skipped": "no live seat shares the authority's party or view"})
        continue
      let key = jobKey(seatGuid, episode, row.sequence, row.kind)
      let speaks = a.scope != scopeGroup or answering
      if backlog or not runAdmitted(cfg, seat, obs, row.kind, row.senderName,
          row.senderGuid, a.text, a.scope, key, seen, speaks):
        backlog = true
        deferRow(seat, row.kind, row.senderName, row.senderGuid, a.text, a.scope,
          key, speaks)
    # Operator files are not touched while a hold applies.
    let claim = if backlog or gate.state != gsOpen: "" else: claimOperator(dir / "jobs")
    if claim.len > 0:
      var unfinished = false
      for line in readFile(claim).splitLines:
        if line.strip.len == 0: continue
        var req: JsonNode
        try:
          req = parseJson(line)
        except JsonParsingError:
          # A malformed line is set aside instead of failing every tick.
          appendLine(dir / "jobs" / "operator.bad.jsonl", line)
          continue
        if not runAdmitted(cfg, seat, obs, "operator", req{"actor"}.getStr("operator"), "",
            req{"text"}.getStr, scopeDirect, req{"key"}.getStr, seen):
          # The claim stays; handled lines are in the ledger.
          unfinished = true
          break
      if not unfinished: removeFile(claim)
    writeAtomic(dir / "jobs" / "chat_cursor.json",
      $(%*{"episode": seat.episode, "sequence": seat.cursor}))
    deliver(seat)
    seats[name] = seat
  # Publish what this tick left behind (deferred rows, held after a chain),
  # so a receipt never reports an older picture than the work on disk.
  gate.refresh()

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

proc profile*(cfg: Config): JsonNode =
  ## Nonsecret routing identity published with admission status: home,
  ## seats, authority name and GUID, poll interval, endpoints, models, output
  ## allowance and deadline. No keys.
  %*{"homeDir": cfg.homeDir, "seats": cfg.seats, "authority": cfg.authorityName,
    "authorityGuid": cfg.authorityGuid, "pollSeconds": cfg.poll,
    "baseUrl": cfg.baseUrl, "model": cfg.model, "routeBaseUrl": cfg.routeBaseUrl,
    "routeModel": cfg.routeModel, "outputTokens": RoutedOutputTokens,
    "timeoutMs": cfg.timeoutMs}

proc defaultConfig*(homeDir: string): Config =
  ## Broker defaults: Lightning through Switchyard `local`, Kev direct.
  Config(homeDir: homeDir,
    authorityName: "Murist", authorityGuid: "1000007", baseUrl: DefaultBaseUrl,
    model: DefaultModel, apiKey: "unused", routeBaseUrl: DefaultRouteBaseUrl,
    routeModel: DefaultRouteModel, routeApiKey: "none", timeoutMs: RoutedTimeoutMs,
    poll: DefaultPoll)

proc parseConfig(): Config =
  ## Command line; defaults follow the existing local serving profile.
  result = defaultConfig(getCurrentDir() / "local_data" / "home-army")
  for kind, key, value in getopt():
    if kind in {cmdArgument, cmdEnd} or key.len == 0: continue
    case key
    of "home-dir": result.homeDir = value
    of "seats": result.seats = value.split(',')
    of "authority": result.authorityName = value
    of "authority-guid": result.authorityGuid = value
    of "base-url": result.baseUrl = value
    of "model": result.model = value
    of "route-base-url": result.routeBaseUrl = value.strip(leading = false, chars = {'/'})
    of "route-model": result.routeModel = value
    of "poll": result.poll = parseFloat(value)
    of "once": result.once = true
    of "to": result.operatorTo = value
    of "text": result.operatorText = value
    of "help", "h":
      echo "Usage: bot_requests [--home-dir=DIR] [--seats=NAME,...] [--to=NAME --text=REQUEST]"
      quit(0)
    else:
      quit("unknown option: " & key, 2)

proc serviceArtifactRetention(homeDir: string; child: var Process;
    lastStarted: var float) =
  ## Maintain private output off tick in one finite, low-priority child.
  ## Never delay model/game work on a retention scan or start another daemon.
  let statusPath = homeDir / "artifact-retention-status.json"
  try:
    if child != nil and not child.running:
      let
        output = child.outputStream.readAll().strip()
        code = child.waitForExit()
      child.close()
      child = nil
      writeFile(statusPath, $(%*{"observedAt": epochTime(), "exit": code,
        "result": output.substr(0, 4095)}))
    if child == nil and epochTime() - lastStarted >= 600:
      let script = parentDir(parentDir(expandFilename(homeDir))) /
        "tools/private_artifact_retention.sh"
      if not fileExists(script): return
      lastStarted = epochTime()
      child = startProcess("nice", args = @["-n", "10", "ionice", "-c", "2",
        "-n", "7", "timeout", "--kill-after=5s", "90s", "bash", script,
        "--apply"], options = {poUsePath, poStdErrToStdOut})
  except CatchableError as error:
    # A maintenance failure must leave the actual request broker available.
    lastStarted = epochTime()
    try:
      writeFile(statusPath, $(%*{"observedAt": lastStarted,
        "error": error.msg.substr(0, 4095)}))
    except CatchableError:
      discard # A full disk must not turn housekeeping into a chat outage.

proc main() =
  ## Enqueue an operator request, or run the broker loop.
  let cfg = parseConfig()
  if cfg.operatorTo.len > 0:
    if cfg.operatorText.strip.len == 0: quit("--text is required with --to", 2)
    enqueueOperator(cfg)
    return
  echo "bot_requests: watching ", cfg.homeDir, " model=", cfg.model, " via ", cfg.baseUrl,
    " route=", (if cfg.routeModel.len > 0: cfg.routeModel & " via " & cfg.routeBaseUrl else: "lightning")
  modelClient = newCurly()
  defer: modelClient.close()
  gate = openGate(cfg.homeDir, profile(cfg))
  var seats = initTable[string, SeatState]()
  var
    retention: Process
    retentionStarted = 0.0
  while true:
    tick(cfg, seats)
    if cfg.once: break
    serviceArtifactRetention(cfg.homeDir, retention, retentionStarted)
    sleep(int(cfg.poll * 1000))

when isMainModule:
  main()
