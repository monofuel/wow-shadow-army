package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;" .. package.path

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 0.0
local logs = {}
_G.wow = {
  log = function(line) logs[#logs + 1] = line end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function()
    return { state = "following", failed_here = false, walkout_available = false }
  end,
}

local function logged(pattern)
  for i = 1, #logs do
    if logs[i]:find(pattern) then return true end
  end
  return false
end

require("tests.lifecycle_fixture")
local life = require("tools.lifecycle")
local raven = require("raven")

local PLAYER = 4242
local IMP_GUID = 9

local function mob(guid, distance, level, extra)
  local u = {
    guid = guid, entry = 1501, name = "mob" .. guid, distance = distance,
    level_known = true, level = level, player_can_attack = true,
    death_known = true, is_dead = false, health_known = true, health = 40,
    max_health = 40, creature_rank_known = true, creature_rank = 0,
    creature_type_known = true, creature_type = 6, is_tapped = false,
    tapped_by_player = false, summoner_guid = 0,
    location = { map_id = 0, position = { x = distance, y = 0, z = 50, o = 0 } },
  }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

local function imp_unit(extra)
  return mob(IMP_GUID, 2, 5, { entry = 416, name = "Imp", player_can_attack = false,
    summoner_guid = PLAYER })
end

local function pet_link(extra)
  local p = { guid_known = true, guid = IMP_GUID, dead = false,
    target_guid_known = true, target_guid = 0, health_known = true,
    health = 50, max_health = 50 }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end

local function button(slot, spell, extra)
  local b = { slot = slot, kind = "spell", spell_id = spell, usable_known = true,
    usable = true, not_enough_mana = false }
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end

local function warlock(extra)
  local v = {
    player_guid = PLAYER, class_id = 9, level = 12, xp = 100, next_level_xp = 9000,
    location_known = true,
    location = { map_id = 0, position = { x = 0, y = 0, z = 50, o = 0 } },
    health_known = true, health = 200, max_health = 200,
    powers = { 300 }, max_powers = { 300 },
    units = {}, action_buttons = { button(1, 705), button(2, 688) },
    known_spells = { 686, 695, 705, 688, 9078, 1180, 227, 5009 },
    auto_attack_guid = 0, in_combat = false, is_dead = false, is_ghost = false,
    resurrect_offer_guid = 0, active_cast_spell_id = 0,
    quest_frame = { open = false }, gossip_open = false, merchant_open = false,
    quest_objectives = {}, accepted_quests = {},
    completed_quest_ids = { 1470 },
    combat_kill_events = {}, ui_nodes = {}, equip_supported = true,
    inventory_items = {}, equipment_items = {}, copper_known = true, copper = 0,
    active_aura_spell_ids = {}, pet = { guid_known = true, guid = 0 },
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- Deathknell: fresh undead warlock without the imp, standing by Venya.
local function fresh(extra)
  local v = warlock({
    level = 1, known_spells = { 686, 687, 9078, 1180, 5009 },
    action_buttons = { button(1, 686) }, completed_quest_ids = {},
    location = { map_id = 0, position = { x = 1100.0, y = 96.0, z = 10, o = 0 } },
  })
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- Ranks -------------------------------------------------------------------
do
  local v = warlock({ units = { mob(7, 20, 11) } })
  check(life.best_nuke(v) == 705, "best nuke reads the trained rank 3 button")
  local i = life.upgrade_attack(v, { kind = "attack", guid = 7 }, true)
  check(i.spell == 705, "attack without a grinder nuke gains the learned rank")
  local floor = life.upgrade_attack(v, { kind = "attack", guid = 7 }, false)
  check(floor.spell == nil, "the grinder's mana floor is preserved")
  local unlearned = warlock({ known_spells = { 686, 695 },
    action_buttons = { button(1, 705), button(2, 695) } })
  check(life.best_nuke(unlearned) == 695,
    "a bound rank the seat never learned is not chosen")
  local oom = warlock({ action_buttons = { button(1, 705, { not_enough_mana = true }),
    button(2, 695) } })
  check(life.best_nuke(oom) == 695, "a rank short of mana falls back to a ready one")
  local unbound = warlock({ action_buttons = {} })
  check(life.best_nuke(unbound) == nil, "no bound rank means no nuke")
  local druid = warlock({ class_id = 11, known_spells = { 5176, 5177 },
    action_buttons = { button(1, 5177) } })
  check(life.best_nuke(druid) == 5177, "druid Wrath rank 2 once trained")
end

-- Pet ---------------------------------------------------------------------
do
  raven.reset()
  local st = life.new_state()
  local v = warlock({ pet = pet_link(), units = { imp_unit() } })
  check(life.own_pet(v) ~= nil, "pet link + our imp row is our pet")
  check(life.pet_step(v, st, 0, false) == nil and st.pet_summons == 1,
    "an existing imp is counted once and not resummoned")
  local stranger = warlock({ pet = { guid_known = true, guid = 0 },
    units = { mob(33, 3, 5, { entry = 416, summoner_guid = PLAYER }) } })
  check(life.own_pet(stranger) == nil,
    "a summoned unit the pet link does not name is not our pet")
  local foreign = warlock({ pet = pet_link(),
    units = { imp_unit() } })
  foreign.units[1].summoner_guid = 777
  check(life.own_pet(foreign) == nil, "a linked guid summoned by someone else is refused")
  local dead = warlock({ pet = pet_link({ dead = true }), units = { imp_unit() } })
  check(life.own_pet(dead) == nil, "a dead pet link is no pet")

  local gone = warlock({ pet = { guid_known = true, guid = 0 } })
  local cast = life.pet_step(gone, st, 1, false)
  check(st.pet_losses == 1, "a vanished pet is counted as lost")
  check(cast and cast.kind == "cast_spell" and cast.spell == 688, "lost imp is resummoned")
  check(life.pet_step(gone, st, 5, false).reason == "summon_settling",
    "the summon is given time to land")
  local fight = warlock({ pet = { guid_known = true, guid = 0 }, in_combat = true })
  check(life.pet_step(fight, st, 6, true) == nil, "a fight never holds for a summon")
  check(life.pet_step(gone, st, 7, false).reason == "summon_settling",
    "an interrupted summon restarts its settle window")
  check(life.pet_step(gone, st, 30, false).kind == "cast_spell",
    "a summon that never linked a pet is retried")
  check(st.summon_failures == 1, "and counted as a failure")
  local back = warlock({ pet = pet_link({ guid = 10 }),
    units = { mob(10, 2, 5, { entry = 416, summoner_guid = PLAYER, player_can_attack = false }) } })
  life.pet_step(back, st, 31, false)
  check(st.pet_summons == 2 and st.summon_failures == 0, "the resummon is counted")

  local unknown = fresh()
  check(life.pet_step(unknown, life.new_state(), 0, false) == nil,
    "no summon before the quest teaches 688")
  local nomana = warlock({ pet = { guid_known = true, guid = 0 },
    action_buttons = { button(1, 705), button(2, 688, { not_enough_mana = true }) } })
  check(life.pet_step(nomana, life.new_state(), 0, false) == nil,
    "a summon short of mana waits for regen instead of spamming")

  local ps = life.new_state()
  local attack = life.with_pet(v, ps, { kind = "attack", guid = 7 })
  check(attack.pet_attack == true and ps.pet_orders == 1, "attacks send the pet")
  local onit = warlock({ pet = pet_link({ target_guid = 7 }), units = { imp_unit() } })
  life.with_pet(onit, ps, { kind = "attack", guid = 7 })
  check(ps.pet_orders == 1, "a pet already on the target is not counted as reordered")
  local nopet = life.with_pet(gone, ps, { kind = "attack", guid = 7 })
  check(nopet.pet_attack == nil, "no pet, no pet_attack")
end

-- Gear --------------------------------------------------------------------
do
  local robe = { item_guid = 501, item_id = 1, name = "Robe", definition_known = true,
    item_class_id = 4, item_subclass_id = 1, inventory_type = 20, quality = 2,
    item_level = 10, required_level = 5, allowable_class_mask = -1,
    upgrade_score = 12, upgrade_slot = 4 }
  local worn = { item_guid = 400, item_id = 2, equipment_slot = 4 }
  local v = warlock({ inventory_items = { robe }, equipment_items = { worn } })
  check(life.upgrade_refusal(v, robe) == nil, "an SDK-scored legal upgrade is accepted")
  local zero = {}
  for k, x in pairs(robe) do zero[k] = x end
  zero.upgrade_score = 0
  check(life.upgrade_refusal(v, zero) == "not an upgrade",
    "quality and item level alone never make an upgrade")
  local high = {}
  for k, x in pairs(robe) do high[k] = x end
  high.required_level = 20
  check(life.upgrade_refusal(v, high) == "level", "too high a level is refused")
  local mask = {}
  for k, x in pairs(robe) do mask[k] = x end
  mask.allowable_class_mask = 1
  check(life.upgrade_refusal(v, mask) == "class mask", "another class's item is refused")

  local st = life.new_state()
  local i = life.gear_step(v, st, 0, false)
  check(i and i.kind == "equip_item" and i.item_guid == 501, "the upgrade is equipped")
  check(i.confirm_bind == true, "the chosen upgrade accepts its bind prompt")
  check(life.gear_step(v, st, 1, false).reason == "equip_settling", "equip waits for the slot")
  local landed = warlock({ inventory_items = {},
    equipment_items = { { item_guid = 501, item_id = 1, equipment_slot = 4 } } })
  local _, outcome = life.gear_step(landed, st, 2, false)
  check(outcome and outcome.equipped and st.equipped == 1 and outcome.equipped.replaced == 2,
    "equip counts only when the worn slot shows the new guid")

  local st2 = life.new_state()
  life.gear_step(v, st2, 0, false)
  local _, first = life.gear_step(v, st2, 10, false)
  check(first == nil and not st2.equip_refused[501], "one miss is retried")
  local again = life.gear_step(v, st2, 20, false)
  check(again and again.kind == "equip_item", "the second try goes out")
  local _, refused = life.gear_step(v, st2, 30, false)
  check(refused and refused.refused and st2.equip_refused[501],
    "an equip that never lands twice is set aside")
  check(life.gear_step(v, st2, 40, false) == nil, "and not retried")
  local st3 = life.new_state()
  life.gear_step(v, st3, 0, false)
  local fight = warlock({ in_combat = true, inventory_items = { robe } })
  check(life.gear_step(fight, st3, 3, false) == nil and st3.equip_pending == nil and
    not st3.equip_tries[501], "a fight mid-settle drops the try without counting it")
  check(life.gear_step(warlock({ in_combat = true, inventory_items = { robe } }),
    life.new_state(), 0, false) == nil, "never equips mid-fight")
end

-- Training ----------------------------------------------------------------
do
  local trainer = mob(88, 5, 30, { entry = 2126, player_can_attack = false })
  local at = { map_id = 0, position = { x = 1100.0, y = 96.0, z = 10, o = 0 } }
  local st = life.new_state()
  local v = warlock({ level = 4, copper = 500, location = at, units = { trainer } })
  local verify = life.train_step(v, st, 0, false)
  check(verify and verify.kind == "interact", "first sight verifies the level at the trainer")
  life.train_step(warlock({ level = 4, copper = 500, location = at, units = { trainer },
    trainer_open = true, trainer_guid = 88, trainer_offers = {} }), st, 0.5, false)
  check(life.train_step(v, st, 0.7, false) == nil and st.trained_level == 4,
    "an exact frame with nothing to buy settles the level")
  local up = warlock({ level = 6, copper = 500, location = at, units = { trainer },
    known_spells = { 686, 688 } })
  local go = life.train_step(up, st, 1, false)
  check(go and go.kind == "interact" and go.guid == 88, "a new level walks to the trainer")
  local offer = { service_spell_id = 1, taught_spell_id = 695, state = 0, cost = 100,
    required_level = 6, pending = false }
  local open = warlock({ level = 6, copper = 500, location = at, units = { trainer },
    known_spells = { 686, 688 }, trainer_open = true, trainer_guid = 88,
    trainer_offers = { offer } })
  local buy = life.train_step(open, st, 2, false)
  check(buy and buy.kind == "train" and buy.guid == 88, "an open trainer frame trains")
  local bought = warlock({ level = 6, copper = 400, location = at, units = { trainer },
    known_spells = { 686, 688, 695 }, trainer_open = true, trainer_guid = 88,
    trainer_offers = { { service_spell_id = 1, taught_spell_id = 695, state = 2,
      cost = 100, required_level = 6, pending = false } } })
  life.train_step(bought, st, 2.5, false)
  local after = warlock({ level = 6, copper = 400, location = at, units = { trainer },
    known_spells = { 686, 688, 695 } })
  check(life.train_step(after, st, 3, false) == nil and st.trained_spells == 1,
    "the visit ends when the frame closes, counting learned spells")
  check(life.train_step(after, st, 4, false) == nil, "no second visit at the same level")
  local broke = life.new_state()
  life.train_step(warlock({ level = 4, location = at }), broke, 0, false)
  check(life.train_step(warlock({ level = 6, copper = 0, location = at }), broke, 1, false) == nil,
    "no trainer walk without money")
  local far = life.new_state()
  life.train_step(warlock({ level = 4, copper = 500 }), far, 0, false)
  check(life.train_step(warlock({ level = 6, copper = 500 }), far, 1, false) == nil,
    "a trainer out of reach is not walked to")
end

-- Class quest -------------------------------------------------------------
do
  check(life.class_quest_phase(fresh()) == "accept", "fresh warlock needs to accept 1470")
  check(life.class_quest_phase(warlock()) == nil, "rewarded quest is done")
  check(life.class_quest_phase(fresh({ known_spells = { 686, 688 } })) == nil,
    "a seat that already knows 688 does not chase the quest")
  check(life.class_quest_phase(fresh({ class_id = 11 })) == nil, "druids have no imp quest")
  local accepted = fresh({ accepted_quests = { { quest_id = 1470 } },
    quest_objectives = { { quest_id = 1470, item_id = 6281, entry = 0, current = 1,
      required = 3, complete = false } } })
  check(life.class_quest_phase(accepted) == "collect", "skulls missing means collect")
  local full = fresh({ accepted_quests = { { quest_id = 1470 } },
    quest_objectives = { { quest_id = 1470, item_id = 6281, entry = 0, current = 3,
      required = 3, complete = true } } })
  check(life.class_quest_phase(full) == "turn_in", "three skulls means turn in")

  local st = life.new_state()
  local walk = life.class_quest_step(fresh({ location = { map_id = 0,
    position = { x = 960, y = 100, z = 10, o = 0 } } }), st)
  check(walk.kind == "navigate" and walk.reason == "class_quest_walk_accept",
    "out of sight of Venya the seat walks to her spawn")
  local venya = mob(55, 6, 5, { entry = 5667, player_can_attack = false })
  local talk = life.class_quest_step(fresh({ units = { venya, mob(7, 10, 1) } }), st)
  check(talk.kind == "interact" and talk.guid == 55,
    "a nearby hunt target does not block the quest giver")

  local dropper = mob(70, 30, 3, { entry = 1890 })
  local hunt = life.class_quest_step(fresh({ accepted_quests = { { quest_id = 1470 } },
    units = { dropper } }), st)
  check(hunt.kind == "attack" and hunt.guid == 70, "collect hunts a visible skull dropper")
  local field = life.class_quest_step(fresh({ accepted_quests = { { quest_id = 1470 } } }), st)
  check(field.kind == "navigate" and field.reason == "class_quest_field",
    "no dropper in sight walks to the skeleton field")
  local inField = life.class_quest_step(fresh({ accepted_quests = { { quest_id = 1470 } },
    location = { map_id = 0, position = { x = 1247, y = 4, z = 10, o = 0 } } }), st)
  check(inField == nil, "inside the field the grinder takes over until one spawns")
  local back = life.class_quest_step(full, st)
  check(back.reason == "class_quest_walk_turn_in", "full skulls walk back to Venya")

  local details = fresh({ quest_frame = { open = true, panel = "details", quest_id = 1470 } })
  check(life.class_quest_dialog(details).command == "/questaccept", "accept 1470 details")
  local other = fresh({ quest_frame = { open = true, panel = "details", quest_id = 1501 } })
  check(life.class_quest_dialog(other).control == "QuestFrameDeclineButton",
    "another quest's details are declined, never left open")
  local reward = fresh({ quest_frame = { open = true, panel = "reward", quest_id = 1470 } })
  check(life.class_quest_dialog(reward).command == "/questreward", "take 1470 reward")
  local progress = fresh({ quest_frame = { open = true, panel = "progress",
    quest_id = 1470, can_complete = true } })
  check(life.class_quest_dialog(progress).command == "/questcomplete", "complete 1470")
  local gossip = fresh({ gossip_open = true, ui_nodes = { { reference_id = "gossip-quest:1470",
    enabled = true, hit_testable = true } } })
  check(life.class_quest_dialog(gossip).reference == "gossip-quest:1470",
    "the 1470 gossip row is picked")
end

-- Gray pulls ----------------------------------------------------------------
do
  check(life.gray_level(5) == 0 and life.gray_level(8) == 3 and life.gray_level(12) == 6,
    "vanilla gray levels")
  local st = life.new_state()
  local v = warlock({ level = 8, units = { mob(1, 10, 3), mob(2, 30, 7) } })
  local swapped = life.purposeful_target(v, st, { kind = "attack", guid = 1, spell = 686 })
  check(swapped.guid == 2 and st.gray_swaps == 1, "a gray fresh pull is swapped for XP")
  local only = warlock({ level = 8, units = { mob(1, 10, 3) } })
  check(life.purposeful_target(only, st, { kind = "attack", guid = 1 }).guid == 1,
    "with nothing better the grinder's choice stands")
  local fighting = warlock({ level = 8, in_combat = true, units = { mob(1, 10, 3), mob(2, 30, 7) } })
  check(life.purposeful_target(fighting, st, { kind = "attack", guid = 1 }).guid == 1,
    "a fight already joined is not abandoned")
  local quest = warlock({ level = 8, units = { mob(1, 10, 3, { entry = 3 }), mob(2, 30, 7) },
    quest_objectives = { { quest_id = 5, entry = 3, item_id = 99, complete = false } } })
  check(life.purposeful_target(quest, st, { kind = "attack", guid = 1 }).guid == 1,
    "a gray quest-item dropper is kept")
end

-- Progress accounting -----------------------------------------------------
do
  local st = life.new_state()
  local v = warlock()
  logs = {}
  life.note_progress(v, st, 0, { kind = "attack", guid = 7 })
  life.note_progress(v, st, 130, { kind = "attack", guid = 7 })
  check(st.longest_no_progress == 130 and logged("no progress 130s"),
    "a long no-progress span is measured and diagnosed, including in combat")
  life.note_progress(warlock({ xp = 200 }), st, 131, nil)
  check(st.progress_since == 131, "XP resets the span")
end

-- Entry wiring --------------------------------------------------------------
do
  raven.reset()
  clock = 100
  local v = fresh({ units = { mob(55, 6, 5, { entry = 5667, player_can_attack = false }) } })
  local i = raven.decide(v)
  check(i.kind == "interact" and i.guid == 55, "raven walks a fresh warlock to Venya")
  local d = raven.decide(fresh({ quest_frame = { open = true, panel = "details",
    quest_id = 1470 } }))
  check(d.command == "/questaccept", "raven answers the class quest dialog")
  raven.reset()
  local grind = raven.decide(warlock({ level = 8, pet = pet_link(),
    units = { imp_unit(), mob(7, 20, 8) }, action_buttons = { button(1, 705) } }))
  check(grind.kind == "attack" and grind.pet_attack == true,
    "a grind attack goes out with the pet")
end

-- Loot and busy -------------------------------------------------------------
do
  local st = life.new_state()
  local corpse = mob(40, 20, 3, { entry = 1890, is_dead = true, lootable_known = true,
    is_lootable = true, tapped_by_player = true, is_tapped = true })
  local other = mob(41, 10, 3, { is_dead = true, lootable_known = true,
    is_lootable = true, tapped_by_player = false, is_tapped = true })
  local v = warlock({ units = { corpse, other } })
  check(life.loot_corpse(v, st) == corpse, "our own lootable corpse is chosen, not another's")
  st.loot_tried[40] = true
  check(life.loot_corpse(v, st) == nil, "a tried corpse is not chosen again")
  local stale = warlock({ auto_attack_guid = 40, units = { corpse } })
  check(not life.fighting(stale), "a swing latched on a corpse is not a fight")
  local live = warlock({ auto_attack_guid = 7, units = { mob(7, 3, 12) } })
  check(life.fighting(live), "a swing at a living target is a fight")
  check(life.fighting(warlock({ in_combat = true })), "combat is a fight")
  raven.reset()
  clock = 500
  local i = raven.decide(warlock({ level = 4, auto_attack_guid = 40,
    pet = pet_link(), units = { imp_unit(), corpse }, completed_quest_ids = { 1470 } }))
  check(i.kind == "interact" and i.guid == 40,
    "after a kill with a stale swing the seat walks to loot its corpse")
end

-- Binding learned spells ----------------------------------------------------
do
  local st = life.new_state()
  -- A quest-rewarded Summon Imp with no button: drag it to the first empty
  -- main-bar slot instead of casting what cannot be pressed.
  local v = warlock({ action_bar_known = true, known_spells = { 686, 688 },
    action_buttons = { button(1, 686), { slot = 2, kind = "empty" },
      { slot = 13, kind = "empty" } } })
  check(life.pet_step(v, st, 0, false) == nil, "an unbound summon is not cast")
  local b = life.bind_step(v, st, 0, false)
  check(b and b.kind == "bind_spell" and b.spell == 688 and b.slot == 2,
    "the unbound imp summon is dragged to empty main slot 2")
  b = life.bind_step(v, st, 5, false)
  check(b and b.kind == "bind_spell" and b.spell == 688, "the drag is held until it lands")
  v.action_buttons[2] = button(2, 688)
  check(life.bind_step(v, st, 6, false) == nil and st.bound_spells == 1,
    "a landed button is counted from the bar")
  -- A family already on the bar at any rank is left alone; the highest
  -- known rank of an unbound family is chosen.
  local w = warlock({ action_bar_known = true, known_spells = { 686, 695, 688, 172, 6222 },
    action_buttons = { button(1, 686), button(2, 688), { slot = 3, kind = "empty" } } })
  local st2 = life.new_state()
  b = life.bind_step(w, st2, 0, false)
  check(b and b.spell == 6222 and b.slot == 3,
    "Corruption's highest known rank is bound; Shadow Bolt rank 1 on the bar counts")
  check(life.bind_step(w, life.new_state(), 0, true) == nil, "no drag during a fight")
  local full = warlock({ action_bar_known = true, known_spells = { 686, 172 },
    action_buttons = { button(1, 686) } })
  check(life.bind_step(full, life.new_state(), 0, false) == nil,
    "no empty main slot, no drag")
  -- A drag that never lands is given up after the settle window and retried
  -- at most twice.
  local st3 = life.new_state()
  local stuck = warlock({ action_bar_known = true, known_spells = { 686, 688 },
    action_buttons = { button(1, 686), { slot = 2, kind = "empty" } } })
  check(life.bind_step(stuck, st3, 0, false) ~= nil, "first attempt")
  check(life.bind_step(stuck, st3, 100, false) == nil, "timed-out attempt released")
  check(life.bind_step(stuck, st3, 101, false) ~= nil, "second attempt")
  check(life.bind_step(stuck, st3, 300, false) == nil, "second timeout released")
  check(life.bind_step(stuck, st3, 301, false) == nil, "no third attempt")
end

-- Objectives done is not rewarded ---------------------------------------------
do
  -- Live Legia: three skulls, quest still in the log, and the server already
  -- lists it in completed_quest_ids. That is the moment to turn it in.
  local v = fresh({ level = 4, known_spells = { 686, 687 },
    accepted_quests = { { quest_id = 1470 } }, completed_quest_ids = { 1470 },
    quest_objectives = { { quest_id = 1470, item_id = 6281, current = 3, required = 3,
      complete = true } } })
  check(life.class_quest_phase(v) == "turn_in",
    "objectives complete with the quest still logged means turn in")
  local st = life.new_state()
  life.note_class_quest(v, st)
  check(not st.quest_logged.done, "a logged quest is not reported as rewarded")
  v.accepted_quests, v.quest_objectives = {}, {}
  v.rewarded_quest_ids = { 1470 }
  check(life.class_quest_phase(v) == nil, "a rewarded quest is over")
  life.note_class_quest(v, st)
  check(st.quest_logged.done, "the reward is reported once it is real")
end

-- Evading targets ---------------------------------------------------------
do
  -- Live Igris: twelve evades on one mob whose health went 20 -> 71 -> 100.
  local st = life.new_state()
  local function at(hp, others)
    local units = { mob(90, 20, 6, { health_known = true, health = hp, max_health = 100 }) }
    for _, u in ipairs(others or {}) do units[#units + 1] = u end
    return warlock({ level = 9, units = units })
  end
  local function atk() return { kind = "attack", guid = 90, spell = 686, reason = "grind" } end
  check(life.avoid_evading(at(20), st, atk(), 0).guid == 90, "a target being hurt is kept")
  check(life.avoid_evading(at(45), st, atk(), 5).guid == 90, "a small regain is not an evade")
  local other = mob(91, 30, 8, { health_known = true, health = 100, max_health = 100 })
  local i = life.avoid_evading(at(71, { other }), st, atk(), 10)
  check(i.guid == 91 and i.reason == "grind:not_evading", "a target that regained 51% is swapped")
  check(life.avoid_evading(at(100), st, atk(), 20).kind == "hold", "with nothing else near the seat stops attacking it")
  check(life.avoid_evading(at(100), st, atk(), 200).guid == 90, "after the avoid window it may be tried again")
end

print(string.format("test_raven: %d checks passed", passed))
