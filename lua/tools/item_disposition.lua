-- Bot-side bag disposition: "this seat is standing at a vendor with 16 full
-- bag slots — what does it sell?" (monofuel, 2026-08-16: "if our bot has gear
-- that it can't equip, it should sell ... if bot already had 6 slot bags, and
-- can't use another 6 slot bag, bot should sell").
--
-- Pure Lua. No `wow` API, no view, no globals — lua/tests drives it on host
-- Lua exactly like the advisor's BagModel (ticket 0039 phase 2), which this
-- mirrors where the rules agree. It deliberately does NOT share code with
-- addons/ShadowArmy/ShadowArmy.lua: that model reads the mined ItemData table
-- (a row per item id, fields omitted at their default), while a seat reads the
-- fork's Observation rows, where every field is present and named differently.
-- One shared table with two data contracts is how a bag-slot index ends up
-- compared against INVTYPE_HEAD.
--
-- THE DATA COMES FROM THE OBSERVATION, NOT FROM A BAKED FILE. The fork's
-- inventory rows already carry item_class_id / item_subclass_id / quality /
-- container_slots / sell_price / inventory_type / item_level, so there is no
-- gen_*_facts.lua to bake and nothing to keep in sync with a patch. What is
-- missing is the projection into the Lua view — see tickets/open/0073.
--
-- SAFETY IS THE WHOLE POINT. Every rule here can destroy something the human
-- cares about, and a seat cannot ask. So the model only ever returns SELL when
-- it is certain, and the certainty is bounded three ways:
--   * quality: uncommon and better (>= 2) is NEVER auto-sold, whatever the
--     proficiency table says. Bind-on-pickup status is not knowable from the
--     rows a seat sees (`bound_known` is false for nearly everything), so
--     white/grey is the honest ceiling.
--   * proficiency: "cannot use" means the class can never learn it at 60, not
--     "cannot use yet". A level-20 warrior holding mail keeps it.
--   * upgrades: armor the seat CAN wear is only sold when the matching slot is
--     already filled with equal-or-better item level. Empty slot or higher
--     ilvl = someone else's decision (equip), never a sale.

local M = {}

M.SELL = "SELL"
M.HOLD = "HOLD"
M.KEEP = "KEEP"

-- item_template.class
M.CLASS_CONSUMABLE = 0
M.CLASS_CONTAINER = 1
M.CLASS_WEAPON = 2
M.CLASS_ARMOR = 4
M.CLASS_REAGENT = 9
M.CLASS_QUEST = 12
M.CLASS_MISC = 15

-- item_template.subclass for class 4 (armor)
M.ARMOR_MISC = 0 -- necks, rings, trinkets, held-in-off-hand: everyone
M.ARMOR_CLOTH = 1
M.ARMOR_LEATHER = 2
M.ARMOR_MAIL = 3
M.ARMOR_PLATE = 4
M.ARMOR_SHIELD = 6

M.QUALITY_POOR = 0
M.QUALITY_COMMON = 1

-- Never sold by id, whatever the table says. The Hearthstone is the seat's
-- only way home and it is worth 0 copper anyway.
M.NEVER_SELL_ITEM_IDS = { [6948] = true }

-- 1.12 class ids (Observation.class_id).
M.WARRIOR, M.PALADIN, M.HUNTER, M.ROGUE, M.PRIEST = 1, 2, 3, 4, 5
M.SHAMAN, M.MAGE, M.WARLOCK, M.DRUID = 7, 8, 9, 11

-- Armor subclasses a class can EVER wear (at 60, all trainers visited).
-- Subclass 0 (Misc: necks/rings/trinkets/held-in-off-hand) is universal and
-- lives outside the table so an unknown class never sells jewellery.
M.ARMOR_PROFICIENCY = {
  [M.WARRIOR] = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true },
  [M.PALADIN] = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true },
  [M.HUNTER]  = { [1] = true, [2] = true, [3] = true },
  [M.ROGUE]   = { [1] = true, [2] = true },
  [M.PRIEST]  = { [1] = true },
  [M.SHAMAN]  = { [1] = true, [2] = true, [3] = true, [6] = true },
  [M.MAGE]    = { [1] = true },
  [M.WARLOCK] = { [1] = true },
  [M.DRUID]   = { [1] = true, [2] = true },
}

-- Weapon subclasses a class can EVER learn. Same "at 60" rule as armor.
-- 0 axe1h, 1 axe2h, 2 bow, 3 gun, 4 mace1h, 5 mace2h, 6 polearm, 7 sword1h,
-- 8 sword2h, 10 staff, 13 fist, 15 dagger, 16 thrown, 18 crossbow, 19 wand.
-- 14 (misc) and 20 (fishing pole) are usable by everyone and stay out of the
-- table for the same reason ARMOR_MISC does.
M.WEAPON_PROFICIENCY = {
  [M.WARRIOR] = { [0]=true, [1]=true, [2]=true, [3]=true, [4]=true, [5]=true,
    [6]=true, [7]=true, [8]=true, [10]=true, [13]=true, [15]=true, [16]=true,
    [18]=true },
  [M.PALADIN] = { [0]=true, [1]=true, [4]=true, [5]=true, [6]=true, [7]=true,
    [8]=true },
  [M.HUNTER]  = { [0]=true, [1]=true, [2]=true, [3]=true, [6]=true, [7]=true,
    [8]=true, [10]=true, [13]=true, [15]=true, [16]=true, [18]=true },
  [M.ROGUE]   = { [2]=true, [3]=true, [4]=true, [7]=true, [13]=true,
    [15]=true, [16]=true, [18]=true },
  [M.PRIEST]  = { [4]=true, [10]=true, [15]=true, [19]=true },
  [M.SHAMAN]  = { [0]=true, [1]=true, [4]=true, [5]=true, [10]=true,
    [13]=true, [15]=true },
  [M.MAGE]    = { [7]=true, [10]=true, [15]=true, [19]=true },
  [M.WARLOCK] = { [7]=true, [10]=true, [15]=true, [19]=true },
  [M.DRUID]   = { [4]=true, [5]=true, [6]=true, [10]=true, [13]=true,
    [15]=true },
}

M.UNIVERSAL_WEAPON_SUBCLASS = { [14] = true, [20] = true }

-- inventory_type -> the one slot key we compare item levels within. Same
-- table as the advisor's BagModel.EQUIP_SLOT and for the same reason: ROBE
-- (20) is a chest piece, and the two-position slots (FINGER 11, TRINKET 12)
-- plus every weapon slot are NOT comparable this way, so they are absent and
-- their items never reach the "already have better" branch.
M.SLOT_KEY = {
  [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest",
  [6] = "waist", [7] = "legs", [8] = "feet", [9] = "wrist",
  [10] = "hands", [16] = "back", [20] = "chest", [23] = "off-hand",
}

-- The four carried bag slots (fork environment/client/items.nim
-- CarriedBagSlotStart = 19).
M.BAG_SLOT_FIRST = 19
M.BAG_SLOT_LAST = 22
M.BAG_SLOT_COUNT = 4

local function num(value, fallback)
  local n = tonumber(value)
  if n == nil then return fallback end
  return n
end

--- true when `class_id` can never wear armor subclass `sub`.
-- nil (not false) when we have no rule for the class — the caller must punt.
function M.armor_unusable(class_id, sub)
  if sub == M.ARMOR_MISC then return false end
  local allowed = M.ARMOR_PROFICIENCY[class_id]
  if not allowed then return nil end
  return not allowed[sub]
end

--- true when `class_id` can never wield weapon subclass `sub`.
function M.weapon_unusable(class_id, sub)
  if M.UNIVERSAL_WEAPON_SUBCLASS[sub] then return false end
  local allowed = M.WEAPON_PROFICIENCY[class_id]
  if not allowed then return nil end
  return not allowed[sub]
end

--- Equipped bags, as { count = <filled slots>, smallest = <slots in the
--- smallest one> }. `smallest` is nil while any of the four slots is empty:
--- an empty slot means the right answer for a carried bag is EQUIP, and no
--- comparison should be able to talk us out of that.
function M.equipped_bags(equipment_items)
  local count, smallest = 0, nil
  for i = 1, #(equipment_items or {}) do
    local row = equipment_items[i] or {}
    local slot = num(row.equipment_slot, -1)
    if slot >= M.BAG_SLOT_FIRST and slot <= M.BAG_SLOT_LAST then
      count = count + 1
      local slots = num(row.container_slots, 0)
      if not smallest or slots < smallest then smallest = slots end
    end
  end
  if count < M.BAG_SLOT_COUNT then smallest = nil end
  return { count = count, smallest = smallest }
end

--- Worn gear indexed by SLOT_KEY, keeping the best item level per key.
function M.equipped_by_slot(equipment_items)
  local worn = {}
  for i = 1, #(equipment_items or {}) do
    local row = equipment_items[i] or {}
    local key = M.SLOT_KEY[num(row.inventory_type, -1)]
    if key then
      local ilvl = num(row.item_level, 0)
      if not worn[key] or ilvl > worn[key] then worn[key] = ilvl end
    end
  end
  return worn
end

local function hold(reason)
  return { tag = M.HOLD, reason = reason }
end

local function sell(reason)
  return { tag = M.SELL, reason = reason }
end

--- One bag row -> { tag, reason }. ORDER MATTERS; first match wins and the
--- order comment is the spec.
-- item: an Observation inventory row (item_id, quality, item_class_id,
--   item_subclass_id, inventory_type, container_slots, container_item_count,
--   sell_price, item_level, count, name).
-- player: { class_id, level }
-- context: { bags = M.equipped_bags(...), worn = M.equipped_by_slot(...) }
function M.decide(item, player, context)
  item = item or {}
  player = player or {}
  context = context or {}
  local bags = context.bags or { count = 0 }
  local worn = context.worn or {}

  local class = num(item.item_class_id, nil)
  local sub = num(item.item_subclass_id, 0)
  local quality = num(item.quality, nil)
  local price = num(item.sell_price, 0)
  local class_id = num(player.class_id, nil)

  -- 1. A row we cannot read is a row we do not touch. `definition_known`
  --    false means the client never got the item template; guessing from a
  --    name is how a quest chain gets vendored.
  if class == nil or quality == nil or item.definition_known == false then
    return hold("unknown item")
  end

  -- 2. Quest items are never sold, whatever they are worth. FIRST, so no
  --    later rule can reach them.
  if class == M.CLASS_QUEST then return { tag = M.KEEP, reason = "quest item" } end
  if M.NEVER_SELL_ITEM_IDS[num(item.item_id, 0)] then
    return { tag = M.KEEP, reason = "never sell" }
  end

  -- 3. Bind status is not knowable from these rows, so uncommon and better
  --    is out of scope for an unattended seat. Also: nothing worth 0 copper
  --    is worth a vendor click.
  if quality > M.QUALITY_COMMON then return hold("uncommon or better") end
  if price <= 0 then return hold("no vendor value") end
  if item.conjured then return hold("conjured") end

  -- 4. Bags. Selling one only ever makes sense when all four bag slots are
  --    already carrying something at least as roomy — an empty slot means
  --    EQUIP and a roomier bag means SWAP, and neither is a sale.
  if class == M.CLASS_CONTAINER then
    local slots = num(item.container_slots, 0)
    if num(item.container_item_count, 0) > 0 then
      return hold("bag is not empty")
    end
    if bags.count < M.BAG_SLOT_COUNT then
      return hold("free bag slot — equip it")
    end
    local smallest = num(bags.smallest, nil)
    if smallest == nil then return hold("equipped bag sizes unknown") end
    if slots > smallest then
      return hold(string.format("bag upgrade %d>%d", slots, smallest))
    end
    return sell(string.format("spare %d-slot bag (smallest worn %d)",
      slots, smallest))
  end

  -- 5. Armor the class can never wear. This is monofuel's headline case:
  --    a warlock holding mail sells the mail.
  if class == M.CLASS_ARMOR then
    local unusable = M.armor_unusable(class_id, sub)
    if unusable == nil then return hold("no armor proficiency rule") end
    if unusable then return sell("cannot wear armor subclass " .. sub) end
    -- Wearable. Only grey goes, and only when the slot is already covered by
    -- something at least as good.
    if quality ~= M.QUALITY_POOR then return hold("wearable") end
    local key = M.SLOT_KEY[num(item.inventory_type, -1)]
    if not key then return hold("grey armor, slot not comparable") end
    local wornLevel = worn[key]
    if wornLevel == nil then return hold("grey armor, " .. key .. " is empty") end
    local ilvl = num(item.item_level, 0)
    if ilvl > wornLevel then
      return hold(string.format("grey armor, %s upgrade il%d>%d",
        key, ilvl, wornLevel))
    end
    return sell(string.format("grey %s il%d <= worn il%d", key, ilvl, wornLevel))
  end

  -- 6. Weapons the class can never learn. Bounded to grey/white by rule 3,
  --    which is what keeps a wrong row in the proficiency table cheap.
  if class == M.CLASS_WEAPON then
    local unusable = M.weapon_unusable(class_id, sub)
    if unusable == nil then return hold("no weapon proficiency rule") end
    if unusable then return sell("cannot wield weapon subclass " .. sub) end
    return hold("wieldable")
  end

  -- 7. Junk. Class 15 grey is the vendor trash the grind generates by the
  --    bagful (Chipped Claw, Ruined Pelt). Trade goods, reagents, and
  --    consumables are NOT swept up here even when grey — a seat that sells
  --    its own reagents is worse than a seat with a full bag.
  if class == M.CLASS_MISC and quality == M.QUALITY_POOR then
    return sell("grey junk")
  end

  return hold("keep")
end

--- Whole-bag pass. Returns every row tagged, plus the sell shortlist in bag
--- order and the copper it is worth.
-- snapshot = {
--   items = { <Observation inventory rows> },
--   equipment = { <Observation equipment rows> },
--   player = { class_id, level },
-- }
function M.evaluate(snapshot)
  snapshot = snapshot or {}
  local items = snapshot.items or {}
  local player = snapshot.player or {}
  local context = {
    bags = M.equipped_bags(snapshot.equipment),
    worn = M.equipped_by_slot(snapshot.equipment),
  }
  local out = { items = {}, sell = {}, sell_copper = 0 }
  for i = 1, #items do
    local row = items[i] or {}
    local decision = M.decide(row, player, context)
    decision.item_guid = row.item_guid
    decision.item_id = row.item_id
    decision.name = row.name
    decision.count = num(row.count, 1)
    out.items[i] = decision
    if decision.tag == M.SELL then
      out.sell[#out.sell + 1] = decision
      out.sell_copper = out.sell_copper +
        num(row.sell_price, 0) * decision.count
    end
  end
  return out
end

return M
