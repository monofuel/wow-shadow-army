-- Original synthetic repair travel facts: a catalogued anchor out of view,
-- then the same observed provider, quote and payment checks as test_repair.
-- These fixtures never repair a realm.
local host = { nav = "idle" }
_G.wow = { log = function() end, time = function() return 0 end,
  set_status = function() end,
  nav_progress = function() return { state = host.nav } end }
require("tests.lifecycle_fixture")
local life = require("tools.lifecycle")
local requests = require("tools.requests")
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end

local ANCHOR = { map_id = 0, x = 200, y = 0, z = 5 }
local function view(x, extra)
  local v = { repair_supported = true, repair_quote_supported = true,
    repair_destination_supported = true,
    repair_destination = { hub_id = "town", source = "service_hub_catalog", point = ANCHOR },
    equipped_durability_known = true, copper_known = true, copper = 20,
    location_known = true,
    location = { map_id = 0, position = { x = x or 0, y = 0, z = 0 } },
    units = {},
    equipment_items = { { item_guid = 11, durability_known = true,
      max_durability_known = true, durability = 0, max_durability = 20 } } }
  for k, value in pairs(extra or {}) do v[k] = value end
  return v
end
local function repairer(x, extra)
  local u = { guid = 9001, services = { "vendor", "repair" }, distance = 200 - x,
    health_known = true, health = 50,
    location = { map_id = 0, position = { x = 200, y = 0, z = 0 } } }
  for k, value in pairs(extra or {}) do u[k] = value end
  return u
end
local function seen(x, extra) local v = view(x); v.units = { repairer(x, extra) }; return v end
local function opened(x, cost)
  local v = seen(x)
  v.merchant_open, v.merchant_guid, v.merchant_can_repair = true, 9001, true
  v.repair_all_cost_known, v.repair_all_cost = cost ~= nil, cost or 0
  return v
end
local function fixed(x, copper)
  local v = opened(x, 7); v.copper = copper
  v.equipment_items[1].durability = 20
  return v
end

check(type(life.repair_route) == "function", "the draft lifecycle module is the one under test")

-- Out of view, a catalogued anchor: an ordinary ground walk, never a payment.
local st = life.new_state()
check(life.repair_route(view(0)) == "catalogued", "catalogued route is reported for the menu")
local go = life.repair_step(view(0), st, 0, false)
check(go.kind == "navigate" and go.x == 200 and go.y == 0 and go.map_id == 0 and
  go.route_profile == "prefer_ground" and go.reason == "repair_destination",
  "out-of-view repair walks to the catalogued anchor on the ground")
check(st.repair_visit == nil, "a catalogued walk is not a visit or a submission")
go = life.repair_step(view(60), st, 10, false)
check(go.kind == "navigate", "the walk continues while it moves")
-- The provider comes into view: the existing visible path takes over.
go = life.repair_step(seen(120), st, 20, false)
check(go.kind == "interact" and go.guid == 9001 and st.repair_travel == nil,
  "an observed living friendly provider replaces the hint")
go = life.repair_step(opened(195, 7), st, 30, false)
check(go.kind == "repair_all" and go.guid == 9001, "repair only at the exact open provider")
local _, outcome = life.repair_step(fixed(195, 13), st, 32, false)
check(outcome.result == "complete" and outcome.paid == 7, "durability and payment confirm the repair")

-- A visible same-map friendly provider wins over the catalogue.
st = life.new_state()
local near = view(0); near.units = { repairer(0, { guid = 9100, distance = 30,
  location = { map_id = 0, position = { x = 30, y = 0, z = 0 } } }) }
check(life.repair_route(near) == "visible", "visible provider is the reported route")
go = life.repair_step(near, st, 0, false)
check(go.kind == "interact" and go.guid == 9100, "the visible provider wins")

-- Hostile, dead or wrong-map providers and missing hints stay blocked.
local function blocked(v, why, label)
  local s = life.new_state()
  local intent, out = life.repair_step(v, s, 0, false)
  check(intent == nil and out and out.result == "blocked" and out.why == why, label)
  check(life.repair_step(v, s, 10, false) == nil, label .. " (retry is gated)")
end
local function no_hint(v) v.repair_destination = nil; return v end
blocked(no_hint(seen(0, { player_reaction_hostile = true })),
  "observed repair provider is hostile", "a hostile repairer is refused")
blocked(no_hint(seen(0, { health = 0 })), "observed repair provider is dead",
  "a dead repairer is refused")
blocked(no_hint(seen(0, { location = { map_id = 1, position = { x = 200, y = 0, z = 0 } } })),
  "observed repair provider is on another map", "a wrong-map repairer is refused")
blocked(no_hint(view(0)), "no observed or catalogued repair provider", "no hint stays blocked")
local far = view(0); far.repair_destination = { hub_id = "far", point = { map_id = 1, x = 1, y = 1, z = 0 } }
blocked(far, "catalogued repair destination is on another map", "a wrong-map anchor is not walked")
local old = view(0); old.repair_destination_supported = nil
blocked(old, "host has no repair destination catalog", "an older host stays visible-only")
check(life.repair_route(no_hint(view(0))) == nil, "no route is offered without a provider or hint")

-- Arrival without a usable provider ends the walk with what was seen.
st = life.new_state()
life.repair_step(view(0), st, 0, false)
go = life.repair_step(view(195), st, 20, false)
check(go.kind == "hold" and go.reason == "repair_provider_search", "arrival looks around briefly")
_, outcome = life.repair_step(view(195), st, 31, false)
check(outcome.result == "blocked" and
  outcome.why == "no repair provider observed at the catalogued destination",
  "an empty anchor is a bounded blocker")
st = life.new_state()
life.repair_step(view(0), st, 0, false)
local hostile_there = seen(195, { player_reaction_hostile = true })
check(life.repair_step(hostile_there, st, 20, false).kind == "hold", "a hostile repairer is not approached")
_, outcome = life.repair_step(hostile_there, st, 31, false)
check(outcome.result == "blocked" and outcome.why == "observed repair provider is hostile",
  "the obstacle names the hostile repairer")

-- No movement while driven is a stall; a fight between driven frames is not.
st = life.new_state()
life.repair_step(view(0), st, 0, false)
check(life.repair_step(view(0), st, 1, false).kind == "navigate", "standing briefly is fine")
check(life.repair_step(view(0, { in_combat = true }), st, 20, false) == nil, "combat is not interrupted")
check(life.repair_step(view(0), st, 80, false).kind == "navigate",
  "time spent fighting does not count as a stall")
local stall_at = 80
repeat
  stall_at = stall_at + 1
  go, outcome = life.repair_step(view(0), st, stall_at, false)
until go == nil
check(outcome.result == "blocked" and stall_at > 108 and stall_at <= 111 and
  outcome.why == "no movement toward the catalogued repair destination",
  "a real stall while driven is bounded")
st = life.new_state()
local x, t = 0, 0
repeat
  go, outcome = life.repair_step(view(x), st, t, false)
  x = (x == 0) and 10 or 0
  t = t + 1
until go == nil
check(outcome.result == "blocked" and outcome.why == "catalogued repair destination not reached in time" and
  t > 240 and t < 243, "moving without arriving ends at the total travel bound")
-- The nearest anchor flipping between hubs mid-walk keeps the walk's clocks.
st = life.new_state()
x, t = 0, 0
repeat
  local v = view(x)
  v.repair_destination.hub_id = (math.floor(t / 10) % 2 == 0) and "a" or "b"
  go, outcome = life.repair_step(v, st, t, false)
  x = (x == 0) and 10 or 0
  t = t + 1
until go == nil or t > 400
check(go == nil and outcome.result == "blocked" and outcome.why == "catalogued repair destination not reached in time" and
  t > 240 and t < 243, "alternating anchors do not restart the total travel bound")

-- Unknown quote and insufficient funds after the walk keep the visible rules.
st = life.new_state()
life.repair_step(view(0), st, 0, false)
life.repair_step(seen(150), st, 20, false)
check(life.repair_step(opened(195, nil), st, 30, false).kind == "hold", "an unknown quote is never free")
_, outcome = life.repair_step(opened(195, nil), st, 41, false)
check(outcome.result == "blocked" and outcome.why == "repair price or funds unobserved",
  "the quote wait after the walk is bounded")
st = life.new_state()
life.repair_step(view(0), st, 0, false)
life.repair_step(seen(150), st, 20, false)
_, outcome = life.repair_step(opened(195, 50), st, 30, false)
check(outcome.result == "blocked" and outcome.why == "not enough money for the observed repair quote",
  "an unaffordable quote is not paid")
-- No effect after the walk is not success.
st = life.new_state()
life.repair_step(view(0), st, 0, false)
life.repair_step(seen(150), st, 20, false)
life.repair_step(opened(195, 7), st, 30, false)
_, outcome = life.repair_step(opened(195, 7), st, 37, false)
check(outcome.result == "incomplete", "a submitted repair with no effect is incomplete")

-- A duplicate request restarts an unsent walk; a submitted repair is never resent.
st = life.new_state()
life.repair_step(view(0), st, 0, false)
life.repair_step(view(80), st, 100, false)
life.request_repair(st, 150)
check(st.repair_travel == nil, "a repeated request does not inherit the old walk")
check(life.repair_step(view(80), st, 150, false).kind == "navigate" and st.repair_travel.since == 150,
  "the new request walks with its own bounds")
st = life.new_state()
life.repair_step(opened(195, 7), st, 1, false)
life.request_repair(st, 3)
check(life.repair_step(opened(195, 7), st, 3, false).kind == "hold", "a settling repair is adopted, not resent")

-- Reconnect: a frame without a position holds a walk in progress; a fresh
-- state after a restart finds the earlier repair already paid for.
st = life.new_state()
life.repair_step(view(0), st, 0, false)
local lost = view(40); lost.location_known = false
check(life.repair_step(lost, st, 5, false).kind == "hold", "a walk survives a position gap")
check(life.repair_step(view(50), st, 8, false).kind == "navigate", "the walk resumes after reconnect")
st = life.new_state()
local whole = view(50); whole.equipment_items[1].durability = 20
go, outcome = life.repair_step(whole, st, 0, false)
check(go == nil and outcome.result == "complete" and outcome.paid == 0,
  "a restarted seat with repaired gear pays nothing")
check(life.repair_status(view(0), life.new_state()).route == "catalogued",
  "status publishes the catalogued route")

-- The owner's request: the same lifecycle, a deadline that covers the walk.
local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p " .. dir))
local function write_job(key, choice)
  local f = assert(io.open(dir .. "/inbox.json", "w"))
  f:write('{"protocol":"wow_shadow_army.private_request.v1","key":"' .. key ..
    '","origin":"operator","actor":"operator","intent":"action","choice":"' .. choice .. '"}')
  f:close()
end
local function receipts()
  local f = assert(io.open(dir .. "/receipts.jsonl")); local body = f:read("*a"); f:close()
  return body
end
st = life.new_state()
local rs = requests.new(dir)
local ctx = { life = life, lstate = st, fighting = false }
write_job("walk1", "repair_gear")
go = requests.step(view(0), rs, 0, ctx)
check(go.kind == "navigate" and go.reason == "repair_destination", "a repair request walks to the anchor")
for i = 1, 13 do go = requests.step(view(i * 10), rs, i * 10, ctx) end
check(go.kind == "navigate" and not receipts():find('"state":"failed"', 1, true),
  "a moving walk past the old 120s bound is still the request's work")
check(requests.step(seen(150), rs, 140, ctx).kind == "interact", "request reaches the observed provider")
check(requests.step(opened(195, 7), rs, 150, ctx).kind == "repair_all", "request issues one ordinary repair")
requests.step(fixed(195, 13), rs, 152, ctx)
check(receipts():find('"key":"walk1","choice":"repair_gear","origin":"operator","actor":"operator","state":"done"', 1, true) and
  receipts():find('"paid":"7"', 1, true), "done only with changed items and payment")
write_job("walk2", "repair_gear")
local empty = no_hint(view(0))
requests.step(empty, rs, 400, ctx)
check(receipts():find('"key":"walk2","choice":"repair_gear","origin":"operator","actor":"operator","state":"failed"', 1, true) and
  receipts():find("no observed or catalogued repair provider", 1, true),
  "a request without a provider or hint fails with its obstacle")
os.execute("rm -rf " .. dir)

-- Home policy: broken gear is repaired before solo leveling legs, never as a
-- detour from Murist's party.
local home = require("home")
home.set_roads({})
local function home_frame(grouped)
  local v = view(0, { simulation_time = 100, player_guid = 200, class_id = 1, level = 11,
    health_known = true, health = 100, max_health = 100,
    powers = { 0, 0, 0, 0, 0 }, max_powers = { 0, 0, 0, 0, 0 }, active_aura_spell_ids = {},
    is_dead = false, is_ghost = false, in_combat = false, selected_target_guid = 0,
    auto_attack_guid = 0, active_cast_spell_id = 0, active_channel_spell_id = 0,
    spell_facts = {}, action_buttons = {}, quest_objectives = {},
    party = { in_group = false, members = {} } })
  if grouped then
    local me = { guid = 200, name = "Tusk", location = { map_id = 0, x = 0, y = 0, z = 0 } }
    local murist = { guid = 100, name = "Murist", leader = true, location_known = true,
      location = { map_id = 0, x = 3, y = 0, z = 0 } }
    v.party = { in_group = true, leader_guid = 100, leader_name = "Murist",
      invite_pending = false, invite_from = "", members = { me, murist } }
    v.units = { { guid = 100, name = "Murist", is_player_controlled = true,
      player_can_attack = false, death_known = true, is_dead = false,
      location = { map_id = 0, position = { x = 3, y = 0, z = 0 } }, distance = 3 } }
  end
  return v
end
home.reset()
local r = home.decide(home_frame(false))
check(r.kind == "navigate" and r.reason == "repair_destination" and r.status.mode == "solo",
  "a solo seat with broken gear walks to repair before leveling")
check(r.status.repair.route == "catalogued" and r.status.repair.travelling,
  "the seat status carries the route the broker offers from")
home.reset()
r = home.decide(home_frame(true))
check(r.reason ~= "repair_destination" and r.status.mode ~= "solo",
  "an escort in Murist's party is not detoured to repair")

-- Full bags (R4): keep-only rows leave the repair walk alone; a grey sellable
-- with a vendor in view takes the existing vendor leg first.
local function full_bags(v)
  v.sell_supported, v.bag_space_known, v.free_bag_slots = true, true, 0
  v.inventory_items = {
    { item_guid = 31, item_id = 9001, name = "Synthetic Writ", count = 1,
      definition_known = true, item_class_id = 12, item_subclass_id = 0,
      quality = 1, sell_price = 0, inventory_type = 0 } }
  return v
end
home.reset()
r = home.decide(full_bags(home_frame(false)))
check(r.kind == "navigate" and r.reason == "repair_destination",
  "full bags of quest items still walk to repair")
home.reset()
local junk = full_bags(home_frame(false))
junk.inventory_items[2] = { item_guid = 32, item_id = 9002, name = "Synthetic Scrap",
  count = 1, definition_known = true, item_class_id = 15, item_subclass_id = 0,
  quality = 0, sell_price = 5, inventory_type = 0 }
junk.units = { { guid = 2200, name = "Synthetic Trader", object_kind = "unit",
  services = { "vendor" }, distance = 40, death_known = true, is_dead = false,
  player_can_attack = false, location = { map_id = 0, position = { x = 40, y = 0, z = 0 } } } }
r = home.decide(junk)
check(r.status.mode == "vendor" and r.reason ~= "repair_destination",
  "a sellable grey with a vendor in view sells before the repair walk")

-- A known broken main hand (R3): the tank starts no fresh pull out of combat;
-- a fight, a turn-in and a healer are unchanged.
local function broken_tank(class_id, extra)
  local v = no_hint(home_frame(false))
  v.class_id = class_id
  v.equipment_items[1].main_hand = true
  v.units = { { guid = 300, name = "Synthetic Hound", player_can_attack = true, level = 10,
    death_known = true, is_dead = false, health_known = true, health = 100, max_health = 100,
    target_guid_known = true, target_guid = 0, active_aura_spell_ids = {}, distance = 4,
    combat_distance_known = true, combat_distance = 4,
    location = { map_id = 0, position = { x = 4, y = 0, z = 0 } } } }
  for k, value in pairs(extra or {}) do v[k] = value end
  return v
end
home.reset()
r = home.decide(broken_tank(1))
check(r.kind == "hold" and r.reason == "broken_weapon_no_fresh_pull" and
  r.status.repair.obstacle == "no observed or catalogued repair provider",
  "a broken-weapon tank holds instead of pulling and reports the repair obstacle")
home.reset()
r = home.decide(broken_tank(1, { in_combat = true }))
check(r.kind == "attack", "a broken-weapon tank still answers a fight")
home.reset()
local giver = broken_tank(1, { completed_quest_ids = { 100 },
  accepted_quests = { { quest_id = 100, title = "Synthetic Errand" } },
  quest_markers = { { questgiver_guid = 900, status = 7 } } })
giver.units[2] = { guid = 900, name = "Synthetic Giver", object_kind = "unit",
  services = { "questgiver" }, player_can_attack_known = true, player_can_attack = false,
  death_known = true, is_dead = false, distance = 6,
  location = { map_id = 0, position = { x = -6, y = 0, z = 0 } } }
r = home.decide(giver)
check(r.kind == "interact" and r.guid == 900, "a broken-weapon tank still turns in a quest")
home.reset()
r = home.decide(broken_tank(5))
check(r.kind == "attack", "a healer with a broken main hand is unchanged")

-- A known road that is only worth it to a broken tank: one original synthetic
-- polyline bowing north of the seat-to-anchor line. At the router's default
-- off-road penalty the crow line is cheaper; at double it the road wins, and
-- its first point is closer to the anchor than the seat.
local road_route = require("tools.road_route")
local BOW = { [0] = { { 30, 20, 0, 100, 110, 0, 170, 20, 0 } } }
local bow = road_route.build(BOW[0])
local _, plain = road_route.route(bow, { x = 0, y = 0 }, ANCHOR)
local _, wary = road_route.route(bow, { x = 0, y = 0 }, ANCHOR,
  { penalty = 2 * road_route.offRoadPenalty })
check(plain.reason == "straight-cheaper" and wary.reason == "road",
  "the synthetic road is a crow line by default and a road at double penalty")
local function at_anchor(r)
  return r.kind == "navigate" and r.reason == "repair_destination" and
    r.x == ANCHOR.x and r.y == ANCHOR.y
end
local function main_hand(v, durability)
  v.equipment_items[2] = { item_guid = 12, main_hand = true, durability_known = true,
    max_durability_known = true, durability = durability, max_durability = 20 }
  return v
end
home.set_roads(BOW)
home.reset()
r = home.decide(main_hand(home_frame(false), 10))
check(at_anchor(r), "a tank with a worn but whole main hand keeps the default crow line")
local caster = main_hand(home_frame(false), 0); caster.class_id = 5
home.reset()
check(at_anchor(home.decide(caster)), "a spellcaster with a broken main hand keeps the default crow line")
local escort = main_hand(home_frame(true), 0)
escort.party.members[2].location = { map_id = 0, x = 200, y = 0, z = 0 }
escort.units[1].location.position.x, escort.units[1].distance = 200, 200
home.reset()
r = home.decide(escort)
check(r.kind == "navigate" and r.x == 200 and r.y == 0 and not tostring(r.reason):find("_road$"),
  "a broken tank following Murist keeps the default crow line")
home.set_roads({})
home.reset()
check(at_anchor(home.decide(main_hand(home_frame(false), 0))),
  "with no road data a broken tank still walks honestly at the anchor")
home.set_roads(BOW)
home.reset()
r = home.decide(main_hand(home_frame(false), 0))
check(r.kind == "navigate" and r.reason == "repair_destination_road" and
  r.x == 30 and r.y == 20 and r.status.repair.travelling,
  "a broken tank takes the known road toward the repairer")
home.set_roads({})
print("test_repair_route: " .. checks .. " checks passed")
