## ClientView JSON → frozen Lua table for lua/entry/traverse.lua.
## Wire-independent: only needs a ClientView-shaped JSON object (vanilla_wow.client.v2).

import std/[json, strutils]

proc jget*(n: JsonNode; k: string): JsonNode =
  if n.isNil or n.kind != JObject or not n.hasKey(k): nil
  else: n[k]

proc jstr*(n: JsonNode; default = ""): string =
  if n.isNil: return default
  case n.kind
  of JString: n.getStr()
  of JInt: $n.getBiggestInt()
  of JFloat: $n.getFloat()
  of JBool: $n.getBool()
  else: default

proc jbool*(n: JsonNode; default = false): bool =
  if n.isNil: return default
  case n.kind
  of JBool: n.getBool()
  of JInt: n.getBiggestInt() != 0
  else: default

proc jnum*(n: JsonNode; default = 0.0): float =
  if n.isNil: return default
  case n.kind
  of JFloat: n.getFloat()
  of JInt: n.getBiggestInt().float
  of JString:
    try: parseFloat(n.getStr())
    except CatchableError: default
  else: default

proc jint*(n: JsonNode; default = 0): int =
  if n.isNil: return default
  case n.kind
  of JInt: int(n.getBiggestInt())
  of JFloat: int(n.getFloat())
  of JString:
    try: parseInt(n.getStr())
    except CatchableError: default
  else: default

proc projectClientView*(view: JsonNode): JsonNode =
  ## Build the minimal table traverse.lua expects:
  ## self_unit, combat.health_pct, death, spells.known
  result = newJObject()
  if view.isNil or view.kind != JObject:
    return result

  result["view_id"] = %jint(jget(view, "view_id"))
  let player = jget(view, "player")
  let gameplay = jget(view, "gameplay")

  var selfUnit = newJObject()
  if not player.isNil and player.kind == JObject:
    let pos = jget(player, "position")
    if not pos.isNil and pos.kind == JObject and jbool(jget(player, "position_known"), true):
      selfUnit["x"] = %jnum(jget(pos, "x"))
      selfUnit["y"] = %jnum(jget(pos, "y"))
      selfUnit["z"] = %jnum(jget(pos, "z"))
      selfUnit["map_id"] = %jint(jget(pos, "map_id"))
      selfUnit["orientation"] = %jnum(jget(pos, "orientation"))
    selfUnit["is_swimming"] = %jbool(jget(player, "swimming"))
    var formId = if jbool(jget(player, "shapeshift_form_known")):
      jint(jget(player, "shapeshift_form_id"))
    else:
      -1
    var formSpell = if jbool(jget(player, "shapeshift_form_spell_known")):
      jint(jget(player, "shapeshift_form_spell_id"))
    else:
      -1
    # Aura fallback: form fields flake to 0 while still shifted → re-cast toggles OFF.
    # Travel 783 / Aquatic 1066 appear on active_aura_spell_ids when present.
    let auras = jget(player, "active_aura_spell_ids")
    if not auras.isNil and auras.kind == JArray:
      for a in auras:
        let sid = jint(a)
        if sid == 1066:
          formSpell = 1066
          formId = 4
        elif sid == 783 and formSpell != 1066:
          formSpell = 783
          formId = 3
    # Live: last_successful_spell_id==1066 while swimming, form ids stay 0, breath
    # timer off — cast "succeeded" but fields lag. Treat as aquatic so we move.
    if formSpell <= 0 and jbool(jget(player, "swimming")):
      let lastOk =
        if not gameplay.isNil: jint(jget(gameplay, "last_successful_spell_id"))
        else: 0
      let breathOn = jbool(jget(player, "breath_timer_active"))
      if lastOk == 1066 and not breathOn:
        formSpell = 1066
        formId = 4
    if formId >= 0:
      selfUnit["shapeshift_form_id"] = %formId
    if formSpell >= 0:
      selfUnit["shapeshift_form_spell_id"] = %formSpell
    selfUnit["moving"] = %jbool(jget(player, "moving"))
    selfUnit["name"] = %jstr(jget(player, "name"))
    # Breath (drown) — ClientView player fields when present.
    selfUnit["breath_timer_active"] = %jbool(jget(player, "breath_timer_active"))
    selfUnit["breath_remaining_fraction"] = %jnum(jget(player, "breath_remaining_fraction"), 1.0)
    selfUnit["liquid_submerged"] = %jbool(jget(player, "liquid_submerged"))
    selfUnit["liquid_coverage_known"] = %jbool(
      jget(player, "liquid_coverage_known"))
    selfUnit["liquid_known"] = %jbool(jget(player, "liquid_known"))
    selfUnit["liquid_surface_z"] = %jnum(jget(player, "liquid_surface_z"))
  result["self_unit"] = selfUnit

  var env = newJObject()
  if not player.isNil and player.kind == JObject:
    env["fatigue_active"] = %jbool(jget(player, "fatigue_timer_active"))
    env["fatigue_remaining_fraction"] = %jnum(
      jget(player, "fatigue_remaining_fraction"), 1.0)
    env["fatigue_known"] = %true
  else:
    env["fatigue_known"] = %false
  result["environment"] = env

  var combat = newJObject()
  if not player.isNil and player.kind == JObject:
    let maxHp = jnum(jget(player, "max_health"))
    let hp = jnum(jget(player, "health"))
    if jbool(jget(player, "health_known")) and maxHp > 0:
      combat["health_pct"] = %(100.0 * hp / maxHp)
    else:
      combat["health_pct"] = %100.0
    combat["in_combat"] = %jbool(jget(player, "in_combat"))
  result["combat"] = combat

  var death = newJObject()
  if not gameplay.isNil and gameplay.kind == JObject:
    death["is_dead"] = %jbool(jget(gameplay, "dead"))
    var isGhost = jbool(jget(gameplay, "ghost"))
    # Fallback: Ghost form aura 8326 (gameplay.ghost can flake while aura sticks).
    if not isGhost and not player.isNil:
      let auras = jget(player, "active_aura_spell_ids")
      if not auras.isNil and auras.kind == JArray:
        for a in auras:
          if jint(a) == 8326:
            isGhost = true
            break
    death["is_ghost"] = %isGhost
    death["can_reclaim_corpse"] = %jbool(jget(gameplay, "can_reclaim_corpse"))
    death["corpse_known"] = %jbool(jget(gameplay, "corpse_known"))
    let corpse = jget(gameplay, "corpse")
    if not corpse.isNil and corpse.kind == JObject:
      death["corpse_x"] = %jnum(jget(corpse, "x"))
      death["corpse_y"] = %jnum(jget(corpse, "y"))
      death["corpse_z"] = %jnum(jget(corpse, "z"))
      death["corpse_map_id"] = %jint(jget(corpse, "map_id"))
    death["gossip_open"] = %jbool(jget(gameplay, "gossip_open"))
  # Spirit Healer unit from ClientView world_nodes (ghost recovery).
  death["spirit_healer_known"] = %false
  let worldNodes = jget(view, "world_nodes")
  if not worldNodes.isNil and worldNodes.kind == JArray:
    for node in worldNodes:
      if jstr(jget(node, "role")) != "unit":
        continue
      let nname = jstr(jget(node, "name"))
      var isSpirit = nname == "Spirit Healer"
      if not isSpirit:
        let services = jget(node, "services")
        if not services.isNil and services.kind == JArray:
          for s in services:
            if jstr(s) == "spirit_healer":
              isSpirit = true
              break
      if not isSpirit:
        continue
      death["spirit_healer_known"] = %true
      death["spirit_healer_name"] = %nname
      death["spirit_healer_guid"] = %jstr(jget(node, "guid"))
      let dist = jnum(jget(node, "distance"), 9999.0)
      death["spirit_healer_dist"] = %dist
      if jbool(jget(node, "interaction_distance_known")):
        death["spirit_healer_interact_dist"] = %jnum(jget(node, "interaction_distance"), 5.0)
      let pos = jget(node, "position")
      if not pos.isNil and pos.kind == JObject:
        death["spirit_healer_x"] = %jnum(jget(pos, "x"))
        death["spirit_healer_y"] = %jnum(jget(pos, "y"))
        death["spirit_healer_z"] = %jnum(jget(pos, "z"))
      break
  result["death"] = death

  var spells = newJObject()
  var known = newJArray()
  if not gameplay.isNil and gameplay.kind == JObject:
    let ids = jget(gameplay, "known_spell_ids")
    if not ids.isNil and ids.kind == JArray:
      for id in ids:
        known.add %jint(id)
  # Also surface action-bar spell ids so form casts are "known" if only on bar.
  let slots = jget(view, "action_slots")
  if not slots.isNil and slots.kind == JArray:
    for slot in slots:
      let sid = jint(jget(slot, "spell_id"))
      if sid > 0:
        var already = false
        for k in known:
          if jint(k) == sid:
            already = true
            break
        if not already:
          known.add %sid
  spells["known"] = known
  result["spells"] = spells

  # Pass-through for lowerer (not used by Lua decide).
  result["_view_id"] = %jint(jget(view, "view_id"))
  result["_client_ready"] = %jbool(jget(view, "client_ready"))
