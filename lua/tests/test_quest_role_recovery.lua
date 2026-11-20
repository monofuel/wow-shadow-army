-- 0152 v3 through the actual home.decide path: the solo/quest pipeline (and
-- the escort tank) fights with home's own class tactics, and a quest request
-- keeps its identity and bounds through the real death recovery branch.
--
-- Fixture shapes follow the projection (fork bots/lua_bot/view.nim):
-- spell rows use the typed spell_facts and action_buttons fields; the seat's
-- own health is health_known + health/max_health (unknown = false with both
-- zero, as an Observation default marshals); unit rows either OMIT
-- active_aura_spell_ids (the current native pushUnits, which never exports
-- it) or carry a dense id list with no extra known flag (the drafted
-- pushUnits export, where {} means no aura is shown on the unit). No
-- auras_known flag is invented for units. Ids, units, positions and quests
-- are synthetic. Cases print and count so old and new sources compare whole;
-- the exit status is nonzero on any failure. An intent here is not a cast,
-- an aura, damage or an objective credit.

local passed, failed = 0, 0
local function case(cond, name, intent)
  if cond then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print(string.format("FAIL %s  [%s %s spell=%s guid=%s stop=%s mode=%s]", name,
      tostring(intent and intent.kind), tostring(intent and intent.reason),
      tostring(intent and intent.spell), tostring(intent and (intent.guid or intent.target_guid)),
      tostring(intent and intent.stop_distance),
      tostring(intent and intent.status and intent.status.mode)))
  end
end

local clock = 0.0
local wall = 2000000000
_G.wow = { log = function() end, set_status = function() end, time = function() return clock end,
  nav_progress = function() return { state = "following" } end }

require("tests.lifecycle_fixture")
local requests = require("tools.requests")
requests.clock = function() return wall end
-- Each run owns a fresh directory from `mktemp -d` (under $TMPDIR when set,
-- else /tmp), so runs sharing a TMPDIR never inherit each other's request
-- receipts. Only that directory is removed: at the end, or by the finalizer
-- when the state closes after an error.
local owned = assert(io.popen("mktemp -d")):read("*l")
assert(owned and owned:match("^/[^']+$"), "mktemp -d gave no usable directory")
local function drop_scratch()
  if owned then os.execute("rm -rf '" .. owned .. "'") owned = nil end
end
local scratch_guard = setmetatable({}, { __gc = drop_scratch })
local dir = owned .. "/jobs"
assert(os.execute("mkdir '" .. dir .. "'"))
local rs = requests.new(dir)
requests.from_env = function() return rs end
local grind = require("accelerated")
local home = require("home")
home.set_roads({})
grind.set_quest_hubs({})
grind.set_objective_areas({})

local function write(path, body)
  local f = assert(io.open(path, "w")) f:write(body) f:close()
end
local function read(path)
  local f = io.open(path, "r") if not f then return nil end
  local b = f:read("*a") f:close() return b
end
local function receipts() return read(dir .. "/receipts.jsonl") or "" end
local function last_state(key)
  local state
  for line in receipts():gmatch("[^\n]+") do
    if line:find('"key":"' .. key .. '"', 1, true) then state = line:match('"state":"([^"]*)"') end
  end
  return state
end
local function key_lines(key, pattern)
  local n = 0
  for line in receipts():gmatch("[^\n]+") do
    if line:find('"key":"' .. key .. '"', 1, true) and line:find(pattern) then n = n + 1 end
  end
  return n
end

local SEAT = 1000052
local MOB = 901
local MOB_ENTRY = 7001

-- A hostile row WITHOUT active_aura_spell_ids: what the current native
-- pushUnits marshals for every unit.
local function mob(guid, extra)
  local u = { guid = guid, entry = MOB_ENTRY, name = "Synthetic Cull Target", distance = 3.0,
    combat_distance_known = true, combat_distance = 3.0,
    level_known = true, level = 4, player_can_attack = true, player_can_attack_known = true,
    death_known = true, is_dead = false, health_known = true, health = 40, max_health = 40,
    combat_known = true, is_in_combat = true, creature_rank_known = true, creature_rank = 0,
    creature_type_known = true, creature_type = 1, is_tapped = false, tapped_by_player = false,
    summoner_guid = 0, target_guid_known = true, target_guid = SEAT,
    location = { map_id = 0, position = { x = 103, y = 100, z = 10, o = 0 } } }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

local function fact(id, name, rank, extra)
  local f = { spell_id = id, name = name, name_known = true, rank = rank,
    rank_name = "Rank " .. rank, readiness = "ready", execution = "action_bar",
    execution_reason = "", bound_slot = 0, self_cast_executable = false,
    passive = false, from_item = false, usable_known = true, usable = true,
    not_enough_mana = false, control_blocked = false, power_cost_known = true,
    power_cost = 10, targeting_known = true, requires_hostile_target = true,
    range_known = true, range_min = 0, range_max = 30, in_range_known = true,
    in_range = true, active = false, cooldown_ms = 0, reagents_available = true,
    requires_equipped_item = false, equipped_item_requirement_known = true,
    equipped_item_requirement_met = true, requires_caster_aura_state = false,
    caster_aura_state_requirement_known = true, caster_aura_state_requirement_met = true,
    cast_time_ms = 0, next_melee_swing = false, intent_names = {}, cure_dispel_types = {} }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

local function kit(facts, bar_only)
  local known, buttons, slot = {}, {}, 0
  for _, f in ipairs(facts) do
    known[#known + 1] = f.spell_id
    if f.execution ~= "unavailable" then
      slot = slot + 1
      f.bound_slot = slot
      buttons[#buttons + 1] = { slot = slot, kind = "spell", bound = true,
        spell_id = f.spell_id, spell_name = f.name, name_known = f.name_known, rank = f.rank,
        rank_name = f.rank_name, passive = f.passive, from_item = f.from_item,
        reagents_available = f.reagents_available, usable_known = f.usable_known,
        usable = f.usable, in_range_known = f.in_range_known, in_range = f.in_range,
        cooldown_ms = f.cooldown_ms, not_enough_mana = f.not_enough_mana,
        power_cost_known = true, power_cost = f.power_cost, cast_time_ms = f.cast_time_ms,
        requires_hostile_target = f.requires_hostile_target, range_min = f.range_min,
        range_max = f.range_max, active = f.active, self_cast_ready = false }
    end
  end
  return { known_spells = known, spell_facts = bar_only and {} or facts,
    action_bar_known = true, action_buttons = buttons }
end

local SOLO = { in_group = false, leader_guid = 0, leader_name = "", invite_pending = false,
  invite_from = "", members = {} }

local function view(extra)
  local v = {
    simulation_time = clock, player_guid = SEAT, class_id = 1, level = 4, xp = 900,
    next_level_xp = 1800, copper = 0, copper_known = true,
    location_known = true, in_combat = true, is_dead = false, is_ghost = false,
    corpse_known = false, corpse_location = { map_id = 0, position = { x = 0, y = 0, z = 0 } },
    corpse_reclaim_delay_known = false, corpse_reclaim_delay_ms = 0,
    can_reclaim_corpse = false, resurrect_offer_guid = 0, movement_allowed = true,
    rooted = false, auto_attack_guid = MOB, selected_target_guid = MOB,
    active_cast_spell_id = 0, active_channel_spell_id = 0,
    health_known = true, health = 100, max_health = 100,
    powers = { 0, 300, 0, 0, 0 }, max_powers = { 0, 1000, 0, 0, 0 },
    active_aura_spell_ids = { 6673 }, combat_kill_events = {},
    location = { map_id = 0, position = { x = 100, y = 100, z = 10, o = 0 } },
    party = SOLO, units = { mob(MOB) }, known_spells = {}, spell_facts = {}, action_buttons = {},
    action_bar_known = true, cast_target_supported = true, self_cast_supported = true,
    pet = { guid_known = true, guid = 0 }, inventory_items = {}, equipment_items = {},
    ui_nodes = {}, quest_frame = { open = false }, quest_markers = {},
    accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
    rewarded_quest_ids = {},
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function merge(a, b)
  local out = {}
  for k, v in pairs(a or {}) do out[k] = v end
  for k, v in pairs(b or {}) do out[k] = v end
  return out
end

local function tick(t, extra)
  clock = t
  local v = view(extra)
  v.simulation_time = t
  return home.decide(v)
end

local function fresh(t, extra)
  home.reset()
  grind.reset()
  rs.active = nil
  return tick(t, extra)
end

-- Request windows for a spell over a frame sequence: a window is a run of
-- consecutive frames asking for it (the pilot's 1.5s press window).
local function windows(seq, spell)
  local n, starts, prev = 0, {}, false
  for k, r in ipairs(seq) do
    local now = r.intent and r.intent.spell == spell
    if now and not prev then n = n + 1 starts[#starts + 1] = r.at end
    prev = now
  end
  return n, starts
end

local function mana(pct) return { powers = { pct, 0, 0, 0, 0 }, max_powers = { 100, 0, 0, 0, 0 } } end
-- The seat's own health as the projection marshals an unknown bar.
local UNKNOWN_HEALTH = { health_known = false, health = 0, max_health = 0 }

local t = 100
local i

-- Warrior -----------------------------------------------------------------
local HS, SUNDER, SUNDER2, SUNDER3, SHOUT, CHARGE, REND = 78, 7386, 7405, 8380, 6673, 100, 772
local WARRIOR_KIT = { fact(HS, "Heroic Strike", 1), fact(SUNDER, "Sunder Armor", 1),
  fact(SUNDER2, "Sunder Armor", 2),
  fact(SUNDER3, "Sunder Armor", 3, { execution = "unavailable", execution_reason = "unbound" }) }

-- Unobserved row (current native): Sunder once on the engaged mob, then the
-- damage dump -- never Sunder every global cooldown.
t = t + 10
i = fresh(t, kit(WARRIOR_KIT))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == SUNDER2 and i.status.mode == "solo",
  "warrior solo, no unit aura facts: Sunder Armor once, highest executable rank", i)
i = tick(t + 0.6, kit(WARRIOR_KIT))
case(i and i.spell == SUNDER2, "warrior solo: the Sunder request survives the pilot's press window", i)
i = tick(t + 2.0, kit(WARRIOR_KIT))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == HS,
  "warrior solo: after the Sunder request, Heroic Strike (not Sunder again)", i)
-- The fight progresses (the mob's health falls), so the stack keeps it.
local again, dumps = 0, 0
for s = 3, 40 do
  local r = tick(t + s, merge(kit(WARRIOR_KIT),
    { units = { mob(MOB, { health = 100 - 2 * s, max_health = 100 }) } }))
  if r and (r.spell == SUNDER or r.spell == SUNDER2) then again = again + 1 end
  if r and r.kind == "attack" and r.guid == MOB and r.spell == HS then dumps = dumps + 1 end
end
case(again == 0 and dumps == 38,
  "warrior solo: 40s on the same unobserved mob, Heroic Strike every frame, no Sunder repeat", nil)

-- Closing frames do not spend the one request: it starts when the mob is
-- selected, engaged and within the stop distance.
t = t + 100
-- The seat walks in from 15 yards (1.5 yd/s here) toward a mob at x=115.
local function closing(s)
  local d = 15.0 - 1.5 * s
  return { auto_attack_guid = 0,
    location = { map_id = 0, position = { x = 100 + 1.5 * s, y = 100, z = 10, o = 0 } },
    units = { mob(MOB, { distance = d, combat_distance = d,
      location = { map_id = 0, position = { x = 115, y = 100, z = 10, o = 0 } } }) } }
end
local function engaged(s)
  return { location = { map_id = 0, position = { x = 112, y = 100, z = 10, o = 0 } },
    units = { mob(MOB, { health = 40 - s, location = { map_id = 0,
      position = { x = 115, y = 100, z = 10, o = 0 } } }) } }
end
i = fresh(t, merge(kit(WARRIOR_KIT), closing(0)))
for s = 1, 5 do i = tick(t + s, merge(kit(WARRIOR_KIT), closing(s))) end
case(i and i.spell == SUNDER2, "warrior solo: five closing seconds keep Sunder requested", i)
i = tick(t + 6, merge(kit(WARRIOR_KIT), engaged(1)))
i = tick(t + 8, merge(kit(WARRIOR_KIT), engaged(2)))
case(i and i.spell == HS, "warrior solo: engaged at last, Sunder requested once then Heroic Strike", i)

-- Observed rows (the drafted unit aura export): presence decides.
t = t + 100
i = fresh(t, merge(kit(WARRIOR_KIT), { units = { mob(MOB, { active_aura_spell_ids = {} }) } }))
case(i and i.spell == SUNDER2, "warrior solo, observed no aura: Sunder Armor is applied", i)
for s = 1, 5 do
  i = tick(t + s, merge(kit(WARRIOR_KIT),
    { units = { mob(MOB, { active_aura_spell_ids = { SUNDER2 }, health = 40 - s }) } }))
end
case(i and i.spell == HS, "warrior solo, observed Sunder present: no refresh/overcap, Heroic Strike", i)
local gone_early = true
for s = 6, 9 do
  local r = tick(t + s, merge(kit(WARRIOR_KIT),
    { units = { mob(MOB, { active_aura_spell_ids = {}, health = 40 - s }) } }))
  if not (r and r.spell == HS) then gone_early = false end
end
i = tick(t + 10, merge(kit(WARRIOR_KIT),
  { units = { mob(MOB, { active_aura_spell_ids = {}, health = 30 }) } }))
case(gone_early and i and i.spell == SUNDER2,
  "warrior solo, observed Sunder gone (fell off/dodged): requested again after the 10s retry, " ..
  "not on every frame", i)

t = t + 100
i = fresh(t, merge(kit({ fact(HS, "Heroic Strike", 1, { active = true }), fact(SUNDER, "Sunder Armor", 1) }),
  { units = { mob(MOB, { active_aura_spell_ids = { SUNDER } }) } }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == nil and i.reason == "tank_swing_queued",
  "warrior solo: a queued Heroic Strike is held, not re-pressed (no cancel)", i)

t = t + 10
i = fresh(t, kit({ fact(REND, "Rend", 1), fact(HS, "Heroic Strike", 1) }))
i = tick(t + 2, kit({ fact(REND, "Rend", 1), fact(HS, "Heroic Strike", 1) }))
case(i and i.spell == HS, "warrior solo, unobserved: Rend once per mob, then Heroic Strike", i)

-- An observed row that never shows Rend (immune or resisting): Rend gets a
-- bounded retry, never every global cooldown, and Heroic Strike keeps the damage.
t = t + 10
local rend_kit = { fact(REND, "Rend", 1), fact(HS, "Heroic Strike", 1) }
local rend_seq = {}
home.reset()
grind.reset()
for s = 0, 59 do
  local at = t + s * 0.5
  rend_seq[#rend_seq + 1] = { at = at, intent = tick(at, merge(kit(rend_kit),
    { units = { mob(MOB, { active_aura_spell_ids = {}, health = 100 - s, max_health = 100 }) } })) }
end
local rend_windows, rend_starts = windows(rend_seq, REND)
local rend_hs = 0
for _, r in ipairs(rend_seq) do
  if r.intent and r.intent.kind == "attack" and r.intent.guid == MOB and r.intent.spell == HS then
    rend_hs = rend_hs + 1
  end
end
case(rend_windows == 3 and rend_starts[2] - rend_starts[1] >= 10 and rend_hs >= 45,
  "warrior solo, observed row never shows Rend for 30s: 3 bounded attempts, Heroic Strike between", nil)

t = t + 10
i = fresh(t, kit({ fact(HS, "Heroic Strike", 1, { not_enough_mana = true, usable = false,
    readiness = "resources" }),
  fact(SUNDER, "Sunder Armor", 1, { not_enough_mana = true, usable = false, readiness = "resources" }) }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == nil,
  "warrior solo control: no rage, nothing unaffordable is pressed", i)

t = t + 10
i = fresh(t, kit({ fact(HS, "Heroic Strike", 1),
  fact(SUNDER2, "Sunder Armor", 2, { cooldown_ms = 1500, readiness = "cooldown" }),
  fact(SUNDER, "", 1, { name_known = false }) }))
case(i and i.kind == "attack" and i.spell == HS,
  "warrior solo control: a cooling-down rank and an unnamed row are never chosen", i)

t = t + 10
i = fresh(t, merge(kit({ fact(SHOUT, "Battle Shout", 1, { requires_hostile_target = false }),
  fact(SUNDER, "Sunder Armor", 1) }), { active_aura_spell_ids = {} }))
case(i and i.kind == "cast_spell" and i.spell == SHOUT and i.target_guid == nil,
  "warrior solo: missing Battle Shout is the class's self buff in the fight", i)

t = t + 10
local friendly = mob(950, { name = "Synthetic Guard", player_can_attack = false,
  target_guid = 0, distance = 2.0, combat_distance = 2.0 })
local other = mob(902, { distance = 30.0, combat_distance = 30.0, target_guid = 0,
  is_in_combat = false })
i = fresh(t, merge(kit({ fact(SUNDER, "Sunder Armor", 1) }),
  { selected_target_guid = 950, units = { friendly, mob(MOB), other } }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == SUNDER,
  "warrior solo: the stack's own target, never the friendly selection or another mob", i)

t = t + 10
i = fresh(t, merge(kit({ fact(CHARGE, "Charge", 1, { range_min = 8, range_max = 25 }),
  fact(SUNDER, "Sunder Armor", 1) }), { in_combat = false, auto_attack_guid = 0,
  selected_target_guid = 0, units = { mob(MOB, { distance = 15.0, combat_distance = 15.0,
    target_guid = 0, is_in_combat = false }) } }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == CHARGE,
  "warrior solo control: an out-of-combat pull in range still opens with Charge", i)

t = t + 10
i = fresh(t, merge(kit({ fact(SUNDER, "Sunder Armor", 1) }), { health = 10 }))
case(i and i.reason == "survive_flee", "warrior solo control: survival still outranks the tactic", i)

-- The same tank rotation in the existing party escort (Tusk with Murist),
-- on the current native unit rows: Sunder is requested once, not spammed.
local function escort_tank(at)
  return tick(at, merge(kit(WARRIOR_KIT), {
    level = 10, party = { in_group = true, leader_guid = 100, leader_name = "Murist",
      invite_pending = false, invite_from = "", members = {
        { guid = SEAT, name = "Tusk", health_known = true, health = 100, max_health = 100,
          level_known = true, level = 10, death_state_known = true, is_dead = false,
          is_ghost = false, active_auras_known = true, active_aura_spell_ids = { 6673 },
          location_known = true, elevation_known = true,
          location = { map_id = 0, x = 100, y = 100, z = 10 } },
        { guid = 100, name = "Murist", leader = true, health_known = true, health = 100,
          max_health = 100, level_known = true, level = 10, death_state_known = true,
          is_dead = false, is_ghost = false, active_auras_known = true,
          active_aura_spell_ids = {}, location_known = true, elevation_known = true,
          location = { map_id = 0, x = 102, y = 100, z = 10 } } } },
    units = { { guid = 100, name = "Murist", is_player_controlled = true,
      player_can_attack = false, death_known = true, is_dead = false, combat_known = true,
      is_in_combat = true, target_guid_known = true, target_guid = MOB, distance = 2,
      location = { map_id = 0, position = { x = 102, y = 100, z = 10 } } }, mob(MOB) } }))
end
t = t + 100
home.reset()
grind.reset()
local escort_first = escort_tank(t)
local escort_sunders = (escort_first and escort_first.spell == SUNDER2) and 1 or 0
local escort_hs = 0
for s = 2, 20 do
  local r = escort_tank(t + s)
  if r and r.spell == SUNDER2 then escort_sunders = escort_sunders + 1 end
  if r and r.spell == HS then escort_hs = escort_hs + 1 end
end
case(escort_first and escort_first.status.mode == "escort" and escort_first.spell == SUNDER2 and
  escort_sunders == 1 and escort_hs >= 15,
  "escort tank on unobserved rows: one Sunder request, then Heroic Strike (was: every GCD)",
  escort_first)

-- Priest ------------------------------------------------------------------
local SMITE, SMITE2, BLAST, PAIN, SHOOT, FLASH = 585, 591, 8092, 589, 5019, 2061
local function priest(extra, facts, bar_only)
  return merge(merge({ class_id = 5, active_aura_spell_ids = {} }, kit(facts, bar_only)), extra)
end
local WAND_ON = { active = true, requires_equipped_item = true }
local WAND_IDLE = { requires_equipped_item = true }
local NO_WAND = { requires_equipped_item = true, equipped_item_requirement_met = false,
  usable = false, readiness = "equipped_item" }
local OOM = { not_enough_mana = true, usable = false, readiness = "resources" }

t = t + 10
i = fresh(t, priest(mana(90), { fact(SMITE, "Smite", 1), fact(SMITE2, "Smite", 2),
  fact(BLAST, "Mind Blast", 1), fact(PAIN, "Shadow Word: Pain", 1) }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == PAIN,
  "priest solo, unobserved: Shadow Word: Pain requested once on the engaged mob", i)
i = tick(t + 2, priest(mana(90), { fact(SMITE, "Smite", 1), fact(SMITE2, "Smite", 2),
  fact(BLAST, "Mind Blast", 1), fact(PAIN, "Shadow Word: Pain", 1) }))
case(i and i.spell == BLAST,
  "priest solo: then Mind Blast, kept over the Smite rank upgrade (no SW:P repeat)", i)
i = fresh(t + 5, priest(merge(mana(90), { units = { mob(MOB, { active_aura_spell_ids = { PAIN } }) } }),
  { fact(SMITE2, "Smite", 2), fact(PAIN, "Shadow Word: Pain", 1) }))
case(i and i.spell == SMITE2, "priest solo, observed SW:P present: no refresh, Smite", i)

t = t + 10
i = fresh(t, priest(mana(90), { fact(SMITE, "Smite", 1), fact(SMITE2, "Smite", 2),
  fact(BLAST, "Mind Blast", 1, { cooldown_ms = 6000, readiness = "cooldown" }) }))
case(i and i.kind == "attack" and i.spell == SMITE2,
  "priest solo control: Mind Blast cooling down, Smite at the highest executable rank", i)

t = t + 10
i = fresh(t, priest(mana(50), { fact(SMITE2, "Smite", 2), fact(SHOOT, "Shoot", 1, WAND_ON) }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == nil and i.reason == "healer_wanding",
  "priest solo 50%: a running wand is not interrupted", i)

t = t + 10
i = fresh(t, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM), fact(SHOOT, "Shoot", 1, WAND_ON) }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == nil and i.stop_distance == 22.0 and
  i.reason == "healer_wanding",
  "priest solo <20% mana, wand firing: keeps the wand at 22yd, no 4yd melee close", i)

t = t + 10
i = fresh(t, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM), fact(SHOOT, "Shoot", 1, WAND_IDLE) }))
local first_wand = i
i = tick(t + 0.5, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM), fact(SHOOT, "Shoot", 1, WAND_IDLE) }))
case(first_wand and first_wand.spell == SHOOT and first_wand.stop_distance == 22.0 and
  i and i.spell == nil and i.reason == "healer_wanding",
  "priest solo <20% mana, equipped idle wand: one Shoot press, then no re-press", i)

t = t + 10
i = fresh(t, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM), fact(SHOOT, "Shoot", 1, NO_WAND) }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == nil and (i.stop_distance or 99) <= 5,
  "priest solo <20% mana, no wand: the stack's melee, not a 22-yard idle stand", i)

-- The client reports the wand running while its button reads a cooldown or
-- unusable for a frame: the running Shoot is held, never melee, never a press.
local function holds(r, who)
  return r and r.kind == "attack" and r.guid == MOB and r.spell == nil and
    r.stop_distance == 22.0 and r.reason == who .. "_wanding"
end
local function melee(r)
  return r and r.kind == "attack" and r.guid == MOB and r.spell == nil and
    (r.stop_distance or 99) <= 5
end
local ON_COOLING = merge(WAND_ON, { cooldown_ms = 1500, readiness = "cooldown" })
local ON_UNUSABLE = merge(WAND_ON, { usable = false, readiness = "unusable" })
t = t + 10
local a = fresh(t, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM), fact(SHOOT, "Shoot", 1, ON_COOLING) }))
local b = tick(t + 0.5, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM),
  fact(SHOOT, "Shoot", 1, ON_UNUSABLE) }))
local c = tick(t + 1.0, priest(mana(15), { fact(SMITE2, "Smite", 2, OOM),
  fact(SHOOT, "Shoot", 1, ON_COOLING) }, true))
case(holds(a, "healer") and holds(b, "healer") and holds(c, "healer"),
  "priest solo <20% mana, wand running with a cooldown/unusable button (facts and bar): " ..
  "22yd, no press", c)

-- Just pressed, not yet latched active, readiness flickers: held on the
-- same mob. A wand that really is gone returns the seat to melee.
local IDLE_COOLING = merge(WAND_IDLE, { cooldown_ms = 1500, readiness = "cooldown" })
local IDLE_UNUSABLE = merge(WAND_IDLE, { usable = false, readiness = "unusable" })
local function shoot_kit(extra, bar_only)
  return priest(mana(15), { fact(SMITE2, "Smite", 2, OOM), fact(SHOOT, "Shoot", 1, extra) }, bar_only)
end
t = t + 10
a = fresh(t, shoot_kit(WAND_IDLE))
b = tick(t + 0.5, shoot_kit(IDLE_COOLING))
c = tick(t + 1.0, shoot_kit(IDLE_UNUSABLE))
case(a and a.spell == SHOOT and holds(b, "healer") and holds(c, "healer"),
  "priest solo: Shoot just pressed, button cooldown/unusable before it latches: held, no re-press", c)
i = tick(t + 1.5, shoot_kit(NO_WAND))
case(melee(i), "priest solo: just pressed but the wand is known unequipped: melee at once", i)
t = t + 10
fresh(t, shoot_kit(WAND_IDLE))
i = tick(t + 0.5, shoot_kit({ requires_equipped_item = true, execution = "unavailable",
  execution_reason = "unbound" }))
case(melee(i), "priest solo: just pressed but Shoot is no longer bound: melee at once", i)
t = t + 10
fresh(t, shoot_kit(WAND_IDLE, true))
b = tick(t + 1.0, shoot_kit(IDLE_UNUSABLE, true))
c = tick(t + 3.5, shoot_kit(IDLE_UNUSABLE, true))
case(holds(b, "healer") and melee(c),
  "priest solo, bar only: a press that never runs and stays unusable returns to melee after 3s", c)

-- Warlock -----------------------------------------------------------------
local BOLT, BOLT2, CORRUPTION, AGONY, TAP = 686, 695, 172, 980, 1454
local function warlock(extra, facts)
  return merge(merge({ class_id = 9, active_aura_spell_ids = {} }, kit(facts)), extra)
end
local TAP_FACT = fact(TAP, "Life Tap", 1, { requires_hostile_target = false })

t = t + 10
i = fresh(t, warlock(mana(10), { TAP_FACT, fact(BOLT, "Shadow Bolt", 1, OOM) }))
case(i and i.kind == "cast_spell" and i.spell == TAP and i.target_guid == nil,
  "warlock solo, known healthy: Life Tap funds an empty bar mid-fight", i)

t = t + 10
i = fresh(t, warlock(merge(mana(10), UNKNOWN_HEALTH),
  { TAP_FACT, fact(BOLT, "Shadow Bolt", 1, OOM), fact(SHOOT, "Shoot", 1, WAND_ON) }))
case(i and i.kind == "attack" and i.guid == MOB and i.spell == nil and i.reason == "warlock_wanding",
  "warlock solo, health unknown: no Life Tap; the running wand keeps firing", i)

t = t + 10
i = fresh(t, warlock(merge(mana(10), UNKNOWN_HEALTH), { TAP_FACT, fact(BOLT, "Shadow Bolt", 1, OOM) }))
local held = 0
for s = 1, 10 do
  local r = tick(t + s, warlock(merge(mana(10), merge(UNKNOWN_HEALTH,
    { units = { mob(MOB, { health = 40 - 3 * s }) } })),
    { TAP_FACT, fact(BOLT, "Shadow Bolt", 1, OOM) }))
  if not (r and r.kind == "attack" and r.guid == MOB and r.spell == nil and
      (r.stop_distance or 99) <= 5) then held = held + 1 end
  if r and r.spell == TAP then held = held + 100 end
end
case(i and i.kind == "attack" and i.spell == nil and (i.stop_distance or 99) <= 5 and held == 0,
  "warlock solo, health unknown, no wand: never Life Tap, the stack's melee every frame", i)

t = t + 10
local idle_kit = { fact(BOLT, "Shadow Bolt", 1, OOM), fact(SHOOT, "Shoot", 1, WAND_IDLE) }
local presses = 0
i = fresh(t, warlock(mana(30), idle_kit))
if i and i.spell == SHOOT then presses = presses + 1 end
for s = 1, 5 do
  local r = tick(t + s * 0.4, warlock(mana(30), idle_kit))
  if r and r.spell == SHOOT then presses = presses + 1 end
end
local on_kit = { fact(BOLT, "Shadow Bolt", 1, OOM), fact(SHOOT, "Shoot", 1, WAND_ON) }
for s = 3, 12 do
  local r = tick(t + s, warlock(mana(30), on_kit))
  if r and r.spell == SHOOT then presses = presses + 1 end
end
case(i and i.spell == SHOOT and i.reason == "warlock_wand" and i.stop_distance == 22.0 and presses == 1,
  "warlock solo, Shadow Bolt unaffordable: Shoot pressed once, never toggled off", i)

t = t + 10
local dot_kit = { fact(CORRUPTION, "Corruption", 1), fact(AGONY, "Curse of Agony", 1),
  fact(BOLT, "Shadow Bolt", 1), fact(BOLT2, "Shadow Bolt", 2) }
i = fresh(t, warlock(mana(80), dot_kit))
local seq = { i and i.spell }
for s = 2, 8, 2 do
  local r = tick(t + s, warlock(mana(80), dot_kit))
  seq[#seq + 1] = r and r.spell
end
case(seq[1] == AGONY and seq[2] == CORRUPTION and seq[3] == BOLT2 and seq[4] == BOLT2 and
  seq[5] == BOLT2,
  "warlock solo, unobserved: Curse of Agony and Corruption once each, then Shadow Bolt r2", i)
i = fresh(t + 20, warlock(merge(mana(80), { units = { mob(MOB,
  { active_aura_spell_ids = { AGONY, CORRUPTION } }) } }), dot_kit))
case(i and i.spell == BOLT2, "warlock solo, observed DoTs present: no recast, Shadow Bolt r2", i)

-- 30s at a GCD cadence on one mob whose observed aura list stays empty
-- (immune or resisting): the first DoT cannot take every global cooldown.
local function dot_run(start, frames, step, ids)
  home.reset()
  grind.reset()
  local seq = {}
  for s = 0, frames - 1 do
    local at = start + s * step
    seq[#seq + 1] = { at = at, intent = tick(at, warlock(merge(mana(80), { units = { mob(MOB,
      { active_aura_spell_ids = ids, health = 1000 - s, max_health = 1000 }) } }), dot_kit)) }
  end
  return seq
end
local function bolts(seq)
  local n = 0
  for _, r in ipairs(seq) do
    if r.intent and r.intent.kind == "attack" and r.intent.guid == MOB and
        r.intent.spell == BOLT2 then n = n + 1 end
  end
  return n
end
t = t + 100
local empty_seq = dot_run(t, 60, 0.5, {})
local agony_w, agony_at = windows(empty_seq, AGONY)
local corr_w = windows(empty_seq, CORRUPTION)
case(agony_w == 3 and agony_at[2] - agony_at[1] >= 10 and corr_w == 3 and bolts(empty_seq) >= 40,
  "warlock solo, observed empty for 30s: Curse of Agony/Corruption 3 bounded attempts each, " ..
  "Shadow Bolt between", nil)
t = t + 100
local up_seq = dot_run(t, 60, 0.5, { AGONY, CORRUPTION })
case(windows(up_seq, AGONY) == 0 and windows(up_seq, CORRUPTION) == 0 and bolts(up_seq) == 60,
  "warlock solo, observed DoTs present for 30s: never refreshed, Shadow Bolt every frame", nil)
t = t + 100
local old_seq = dot_run(t, 140, 0.5, nil)
local old_w, old_at = windows(old_seq, AGONY)
case(old_w == 2 and old_at[2] - old_at[1] >= 60 and bolts(old_seq) >= 120,
  "warlock solo, host without the aura field for 70s: one request, another only after 60s", nil)

t = t + 10
i = fresh(t, warlock(mana(30), { fact(BOLT, "Shadow Bolt", 1, { cooldown_ms = 1500,
  readiness = "cooldown" }), fact(SHOOT, "Shoot", 1, ON_COOLING) }))
case(holds(i, "warlock"),
  "warlock solo, Shadow Bolt and Shoot both on the cooldown, wand running: 22yd, no press", i)

t = t + 30
local IMP = 3001
i = fresh(t, warlock(merge(mana(80), { pet = { guid_known = true, guid = IMP },
    units = { mob(MOB), mob(IMP, { entry = 416, name = "Imp", player_can_attack = false,
      summoner_guid = SEAT, target_guid = 0, is_in_combat = false }) } }),
  { fact(BOLT2, "Shadow Bolt", 2) }))
case(i and i.kind == "attack" and i.guid == MOB and i.pet_attack == true,
  "warlock solo control: the pet is sent with the class attack", i)

-- Other classes keep the solo stack --------------------------------------
t = t + 10
i = fresh(t, merge(merge({ class_id = 11, active_aura_spell_ids = {} }, kit({
  fact(5176, "Wrath", 1), fact(5177, "Wrath", 2) })), mana(80)))
case(i and i.kind == "attack" and i.spell == 5177 and not tostring(i.reason):find("warlock"),
  "druid control: the stack's Wrath, no warlock rotation wiring", i)
t = t + 10
i = fresh(t, merge(merge({ class_id = 4, active_aura_spell_ids = {} }, kit({
  fact(1752, "Sinister Strike", 1) })), {}))
case(i and i.kind == "attack" and i.spell == 1752 and tostring(i.reason):find("^grind"),
  "rogue control: the stack's Sinister Strike, unchanged", i)
t = t + 10
i = fresh(t, merge(merge({ class_id = 8, active_aura_spell_ids = {} }, kit({
  fact(133, "Fireball", 1) })), mana(80)))
case(i and i.kind == "attack" and i.spell == 133 and tostring(i.reason):find("^mage"),
  "mage control: the stack's mage line, unchanged", i)

-- A quest request -----------------------------------------------------------
local ACCEPTED = { { quest_id = 100, title = "Synthetic Cull", level = 4, failed = false } }
local function cull(current)
  return { { quest_id = 100, entry = MOB_ENTRY, item_id = 0, text = "Synthetic Cull Target",
    current = current, required = 10, complete = false } }
end
local function job(key, choice)
  return string.format('{"key":"%s","origin":"whisper","actor":"Owner","actor_guid":"100",' ..
    '"choice":"%s","intent":"action","reply":"","x":0,"y":0,"z":10,"map_id":0}\n', key, choice)
end
local function start(key, at, extra)
  home.reset()
  grind.reset()
  rs.last_poll = nil
  write(dir .. "/inbox.json", job(key, "do_quests"))
  return tick(at, extra)
end
local function quest(extra)
  return merge({ accepted_quests = ACCEPTED, quest_objectives = cull(2) }, extra)
end

t = 1000
i = start("r1", t, quest(kit({ fact(HS, "Heroic Strike", 1), fact(SUNDER, "Sunder Armor", 1) })))
local r1b = tick(t + 2, quest(kit({ fact(HS, "Heroic Strike", 1), fact(SUNDER, "Sunder Armor", 1) })))
case(i and i.status.mode == "request" and i.kind == "attack" and i.guid == MOB and
  i.spell == SUNDER and r1b and r1b.status.mode == "request" and r1b.spell == HS,
  "warrior request: the quest's own pull Sunders once, then Heroic Strike", r1b)

local OWNER = 100
local party = { in_group = true, leader_guid = OWNER, leader_name = "Murist", invite_pending = false,
  invite_from = "", members = {
    { guid = OWNER, name = "Murist", health_known = true, health = 20, max_health = 100,
      level_known = true, level = 4, death_state_known = true, is_dead = false, is_ghost = false,
      active_auras_known = true, active_aura_spell_ids = {}, location_known = true,
      elevation_known = true, location = { map_id = 0, x = 110, y = 100, z = 10 } } } }
i = tick(t + 3, quest(priest(merge(mana(90), { party = party }), { fact(BLAST, "Mind Blast", 1),
  fact(FLASH, "Flash Heal", 1, { requires_hostile_target = false, requires_friendly_target = true }) })))
case(i and i.status.mode == "request" and i.kind == "cast_spell" and i.spell == FLASH and
  i.target_guid == OWNER, "priest request control: a falling party member is healed first", i)
rs.active = nil
os.remove(dir .. "/active.json")

-- Real recovery -------------------------------------------------------------
local CORPSE = { x = 560, y = 100, z = 10 }
local function dead(at)
  return tick(at, { is_dead = true, is_ghost = false, in_combat = false, auto_attack_guid = 0,
    selected_target_guid = 0, health = 0, units = {}, accepted_quests = {},
    quest_objectives = {}, rewarded_quest_ids = {} })
end
local function ghost(at, x, extra)
  return tick(at, merge({ is_dead = true, is_ghost = true, in_combat = false, auto_attack_guid = 0,
    selected_target_guid = 0, health = 1, units = {},
    location = { map_id = 0, position = { x = x, y = 100, z = 10, o = 0 } },
    corpse_known = true, corpse_location = { map_id = 0, position = CORPSE },
    accepted_quests = {}, quest_objectives = {}, rewarded_quest_ids = {} }, extra))
end
local function alive_at_corpse(at, extra)
  return tick(at, quest(merge({ in_combat = false, auto_attack_guid = 0, selected_target_guid = 0,
    location = { map_id = 0, position = { x = CORPSE.x, y = CORPSE.y, z = 10, o = 0 } },
    units = { mob(MOB, { target_guid = 0, is_in_combat = false, location = { map_id = 0,
      position = { x = CORPSE.x + 3, y = CORPSE.y, z = 10, o = 0 } } }) } }, extra)))
end
-- The client's reclaim countdown (view.nim corpse_reclaim_delay_*): known and
-- positive while the server still holds the reclaim, cleared when it may.
local function delay(ms) return { corpse_reclaim_delay_known = true, corpse_reclaim_delay_ms = ms } end

-- A genuine corpse run longer than the idle bound resumes the same quest.
t = 2000
start("r2", t, quest())
tick(t + 20, quest({ quest_objectives = cull(3) }))
local died = t + 40
for s = died, died + 21 do dead(s) end
local x, seenRecovery, allRecovery = 0, 0, true
for s = died + 22, died + 160 do
  local g = ghost(s, x)
  if g and g.status and g.status.mode == "recovery" and
      tostring(g.reason):find("^corpse_run") then seenRecovery = seenRecovery + 1 end
  if not (g and g.status and g.status.mode == "recovery") then allRecovery = false end
  x = math.min(x + 4, CORPSE.x - 25)
end
case(seenRecovery > 100 and allRecovery,
  "fixture: the ghost frames really take the production corpse-run branch", nil)
i = ghost(died + 161, CORPSE.x - 25, { can_reclaim_corpse = true })
case(i and i.kind == "reclaim" and i.status.mode == "recovery",
  "recovery control: the reclaim stays the recovery's own verb", i)
i = alive_at_corpse(died + 162)
case(last_state("r2") == "progress" and i and i.status.mode == "request" and i.kind == "attack" and
  i.guid == MOB, "after a 160s+ moving corpse run and reclaim the quest resumes, not idle-failed", i)
case(key_lines("r2", "left the log") == 0 and key_lines("r2", "accepted quest 100") == 0,
  "the ghost's empty quest lists are not read as an abandon or a fresh accept", nil)

-- A real reclaim delay at the corpse: the server holds the ghost 120s.
t = 2500
start("r2d", t, quest())
tick(t + 20, quest({ quest_objectives = cull(3) }))
died = t + 40
for s = died, died + 21 do dead(s) end
x = 0
for s = died + 22, died + 60 do ghost(s, x) x = math.min(x + 15, CORPSE.x - 25) end
local waiting = true
for s = died + 61, died + 180 do
  local g = ghost(s, CORPSE.x - 25, delay((died + 181 - s) * 1000))
  if not (g and g.status.mode == "recovery" and g.kind ~= "reclaim") then waiting = false end
end
case(waiting and last_state("r2d") ~= "failed",
  "a 120s server reclaim delay inside the reclaim radius: recovery holds, job not failed", nil)
i = ghost(died + 181, CORPSE.x - 25, merge(delay(0), { can_reclaim_corpse = true }))
case(i and i.kind == "reclaim", "the delay over, recovery reclaims", i)
i = alive_at_corpse(died + 182)
case(last_state("r2d") == "progress" and i and i.status.mode == "request" and i.guid == MOB,
  "after the bounded reclaim wait the same quest resumes", i)

-- Standing in the radius WITHOUT a known positive delay is not a wait.
t = 2800
start("r2n", t, quest())
for s = t + 1, t + 21 do dead(s) end
for s = t + 22, t + 40 do ghost(s, CORPSE.x - 25) end
for s = t + 41, t + 180 do ghost(s, CORPSE.x - 25, { corpse_reclaim_delay_known = false }) end
alive_at_corpse(t + 181)
case(last_state("r2n") == "failed" and receipts():find('"key":"r2n"[^\n]-no reachable quest work'),
  "a ghost at its corpse with no known reclaim delay is idle, not waiting", nil)

-- A ghost that stands still is not progress.
t = 3000
start("r3", t, quest())
for s = t + 1, t + 21 do dead(s) end
for s = t + 22, t + 220 do ghost(s, 0) end
alive_at_corpse(t + 221)
case(last_state("r3") == "failed" and receipts():find('"key":"r3"[^\n]-no reachable quest work'),
  "a stationary ghost comes back already idle and the job ends", nil)

-- A ghost that never comes back is bounded while still a ghost.
t = 4000
start("r4", t, quest())
for s = t + 1, t + 21 do dead(s) end
local last
for s = t + 22, t + 500 do last = ghost(s, 0) end
case(last_state("r4") == "failed" and receipts():find('"key":"r4"[^\n]-during death recovery'),
  "a ghost stuck for 500s ends the request at the existing stall bound", nil)
case(last and last.status.mode == "recovery" and tostring(last.reason):find("^corpse_run"),
  "and the recovery keeps the seat after the job ends", last)

-- An endless reclaim delay is still bounded by the stall limit.
t = 4600
start("r4d", t, quest())
for s = t + 1, t + 21 do dead(s) end
for s = t + 22, t + 500 do ghost(s, CORPSE.x - 25, delay(60000)) end
case(last_state("r4d") == "failed" and receipts():find('"key":"r4d"[^\n]-during death recovery'),
  "a reclaim delay that never ends still stops at the 420s stall bound", nil)

-- The original wall deadline holds across a restart during death.
t = 5000
wall = 2000000000
start("r5", t, quest())
wall = wall + 1790
local reload = requests.new(dir)
for k in pairs(rs) do rs[k] = nil end
for k, val in pairs(reload) do rs[k] = val end
home.reset()
for s = t + 1, t + 21 do dead(s) end
for s = t + 22, t + 40 do ghost(s, 0) end
case(receipts():find('"key":"r5"[^\n]-"state":"resumed"') ~= nil,
  "a restart during death resumes the same job", nil)
case(last_state("r5") == "failed" and
  receipts():find('"key":"r5"[^\n]-request window of 1800s ended during death recovery'),
  "the original 1800s window ends it during recovery, not a fresh deadline", nil)
case(key_lines("r5", "quest baseline") == 1,
  "no second baseline is taken from the ghost after the restart", nil)

-- An owner's stop sent during recovery waits, then supersedes the quest.
t = 6000
start("r6", t, quest())
for s = t + 1, t + 21 do dead(s) end
ghost(t + 22, 0)
write(dir .. "/inbox.json", job("r6stop", "resume"))
i = ghost(t + 24, 4)
case(i and i.status.mode == "recovery" and tostring(i.reason):find("^corpse_run") and
  read(dir .. "/inbox.json") ~= nil and last_state("r6") ~= "superseded",
  "a stop arriving during recovery does not take the ghost's frame", i)
i = alive_at_corpse(t + 30)
case(last_state("r6") == "superseded" and last_state("r6stop") == "done" and
  i and i.status.mode ~= "request",
  "on return the queued stop supersedes the quest job", i)

-- A reward witness seen while dead is acknowledged once, by the living seat.
t = 7000
start("r7", t, quest())
for s = t + 1, t + 21 do dead(s) end
ghost(t + 22, 0, { rewarded_quest_ids = { 100 } })
local during = key_lines("r7", "turned in quest 100")
alive_at_corpse(t + 30, { rewarded_quest_ids = { 100 } })
alive_at_corpse(t + 31, { rewarded_quest_ids = { 100 } })
case(during == 0 and key_lines("r7", "turned in quest 100") == 1,
  "a turn-in is acknowledged exactly once, from a living view", nil)

-- Default seat with no request directory: recovery is untouched.
t = 8000
local saved_dir = rs.dir
rs.dir = nil
rs.active = nil
home.reset()
for s = t + 1, t + 21 do dead(s) end
i = ghost(t + 22, 0)
rs.dir = saved_dir
case(i and i.status.mode == "recovery" and tostring(i.reason):find("^corpse_run"),
  "default control: no request directory, the corpse run is the same", i)

-- A trainer retry inside a quest request ----------------------------------
-- A level-10 warrior out of combat with a quest objective unfinished and its
-- mob in view; the class trainer is in reach (300 yd) but not in view. The
-- first visit after a cold start walks and times out unsettled (the fixture
-- seat walks slowly and never sees the trainer). The retry 300s later must
-- not walk off the objective again; with the trainer in view it is taken.
-- The trainer's synthetic spot is added here, far from every earlier case.
require("data.bot_lifecycle_positions").creatures[2119] = { map = 0, x = 1700.0, y = 100.0, z = 10.0 }
local TRAINER_ENTRY, TRAINER = 2119, 905
local L10_KIT = { fact(284, "Heroic Strike", 2), fact(REND, "Rend", 1), fact(CHARGE, "Charge", 1),
  fact(6343, "Thunder Clap", 1, { requires_hostile_target = false }),
  fact(SHOUT, "Battle Shout", 1, { requires_hostile_target = false }) }
local function field_quest(at_x, current, hp, extra)
  return merge(merge(kit(L10_KIT), {
    level = 10, copper = 1500, in_combat = false, auto_attack_guid = 0, selected_target_guid = 0,
    location = { map_id = 0, position = { x = at_x, y = 100, z = 10, o = 0 } },
    units = { mob(MOB, { target_guid = 0, is_in_combat = false, health = hp, max_health = 100,
      distance = math.abs(at_x - 1406) + 1, combat_distance = math.abs(at_x - 1406) + 1,
      location = { map_id = 0, position = { x = 1406, y = 100, z = 10, o = 0 } } }) },
    accepted_quests = ACCEPTED,
    quest_objectives = { { quest_id = 100, entry = MOB_ENTRY, item_id = 0,
      text = "Synthetic Cull Target", current = current, required = 7, complete = false } } }),
    extra or {})
end
local function trainer_leg(r) return r and tostring(r.reason):find("^class_trainer") ~= nil end

rs.active = nil
os.remove(dir .. "/active.json")
t = 10000
i = start("r9", t, field_quest(1400, 5, 100))
case(i and i.status.mode == "request" and i.reason == "class_trainer_walk",
  "trainer retry: a cold start inside a quest request still makes its first trainer visit", i)
for s = 5, 95, 5 do i = tick(t + s, field_quest(1400 + 2 * s, 5, 100)) end
local first = i.status.training
case(not trainer_leg(i) and first.attempts == 1 and first.state == "incomplete" and
  first.trained_level == 0, "trainer retry: the first visit times out unsettled", i)
-- Back on the objective (the walk back is not modeled): the fight keeps paying.
for s = 100, 390, 5 do
  i = tick(t + s, field_quest(1400, s >= 150 and 6 or 5, 100 - (s - 100) / 5))
end
local walks, frames = 0, 0
for s = 400, 520, 5 do
  local r = tick(t + s, field_quest(1400, 6, 40 - (s - 400) / 5))
  frames = frames + 1
  if trainer_leg(r) then walks = walks + 1 end
  if s == 400 then i = r end
end
print(string.format("INFO trainer retry: %d/%d request frames walked to the trainer after the retry came due",
  walks, frames))
case(walks == 0 and i and i.status.mode == "request" and i.kind == "attack" and i.guid == MOB and
  i.status.training.blocked == "retry waits for trainer in view during quest" and
  i.status.training.attempts == 1 and i.status.training.trained_level == 0,
  "trainer retry: a due retry with the trainer out of view keeps the quest's own fight", i)
i = tick(t + 525, field_quest(1660, 6, 100, { units = { { guid = TRAINER, entry = TRAINER_ENTRY,
  name = "Synthetic Trainer", distance = 40, combat_distance_known = true, combat_distance = 40,
  death_known = true, is_dead = false, health_known = true, health = 100, max_health = 100,
  player_can_attack = false, player_can_attack_known = true,
  location = { map_id = 0, position = { x = 1700, y = 100, z = 10, o = 0 } } } } }))
case(i and i.status.mode == "request" and i.kind == "interact" and i.guid == TRAINER and
  i.reason == "class_trainer", "trainer retry: with the trainer in view the pending retry is taken", i)
rs.active = nil
os.remove(dir .. "/active.json")

print(string.format("test_quest_role_recovery: passed=%d failed=%d", passed, failed))
drop_scratch()
if failed > 0 then os.exit(1) end
