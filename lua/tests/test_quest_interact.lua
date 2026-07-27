-- Unit tests for quest_interact decide.
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local qi = require("tools.quest_interact")

local function assert_eq(a, b, msg)
  if a ~= b then error((msg or "assert_eq") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
end

-- Accept concrete offer
do
  local frame = {
    self_unit = { x = 0, y = 0, z = 0, map_id = 0 },
    quest = {
      offers = { { id = 367, quest_factor = 1, entity_id = 11 } },
      interactables = {},
      turn_ins = {},
    },
  }
  local d = qi.decide(frame, {})
  assert_eq(d.kind, "accept_quest")
  assert_eq(d.quest_id, 367)
  assert_eq(d.quest_factor, 1)
end

-- Synthetic empty offer (id=0 factor=0) → discovery accept on open dialog
do
  local frame = {
    self_unit = { x = 0, y = 0, z = 0, map_id = 0 },
    quest = {
      offers = { { id = 0, quest_factor = 0, entity_id = 11 } },
      interactables = {
        { id = 20, kind = "unit", is_questgiver = true, services = { "questgiver", "vendor" }, x = 1, y = 0, z = 0 },
        { id = 11, kind = "unit", is_questgiver = true, services = { "questgiver" }, x = 2, y = 0, z = 0 },
      },
      turn_ins = {},
    },
  }
  local d = qi.decide(frame, {})
  assert_eq(d.kind, "accept_quest")
  assert_eq(d.unit_id, 11)
  assert_eq(d.reason, "accept_discovery")
end

-- Prefer pure questgiver over vendor when approaching
do
  local frame = {
    self_unit = { x = 0, y = 0, z = 0, map_id = 0 },
    quest = {
      offers = {},
      interactables = {
        { id = 20, kind = "unit", is_questgiver = true, services = { "questgiver", "vendor" }, x = 1, y = 0, z = 0 },
        { id = 11, kind = "unit", is_questgiver = true, services = { "questgiver" }, x = 50, y = 0, z = 0 },
      },
      turn_ins = {},
    },
  }
  local d = qi.decide(frame, {})
  assert_eq(d.kind, "move_to_unit")
  assert_eq(d.unit_id, 11, "prefer pure qg even if farther")
end

print("test_quest_interact: ok")
