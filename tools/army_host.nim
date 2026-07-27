## Nim army host — goal installer + fair-play audit for nim_control.v2.
##
## Upstream v2 runs policy **in-process** (step(observation)). External hosts
## install leveling goals with leader/party (escort) and observe frames; they
## do **not** select factorized actions. Watchdogs may reinstall goals when a
## seat thrashes (e.g. warlock selected_target_guid == active_pet_guid).
## Never send control_directive cancel for thrash — live v2 seats exit on it.
##
##   nim r tools/army_host.nim --slot:2 --leader:Murist
##
## Cadence defaults 1.0s (status/audit + thrash watch). Audit: --audit-path.

import
  std/[
    endians, json, math, options, os, osproc, parseopt, sets, strformat, strutils,
    streams, net, times
  ],
  msgpack_json, party_promote, fair_play_audit

const
  Protocol = "vanilla_wow.nim_control.v2"
  Magic = 0x44524E4Bu32
  Version = 2'u16
  FrameGoal = 1'u16
  FrameDirective = 2'u16
  FrameStatusReq = 4'u16
  FrameControlStatus = 5'u16
  FrameEnv = 6'u16
  FrameErr = 8'u16
  ## Fork extension (lua-external-policy branch): one typed BotAction per
  ## request while the in-process planner is held/idle.
  FrameExecAction = 7'u16
  FrameActionResult = 9'u16
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
    ## Append-only fair-play milestone log (empty = disabled).
    auditPath: string
    ## External policy mode: hold the in-process planner and drive the seat
    ## from lua/tools/<tool>.decide via the fork's execute_action frame.
    external: bool

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
  # Let the server's accept handler reach its first await before the first
  # frame lands (fast local connect+send raced it on fork builds).
  sleep(250)

proc close(c: ControlClient) =
  if c.sock != nil:
    try: c.sock.close()
    except: discard
    c.sock = nil

proc request(c: ControlClient; frameType: uint16; body: JsonNode):
    tuple[ft: uint16, node: JsonNode, raw: string] =
  if c.sock.isNil:
    raise newException(IOError, "socket closed")
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
    "include_environment_frame": false
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
    "include_environment_frame": true
  }
  let (ft, node, _) = c.request(FrameStatusReq, body)
  if ft != FrameEnv:
    raise newException(IOError, "expected environment_frame got " & $ft)
  node

proc submitGoal(c: ControlClient; goalId, leader: string; party: seq[string];
    revision: int; botId = "relh-roam"; stopLevel = 0) =
  ## Install an in-process leveling goal. Escort uses leader_name + party_members;
  ## the client policy steps follow/assist/grind autonomously (nim_control.v2).
  let body = %*{
    "protocol": Protocol,
    "type": "goal_request",
    "goal_id": goalId,
    "goal_kind": "leveling",
    "bot_id": botId,
    "profile_id": "",
    "task_id": "",
    "role": "",
    "leader_name": leader,
    "party_members": party,
    "stop_level": stopLevel,
    "expected_slot": c.slot,
    "expected_revision": revision,
    "practice_reset": false,
    "rfc_launch": false
  }
  discard c.request(FrameGoal, body)

proc sendDirective(c: ControlClient; directive: string; revision: int) =
  ## hold | resume | cancel — v2 control plane (no factorized SELECT).
  let body = %*{
    "protocol": Protocol,
    "type": "control_directive",
    "directive": directive,
    "expected_slot": c.slot,
    "expected_revision": revision
  }
  discard c.request(FrameDirective, body)

proc executeAction(c: ControlClient; action: JsonNode; revision: int): JsonNode =
  ## Fire one typed BotAction through the fork's execute_action frame.
  ## Blocks until the executor settles (moves walk their corridor first).
  let body = %*{
    "protocol": Protocol,
    "type": "execute_action",
    "expected_slot": c.slot,
    "expected_revision": revision,
    "action": action
  }
  let (ft, node, _) = c.request(FrameExecAction, body)
  if ft != FrameActionResult:
    raise newException(IOError, "expected action_result got " & $ft)
  node

proc isStaleRevisionError(msg: string): bool =
  msg.contains("stale controller revision") or msg.contains("stale revision")

proc guidNonzero(s: string): bool =
  s.len > 0 and s != "0"

proc swingingAtOwnPet(obs: JsonNode): bool =
  ## Real thrash: policy AA-swings the imp (attack/stop_attack forever).
  ## Mere selected_target == pet is normal OOC (feed/pet-command) — do NOT
  ## treat that as thrash (live false positive on Igris every pull).
  if obs.isNil: return false
  let pet = jstr(jget(obs, "active_pet_guid"))
  if not guidNonzero(pet): return false
  let aa = jstr(jget(obs, "auto_attack_guid"))
  aa == pet

proc stuckCombatFollowOnly(frame, obs: JsonNode): bool =
  ## In combat, leveling reports no progress, and the only recommended
  ## actions are movement (follow leader) — not cast/attack. Live Shadowfel:
  ## sticky AA on a 60yd mob while only move→Murist for 20+s.
  if obs.isNil or frame.isNil: return false
  if not jbool(jget(obs, "in_combat")): return false
  let nop = jnum(jget(frame, "leveling_lifecycle", "no_progress_seconds"))
  if nop < 15.0: return false
  let acts = jget(frame, "actions")
  if acts.isNil or acts.kind != JArray or acts.len == 0: return false
  for a in acts:
    let k = jstr(jget(a, "kind"))
    if k notin ["move", "follow", "face", "stop_attack", ""]:
      return false
  true

proc moveActionFarDest(frame, obs: JsonNode; minDist = 25.0): bool =
  ## True when recommended action is a move whose destination is still far
  ## from self (not micro-reposition / in-formation hold).
  if obs.isNil or frame.isNil: return false
  let loc = jget(obs, "location")
  if loc.isNil: return false
  let sx = jnum(jget(loc, "x"))
  let sy = jnum(jget(loc, "y"))
  let acts = jget(frame, "actions")
  if acts.isNil or acts.kind != JArray or acts.len == 0: return false
  var sawMove = false
  for a in acts:
    let k = jstr(jget(a, "kind"))
    if k != "move": continue
    sawMove = true
    let dest = jget(a, "destination")
    if dest.isNil: return false
    let dx = jnum(jget(dest, "x")) - sx
    let dy = jnum(jget(dest, "y")) - sy
    if dx * dx + dy * dy < minDist * minDist:
      return false
  sawMove

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

# ---------- v2 projection (observation → plain Lua table) ----------
#
# The v2 environment frame has no action_space/action_mask/bindings — those
# died with the v1 select protocol. Units carry real guids (uint64, may not
# fit a Lua double), so tools see dense 1-based ids and the host resolves
# id → guid on the way back out.

proc projectV2(frame: JsonNode; preferLeaderName = ""):
    tuple[proj: JsonNode, guids: seq[string]] =
  let obs = jget(frame, "observation")
  let loc = jget(obs, "location")
  var guids: seq[string] = @[]
  let selfUnit = %*{
    "x": jnum(jget(loc, "x")),
    "y": jnum(jget(loc, "y")),
    "z": jnum(jget(loc, "z")),
    "map_id": jnum(jget(loc, "map_id")),
    "class_id": jint(jget(obs, "class_id")),
    "level": jint(jget(obs, "level"))
  }
  let maxHp = max(1.0, jnum(jget(obs, "max_health"), 1.0))
  let hpPct = jnum(jget(obs, "health"), maxHp) / maxHp * 100.0
  # Mana from pool 0 — active_power_type latches onto pet focus (old
  # grind_policy lesson, still true on live warlock frames).
  var manaPct = 100.0
  var mana = 0
  let powers = jget(obs, "powers")
  let maxPowers = jget(obs, "max_powers")
  if not powers.isNil and powers.kind == JArray and powers.len > 0 and
      not maxPowers.isNil and maxPowers.kind == JArray and maxPowers.len > 0:
    mana = jint(powers[0])
    let mm = max(1, jint(maxPowers[0]))
    manaPct = float(mana) / float(mm) * 100.0

  var attackable = newJArray()
  var lootable = newJArray()
  var focusId = 0
  let selectedGuid = jstr(jget(obs, "selected_target_guid"))
  let units = jget(obs, "units")
  if not units.isNil and units.kind == JArray:
    for u in units:
      let g = jstr(jget(u, "guid"))
      if not guidNonzero(g): continue
      let uloc = jget(u, "location")
      if uloc.isNil: continue
      let hostile = jstr(jget(u, "reaction")) == "hostile"
      let alive = jint(jget(u, "health")) > 0
      let isLoot = jbool(jget(u, "is_lootable"))
      if not hostile and not isLoot: continue
      guids.add g
      let id = guids.len
      let row = %*{
        "id": id,
        "x": jnum(jget(uloc, "x")),
        "y": jnum(jget(uloc, "y")),
        "z": jnum(jget(uloc, "z")),
        "map_id": jnum(jget(uloc, "map_id")),
        "entry": jint(jget(u, "entry")),
        "level": jint(jget(u, "level")),
        "distance": jnum(jget(u, "distance")),
        "los_blocked": jbool(jget(u, "line_of_sight_blocked")),
        "lootable": isLoot and not alive
      }
      if isLoot and not alive:
        lootable.add row
      elif hostile and alive:
        attackable.add row
        if g == selectedGuid:
          focusId = id

  # Leader projection for escort tools: party member row + live unit overlay.
  var leaderUnit = newJNull()
  let party = jget(obs, "party")
  let prefer = preferLeaderName.toLowerAscii
  if jbool(jget(party, "in_group")):
    let leaderName =
      if prefer.len > 0: prefer
      else: jstr(jget(party, "leader_name")).toLowerAscii
    let members = jget(party, "members")
    if not members.isNil and members.kind == JArray:
      for m in members:
        if jstr(jget(m, "name")).toLowerAscii != leaderName: continue
        let g = jstr(jget(m, "guid"))
        var x, y, z, mapId = 0.0
        var visible = false
        var inCombat = false
        if not units.isNil and units.kind == JArray:
          for u in units:
            if jstr(jget(u, "guid")) != g: continue
            let uloc = jget(u, "location")
            if not uloc.isNil:
              x = jnum(jget(uloc, "x"))
              y = jnum(jget(uloc, "y"))
              z = jnum(jget(uloc, "z"))
              mapId = jnum(jget(uloc, "map_id"))
              visible = not (x == 0.0 and y == 0.0)
            let tg = jstr(jget(u, "target_guid"))
            inCombat = guidNonzero(tg)
            break
        var leaderHpPct = 100.0
        if jbool(jget(m, "health_known")):
          let mh = max(1.0, jnum(jget(m, "max_health"), 1.0))
          leaderHpPct = jnum(jget(m, "health"), mh) / mh * 100.0
        if not inCombat and leaderHpPct < 99.5:
          inCombat = true
        guids.add g
        leaderUnit = %*{
          "id": guids.len,
          "x": x, "y": y, "z": z, "map_id": mapId,
          "visible": visible,
          "assistable": visible,
          "health_pct": leaderHpPct,
          "in_combat": inCombat,
          "position_reliable": visible
        }
        break

  let corpseKnown = jbool(jget(obs, "corpse_known"))
  let corpseLoc = jget(obs, "corpse_location")
  var corpse = newJNull()
  if corpseKnown and not corpseLoc.isNil:
    corpse = %*{
      "map_id": jnum(jget(corpseLoc, "map_id")),
      "x": jnum(jget(corpseLoc, "x")),
      "y": jnum(jget(corpseLoc, "y")),
      "z": jnum(jget(corpseLoc, "z"))
    }
  let isDead = jbool(jget(obs, "is_dead"))
  let isGhost = jbool(jget(obs, "is_ghost"))

  var known = newJArray()
  let ks = jget(obs, "known_spells")
  if not ks.isNil and ks.kind == JArray:
    for s in ks: known.add s
  var cooldowns = newJArray()
  let cds = jget(obs, "cooldown_spell_ids")
  if not cds.isNil and cds.kind == JArray:
    for s in cds: cooldowns.add s

  let proj = %*{
    "self_unit": selfUnit,
    "leader_unit": leaderUnit,
    "combat": {
      "in_combat": jbool(jget(obs, "in_combat")),
      "health_pct": hpPct,
      "mana_pct": manaPct,
      "focus_id": focusId,
      "attackable": attackable,
      "lootable": lootable,
      "casts": newJArray()
    },
    "spells": {
      "known": known,
      "cooldowns": cooldowns,
      "mana": mana,
      "mana_pct": manaPct
    },
    "death": {
      "is_dead": isDead,
      "is_ghost": isGhost,
      "can_release_spirit": isDead and not isGhost,
      "can_reclaim_corpse": jbool(jget(obs, "can_reclaim_corpse")),
      "can_reclaim_action": jbool(jget(obs, "can_reclaim_corpse")),
      "can_move": true,
      "corpse": corpse
    },
    "party": {
      "in_group": jbool(jget(party, "in_group")),
      "invite_pending": jbool(jget(party, "invite_pending")),
      "invite_from": jstr(jget(party, "invite_from")),
      "leader_name": jstr(jget(party, "leader_name"))
    }
  }
  (proj, guids)

proc guidFor(guids: seq[string]; unitId: int): string =
  if unitId >= 1 and unitId <= guids.len:
    return guids[unitId - 1]
  ""

proc mapIntentV2(intent: JsonNode; guids: seq[string]): Option[JsonNode] =
  ## Lua intent → typed BotAction JSON for the fork's execute_action frame.
  if intent.isNil or intent.kind != JObject: return none(JsonNode)
  let kind = jstr(jget(intent, "kind"))
  let uid = jint(jget(intent, "unit_id"))
  let guid = guidFor(guids, uid)
  proc dest(arrival: float): JsonNode =
    %*{
      "kind": "move",
      "destination": {
        "map_id": jint(jget(intent, "map_id")),
        "x": jnum(jget(intent, "x")),
        "y": jnum(jget(intent, "y")),
        "z": jnum(jget(intent, "z")),
        "orientation": 0.0
      },
      "arrival_radius": arrival
    }
  case kind
  of "hold", "":
    none(JsonNode)
  of "move_to_unit":
    if jget(intent, "x") != nil and jget(intent, "y") != nil:
      some(dest(4.0))
    elif guid.len > 0:
      some(%*{"kind": "follow", "target_guid": guid})
    else:
      none(JsonNode)
  of "move_to_corpse":
    some(dest(6.0))
  of "follow_unit":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "follow", "target_guid": guid})
  of "assist_unit":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "assist", "target_guid": guid})
  of "attack_unit":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "attack", "target_guid": guid})
  of "cast_spell":
    let spell = jint(jget(intent, "spell"))
    if spell <= 0: none(JsonNode)
    else:
      var a = %*{"kind": "cast", "spell_id": spell}
      if guid.len > 0: a["target_guid"] = %guid
      some(a)
  of "stop_attack":
    some(%*{"kind": "stop_attack"})
  of "loot_unit":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "loot", "target_guid": guid})
  of "interact_unit":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "interact", "target_guid": guid})
  of "accept_party":
    some(%*{"kind": "accept_party"})
  of "promote_party":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "promote_party", "target_guid": guid})
  of "accept_quest":
    if guid.len == 0: none(JsonNode)
    else:
      some(%*{
        "kind": "accept_quest", "target_guid": guid,
        "quest_id": jint(jget(intent, "quest_id"))
      })
  of "turn_in_quest":
    if guid.len == 0: none(JsonNode)
    else:
      some(%*{
        "kind": "turn_in_quest", "target_guid": guid,
        "quest_id": jint(jget(intent, "quest_id")),
        "quest_reward_choice": jint(jget(intent, "reward_choice"))
      })
  of "release_spirit":
    some(%*{"kind": "release_spirit"})
  of "reclaim_corpse":
    some(%*{"kind": "reclaim_corpse"})
  else:
    none(JsonNode)

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

proc parseConfig(): HostConfig =
  result = HostConfig(
    slot: 2,
    tool: "escort_leader",
    leader: "Murist",
    leaderSlot: 0,
    party: @["Murist", "Shadowfel", "Igris", "Tusk", "Beru"],
    goalId: "army-slot-2",
    cadence: 1.0,
    acceptFrom: "Murist",
    maxSeconds: 0.0,
    quiet: true,
    auditPath: DefaultAuditPath
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
      of "audit-path": result.auditPath = val
      of "no-audit": result.auditPath = ""
      of "external": result.external = true
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

proc say(msg: string) =
  echo msg
  flushFile(stdout)

proc runExternal(cfg: var HostConfig) =
  ## Lua drives the seat: hold the in-process planner, then each tick
  ## project the env frame, run lua/tools/<tool>.decide, and fire the intent
  ## through the fork's execute_action frame. Fair-play audit still runs;
  ## the client also appends every action to action-results.jsonl.
  echo &"[army_host] EXTERNAL lua policy slot={cfg.slot} tool={cfg.tool} leader={cfg.leader}"
  var audit = AuditState(path: cfg.auditPath, slot: cfg.slot, tool: cfg.tool)
  var client = connectClient(cfg.slot)
  defer: client.close()
  proc ensureHeld(): int =
    ## The execute frame is only legal while the planner cannot step.
    let st = client.statusJson()
    var rev = jint(jget(st, "revision"))
    if jstr(jget(st, "phase")) == "running":
      client.sendDirective("hold", rev)
      rev = jint(jget(client.statusJson(), "revision"))
      echo &"[army_host] planner held (rev={rev})"
    rev
  var rev = ensureHeld()
  let t0 = epochTime()
  var i = 0
  var lastHeartbeatAt = 0.0
  var lastIntent = ""
  const HeartbeatSec = 15.0
  while true:
    if cfg.maxSeconds > 0 and epochTime() - t0 > cfg.maxSeconds:
      echo "[army_host] max-seconds"
      break
    inc i
    try:
      let frame = client.envFrame()
      discard processFrame(audit, frame)
      let obs = jget(frame, "observation")
      let name = jstr(jget(obs, "name"))
      let (proj, guids) = projectV2(frame, cfg.leader)
      var intentDesc = "hold"
      try:
        let intent = runDecide(cfg.tool, proj)
        if not cfg.quiet:
          say "[external] intent " & $intent
        let action = mapIntentV2(intent, guids)
        intentDesc = jstr(jget(intent, "kind"), "hold") & ":" &
          jstr(jget(intent, "reason"))
        if action.isSome:
          try:
            let res = client.executeAction(action.get, rev)
            if not jbool(jget(res, "success")):
              echo "[army_host] action FAIL ", intentDesc, " → ",
                jstr(jget(res, "message"))
            rev = jint(jget(res, "revision"), rev)
          except:
            let msg = getCurrentExceptionMsg()
            if isStaleRevisionError(msg):
              rev = ensureHeld()
            else:
              raise
      except:
        echo "[army_host] decide FAIL: ", getCurrentExceptionMsg()
      if intentDesc != lastIntent or
          epochTime() - lastHeartbeatAt >= HeartbeatSec:
        lastHeartbeatAt = epochTime()
        lastIntent = intentDesc
        let loc = jget(obs, "location")
        echo "[army_host] #", i, " ", name,
          " intent=", intentDesc,
          " pos=(",
          jnum(jget(loc, "x")).formatFloat(ffDecimal, 0), ",",
          jnum(jget(loc, "y")).formatFloat(ffDecimal, 0), ")",
          " hp=", jnum(jget(proj, "combat", "health_pct")).formatFloat(ffDecimal, 0)
    except:
      let msg = getCurrentExceptionMsg()
      echo "[army_host] loop error: ", msg
      if msg.contains("socket") or msg.contains("closed") or
          msg.contains("send failed"):
        try: client.close()
        except: discard
        sleep(1000)
        try:
          client = connectClient(cfg.slot)
          rev = ensureHeld()
          echo "[army_host] reconnected slot=", cfg.slot
        except:
          echo "[army_host] reconnect failed: ", getCurrentExceptionMsg()
    sleep(int(cfg.cadence * 1000))

proc main() =
  var cfg = parseConfig()
  if cfg.external:
    runExternal(cfg)
    return
  echo &"[army_host] v2 goal-host slot={cfg.slot} leader={cfg.leader} party={cfg.party}"
  if cfg.auditPath.len > 0:
    echo &"[army_host] fair-play audit → {cfg.auditPath}"
  var audit = AuditState(
    path: cfg.auditPath,
    slot: cfg.slot,
    tool: cfg.tool
  )
  var client = connectClient(cfg.slot)
  defer: client.close()
  proc installEscortGoal() =
    let st = client.statusJson()
    let rev = jint(jget(st, "revision"))
    let phase = jstr(jget(st, "phase"))
    client.submitGoal(cfg.goalId, cfg.leader, cfg.party, rev)
    echo &"[army_host] goal {cfg.goalId} submitted (was phase={phase} rev={rev})"
  installEscortGoal()
  let t0 = epochTime()
  var i = 0
  var lastHeartbeatAt = 0.0
  var petTargetStreak = 0
  var stuckCombatStreak = 0
  var zeroDispStreak = 0
  var lastPosX = 0.0
  var lastPosY = 0.0
  var haveLastPos = false
  var lastUnstickAt = 0.0
  const HeartbeatSec = 15.0
  ## Cadence is often 0.35s (escort-army). Need multi-second confirmation.
  const PetTargetStreakLimit = 20   ## ~7s at 0.35s cadence, OOC only
  const StuckCombatStreakLimit = 8  ## ~3s of no-progress combat frames
  ## Moves "succeed" but body does not move (Brill freeze 2026-07-27).
  const ZeroDispStreakLimit = 25    ## ~9s @0.35 / 25s @1.0
  ## Cooldown between goal-id bumps so we do not thrash installs.
  const UnstickCooldownSec = 60.0
  proc unstickGoal(reason, name: string) =
    ## Bump goal_id so the controller drops sticky combat/target memory.
    ## Never send control_directive cancel — it exits the seat on this pin.
    if epochTime() - lastUnstickAt < UnstickCooldownSec:
      return
    let stU = client.statusJson()
    let freshId = cfg.goalId & "-u" & $int(epochTime())
    client.submitGoal(
      freshId, cfg.leader, cfg.party, jint(jget(stU, "revision"))
    )
    cfg.goalId = freshId
    lastUnstickAt = epochTime()
    petTargetStreak = 0
    stuckCombatStreak = 0
    zeroDispStreak = 0
    echo "[army_host] FAIL unstuck ", reason, " name=", name,
      " slot=", cfg.slot, " goal=", freshId
  while true:
    if cfg.maxSeconds > 0 and epochTime() - t0 > cfg.maxSeconds:
      echo "[army_host] max-seconds"
      break
    inc i
    try:
      let st = client.statusJson()
      let phase = jstr(jget(st, "phase"))
      let rev = jint(jget(st, "revision"))
      # Re-install only when the controller dropped the goal. Periodic re-submit
      # resets policy memory and thrash-glitches movement.
      if phase in ["idle", "failed", "complete"]:
        try:
          client.submitGoal(cfg.goalId, cfg.leader, cfg.party, rev)
          echo &"[army_host] re-installed goal (phase was {phase})"
        except:
          let msg = getCurrentExceptionMsg()
          if isStaleRevisionError(msg):
            let st2 = client.statusJson()
            client.submitGoal(
              cfg.goalId, cfg.leader, cfg.party, jint(jget(st2, "revision"))
            )
          else:
            raise
      try:
        let frame = client.envFrame()
        discard processFrame(audit, frame)
        let obs = jget(frame, "observation")
        let name = jstr(jget(obs, "name"))
        let loc = jget(obs, "location")
        let party = jget(obs, "party")
        # AA on own pet (true thrash). Selected-pet alone is normal OOC.
        if swingingAtOwnPet(obs):
          inc petTargetStreak
        else:
          petTargetStreak = 0
        if petTargetStreak >= PetTargetStreakLimit:
          try:
            unstickGoal("aa-on-own-pet thrash", name)
          except:
            echo "[army_host] FAIL pet-unstick: ", getCurrentExceptionMsg()
        # Combat + no progress + only move/follow recommended (sticky far target).
        if stuckCombatFollowOnly(frame, obs):
          inc stuckCombatStreak
        else:
          stuckCombatStreak = 0
        if stuckCombatStreak >= StuckCombatStreakLimit:
          try:
            unstickGoal("stuck-combat follow-only", name)
          except:
            echo "[army_host] FAIL combat-unstick: ", getCurrentExceptionMsg()
        # Zero-displacement move thrash: far dest, body not moving.
        let px = jnum(jget(loc, "x"))
        let py = jnum(jget(loc, "y"))
        if haveLastPos and moveActionFarDest(frame, obs):
          let ddx = px - lastPosX
          let ddy = py - lastPosY
          if ddx * ddx + ddy * ddy < 0.6 * 0.6:
            inc zeroDispStreak
          else:
            zeroDispStreak = 0
        else:
          zeroDispStreak = 0
        if not (px == 0.0 and py == 0.0):
          lastPosX = px
          lastPosY = py
          haveLastPos = true
        if zeroDispStreak >= ZeroDispStreakLimit:
          try:
            unstickGoal("zero-displacement move", name)
          except:
            echo "[army_host] FAIL zero-disp-unstick: ", getCurrentExceptionMsg()
        if epochTime() - lastHeartbeatAt >= HeartbeatSec or not cfg.quiet:
          lastHeartbeatAt = epochTime()
          echo "[army_host] heartbeat #", i,
            " name=", name,
            " phase=", phase,
            " pos=(",
            jnum(jget(loc, "x")).formatFloat(ffDecimal, 0), ",",
            jnum(jget(loc, "y")).formatFloat(ffDecimal, 0), ")",
            " party=", jbool(jget(party, "in_group")),
            " leader=", jstr(jget(party, "leader_name"))
      except:
        # Frame optional if only status works
        if not cfg.quiet:
          echo "[army_host] frame skip: ", getCurrentExceptionMsg()
    except:
      let msg = getCurrentExceptionMsg()
      echo "[army_host] loop error: ", msg
      if msg.contains("socket") or msg.contains("closed") or msg.contains("send failed"):
        try: client.close()
        except: discard
        sleep(1000)
        try:
          client = connectClient(cfg.slot)
          installEscortGoal()
          echo "[army_host] reconnected slot=", cfg.slot
        except:
          echo "[army_host] reconnect failed: ", getCurrentExceptionMsg()
    sleep(int(cfg.cadence * 1000))

when isMainModule:
  main()
