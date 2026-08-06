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

suite "lowerIntent":
  test "cast_spell presses Digit1 for travel form":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let intent = %*{"kind": "cast_spell", "spell": 783, "reason": "travel_form"}
    let batch = lowerIntent(view, intent, 1)
    check jstr(jget(batch, "type")) == "client_input_batch"
    check jint(jget(batch, "expected_view_id")) == 42
    let events = jget(batch, "events")
    check events.kind == JArray
    var sawDown = false
    for e in events:
      if jstr(jget(e, "kind")) == "key_down" and jstr(jget(e, "key")) == "Digit1":
        sawDown = true
    check sawDown

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

suite "runTraverseDecide":
  test "land without form → cast travel":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    check jstr(jget(intent, "kind")) == "cast_spell"
    check jint(jget(intent, "spell")) == 783

  test "travel form → move toward checkpoint":
    let view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    check jstr(jget(intent, "kind")) == "move"
    check jstr(jget(intent, "reason")) == "water_entry"

  test "swimming wrong form → aquatic cast":
    let view = parseJson(readFile(fixtures / "swimming.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    check jstr(jget(intent, "kind")) == "cast_spell"
    check jint(jget(intent, "spell")) == 1066

  test "bridge end-to-end land":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    let batch = lowerIntent(view, intent, 1)
    check jstr(jget(batch, "type")) == "client_input_batch"
    check jget(batch, "events").len > 0
