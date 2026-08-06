## In-process Petrel embed: project fixture → strategy intent (no process spawn).
import std/[json, os, strutils, unittest]
import ../../src/petrel/embed
import ../../src/traverse_cv/[project, decide]

let repo = getCurrentDir()
let fixtures = repo / "tools" / "fixtures" / "clientview"

suite "petrel embed":
  test "land fixture → navigate or cast_spell strategy":
    let view = parseJson(readFile(fixtures / "tanaris_land.json"))
    let proj = projectClientView(view)
    let intent = globalDecide(proj, repo)
    let kind = intent{"kind"}.getStr
    check kind in ["navigate", "cast_spell", "hold"]
    if kind == "navigate":
      check intent.hasKey("x")
      check intent.hasKey("y")
      check intent{"mode"}.getStr.len > 0
      check intent{"reason"}.getStr != "embed_boot_failed"
    if kind == "cast_spell":
      check intent{"spell"}.getInt == 783

  test "travel form fixture → navigate land beat":
    let view = parseJson(readFile(fixtures / "tanaris_travel_form.json"))
    let proj = projectClientView(view)
    let intent = runTraverseDecide(proj, repo)
    check intent{"kind"}.getStr == "navigate"
    check intent{"reason"}.getStr in ["land_approach", "water_entry", "enter_water"]
    check intent{"x"}.getFloat > -9200.0

  test "swimming wrong form → aquatic cast_spell":
    let view = parseJson(readFile(fixtures / "swimming.json"))
    var proj = projectClientView(view)
    # force even view_id for cast cadence
    proj["view_id"] = %0
    let intent = globalDecide(proj, repo)
    check intent{"kind"}.getStr == "cast_spell"
    check intent{"spell"}.getInt == 1066

  test "swimming aquatic mid-ocean → navigate merchant":
    var view = parseJson(readFile(fixtures / "swimming.json"))
    view["player"]["shapeshift_form_id"] = %4
    view["player"]["shapeshift_form_spell_id"] = %1066
    view["player"]["position"]["x"] = %(-5000.0)
    view["player"]["position"]["y"] = %(-4500.0)
    let proj = projectClientView(view)
    let intent = globalDecide(proj, repo)
    check intent{"kind"}.getStr == "navigate"
    check intent{"reason"}.getStr == "swim_merchant"
    check intent{"mode"}.getStr == "liquid_prefer"
    check intent{"x"}.getFloat > -2000.0  # merchant-ish north

  test "wet near merchant → hold merchant_coast":
    var view = parseJson(readFile(fixtures / "swimming.json"))
    view["player"]["shapeshift_form_id"] = %4
    view["player"]["shapeshift_form_spell_id"] = %1066
    view["player"]["position"]["x"] = %(-1533.7 + 20.0)
    view["player"]["position"]["y"] = %(-4056.5 - 20.0)
    view["player"]["swimming"] = %true
    let proj = projectClientView(view)
    let intent = globalDecide(proj, repo)
    check intent{"kind"}.getStr == "hold"
    check intent{"reason"}.getStr == "merchant_coast"

  test "decide path is not subprocess (no TRAVERSE_LUA_BRIDGE binary)":
    # Structural: decide.nim imports petrel/embed only.
    let src = readFile(repo / "src" / "traverse_cv" / "decide.nim")
    check "petrel/embed" in src
    check "execCmdEx" notin src
    check "findLua" notin src
