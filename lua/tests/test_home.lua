wow = {
  time = function() return 100 end,
  nav_progress = function() return { state = "idle" } end,
  log = function() end,
  set_status = function() end,
}

local home = require("home")

-- Road routing is fed synthetic maps here, never the baked artifact: a test
-- that reads lua/data/bot_roads.lua would change its answer every time the
-- bake does. {} is "this world has no roads", which is the pre-road behaviour
-- every other case in this file expects.
home.set_roads({})

local checks = 0
local function check(ok, label)
  assert(ok, label)
  checks = checks + 1
end

local function idle_ok(r)
  return (r.kind == "hold" and r.reason == "in_formation")
    or (r.kind == "navigate" and r.reason == "formation_fidget")
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
check((r.reason == "hold_for_murist" or r.reason == "formation_fidget")
    and r.status.mode == "escort",
  "in Murist's party we hold/fidget, never solo, when he is unseen")

home.reset()
v = frame()
v.party = { in_group = false, members = {} }
v.units = {}
r = home.decide(v)
check(r.status.mode == "solo", "an ungrouped seat still solos")

-- Out-of-sight Murist with a known roster position: rejoin, don't shrug solo.
home.reset()
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 200, y = 0, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_far" and
  r.x == 200 and r.map_id == 0,
  "far roster position drives a long-range rejoin")
check(r.status.mode == "rejoin", "long-range rejoin reports rejoin mode")

-- Roads are freeways: a long rejoin walks the road rather than crowing
-- through the mob field between here and the leader. The fixture is the
-- router's own L-shaped freeway at world scale (lua/tests/test_road_route.lua):
-- a column up x=0 to y=800, then east along y=800, against a 1131 yd diagonal.
local function road_seg(pts)
  local flat = {}
  for _, p in ipairs(pts) do
    flat[#flat + 1] = p[1]
    flat[#flat + 1] = p[2]
    flat[#flat + 1] = p[3]
  end
  return flat
end
local elbow_column, elbow_row = {}, {}
for i = 0, 40 do
  elbow_column[#elbow_column + 1] = { 0, i * 20, 5 }
  elbow_row[#elbow_row + 1] = { i * 20, 800, 5 }
end
home.set_roads({ [0] = { road_seg(elbow_column), road_seg(elbow_row) } })

home.reset()
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 800, y = 800, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_road",
  "a long rejoin with usable road takes the road")
check(r.x == 0 and r.y > 0 and r.y <= 60 and r.z == 5,
  "the road rejoin walks at the next waypoint up the road, not at Murist")
check(r.stop_distance == 10 and r.map_id == 0,
  "road waypoints are handholds: stop short and re-decide next tick")
check(r.status.mode == "rejoin", "the road rejoin is still a rejoin")

-- Further along the same road: the waypoint advances, it never points back
-- down the column the seat already walked.
v = frame()
v.units = {}
v.location = { map_id = 0, position = { x = 0, y = 400, z = 5 } }
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 800, y = 800, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_road" and
  r.y > 400 and r.y <= 460, "the road waypoint advances with the seat")

-- Under the road threshold the crow line is still the right answer.
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 0, y = 60, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_far" and r.y == 60,
  "a short rejoin does not detour onto the road")

-- A road bail (here: no road on this map at all) is not an error, it is the
-- straight line the escort walked before roads existed.
home.set_roads({})
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 800, y = 800, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_far" and
  r.x == 800 and r.y == 800 and r.route_profile == "safe_ground",
  "a bailed road route navigates at Murist exactly as before")

-- Off-screen roster rows have no height (vanilla sends int16 x/y only, so the
-- projection fills z = 0.0 and flags elevation_known = false). Standing on a
-- ridge, walking at that literal z aims the router tens of yards underground.
v = frame()
v.units = {}
v.location = { map_id = 0, position = { x = 0, y = 0, z = 60 } }
v.party.members[2].location_known = true
v.party.members[2].elevation_known = false
v.party.members[2].location = { map_id = 0, x = 800, y = 800, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_far" and r.z == 60,
  "a heightless roster row walks at our own z, never at z = 0")

-- The leash has to be flat too, or our own altitude alone exceeds it while we
-- stand right on top of the leader, pinning the seat in rejoin forever.
v = frame()
v.units = {}
v.location = { map_id = 0, position = { x = 0, y = 0, z = 60 } }
v.party.members[2].location_known = true
v.party.members[2].elevation_known = false
v.party.members[2].location = { map_id = 0, x = 5, y = 0, z = 0, o = 0 }
r = home.decide(v)
check(r.status.mode ~= "rejoin",
  "own height alone does not trip the rejoin leash on a heightless row")

-- When the projection DOES vouch for the height (leader visible this tick),
-- the real z is used and the leash is the honest 3D distance again.
v = frame()
v.units = {}
v.location = { map_id = 0, position = { x = 0, y = 0, z = 60 } }
v.party.members[2].location_known = true
v.party.members[2].elevation_known = true
v.party.members[2].location = { map_id = 0, x = 800, y = 800, z = 5, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_far" and r.z == 5,
  "a roster row with a known elevation keeps its real z")

-- Roster position on another map is not walkable: solo, not a doomed walk.
home.reset()
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 1, x = 200, y = 0, z = 0, o = 0 }
r = home.decide(v)
check(r.reason == "hold_for_murist" or r.reason == "formation_fidget",
  "cross-map roster position holds/fidgets; we do not solo-wander")

-- follow/assist are not intent-boundary verbs (intent.nim); the escort
-- expresses both as navigate-to-leader, which the pilot actually accepts.
v = frame()
v.units = { leader_unit(30, false) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "hard_rejoin_murist" and
  r.navigation_mode == "local_steer" and r.stop_distance and r.stop_distance > 0,
  "hard leash walks straight at a visible Murist")

-- A road that heads the wrong way must not steal the follow (Shadowfel
-- walked east to 2812 while Murist was at 2655).
home.set_roads({ [0] = { { 0, 50, 0, 0, 150, 0, 0, 250, 0 } } })
home.reset()
v = frame()
v.units = { leader_unit(200, false) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "hard_rejoin_murist" and
  math.abs((r.x or 0) - 200) < 1,
  "a receding road waypoint is ignored; walk at Murist")
home.set_roads({})
home.reset()

v = frame()
v.units = { leader_unit(12, false) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "follow_murist",
  "visible Murist past 8yd always follows")

v = frame()
v.units = { leader_unit(12, true, 300), hostile(300, 100) }
r = home.decide(v)
check(r.reason ~= "follow_murist",
  "a fight at 12yd is played, not dropped to follow Murist")
check(r.kind == "attack" or r.kind == "cast_spell",
  "warlock at 12yd mid-fight still swings")

v = frame()
v.units = { leader_unit(25, true, 300), hostile(300, 100) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "hard_rejoin_murist",
  "a fight past the hard leash still rejoins")

home.reset()
v = frame()
v.health = 20
v.max_health = 100
v.in_combat = true
v.units = { leader_unit(3, true, 300), hostile(300, 100) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "survive_flee",
  "a seat at 20% hp steps off the mob instead of dying")

-- A runner inside 8yd must not park. Live Shadowfel held in_formation at
-- 7.6yd while Murist kept going 2434 -> 2440.
home.reset()
v = frame()
v.units = { leader_unit(6, false) }
v.simulation_time = 100
r = home.decide(v)
check(idle_ok(r), "first sample of a close Murist is still formation")
v.units = { leader_unit(7.5, false) }
v.simulation_time = 100.2
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "follow_murist" and
    r.stop_distance and r.stop_distance <= 2.5,
  "a moving Murist inside 8yd is followed, not held")

home.reset()
v = frame()
v.units = { leader_unit(6, false) }
v.simulation_time = 100
home.decide(v)
v.simulation_time = 100.2
r = home.decide(v)
check(idle_ok(r), "a standing Murist inside 8yd still holds")

home.reset()
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 12, y = 0, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "rejoin_murist_far",
  "off-screen Murist past 8yd rejoins instead of solo")

v = frame()
v.units = { leader_unit(3, true) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "assist_murist_close",
  "closes on fighting Murist without known target")

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

-- Heal range against a roster row hits the same heightless-z trap as the long
-- rejoin: a row the projection has not vouched for carries z = 0, so a healer
-- on a hill measures its OWN altitude and rules the party out of range while
-- standing on top of them.
v = frame(5)
v.party.members[1].name = "Beru"
v.location = { map_id = 0, position = { x = 0, y = 0, z = 50 } }
v.party.members[2].health = 30
v.party.members[2].elevation_known = false
v.spell_facts = {
  spell(17, "Power Word: Shield", 1), spell(2050, "Lesser Heal", 1),
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 17 and r.target_guid == 100,
  "a healer on a hill still heals through a heightless roster row")

-- A height the projection DOES vouch for is real distance and must still gate
-- the heal, or the healer burns casts on someone 50 yards below it.
v = frame(5)
v.party.members[1].name = "Beru"
v.location = { map_id = 0, position = { x = 0, y = 0, z = 50 } }
v.party.members[2].health = 30
v.party.members[2].elevation_known = true
v.spell_facts = {
  spell(17, "Power Word: Shield", 1), spell(2050, "Lesser Heal", 1),
}
r = home.decide(v)
check(r.kind ~= "cast_spell",
  "a vouched height still puts an out-of-range member out of heal range")

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
r = home.decide(v)
check(r.kind == "hold" and r.reason == "release_pending",
  "do not spam /release every tick")

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

-- A LONG ghost run takes the road like a long rejoin does (same elbow
-- freeway fixture as the rejoin cases; corpse at the far end of the elbow).
home.set_roads({ [0] = { road_seg(elbow_column), road_seg(elbow_row) } })
home.reset()
v = frame()
v.is_ghost = true
v.corpse_known = true
v.corpse_location = { map_id = 0, position = { x = 800, y = 800, z = 5 } }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "corpse_run_road" and
  r.x == 0 and r.y > 0 and r.y <= 60,
  "a long corpse run walks the road, not the crow line")
home.set_roads({})

v = frame()
v.resurrect_offer_guid = 999
r = home.decide(v)
check(r.kind == "accept_rez", "observed resurrection offer wins recovery")

-- A stranded chat box is flushed AHEAD of recovery: /reclaim is chat-driven
-- and types into the same fouled box forever otherwise.
home.reset()
v = frame()
v.is_ghost = true
v.can_reclaim_corpse = true
v.chat_input_visible = true
r = home.decide(v)
check(r.kind == "reclaim", "a fresh open box does not block the reclaim")
v.simulation_time = 106
r = home.decide(v)
check(r.kind == "quest_cmd" and r.reason == "close_chat_box",
  "a stranded box is flushed before recovery verbs retype into it")

v = frame()
v.active_cast_spell_id = 686
r = home.decide(v)
check(r.kind == "hold" and r.reason == "finish_active_cast",
  "active casts are not interrupted by reorder churn")

-- Live seats have EMPTY spell_facts (spellbook facts need catalog rows the
-- embedded client never requests); the bars are the real kit. The picker
-- must find bar spells when facts are absent.
v = frame(9)
v.spell_facts = {}
v.action_buttons = {
  { slot = 1, kind = "spell", spell_id = 688, spell_name = "Summon Imp",
    usable_known = true, usable = true, cooldown_ms = 0,
    not_enough_mana = false },
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 688,
  "empty spell_facts falls back to the action bars")

-- A petless warlock summons its imp in the idle window; a warlock whose
-- summoned unit is visible holds formation as before.
v = frame(9)
v.spell_facts = { spell(688, "Summon Imp", 1) }
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 688,
  "petless escort warlock summons its imp when idle")
v.units[#v.units + 1] = {
  guid = 4242, name = "Imp", summoner_guid = 200,
  player_can_attack = false, death_known = true, is_dead = false,
  distance = 2, location = { map_id = 0, position = { x = 1, y = 0, z = 0 } },
}
r = home.decide(v)
check(r.kind ~= "cast_spell", "warlock with a live summoned imp does not resummon")

-- THE gate that kept Igris petless for a whole session (live probe
-- 2026-08-16): the bar carried 688 with the right name and a zero cooldown,
-- but IsUsableAction reported usable=false / not_enough_mana=true because
-- escort mode chain-pulls and never rebuilds the bar. Out of combat with the
-- health to spare, Life Tap funds the summon instead of holding formation
-- broke; below the health floor the seat holds and regenerates.
v = frame(9)
v.spell_facts = {}
v.powers = { 5, 0, 0, 0, 0 }
v.action_buttons = {
  { slot = 1, kind = "spell", spell_id = 688, spell_name = "Summon Imp",
    usable_known = true, usable = false, cooldown_ms = 0,
    not_enough_mana = true },
  { slot = 2, kind = "spell", spell_id = 1454, spell_name = "Life Tap",
    usable_known = true, usable = true, cooldown_ms = 0,
    not_enough_mana = false },
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 1454 and
  r.reason == "life_tap_for_summon",
  "mana-blocked Summon Imp life taps for the mana instead of holding")
v.health = 20
r = home.decide(v)
check(idle_ok(r),
  "a hurt warlock does not life tap for a summon")
v.health = 100
v.action_buttons[1].usable = true
v.action_buttons[1].not_enough_mana = false
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 688,
  "with the mana back the summon wins over the life tap")

-- Pet before armor: a petless lock with mana for exactly one cast spends it
-- on the imp, not on Demon Skin.
v = frame(9)
v.spell_facts = {}
v.action_buttons = {
  { slot = 1, kind = "spell", spell_id = 687, spell_name = "Demon Skin",
    usable_known = true, usable = true, cooldown_ms = 0,
    not_enough_mana = false },
  { slot = 2, kind = "spell", spell_id = 688, spell_name = "Summon Imp",
    usable_known = true, usable = true, cooldown_ms = 0,
    not_enough_mana = false },
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 688,
  "petless warlock summons before self-buffing")
v.units[#v.units + 1] = {
  guid = 4244, name = "Imp", summoner_guid = 200,
  player_can_attack = false, death_known = true, is_dead = false,
  distance = 2, location = { map_id = 0, position = { x = 1, y = 0, z = 0 } },
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 687,
  "with the imp out the warlock goes back to self-buffing")

home.reset()
v = frame(9)
v.party = { in_group = false, members = {} }
v.units = {}
v.spell_facts = { spell(688, "Summon Imp", 1) }
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 688 and r.reason == "summon_imp",
  "petless solo warlock summons its imp before grinding")
check(r.status.mode == "solo", "solo summon reports solo mode")
v.active_cast_spell_id = 688
r = home.decide(v)
check(r.kind == "hold" and r.reason == "finish_active_cast",
  "solo does not interrupt the 10s summon")
v.active_cast_spell_id = 0
v.units = {
  { guid = 4245, name = "Imp", summoner_guid = 200,
    player_can_attack = false, death_known = true, is_dead = false,
    distance = 2, location = { map_id = 0, position = { x = 1, y = 0, z = 0 } } },
}
r = home.decide(v)
check(not (r.kind == "cast_spell" and r.spell == 688),
  "solo warlock with a live imp does not resummon")
home.reset()
v = frame(9)
v.party = { in_group = false, members = {} }
v.in_combat = true
v.spell_facts = { spell(688, "Summon Imp", 1) }
v.units = { hostile(301, 200) }
r = home.decide(v)
check(not (r.kind == "cast_spell" and r.spell == 688),
  "solo warlock does not start a summon mid-fight")

-- A mob beating on a party member's PET is party business too.
v = frame(9)
v.spell_facts = {
  spell(172, "Corruption", 1), spell(686, "Shadow Bolt", 1),
}
v.units = {
  leader_unit(3, false),
  { guid = 4243, name = "Imp", summoner_guid = 100,
    player_can_attack = false, death_known = true, is_dead = false,
    distance = 3, location = { map_id = 0, position = { x = 2, y = 0, z = 0 } } },
  hostile(301, 4243),
}
r = home.decide(v)
check(r.kind == "attack" and r.guid == 301,
  "escort attacks a hostile beating on the leader's pet")

-- A leashed mob far away keeps a stale party target set; it is not our
-- fight, and fixating on it starves the idle branch (no swings, no summon).
v = frame(9)
v.spell_facts = { spell(686, "Shadow Bolt", 1) }
v.units = {
  leader_unit(3, false),
  { guid = 302, name = "Scarlet Zealot", player_can_attack = true,
    death_known = true, is_dead = false, health_known = true,
    health = 82, max_health = 100, target_guid_known = true,
    target_guid = 100, active_aura_spell_ids = {}, distance = 1273,
    combat_distance_known = true, combat_distance = 1273,
    location = { map_id = 0, position = { x = 1273, y = 0, z = 0 } } },
}
r = home.decide(v)
check(r.kind ~= "attack", "a party-targeting hostile beyond range is ignored")

v = frame(9)
v.spell_facts = { spell(686, "Shadow Bolt", 1) }
v.units = {
  leader_unit(3, false),
  { guid = 302, name = "Scarlet Zealot", player_can_attack = true,
    death_known = true, is_dead = false, health_known = true,
    health = 82, max_health = 100, target_guid_known = true,
    target_guid = 100, active_aura_spell_ids = {}, distance = 1273,
    combat_distance_known = true, combat_distance = 1273,
    location = { map_id = 0, position = { x = 1273, y = 0, z = 0 } } },
}
v.selected_target_guid = 302
r = home.decide(v)
check(r.kind ~= "attack", "a stale far selection does not fixate the escort")

-- A party kill arms the shared loot machinery: the corpse gets interacted
-- with from the escort's idle window, before buffs.
v = frame()
v.player_guid = 200
v.units[#v.units + 1] = {
  guid = 950, name = "Duskbat", player_can_attack = true,
  death_known = true, is_dead = true, health_known = true, health = 0,
  max_health = 40, distance = 2, active_aura_spell_ids = {},
  location = { map_id = 0, position = { x = 1, y = 0, z = 0 } },
}
v.combat_kill_events = { { source_guid = 200, target_guid = 950 } }
r = home.decide(v)
check(r.kind == "interact" and r.reason == "loot_corpse",
  "escort loots its own party kill when idle")

v = frame()
r = home.decide(v)
check(idle_ok(r),
  "idle escort does not pull unrelated mobs")
check(r.kind ~= "ui_press", "no roll prompt presses nothing")

-- Group loot rolls. The guid in the reference is an unsigned spelling of a
-- uint64 the seat would read back as a negative int64: matched by prefix and
-- choice suffix only, never compared.
-- Source names and reference spellings come from the client:
-- GroupLootFrame1RollButton/GreedButton/PassButton (ui/chrome.nim
-- lootRollButtonSourceName) over "loot-roll:<target>:<slot>:<choice>".
local function roll_node(suffix, choice, enabled)
  return {
    source_name = "GroupLootFrame1" .. suffix,
    reference_id = "loot-roll:18446744073709551615:3:" .. choice,
    enabled = enabled ~= false, hit_testable = true, text = "",
  }
end

v = frame()
v.ui_nodes = {
  roll_node("RollButton", "need"),
  roll_node("GreedButton", "greed"),
  roll_node("PassButton", "pass"),
}
r = home.decide(v)
check(r.kind == "ui_press" and r.reason == "group_loot_greed" and
  r.reference == "loot-roll:18446744073709551615:3:greed",
  "visible group loot roll is answered with greed")
check(r.status.mode == "loot_roll", "roll answer reports loot-roll mode")

v = frame()
v.ui_nodes = {
  roll_node("RollButton", "need"),
  roll_node("GreedButton", "greed", false),
  roll_node("PassButton", "pass"),
}
r = home.decide(v)
check(r.kind == "ui_press" and r.reason == "group_loot_pass" and
  r.reference == "loot-roll:18446744073709551615:3:pass",
  "unavailable greed falls through to pass, never to need")

v = frame()
v.units = {}
v.ui_nodes = { roll_node("GreedButton", "greed") }
r = home.decide(v)
check(r.kind == "ui_press" and r.reason == "group_loot_greed",
  "roll is answered ahead of the solo fallback")

v = frame()
v.is_ghost = true
v.ui_nodes = { roll_node("GreedButton", "greed") }
r = home.decide(v)
check(r.kind == "ui_press" and r.reason == "group_loot_greed",
  "roll is answered ahead of corpse recovery")

-- Party banter. The seat's mailbox is a real file on disk here, because the
-- consume-once rule is the whole contract between brain and host.
local chat_dir = os.tmpname()
os.remove(chat_dir)
assert(os.execute("mkdir -p '" .. chat_dir .. "/chat'"))
local chat_off = nil
local real_getenv = os.getenv
os.getenv = function(key)
  if key == "VANILLA_WOW_LUA_DEBUG_DIR" then return chat_dir .. "/control" end
  if key == "SHADOW_CHAT_QWEN_OFF" then return chat_off end
  return real_getenv(key)
end

local function put_line(text, written_at)
  local handle = assert(io.open(chat_dir .. "/chat/outbox.json", "w"))
  handle:write('{"protocol":"wow_shadow_army.bot_chat.v1","seat":"Shadowfel",' ..
    '"channel":"party","text":"' .. text .. '","id":1' ..
    (written_at and (',"created_at_unix_seconds":' .. written_at) or "") .. "}")
  handle:close()
end

local function outbox_present()
  local handle = io.open(chat_dir .. "/chat/outbox.json", "r")
  if not handle then return false end
  handle:close()
  return true
end

local function chat_frame(at)
  local f = frame()
  f.simulation_time = at
  f.chat_send_supported = true
  return f
end

home.reset()
put_line("stand ready")
v = frame()
v.simulation_time = 200
r = home.decide(v)
check(idle_ok(r),
  "a host without chat support never reaches the mailbox")
check(outbox_present(), "an unsupported host leaves the line for a newer one")

home.reset()
v = chat_frame(300)
r = home.decide(v)
check(r.kind == "chat" and r.channel == "party" and r.text == "stand ready",
  "a queued line is spoken in party from formation")
check(not outbox_present(), "the mailbox is consumed on read")
check(r.status.mode == "escort", "banter still reports escort mode")

-- The client opens the box, takes the text, then closes it; the brain must
-- hold the same intent for every frame in between.
v = chat_frame(300.2)
v.chat_input_visible = true
r = home.decide(v)
check(r.kind == "chat" and r.text == "stand ready",
  "an in-flight line repeats while the box is open")
v = chat_frame(300.4)
r = home.decide(v)
check(idle_ok(r),
  "the closed box ends the sequence")

put_line("again already")
v = chat_frame(305)
r = home.decide(v)
check(idle_ok(r),
  "a second line inside the gap is not spoken")
v = chat_frame(325)
r = home.decide(v)
check(r.kind == "chat" and r.text == "again already",
  "the next line waits out the gap and then speaks")

home.reset()
put_line("mid sentence")
v = chat_frame(400)
r = home.decide(v)
check(r.kind == "chat", "line starts from formation")
v = chat_frame(400.2)
v.in_combat = true
v.units = { leader_unit(3, true, 300), hostile(300, 200) }
r = home.decide(v)
check(r.kind ~= "chat", "combat drops the line rather than finishing it")

home.reset()
put_line("waited too long")
v = chat_frame(500)
r = home.decide(v)
check(r.kind == "chat", "line starts")
v = chat_frame(504)
v.chat_input_visible = true
r = home.decide(v)
check(r.kind ~= "chat",
  "a line the box never accepts is abandoned inside the flush window")

home.reset()
put_line("/script evil()")
v = chat_frame(600)
r = home.decide(v)
check(idle_ok(r),
  "a line that opens a slash command is refused")

home.reset()
put_line(string.rep("x", 121))
v = chat_frame(700)
r = home.decide(v)
check(idle_ok(r),
  "a line past the length cap is refused")

home.reset()
put_line("asked an hour ago", string.format("%d", os.time() - 3600))
v = chat_frame(750)
r = home.decide(v)
check(idle_ok(r),
  "a line written long before this seat looked is not spoken")
check(not outbox_present(), "the stale line is still cleared from the mailbox")

home.reset()
put_line("just now", string.format("%d", os.time()))
v = chat_frame(760)
r = home.decide(v)
check(r.kind == "chat" and r.text == "just now",
  "a freshly written line is spoken")

home.reset()
chat_off = "1"
put_line("silence me")
v = chat_frame(800)
r = home.decide(v)
check(idle_ok(r),
  "the kill switch stops the seat speaking")
check(outbox_present(), "a silenced seat does not even open the mailbox")
chat_off = nil
os.execute("rm -rf '" .. chat_dir .. "'")

-- Formation hold is silent; vanilla AFKs after ~5 min. First idle hop
-- is a movement packet so <AFK> clears.
home.reset()
v = frame()
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "formation_fidget",
  "first idle in formation hops so the AFK timer cannot start")
r = home.decide(v)
check(r.kind == "hold" and r.reason == "in_formation",
  "the hop is rate limited; later ticks hold")
v.simulation_time = 200
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "formation_fidget",
  "the hop repeats after the fidget interval")

-- Displacement watchdog: a ghost wedged in place for more than eight seconds
-- across several frames escapes by a short local-steer leg, then rotates
-- the bearing once the six-second window closes.
home.reset()
v = frame()
v.is_ghost = true
v.can_reclaim_corpse = false
v.corpse_known = true
v.corpse_location = { map_id = 0, position = { x = 200, y = 0, z = 0 } }
v.location = { map_id = 0, position = { x = 10, y = 20, z = 1 } }
r = nil
for t = 100, 109, 1 do
  v.simulation_time = t
  r = home.decide(v)
end
check(r.kind == "navigate" and r.reason == "corpse_run_unstick" and
  r.navigation_mode == "local_steer" and r.allow_jump == true,
  "wedged ghost escapes with a local-steer corpse-run unstick")
local first_dx = r.x - v.location.position.x
local first_dy = r.y - v.location.position.y
for t = 110, 116, 1 do
  v.simulation_time = t
  r = home.decide(v)
end
check(r.reason == "corpse_run_unstick" and
  (first_dx ~= r.x - v.location.position.x or
    first_dy ~= r.y - v.location.position.y),
  "the second unstick attempt rotates the bearing")

-- Same ghost setup, but the seat actually moves: the watchdog must not fire.
home.reset()
v = frame()
v.is_ghost = true
v.can_reclaim_corpse = false
v.corpse_known = true
v.corpse_location = { map_id = 0, position = { x = 400, y = 0, z = 0 } }
local saw_unstick = false
r = nil
for t = 100, 109, 1 do
  v.simulation_time = t
  v.location = { map_id = 0, position = { x = (t - 100) * 5, y = 0, z = 0 } }
  r = home.decide(v)
  if r.reason == "corpse_run_unstick" then saw_unstick = true end
end
check(not saw_unstick and
  (r.reason == "corpse_run" or r.reason == "corpse_run_road"),
  "a moving ghost stays on the corpse run")

-- Off-screen Murist past the hard leash, seat glued to one tile: rejoin unstick.
home.reset()
v = frame()
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 200, y = 0, z = 0, o = 0 }
r = nil
for t = 100, 109, 1 do
  v.simulation_time = t
  r = home.decide(v)
end
check(r.kind == "navigate" and r.reason == "rejoin_unstick",
  "wedged rejoin escapes with a rejoin unstick")

-- Combat is a legitimate pin: the same wedged rejoin must keep walking Murist.
home.reset()
v = frame()
v.in_combat = true
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].location = { map_id = 0, x = 200, y = 0, z = 0, o = 0 }
saw_unstick = false
r = nil
for t = 100, 109, 1 do
  v.simulation_time = t
  r = home.decide(v)
  if r.reason == "rejoin_unstick" then saw_unstick = true end
end
check(not saw_unstick and
  (r.reason == "rejoin_murist_far" or r.reason == "rejoin_murist_road"),
  "a busy seat never unsticks")

-- Murist VISIBLE but past the hard leash is a third blind walk, and it wedges
-- like the other two: Tusk sat at 2234.4,-17.9 for 90s with nav reporting
-- "following" while the pilot's own escape reflex failed on the spot. This
-- branch returns before the rejoin and recovery branches, so it never reached
-- their watchdog.
home.reset()
v = frame()
v.units = { leader_unit(30, false) }
r = nil
for t = 100, 109, 1 do
  v.simulation_time = t
  r = home.decide(v)
end
check(r.kind == "navigate" and r.reason == "escort_unstick" and
  r.navigation_mode == "local_steer" and r.allow_jump == true,
  "a wedged hard-leash escort escapes with an escort unstick")

-- A tank legitimately holding a pull out past the leash is not wedged, and
-- yanking it 22 yards off the mob would be worse than the stall.
home.reset()
v = frame()
v.in_combat = true
v.units = { leader_unit(30, false) }
saw_unstick = false
r = nil
for t = 100, 109, 1 do
  v.simulation_time = t
  r = home.decide(v)
  if r.reason == "escort_unstick" then saw_unstick = true end
end
check(not saw_unstick, "a hard-leash escort in combat never unsticks")

-- Vendor sell. Everything here is stubbed at the SHAPE the fork's Observation
-- already publishes (environment/contract/observation_types.nim) but that
-- bots/lua_bot/view.nim does not yet project into the Lua view — see
-- tickets/open/0073. The `sell_supported` flag is the same host-capability
-- idiom as chat_send_supported: absent means the seat only watches.
local logged = {}
local realLog = wow.log
wow.log = function(msg) logged[#logged + 1] = tostring(msg) end

local function logs_matching(needle)
  for i = 1, #logged do
    if string.find(logged[i], needle, 1, true) then return logged[i] end
  end
  return nil
end

local function bag_row(guid, id, name, class, sub, quality, price, extra)
  local row = {
    item_guid = guid, item_id = id, name = name, count = 1,
    definition_known = true, item_class_id = class, item_subclass_id = sub,
    quality = quality, sell_price = price, inventory_type = 0,
    container_slots = 0, container_item_count = 0, item_level = 1,
  }
  for k, val in pairs(extra or {}) do row[k] = val end
  return row
end

local function vendor_frame()
  local vf = frame(9) -- warlock
  vf.merchant_open = true
  vf.merchant_guid = 4242
  vf.equipment_items = {
    { equipment_slot = 19, item_id = 4496, container_slots = 6,
      inventory_type = 18, item_level = 1 },
    { equipment_slot = 20, item_id = 4496, container_slots = 6,
      inventory_type = 18, item_level = 1 },
    { equipment_slot = 21, item_id = 4496, container_slots = 6,
      inventory_type = 18, item_level = 1 },
    { equipment_slot = 22, item_id = 4496, container_slots = 6,
      inventory_type = 18, item_level = 1 },
  }
  vf.inventory_items = {
    bag_row(11, 6948, "Hearthstone", 15, 0, 1, 0),
    bag_row(12, 1234, "Chain Bracers", 4, 3, 1, 55),
    bag_row(13, 4496, "Small Brown Pouch", 1, 0, 1, 25,
      { container_slots = 6 }),
    bag_row(14, 2589, "Linen Cloth", 7, 0, 1, 1, { count = 5 }),
  }
  return vf
end

-- 1. No merchant window, no vendor work — and no logging noise either.
home.reset()
logged = {}
v = frame()
v.inventory_items = vendor_frame().inventory_items
r = home.decide(v)
check(r.kind ~= "sell_item" and r.status.mode ~= "vendor",
  "a closed merchant window never sells")

-- 2. The live shape today: merchant open, bags invisible to the view. The
--    seat must NOT invent an action, and must say why exactly once.
home.reset()
logged = {}
v = frame()
v.merchant_open = true
v.merchant_guid = 4242
r = home.decide(v)
check(r.kind ~= "sell_item", "no bag projection means no sale")
check(logs_matching("0073") ~= nil,
  "the missing bag projection names its ticket in the log")

-- 3. Bags visible, host cannot sell: report the shortlist, move nothing.
home.reset()
logged = {}
v = vendor_frame()
r = home.decide(v)
check(r.kind ~= "sell_item", "a host without sell support never sells")
local report = logs_matching("bag items to sell")
check(report ~= nil, "a vendor visit reports its sell shortlist")
check(string.find(report, "Chain Bracers", 1, true) ~= nil,
  "the shortlist names the mail a warlock cannot wear")
check(string.find(report, "Small Brown Pouch", 1, true) ~= nil,
  "the shortlist names the spare six-slot bag")
check(string.find(report, "Linen Cloth", 1, true) == nil,
  "the shortlist leaves white trade goods alone")
check(string.find(report, "Hearthstone", 1, true) == nil,
  "the shortlist never touches the Hearthstone")
r = home.decide(v)
check(logs_matching("bag items to sell") == report and #logged <= 2,
  "the shortlist is reported once per merchant, not once per tick")

-- 4. Host CAN sell: one item per tick, rate limited, never the same twice.
home.reset()
logged = {}
v = vendor_frame()
v.sell_supported = true
r = home.decide(v)
check(r.kind == "sell_item" and r.guid == 4242 and r.item_guid == 12,
  "an open merchant sells the unwearable mail first")
check(r.status.mode == "vendor", "a sale reports vendor mode")
r = home.decide(v)
check(r.kind ~= "sell_item", "sales are rate limited inside the gap")
v.simulation_time = 102
r = home.decide(v)
check(r.kind == "sell_item" and r.item_guid == 13,
  "the next tick sells the next item, not the same one again")
v.simulation_time = 104
r = home.decide(v)
check(r.kind ~= "sell_item", "nothing left to sell ends the vendor step")

-- 5. A warrior at the same vendor keeps the mail: warriors learn it at 40, so
--    "cannot use yet" is never a sale.
home.reset()
logged = {}
v = vendor_frame()
v.class_id = 1
v.sell_supported = true
r = home.decide(v)
check(r.kind == "sell_item" and r.item_guid == 13,
  "a warrior sells the spare bag but keeps the mail")

-- 6. Bags: the equip half (ticket 0073's "first order fix is EQUIP, not
--    sell"). A seat carrying pouches with an empty carried-bag slot wears
--    the roomiest one, out of combat, one per tick.
local function bagless_frame()
  local bf = frame(9) -- warlock
  -- Equip is banned while Murist is grouped (0074 hang). These tests
  -- cover the solo verb, so drop the party.
  bf.party = { in_group = false, members = {} }
  bf.equip_supported = true
  bf.equipment_items = {} -- zero bags equipped: the live home-seat shape
  bf.inventory_items = {
    bag_row(21, 4496, "Small Brown Pouch", 1, 0, 1, 25,
      { container_slots = 6 }),
    bag_row(22, 4500, "Large Knapsack", 1, 0, 1, 90,
      { container_slots = 10 }),
    bag_row(23, 6948, "Hearthstone", 15, 0, 1, 0),
    bag_row(24, 1234, "Chain Bracers", 4, 3, 1, 55),
  }
  return bf
end

-- Off-screen Murist wins over a carried bag. Live Igris sat on
-- equip_bag at 1897,-242 while Murist was 600yd east on the roster.
home.reset()
logged = {}
v = bagless_frame()
v.party = frame().party
v.units = {}
v.party.members[2].location_known = true
v.party.members[2].elevation_known = false
v.party.members[2].location = { map_id = 0, x = 400, y = 0, z = 0, o = 0 }
r = home.decide(v)
check(r.kind == "navigate" and (r.reason == "rejoin_murist_far" or
    r.reason == "rejoin_murist_road"),
  "a carried bag does not pin a seat that should walk to Murist")
check(r.status.mode == "rejoin", "bag-vs-rejoin reports rejoin, not vendor")

home.reset()
logged = {}
v = bagless_frame()
v.party = frame().party
v.units = { leader_unit(12, false) }
r = home.decide(v)
check(r.kind == "navigate" and r.reason == "follow_murist",
  "a carried bag does not pin a seat while Murist is walking")

home.reset()
logged = {}
v = bagless_frame()
v.party = frame().party
v.units = { leader_unit(3, false) }
r = home.decide(v)
check(r.kind ~= "equip_item",
  "in Murist's party never emits equip_item")

home.reset()
logged = {}
v = bagless_frame()
v.party = frame().party
v.units = {}
r = home.decide(v)
check(r.kind ~= "equip_item" and
    (r.reason == "hold_for_murist" or r.reason == "formation_fidget"),
  "unseen Murist with no rejoin holds/fidgets instead of equipping")

home.reset()
logged = {}
v = bagless_frame()
r = home.decide(v)
check(r.kind ~= "equip_item",
  "0074: first equip_item freezes decide, so solo seats skip the verb")
check(logs_matching("0074 host freeze") ~= nil,
  "the skip names the fork freeze once")
r = home.decide(v)
check(logs_matching("0074 host freeze") ~= nil,
  "standing down says why, once")

-- When EQUIP_EMIT is restored, the attempt budget still has to cap a
-- host that accepts the verb but never lands the bag. That path is
-- dead while the live emit is off; the skip above is the live gate.

-- Never the Hearthstone, never armour: only class-1 rows with real capacity.
home.reset()
logged = {}
v = bagless_frame()
v.inventory_items = {
  bag_row(23, 6948, "Hearthstone", 15, 0, 1, 0),
  bag_row(24, 1234, "Chain Bracers", 4, 3, 1, 55),
}
r = home.decide(v)
check(r.kind ~= "equip_item", "nothing but a container is ever equipped here")

-- A packed bag is left alone: the seat cannot know why it is packed.
home.reset()
logged = {}
v = bagless_frame()
v.inventory_items = {
  bag_row(25, 4496, "Small Brown Pouch", 1, 0, 1, 25,
    { container_slots = 6, container_item_count = 3 }),
}
r = home.decide(v)
check(r.kind ~= "equip_item", "a bag with contents in it is not equipped")

-- All four slots full: that is the sell path's job, not this one. This is the
-- seam that keeps the two halves from fighting over the same bag.
home.reset()
logged = {}
v = bagless_frame()
v.equipment_items = vendor_frame().equipment_items -- four 6-slot bags worn
r = home.decide(v)
check(r.kind ~= "equip_item",
  "no free bag slot means no equip — the spare is the sell path's problem")

-- Unsupported host and combat both refuse, the same way the sell half does.
home.reset()
logged = {}
v = bagless_frame()
v.equip_supported = false
r = home.decide(v)
check(r.kind ~= "equip_item", "a host without equip support never equips")

home.reset()
logged = {}
v = bagless_frame()
v.in_combat = true
r = home.decide(v)
check(r.kind ~= "equip_item", "a seat in combat never stops to equip a bag")

home.reset()
logged = {}
v = bagless_frame()
v.is_dead = true
r = home.decide(v)
check(r.kind ~= "equip_item", "a corpse never equips a bag")

-- 7. Solo seat, bags full, junk in the backpack, vendor in view: walk over
--    and open the window. Equip already ran (no spare bag here), sell needs
--    merchant_open, so this is the missing third verb.
local function solo_full_bags()
  local sf = frame(9)
  sf.party = { in_group = false, members = {} }
  sf.equip_supported = true
  sf.sell_supported = true
  sf.bag_space_known = true
  sf.free_bag_slots = 0
  sf.equipment_items = vendor_frame().equipment_items
  sf.inventory_items = {
    bag_row(12, 1234, "Chain Bracers", 4, 3, 1, 55),
    bag_row(13, 4865, "Ruined Pelt", 15, 0, 0, 5),
  }
  sf.units = {
    {
      guid = 2115, name = "Joshua Kien", object_kind = "unit",
      services = { "questgiver", "vendor" }, distance = 40,
      death_known = true, is_dead = false, player_can_attack = false,
      location = { map_id = 0, position = { x = 40, y = 0, z = 0 } },
    },
  }
  return sf
end

home.reset()
logged = {}
v = solo_full_bags()
r = home.decide(v)
check(r.reason ~= "open_vendor" and r.reason ~= "open_vendor_walk",
  "live interact freeze: vendor seek is off; full bags still grind")

v.quest_frame = { open = true, panel = "reward" }
r = home.decide(v)
check(r.reason ~= "vendor_clear_dialog",
  "vendor seek off means no dialog-clear for the vendor walk")

v.quest_frame = { open = false }
v.free_bag_slots = 5
r = home.decide(v)
check(r.reason ~= "open_vendor", "roomy bags do not walk to a vendor")

v.free_bag_slots = 0
v.units = {}
r = home.decide(v)
check(r.reason ~= "open_vendor", "no vendor in view means no seek")

home.reset()
v = solo_full_bags()
v.party = frame().party
v.units = { leader_unit(3, false), solo_full_bags().units[1] }
r = home.decide(v)
check(r.reason ~= "open_vendor",
  "an escort with Murist does not walk off to a vendor")

home.reset()
v = solo_full_bags()
v.in_combat = true
r = home.decide(v)
check(r.reason ~= "open_vendor", "combat never seeks a vendor")

-- A questgiver-vendor opens quest, not merchant. Prefer the pure vendor.
home.reset()
v = solo_full_bags()
v.units = {
  solo_full_bags().units[1], -- Joshua, questgiver+vendor @40
  {
    guid = 2113, name = "Archibald Kava", object_kind = "unit",
    services = { "vendor", "repair" }, distance = 50,
    death_known = true, is_dead = false, player_can_attack = false,
    location = { map_id = 0, position = { x = 50, y = 0, z = 0 } },
  },
}
r = home.decide(v)
check(r.reason ~= "open_vendor",
  "vendor seek off: no interact even when a pure vendor is in view")

local old_nav = wow.nav_progress
wow.nav_progress = function() return { state = "planning" } end
home.reset()
v = solo_full_bags()
r = home.decide(v)
check(r.reason ~= "open_vendor_walk" and r.reason ~= "vendor_unstick",
  "vendor seek off: no steered vendor walk")
wow.nav_progress = old_nav

-- Escort warrior Charges to close; other classes never do.
home.reset()
v = frame(1)
v.action_buttons = {
  { slot = 1, kind = "spell", spell_id = 100, spell_name = "Charge",
    usable_known = true, usable = true, cooldown_ms = 0 },
  { slot = 2, kind = "spell", spell_id = 78, spell_name = "Heroic Strike",
    usable_known = true, usable = true, cooldown_ms = 0 },
}
local far = hostile(400, 100)
far.distance = 15
far.combat_distance = 15
far.location.position.x = 15
v.units = { leader_unit(3, true, 400), far }
r = home.decide(v)
check(r.kind == "attack" and r.spell == 100 and r.reason == "warrior_charge",
  "escort warrior Charges from mid range")
check(r.stop_distance == 25.0, "escort Charge stop stays at Charge max range")
v.in_combat = true
r = home.decide(v)
check(r.spell ~= 100, "escort warrior does not Charge once in combat")

-- Escort mage: Frost Armor out of combat, Fireball at caster range in a fight.
home.reset()
v = frame(8)
v.action_buttons = {
  { slot = 1, kind = "spell", spell_id = 168, spell_name = "Frost Armor",
    usable_known = true, usable = true, cooldown_ms = 0 },
  { slot = 2, kind = "spell", spell_id = 133, spell_name = "Fireball",
    usable_known = true, usable = true, cooldown_ms = 0 },
}
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 168 and r.reason == "self_buff",
  "escort mage buffs Frost Armor before standing in formation")
v.units = { leader_unit(3, true, 400), hostile(400, 100) }
v.in_combat = true
r = home.decide(v)
check(r.kind == "attack" and r.spell == 133 and r.reason == "mage_nuke",
  "escort mage opens with Fireball")
check(r.stop_distance == 22.0, "escort mage stops at caster range")

-- === tank and healer rotations (Tusk / Beru, 2026-08-16) ================
-- The live bars ARE the kit. bots/lua_bot/view.nim never exports spell_facts
-- at all and only exports the 12 buttons of the ACTIVE bar page, so every
-- case below drives the action-bar path the seats actually run.
local function bar(id, name)
  return { slot = 1, kind = "spell", spell_id = id, spell_name = name,
    usable_known = true, usable = true, cooldown_ms = 0,
    not_enough_mana = false }
end

-- Charge is the opener: out of combat in the 8-25yd band it closes the gap
-- AND arrives with the rage the tank otherwise stands around waiting for.
home.reset()
v = frame(1)
v.party.members[1].name = "Tusk"
local far_mob = hostile(300, 100)
far_mob.distance = 15
far_mob.combat_distance = 15
far_mob.location = { map_id = 0, position = { x = 15, y = 0, z = 0 } }
v.units = { leader_unit(3, true, 300), far_mob }
v.action_buttons = { bar(100, "Charge"), bar(78, "Heroic Strike") }
r = home.decide(v)
check(r.kind == "attack" and r.spell == 100 and r.reason == "warrior_charge",
  "tank charges the opener from range")

-- In combat the charge is gone and the filler takes over: Sunder builds the
-- threat, Heroic Strike is only the dump for rage left over.
v.in_combat = true
v.action_buttons = { bar(78, "Heroic Strike"), bar(7386, "Sunder Armor") }
r = home.decide(v)
check(r.kind == "attack" and r.spell == 7386,
  "tank sunders before dumping rage into Heroic Strike")

-- Heroic Strike is queued on the NEXT swing and the client reports the queue
-- as an active button; pressing it again cancels the queue. A level 8 tank
-- whose only ability is Heroic Strike spends the whole fight doing that.
v.action_buttons = { bar(78, "Heroic Strike") }
v.action_buttons[1].active = true
r = home.decide(v)
check(r.kind == "attack" and r.spell == nil and r.reason == "tank_swing_queued",
  "a queued Heroic Strike is never re-pressed")

-- Battle Shout falls off mid-pull, so it is upkeep IN combat -- aura-gated,
-- or a tank who cannot afford anything else turns it into the rage sink.
home.reset()
v.action_buttons = { bar(6673, "Battle Shout"), bar(78, "Heroic Strike") }
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 6673 and
  r.reason == "tank_battle_shout", "tank keeps Battle Shout up in combat")
v.active_aura_spell_ids = { 6673 }
r = home.decide(v)
check(r.spell == 78, "a shouting tank goes straight back to building threat")

-- Taunt is one mob's worth of threat on a 30s cooldown. A mob already
-- chewing on the tank is exactly where a tank wants it.
home.reset()
v = frame(1)
v.party.members[1].name = "Tusk"
local on_me = hostile(300, 200)
v.units = { leader_unit(3, true, 300), on_me }
v.in_combat = true
v.action_buttons = { bar(355, "Taunt"), bar(7386, "Sunder Armor") }
r = home.decide(v)
check(r.kind == "attack" and r.spell == 7386,
  "tank does not waste Taunt on a mob already on him")
on_me.target_guid = 100
r = home.decide(v)
check(r.kind == "attack" and r.spell == 355 and
  r.reason == "tank_taunt_party_attacker",
  "tank taunts a mob that peeled onto a party member")

-- Beru outranks Murist's own target. A level 8 priest in cloth dies to two
-- hits from anything Murist is willing to pull, and the healer that dies ends
-- the fight for everybody.
home.reset()
v = frame(1)
v.party.members[1].name = "Tusk"
v.party.members[#v.party.members + 1] = member(700, "Beru", 100, 8)
local on_beru = hostile(400, 700)
on_beru.distance = 12
on_beru.combat_distance = 12
on_beru.location = { map_id = 0, position = { x = 12, y = 0, z = 0 } }
local on_murist = hostile(500, 100)
v.units = { leader_unit(3, true, 500), on_murist, on_beru }
v.in_combat = true
v.action_buttons = { bar(78, "Heroic Strike") }
r = home.decide(v)
check(r.kind == "attack" and r.guid == 400,
  "tank peels the mob off Beru instead of assisting Murist's target")
check(r.status.target_guid == 400, "the peel is what status reports")

-- Two adds on the healer trade places in the distance sort every tick, and a
-- tank that re-selects on every tie never lands a swing.
v.auto_attack_guid = 400
local also_on_beru = hostile(600, 700)
also_on_beru.distance = 3
also_on_beru.combat_distance = 3
v.units = { leader_unit(3, true, 500), on_murist, on_beru, also_on_beru }
r = home.decide(v)
check(r.guid == 400, "the tank holds its peel against an equal-rank add")

-- A mob already on the tank is a peel that WORKED. Handing it back to go
-- fetch one off Murist is how the mob ends up on Beru again.
on_beru.target_guid = 200
v.units = { leader_unit(3, true, 500), on_murist, on_beru }
r = home.decide(v)
check(r.guid == 400, "the tank keeps the mob it already pulled off Beru")

-- ...but a fresh mob ON the healer still outranks the one in hand.
local new_on_beru = hostile(800, 700)
new_on_beru.distance = 6
new_on_beru.combat_distance = 6
v.units = { leader_unit(3, true, 500), on_murist, on_beru, new_on_beru }
r = home.decide(v)
check(r.guid == 800, "a fresh mob on Beru outranks an established pull")

-- Beru's whole live bar is Attack + Smite + Lesser Heal + Shoot, and Smite is
-- 15 mana a cast against a pool of about 250.
local function beru_frame(mana)
  local f = frame(5)
  f.party.members[1].name = "Beru"
  f.powers = { mana or 100, 0, 0, 0, 0 }
  f.max_powers = { 100, 0, 0, 0, 0 }
  f.in_combat = true
  f.units = { leader_unit(3, true, 300), hostile(300, 100) }
  f.action_buttons = { bar(585, "Smite"), bar(2050, "Lesser Heal"),
    bar(5019, "Shoot") }
  return f
end

home.reset()
v = beru_frame(100)
r = home.decide(v)
check(r.kind == "attack" and r.spell == 585 and r.reason == "priest_damage",
  "a full-mana healer still spends it on Smite")

home.reset()
v = beru_frame(50)
r = home.decide(v)
check(r.kind == "attack" and r.spell == 5019 and r.reason == "healer_wand",
  "a healer past the wand floor shoots for free instead of Smiting")

-- Shoot is an auto-repeat TOGGLE: pressing it while the wand is firing
-- cancels it, and the pilot presses whatever the intent names on a 0.4s
-- throttle with no guard of its own.
r = home.decide(v)
check(r.kind == "attack" and r.spell == nil and r.reason == "healer_wanding",
  "a wand we just started is never re-pressed")
v.action_buttons[3].active = true
v.simulation_time = 130
r = home.decide(v)
check(r.spell == nil and r.reason == "healer_wanding",
  "the client's own auto-repeat flag keeps the finger off the button")
v.action_buttons[3].active = false
r = home.decide(v)
check(r.spell == 5019, "a wand the client reports idle is re-pressed")

-- Under the conserve floor the healer stops PRESSING entirely: a press is the
-- one thing that can toggle a running wand off, and free wand damage is the
-- whole point of conserving.
home.reset()
v = beru_frame(15)
r = home.decide(v)
check(r.kind == "attack" and r.spell == nil and
  r.reason == "healer_conserve_mana",
  "a nearly-empty healer presses nothing and banks the rest for heals")
check(r.status.conserving == true, "conserving mana is visible in /status")

home.reset()
v = beru_frame(50)
r = home.decide(v)
check(r.status.conserving == false,
  "a healer with mana to spend is not flagged conserving")

-- Proactive mitigation. A shield has to be UP before the swing lands, so it
-- goes on the tank at 60% rather than racing the hit that takes him to 35.
home.reset()
v = beru_frame(100)
v.party.members[#v.party.members + 1] = member(700, "Tusk", 55, 8)
v.action_buttons = { bar(17, "Power Word: Shield"), bar(139, "Renew"),
  bar(2050, "Lesser Heal"), bar(585, "Smite") }
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 17 and r.target_guid == 700 and
  r.reason == "shield_tank",
  "healer shields the tank before he falls into emergency range")

-- Shielded and still being hit: Renew is upkeep, not a top-off.
v.party.members[3].active_aura_spell_ids = { 17 }
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 139 and r.target_guid == 700 and
  r.reason == "renew_tank", "healer keeps Renew ticking on the tank")

-- Somebody actually falling still outranks proactive tank upkeep.
v.party.members[2].health = 25
r = home.decide(v)
check(r.kind == "cast_spell" and r.target_guid == 100,
  "a member actually falling outranks proactive tank upkeep")

-- Fortitude is idle-window work and it has a RANGE: an unbuffed member across
-- the zone used to eat every idle tick as a cast into nothing.
home.reset()
v = frame(5)
v.party.members[1].name = "Beru"
v.party.members[1].active_aura_spell_ids = { 1243 }
v.active_aura_spell_ids = { 1243 }
v.party.members[2].location = { map_id = 0, x = 400, y = 0, z = 0 }
v.action_buttons = { bar(1243, "Power Word: Fortitude") }
r = home.decide(v)
check(not (r.kind == "cast_spell" and r.spell == 1243),
  "fortitude is not cast at a member across the zone")
v.party.members[2].location = { map_id = 0, x = 6, y = 0, z = 0 }
r = home.decide(v)
check(r.kind == "cast_spell" and r.spell == 1243 and r.target_guid == 100,
  "fortitude buffs the member standing next to the healer")

home.reset()
v = frame(4)
v.party.members[1].name = "Kamish"
v.in_combat = true
v.units = { leader_unit(3, true, 300), hostile(300, 100) }
v.action_buttons = {
  bar(1752, "Sinister Strike"), bar(2098, "Eviscerate"), bar(686, "Shadow Bolt"),
}
r = home.decide(v)
check(r.kind == "attack" and r.spell == 1752 and
  r.reason == "rogue_sinister_strike",
  "escort rogue fills with Sinister Strike, not Shadow Bolt")
check(r.stop_distance == 4.0, "escort rogue stops in melee")
v.action_buttons[1].usable = false
r = home.decide(v)
check(r.kind == "attack" and r.spell == nil and r.reason == "rogue_melee",
  "escort rogue auto-attacks when energy-starved")

wow.log = realLog

print("test_home: " .. checks .. " checks passed")
