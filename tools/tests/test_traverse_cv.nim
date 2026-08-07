## Unit tests: ClientView projection + intent→ClientInputBatch + Lua decide.
import std/[json, os, strutils, unittest]
import ../../src/traverse_cv/[project, lower, decide]

let repo = getCurrentDir()
let fixtures = repo / "tools" / "fixtures" / "clientview"

suite "projectClientView":
  test "land pose and spells":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let p = projectClientView(view)
    check jnum(jget(jget(p, "self_unit"), "x")) == -9187.0
    check jnum(jget(jget(p, "self_unit"), "y")) == -2530.0
    check jbool(jget(jget(p, "self_unit"), "is_swimming")) == false
    check jnum(jget(jget(p, "combat"), "health_pct")) == 100.0
    let known = jget(jget(p, "spells"), "known")
    check known.kind == JArray
    var hasTravel = false
    for id in known:
      if jint(id) == 783: hasTravel = true
    check hasTravel

  test "swimming flag":
    let view = parseJson(readFile(fixtures / "swimming.json"))
    let p = projectClientView(view)
    check jbool(jget(jget(p, "self_unit"), "is_swimming")) == true

  test "typed fatigue projection":
    var view = parseJson(readFile(fixtures / "swimming.json"))
    view["player"]["fatigue_timer_active"] = %true
    view["player"]["fatigue_remaining_fraction"] = %0.42
    let environment = projectClientView(view){"environment"}
    check environment{"fatigue_known"}.getBool
    check environment{"fatigue_active"}.getBool
    check abs(environment{"fatigue_remaining_fraction"}.getFloat - 0.42) < 0.001

suite "lowerIntent":
  test "cast_spell batch is well-formed for travel form":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let intent = %*{"kind": "cast_spell", "spell": 783, "reason": "travel_form"}
    let batch = lowerIntent(view, intent, 1)
    check jstr(jget(batch, "type")) == "client_input_batch"
    check jint(jget(batch, "expected_view_id")) == 42
    check jint(jget(batch, "sequence")) == 1
    let events = jget(batch, "events")
    check events.kind == JArray
    # Fixture may lack stance-bar icons; empty events is ok for bare land fixture.

  test "move holds KeyW when facing target":
    let view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    # Goal north (+X) while facing orientation 0 → forward
    let intent = %*{
      "kind": "move", "map_id": 1, "x": -9000.0, "y": -2530.0, "z": 0.7,
      "intent": "travel", "reason": "water_entry"
    }
    let batch = lowerIntent(view, intent, 2)
    let events = jget(batch, "events")
    var forwardDown = false
    for e in events:
      if jstr(jget(e, "kind")) == "key_down" and jstr(jget(e, "key")) == "KeyW":
        forwardDown = true
    check forwardDown

  test "hold releases keys":
    let view = parseJson(readFile(fixtures / "swimming.json"))
    let intent = %*{"kind": "hold", "reason": "water_entry"}
    let batch = lowerIntent(view, intent, 3)
    let events = jget(batch, "events")
    var releasedW = false
    for e in events:
      if jstr(jget(e, "kind")) == "key_up" and jstr(jget(e, "key")) == "KeyW":
        releasedW = true
    check releasedW

  test "swim move never jumps":
    # Periodic land jump used Space while swimming → surface + cancel Aquatic.
    var view = parseJson(readFile(fixtures / "swimming.json"))
    view["view_id"] = %48  # would have hit phase mod 8 jump cadence
    let player = jget(view, "player")
    if not player.isNil:
      player["moving"] = %false  # land path jumped on not-moving too
    let intent = %*{
      "kind": "move", "map_id": 1, "x": -6500.0, "y": -4800.0, "z": -5.0,
      "intent": "travel", "reason": "swim_duskwallow"
    }
    let batch = lowerIntent(view, intent, 4)
    let events = jget(batch, "events")
    for e in events:
      let key = jstr(jget(e, "key"))
      check key != "Space" and key != "KeySpace"
      # JUMP binding may still be named Space in fixtures; guard kind+key only.

  test "land stuck never jumps or strafes":
    # Old unstick: Space + Q/E/S thrash when not moving. Motion-sick and cliffs.
    var view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    view["view_id"] = %48
    let player = jget(view, "player")
    if not player.isNil:
      player["moving"] = %false
      player["swimming"] = %false
    let intent = %*{
      "kind": "move", "map_id": 1, "x": -7100.0, "y": -4600.0, "z": 5.0,
      "intent": "travel", "reason": "land_approach"
    }
    let batch = lowerIntent(view, intent, 5)
    let events = jget(batch, "events")
    for e in events:
      let key = jstr(jget(e, "key"))
      check key != "Space" and key != "KeySpace"
      # May release Q/E/S (key_up) but must never press them down for thrash.
      if jstr(jget(e, "kind")) == "key_down":
        check key != "KeyQ" and key != "KeyE" and key != "KeyS"

  test "large heading error turns without W (no W+A curve thrash)":
    # Goal west while facing north → must turn, must not hold W while turning.
    var view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    view["held_keys"] = %*[]
    let intent = %*{
      "kind": "move", "map_id": 1, "x": -9187.0, "y": -2000.0, "z": 16.0,
      "intent": "travel", "reason": "water_entry"
    }
    let batch = lowerIntent(view, intent, 6)
    let events = jget(batch, "events")
    var turnDown = false
    var wDown = false
    for e in events:
      if jstr(jget(e, "kind")) != "key_down": continue
      let key = jstr(jget(e, "key"))
      if key == "KeyA" or key == "KeyD": turnDown = true
      if key == "KeyW": wDown = true
    check turnDown
    check wDown == false

  test "hysteresis keeps one turn direction (no A/D chatter)":
    # Already holding A with small residual left error: keep A, never press D.
    var view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    view["held_keys"] = %*["KeyA"]
    # Face slightly left of target north: orientation a bit negative of 0.
    let player = jget(view, "player")
    if not player.isNil:
      let pos = jget(player, "position")
      if not pos.isNil:
        pos["orientation"] = %(-0.2)  # need left turn toward 0 for +X goal
    let intent = %*{
      "kind": "move", "map_id": 1, "x": -9000.0, "y": -2530.0, "z": 16.0,
      "intent": "travel", "reason": "water_entry"
    }
    let batch = lowerIntent(view, intent, 7)
    let events = jget(batch, "events")
    for e in events:
      if jstr(jget(e, "kind")) == "key_down":
        check jstr(jget(e, "key")) != "KeyD"
      if jstr(jget(e, "kind")) == "key_up":
        # Must not release A while still needing left (delta > TurnDone).
        check jstr(jget(e, "key")) != "KeyA"

suite "runTraverseDecide":
  test "land without form → cast travel or navigate":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    let kind = jstr(jget(intent, "kind"))
    check kind == "cast_spell" or kind == "navigate" or kind == "hold"
    if kind == "cast_spell":
      check jint(jget(intent, "spell")) == 783

  test "travel form → navigate toward beat":
    let view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    check jstr(jget(intent, "kind")) == "navigate"
    let reason = jstr(jget(intent, "reason"))
    check reason == "water_entry" or reason == "land_approach" or
      reason == "enter_water"

  test "swimming wrong form → aquatic cast":
    var view = parseJson(readFile(fixtures / "swimming.json"))
    view["view_id"] = %0
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    check jstr(jget(intent, "kind")) == "cast_spell"
    check jint(jget(intent, "spell")) == 1066
    check jstr(jget(intent, "reason")) == "aquatic_form"

  test "already in aquatic form → cast_spell emits no toggle events":
    var view = parseJson(readFile(fixtures / "swimming.json"))
    view["player"]["shapeshift_form_id"] = %4
    view["player"]["shapeshift_form_spell_id"] = %1066
    view["player"]["shapeshift_form_known"] = %true
    view["player"]["shapeshift_form_spell_known"] = %true
    let intent = %*{"kind": "cast_spell", "spell": 1066, "reason": "aquatic_form"}
    let batch = lowerIntent(view, intent, 9)
    let events = jget(batch, "events")
    # May release movement keys, but must not open chat / click stance (toggle-off).
    var castish = false
    for e in events:
      let k = jstr(jget(e, "kind"))
      if k == "text_input" or k == "mouse_down":
        castish = true
    check castish == false

  test "bridge end-to-end land":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    let batch = lowerIntent(view, intent, 1)
    check jstr(jget(batch, "type")) == "client_input_batch"
    check jget(batch, "events").len > 0
