## Lua traverse intents → ClientInputBatch JSON (vanilla_wow.client.v2).

import std/[json, math, strutils]
import project

const
  ClientProtocol* = "vanilla_wow.client.v2"
  TravelFormSpell* = 783
  AquaticFormSpell* = 1066
  TurnThreshold* = 0.35   ## radians before we turn instead of only pressing W
  ArriveHoldYards* = 0.0  ## lowerer does not hold; Lua already holds at checkpoint

proc eventKey(kind, key: string): JsonNode =
  %*{"kind": kind, "key": key}

proc appendKeyEdge(events: JsonNode; key: string; pressed: bool) =
  events.add eventKey(if pressed: "key_down" else: "key_up", key)

proc appendKeyPress(events: JsonNode; key: string) =
  appendKeyEdge(events, key, true)
  appendKeyEdge(events, key, false)

proc keyHeld(view: JsonNode; key: string): bool =
  let held = jget(view, "held_keys")
  if held.isNil or held.kind != JArray: return false
  for h in held:
    if jstr(h) == key: return true
  false

proc setKeyDesired(view: JsonNode; events: JsonNode; key: string; desired: bool) =
  if keyHeld(view, key) != desired:
    appendKeyEdge(events, key, desired)

proc bindingKey(view: JsonNode; command: string): tuple[key: string, shift, control, alt: bool] =
  result.key = ""
  let bindings = jget(view, "bindings")
  if bindings.isNil or bindings.kind != JArray: return
  for b in bindings:
    if jstr(jget(b, "command")) == command and jstr(jget(b, "key")).len > 0:
      return (
        key: jstr(jget(b, "key")),
        shift: jbool(jget(b, "shift")),
        control: jbool(jget(b, "control")),
        alt: jbool(jget(b, "alt"))
      )

proc movementKey(view: JsonNode; command, fallback: string): string =
  let b = bindingKey(view, command)
  if b.key.len > 0: b.key else: fallback

proc appendChordPress(view: JsonNode; events: JsonNode; key: string;
                      shift, control, alt: bool) =
  if key.len == 0: return
  let mods = [
    ("KeyLeftControl", control),
    ("KeyLeftShift", shift),
    ("KeyLeftAlt", alt)
  ]
  var was: array[3, bool]
  for i, m in mods:
    was[i] = keyHeld(view, m[0])
    setKeyDesired(view, events, m[0], m[1])
  appendKeyPress(events, key)
  for i, m in mods:
    setKeyDesired(view, events, m[0], was[i])

proc findSpellSlot(view: JsonNode; spellId: int): JsonNode =
  let slots = jget(view, "action_slots")
  if slots.isNil or slots.kind != JArray: return nil
  for slot in slots:
    if jint(jget(slot, "spell_id")) == spellId:
      return slot
  nil

proc clickNormalized(events: JsonNode; x, y: float) =
  ## Left-click at normalized ClientView coordinates (0..1).
  events.add %*{"kind": "mouse_move", "position": {"x": x, "y": y}}
  events.add %*{
    "kind": "mouse_down", "button": "left",
    "position": {"x": x, "y": y}
  }
  events.add %*{
    "kind": "mouse_up", "button": "left",
    "position": {"x": x, "y": y}
  }

proc clickControlSource(view: JsonNode; events: JsonNode; source: string): bool =
  ## Click a UI node by source_name (spellbook buttons etc.).
  if source.len == 0: return false
  let nodes = jget(view, "ui_nodes")
  if nodes.isNil or nodes.kind != JArray: return false
  for n in nodes:
    if jstr(jget(n, "source_name")) == source:
      let pt = jget(n, "input_point")
      if pt.isNil: return false
      clickNormalized(events, jnum(jget(pt, "x")), jnum(jget(pt, "y")))
      return true
  false

proc castSpellEvents(view: JsonNode; spellId: int): JsonNode =
  ## Press action-bar binding, else multi-tick spellbook navigation.
  result = newJArray()
  let player = jget(view, "player")
  if not player.isNil and jbool(jget(player, "casting")):
    return result
  let slot = findSpellSlot(view, spellId)
  if not slot.isNil:
    let key = jstr(jget(slot, "binding_key"))
    if key.len > 0:
      appendChordPress(
        view, result, key,
        jbool(jget(slot, "binding_shift")),
        jbool(jget(slot, "binding_control")),
        jbool(jget(slot, "binding_alt"))
      )
      return
    let slotIdx = jint(jget(slot, "slot"))
    if slotIdx >= 1 and slotIdx <= 12:
      let b = bindingKey(view, "ACTIONBUTTON" & $slotIdx)
      if b.key.len > 0:
        appendChordPress(view, result, b.key, b.shift, b.control, b.alt)
        return
      appendKeyPress(result, "Key" & $(if slotIdx < 10: $slotIdx else: "0"))
      return

  # --- Spellbook path (forms often not on main bar in the traverse fixture) ---
  let gameplay = jget(view, "gameplay")
  if gameplay.isNil:
    return result
  let bookOpen = jbool(jget(gameplay, "spell_book_open"))
  if not bookOpen:
    let b = bindingKey(view, "TOGGLESPELLBOOK")
    if b.key.len > 0:
      appendChordPress(view, result, b.key, b.shift, b.control, b.alt)
    else:
      appendKeyPress(result, "KeyP")
    return result

  # Find spell in catalog (may be on another tab/page).
  var targetSpell: JsonNode = nil
  let spells = jget(gameplay, "spell_book_spells")
  if not spells.isNil and spells.kind == JArray:
    for sp in spells:
      if jint(jget(sp, "spell_id")) == spellId:
        targetSpell = sp
        break
  if targetSpell.isNil:
    # Close book and give up this tick.
    let b = bindingKey(view, "TOGGLESPELLBOOK")
    if b.key.len > 0:
      appendChordPress(view, result, b.key, b.shift, b.control, b.alt)
    return result

  let wantTab = jint(jget(targetSpell, "tab_index"))
  let wantPage = jint(jget(targetSpell, "page"))
  let tabs = jget(gameplay, "spell_book_tabs")
  if not tabs.isNil and tabs.kind == JArray and wantTab >= 1 and wantTab <= tabs.len:
    var selectedIdx = -1
    for ti in 0 ..< tabs.len:
      if jbool(jget(tabs[ti], "selected")):
        selectedIdx = ti
        break
    if selectedIdx + 1 != wantTab:
      let want = tabs[wantTab - 1]
      let wctrl = jstr(jget(want, "control_source"))
      if wctrl.len > 0 and clickControlSource(view, result, wctrl):
        return result
      let label = jstr(jget(want, "label"))
      let nodes = jget(view, "ui_nodes")
      if not nodes.isNil and nodes.kind == JArray:
        for n in nodes:
          if label.len > 0 and jstr(jget(n, "text")) == label:
            let pt = jget(n, "input_point")
            if not pt.isNil:
              clickNormalized(result, jnum(jget(pt, "x")), jnum(jget(pt, "y")))
              return result
      # Fall through: still try paging/clicking

  let curPage = jint(jget(gameplay, "spell_book_page"))
  if wantPage > 0 and curPage > 0 and curPage < wantPage:
    let nextCtrl = jstr(jget(gameplay, "spell_book_next_control"))
    if nextCtrl.len > 0 and clickControlSource(view, result, nextCtrl):
      return result
    appendKeyPress(result, "PageDown")
    return result
  if wantPage > 0 and curPage > wantPage:
    let prevCtrl = jstr(jget(gameplay, "spell_book_prev_control"))
    if prevCtrl.len > 0 and clickControlSource(view, result, prevCtrl):
      return result
    appendKeyPress(result, "PageUp")
    return result

  let ctrl = jstr(jget(targetSpell, "control_source"))
  if ctrl.len > 0 and clickControlSource(view, result, ctrl):
    return result
  if jbool(jget(targetSpell, "visible")):
    let name = jstr(jget(targetSpell, "spell_name"))
    let nodes = jget(view, "ui_nodes")
    if not nodes.isNil and nodes.kind == JArray:
      for n in nodes:
        if name.len > 0 and jstr(jget(n, "text")).contains(name):
          let pt = jget(n, "input_point")
          if not pt.isNil:
            clickNormalized(result, jnum(jget(pt, "x")), jnum(jget(pt, "y")))
            return result

  return result

proc normalizeAngle(a: float): float =
  ## Wrap to (-PI, PI].
  result = a
  while result <= -PI: result += 2 * PI
  while result > PI: result -= 2 * PI

proc moveEvents(view: JsonNode; intent: JsonNode): JsonNode =
  ## Face toward (x,y) and hold MOVEFORWARD. Uses stock W/A/D fallbacks.
  result = newJArray()
  # Close spellbook if still open so movement keys aren't swallowed by UI.
  let gameplay = jget(view, "gameplay")
  if not gameplay.isNil and jbool(jget(gameplay, "spell_book_open")):
    let b = bindingKey(view, "TOGGLESPELLBOOK")
    if b.key.len > 0:
      appendChordPress(view, result, b.key, b.shift, b.control, b.alt)
    else:
      appendKeyPress(result, "KeyP")
    return result
  let player = jget(view, "player")
  let pos = if player.isNil: nil else: jget(player, "position")
  if pos.isNil or not jbool(jget(player, "position_known"), true):
    return result
  let
    px = jnum(jget(pos, "x"))
    py = jnum(jget(pos, "y"))
    o = jnum(jget(pos, "orientation"))
    tx = jnum(jget(intent, "x"))
    ty = jnum(jget(intent, "y"))
    dx = tx - px
    dy = ty - py
    dist = sqrt(dx * dx + dy * dy)
  if dist < 1.0:
    # Release movement keys near hop target; Lua will issue next hop.
    setKeyDesired(view, result, movementKey(view, "MOVEFORWARD", "KeyW"), false)
    setKeyDesired(view, result, movementKey(view, "TURNLEFT", "KeyA"), false)
    setKeyDesired(view, result, movementKey(view, "TURNRIGHT", "KeyD"), false)
    return result

  # WoW: orientation 0 faces +X (north); increasing orientation turns left (CCW)
  # toward +Y. desired = atan2(dy, dx) matches that convention.
  let desired = arctan2(dy, dx)
  let delta = normalizeAngle(desired - o)

  let keyW = movementKey(view, "MOVEFORWARD", "KeyW")
  let keyA = movementKey(view, "TURNLEFT", "KeyA")
  let keyD = movementKey(view, "TURNRIGHT", "KeyD")

  if delta > TurnThreshold:
    setKeyDesired(view, result, keyA, true)
    setKeyDesired(view, result, keyD, false)
    setKeyDesired(view, result, keyW, abs(delta) < 1.2)
  elif delta < -TurnThreshold:
    setKeyDesired(view, result, keyD, true)
    setKeyDesired(view, result, keyA, false)
    setKeyDesired(view, result, keyW, abs(delta) < 1.2)
  else:
    setKeyDesired(view, result, keyA, false)
    setKeyDesired(view, result, keyD, false)
    setKeyDesired(view, result, keyW, true)

proc releaseMoveEvents(view: JsonNode): JsonNode =
  result = newJArray()
  setKeyDesired(view, result, movementKey(view, "MOVEFORWARD", "KeyW"), false)
  setKeyDesired(view, result, movementKey(view, "TURNLEFT", "KeyA"), false)
  setKeyDesired(view, result, movementKey(view, "TURNRIGHT", "KeyD"), false)
  setKeyDesired(view, result, movementKey(view, "MOVEBACKWARD", "KeyS"), false)

proc lowerIntent*(
  view: JsonNode;
  intent: JsonNode;
  sequence: int
): JsonNode =
  ## Return a client_input_batch object (not string).
  let viewId = jint(jget(view, "view_id"))
  var events = newJArray()
  let kind = if intent.isNil: "hold" else: jstr(jget(intent, "kind"), "hold")
  case kind
  of "hold", "":
    events = releaseMoveEvents(view)
  of "cast_spell":
    events = releaseMoveEvents(view)
    let spell = jint(jget(intent, "spell"))
    if spell > 0:
      let castEv = castSpellEvents(view, spell)
      for e in castEv:
        events.add e
  of "move", "move_to":
    events = moveEvents(view, intent)
  else:
    events = releaseMoveEvents(view)

  result = %*{
    "protocol": ClientProtocol,
    "type": "client_input_batch",
    "expected_view_id": viewId,
    "sequence": sequence,
    "events": events
  }

proc lowerIntentString*(
  view: JsonNode;
  intent: JsonNode;
  sequence: int
): string =
  $lowerIntent(view, intent, sequence)
