## Nim army host — Lua external policy over WS /env (AgentFrame → AgentAction).
##
## Transport: tools/env_transport.nim. Default is direct TCP to the host-local
## env host (127.0.0.1:41113 + kind-11 attach). `--ws` uses the game relay
## at :8080 when it is alive. Policy loop: agent_frame → projectV2 (frozen Lua
## shape) → lua/tools/<tool>.decide → mapIntentV2 → action_submission.
##
##   nim r tools/army_host.nim --slot:2 --leader:Murist --character:Igris
##   nim r tools/army_host.nim --mode:traverse --ws --slot:0 --token:…
##
## Cadence defaults from hello.action_deadline_seconds; `--cadence` overrides.
## `--mode=<name>` loads lua/entry/<name>.lua; `--tool=<name>` loads a tool.
## Mode wins when both are set.

import
  std/[
    json, math, options, os, osproc, parseopt, random, strformat, strutils,
    times
  ],
  env_transport, msgpack_json, fair_play_audit

const
  EnvProtocol = "vanilla_wow.environment.v1"
  DefaultHost = "127.0.0.1"
  DefaultDirectPort = 41113
  DefaultWsPort = 8080
  DefaultGameUrl = "http://127.0.0.1:8080"
  DefaultToken = "token-0"
  DefaultAccount = "coworld"
  DefaultPassword = "coworld"
  # The game validates assets/navmesh HTTP with `config.tokens[slot] == token`
  # (game/config.py slot_token_valid). The local realm ships exactly one token,
  # so only slot 0 authenticates — while the ATTACH slot is whatever seat we
  # are. These are independent: attach on 2-5, fetch assets as slot 0.
  DefaultAssetSlot = 0

type
  HostConfig = object
    slot: int
    tool: string            ## lua/tools/<tool> when mode is empty
    mode: string            ## lua/entry/<mode> when set (wins over tool)
    leader: string
    party: seq[string]
    cadence: float          ## 0 = use hello.action_deadline_seconds
    cadenceOverride: bool
    acceptFrom: string
    maxSeconds: float
    quiet: bool
    auditPath: string
    host: string
    port: int               ## 0 = mode default
    direct: bool            ## true = TCP env host; false = WS relay
    account: string
    password: string
    character: string
    gameUrl: string
    token: string
    assetSlot: int          ## slot used in assets/navmesh URLs, NOT the attach slot
    polMinYards: float      ## >0: exit 0 after path yards reach this (PoL)
    polRequireMove: bool    ## require at least one accepted move action

# ---------- JSON helpers ----------

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

proc guidNonzero(s: string): bool =
  s.len > 0 and s != "0"

proc closeMessage(code: int; reason: string): string =
  ## Distinct human-readable line per WS close code (and direct-TCP errors).
  case code
  of 1008:
    result = "close 1008: bad token or slot already attached"
  of 1011:
    result = "close 1011: internal error or session ended before hello"
  of 1002:
    result = "close 1002: protocol error"
  of 1000:
    result = "close 1000: normal closure"
  of 1001:
    result = "close 1001: going away"
  else:
    result = "close " & $code
  if reason.len > 0:
    result.add " (" & reason & ")"

# ---------- Safety heuristics (inputs ported to flat AgentFrame) ----------

proc swingingAtOwnPet(frame: JsonNode): bool =
  ## Real thrash: auto-attack locked on the active pet guid.
  if frame.isNil: return false
  let pet = jstr(jget(frame, "active_pet_guid"))
  if not guidNonzero(pet): return false
  let aa = jstr(jget(frame, "auto_attack_guid"))
  aa == pet

proc stuckCombatFollowOnly(frame: JsonNode): bool =
  ## Goal-era helper: in combat, no progress, only move/follow recommended.
  ## AgentFrame has no recommended `actions` / leveling_lifecycle — returns
  ## false when those fields are absent (external policy path).
  if frame.isNil: return false
  if not jbool(jget(frame, "in_combat")): return false
  let nop = jnum(jget(frame, "leveling_lifecycle", "no_progress_seconds"))
  if nop < 15.0: return false
  let acts = jget(frame, "actions")
  if acts.isNil or acts.kind != JArray or acts.len == 0: return false
  for a in acts:
    let k = jstr(jget(a, "kind"))
    if k notin ["move", "follow", "face", "stop_attack", ""]:
      return false
  true

proc moveActionFarDest(frame: JsonNode; minDist = 25.0): bool =
  ## Goal-era helper: recommended move destination still far from self.
  if frame.isNil: return false
  let loc = jget(frame, "location")
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

# ---------- Phase 2 — projection (AgentFrame flat → frozen Lua shape) ----------
#
# Inbound AgentFrame is FLAT (no observation wrapper). Output table is frozen:
# self_unit / leader_unit / combat / spells / death / party (+ guids side table).

proc unitIsAlive(u: JsonNode): bool =
  ## Prefer death_known/is_dead; fall back to health when known or bare.
  if jbool(jget(u, "death_known")):
    return not jbool(jget(u, "is_dead"))
  if jbool(jget(u, "health_known"), jget(u, "health") != nil):
    return jint(jget(u, "health")) > 0
  # Unknown → treat as not attackable/lootable classifiable; caller filters.
  false

proc unitIsDead(u: JsonNode): bool =
  if jbool(jget(u, "death_known")):
    return jbool(jget(u, "is_dead"))
  if jbool(jget(u, "health_known"), jget(u, "health") != nil):
    return jint(jget(u, "health")) <= 0
  false

proc unitIsLootable(u: JsonNode): bool =
  ## lootable_known false → unknown → not lootable (absent).
  if jget(u, "lootable_known") != nil and not jbool(jget(u, "lootable_known")):
    return false
  jbool(jget(u, "is_lootable"))

proc unitLosBlocked(u: JsonNode): bool =
  ## line_of_sight_known false → unknown → not blocked (old missing default).
  if jget(u, "line_of_sight_known") != nil and
      not jbool(jget(u, "line_of_sight_known")):
    return false
  jbool(jget(u, "line_of_sight_blocked"))

proc projectV2*(frame: JsonNode; preferLeaderName = ""):
    tuple[proj: JsonNode, guids: seq[string]] =
  ## Project a flat AgentFrame (or legacy wrapped frame) into the frozen Lua table.
  ##
  ## Accepts either top-level AgentFrame keys or the old `{observation: ...}`
  ## wrapper so unit tests and any residual wrapped dumps still work.
  let obs =
    if frame.isNil: nil
    elif jget(frame, "observation") != nil and
        jget(frame, "observation").kind == JObject and
        jget(frame, "location") == nil:
      jget(frame, "observation")
    else:
      frame
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

  var hpPct = 100.0
  if jbool(jget(obs, "health_known"), true):
    let maxHp = max(1.0, jnum(jget(obs, "max_health"), 1.0))
    hpPct = jnum(jget(obs, "health"), maxHp) / maxHp * 100.0
  # Mana from pool 0 — active_power_type latches onto pet focus (old
  # grind_policy lesson, still true on live warlock frames).
  var manaPct = 100.0
  var mana = 0
  let powers = jget(obs, "powers")
  let maxPowers = jget(obs, "max_powers")
  let powerKnown = jget(obs, "power_known")
  var pool0Known = true
  if not powerKnown.isNil and powerKnown.kind == JArray and powerKnown.len > 0:
    pool0Known = jbool(powerKnown[0], true)
  if pool0Known and not powers.isNil and powers.kind == JArray and powers.len > 0 and
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
      let alive = unitIsAlive(u)
      let dead = unitIsDead(u)
      let isLoot = unitIsLootable(u)
      if not hostile and not isLoot: continue
      # Skip when death/health truth is fully unknown (neither flag usable).
      if not alive and not dead and not isLoot: continue
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
        "los_blocked": unitLosBlocked(u),
        "lootable": isLoot and dead
      }
      if isLoot and dead:
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

  # corpse_known false → null corpse (unknown, not zero coords).
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

proc guidFor*(guids: seq[string]; unitId: int): string =
  if unitId >= 1 and unitId <= guids.len:
    return guids[unitId - 1]
  ""

# ---------- Phase 3 — mapIntentV2 (Lua intent → AgentAction JSON) ----------

proc moveIntentName(intent: JsonNode): string =
  ## navigation_mode / intent string → AgentMoveIntent wire name.
  let raw = jstr(jget(intent, "intent"))
  let nav = if raw.len > 0: raw else: jstr(jget(intent, "navigation_mode"))
  case nav.toLowerAscii
  of "", "travel", "goal": "travel"
  of "approach", "local": "approach"
  of "retreat": "retreat"
  of "explore": "explore"
  else: "travel"

proc targetZKnownFromIntent(intent: JsonNode): bool =
  ## Polarity flip: destination_z_unknown → target_z_known = not unknown.
  ## Default when the flag is absent: known (matches action_json optionalBool true).
  not jbool(jget(intent, "destination_z_unknown"), false)

proc mapIntentV2*(intent: JsonNode; guids: seq[string]): Option[JsonNode] =
  ## Lua intent → typed AgentAction JSON body (no submission envelope).
  if intent.isNil or intent.kind != JObject: return none(JsonNode)
  let kind = jstr(jget(intent, "kind"))
  let uid = jint(jget(intent, "unit_id"))
  let guid = guidFor(guids, uid)
  proc destMove(arrival: float): JsonNode =
    ## aakMove with inverted Z polarity and moveIntent enum on the wire.
    %*{
      "kind": "move",
      "destination": {
        "map_id": jint(jget(intent, "map_id")),
        "x": jnum(jget(intent, "x")),
        "y": jnum(jget(intent, "y")),
        "z": jnum(jget(intent, "z")),
        "orientation": 0.0
      },
      "arrival_radius": arrival,
      "target_z_known": targetZKnownFromIntent(intent),
      "intent": moveIntentName(intent)
    }
  case kind
  of "hold", "":
    none(JsonNode)
  of "move", "move_to":
    ## Destination point move (traverse / shared move_to tool).
    if jget(intent, "x") == nil or jget(intent, "y") == nil:
      none(JsonNode)
    else:
      let arr = jnum(jget(intent, "arrival_radius"), 4.0)
      some(destMove(if arr > 0: arr else: 4.0))
  of "move_to_unit":
    if jget(intent, "x") != nil and jget(intent, "y") != nil:
      some(destMove(4.0))
    elif guid.len > 0:
      some(%*{"kind": "follow", "target_guid": guid})
    else:
      none(JsonNode)
  of "move_to_corpse":
    some(destMove(6.0))
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
      if guid.len > 0:
        a["target_guid"] = %guid
      else:
        # Cast requires exactly one target mode (action_json.nim).
        a["cast_without_target"] = %true
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
  of "remove_party":
    if guid.len == 0: none(JsonNode)
    else: some(%*{"kind": "remove_party", "target_guid": guid})
  of "ready_check":
    some(%*{"kind": "ready_check"})
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
        "reward_choice": jint(jget(intent, "reward_choice"))
      })
  of "release_spirit":
    some(%*{"kind": "release_spirit"})
  of "reclaim_corpse":
    some(%*{"kind": "reclaim_corpse"})
  else:
    none(JsonNode)

proc actionSubmissionPayload*(
  action: JsonNode;
  expectedFrameId: int;
  expectedSlot: int
): string =
  ## Kind-9 JSON envelope (control_json.nim environmentActionSubmissionFromJson).
  $(%*{
    "protocol": EnvProtocol,
    "type": "action_submission",
    "action": action,
    "expected_frame_id": expectedFrameId,
    "expected_slot": expectedSlot
  })

proc actionStateStatus(frame: JsonNode): string =
  ## Wire status string from action_state, or "" when idle/null.
  let st = jget(frame, "action_state")
  if st.isNil or st.kind != JObject:
    return ""
  jstr(jget(st, "status"))

proc actionIsPending(frame: JsonNode): bool =
  actionStateStatus(frame) == "pending"

proc actionIsRejected(frame: JsonNode): bool =
  actionStateStatus(frame) == "rejected"

proc runDecide(cfg: HostConfig; proj: JsonNode): JsonNode =
  ## Run entry or tool decide(proj) in a lua5.3 subprocess; return intent JSON.
  let repo = getCurrentDir()
  let useMode = cfg.mode.len > 0
  let name = if useMode: cfg.mode else: cfg.tool
  let packagePath =
    if useMode:
      repo & "/lua/?.lua;" & repo & "/lua/entry/?.lua;" & repo &
        "/lua/tools/?.lua;;"
    else:
      repo & "/lua/?.lua;" & repo & "/lua/tools/?.lua;;"
  let loadBody =
    if useMode:
      "local entry = require(\"" & name & "\")\n" &
      "local intent = entry.decide(frame, {})\n"
    else:
      "local registry = require(\"registry\")\n" &
      "require(\"" & name & "\")\n" &
      "local tool = registry.get(\"" & name & "\")\n" &
      "local intent = tool.decide(frame, {})\n"
  let script = (
    "package.path = [[" & packagePath & "]]\n" &
    "local frame = " & toLua(proj) & "\n" &
    loadBody &
    """
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
"""
  )
  let tmp = getTempDir() / ("army_decide_" & $getCurrentProcessId() & ".lua")
  writeFile(tmp, script)
  var bin = findExe("lua5.3")
  if bin.len == 0:
    bin = findExe("lua")
  if bin.len == 0:
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

# ---------- Config / connect ----------

proc parseConfig(): HostConfig =
  result = HostConfig(
    slot: 2,
    tool: "escort_leader",
    mode: "",
    leader: "Murist",
    party: @["Murist", "Shadowfel", "Igris", "Tusk", "Beru"],
    cadence: 0.0,
    cadenceOverride: false,
    acceptFrom: "Murist",
    maxSeconds: 0.0,
    quiet: true,
    auditPath: DefaultAuditPath,
    host: DefaultHost,
    port: 0,
    direct: true,
    account: DefaultAccount,
    password: DefaultPassword,
    character: "",
    gameUrl: DefaultGameUrl,
    token: DefaultToken,
    assetSlot: DefaultAssetSlot,
    polMinYards: 0.0,
    polRequireMove: false
  )
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "slot": result.slot = parseInt(val)
      of "tool": result.tool = val
      of "mode": result.mode = val
      of "leader": result.leader = val
      of "party": result.party = val.split(',')
      of "cadence":
        result.cadence = parseFloat(val)
        result.cadenceOverride = true
      of "accept-from": result.acceptFrom = val
      of "max-seconds": result.maxSeconds = parseFloat(val)
      of "verbose": result.quiet = false
      of "audit-path": result.auditPath = val
      of "no-audit": result.auditPath = ""
      of "host", "h": result.host = val
      of "port", "p": result.port = parseInt(val)
      of "direct": result.direct = true
      of "ws": result.direct = false
      of "account": result.account = val
      of "password": result.password = val
      of "character": result.character = val
      of "game-url": result.gameUrl = val
      of "token", "t": result.token = val
      of "asset-slot": result.assetSlot = parseInt(val)
      of "pol-min-yards": result.polMinYards = parseFloat(val)
      of "pol-require-move": result.polRequireMove = true
      # Dead goal-era flags: accepted and ignored so old Makefiles still parse.
      of "goal-id", "leader-slot", "external": discard
      else: discard
    else: discard
  if result.character.len == 0:
    # Sensible default when Makefile only passes --slot.
    result.character = "Slot" & $result.slot

proc attachPayload(cfg: HostConfig): string =
  ## Mirror of env_smoke / game relay env_attach_payload for direct TCP.
  randomize()
  var sid = ""
  for _ in 0 ..< 32:
    sid.add "0123456789abcdef"[rand(15)]
  let q = "?slot=" & $cfg.assetSlot & "&token=" & cfg.token
  $(%*{
    "protocol": "vanilla_wow.env.attach.v1",
    "type": "attach",
    "session_id": sid,
    "slot": cfg.slot,
    "account_username": cfg.account,
    "account_password": cfg.password,
    "character_name": cfg.character,
    "character_creation": nil,
    "simulation_time_scale": 1,
    "class_deck_enabled": false,
    "assets_base_url": cfg.gameUrl & "/player/assets" & q,
    "navmesh_service_url": cfg.gameUrl & "/player/navigation" & q
  })

proc connectHost(cfg: HostConfig): EnvClient =
  ## Direct (default) or WS relay attach. Does not receive hello.
  let port =
    if cfg.port != 0: cfg.port
    elif cfg.direct: DefaultDirectPort
    else: DefaultWsPort
  if cfg.direct:
    result = connectEnvDirect(cfg.host, port)
    result.sendAttach(attachPayload(cfg))
  else:
    result = connectEnv(cfg.host, port, cfg.slot, cfg.token)

proc say(msg: string) =
  echo msg
  flushFile(stdout)

# ---------- Main policy loop ----------

proc main() =
  var cfg = parseConfig()
  let transport = if cfg.direct: "direct" else: "ws"
  let policyLabel =
    if cfg.mode.len > 0: "mode=" & cfg.mode
    else: "tool=" & cfg.tool
  echo &"[army_host] env policy slot={cfg.slot} {policyLabel} " &
    &"leader={cfg.leader} transport={transport} character={cfg.character}"
  if cfg.auditPath.len > 0:
    echo &"[army_host] fair-play audit → {cfg.auditPath}"
  if cfg.polMinYards > 0:
    echo &"[army_host] pol-min-yards={cfg.polMinYards}"

  let auditTool =
    if cfg.mode.len > 0: "mode:" & cfg.mode
    else: cfg.tool
  var audit = AuditState(path: cfg.auditPath, slot: cfg.slot, tool: auditTool)
  var client: EnvClient
  try:
    client = connectHost(cfg)
  except EnvTransportError as e:
    echo closeMessage(e.closeCode, e.closeReason)
    if e.closeCode == 0:
      echo "[army_host] connect failed: ", e.msg
    quit 1
  except CatchableError as e:
    echo "[army_host] connect failed: ", e.msg
    quit 1
  defer:
    try: client.close()
    except CatchableError: discard

  # Hello (kind 12).
  var sessionId = ""
  var helloSlot = cfg.slot
  var actionDeadline = 5.0
  var detachedSteps = 0
  try:
    let hello = client.recvControlFrame()
    if hello.kind != FrameEnvHello:
      echo &"[army_host] expected hello kind {FrameEnvHello}, got {hello.kind}"
      quit 1
    let hnode = parseJson(hello.payload)
    sessionId = jstr(jget(hnode, "session_id"))
    helloSlot = jint(jget(hnode, "slot"), cfg.slot)
    actionDeadline = jnum(jget(hnode, "action_deadline_seconds"), 5.0)
    detachedSteps = jint(jget(hnode, "detached_steps"))
    if detachedSteps > 0:
      echo &"[army_host] resumed session_id={sessionId} slot={helloSlot} " &
        &"detached_steps={detachedSteps}"
    else:
      echo &"[army_host] hello session_id={sessionId} slot={helloSlot} " &
        &"action_deadline_seconds={actionDeadline}"
  except EnvTransportError as e:
    echo closeMessage(e.closeCode, e.closeReason)
    quit 1
  except CatchableError as e:
    echo "[army_host] hello failed: ", e.msg
    quit 1

  let loopCadence =
    if cfg.cadenceOverride: cfg.cadence
    elif actionDeadline > 0: actionDeadline
    else: 1.0

  var reqId: uint32 = 0
  var pendingAction = false   ## ONE pending action at a time (enforcement point).
  var lastSubmittedFrameId = -1
  let t0 = epochTime()
  var i = 0
  var lastHeartbeatAt = 0.0
  var lastIntent = ""
  const HeartbeatSec = 15.0
  var pathYards = 0.0
  var haveLastPos = false
  var lastX = 0.0
  var lastY = 0.0
  var acceptedMoves = 0
  var polPassed = false
  var lastSubmittedWasMove = false
  var pendingSince = 0.0
  const PendingStallSec = 30.0

  while true:
    if cfg.maxSeconds > 0 and epochTime() - t0 > cfg.maxSeconds:
      echo "[army_host] max-seconds path_yards=",
        pathYards.formatFloat(ffDecimal, 1),
        " accepted_moves=", acceptedMoves
      break
    inc i
    try:
      let frame = client.recvControlFrame()
      case frame.kind
      of FrameAgentFrame:
        var node: JsonNode
        try:
          node = unpackJson(frame.payload)
        except CatchableError as e:
          echo &"[army_host] msgpack error: {e.msg} bytes={frame.payload.len}"
          continue

        discard processFrame(audit, node)

        let frameId = jint(jget(node, "frame_id"))
        let name = jstr(jget(node, "name"))
        let loc = jget(node, "location")
        let px = jnum(jget(loc, "x"))
        let py = jnum(jget(loc, "y"))
        let pz = jnum(jget(loc, "z"))
        let mapId = jint(jget(loc, "map_id"))
        if loc != nil and jget(loc, "x") != nil:
          if haveLastPos:
            let dx = px - lastX
            let dy = py - lastY
            let step = sqrt(dx * dx + dy * dy)
            # Accept larger steps (teleport rare); reject only zero/noise.
            if step > 0.05 and step < 500.0:
              pathYards += step
          lastX = px
          lastY = py
          haveLastPos = true

        # ActionState settlement tracking.
        let st = actionStateStatus(node)
        if cfg.polMinYards > 0 and i <= 25:
          let detail = jstr(jget(node, "action_state", "detail"))
          let aid = jstr(jget(node, "action_state", "action_id"))
          echo "[army_host] diag #", i, " frame=", frameId,
            " astate=", st,
            " detail=", detail,
            " action_id=", aid,
            " map=", mapId,
            " pos=(", px.formatFloat(ffDecimal, 2), ",",
            py.formatFloat(ffDecimal, 2), ",",
            pz.formatFloat(ffDecimal, 2), ")",
            " path_yd=", pathYards.formatFloat(ffDecimal, 1)
        if pendingAction:
          case st
          of "pending":
            if pendingSince > 0 and epochTime() - pendingSince > PendingStallSec:
              echo "[army_host] pending stall >", PendingStallSec,
                "s — clear local pending to resubmit"
              pendingAction = false
              lastSubmittedFrameId = -1
              lastSubmittedWasMove = false
              pendingSince = 0.0
          of "rejected":
            # Recompute from this frame — do not resend the old body.
            pendingAction = false
            lastSubmittedFrameId = -1
            lastSubmittedWasMove = false
            pendingSince = 0.0
            if not cfg.quiet:
              say &"[army_host] action rejected frame={frameId} " &
                jstr(jget(node, "action_state", "detail"))
          of "succeeded", "failed", "timed_out", "cancelled", "":
            if st == "succeeded" and lastSubmittedWasMove:
              inc acceptedMoves
            pendingAction = false
            lastSubmittedFrameId = -1
            lastSubmittedWasMove = false
            pendingSince = 0.0
          else:
            pendingAction = false
            lastSubmittedFrameId = -1
            lastSubmittedWasMove = false
            pendingSince = 0.0

        if swingingAtOwnPet(node):
          echo "[army_host] warn aa-on-own-pet name=", name, " frame=", frameId

        let (proj, guids) = projectV2(node, cfg.leader)
        var intentDesc = "hold"
        try:
          let intent = runDecide(cfg, proj)
          if not cfg.quiet:
            say "[policy] intent " & $intent
          intentDesc = jstr(jget(intent, "kind"), "hold") & ":" &
            jstr(jget(intent, "reason"))
          let action = mapIntentV2(intent, guids)
          # ONE pending action at a time — skip submit while prior is pending.
          if action.isSome and not pendingAction:
            inc reqId
            let payload = actionSubmissionPayload(action.get, frameId, helloSlot)
            client.sendActionSubmission(reqId, payload)
            pendingAction = true
            pendingSince = epochTime()
            lastSubmittedFrameId = frameId
            lastSubmittedWasMove = jstr(jget(action.get, "kind")) == "move"
            recordSelect(
              audit, name, jstr(jget(action.get, "kind")), intent, true
            )
          elif action.isSome and pendingAction and not cfg.quiet:
            say &"[army_host] skip submit (pending) frame={frameId}"
        except CatchableError as e:
          echo "[army_host] decide FAIL: ", e.msg

        if cfg.polMinYards > 0 and pathYards >= cfg.polMinYards:
          let moveOk = (not cfg.polRequireMove) or acceptedMoves > 0
          if moveOk:
            echo "[army_host] pol PASS path_yards=",
              pathYards.formatFloat(ffDecimal, 1),
              " accepted_moves=", acceptedMoves
            polPassed = true
            break

        if intentDesc != lastIntent or
            epochTime() - lastHeartbeatAt >= HeartbeatSec:
          lastHeartbeatAt = epochTime()
          lastIntent = intentDesc
          echo "[army_host] #", i, " ", name,
            " intent=", intentDesc,
            " frame=", frameId,
            " pending=", pendingAction,
            " astate=", st,
            " path_yd=", pathYards.formatFloat(ffDecimal, 1),
            " moves=", acceptedMoves,
            " pos=(",
            px.formatFloat(ffDecimal, 0), ",",
            py.formatFloat(ffDecimal, 0), ")",
            " hp=", jnum(jget(proj, "combat", "health_pct")).formatFloat(
              ffDecimal, 0)

      of FrameControlError:
        echo "[army_host] control_error request_id=", frame.requestId, " ",
          frame.payload
      of FrameEnvClose:
        echo "[army_host] env_close: ", frame.payload
        break
      of FrameEnvHello:
        echo "[army_host] hello(re): ", frame.payload
      else:
        if not cfg.quiet:
          echo &"[army_host] frame kind={frame.kind} rid={frame.requestId} " &
            &"bytes={frame.payload.len}"

    except EnvTransportError as e:
      echo closeMessage(e.closeCode, e.closeReason)
      if e.closeCode == 0:
        echo "[army_host] loop error: ", e.msg
      # PoL runs must not soft-reconnect into a stale pending session.
      if cfg.polMinYards > 0:
        break
      # Soft reconnect for operator-run sessions only.
      try: client.close()
      except CatchableError: discard
      sleep(1000)
      try:
        client = connectHost(cfg)
        let hello = client.recvControlFrame()
        if hello.kind == FrameEnvHello:
          let hnode = parseJson(hello.payload)
          detachedSteps = jint(jget(hnode, "detached_steps"))
          sessionId = jstr(jget(hnode, "session_id"))
          echo &"[army_host] reconnected session_id={sessionId} " &
            &"detached_steps={detachedSteps}"
          pendingAction = false
          pendingSince = 0.0
        else:
          echo "[army_host] reconnect: unexpected frame ", hello.kind
          break
      except CatchableError as e2:
        echo "[army_host] reconnect failed: ", e2.msg
        break
    except CatchableError as e:
      echo "[army_host] loop error: ", e.msg

    # Cadence is a soft sleep between frames when the host is quiet; most
    # agent frames arrive pushed. Keep it small when deadline-driven.
    if loopCadence > 0 and loopCadence < 60:
      sleep(int(min(loopCadence, 0.25) * 1000))

  if cfg.polMinYards > 0:
    if polPassed:
      quit 0
    echo "[army_host] pol FAIL path_yards=",
      pathYards.formatFloat(ffDecimal, 1),
      " accepted_moves=", acceptedMoves,
      " need>=", cfg.polMinYards.formatFloat(ffDecimal, 1)
    quit 1

when isMainModule:
  main()
