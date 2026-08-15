wow = {
  time = function() return 100 end,
  nav_progress = function() return { state = "idle" } end,
  log = function() end,
  set_status = function() end,
}

local home = require("home")

local checks = 0
local function check(ok, label)
  assert(ok, label)
  checks = checks + 1
end

local function spell(id, name, rank)
  return {
    spell_id = id, name = name, name_known = true, rank = rank or 1,
    usable_known = true, usable = true, cooldown_ms = 0,
    reagents_available = true,
  }
end

local function member(guid, name, hp, level)
  return {
    guid = guid, name = name, health_known = true, health = hp or 100,
    max_health = 100, level_known = true, level = level or 10,
    death_state_known = true, is_dead = false, is_ghost = false,
    active_auras_known = true, active_aura_spell_ids = {},
    location_known = true, elevation_known = true,
    location = { map_id = 0, x = 0, y = 0, z = 0 },
  }
end

local function leader_unit(distance, combat, target)
  return {
    guid = 100, name = "Murist", is_player_controlled = true,
    player_can_attack = false, death_known = true, is_dead = false,
    combat_known = true, is_in_combat = combat or false,
    target_guid_known = target ~= nil, target_guid = target or 0,
    location = { map_id = 0, position = { x = distance or 3, y = 0, z = 0 } },
    distance = distance or 3,
  }
end

local function hostile(guid, target_guid)
  return {
    guid = guid, name = "Mindless Zombie", player_can_attack = true,
    death_known = true, is_dead = false, health_known = true,
    health = 100, max_health = 100, target_guid_known = target_guid ~= nil,
    target_guid = target_guid or 0, active_aura_spell_ids = {}, distance = 4,
    combat_distance_known = true, combat_distance = 4,
    location = { map_id = 0, position = { x = 4, y = 0, z = 0 } },
  }
end

local function frame(class_id)
  local self_member = member(200, "Shadowfel", 100, 10)
  local murist = member(100, "Murist", 100, 10)
  murist.leader = true
  return {
    simulation_time = 100,
    player_guid = 200,
    class_id = class_id or 9,
    level = 10,
    location_known = true,
    location = { map_id = 0, position = { x = 0, y = 0, z = 0 } },
    health_known = true, health = 100, max_health = 100,
    powers = { 100, 0, 0, 0, 0 }, max_powers = { 100, 0, 0, 0, 0 },
    active_aura_spell_ids = {},
    is_dead = false, is_ghost = false, can_reclaim_corpse = false,
    resurrect_offer_guid = 0,
    in_combat = false, selected_target_guid = 0, auto_attack_guid = 0,
    active_cast_spell_id = 0, active_channel_spell_id = 0,
    party = {
      in_group = true, leader_guid = 100, leader_name = "Murist",
      invite_pending = false, invite_from = "",
      members = { self_member, murist },
    },
    units = { leader_unit(3, false) },
    spell_facts = {}, action_buttons = {}, quest_objectives = {},
  }
end

home.reset()
local v = frame()
v.party.in_group = false
v.party.invite_pending = true
v.party.invite_from = "mUrIsT"
local r = home.decide(v)
check(r.kind == "accept_party", "accepts only case-insensitive Murist invitation")
check(r.status.mode == "party_forming", "invite reports party-forming mode")

home.reset()
v = frame()
v.party.leader_guid = v.player_guid
v.party.leader_name = "Shadowfel"
r = home.decide(v)
check(r.kind == "promote_party" and r.guid == 100, "bot leader promotes Murist")
r = home.decide(v)
check(r.kind ~= "promote_party", "promotion retries are rate limited")
v.simulation_time = 106
r = home.decide(v)
check(r.kind == "promote_party", "promotion retries after five seconds")

home.reset()
v = frame()
v.units = {}
r = home.decide(v)
check(r.status.mode == "solo", "unobservable Murist selects solo fallback")
check(r.kind ~= "accept_party" and r.kind ~= "follow", "solo fallback does not invent party actions")

v = frame()
v.units = { leader_unit(30, false) }
r = home.decide(v)
check(r.kind == "follow" and r.guid == 100, "hard leash follows Murist")

v = frame()
v.units = { leader_unit(3, true) }
r = home.decide(v)
check(r.kind == "assist" and r.guid == 100, "assists fighting Murist without known target")

v = frame(9)
v.spell_facts = {
  spell(172, "Corruption", 1), spell(6222, "Corruption", 2),
  spell(686, "Shadow Bolt", 1),
}
v.units = { leader_unit(3, true, 300), hostile(300, 100) }
r = home.decide(v)
check(r.kind == "attack" and r.guid == 300 and r.spell == 6222,
  "warlock uses highest-rank missing DoT on Murist target")
check(r.kind ~= "pet_attack", "home rotation never emits pet attack")

v = frame(1)
v.party.members[1].name = "Tusk"
v.spell_facts = { spell(355, "Taunt", 1), spell(7386, "Sunder Armor", 1) }
v.units = { leader_unit(3, true, 300), hostile(300, 100) }
r = home.decide(v)
check(r.kind == "attack" and r.spell == 355, "tank taunts a party attacker")

v = frame(5)
v.party.members[1].name = "Beru"
v.party.members[2].health = 30
v.spell_facts = {
  spell(17, "Power Word: Shield", 1), spell(2050, "Lesser Heal", 1),
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 17 and r.target_guid == 100,
  "healer shields a low party member before formation work")

v = frame(5)
v.party.members[1].name = "Beru"
local dead = member(400, "Igris", 0, 10)
dead.is_dead = true
v.party.members[#v.party.members + 1] = dead
v.spell_facts = { spell(2006, "Resurrection", 1) }
r = home.decide(v)
check(r.kind == "cast_spell" and r.target_guid == 400,
  "Beru resurrects a nearby dead party member out of combat")

home.reset()
v = frame(9)
v.is_dead = true
v.party.members[#v.party.members + 1] = member(500, "Beru", 100, 10)
r = home.decide(v)
check(r.kind == "hold" and r.reason == "wait_for_beru_resurrection",
  "dead seat briefly waits for plausible Beru resurrection")
v.simulation_time = 121
r = home.decide(v)
check(r.kind == "release", "dead seat releases after bounded resurrection wait")

home.reset()
v = frame()
v.is_ghost = true
v.corpse_known = true
v.corpse_location = { map_id = 0, position = { x = 50, y = 20, z = 1 } }
r = home.decide(v)
check(r.kind == "navigate" and r.route_profile == "safe_ground",
  "ghost uses safe-ground corpse navigation")
v.can_reclaim_corpse = true
r = home.decide(v)
check(r.kind == "reclaim", "ghost reclaims only when observed available")

v = frame()
v.resurrect_offer_guid = 999
r = home.decide(v)
check(r.kind == "accept_rez", "observed resurrection offer wins recovery")

v = frame()
v.active_cast_spell_id = 686
r = home.decide(v)
check(r.kind == "hold" and r.reason == "finish_active_cast",
  "active casts are not interrupted by reorder churn")

v = frame()
r = home.decide(v)
check(r.kind == "hold" and r.reason == "in_formation",
  "idle escort does not pull unrelated mobs")

print("test_home: " .. checks .. " checks passed")
