-- A catalogued repair walk's road-or-crow choice over TIME, through
-- home.decide and the owner's repair request. One original synthetic road
-- runs 80 yd north of the seat-to-anchor line; at the router's default
-- off-road penalty it never pays, at double it pays only north of about
-- y = 15. A seat pacing a few yards across that line must keep ONE goal:
-- the road it chose, until it really stands at each handhold, or the crow
-- line it chose, until the walk itself ends. No realm, point or graph here
-- is real.

local checks = 0
local function check(ok, why)
  if not ok then io.stderr:write("FAIL: " .. why .. "\n"); os.exit(1) end
  checks = checks + 1
end

_G.wow = { log = function() end, time = function() return 0 end,
  set_status = function() end,
  nav_progress = function() return { state = "following" } end }
require("tests.lifecycle_fixture")
local requests = require("tools.requests")
local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p " .. dir))
local rs = requests.new(dir)
requests.from_env = function() return rs end
local home = require("home")

local ANCHOR = { map_id = 0, x = 200, y = 0, z = 0 }
local NORTH = {}
for x = 20, 180, 20 do NORTH[#NORTH + 1] = x; NORTH[#NORTH + 1] = 80; NORTH[#NORTH + 1] = 0 end
local ROADS = { [0] = { NORTH } }

local function frame(x, y, t, extra)
  local v = { repair_supported = true, repair_quote_supported = true,
    repair_destination_supported = true,
    repair_destination = { hub_id = "town", source = "service_hub_catalog", point = ANCHOR },
    equipped_durability_known = true, copper_known = true, copper = 20,
    location_known = true, location = { map_id = 0, position = { x = x, y = y, z = 0 } },
    units = {}, simulation_time = t, player_guid = 200, class_id = 1, level = 11,
    health_known = true, health = 100, max_health = 100,
    powers = { 0, 0, 0, 0, 0 }, max_powers = { 0, 0, 0, 0, 0 }, active_aura_spell_ids = {},
    is_dead = false, is_ghost = false, in_combat = false, selected_target_guid = 0,
    auto_attack_guid = 0, active_cast_spell_id = 0, active_channel_spell_id = 0,
    spell_facts = {}, action_buttons = {}, quest_objectives = {},
    party = { in_group = false, members = {} },
    equipment_items = { { item_guid = 12, main_hand = true, durability_known = true,
      max_durability_known = true, durability = 0, max_durability = 20 } } }
  for k, value in pairs(extra or {}) do v[k] = value end
  return v
end
local n, t = 0, 100
-- The seat polls its inbox once a second; a fresh request starts on the next
-- decide after the poll interval.
local function ask(choice)
  n, t = n + 1, t + 1
  local f = assert(io.open(dir .. "/inbox.json", "w"))
  f:write('{"protocol":"wow_shadow_army.private_request.v1","key":"walk' .. n ..
    '","origin":"operator","actor":"operator","intent":"action","choice":"' ..
    (choice or "repair_gear") .. '"}')
  f:close()
end
local function receipts()
  local f = io.open(dir .. "/receipts.jsonl"); if not f then return "" end
  local body = f:read("*a"); f:close(); return body
end
local function goal(r)
  if r.kind ~= "navigate" then return r.kind .. ":" .. tostring(r.reason) end
  return string.format("%s@%g,%g", r.reason, r.x, r.y)
end
local ROAD1, CROW = "repair_destination_road@20,80", "repair_destination@200,0"
-- Drive a pose script; return the goals and how often the goal changed.
local function walk(poses, extra)
  local seen, flips, last = {}, 0, nil
  for _, p in ipairs(poses) do
    local r = home.decide(frame(p[1], p[2], t, extra))
    t = t + 0.5
    local g = goal(r)
    if last and g ~= last then flips = flips + 1 end
    seen[#seen + 1], last = g, g
  end
  return seen, flips, last
end
local function pace(a, b, count)
  local poses = {}
  for i = 1, count do poses[i] = (i % 2 == 1) and a or b end
  return poses
end

-- 1. The synthetic geometry really straddles the router's own boundary.
local road_route = require("tools.road_route")
local graph = road_route.build(ROADS[0])
local wary = { penalty = 2 * road_route.offRoadPenalty }
local _, s18 = road_route.route(graph, { x = 0, y = 18 }, ANCHOR, wary)
local _, s12 = road_route.route(graph, { x = 0, y = 12 }, ANCHOR, wary)
local _, d18 = road_route.route(graph, { x = 0, y = 18 }, ANCHOR)
check(s18.reason == "road" and s12.reason == "straight-cheaper" and
  d18.reason == "straight-cheaper",
  "6 yd of pacing crosses the doubled-penalty road boundary; the default never takes it")

-- 2. An escort is not a repair walk: grouped with a far Murist and no
-- request, the broken tank follows him exactly as before.
home.set_roads(ROADS); home.reset()
local escort = frame(0, 18, t)
escort.party = { in_group = true, leader_guid = 100, leader_name = "Murist", invite_pending = false,
  invite_from = "", members = {
    { guid = 200, name = "Tusk", location = { map_id = 0, x = 0, y = 18, z = 0 } },
    { guid = 100, name = "Murist", leader = true, location_known = true,
      location = { map_id = 0, x = 200, y = 0, z = 0 } } } }
escort.units = { { guid = 100, name = "Murist", is_player_controlled = true,
  player_can_attack = false, death_known = true, is_dead = false,
  location = { map_id = 0, position = { x = 200, y = 0, z = 0 } }, distance = 200 } }
local r = home.decide(escort)
check(r.kind == "navigate" and r.x == 200 and r.y == 0 and not tostring(r.reason):find("repair"),
  "a broken tank following Murist is not routed by the repair journey")

-- 3. The counterexample: a broken tank on an owner's repair request paces
-- between the two sides. Re-asking every frame turns that into a goal that
-- flips between the road and the anchor; the journey keeps the first plan.
home.reset()
ask()
local seen, flips, last = walk(pace({ 0, 18 }, { 0, 12 }, 20))
check(seen[1] == ROAD1, "the first plan from the road side takes the known road")
check(flips == 0 and last == ROAD1,
  "pacing across the cost boundary keeps the chosen road leg (" .. flips .. " goal changes)")

-- 4. True arrival advances the journey in order; a step back never re-targets
-- a reached handhold, and the anchor leg is final. Arrival is the pilot's own
-- stop distance: half a yard outside it is still on the way.
seen = walk({ { 6, 40 }, { 20, 69.5 }, { 20, 70 } })
check(seen[1] == ROAD1, "closing on a handhold is not arriving at it")
check(seen[2] == ROAD1, "just outside the stop distance the handhold stays the goal")
check(seen[3] == "repair_destination_road@60,80", "at the stop distance the journey advances one lookahead along the road")
seen = walk({ { 0, 18 }, { 0, 12 } })
check(seen[1] == "repair_destination_road@60,80" and seen[2] == seen[1],
  "pushed back off the road, the seat heads for the unreached leg, not a reached one")
seen = walk({ { 52, 78 }, { 96, 79 }, { 136, 80 } })
check(seen[1] == "repair_destination_road@100,80" and seen[2] == "repair_destination_road@140,80" and
  seen[3] == "repair_destination_road@180,80", "the road is walked handhold by handhold")
seen, flips = walk({ { 176, 78 }, { 170, 82 }, { 150, 85 } })
check(seen[1] == CROW and flips == 0,
  "the last handhold hands over to the anchor and the road is never resumed")

-- 5. A fight or a position gap pauses the walk without advancing or
-- replanning it, and cannot fake arrival.
ask()
seen = walk({ { 0, 18 } })
check(seen[1] == ROAD1, "a new repair request plans afresh from where the seat stands")
seen = walk({ { 18, 78 } }, { in_combat = true })
check(not seen[1]:find("^repair_destination"), "a fight outranks the walk")
seen = walk({ { 18, 78 } }, { location_known = false })
check(seen[1] == "hold:repair_position_wait", "an unknown position holds")
seen = walk({ { 8, 30 } })
check(seen[1] == ROAD1, "after the pause the same unreached leg resumes; the pause did not arrive")

-- 6. A different owning job replans. A quest request supersedes the repair
-- request but leaves its walk record; its own pipeline reaches the same
-- repair walk from a new pose and plans from there, not from the old job's
-- road leg.
ask()
seen = walk({ { 0, 18 } })
check(seen[1] == ROAD1, "the repair request's journey takes the road")
ask("do_quests")
seen = walk({ { 0, 12 }, { 0, 12 } })
check(receipts():find('"key":"walk' .. (n - 1) .. '","choice":"repair_gear"[^\n]-"state":"superseded"') and
  seen[1] == CROW and seen[2] == CROW,
  "the superseding quest job replans from its own pose (got " .. seen[1] .. ", " .. seen[2] .. ")")

-- 7. A new repair request is a new walk: from the crow side it plans the crow
-- line and keeps it through the same pacing.
ask()
seen, flips = walk(pace({ 0, 12 }, { 0, 18 }, 12))
check(seen[1] == CROW and flips == 0, "a crow-line plan is kept across the boundary too")

-- 8. A leg the seat cannot make progress on is not hidden: the goal stays
-- put and the existing stall bound fails the request with its obstacle.
ask()
local driven, strays = 0, 0
for i = 1, 90 do
  r = home.decide(frame(0, (i % 2 == 1) and 18 or 14.5, t)); t = t + 0.5
  local g = goal(r)
  if not g:find("^repair_destination") then break end
  driven = driven + 1
  if g ~= ROAD1 then strays = strays + 1 end
end
check(driven > 40 and strays == 0, "a stuck seat keeps its stable leg while it is driven")
check(receipts():find('"key":"walk' .. n .. '","choice":"repair_gear","origin":"operator","actor":"operator","state":"failed"', 1, true) and
  receipts():find("no movement toward the catalogued repair destination", 1, true),
  "pacing in place ends at the existing stall bound as a failed repair")

-- 9. Defaults: a healer and no road data keep the crow line.
home.reset(); t = t + 400
ask()
seen = walk(pace({ 0, 18 }, { 0, 12 }, 4), { class_id = 5 })
check(seen[1] == CROW and seen[4] == CROW, "a healer's repair walk keeps the default crow line")
home.set_roads({}); home.reset(); t = t + 400
ask()
seen = walk({ { 0, 18 } })
check(seen[1] == CROW, "with no road data a broken tank walks honestly at the anchor")
home.set_roads({})
os.execute("rm -rf " .. dir)
print("test_repair_journey: " .. checks .. " checks passed")
