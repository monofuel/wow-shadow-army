-- Quest materials through the real home.decide. At a merchant the seat
-- already has open, the brain asks for one exact purchase, reads the pilot's
-- answer on the next tick (wow.nav_progress), and never asks again for an
-- item whose issued purchase the bags have not proven. The pilot's answers
-- are scripted here; the fork's proof/lua_bot_vendor_action_check.nim drives
-- the real pilot, its reload-surviving guard and the host lowering with the
-- same intent. All quests, items, units and prices are synthetic.

local logged = {}
local nav_state = "idle"
wow = {
  time = function() return 100 end,
  nav_progress = function() return { state = nav_state } end,
  log = function(line) logged[#logged + 1] = tostring(line) end,
  set_status = function() end,
}

local chat_dir = os.tmpname()
os.remove(chat_dir)
assert(os.execute("mkdir -p '" .. chat_dir .. "/chat'"))
local real_getenv = os.getenv
os.getenv = function(key)
  if key == "VANILLA_WOW_LUA_DEBUG_DIR" then return chat_dir .. "/control" end
  if key == "SHADOW_CHAT_QWEN_OFF" then return nil end
  return real_getenv(key)
end

require("tests.lifecycle_fixture")
local requests = require("tools.requests")
local rs = requests.new(nil)
requests.from_env = function() return rs end
local home = require("home")
home.set_roads({})

local checks = 0
local function check(ok, label)
  assert(ok, label)
  checks = checks + 1
end

local MERCHANT, OTHER, ITEM, QUEST = 4242, 4343, 7001, 900
local results = {}

local function decide(v)
  local r = home.decide(v)
  results[#results + 1] = r
  return r
end

local function bought(r) return r.kind == "buy_item" end
local function material_hold(r)
  return r.kind == "hold" and tostring(r.reason):find("^material_") ~= nil
end

local function logs_matching(needle)
  for i = #logged, 1, -1 do
    if string.find(logged[i], needle, 1, true) then return logged[i] end
  end
  return nil
end

-- A solo seat standing at an open merchant that lists the one missing quest
-- material at a known price.
local function frame(t)
  return {
    simulation_time = t, player_guid = 200, class_id = 9, level = 10,
    location_known = true,
    location = { map_id = 0, position = { x = 0, y = 0, z = 0 } },
    health_known = true, health = 100, max_health = 100,
    powers = { 100, 0, 0, 0, 0 }, max_powers = { 100, 0, 0, 0, 0 },
    active_aura_spell_ids = {}, is_dead = false, is_ghost = false,
    can_reclaim_corpse = false, resurrect_offer_guid = 0, in_combat = false,
    selected_target_guid = 0, auto_attack_guid = 0, active_cast_spell_id = 0,
    active_channel_spell_id = 0,
    party = { in_group = false, members = {} },
    units = {}, spell_facts = {}, action_buttons = {},
    accepted_quests = { { quest_id = QUEST, failed = false } },
    quest_objectives = { { quest_id = QUEST, item_id = ITEM, current = 0,
      required = 2, complete = false } },
    inventory_items = {}, equipment_items = {},
    merchant_open = true, merchant_guid = MERCHANT,
    sell_supported = true, buy_supported = true,
    merchant_offers = { { index = 1, item_id = ITEM, price = 25, stock = -1,
      buy_count = 1, definition_known = true, max_stack_size = 20 } },
    copper_known = true, copper = 100, bag_space_known = true, free_bag_slots = 10,
  }
end

local function carrying(v, n)
  v.inventory_items = { {
    item_guid = 51, item_id = ITEM, name = "Synthetic Thread", count = n,
    definition_known = true, item_class_id = 7, item_subclass_id = 0,
    quality = 1, sell_price = 1, inventory_type = 0, container_slots = 0,
    container_item_count = 0, item_level = 1, max_stack_size = 20,
  } }
  return v
end

local function fresh()
  home.reset()
  rs.active = nil
  nav_state = "idle"
end

-- 1. A host without the verb never sees a purchase.
fresh()
for t = 100, 103, 0.5 do
  local v = frame(t)
  v.buy_supported = nil
  check(not bought(decide(v)), "an old host (buy_supported nil) is never asked to buy")
end

-- 2. One exact purchase, then no retry while unproven, here or elsewhere.
fresh()
local r = decide(frame(100))
check(bought(r) and r.guid == MERCHANT and r.item_id == ITEM and r.count == 2 and
  r.expected_price == 25 and r.reason == "quest_material_buy",
  "the missing count is bought once at the observed price")
check(r.status.mode == "vendor", "a purchase reports vendor mode")
nav_state = "buy_verb_issued"
r = decide(frame(100.1))
check(r.kind == "hold" and r.reason == "material_buy_settle",
  "an issued buy holds the merchant for its bag proof")
nav_state = "held"
check(material_hold(decide(frame(102))), "the hold lasts the settle window")
r = decide(frame(104.3))
check(not bought(r) and not material_hold(r), "no full proof ends the hold")
check(logs_matching("unconfirmed") ~= nil, "the unconfirmed buy is logged")
for t = 105, 800, 5 do
  local v = frame(t)
  if t % 10 == 0 then v.merchant_guid = OTHER end
  check(not bought(decide(v)),
    "an issued, unproven buy is never repeated at this or another merchant")
end

-- 3. The late reply proves it; a need that comes straight back is not rebought.
r = decide(carrying(frame(801), 2))
check(not bought(r) and logs_matching("late bag proof for item 7001") ~= nil,
  "a late delivery is recognised from the bags")
check(not bought(decide(carrying(frame(802), 0))),
  "a need that reappears right after a purchase does not buy straight back")
check(bought(decide(frame(1403))), "the same need may buy again after the window")

-- 4. Deferred queued nothing, so the same ask goes again; issued never does.
fresh()
check(bought(decide(frame(100))), "deferral case: first ask")
nav_state = "buy_verb_deferred"
r = decide(frame(100.1))
check(bought(r) and r.count == 2 and r.expected_price == 25,
  "a deferred ask is sent again unchanged")
nav_state = "buy_verb_issued"
check(material_hold(decide(frame(100.2))), "the re-sent ask was issued")
nav_state = "held"
for t = 100.3, 104, 0.3 do
  check(not bought(decide(frame(t))), "an issued ask is never re-sent")
end

-- 5. Closing the window or switching merchant mid-proof blocks the item.
fresh()
decide(frame(100))
nav_state = "buy_verb_issued"
decide(frame(100.1))
nav_state = "held"
local closed = frame(101)
closed.merchant_open = false
closed.merchant_offers = {}
check(not bought(decide(closed)), "a closed window mid-proof buys nothing")
check(logs_matching("merchant window closed or changed") ~= nil,
  "the interrupted proof is logged")
check(not bought(decide(frame(102))), "reopening the merchant does not re-buy")
local other = frame(103)
other.merchant_guid = OTHER
check(not bought(decide(other)), "another merchant does not re-buy")

-- 6. A partial delivery is not a purchase and cannot trigger another buy.
fresh()
decide(frame(100))
nav_state = "buy_verb_issued"
decide(frame(100.1))
nav_state = "held"
check(material_hold(decide(carrying(frame(101), 1))),
  "one of two delivered keeps waiting for the full count")
check(not bought(decide(carrying(frame(104.3), 1))), "a partial delivery times out unproven")
for t = 105, 700, 5 do
  check(not bought(decide(carrying(frame(t), 1))),
    "the missing remainder is not bought over a partial delivery")
end

-- 7. A hot reload wipes the brain; the pilot's guard refuses its fresh ask
-- and the reloaded brain then stops asking.
fresh()
decide(frame(100))
nav_state = "buy_verb_issued"
decide(frame(100.1))
package.loaded["home"] = nil
home = require("home")
home.set_roads({})
nav_state = "held"
check(bought(decide(frame(101))), "a reloaded brain re-plans the same need once")
nav_state = "buy_verb_refused"
check(not bought(decide(frame(101.1))), "the pilot's refusal is read back")
check(logs_matching("refused by the pilot") ~= nil, "the refusal is logged")
nav_state = "held"
for t = 102, 700, 5 do
  check(not bought(decide(frame(t))), "the reloaded brain does not keep asking")
end

-- 8. Everything that outranks a purchase still does.
fresh()
local fight = frame(100)
fight.in_combat = true
r = decide(fight)
check(not bought(r) and not material_hold(r), "a fight outranks a purchase")
local dead = frame(100)
dead.is_dead = true
r = decide(dead)
check(not bought(r) and not material_hold(r), "death outranks a purchase")
rs.active = { key = "k1", choice = "follow_me" }
r = decide(frame(100))
check(not bought(r) and not material_hold(r), "an owner request outranks a purchase")
rs.active = { key = "k2", choice = "do_quests" }
check(bought(decide(frame(100))), "an owner quest request may buy its materials")
fresh()
local escort = frame(100)
escort.party = { in_group = true, leader_guid = 100, members = {
  { guid = 200, name = "Shadowfel" }, { guid = 100, name = "Murist", leader = true } } }
r = decide(escort)
check(not bought(r) and not material_hold(r), "the escort's follow outranks a purchase")

local outbox = assert(io.open(chat_dir .. "/chat/outbox.json", "w"))
outbox:write('{"protocol":"wow_shadow_army.bot_chat.v1","seat":"Shadowfel",' ..
  '"channel":"party","text":"stand ready","id":1}')
outbox:close()
fresh()
local talk = frame(300)
talk.merchant_open = false
talk.chat_send_supported = true
talk.party = escort.party
talk.units = { {
  guid = 100, name = "Murist", is_player_controlled = true, player_can_attack = false,
  death_known = true, is_dead = false, combat_known = true, is_in_combat = false,
  target_guid_known = false, target_guid = 0,
  location = { map_id = 0, position = { x = 3, y = 0, z = 0 } }, distance = 3,
} }
talk.party.members[1] = { guid = 200, name = "Shadowfel", health_known = true,
  health = 100, max_health = 100, location_known = true,
  location = { map_id = 0, x = 0, y = 0, z = 0 } }
talk.party.members[2] = { guid = 100, name = "Murist", leader = true,
  health_known = true, health = 100, max_health = 100, location_known = true,
  location = { map_id = 0, x = 3, y = 0, z = 0 } }
r = decide(talk)
check(r.kind == "chat", "a party line is queued from formation")
r = decide(frame(300.2))
check(not bought(r) and not material_hold(r), "a line being typed outranks a purchase")

-- 9. Bundles round up to the minimum legal purchase; price 0 is a price.
fresh()
local bundle = frame(100)
bundle.quest_objectives[1].required = 3
bundle.merchant_offers[1].buy_count = 5
r = decide(bundle)
check(bought(r) and r.count == 1, "3 missing from a 5-item bundle buys one bundle")
fresh()
local free = frame(100)
free.merchant_offers[1].price = 0
free.copper = 0
r = decide(free)
check(bought(r) and r.expected_price == 0, "a listed price of 0 with known 0 copper buys")
fresh()
local unknown = frame(100)
unknown.copper_known = false
check(not bought(decide(unknown)), "unknown funds buy nothing")

-- 10. A bought ordinary weapon required by a quest must survive the earlier
-- sale step. The fixture's previous class-7 material could never expose this.
fresh()
check(bought(decide(frame(1500))), "quest weapon: ask once")
nav_state = "buy_verb_issued"
decide(frame(1500.1))
nav_state = "held"
local function objective_weapon(t)
  local v = carrying(frame(t), 2)
  v.inventory_items[1].item_class_id = 2
  v.inventory_items[1].item_subclass_id = 1
  v.inventory_items[1].sell_price = 5
  return v
end
local delivered = objective_weapon(1501)
delivered.inventory_items[2] = {
  item_guid = 61, item_id = 9999, name = "Synthetic junk", count = 1,
  definition_known = true, item_class_id = 15, quality = 0, sell_price = 2,
}
r = decide(delivered)
check(r.kind == "sell_item" and r.item_guid == 61,
  "after purchase only unrelated junk is sold, never the required weapon")
r = decide(objective_weapon(1502))
check(r.kind ~= "sell_item" and logs_matching("bought item 7001") ~= nil,
  "the full required weapon count is recognised after the junk sale")
local complete = objective_weapon(1503)
complete.quest_objectives[1].current = 2
complete.quest_objectives[1].complete = true
check(decide(complete).kind ~= "sell_item",
  "satisfied objective weapons remain protected until turn-in")
local gone = objective_weapon(1504)
gone.accepted_quests = {}
r = decide(gone)
check(r.kind == "sell_item" and r.item_guid == 51,
  "once the quest leaves the log the ordinary weapon may be sold")

-- 11. There is no vendor search in this step.
for _, result in ipairs(results) do
  check(result.reason ~= "quest_material_browse", "no browse intent is ever emitted")
end

os.execute("rm -rf '" .. chat_dir .. "'")
