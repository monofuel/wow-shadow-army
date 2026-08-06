import std/[json, os]
import ../../src/petrel/embed
let repo = getCurrentDir()
let fixtures = repo / "tools/fixtures/clientview"
for name in ["tanaris_land.json", "tanaris_travel_form.json", "swimming.json"]:
  var view = parseJson(readFile(fixtures / name))
  if name == "swimming.json": view["view_id"] = %0
  echo name, " -> ", globalDecideFromViewJson($view, repo)
var v = parseJson(readFile(fixtures / "swimming.json"))
v["player"]["shapeshift_form_id"] = %4
v["player"]["shapeshift_form_spell_id"] = %1066
v["player"]["position"]["x"] = %(-5000.0)
v["player"]["position"]["y"] = %(-4500.0)
echo "mid_ocean_aquatic -> ", globalDecideFromViewJson($v, repo)
