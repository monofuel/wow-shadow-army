-- Home army: Murist escort with class roles and a solo-leveling fallback.
-- Runs in the fork's embedded lua-bot against the raw Observation mirror.

local solo = require("accelerated")

local M = {}

local MURIST = "murist"
local NEAR_YARDS = 8.0
local HARD_LEASH_YARDS = 18.0
local HEAL_RANGE_YARDS = 30.0
local RES_WAIT_SECONDS = 20.0
local PROMOTE_RETRY_SECONDS = 5.0

local CLASS_WARRIOR = 1
local CLASS_PRIEST = 5
local CLASS_WARLOCK = 9

local dead_since = nil
local last_promote_at = nil

local AURA_FAMILIES = {
  ["curse of agony"] = { 980, 1014, 6217, 11711, 11712, 11713 },
  ["corruption"] = { 172, 6222, 6223, 7648, 11671, 11672 },
  ["immolate"] = { 348, 707, 1094, 2941, 11665, 11667, 11668 },
  ["demon skin"] = { 687, 696 },
  ["demon armor"] = { 706, 1086, 11733, 11734, 11735 },
  ["battle shout"] = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 },
  ["power word shield"] = { 17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 },
  ["weakened soul"] = { 6788 },
  ["renew"] = { 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929 },
  ["power word fortitude"] = { 1243, 1244, 1245, 2791, 10937, 10938 },
  ["inner fire"] = { 588, 7128, 602, 1006, 10951, 10952 },
  ["shadow word pain"] = { 589, 594, 970, 992, 2767, 10892, 10893, 10894 },
}

local function lower(value)
  return tostring(value or ""):lower()
end

local function normalized(value)
  return lower(value):gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function guid_equal(a, b)
  if a == nil or b == nil then return false end
  return tostring(a) == tostring(b) and tostring(a) ~= "0"
end

local function percent(current, maximum)
  maximum = tonumber(maximum) or 0
  if maximum <= 0 then return 100.0 end
  return (tonumber(current) or 0) * 100.0 / maximum
end

local function health_pct(row)
  if not row or row.health_known == false then return 100.0 end
  return percent(row.health, row.max_health)
end

local function self_health_pct(view)
  if view.health_known == false then return 100.0 end
  return percent(view.health, view.max_health)
end

local function mana_pct(view)
  local powers, maxima = view.powers or {}, view.max_powers or {}
  return percent(powers[1], maxima[1])
end

local function point(row)
  if not row then return nil end
  if row.location and row.location.position then return row.location.position end
  if row.position then return row.position end
  return nil
end

local function view_point(view)
  return view and view.location and view.location.position or nil
end

local function distance(a, b)
  if not a or not b then return nil end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function party_member(view, name)
  local wanted = lower(name)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if lower(member.name) == wanted then return member end
  end
  return nil
end

local function party_member_by_guid(view, guid)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if guid_equal(member.guid, guid) then return member end
  end
  return nil
end

local function visible_unit(view, guid)
  for _, unit in ipairs(view.units or {}) do
    if guid_equal(unit.guid, guid) then return unit end
  end
  return nil
end

local function visible_player_by_name(view, name)
  local wanted = lower(name)
  for _, unit in ipairs(view.units or {}) do
    if lower(unit.name) == wanted and unit.is_player_controlled ~= false then
      return unit
    end
  end
  return nil
end

local function hostile(unit)
  if not unit or unit.player_can_attack ~= true then return false end
  if unit.death_known and unit.is_dead then return false end
  if unit.health_known and (unit.health or 0) <= 0 then return false end
  return true
end

local function spell_ready(spell)
  if not spell or spell.passive or spell.from_item then return false end
  if spell.usable_known and not spell.usable then return false end
  if spell.not_enough_mana then return false end
  if (spell.cooldown_ms or 0) > 0 then return false end
  if spell.reagents_available == false then return false end
  if spell.requires_equipped_item and spell.equipped_item_requirement_known and
      not spell.equipped_item_requirement_met then return false end
  if spell.requires_caster_aura_state and
      spell.caster_aura_state_requirement_known and
      not spell.caster_aura_state_requirement_met then return false end
  return true
end

local function pick_spell(view, priorities)
  for _, wanted in ipairs(priorities) do
    local want = normalized(wanted)
    local best = nil
    for _, spell in ipairs(view.spell_facts or {}) do
      local name = normalized(spell.name)
      if spell.name_known ~= false and spell_ready(spell) and
          (name == want or name:find(want, 1, true)) and
          (not best or (spell.rank or 0) > (best.rank or 0)) then
        best = spell
      end
    end
    if best then return best, want end
  end
  return nil, nil
end

local function aura_present(ids, family, selected_spell_id)
  local wanted = {}
  for _, id in ipairs(AURA_FAMILIES[family] or {}) do wanted[id] = true end
  if selected_spell_id then wanted[selected_spell_id] = true end
  for _, id in ipairs(ids or {}) do
    if wanted[id] then return true end
  end
  return false
end

local function role_for(view)
  if view.class_id == CLASS_WARRIOR then return "tank" end
  if view.class_id == CLASS_PRIEST then return "healer" end
  if view.class_id == CLASS_WARLOCK then return "dps" end
  return "dps"
end

local function status_for(view, mode, role, leader, target, recovery)
  return {
    mode = mode,
    role = role,
    party_leader = (view.party and view.party.leader_name) or "",
    murist_visible = leader ~= nil,
    target_guid = target and target.guid or 0,
    recovery = recovery or "",
  }
end

local function finish(intent, view, mode, role, leader, target, recovery)
  intent = intent or { kind = "hold", reason = "no_intent" }
  intent.status = status_for(view, mode, role, leader, target, recovery)
  return intent
end

local function cast(spell, reason, target_guid)
  if not spell then return nil end
  local result = { kind = "cast_spell", spell = spell.spell_id, reason = reason }
  if target_guid then result.target_guid = target_guid end
  return result
end

local function nearest_hostile(view)
  local best, best_distance = nil, nil
  for _, unit in ipairs(view.units or {}) do
    if hostile(unit) then
      local d = unit.combat_distance_known and unit.combat_distance or unit.distance or 1e9
      if not best_distance or d < best_distance then
        best, best_distance = unit, d
      end
    end
  end
  return best
end

local function current_hostile(view)
  local target = visible_unit(view, view.auto_attack_guid)
  if hostile(target) then return target end
  target = visible_unit(view, view.selected_target_guid)
  if hostile(target) then return target end
  if view.in_combat then return nearest_hostile(view) end
  return nil
end

local function beru_can_resurrect(view)
  local beru = party_member(view, "Beru")
  if not beru or not beru.level_known or (beru.level or 0) < 10 then return false end
  if not beru.death_state_known or beru.is_dead or beru.is_ghost then return false end
  if not beru.location_known or not view.location_known then return false end
  local d = distance(view_point(view), {
    x = beru.location.x, y = beru.location.y, z = beru.location.z,
  })
  return d ~= nil and d <= HEAL_RANGE_YARDS
end

local function death_intent(view, now)
  if (view.resurrect_offer_guid or 0) ~= 0 then
    return { kind = "accept_rez", reason = "accept_resurrection" }, "accept_rez"
  end
  if view.is_dead and not view.is_ghost then
    if not dead_since then dead_since = now end
    if beru_can_resurrect(view) and now - dead_since < RES_WAIT_SECONDS then
      return { kind = "hold", reason = "wait_for_beru_resurrection" }, "waiting_for_beru"
    end
    return { kind = "release", reason = "release_spirit" }, "releasing"
  end
  if view.is_ghost then
    if view.can_reclaim_corpse then
      return { kind = "reclaim", reason = "reclaim_corpse" }, "reclaiming"
    end
    if view.corpse_known and view.corpse_location and view.corpse_location.position then
      local corpse = view.corpse_location.position
      return {
        kind = "navigate",
        x = corpse.x,
        y = corpse.y,
        z = corpse.z,
        map_id = view.corpse_location.map_id,
        stop_distance = 30.0,
        route_profile = "safe_ground",
        reason = "corpse_run",
      }, "corpse_run"
    end
    return { kind = "hold", reason = "ghost_without_known_corpse" }, "corpse_unknown"
  end
  dead_since = nil
  return nil, nil
end

local function heal_candidate(view)
  local best = nil
  local function consider(row, is_self)
    if row.death_state_known and (row.is_dead or row.is_ghost) then return end
    if row.health_known == false or (row.max_health or 0) <= 0 then return end
    if not is_self then
      if not row.location_known or not view.location_known then return end
      local d = distance(view_point(view), {
        x = row.location.x, y = row.location.y, z = row.location.z,
      })
      if not d or d > HEAL_RANGE_YARDS or row.line_of_sight_blocked then return end
    end
    local hp = health_pct(row)
    if hp < 90 and (not best or hp < best.hp or
        (hp == best.hp and tostring(row.guid) < tostring(best.row.guid))) then
      best = { row = row, hp = hp, self_target = is_self }
    end
  end
  consider({
    guid = view.player_guid,
    health_known = view.health_known,
    health = view.health,
    max_health = view.max_health,
    active_auras_known = true,
    active_aura_spell_ids = view.active_aura_spell_ids or {},
  }, true)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if not guid_equal(member.guid, view.player_guid) then consider(member, false) end
  end
  return best
end

local function healer_action(view, emergency_only)
  local candidate = heal_candidate(view)
  if not candidate or (emergency_only and candidate.hp >= 50) then return nil end
  local row, hp = candidate.row, candidate.hp
  local auras = row.active_aura_spell_ids or {}
  if hp < 50 and row.active_auras_known ~= false then
    local shield = pick_spell(view, { "Power Word: Shield" })
    if shield and not aura_present(auras, "power word shield", shield.spell_id) and
        not aura_present(auras, "weakened soul") then
      return cast(shield, "shield_low_party_member", row.guid)
    end
  end
  local heal = nil
  if hp < 20 then
    heal = pick_spell(view, { "Flash Heal", "Heal", "Lesser Heal" })
  elseif hp < 70 then
    heal = pick_spell(view, { "Heal", "Lesser Heal", "Flash Heal" })
  elseif hp < 90 and row.active_auras_known ~= false then
    local renew = pick_spell(view, { "Renew" })
    if renew and not aura_present(auras, "renew", renew.spell_id) then
      return cast(renew, "renew_party_member", row.guid)
    end
  end
  return cast(heal, "heal_party_member", row.guid)
end

local function resurrection_action(view)
  if view.in_combat then return nil end
  local spell = pick_spell(view, { "Resurrection" })
  if not spell then return nil end
  local candidates = {}
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if not guid_equal(member.guid, view.player_guid) and member.death_state_known and
        (member.is_dead or member.is_ghost) and member.location_known and
        view.location_known then
      local d = distance(view_point(view), {
        x = member.location.x, y = member.location.y, z = member.location.z,
      })
      if d and d <= HEAL_RANGE_YARDS and not member.line_of_sight_blocked then
        candidates[#candidates + 1] = member
      end
    end
  end
  table.sort(candidates, function(a, b) return tostring(a.guid) < tostring(b.guid) end)
  if candidates[1] then
    return cast(spell, "resurrect_party_member", candidates[1].guid)
  end
  return nil
end

local function warlock_action(view, target)
  if mana_pct(view) < 18 and self_health_pct(view) >= 40 then
    local tap = pick_spell(view, { "Life Tap" })
    if tap then return cast(tap, "life_tap") end
  end
  local auras = target.active_aura_spell_ids or {}
  for _, name in ipairs({ "Curse of Agony", "Corruption", "Immolate" }) do
    local spell, family = pick_spell(view, { name })
    if spell and not aura_present(auras, family, spell.spell_id) then
      return { kind = "attack", guid = target.guid, spell = spell.spell_id,
        stop_distance = 22.0, reason = "warlock_" .. family:gsub(" ", "_") }
    end
  end
  local filler = pick_spell(view, { "Shadow Bolt", "Shoot" })
  return { kind = "attack", guid = target.guid,
    spell = filler and filler.spell_id or nil,
    stop_distance = filler and 22.0 or 4.0,
    reason = filler and "warlock_filler" or "warlock_melee_fallback" }
end

local function warrior_action(view, target)
  if target.target_guid_known and not guid_equal(target.target_guid, view.player_guid) and
      party_member_by_guid(view, target.target_guid) then
    local taunt = pick_spell(view, { "Taunt" })
    if taunt then
      return { kind = "attack", guid = target.guid, spell = taunt.spell_id,
        stop_distance = 4.0, reason = "tank_taunt_party_attacker" }
    end
  end
  local threat = pick_spell(view, {
    "Sunder Armor", "Revenge", "Heroic Strike", "Thunder Clap",
    "Demoralizing Shout", "Battle Shout",
  })
  return { kind = "attack", guid = target.guid,
    spell = threat and threat.spell_id or nil,
    stop_distance = 4.0,
    reason = threat and "tank_threat" or "tank_melee" }
end

local function priest_damage(view, target)
  local auras = target.active_aura_spell_ids or {}
  local pain, family = pick_spell(view, { "Shadow Word: Pain" })
  if pain and not aura_present(auras, family, pain.spell_id) then
    return { kind = "attack", guid = target.guid, spell = pain.spell_id,
      stop_distance = 22.0, reason = "priest_shadow_word_pain" }
  end
  local spell = pick_spell(view, { "Mind Blast", "Smite", "Shoot" })
  return { kind = "attack", guid = target.guid,
    spell = spell and spell.spell_id or nil,
    stop_distance = spell and 22.0 or 4.0,
    reason = spell and "priest_damage" or "priest_melee" }
end

local function self_buff(view, role)
  local priorities = role == "tank" and { "Battle Shout" }
    or role == "healer" and { "Inner Fire" }
    or { "Demon Armor", "Demon Skin" }
  for _, name in ipairs(priorities) do
    local spell, family = pick_spell(view, { name })
    if spell and not aura_present(view.active_aura_spell_ids, family, spell.spell_id) then
      return cast(spell, "self_buff")
    end
  end
  return nil
end

local function fortitude_action(view)
  local spell = pick_spell(view, { "Power Word: Fortitude" })
  if not spell then return nil end
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if member.death_state_known and not member.is_dead and not member.is_ghost and
        member.active_auras_known and
        not aura_present(member.active_aura_spell_ids, "power word fortitude", spell.spell_id) and
        (guid_equal(member.guid, view.player_guid) or member.location_known) then
      return cast(spell, "fortitude_party_member", member.guid)
    end
  end
  return nil
end

function M.reset()
  dead_since = nil
  last_promote_at = nil
end

function M.decide(view)
  view = view or {}
  local now = tonumber(view.simulation_time) or 0
  local role = role_for(view)
  local death, recovery = death_intent(view, now)
  if death then return finish(death, view, "recovery", role, nil, nil, recovery) end

  local party = view.party or {}
  if party.invite_pending and lower(party.invite_from) == MURIST then
    return finish({ kind = "accept_party", reason = "accept_murist_invite" },
      view, "party_forming", role)
  end

  local murist_member = party_member(view, "Murist")
  if party.in_group and murist_member and
      guid_equal(party.leader_guid, view.player_guid) then
    if not last_promote_at or now - last_promote_at >= PROMOTE_RETRY_SECONDS then
      last_promote_at = now
      return finish({ kind = "promote_party", guid = murist_member.guid,
        reason = "promote_murist" }, view, "party_forming", role)
    end
  end

  local leader = murist_member and visible_player_by_name(view, "Murist") or nil
  if not party.in_group or not murist_member or not leader then
    local intent = solo.decide(view)
    return finish(intent, view, "solo", role)
  end

  if (view.active_cast_spell_id or 0) ~= 0 or
      (view.active_channel_spell_id or 0) ~= 0 then
    return finish({ kind = "hold", reason = "finish_active_cast" },
      view, "escort", role, leader)
  end

  if role == "healer" then
    local emergency = healer_action(view, true)
    if emergency then return finish(emergency, view, "escort", role, leader) end
  end

  local leader_distance = distance(view_point(view), point(leader))
  if not leader_distance or leader_distance > HARD_LEASH_YARDS then
    return finish({ kind = "follow", guid = leader.guid, reason = "hard_rejoin_murist" },
      view, "escort", role, leader)
  end

  local target = nil
  if leader.is_in_combat and leader.target_guid_known then
    local candidate = visible_unit(view, leader.target_guid)
    if hostile(candidate) then target = candidate end
  end
  if not target then target = current_hostile(view) end

  if role == "healer" then
    local heal = healer_action(view, false)
    if heal then return finish(heal, view, "escort", role, leader, target) end
    local rez = resurrection_action(view)
    if rez then return finish(rez, view, "escort", role, leader, target) end
  end

  if target then
    local action = role == "tank" and warrior_action(view, target)
      or role == "healer" and priest_damage(view, target)
      or warlock_action(view, target)
    return finish(action, view, "escort", role, leader, target)
  end

  if leader.is_in_combat then
    return finish({ kind = "assist", guid = leader.guid, reason = "assist_murist" },
      view, "escort", role, leader)
  end

  if leader_distance > NEAR_YARDS then
    return finish({ kind = "follow", guid = leader.guid, reason = "follow_murist" },
      view, "escort", role, leader)
  end

  if not view.in_combat then
    local buff = role == "healer" and fortitude_action(view) or nil
    if not buff then buff = self_buff(view, role) end
    if buff then return finish(buff, view, "escort", role, leader) end
  end

  return finish({ kind = "hold", reason = "in_formation" },
    view, "escort", role, leader)
end

return M
