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
    if jbool(jget(player, "shapeshift_form_known")):
      selfUnit["shapeshift_form_id"] = %jint(jget(player, "shapeshift_form_id"))
    if jbool(jget(player, "shapeshift_form_spell_known")):
      selfUnit["shapeshift_form_spell_id"] = %jint(jget(player, "shapeshift_form_spell_id"))
    selfUnit["moving"] = %jbool(jget(player, "moving"))
    selfUnit["name"] = %jstr(jget(player, "name"))
  result["self_unit"] = selfUnit

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
    death["is_ghost"] = %jbool(jget(gameplay, "ghost"))
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
