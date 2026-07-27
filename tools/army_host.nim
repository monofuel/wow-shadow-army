## Nim army host — external-policy loop without Python.
##
## Connects to nim_control (JSON requests, msgpack env frames), projects a
## small table for Lua tools, runs `decide` via lua5.3, maps intents, selects.
##
##   nim r tools/army_host.nim --slot:2 --tool:escort_leader --leader:Murist
##
## Cadence defaults 0.35s; only selects when action_ready.

import
  std/[
    endians, json, math, options, os, osproc, parseopt, sets, strformat, strutils,
    streams, net, times
  ],
  msgpack_json, party_promote

const
  Protocol = "vanilla_wow.nim_control.v1"
  Magic = 0x44524E4Bu32
  Version = 2'u16
  FrameGoal = 1'u16
  FrameSelect = 3'u16
  FrameStatusReq = 4'u16
  FrameControlStatus = 5'u16
  FrameEnv = 6'u16
  FrameErr = 8'u16
  BasePort = 41114

type
  HostConfig = object
    slot: int
    tool: string
    leader: string
    ## Control slot for the human leader (default 0 = Murist :41114). Used to
    ## overlay live xy/combat onto party projection when party packets lag.
    leaderSlot: int
    party: seq[string]
    goalId: string
    cadence: float
    acceptFrom: string
    maxSeconds: float
    quiet: bool

proc jget(n: JsonNode; keys: varargs[string]): JsonNode =
  result = n
  for k in keys:
    if result.isNil or result.kind != JObject or k notin result:
      return nil
    result = result[k]

proc jstr(n: JsonNode; def = ""): string =
  if n.isNil: return def
  case n.kind
  of JString: n.getStr
  of JInt: $n.getInt
  of JFloat: $n.getFloat
  of JBool: $n.getBool
  else: def

proc jbool(n: JsonNode; def = false): bool =
  if n.isNil: return def
  case n.kind
  of JBool: n.getBool
  of JInt: n.getInt != 0
  else: def

proc jnum(n: JsonNode; def = 0.0): float =
  if n.isNil: return def
  case n.kind
  of JFloat: n.getFloat
  of JInt: n.getInt.float
  of JString:
    try: parseFloat(n.getStr)
    except: def
  else: def

proc jint(n: JsonNode; def = 0): int =
  if n.isNil: return def
  case n.kind
  of JInt: n.getInt
  of JFloat: n.getFloat.int
  of JString:
    try: parseInt(n.getStr)
    except: def
  else: def

proc sendFrame(s: Socket; frameType: uint16; reqId: uint32; payload: string) =
  var header = newString(16)
  var magic = Magic
  var ver = Version
  var ft = frameType
  var rid = reqId
  var plen = uint32(payload.len)
  littleEndian32(addr header[0], addr magic)
  littleEndian16(addr header[4], addr ver)
  littleEndian16(addr header[6], addr ft)
  littleEndian32(addr header[8], addr rid)
  littleEndian32(addr header[12], addr plen)
  let data = header & payload
  var sent = 0
  while sent < data.len:
    let n = s.send(data[sent].addr, data.len - sent)
    if n <= 0:
      raise newException(IOError, "send failed")
    sent += n

proc recvExact(s: Socket; n: int): string =
  result = newString(n)
  var got = 0
  while got < n:
    let k = s.recv(addr result[got], n - got)
    if k <= 0:
      raise newException(IOError, "socket closed")
    got += k

proc recvFrame(s: Socket): tuple[ft: uint16, rid: uint32, payload: string] =
  let h = s.recvExact(16)
  var magic, rid, plen: uint32
  var ver, ft: uint16
  littleEndian32(addr magic, addr h[0])
  littleEndian16(addr ver, addr h[4])
  littleEndian16(addr ft, addr h[6])
  littleEndian32(addr rid, addr h[8])
  littleEndian32(addr plen, addr h[12])
  if magic != Magic:
    raise newException(IOError, "bad magic")
  (ft, rid, s.recvExact(int(plen)))

type
  ControlClient = ref object
    sock: Socket
    slot: int
    reqId: uint32

proc connectClient(slot: int): ControlClient =
  result = ControlClient(slot: slot, reqId: 0)
  result.sock = newSocket()
  result.sock.connect("127.0.0.1", Port(BasePort + slot))

proc close(c: ControlClient) =
  if c.sock != nil:
    c.sock.close()
    c.sock = nil

proc request(c: ControlClient; frameType: uint16; body: JsonNode):
    tuple[ft: uint16, node: JsonNode, raw: string] =
  inc c.reqId
  let payload = $body
  c.sock.sendFrame(frameType, c.reqId, payload)
  let (ft, rid, raw) = c.sock.recvFrame()
  if rid != c.reqId:
    raise newException(IOError, "request id mismatch")
  if ft == FrameErr:
    raise newException(IOError, "control error: " & raw)
  if ft == FrameEnv:
    return (ft, unpackJson(raw), raw)
  return (ft, parseJson(raw), raw)

proc statusJson(c: ControlClient): JsonNode =
  let body = %*{
    "protocol": Protocol,
    "type": "status_request",
    "expected_slot": c.slot,
    "include_environment_frame": false,
    "include_action_settled": false
  }
  let (ft, node, _) = c.request(FrameStatusReq, body)
  if ft != FrameControlStatus:
    raise newException(IOError, "expected control_status")
  node

proc envFrame(c: ControlClient): JsonNode =
  let body = %*{
    "protocol": Protocol,
    "type": "status_request",
    "expected_slot": c.slot,
    "include_environment_frame": true,
    "include_action_settled": false
  }
  let (ft, node, _) = c.request(FrameStatusReq, body)
  if ft != FrameEnv:
    raise newException(IOError, "expected environment_frame got " & $ft)
  node

proc submitGoal(c: ControlClient; goalId, leader: string; party: seq[string];
    revision: int) =
  let body = %*{
    "protocol": Protocol,
    "type": "goal_request",
    "goal_id": goalId,
    "goal_kind": "leveling",
    "bot_id": "relh-roam",
    "profile_id": "",
    "task_id": "",
    "role": "",
    "leader_name": leader,
    "party_members": party,
    "stop_level": 0,
    "deadline_unix_seconds": 0.0,
    "expected_slot": c.slot,
    "expected_revision": revision,
    "selection_mode": "external",
    "practice_reset": false,
    "rfc_launch": false
  }
  discard c.request(FrameGoal, body)

proc selectAction(c: ControlClient; action: JsonNode; frameId, tick, rev: int) =
  # Wire always requires destination key (null for non-move, object for move).
  var act = copy(action)
  if act.kind == JObject:
    if jstr(jget(act, "kind")) == "move":
      let dest = jget(act, "destination")
      if dest.isNil or dest.kind != JObject:
        raise newException(ValueError, "move without destination")
    else:
      act["destination"] = newJNull()
  let body = %*{
    "protocol": Protocol,
    "type": "action_selection",
    "action": act,
    "frame_id": frameId,
    "observed_tick": tick,
    "expected_slot": c.slot,
    "expected_revision": rev
  }
  discard c.request(FrameSelect, body)

# ---------- projection (subset of brain/frame_projection.py) ----------

proc kindsList(frame: JsonNode): seq[string] =
  result = @[]
  let kinds = jget(frame, "action_space", "kinds")
  if kinds.isNil or kinds.kind != JArray: return
  for k in kinds:
    result.add k.getStr

proc kindAllows(frame: JsonNode; kind: string): bool =
  let kinds = kindsList(frame)
  let i = kinds.find(kind)
  if i < 0: return false
  let row = jget(frame, "action_mask", "kind")
  if row.isNil or row.kind != JArray or i >= row.len: return false
  jbool(row[i])

proc targetAllows(frame: JsonNode; kind: string; entityIndex: int): bool =
  if not kindAllows(frame, kind): return false
  let kinds = kindsList(frame)
  let ki = kinds.find(kind)
  let mask = jget(frame, "action_mask", "target")
  if mask.isNil or mask.kind != JArray or ki >= mask.len: return false
  let row = mask[ki]
  if row.kind != JArray or entityIndex >= row.len: return false
  jbool(row[entityIndex])

proc questFactorAllows(frame: JsonNode; kind: string; factor: int): bool =
  if not kindAllows(frame, kind): return false
  let kinds = kindsList(frame)
  let ki = kinds.find(kind)
  let mask = jget(frame, "action_mask", "quest")
  if mask.isNil or mask.kind != JArray or ki >= mask.len: return false
  let row = mask[ki]
  if row.kind != JArray or factor >= row.len: return false
  jbool(row[factor])

proc firstQuestFactor(frame: JsonNode; kind: string): int =
  ## Factorized quest index (NOT quest_id). 0 is valid when dialog admits it.
  if not kindAllows(frame, kind): return -1
  let kinds = kindsList(frame)
  let ki = kinds.find(kind)
  let mask = jget(frame, "action_mask", "quest")
  if mask.isNil or mask.kind != JArray or ki >= mask.len: return -1
  let row = mask[ki]
  if row.kind != JArray: return -1
  for i in 0 ..< row.len:
    if jbool(row[i]): return i
  return -1

proc questBindingFactor(frame: JsonNode; questId: int): int =
  ## Map quest_id → bindings.quests[].index when present.
  let qs = jget(frame, "bindings", "quests")
  if qs.isNil or qs.kind != JArray: return -1
  for q in qs:
    if jint(jget(q, "quest_id")) == questId:
      return jint(jget(q, "index"))
  return -1

proc projectEscort(frame: JsonNode; preferLeaderName = ""): JsonNode =
  ## Build the plain table escort_leader / warlock_imp_quest expect.
  ## preferLeaderName: when set (e.g. human Murist), follow that party member
  ## even if the party leader flag is on another seat.
  let obs = jget(frame, "observation")
  let loc = jget(obs, "location")
  let selfUnit = %*{
    "x": jnum(jget(loc, "x")),
    "y": jnum(jget(loc, "y")),
    "z": jnum(jget(loc, "z")),
    "map_id": jnum(jget(loc, "map_id")),
    "class_id": jint(jget(obs, "class_id"))
  }
  var leaderUnit = newJNull()
  let party = jget(obs, "party")
  if jbool(jget(party, "in_group")):
    let ents = jget(frame, "bindings", "entities")
    var found: JsonNode = nil
    let prefer = preferLeaderName.toLowerAscii
    let partyLeaderName = jstr(jget(party, "leader_name")).toLowerAscii
    let partyLeaderGuid = jstr(jget(party, "leader_guid"))
    # Prefer explicit host --leader name (human Murist) over party flag.
    let leaderName = if prefer.len > 0: prefer else: partyLeaderName
    var leaderGuid = ""
    if prefer.len == 0:
      leaderGuid = partyLeaderGuid
    else:
      # Resolve guid for preferred name from members.
      let members = jget(party, "members")
      if not members.isNil and members.kind == JArray:
        for m in members:
          if jstr(jget(m, "name")).toLowerAscii == prefer:
            leaderGuid = jstr(jget(m, "guid"))
            break
    if not ents.isNil and ents.kind == JArray:
      for e in ents:
        let kind = jstr(jget(e, "kind")).toLowerAscii
        # Party rows first; also accept player entity for the leader guid.
        if kind notin ["party", "player"]: continue
        let eg = jstr(jget(e, "guid"))
        let en = jstr(jget(e, "name")).toLowerAscii
        if (leaderGuid.len > 0 and eg == leaderGuid) or
            (leaderName.len > 0 and en == leaderName):
          found = e
          if kind == "party":
            break
    if not found.isNil:
      let idx = jint(jget(found, "index"))
      let eloc = jget(found, "location")
      var x = jnum(jget(eloc, "x"))
      var y = jnum(jget(eloc, "y"))
      var z = jnum(jget(eloc, "z"))
      var mapId = jnum(jget(eloc, "map_id"))
      var visible = true
      var leaderHpPct = 100.0
      var leaderInCombat = false
      # Prefer live observation.units row for the leader guid — party binding
      # locations are often stale/zero-z and can equal the follower's own
      # square, which falsely kills rejoin.
      let unitsObs = jget(obs, "units")
      if not unitsObs.isNil and unitsObs.kind == JArray and leaderGuid.len > 0:
        for u in unitsObs:
          if jstr(jget(u, "guid")) == leaderGuid:
            let uloc = jget(u, "location")
            if not uloc.isNil:
              x = jnum(jget(uloc, "x"), x)
              y = jnum(jget(uloc, "y"), y)
              z = jnum(jget(uloc, "z"), z)
              mapId = jnum(jget(uloc, "map_id"), mapId)
              visible = true
            if jget(u, "in_combat") != nil:
              leaderInCombat = jbool(jget(u, "in_combat"))
            break
      # last_visible: fill missing z only. Party xy can be correct while z=0;
      # overwriting xy with last_visible collapses rejoin onto the follower.
      # Also project leader health (party members) so OOC join can assist when
      # the human is fighting — attack kind is false OOC, assist is not.
      let members = jget(party, "members")
      if not members.isNil and members.kind == JArray:
        for m in members:
          if jbool(jget(m, "leader")) or
              jstr(jget(m, "name")).toLowerAscii == leaderName:
            let last = jget(m, "last_visible_location")
            let locKnown = jbool(jget(m, "location_known"))
            if not last.isNil:
              let lz = jnum(jget(last, "z"))
              let lx = jnum(jget(last, "x"))
              let ly = jnum(jget(last, "y"))
              if not locKnown and (x == 0.0 and y == 0.0) and lx != 0.0:
                x = lx
                y = ly
                z = lz
                mapId = jnum(jget(last, "map_id"), mapId)
              elif z == 0.0 and lz != 0.0:
                z = lz
            if jbool(jget(m, "health_known")):
              let mh = max(1.0, jnum(jget(m, "max_health"), 1.0))
              let hh = jnum(jget(m, "health"), mh)
              leaderHpPct = hh / mh * 100.0
            if jget(m, "in_combat") != nil:
              leaderInCombat = leaderInCombat or jbool(jget(m, "in_combat"))
            break
      # Damaged leader with no explicit in_combat bit still means join window.
      if not leaderInCombat and leaderHpPct < 99.5:
        leaderInCombat = true
      leaderUnit = %*{
        "id": idx,
        "x": x,
        "y": y,
        "z": z,
        "map_id": mapId,
        "visible": visible,
        "assistable": targetAllows(frame, "assist", idx),
        "health_pct": leaderHpPct,
        "in_combat": leaderInCombat
      }

  # combat casts from spell mask
  var casts = newJArray()
  let spellMask = jget(frame, "action_mask", "spell")
  let spells = jget(frame, "bindings", "spells")
  if not spellMask.isNil and spellMask.kind == JArray and kindAllows(frame, "cast"):
    for ti in 0 ..< spellMask.len:
      let row = spellMask[ti]
      if row.kind != JArray: continue
      for si in 1 ..< row.len:
        if not jbool(row[si]): continue
        var name = ""
        var spellId = 0
        if not spells.isNil and spells.kind == JArray and si - 1 < spells.len:
          name = jstr(jget(spells[si - 1], "name"))
          spellId = jint(jget(spells[si - 1], "spell_id"))
        casts.add %*{
          "target": ti,
          "spell": si,
          "name": name,
          "spell_id": spellId
        }

  var attackable = newJArray()
  var focusId = 0
  let focusGuid = jstr(jget(obs, "combat_focus_guid"))
  let autoGuid = jstr(jget(obs, "auto_attack_guid"))
  let ents = jget(frame, "bindings", "entities")
  if not ents.isNil and ents.kind == JArray:
    for e in ents:
      let idx = jint(jget(e, "index"))
      if idx <= 0: continue
      let eg = jstr(jget(e, "guid"))
      let kind = jstr(jget(e, "kind")).toLowerAscii
      if kind in ["self", "party", "player"]: continue
      if eg == focusGuid or eg == autoGuid:
        focusId = idx
      let lootable = jbool(jget(e, "lootable"))
      if not targetAllows(frame, "attack", idx) and not lootable: continue
      let eloc = jget(e, "location")
      var entry = %*{"id": idx, "guid": eg, "lootable": lootable}
      if not eloc.isNil:
        entry["x"] = %jnum(jget(eloc, "x"))
        entry["y"] = %jnum(jget(eloc, "y"))
        entry["z"] = %jnum(jget(eloc, "z"))
        entry["map_id"] = %jnum(jget(eloc, "map_id"))
      attackable.add entry

  # mana/health pct
  let maxHp = max(1.0, jnum(jget(obs, "max_health"), 1.0))
  let hp = jnum(jget(obs, "health"), maxHp)
  let maxMana = max(1.0, jnum(jget(obs, "max_power"), 1.0))
  let mana = jnum(jget(obs, "power"), maxMana)

  # quest projection
  var offers = newJArray()
  let qOffers = jget(obs, "quest_offers")
  if not qOffers.isNil and qOffers.kind == JArray:
    for o in qOffers:
      let qid = jint(jget(o, "quest_id"))
      var qf = questBindingFactor(frame, qid)
      if qf < 0:
        qf = firstQuestFactor(frame, "accept_quest")
      if qf < 0:
        qf = 0
      var entityId = 0
      let entsO = jget(frame, "bindings", "entities")
      if not entsO.isNil and entsO.kind == JArray:
        for e in entsO:
          let idx = jint(jget(e, "index"))
          if targetAllows(frame, "accept_quest", idx):
            entityId = idx
            break
      offers.add %*{
        "id": qid,
        "entity_id": entityId,
        "quest_factor": qf,
        "title": jstr(jget(o, "title"))
      }
  # Dialog-open discovery: accept kind allowed but no concrete offer rows yet.
  if offers.len == 0 and kindAllows(frame, "accept_quest"):
    var entityId = 0
    let entsA = jget(frame, "bindings", "entities")
    if not entsA.isNil and entsA.kind == JArray:
      for e in entsA:
        let idx = jint(jget(e, "index"))
        if targetAllows(frame, "accept_quest", idx):
          entityId = idx
          break
    var qf = firstQuestFactor(frame, "accept_quest")
    if qf < 0:
      qf = 0
    if entityId > 0 or qf >= 0:
      offers.add %*{
        "id": 0,
        "entity_id": entityId,
        "quest_factor": qf,
        "title": ""
      }
  # Inventory counts for quest item progress (1470 Rattlecage Skull = 6281).
  var skullCount = 0
  let inv = jget(obs, "inventory_items")
  if not inv.isNil and inv.kind == JArray:
    for it in inv:
      if jint(jget(it, "item_id")) == 6281:
        skullCount = jint(jget(it, "count"))
        break

  # Server-side completed set (objectives done, ready to turn in).
  var completedIds = initHashSet[int]()
  let completed = jget(obs, "completed_quest_ids")
  if not completed.isNil and completed.kind == JArray:
    for c in completed:
      completedIds.incl jint(c)

  var active = newJArray()
  let qLog = jget(obs, "quest_log_quest_ids")
  let accepted = jget(obs, "accepted_quests")
  proc addActive(qid: int) =
    var itemCount = 0
    var complete = qid in completedIds
    if qid == 1470:
      itemCount = skullCount
      if skullCount >= 3:
        complete = true
    active.add %*{
      "id": qid,
      "complete": complete,
      "item_count": itemCount
    }
  if not accepted.isNil and accepted.kind == JArray:
    for a in accepted:
      addActive(jint(jget(a, "quest_id")))
  elif not qLog.isNil and qLog.kind == JArray:
    for qid in qLog:
      addActive(jint(qid))

  # Turn-ins: entity with turn_in_quest target mask.
  # Wire `quest` is 1-based index into bindings.quests (NOT quest_id, NOT 0).
  # policy.quest==0 leaves questId=0 and turnInQuestAtQuestgiver fails.
  var turnIns = newJArray()
  let bind1470 = questBindingFactor(frame, 1470)
  var qFactorTurn = -1
  if bind1470 > 0 and (
      questFactorAllows(frame, "turn_in_quest", bind1470) or
      kindAllows(frame, "turn_in_quest")
  ):
    qFactorTurn = bind1470
  if qFactorTurn < 0:
    let f = firstQuestFactor(frame, "turn_in_quest")
    if f > 0:
      qFactorTurn = f
  let entsAll = jget(frame, "bindings", "entities")
  if qFactorTurn > 0 and not entsAll.isNil and entsAll.kind == JArray:
    for e in entsAll:
      let idx = jint(jget(e, "index"))
      if idx <= 0: continue
      if targetAllows(frame, "turn_in_quest", idx):
        turnIns.add %*{
          "id": 1470,
          "entity_id": idx,
          "quest_factor": qFactorTurn
        }

  # Interactable units/objects for open-dialog path (Venya before masks appear).
  # Prefer units with questgiver service; pass services so Lua can skip vendors
  # that open empty gossip and sticky-accept forever.
  var interactables = newJArray()
  if not entsAll.isNil and entsAll.kind == JArray:
    for e in entsAll:
      let idx = jint(jget(e, "index"))
      let kind = jstr(jget(e, "kind")).toLowerAscii
      if idx <= 0: continue
      if kind in ["self", "party", "player"]: continue
      if not targetAllows(frame, "interact", idx): continue
      let eloc = jget(e, "location")
      var services = newJArray()
      let sv = jget(e, "services")
      var isQuestgiver = false
      if not sv.isNil and sv.kind == JArray:
        for s in sv:
          let sn = jstr(s).toLowerAscii
          services.add %sn
          if sn == "questgiver":
            isQuestgiver = true
      # Also match observation units by guid for entry + services if entity lacks them.
      var creatureEntry = 0
      let guidStr = jstr(jget(e, "guid"))
      let unitsObs = jget(obs, "units")
      if not unitsObs.isNil and unitsObs.kind == JArray:
        for u in unitsObs:
          if jstr(jget(u, "guid")) == guidStr:
            creatureEntry = jint(jget(u, "entry"))
            let usv = jget(u, "services")
            if not usv.isNil and usv.kind == JArray:
              for s in usv:
                let sn = jstr(s).toLowerAscii
                var already = false
                for existing in services:
                  if jstr(existing) == sn:
                    already = true
                    break
                if not already:
                  services.add %sn
                if sn == "questgiver":
                  isQuestgiver = true
            break
      var entry = %*{
        "id": idx,
        "kind": kind,
        "is_questgiver": isQuestgiver,
        "entry": creatureEntry,
        "services": services
      }
      if not eloc.isNil:
        entry["x"] = %jnum(jget(eloc, "x"))
        entry["y"] = %jnum(jget(eloc, "y"))
        entry["z"] = %jnum(jget(eloc, "z"))
        entry["map_id"] = %jnum(jget(eloc, "map_id"))
      interactables.add entry
  # Prefer pure questgivers first (no vendor/trainer/innkeeper) so decide walks
  # the useful surface before empty gossip NPCs.
  var ranked = newJArray()
  var rest = newJArray()
  for it in interactables:
    let sv = jget(it, "services")
    var pureQg = jbool(jget(it, "is_questgiver"))
    if pureQg and not sv.isNil and sv.kind == JArray:
      for s in sv:
        let sn = jstr(s)
        if sn in ["vendor", "trainer", "innkeeper"]:
          pureQg = false
          break
    if pureQg:
      ranked.add it
    else:
      rest.add it
  interactables = ranked
  for it in rest:
    interactables.add it

  var abilities = newJObject()
  let known = jget(obs, "known_spells")
  # Summon Imp classic id 688
  if not known.isNil and known.kind == JArray:
    for sid in known:
      if jint(sid) == 688:
        # find spell binding index for cast
        if not spells.isNil and spells.kind == JArray:
          var si = 0
          for sp in spells:
            inc si
            if jint(jget(sp, "spell_id")) == 688:
              abilities["summon_imp"] = %*{"spell": si}
              break

  let death = %*{
    "is_dead": jbool(jget(obs, "is_dead")),
    "is_ghost": jbool(jget(obs, "is_ghost")),
    "can_reclaim_corpse": jbool(jget(obs, "can_reclaim_corpse")),
    "can_release_spirit": kindAllows(frame, "release_spirit"),
    "can_reclaim_action": kindAllows(frame, "reclaim_corpse"),
    "can_move": kindAllows(frame, "move"),
    "corpse_known": jbool(jget(obs, "corpse_known")),
    "corpse": newJNull()
  }
  let cl = jget(obs, "corpse_location")
  if jbool(jget(obs, "corpse_known")) and not cl.isNil:
    death["corpse"] = %*{
      "map_id": jnum(jget(cl, "map_id")),
      "x": jnum(jget(cl, "x")),
      "y": jnum(jget(cl, "y")),
      "z": jnum(jget(cl, "z"))
    }
    death["corpse_known"] = %true

  result = %*{
    "self_unit": selfUnit,
    "party": %*{"leader_unit": leaderUnit},
    "combat": %*{
      "in_combat": jbool(jget(obs, "in_combat")),
      "mana_pct": mana / maxMana * 100.0,
      "health_pct": hp / maxHp * 100.0,
      "focus_guid": focusGuid,
      "auto_attack_guid": autoGuid,
      "focus_id": focusId,
      "attackable": attackable,
      "casts": casts
    },
    "death": death,
    "quest": %*{
      "offers": offers,
      "active": active,
      "turn_ins": turnIns,
      "interactables": interactables,
      "masks_empty": offers.len == 0 and active.len == 0 and turnIns.len == 0
    },
    "abilities": abilities
  }

# ---------- Lua decide ----------

proc luaEscape(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    else: result.add ch
  result.add '"'

proc toLua(n: JsonNode): string =
  if n.isNil: return "nil"
  case n.kind
  of JNull: "nil"
  of JBool: (if n.getBool: "true" else: "false")
  of JInt: $n.getInt
  of JFloat:
    let f = n.getFloat
    if f == f.int.float: $f.int & ".0"
    else: $f
  of JString: luaEscape(n.getStr)
  of JArray:
    var parts: seq[string]
    for x in n: parts.add toLua(x)
    "{" & parts.join(", ") & "}"
  of JObject:
    var parts: seq[string]
    for k, v in n.pairs:
      parts.add "[" & luaEscape(k) & "] = " & toLua(v)
    "{" & parts.join(", ") & "}"

proc runDecide(tool: string; proj: JsonNode): JsonNode =
  let repo = getCurrentDir()
  let script = """
package.path = [[$1/lua/?.lua;$1/lua/tools/?.lua;;]]
local registry = require("registry")
require("$2")
local tool = registry.get("$2")
local frame = $3
local intent = tool.decide(frame, {})
local function enc(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then return tostring(v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "table" then
    local isArr = true
    local n = 0
    for k,_ in pairs(v) do
      if type(k) ~= "number" then isArr = false break end
      if k > n then n = k end
    end
    if isArr then
      local p = {}
      for i=1,n do p[i] = enc(v[i]) end
      return "[" .. table.concat(p, ",") .. "]"
    else
      local p = {}
      for k,val in pairs(v) do
        p[#p+1] = string.format("%q", tostring(k)) .. ":" .. enc(val)
      end
      return "{" .. table.concat(p, ",") .. "}"
    end
  else return "null" end
end
print(enc(intent))
""" % [repo, tool, toLua(proj)]
  let tmp = getTempDir() / ("army_decide_" & $getCurrentProcessId() & ".lua")
  writeFile(tmp, script)
  var bin = findExe("lua5.3")
  if bin.len == 0:
    bin = findExe("lua")
  if bin.len == 0:
    # Match Makefile RUN_LUA fallback.
    let (nixOut, nixCode) = execCmdEx(
      "nix shell nixpkgs#lua5_3 --command which lua"
    )
    if nixCode == 0:
      bin = nixOut.strip().splitLines()[^1].strip()
  if bin.len == 0:
    raise newException(IOError, "lua5.3/lua not found")
  let (outp, code) = execCmdEx(bin & " " & quoteShell(tmp))
  removeFile(tmp)
  if code != 0:
    raise newException(IOError, "lua decide failed: " & outp)
  let line = outp.strip().splitLines()[^1]
  parseJson(line)

# ---------- intent → factorized action ----------

proc mapIntent(intent: JsonNode): Option[JsonNode] =
  if intent.isNil or intent.kind != JObject: return none(JsonNode)
  let kind = jstr(jget(intent, "kind"))
  case kind
  of "hold", "":
    return none(JsonNode)
  of "move_to_unit":
    if jget(intent, "x") != nil and jget(intent, "y") != nil and jget(intent, "z") != nil:
      return some(%*{
        "kind": "move",
        "target": 0,
        "spell": 0,
        "item": 0,
        "equipment_slot": 0,
        "quest": 0,
        "choice": 0,
        "recipient": 0,
        "text": 0,
        "trigger": 0,
        "dialog": 0,
        "destination": {
          "map_id": jint(jget(intent, "map_id")),
          "x": jnum(jget(intent, "x")),
          "y": jnum(jget(intent, "y")),
          "z": jnum(jget(intent, "z")),
          "orientation": 0.0
        }
      })
    let uid = jint(jget(intent, "unit_id"))
    if uid <= 0: return none(JsonNode)
    return some(%*{
      "kind": "follow", "target": uid, "spell": 0, "item": 0,
      "equipment_slot": 0, "quest": 0, "choice": 0, "recipient": 0,
      "text": 0, "trigger": 0, "dialog": 0
    })
  of "assist_unit":
    return some(%*{
      "kind": "assist", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0, "quest": 0, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "promote_party":
    return some(%*{
      "kind": "promote_party", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0, "quest": 0, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "attack_unit":
    return some(%*{
      "kind": "attack", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0, "quest": 0, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "cast_spell":
    return some(%*{
      "kind": "cast",
      "target": jint(jget(intent, "unit_id")),
      "spell": jint(jget(intent, "spell")),
      "item": 0, "equipment_slot": 0, "quest": 0, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "accept_party":
    return some(%*{"kind": "accept_party", "target": 0, "spell": 0, "item": 0,
      "equipment_slot": 0, "quest": 0, "choice": 0, "recipient": 0,
      "text": 0, "trigger": 0, "dialog": 0})
  of "accept_quest":
    # `quest` on the wire is the factorized binding index, not quest_id.
    var qf = jint(jget(intent, "quest_factor"))
    if jget(intent, "quest_factor").isNil:
      qf = 0
    return some(%*{
      "kind": "accept_quest", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0,
      "quest": qf, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "turn_in_quest":
    var qf = jint(jget(intent, "quest_factor"))
    if jget(intent, "quest_factor").isNil:
      qf = 0
    return some(%*{
      "kind": "turn_in_quest", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0,
      "quest": qf, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "interact_unit":
    return some(%*{
      "kind": "interact", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0, "quest": 0, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "loot_unit":
    return some(%*{
      "kind": "loot", "target": jint(jget(intent, "unit_id")),
      "spell": 0, "item": 0, "equipment_slot": 0, "quest": 0, "choice": 0,
      "recipient": 0, "text": 0, "trigger": 0, "dialog": 0
    })
  of "release_spirit":
    return some(%*{"kind": "release_spirit", "target": 0, "spell": 0, "item": 0,
      "equipment_slot": 0, "quest": 0, "choice": 0, "recipient": 0,
      "text": 0, "trigger": 0, "dialog": 0})
  of "reclaim_corpse":
    return some(%*{"kind": "reclaim_corpse", "target": 0, "spell": 0, "item": 0,
      "equipment_slot": 0, "quest": 0, "choice": 0, "recipient": 0,
      "text": 0, "trigger": 0, "dialog": 0})
  of "move_to_corpse":
    return some(%*{
      "kind": "move", "target": 0, "spell": 0, "item": 0,
      "equipment_slot": 0, "quest": 0, "choice": 0, "recipient": 0,
      "text": 0, "trigger": 0, "dialog": 0,
      "destination": {
        "map_id": jint(jget(intent, "map_id")),
        "x": jnum(jget(intent, "x")),
        "y": jnum(jget(intent, "y")),
        "z": jnum(jget(intent, "z")),
        "orientation": 0.0
      }
    })
  else:
    return none(JsonNode)

proc overlayLeaderLive(proj: JsonNode; leaderFrame: JsonNode) =
  ## Party bindings often freeze leader xy / omit in_combat. Overlay the
  ## leader seat's own observation (same control plane, not in-game collusion).
  if proj.isNil or leaderFrame.isNil: return
  let obs = jget(leaderFrame, "observation")
  if obs.isNil: return
  let loc = jget(obs, "location")
  let lu = jget(proj, "party", "leader_unit")
  if lu.isNil or lu.kind != JObject: return
  if not loc.isNil:
    let lx = jnum(jget(loc, "x"))
    let ly = jnum(jget(loc, "y"))
    # Ignore broken 0,0 desync snapshots.
    if not (lx == 0.0 and ly == 0.0):
      lu["x"] = %lx
      lu["y"] = %ly
      lu["z"] = %jnum(jget(loc, "z"))
      lu["map_id"] = %jnum(jget(loc, "map_id"))
      lu["visible"] = %true
  let maxHp = max(1.0, jnum(jget(obs, "max_health"), 1.0))
  let hp = jnum(jget(obs, "health"), maxHp)
  lu["health_pct"] = %(hp / maxHp * 100.0)
  # Real combat only: obs.in_combat and/or missing HP. Sticky
  # auto_attack_guid / combat_focus_guid must NOT force fighting — that caused
  # permanent join_leader_assist thrash while the human sat full-HP.
  let fighting =
    jbool(jget(obs, "in_combat")) or (hp / maxHp * 100.0 < 99.5)
  lu["in_combat"] = %fighting

proc parseConfig(): HostConfig =
  result = HostConfig(
    slot: 2,
    tool: "escort_leader",
    leader: "Murist",
    leaderSlot: 0,
    party: @["Murist", "Shadowfel", "Igris", "Tusk", "Beru"],
    goalId: "army-slot-2",
    cadence: 0.35,
    acceptFrom: "Murist",
    maxSeconds: 0.0,
    quiet: true
  )
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "slot": result.slot = parseInt(val)
      of "tool": result.tool = val
      of "leader": result.leader = val
      of "leader-slot": result.leaderSlot = parseInt(val)
      of "party": result.party = val.split(',')
      of "goal-id": result.goalId = val
      of "cadence": result.cadence = parseFloat(val)
      of "accept-from": result.acceptFrom = val
      of "max-seconds": result.maxSeconds = parseFloat(val)
      of "verbose": result.quiet = false
      else: discard
    else: discard
  if result.goalId == "army-slot-2":
    result.goalId = "army-slot-" & $result.slot

proc log(c: HostConfig; msg: string) =
  if not c.quiet:
    echo msg
  else:
    # failures always? only print if FAIL in msg
    if msg.contains("FAIL") or msg.contains("fatal") or msg.contains("goal"):
      echo msg

proc main() =
  let cfg = parseConfig()
  echo &"[army_host] nim slot={cfg.slot} tool={cfg.tool} leader={cfg.leader} leaderSlot={cfg.leaderSlot}"
  var client = connectClient(cfg.slot)
  defer: client.close()
  # Optional live overlay from the human leader's control seat.
  var leaderClient: ControlClient = nil
  if cfg.leaderSlot >= 0 and cfg.leaderSlot != cfg.slot:
    try:
      leaderClient = connectClient(cfg.leaderSlot)
      echo &"[army_host] leader overlay slot={cfg.leaderSlot}"
    except:
      echo "[army_host] leader overlay unavailable: ", getCurrentExceptionMsg()
  defer:
    if leaderClient != nil: leaderClient.close()
  let st = client.statusJson()
  let rev = jint(jget(st, "revision"))
  client.submitGoal(cfg.goalId, cfg.leader, cfg.party, rev)
  echo &"[army_host] goal {cfg.goalId} submitted"
  let t0 = epochTime()
  var i = 0
  var lastPromoteAt = 0.0
  const PromoteRateLimitSec = 5.0
  while true:
    if cfg.maxSeconds > 0 and epochTime() - t0 > cfg.maxSeconds:
      echo "[army_host] max-seconds"
      break
    inc i
    try:
      let frame = client.envFrame()
      let ready = jbool(jget(frame, "action_ready"))
      let phase = jstr(jget(frame, "phase"))
      let rev2 = jint(jget(frame, "revision"))
      let fid = jint(jget(frame, "frame_id"))
      let tick = jint(jget(frame, "observed_tick"))
      # invite accept
      let party = jget(frame, "observation", "party")
      if jbool(jget(party, "invite_pending")) and ready:
        let invFrom = jstr(jget(party, "invite_from")).toLowerAscii
        if cfg.acceptFrom.len == 0 or invFrom == cfg.acceptFrom.toLowerAscii:
          let act = %*{
            "kind": "accept_party", "target": 0, "spell": 0, "item": 0,
            "equipment_slot": 0, "quest": 0, "choice": 0, "recipient": 0,
            "text": 0, "trigger": 0, "dialog": 0
          }
          client.selectAction(act, fid, tick, rev2)
          sleep(int(cfg.cadence * 1000))
          continue
      # Auto hand leadership to preferred human (Murist) when this seat is
      # the current party leader and Murist is online in the group.
      if ready and jbool(jget(party, "in_group")) and
          epochTime() - lastPromoteAt >= PromoteRateLimitSec:
        let selfName = jstr(jget(frame, "observation", "name"))
        let partyLeaderName = jstr(jget(party, "leader_name"))
        var members: seq[PromoteMember] = @[]
        let memArr = jget(party, "members")
        let entsP = jget(frame, "bindings", "entities")
        if not memArr.isNil and memArr.kind == JArray:
          for m in memArr:
            let mn = jstr(jget(m, "name"))
            var eidx = 0
            let mg = jstr(jget(m, "guid"))
            if not entsP.isNil and entsP.kind == JArray:
              for e in entsP:
                let kind = jstr(jget(e, "kind")).toLowerAscii
                if kind notin ["party", "player"]: continue
                if jstr(jget(e, "guid")) == mg or
                    jstr(jget(e, "name")).cmpIgnoreCase(mn) == 0:
                  eidx = jint(jget(e, "index"))
                  break
            members.add PromoteMember(name: mn, entityIndex: eidx)
        var preferIdx = 0
        for m in members:
          if m.name.cmpIgnoreCase(cfg.leader) == 0:
            preferIdx = m.entityIndex
            break
        let dec = decidePromote(
          selfName,
          partyLeaderName,
          cfg.leader,
          members,
          kindAllows(frame, "promote_party"),
          preferIdx > 0 and targetAllows(frame, "promote_party", preferIdx)
        )
        if dec.shouldPromote:
          let intent = %*{
            "kind": "promote_party",
            "unit_id": dec.targetIndex,
            "reason": dec.reason
          }
          let mapped = mapIntent(intent)
          if mapped.isSome:
            try:
              client.selectAction(mapped.get, fid, tick, rev2)
              lastPromoteAt = epochTime()
              echo "[army_host] #", i, " SELECT promote_party -> ", dec.targetName,
                " (", dec.reason, ")"
              sleep(int(cfg.cadence * 1000))
              continue
            except:
              echo "[army_host] #", i, " SELECT FAIL promote_party ",
                getCurrentExceptionMsg()
      let proj = projectEscort(frame, preferLeaderName = cfg.leader)
      if leaderClient != nil:
        try:
          let lf = leaderClient.envFrame()
          overlayLeaderLive(proj, lf)
        except:
          discard
      let intent = runDecide(cfg.tool, proj)
      if not cfg.quiet:
        var atkSample = "[]"
        let atk = proj{"combat"}{"attackable"}
        if not atk.isNil and atk.kind == JArray and atk.len > 0:
          atkSample = $atk[0]
        let lead = proj{"party"}{"leader_unit"}
        echo "[army_host] #", i, " ready=", ready, " intent=", intent,
          " leader=", lead, " attackable0=", atkSample
      if not ready:
        sleep(int(cfg.cadence * 1000))
        continue
      let mapped = mapIntent(intent)
      if mapped.isNone:
        sleep(int(cfg.cadence * 1000))
        continue
      try:
        if not cfg.quiet:
          echo "[army_host] #", i, " action=", mapped.get, " intent=", intent
        client.selectAction(mapped.get, fid, tick, rev2)
        if not cfg.quiet:
          let ak = jstr(jget(mapped.get, "kind"))
          echo "[army_host] #", i, " SELECT ", ak
      except:
        echo "[army_host] #", i, " SELECT FAIL ", getCurrentExceptionMsg(),
          " action=", mapped.get
    except:
      echo "[army_host] loop error: ", getCurrentExceptionMsg()
    sleep(int(cfg.cadence * 1000))

when isMainModule:
  main()
