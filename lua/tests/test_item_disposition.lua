local D = require("item_disposition")

local checks = 0
local function check(ok, label)
  assert(ok, label)
  checks = checks + 1
end

local function decide(item, player, equipment)
  return D.decide(item, player, {
    bags = D.equipped_bags(equipment),
    worn = D.equipped_by_slot(equipment),
  })
end

local warlock = { class_id = 9 }
local warrior = { class_id = 1 }
local rogue = { class_id = 4 }
local priest = { class_id = 5 }

local mail_bracer = {
  item_class_id = 4, item_subclass_id = 3, quality = 1, sell_price = 55,
}
local cloth_robe = {
  item_class_id = 4, item_subclass_id = 1, quality = 1, sell_price = 30,
  inventory_type = 20, item_level = 10,
}
local plate = {
  item_class_id = 4, item_subclass_id = 4, quality = 1, sell_price = 10,
}
local leather = {
  item_class_id = 4, item_subclass_id = 2, quality = 1, sell_price = 10,
}
local ring = {
  item_class_id = 4, item_subclass_id = 0, quality = 1, sell_price = 10,
}

local r

-- A. Armor proficiency
r = decide(mail_bracer, warlock)
check(r.tag == D.SELL, "warlock white mail bracer sells")

r = decide(cloth_robe, warlock)
check(r.tag == D.HOLD, "warlock white cloth robe holds")
check(r.tag ~= D.SELL, "warlock white cloth robe never sells")

r = decide(mail_bracer, warrior)
check(r.tag == D.HOLD, "warrior white mail bracer holds")

r = decide(plate, rogue)
check(r.tag == D.SELL, "rogue plate sells")
r = decide(leather, rogue)
check(r.tag == D.HOLD, "rogue leather holds")

r = decide(ring, warlock)
check(r.tag == D.HOLD, "misc armor subclass 0 holds")
check(r.tag ~= D.SELL, "misc armor subclass 0 never sells")
r = decide(ring, warrior)
check(r.tag ~= D.SELL, "warrior misc armor never sells")

r = decide(mail_bracer, { class_id = 99 })
check(r.tag == D.HOLD, "unknown class mail holds")
check(string.find(r.reason, "no armor proficiency rule", 1, true),
  "unknown class reason mentions no armor proficiency rule")

-- B. Quality / never-sell guards
r = decide({
  item_class_id = 4, item_subclass_id = 3, quality = 2, sell_price = 55,
}, warlock)
check(r.tag == D.HOLD, "green mail on warlock holds")

r = decide({ item_class_id = 12, quality = 1, sell_price = 100 }, warlock)
check(r.tag == D.KEEP, "quest item is KEEP")
check(r.tag ~= D.SELL, "quest item never sells")

r = decide({
  item_id = 6948, item_class_id = 15, quality = 1, sell_price = 0,
}, warlock)
check(r.tag == D.KEEP, "Hearthstone is KEEP")

r = decide({
  item_class_id = 4, item_subclass_id = 3, quality = 1, sell_price = 0,
}, warlock)
check(r.tag == D.HOLD, "unusable mail with sell_price 0 holds")

r = decide({ definition_known = false }, warlock)
check(r.tag == D.HOLD and r.reason == "unknown item",
  "definition_known false holds as unknown item")

-- C. Bags
local four_six = {
  { equipment_slot = 19, container_slots = 6 },
  { equipment_slot = 20, container_slots = 6 },
  { equipment_slot = 21, container_slots = 6 },
  { equipment_slot = 22, container_slots = 6 },
}
local three_six = {
  { equipment_slot = 19, container_slots = 6 },
  { equipment_slot = 20, container_slots = 6 },
  { equipment_slot = 21, container_slots = 6 },
}
local pouch6 = {
  item_class_id = 1, item_subclass_id = 0, quality = 1,
  container_slots = 6, container_item_count = 0, sell_price = 25,
}
local bag8 = {
  item_class_id = 1, item_subclass_id = 0, quality = 1,
  container_slots = 8, container_item_count = 0, sell_price = 25,
}

r = decide(pouch6, warlock, four_six)
check(r.tag == D.SELL, "spare 6-slot pouch with four 6-slot bags sells")

r = decide(bag8, warlock, four_six)
check(r.tag == D.HOLD, "8-slot bag vs four 6-slot bags holds as upgrade")

r = decide(pouch6, warlock, three_six)
check(r.tag == D.HOLD, "pouch with a free bag slot holds")
check(string.find(r.reason, "free bag slot", 1, true),
  "three equipped bags mention a free bag slot")

r = decide({
  item_class_id = 1, item_subclass_id = 0, quality = 1,
  container_slots = 6, container_item_count = 2, sell_price = 25,
}, warlock, four_six)
check(r.tag == D.HOLD, "non-empty 6-slot pouch holds")

-- D. Grey armor upgrade guard
local grey_chest = {
  item_class_id = 4, item_subclass_id = 1, quality = 0,
  inventory_type = 5, item_level = 10, sell_price = 5,
}
local worn_robe = { { inventory_type = 20, item_level = 15 } }

r = decide(grey_chest, priest, worn_robe)
check(r.tag == D.SELL, "grey cloth chest worse than worn robe sells")

r = decide({
  item_class_id = 4, item_subclass_id = 1, quality = 0,
  inventory_type = 5, item_level = 20, sell_price = 5,
}, priest, worn_robe)
check(r.tag == D.HOLD, "grey cloth chest upgrade holds")

r = decide(grey_chest, priest, {})
check(r.tag == D.HOLD, "grey cloth chest with empty chest slot holds")

-- E. Junk + non-junk
r = decide({ item_class_id = 15, quality = 0, sell_price = 3 }, warlock)
check(r.tag == D.SELL and r.reason == "grey junk", "grey misc sells as grey junk")

r = decide({ item_class_id = 7, quality = 1, sell_price = 1 }, warlock)
check(r.tag == D.HOLD, "white trade good holds")
check(r.tag ~= D.SELL, "white trade good never sells")

r = decide({ item_class_id = 0, quality = 1, sell_price = 1 }, warlock)
check(r.tag == D.HOLD, "white consumable holds")

-- F. Weapons
r = decide({
  item_class_id = 2, item_subclass_id = 1, quality = 1, sell_price = 20,
}, warlock)
check(r.tag == D.SELL, "warlock 2H axe sells")

r = decide({
  item_class_id = 2, item_subclass_id = 15, quality = 1, sell_price = 20,
}, warlock)
check(r.tag == D.HOLD, "warlock dagger holds")

local wand = {
  item_class_id = 2, item_subclass_id = 19, quality = 1, sell_price = 20,
}
r = decide(wand, priest)
check(r.tag == D.HOLD, "priest wand holds")
r = decide(wand, warrior)
check(r.tag == D.SELL, "warrior wand sells")

-- G. evaluate()
local snap_items = {
  {
    item_id = 1001, name = "Mail Bracer", count = 1,
    item_class_id = 4, item_subclass_id = 3, quality = 1, sell_price = 55,
  },
  {
    item_id = 1002, name = "Cloth Robe", count = 1,
    item_class_id = 4, item_subclass_id = 1, quality = 1, sell_price = 30,
    inventory_type = 20, item_level = 10,
  },
  {
    item_id = 1003, name = "Chipped Claw", count = 2,
    item_class_id = 15, quality = 0, sell_price = 3,
  },
  {
    item_id = 2589, name = "Linen Cloth", count = 20,
    item_class_id = 7, quality = 1, sell_price = 1,
  },
  {
    item_id = 6948, name = "Hearthstone", count = 1,
    item_class_id = 15, quality = 1, sell_price = 0,
  },
  {
    item_id = 1004, name = "Two-Handed Axe", count = 1,
    item_class_id = 2, item_subclass_id = 1, quality = 1, sell_price = 40,
  },
  {
    item_id = 1005, name = "Small Pouch", count = 1,
    item_class_id = 1, item_subclass_id = 0, quality = 1,
    container_slots = 6, container_item_count = 0, sell_price = 25,
  },
}
local out = D.evaluate({
  items = snap_items,
  equipment = four_six,
  player = warlock,
})
-- SELL: mail 55*1, claw 3*2, axe 40*1, pouch 25*1
check(#out.sell == 4, "evaluate sell count")
check(out.sell_copper == 55 + 6 + 40 + 25, "evaluate sell_copper is SELL rows only")
for i = 1, #snap_items do
  local row, it = snap_items[i], out.items[i]
  check(it.item_id == row.item_id and it.name == row.name and it.count == row.count,
    "evaluate row " .. i .. " carries item_id/name/count")
end

print("test_item_disposition: " .. checks .. " checks passed")
