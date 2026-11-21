-- Synthetic controls for the pure planner in tools/quest_material.lua.
local m = require("tools.quest_material")

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; print("FAIL " .. msg) end
end

local function base()
  return {
    accepted_quests = { { quest_id = 900, failed = false } },
    quest_objectives = {
      { quest_id = 900, item_id = 11, current = 5, required = 5, complete = true },
      { quest_id = 900, item_id = 22, current = 0, required = 1, complete = false },
    },
    inventory_items = { { item_id = 11, count = 5, max_stack_size = 10 } },
    merchant_open = true, merchant_guid = 77,
    merchant_offers = { { index = 1, item_id = 22, price = 40, stock = -1,
      buy_count = 1, max_stack_size = 20 } },
    copper_known = true, copper = 100, bag_space_known = true, free_bag_slots = 2,
  }
end

-- Exact missing quantity: only the incomplete item objective, one item.
local v = base()
local needs = m.needs(v)
check(#needs == 1 and needs[1].item_id == 22 and needs[1].missing == 1, "exact need")
local plan, why = m.plan(v, needs[1])
check(plan and plan.bundles == 1 and plan.items == 1 and plan.cost == 40, "positive plan " .. tostring(why))

-- Carried items count even when the objective counter lags.
v = base(); v.inventory_items[2] = { item_id = 22, count = 1, max_stack_size = 20 }
check(#m.needs(v) == 0, "carried satisfies need")

-- Quest already complete / failed / not accepted.
v = base(); v.quest_objectives[2].complete = true
check(#m.needs(v) == 0, "complete objective")
v = base(); v.accepted_quests[1].failed = true
check(#m.needs(v) == 0, "failed quest")
v = base(); v.accepted_quests = {}
check(#m.needs(v) == 0, "unaccepted quest")

-- Funds.
v = base(); v.copper = 39
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "insufficient_funds", "funds")
v = base(); v.copper_known = false
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "funds_unknown", "funds unknown")

-- Bags: full with no stack room vs stack room in an existing partial stack.
v = base(); v.free_bag_slots = 0
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "bags_full", "bags full")
v = base(); v.free_bag_slots = 0
v.quest_objectives[2].required = 3
v.inventory_items[2] = { item_id = 22, count = 1, max_stack_size = 20 }
plan, why = m.plan(v, m.needs(v)[1]); check(plan and plan.items == 2, "stack room " .. tostring(why))

-- Sold out / limited stock / not listed / merchant closed / price unknown.
v = base(); v.merchant_offers[1].stock = 0
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "sold_out", "sold out")
v = base(); v.merchant_offers[1].item_id = 23
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "not_listed", "not listed")
v = base(); v.merchant_open = false
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "not_listed", "closed merchant")
v = base(); v.merchant_offers[1].price = nil
plan, why = m.plan(v, m.needs(v)[1]); check(not plan and why == "price_unknown", "price unknown")

-- Bundled rows round up to the fewest bundles, priced per bundle.
v = base(); v.quest_objectives[2].required = 6; v.merchant_offers[1].buy_count = 5
plan = m.plan(v, m.needs(v)[1]); check(plan and plan.bundles == 2 and plan.items == 10 and plan.cost == 80, "bundles")

-- Partial fill reconciles: one of three carried -> plan only the remainder.
v = base(); v.quest_objectives[2].required = 3
v.inventory_items[2] = { item_id = 22, count = 1, max_stack_size = 20 }
plan = m.plan(v, m.needs(v)[1]); check(plan and plan.items == 2, "partial reconcile")

if fails > 0 then os.exit(1) end
