local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.bagModel

local function one(item, player)
  local r = model.evaluate({ items = { item }, player = player })
  return r.items[1], r
end

local it, r

it, r = one({ data = { sell = 12 } })
check(it.tag == model.SELL and it.reason == "gray" and it.sell == 12,
  "omitted fields default to zero: bare sell row is a gray sell")

it, r = one({ data = { sell = 5, q = 1 } })
check(it.tag == model.HOLD and it.reason == "consumable — USE not implemented",
  "omitted class means Consumable, not unknown")

it, r = one({ data = nil })
check(it.tag == model.HOLD and it.reason == "unknown item" and r.unknown == 1,
  "an item with no ItemData row holds as unknown")

it, r = one({ data = { class = 12, sell = 5000, q = 1 } })
check(it.tag == model.KEEP_QUEST and it.reason == "quest item",
  "a quest item is never sold, however rich")

it, r = one({ data = { q = 0, sell = 0, class = 15 } })
check(it.tag == model.HOLD and it.reason == "no value",
  "gray with no vendor price is not a sale")

local warlock = { level = 10, classToken = "WARLOCK", equipped = {} }
local cloth = { class = 4, sub = 1, slot = 5, lvl = 12, q = 1, sell = 40 }

it, r = one({ data = cloth }, warlock)
check(it.tag == model.EQUIP and it.equipSlot == "chest" and it.reason == "chest slot is empty",
  "an empty slot takes any wearable cloth piece")

it, r = one({ data = cloth }, { level = 10, classToken = "WARLOCK", equipped = { chest = { lvl = 5 } } })
check(it.tag == model.EQUIP and it.reason == "chest upgrade il12>5",
  "a higher item level upgrades the worn piece")

it, r = one({ data = cloth }, { level = 10, classToken = "WARLOCK", equipped = { chest = { lvl = 20 } } })
check(it.tag == model.HOLD and it.reason == "chest il12 <= worn il20",
  "a lower item level is not an upgrade")

it, r = one({ data = { class = 4, sub = 1, slot = 5, lvl = 30, req = 20, q = 2, sell = 90 } }, warlock)
check(it.tag == model.HOLD and it.reason == "needs level 20",
  "equip needs the required level")

it, r = one({ data = { class = 4, sub = 2, slot = 5, lvl = 12, q = 1, sell = 40 } }, warlock)
check(it.tag == model.HOLD and it.reason == "not your armor type",
  "a warlock wears cloth only - leather holds")

it, r = one({ data = { class = 4, sub = 0, slot = 2, lvl = 8, q = 2, sell = 100 } }, warlock)
check(it.tag == model.EQUIP and it.equipSlot == "neck",
  "Misc armor (subclass 0) is wearable by every class")

it, r = one({ data = { class = 2, sub = 7, slot = 13, lvl = 10, req = 5, q = 2, sell = 244 } })
check(it.tag == model.HOLD and it.reason == "weapon — your call",
  "a weapon punts to the human")

it, r = one({ data = { class = 4, sub = 4, slot = 5, lvl = 12, q = 1 } }, { classToken = "WARRIOR" })
check(it.tag == model.HOLD and it.reason == "equippable — no proficiency rule",
  "a class with no proficiency rule punts")

r = model.evaluate({
  items = {
    { count = 5, data = { sell = 12 } },
    { count = 1, data = { sell = 3 } },
  },
})
check(r.sellCount == 2 and r.sellCopper == 63, "sell totals multiply by stack count")

r = model.evaluate({})
check(#r.items == 0 and r.sellCopper == 0, "an empty snapshot is safe")

print("test_advisor_bag_model: " .. passed .. " checks passed")
