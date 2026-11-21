## Request broker contracts: who is addressed, what may be chosen.

import
  std/[json, os, strutils, tables, times, unittest],
  curly,
  ../bot_requests

const
  Murist = "1000007"

proc row(kind, text: string; guid = Murist; name = "Murist"): ChatRow =
  ## One chat row as the seat's observation reports it.
  ChatRow(sequence: 1, kind: kind, senderGuid: guid, senderName: name, text: text)

suite "addressing":
  test "a whisper from the authority is direct":
    let a = row("whisper", "can you stay here").address("Legia", "Murist", Murist)
    check a.scope == scopeDirect and a.text == "can you stay here"

  test "an explicit @recipient in party reaches only that seat":
    let line = row("party", "@Legia come here")
    check line.address("Legia", "Murist", Murist).scope == scopeDirect
    check line.address("Legia", "Murist", Murist).text == "come here"
    check line.address("Vulcan", "Murist", Murist).scope == scopeNone

  test "a raid line is not a request (the seat has no raid reply path)":
    check row("raid", "@Legia come here").address("Legia", "Murist", Murist).scope == scopeNone

  test "a deliberate group request reaches every seat":
    for seat in ["Legia", "Vulcan"]:
      let a = row("party", "@all summon your pets").address(seat, "Murist", Murist)
      check a.scope == scopeGroup and a.text == "summon your pets"

  test "unprefixed party chat and ordinary phrases are not @-addressed":
    for text in ["Can you all hear me", "can you come here", "lol", "@Leg come"]:
      check row("party", text).address("Legia", "Murist", Murist).scope == scopeNone
    # A seat literally named Can is not woken by "Can you ...".
    check row("party", "Can you come").address("Can", "Murist", Murist).scope == scopeNone

  test "anyone but the authority is ignored, by guid and name":
    check row("whisper", "stay", guid = "1000012", name = "Kaisel").address(
      "Legia", "Murist", Murist).scope == scopeNone
    check row("whisper", "stay", guid = "1000012", name = "Murist").address(
      "Legia", "Murist", Murist).scope == scopeNone

suite "decisions":
  let offered: seq[MenuItem] = @[("hold_here", "stay"), ("none", "nothing")]

  test "an offered action is accepted":
    let d = parseDecision("""{"intent":"action","choice":"hold_here"}""", offered)
    check d.intent == "action" and d.choice == "hold_here"

  test "an unoffered action is refused, never defaulted":
    expect ValueError:
      discard parseDecision("""{"intent":"action","choice":"summon_pet"}""", offered)

  test "a question never becomes an action job":
    let d = parseDecision("""{"intent":"question","choice":"hold_here"}""", offered)
    check d.intent == "question" and d.choice == "none"

suite "menu":
  test "repair requires actual known worn damage and an observed repair service":
    var obs = %*{"equipped_durability_known": true, "equipment_items": [{"durability_known": true,
      "max_durability_known": true, "durability": 0, "max_durability": 20}],
      "location": {"map_id": 0, "x": 0, "y": 0, "z": 0},
      "units": [{"services": ["vendor", "repair"], "health_known": true, "health": 50,
        "location": {"map_id": 0, "x": 10, "y": 0, "z": 0}}]}
    proc offersRepair(value: JsonNode): bool =
      for item in menu(value, false, false):
        if item.key == "repair_gear": return true
    check offersRepair(obs)
    obs["equipped_durability_known"] = %false
    check not offersRepair(obs)
    obs["equipped_durability_known"] = %true
    obs["equipment_items"][0]["durability_known"] = %false
    check not offersRepair(obs)
    obs["equipment_items"][0]["durability_known"] = %true
    obs["equipment_items"][0]["durability"] = %20
    check not offersRepair(obs)
    obs["equipment_items"][0]["durability"] = %0
    obs["units"][0]["services"] = %*["vendor"]
    check not offersRepair(obs)

  test "an out-of-view repair is offered only from the seat's fresh catalogued route":
    let obs = %*{"equipped_durability_known": true, "equipment_items": [{"durability_known": true,
      "max_durability_known": true, "durability": 0, "max_durability": 20}],
      "location": {"map_id": 0, "x": 0, "y": 0, "z": 0}, "units": []}
    proc repairOffer(value, status: JsonNode): string =
      for item in menu(value, false, false, status):
        if item.key == "repair_gear": return item.description
    let dir = getTempDir() / "bot_requests_repair_status"
    removeDir(dir)
    createDir(dir / "status")
    defer: removeDir(dir)
    proc writeStatus(route: string; age: float; entry = "home") =
      writeFile(dir / "status" / "status.json", $(%*{
        "entry": entry, "recorded_at_unix_seconds": epochTime() - age,
        "bot": {"repair": {"route": route}}}))
    check seatStatus(dir).isNil
    check repairOffer(obs, nil) == ""
    writeStatus("catalogued", 1.0)
    check "known town repairer" in repairOffer(obs, seatStatus(dir))
    writeStatus("catalogued", 120.0)
    check seatStatus(dir).isNil
    writeStatus("", 1.0)
    check repairOffer(obs, seatStatus(dir)) == ""
    # A status left by another entry never vouches for the home repair job.
    writeStatus("catalogued", 1.0, "traverse")
    check repairOffer(obs, seatStatus(dir)) == ""
    writeFile(dir / "status" / "status.json", "{not json")
    check seatStatus(dir).isNil
    # The seat's raw durability still gates the offer; a stale route alone
    # never offers repair for gear that is not observed damaged.
    writeStatus("catalogued", 1.0)
    var whole = obs.copy
    whole["equipment_items"][0]["durability"] = %20
    check repairOffer(whole, seatStatus(dir)) == ""
    var visible = obs.copy
    visible["units"] = %*[{"services": ["repair"], "health_known": true, "health": 50,
      "location": {"map_id": 0, "x": 10, "y": 0, "z": 0}}]
    check "observed repair vendor" in repairOffer(visible, seatStatus(dir))

  test "repair is not offered for a vendor the seat would refuse":
    var obs = %*{"equipped_durability_known": true, "equipment_items": [{"durability_known": true,
      "max_durability_known": true, "durability": 0, "max_durability": 20}],
      "location": {"map_id": 0, "x": 0, "y": 0, "z": 0},
      "units": [{"services": ["repair"], "health_known": true, "health": 50,
        "location": {"map_id": 0, "x": 10, "y": 0, "z": 0}}]}
    proc offersRepair(value: JsonNode): bool =
      for item in menu(value, false, false):
        if item.key == "repair_gear": return true
    check offersRepair(obs)
    obs["units"][0]["health"] = %0
    check not offersRepair(obs)
    obs["units"][0]["health"] = %50
    obs["units"][0]["death_known"] = %true
    obs["units"][0]["is_dead"] = %true
    check not offersRepair(obs)
    obs["units"][0]["is_dead"] = %false
    obs["units"][0]["player_reaction_hostile"] = %true
    check not offersRepair(obs)
    obs["units"][0]["player_reaction_hostile"] = %false
    obs["units"][0]["location"]["map_id"] = %1
    check not offersRepair(obs)
    obs["units"][0]["location"]["map_id"] = %0
    obs.delete("location")
    check not offersRepair(obs)

  test "only feasible actions are offered":
    let petless = %*{"class_id": 9, "known_spells": [686, 688], "active_pet_guid": "0",
      "copper": 35, "level": 5, "inventory_items": []}
    var keys: seq[string]
    for item in menu(petless, false, false): keys.add item.key
    check "summon_pet" in keys
    check "come_here" notin keys and "train" notin keys and "resume" notin keys
    let withPet = %*{"class_id": 9, "known_spells": [688], "active_pet_guid": "77",
      "active_pet_dead": false, "copper": 300, "level": 5,
      "inventory_items": [{"item_guid": "900000001", "item_id": 900001,
        "definition_known": true, "inventory_type": 7, "required_level": 3}],
      "equipment_upgrade": {"found": true, "item_guid": "900000001",
        "item_id": 900001, "equipment_slot": 6, "item_level": 11,
        "equipped_item_level": 1, "capacity_upgrade": false, "bag_slots": 0}}
    keys = @[]
    for item in menu(withPet, true, true): keys.add item.key
    check "summon_pet" notin keys
    check "come_here" in keys and "wear_upgrades" in keys and "train" in keys and
      "resume" in keys

  test "wear_upgrades follows the observed equipment_upgrade summary":
    proc offersUpgrade(obs: JsonNode): bool =
      for item in menu(obs, requesterVisible = false, jobActive = false):
        if item.key == "wear_upgrades": return true
    let row = %*{"item_guid": "900000001", "item_id": 900001,
      "definition_known": true, "inventory_type": 7, "required_level": 6}
    let found = %*{"found": true, "item_guid": "900000001",
      "item_id": 900001, "equipment_slot": 6, "item_level": 11,
      "equipped_item_level": 1, "capacity_upgrade": false, "bag_slots": 0}
    var obs = %*{"level": 11, "inventory_items": [row], "equipment_upgrade": found}
    check offersUpgrade(obs)
    obs["level"] = %5
    check not offersUpgrade(obs)
    obs["level"] = %11
    obs["equipment_upgrade"]["capacity_upgrade"] = %true
    check not offersUpgrade(obs)
    obs["equipment_upgrade"]["capacity_upgrade"] = %false
    obs["equipment_upgrade"]["found"] = %false
    check not offersUpgrade(obs)
    obs["equipment_upgrade"]["found"] = %true
    obs["inventory_items"] = %*[]
    check not offersUpgrade(obs)
    obs["inventory_items"] = %*[row]
    obs.delete("equipment_upgrade")
    check not offersUpgrade(obs)
    obs["equipment_upgrade"] = found
    obs["inventory_items"][0]["upgrade_score"] = %4
    obs["equipment_upgrade"]["found"] = %false
    check not offersUpgrade(obs)

  test "quest work is offered only for an observed live quest or giver marker":
    proc offersQuests(value: JsonNode): bool =
      for item in menu(value, false, false):
        if item.key == "do_quests": return true
    var obs = %*{"accepted_quests": [], "quest_markers": []}
    check not offersQuests(obs)
    obs["accepted_quests"] = %*[{"quest_id": 100, "failed": true}]
    check not offersQuests(obs)
    obs["accepted_quests"] = %*[{"quest_id": 100, "failed": false}]
    check offersQuests(obs)
    obs["accepted_quests"] = %*[]
    obs["quest_markers"] = %*[{"questgiver_guid": "900", "status": 3}]
    check not offersQuests(obs)
    obs["quest_markers"] = %*[{"questgiver_guid": "900", "status": 5}]
    check offersQuests(obs)
    # The job keeps handing in whichever quests it can until its bounds, so
    # the offer must neither promise one particular quest nor read as ending
    # at the first turn-in.
    for item in menu(obs, false, false):
      if item.key == "do_quests":
        check "whichever quests" in item.description
        check "cannot pick a named quest" in item.description
        check "first quest" notin item.description
        check "turn that in" notin item.description
        check "finish your quest" notin item.description
        check "all quests" notin item.description

  test "replies are one printable line within the chat limit":
    check cleanReply("/w Murist \"hi\"\nthere") == "w Murist hi there"
    check cleanReply("x".repeat(200)).len == 120

  test "unknown health, durability and talent points stay unobserved in model context":
    let unknown = stateLine(%*{"health_known": false, "health": 100,
      "max_health": 100, "unspent_talent_points": 0}, "")
    check "health unobserved" in unknown
    check "broken worn items: unobserved" in unknown
    check "unspent talent points: unobserved" in unknown
    let known = stateLine(%*{"health_known": true, "health": 25, "max_health": 100,
      "equipped_durability_known": true, "equipment_items": [{"durability_known": true,
        "max_durability_known": true, "durability": 0, "max_durability": 20}],
      "talent_points_known": true, "unspent_talent_points": 1}, "")
    check "health 25/100" in known
    check "broken worn items: 1" in known
    check "unspent talent points: 1" in known

suite "operator requests":
  test "pending requests are claimed, and a crash-left claim comes first":
    let jobs = getTempDir() / "test_bot_requests_operator"
    removeDir(jobs)
    createDir(jobs)
    check claimOperator(jobs) == ""
    writeFile(jobs / "operator.jsonl", "{\"key\":\"a\"}\n")
    let claim = claimOperator(jobs)
    check claim == jobs / "operator.claimed.jsonl"
    check not fileExists(jobs / "operator.jsonl")
    check readFile(claim) == "{\"key\":\"a\"}\n"
    writeFile(jobs / "operator.jsonl", "{\"key\":\"b\"}\n")
    check claimOperator(jobs) == claim
    check readFile(claim) == "{\"key\":\"a\"}\n"
    check fileExists(jobs / "operator.jsonl")
    removeDir(jobs)

suite "ambient conversation":
  test "Advisor protocol telemetry never becomes conversation":
    for text in ["<SA> loaded rev=60", "<SA> inv 1/1 25:1", "<SA> invd 1/1 +25:1",
        "<SA> admin tele_party_to_murist", "<SA> err unavailable"]:
      check row("say", text).ambient("Murist", Murist).scope == scopeNone

  test "an unprefixed owner line in party or say is ambient":
    for kind in ["party", "say"]:
      let a = row(kind, "hello there").ambient("Murist", Murist)
      check a.scope == scopeAmbient and a.text == "hello there"

  test "whispers, raid, @-addressed lines and other senders are never ambient":
    check row("whisper", "hello").ambient("Murist", Murist).scope == scopeNone
    check row("raid", "hello").ambient("Murist", Murist).scope == scopeNone
    check row("party", "@Vulcan hello").ambient("Murist", Murist).scope == scopeNone
    check row("party", "   ").ambient("Murist", Murist).scope == scopeNone
    check row("say", "hello", guid = "1000012", name = "Kaisel").ambient(
      "Murist", Murist).scope == scopeNone
    check row("say", "hello", guid = "1000012", name = "Murist").ambient(
      "Murist", Murist).scope == scopeNone

  test "one responder: the first live seat sharing the owner's party":
    let inParty = %*{"party": {"members": [{"guid": Murist, "name": "Murist"}]}}
    let numeric = %*{"party": {"members": [{"guid": 1000007, "name": "Murist"}]}}
    let onlyNear = %*{"party": {"members": []}, "units": [{"guid": Murist}]}
    let elsewhere = %*{"party": {"members": [{"guid": "1000012"}]}, "units": []}
    let live = @[("Zed", inParty), ("Vulcan", numeric), ("Adam", onlyNear),
      ("Aaron", elsewhere)]
    check responder(live, "party", Murist) == "Vulcan"
    check responder(live, "say", Murist) == "Adam"
    check responder(@[("Aaron", elsewhere)], "say", Murist) == ""

suite "grounding":
  test "the state line reports the party and never assumes solo leveling":
    let obs = %*{"level": 5, "party": {"members": [{"guid": Murist, "name": "Murist"},
      {"guid": "2005", "name": "Vulcan"}]}}
    let idle = stateLine(obs, "")
    check "leveling" notin idle and "on its own" notin idle
    check "party: Murist Vulcan" in idle and "task from the player: none" in idle
    check "task from the player: follow_me" in stateLine(obs, "follow_me")
    check "party: none" in stateLine(%*{"level": 5}, "")

suite "route model":
  test "kev's keyed choice is accepted with its probabilities":
    let r = parseRoute("""{"model":"kev-4b","answers":{"intent":{"type":"choice",
      "choice":"chatter","confidence":0.9,"probabilities":{"question":0.05,
      "action":0.05,"chatter":0.9}}},"usage":{"input_tokens":50,"output_tokens":1}}""")
    check r.intent == "chatter" and r.confidence == 0.9 and r.actionProbability == 0.05

  test "malformed kev answers are refused, never defaulted":
    for body in [
        """{"answers":{"intent":{"type":"choice","choice":"dance"}}}""",
        """{"answers":{}}""",
        """{"error":{"message":"no model"}}""",
        """{"answers":{"intent":{"type":"choice","choice":"action","confidence":2}}}""",
        """{"answers":{"intent":{"type":"choice","choice":"action",
          "probabilities":{"action":0.5,"chatter":0.2}}}}"""]:
      expect ValueError:
        discard parseRoute(body)

  test "the route request is a System One keyed choice, not a chat completion":
    let body = routeBody("kev-4b", "Legia", "warlock", "ambient", "level 5", "hello")
    check body{"messages"}.isNil and body{"model"}.getStr == "kev-4b"
    let q = body{"questions"}{"intent"}
    check q{"type"}.getStr == "choice"
    for key in ["question", "action", "chatter"]: check q{"criteria"}.hasKey(key)
    check "not to Legia by name" in body{"state"}.getStr

type
  Stub = object
    routes, decisions, replies: int

var stub: Stub

proc fakePost(url, apiKey, body: string; timeoutMs: int): Response =
  ## Synthetic Kev/Lightning: routes by keyword, offers come_here when asked.
  result.code = 200
  let req = parseJson(body)
  if url.endsWith("/systemone"):
    inc stub.routes
    let state = req{"state"}.getStr
    let message = state[state.find("Message: ") + 9 ..^ 1]
    let intent = if "come" in message or "follow" in message: "action"
      elif "level" in message: "question" else: "chatter"
    var probs = %*{"question": 0.0, "action": 0.0, "chatter": 0.0}
    probs[intent] = %1.0
    result.body = $(%*{"model": "kev-4b", "answers": {"intent": {"type": "choice",
      "choice": intent, "confidence": 0.95, "probabilities": probs}},
      "usage": {"input_tokens": 40, "output_tokens": 1}})
  elif not req{"response_format"}.isNil:
    inc stub.decisions
    let keys = $req{"response_format"}{"json_schema"}{"schema"}{"properties"}{"choice"}{"enum"}
    let choice = if "come_here" in keys: "come_here" else: "none"
    result.body = $(%*{"model": "lightning", "choices": [{"finish_reason": "stop",
      "message": {"content": $(%*{"intent": "action", "choice": choice})}}]})
  else:
    inc stub.replies
    result.body = $(%*{"model": "lightning", "choices": [{"finish_reason": "stop",
      "message": {"content": "Hey Murist, good to see you."}}]})

proc writeSeat(home, name: string; live, inParty: bool; rows: JsonNode;
    stale = false) =
  ## A synthetic seat directory: launcher pid and its own observation.
  let dir = home / name
  createDir(dir / "observer")
  writeFile(dir / "launcher.pid", if live: $getCurrentProcessId() else: "999999999")
  var last = 0
  for r in rows: last = max(last, r{"sequence"}.getInt)
  let obs = %*{"episode_id": "episode-1", "player_guid": "20" & $name.len,
    "class_id": 9, "level": 5, "xp": 10, "next_level_xp": 400, "copper": 20,
    "known_spells": [], "active_pet_guid": "0", "inventory_items": [],
    "location": {"x": 1, "y": 2, "z": 3, "map_id": 0},
    "units": (if inParty: %*[{"guid": Murist, "location": {"x": 4, "y": 5, "z": 3,
      "map_id": 0}}] else: %*[]),
    "party": {"members": (if inParty: %*[{"guid": Murist, "name": "Murist"}] else: %*[])},
    "chat_messages_last_sequence": last, "chat_messages": rows}
  let path = dir / "observer" / "observation.json"
  writeFile(path, $obs)
  # Distinct mtimes per write; a stale seat's observation is old.
  let shift = if stale: -600.0 else: float(last) / 1000.0
  setLastModificationTime(path, fromUnixFloat(epochTime() + shift))

proc chat(sequence: int; kind, text: string; guid = Murist; name = "Murist"): JsonNode =
  ## One synthetic chat row.
  %*{"sequence": sequence, "kind": kind, "sender_guid": guid, "sender_name": name,
    "text": text}

proc jobsOf(home, name: string): seq[JsonNode] =
  ## Every job handed to a seat: its one-slot inbox, then its queue.
  let jobs = home / name / "jobs"
  if fileExists(jobs / "inbox.json"): result.add parseFile(jobs / "inbox.json")
  if fileExists(jobs / "queue.jsonl"):
    for line in lines(jobs / "queue.jsonl"):
      if line.strip.len > 0: result.add parseJson(line)

suite "broker tick":
  let home = getTempDir() / "test_bot_requests_home"
  let main = ["Legia", "Vulcan", "Zed"]

  proc everySeat(rows: JsonNode) =
    ## Main seats in the owner's party, plus an inactive, a stale and an
    ## unrelated live seat that all heard the same lines.
    for name in main: writeSeat(home, name, true, true, rows)
    writeSeat(home, "Aaron", false, true, rows)
    writeSeat(home, "Abel", true, true, rows, stale = true)
    writeSeat(home, "Adam", true, false, rows)

  proc clearJobs() =
    ## Take every delivered job, as the seats would.
    for name in ["Aaron", "Abel", "Adam", "Legia", "Vulcan", "Zed"]:
      removeFile(home / name / "jobs" / "inbox.json")
      removeFile(home / name / "jobs" / "queue.jsonl")

  test "greeting, explicit routing, negatives and restart dedup":
    removeDir(home)
    postJson = fakePost
    stub = Stub()
    var cfg = defaultConfig(home)
    cfg.seats = @["Aaron", "Abel", "Adam", "Legia", "Vulcan", "Zed", "Ghost"]
    var seats = initTable[string, SeatState]()

    # History present at startup is never replayed.
    var rows = %*[chat(5, "party", "hello from before")]
    everySeat(rows)
    tick(cfg, seats)
    check stub == Stub()

    # One unprefixed greeting gets one reply from the first live party seat;
    # other users, private whispers to others and raid lines get nothing.
    rows.add chat(6, "party", "hello everyone")
    rows.add chat(7, "say", "hi all", guid = "1000012", name = "Kaisel")
    rows.add chat(8, "whisper", "hello", guid = "1000012", name = "Kaisel")
    rows.add chat(9, "raid", "hello raid")
    everySeat(rows)
    tick(cfg, seats)
    check stub.routes == 1 and stub.replies == 1 and stub.decisions == 0
    let greeting = jobsOf(home, "Legia")
    check greeting.len == 1
    check greeting[0]{"intent"}.getStr == "chatter"
    check greeting[0]{"choice"}.getStr == "none"
    check greeting[0]{"origin"}.getStr == "party"
    check greeting[0]{"reply"}.getStr == "Hey Murist, good to see you."
    for name in ["Aaron", "Abel", "Adam", "Vulcan", "Zed"]:
      check jobsOf(home, name).len == 0
    clearJobs()

    # Unchanged observations and a restarted broker do not answer again.
    tick(cfg, seats)
    var restarted = initTable[string, SeatState]()
    everySeat(rows)
    tick(cfg, restarted)
    check stub.routes == 1 and stub.replies == 1

    # A whisper still reaches its own seat and a question never becomes a
    # job; a natural owner "follow me" in party has @Seat authority: Kev
    # routes it to action, Lightning picks an offered key, and exactly the
    # one responder gets the job.
    rows.add chat(10, "whisper", "what level are you")
    rows.add chat(11, "party", "follow me")
    for name in main:
      var own = rows.copy
      if name != "Vulcan": own.elems.delete(own.len - 2)
      writeSeat(home, name, true, true, own)
    tick(cfg, restarted)
    let answer = jobsOf(home, "Vulcan")
    check answer.len == 1
    check answer[0]{"intent"}.getStr == "question"
    check answer[0]{"choice"}.getStr == "none"
    check answer[0]{"origin"}.getStr == "whisper"
    check answer[0]{"actor"}.getStr == "Murist"
    check stub.decisions == 1
    let follow = jobsOf(home, "Legia")
    check follow.len == 1
    check follow[0]{"intent"}.getStr == "action"
    check follow[0]{"choice"}.getStr == "come_here"
    check follow[0]{"origin"}.getStr == "party"
    check follow[0]{"actor"}.getStr == "Murist"
    check follow[0]{"actor_guid"}.getStr == Murist
    check follow[0]{"x"}.getFloat == 4.0
    check jobsOf(home, "Zed").len == 0
    for name in ["Aaron", "Abel", "Adam"]: check jobsOf(home, name).len == 0
    clearJobs()

    # @party: the action reaches every main seat; conversation is answered once.
    rows.add chat(12, "party", "@party come here")
    rows.add chat(13, "party", "@party hello friends")
    everySeat(rows)
    tick(cfg, restarted)
    for name in main:
      let jobs = jobsOf(home, name)
      check jobs.len == (if name == "Legia": 2 else: 1)
      check jobs[0]{"choice"}.getStr == "come_here"
    check jobsOf(home, "Legia")[1]{"intent"}.getStr == "chatter"
    check jobsOf(home, "Legia")[1]{"reply"}.getStr.len > 0
    removeDir(home)
