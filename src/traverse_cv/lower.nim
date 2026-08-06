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
  ## Press key with optional mods. Always edge-up mods we edged-down — setKeyDesired
  ## alone left sticky Ctrl (live: Ctrl+Tab never released Control).
  if key.len == 0: return
  let mods = [
    ("KeyLeftControl", control),
    ("KeyLeftShift", shift),
    ("KeyLeftAlt", alt)
  ]
  var pressed: array[3, bool]
  for i, m in mods:
    pressed[i] = false
    if m[1] and not keyHeld(view, m[0]):
      appendKeyEdge(events, m[0], true)
      pressed[i] = true
    elif m[1]:
      discard  # already held
  appendKeyPress(events, key)
  for i, m in mods:
    if pressed[i]:
      appendKeyEdge(events, m[0], false)

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

proc formIconHint(spellId: int): string =
  ## Match ShapeshiftButtonNIcon texture substrings (druid stance bar).
  case spellId
  of TravelFormSpell: "TravelForm"
  of AquaticFormSpell: "AquaticForm"
  else: ""

proc formCastSlash(spellId: int): string =
  case spellId
  of TravelFormSpell: "/cast Travel Form"
  of AquaticFormSpell: "/cast Aquatic Form"
  else: ""

proc playerInForm*(view: JsonNode; spellId: int): bool =
  ## True if player already has this shapeshift. Never re-click / re-/cast —
  ## both paths toggle the form *off* in Classic when already active.
  let player = jget(view, "player")
  if player.isNil: return false
  let fid = jint(jget(player, "shapeshift_form_id"))
  let fsp = jint(jget(player, "shapeshift_form_spell_id"))
  # Aura fallback when form ids flake to 0 mid-swim (live: re-cast toggled off).
  var auraForm = 0
  let auras = jget(player, "active_aura_spell_ids")
  if not auras.isNil and auras.kind == JArray:
    for a in auras:
      let sid = jint(a)
      if sid == AquaticFormSpell or sid == TravelFormSpell:
        auraForm = sid
  case spellId
  of TravelFormSpell:
    fid == 3 or fsp == TravelFormSpell or auraForm == TravelFormSpell
  of AquaticFormSpell:
    fid == 4 or fsp == AquaticFormSpell or auraForm == AquaticFormSpell
  else:
    fsp == spellId and spellId > 0

proc chatSlashCommand(view: JsonNode; events: JsonNode; slash: string): bool =
  ## Multi-tick chat: open → type slash → enter. Returns true if this tick spent.
  if slash.len == 0: return false
  let gameplay = jget(view, "gameplay")
  let focused = jstr(jget(view, "focused_widget"))
  let chatOpen = focused == "ChatFrameEditBox" or
    (not gameplay.isNil and jbool(jget(gameplay, "chat_input_visible")))
  let chatText = if gameplay.isNil: "" else: jstr(jget(gameplay, "chat_input_text"))
  if chatOpen:
    if chatText == slash:
      appendKeyPress(events, "KeyEnter")
      return true
    if chatText.len > 0 and not slash.startsWith(chatText):
      appendKeyPress(events, "KeyEscape")
      return true
    if chatText.len == 0:
      events.add %*{"kind": "text_input", "text": slash}
      return true
    return true
  if not gameplay.isNil and jbool(jget(gameplay, "spell_book_open")):
    let b = bindingKey(view, "TOGGLESPELLBOOK")
    if b.key.len > 0:
      appendChordPress(view, events, b.key, b.shift, b.control, b.alt)
    else:
      appendKeyPress(events, "KeyP")
    return true
  appendKeyPress(events, "KeyEnter")
  true

proc clickShapeshiftForm(view: JsonNode; events: JsonNode; spellId: int): bool =
  ## Click the stance/form bar button whose icon matches the form spell.
  let hint = formIconHint(spellId)
  if hint.len == 0: return false
  let nodes = jget(view, "ui_nodes")
  if nodes.isNil or nodes.kind != JArray: return false
  var buttonName = ""
  for n in nodes:
    let src = jstr(jget(n, "source_name"))
    let icon = jstr(jget(n, "icon"))
    if src.startsWith("ShapeshiftButton") and src.endsWith("Icon") and
        icon.contains(hint):
      # ShapeshiftButton4Icon → ShapeshiftButton4
      buttonName = src[0 .. ^5]  # drop "Icon"
      break
  if buttonName.len == 0: return false
  # Close spellbook so bar clicks aren't swallowed.
  let gameplay = jget(view, "gameplay")
  if not gameplay.isNil and jbool(jget(gameplay, "spell_book_open")):
    let b = bindingKey(view, "TOGGLESPELLBOOK")
    if b.key.len > 0:
      appendChordPress(view, events, b.key, b.shift, b.control, b.alt)
    else:
      appendKeyPress(events, "KeyP")
    return true  # spend this tick closing book; cast next tick
  return clickControlSource(view, events, buttonName)

proc castFormViaChat(view: JsonNode; events: JsonNode; spellId: int): bool =
  ## Multi-tick /cast Form when stance-bar clicks don't stick (headless).
  let slash = formCastSlash(spellId)
  if slash.len == 0: return false
  chatSlashCommand(view, events, slash)

proc chatInputOpen(view: JsonNode): bool =
  let gameplay = jget(view, "gameplay")
  let focused = jstr(jget(view, "focused_widget"))
  focused == "ChatFrameEditBox" or
    (not gameplay.isNil and jbool(jget(gameplay, "chat_input_visible")))

proc castSpellEvents(view: JsonNode; spellId: int): JsonNode =
  ## Prefer shapeshift bar (forms), then /cast chat, then action bar, then spellbook.
  result = newJArray()
  let player = jget(view, "player")
  if not player.isNil and jbool(jget(player, "casting")):
    return result

  # Already in form: no-op. Re-cast / stance click toggles OFF (drowned the swim leg).
  # Also close leftover chat from a previous /cast attempt so move can resume.
  if formIconHint(spellId).len > 0 and playerInForm(view, spellId):
    if chatInputOpen(view):
      appendKeyPress(result, "KeyEscape")
    return result

  # Druid forms: stance bar single-click (chat multi-tick freezes swimming).
  # playerInForm (ids + auras + last_successful 1066) must prevent toggle-off.
  if formIconHint(spellId).len > 0:
    if chatInputOpen(view):
      appendKeyPress(result, "KeyEscape")
      return result
    if clickShapeshiftForm(view, result, spellId) and result.len > 0:
      return result
    # Aquatic: if stance missing, one chat attempt; travel same.
    if castFormViaChat(view, result, spellId):
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

  # --- Spellbook path (fallback if stance bar not in ClientView) ---
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
  # Close chat only when there is text to discard. Ghost GY stuck forever with
  # chat_input_visible=true + empty text; Escape/Enter never cleared the flag.
  let gameplay0 = jget(view, "gameplay")
  let chatText0 =
    if gameplay0.isNil: "" else: jstr(jget(gameplay0, "chat_input_text"))
  if chatInputOpen(view) and chatText0.len > 0:
    appendKeyPress(result, "KeyEscape")
    return result
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
  let keyQ = movementKey(view, "STRAFELEFT", "KeyQ")
  let keyE = movementKey(view, "STRAFERIGHT", "KeyE")
  let keyS = movementKey(view, "MOVEBACKWARD", "KeyS")

  # Always clear strafe/back first — unstick used to leave sticky KeyQ (live:
  # held Q+W forever, empty batches, orbiting water_entry).
  setKeyDesired(view, result, keyQ, false)
  setKeyDesired(view, result, keyE, false)
  setKeyDesired(view, result, keyS, false)

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

  # Geometry stick: moving=false → jump + strafe. Also periodic jump while
  # moving — live: KeyW into mesa wall, moving=true, position frozen forever.
  let moving = jbool(jget(player, "moving"))
  let phase = jint(jget(view, "view_id")) div 6
  if dist > 5.0 and ((not moving) or (phase mod 8) == 0):
    let jumpKey = movementKey(view, "JUMP", "Space")
    appendKeyPress(result, jumpKey)
  if not moving and dist > 5.0:
    case phase mod 3
    of 0:
      setKeyDesired(view, result, keyQ, true)
      setKeyDesired(view, result, keyA, true)
      setKeyDesired(view, result, keyD, false)
      setKeyDesired(view, result, keyW, true)
    of 1:
      setKeyDesired(view, result, keyE, true)
      setKeyDesired(view, result, keyD, true)
      setKeyDesired(view, result, keyA, false)
      setKeyDesired(view, result, keyW, true)
    else:
      setKeyDesired(view, result, keyW, false)
      setKeyDesired(view, result, keyS, true)
      setKeyDesired(view, result, keyA, phase mod 2 == 0)
      setKeyDesired(view, result, keyD, phase mod 2 != 0)

proc releaseMoveEvents(view: JsonNode): JsonNode =
  result = newJArray()
  setKeyDesired(view, result, movementKey(view, "MOVEFORWARD", "KeyW"), false)
  setKeyDesired(view, result, movementKey(view, "TURNLEFT", "KeyA"), false)
  setKeyDesired(view, result, movementKey(view, "TURNRIGHT", "KeyD"), false)
  setKeyDesired(view, result, movementKey(view, "MOVEBACKWARD", "KeyS"), false)
  setKeyDesired(view, result, movementKey(view, "STRAFELEFT", "KeyQ"), false)
  setKeyDesired(view, result, movementKey(view, "STRAFERIGHT", "KeyE"), false)
  # Sticky Ctrl from TARGETNEARESTFRIEND left chat/Enter dead (live ghost stuck).
  for modKey in ["KeyLeftControl", "KeyRightControl", "KeyLeftShift",
                 "KeyRightShift", "KeyLeftAlt", "KeyRightAlt"]:
    setKeyDesired(view, result, modKey, false)

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
    let holdReason = if intent.isNil: "" else: jstr(jget(intent, "reason"))
    # Death popups: click Accept on StaticPopup when releasing / reclaiming.
    if holdReason in ["release_spirit", "reclaim_corpse", "dead"]:
      let nodes = jget(view, "ui_nodes")
      if not nodes.isNil and nodes.kind == JArray:
        for n in nodes:
          let src = jstr(jget(n, "source_name"))
          let text = jstr(jget(n, "text"))
          if src.contains("StaticPopup") and src.contains("Button1"):
            let pt = jget(n, "input_point")
            if not pt.isNil:
              clickNormalized(events, jnum(jget(pt, "x")), jnum(jget(pt, "y")))
              break
          if text.toLowerAscii().contains("release") or
              text.toLowerAscii().contains("resurrect") or
              text.toLowerAscii().contains("retrieve"):
            let pt = jget(n, "input_point")
            if not pt.isNil:
              clickNormalized(events, jnum(jget(pt, "x")), jnum(jget(pt, "y")))
              break
  of "cast_spell":
    events = releaseMoveEvents(view)
    let reason = jstr(jget(intent, "reason"))
    let spell = jint(jget(intent, "spell"))
    # Shore leave: /cancelform is more reliable than toggling Travel again.
    if reason == "leave_travel_at_shore":
      discard chatSlashCommand(view, events, "/cancelform")
    elif spell > 0:
      # Guard: never re-issue form cast if already shifted (toggle-off).
      if formIconHint(spell).len == 0 or not playerInForm(view, spell):
        let castEv = castSpellEvents(view, spell)
        for e in castEv:
          events.add e
  of "move", "move_to":
    events = moveEvents(view, intent)
  of "interact":
    # Ghost → Spirit Healer. Headless chat Enter often fails to submit.
    # Order: XP_LOSS Accept → clear chat → gossip title → scene click.
    events = releaseMoveEvents(view)
    let gameplay = jget(view, "gameplay")
    let name = jstr(jget(intent, "name"), "Spirit Healer")
    let viewId = jint(jget(view, "view_id"))
    var handled = false
    # 1) Resurrect Accept popup (XP_LOSS) — never re-click spirit while up.
    if not gameplay.isNil:
      let popups = jget(gameplay, "popups")
      if not popups.isNil and popups.kind == JArray:
        for p in popups:
          let accept = jstr(jget(p, "accept_control"))
          if accept.len > 0 and clickControlSource(view, events, accept):
            handled = true
            break
          let dname = jstr(jget(p, "dialog_name"))
          if dname == "XP_LOSS" or dname.contains("RESURRECT"):
            if clickControlSource(view, events, "StaticPopup1Button1"):
              handled = true
              break
    # 2) Close leftover chat with text so clicks aren't typed into the box.
    # Empty open chat flag is ignored (ghost GY stuck: visible=true, text="").
    if not handled:
      let chatText =
        if gameplay.isNil: "" else: jstr(jget(gameplay, "chat_input_text"))
      if chatText.len > 0:
        appendKeyPress(events, "KeyEscape")
        handled = true
    # 3) Gossip title option (not Close/Goodbye).
    if not handled and not gameplay.isNil and jbool(jget(gameplay, "gossip_open")):
      var clickedPopup = false
      let choices = jget(gameplay, "gossip_choices")
      if not choices.isNil and choices.kind == JArray:
        for ch in choices:
          let ctrl = jstr(jget(ch, "control_source"))
          if ctrl.len > 0 and clickControlSource(view, events, ctrl):
            clickedPopup = true
            break
      let nodes = jget(view, "ui_nodes")
      if not clickedPopup and not nodes.isNil and nodes.kind == JArray:
        for n in nodes:
          let src = jstr(jget(n, "source_name"))
          if src.startsWith("GossipTitleButton"):
            let pt = jget(n, "input_point")
            if not pt.isNil:
              clickNormalized(events, jnum(jget(pt, "x")), jnum(jget(pt, "y")))
              clickedPopup = true
              break
      if not clickedPopup:
        discard chatSlashCommand(view, events, "/run SelectGossipOption(1)")
      handled = true
    # 4) Target + interact. Scene bounds often garbage (0,0 half-screen) —
    # prefer Ctrl+Tab nearest friend then InteractUnit (live: 0.85yd unselected).
    if not handled:
      var spiritSelected = false
      let worldNodes = jget(view, "world_nodes")
      if not worldNodes.isNil and worldNodes.kind == JArray:
        for node in worldNodes:
          let nname = jstr(jget(node, "name"))
          if nname == name or nname == "Spirit Healer":
            spiritSelected = jbool(jget(node, "selected"))
            break
      if not spiritSelected:
        # TARGETNEARESTFRIEND = Ctrl+Tab (mods edge-up fixed).
        appendChordPress(view, events, "KeyTab", false, true, false)
      else:
        # Headless scene right-click no-ops on Spirit Healer (live: selected
        # 0.85yd, gossip never opens). InteractUnit chat multi-tick.
        if (viewId mod 3) == 0:
          discard chatSlashCommand(view, events, "/run InteractUnit(\"target\")")
        elif (viewId mod 3) == 1:
          discard chatSlashCommand(view, events, "/run SelectGossipOption(1)")
        else:
          discard chatSlashCommand(view, events, "/run AcceptXPLoss()")
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
