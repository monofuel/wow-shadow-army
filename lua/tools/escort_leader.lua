-- escort_leader: stay near the party leader and fight with the cast.
--
-- Role is derived from observation class_id (projected on self_unit):
--   warrior (1)  → tank: threat/melee casts, then attack_unit
--   priest  (5)  → healer: heal/shield when offered, else smite/wand
--   warlock (9) / default → DPS: DoTs → Shadow Bolt → wand
--
-- Priority (each decide):
--   0. Death recovery
--   1. Life Tap when dry
--   2. FORMATION leash/far rejoin (beats combat — stay on the human)
--   3. Soft rejoin outside near band when not on a real focus
--   4. Combat on focus / join casts near LEADER only / defend if in_combat
--   5. Buff / hold — never OOC assist-spam, never free-fire zone
--
-- Cast list from projection combat.casts (masked only).

local registry = require("registry")

local DEFAULT_NEAR = 8.0
-- Beyond this: always rejoin (even mid-combat). Tight escort leash.
local DEFAULT_FAR = 18.0
-- Outside near but inside far while fighting: stay on target.
local COMBAT_LEASH = 12.0
local LIFE_TAP_MANA = 18.0
local LIFE_TAP_MIN_HP = 40.0
-- Below this: prefer wand/dagger over spending for SB.
local OOM_MANA = 8.0
-- Casters approach this far before falling back to melee (vanilla SB/Smite ~30).
local CAST_APPROACH = 22.0
-- Inside this, casters may dagger/wand-swing if the cast mask is empty.
local MELEE_RANGE = 5.5
-- OOC: only open on cast targets within this of the LEADER (join his pull,
-- not free-fire the zone).
local JOIN_LEADER_BAND = 16.0
-- Corpse runs: never emit a single long direct move to the body (mountain /
-- cave deaths). Brain/shadow rewrites destinations onto a multi-leg
-- Detour/anchor corridor; Lua only names the body so reclaim/hop reasons stay.
local CORPSE_HOP = 22.0

local DOT_PRIORITY = {
  "curse of agony",
  "corruption",
  "immolate",
}
local FILLER_PRIORITY = {
  "shadow bolt",
}
local WAND_PRIORITY = {
  "shoot",
}
local BUFF_PRIORITY = {
  "demon skin",
  "demon armor",
}
-- Warrior threat / melee options (masked names only; never invent spells).
local TANK_THREAT_PRIORITY = {
  "sunder armor",
  "revenge",
  "heroic strike",
  "thunder clap",
  "shield bash",
  "taunt",
  "demoralizing shout",
  "battle shout",
}
-- Priest heals / shields (prefer cast mask targets as offered).
local HEAL_PRIORITY = {
  "flash heal",
  "lesser heal",
  "heal",
  "renew",
  "power word: shield",
  "power word shield",
}
local PRIEST_DAMAGE_PRIORITY = {
  "smite",
  "shadow word: pain",
  "mind blast",
  "shoot",
}
local PRIEST_BUFF_PRIORITY = {
  "power word: fortitude",
  "inner fire",
}

-- Classic class ids (ChrClasses).
local CLASS_WARRIOR = 1
local CLASS_PRIEST = 5
local CLASS_WARLOCK = 9

local function role_for_class(class_id)
  local c = tonumber(class_id) or 0
  if c == CLASS_WARRIOR then return "tank" end
  if c == CLASS_PRIEST then return "healer" end
  if c == CLASS_WARLOCK then return "dps" end
  return "dps"
end

local function dist2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function has_z(u)
  -- Party bindings often ship z=0 when elevation is unknown. Treat that as
  -- "no z" so we do not thrash vertical rejoin and skip combat join.
  return u and u.z ~= nil and u.z ~= 0
end

-- Prefer destination `move` whenever we have leader z. Stock `follow` settles
-- "ok / observed no movement" or dies on WMO floor-diverge while the bot
-- never walks. Point-move lag (~cadence) is better than standing still.
-- Stock follow only if leader has no z (fallback).
local VERTICAL_DEST_DZ = 2.5

local function leader_pos_reliable(leader)
  -- Host sets false when only stale party packets exist (no units obs,
  -- no elevation, no leader-slot overlay). Missing field = tests / trusted.
  if leader == nil then return false end
  if leader.position_reliable == false then return false end
  return true
end

local function rejoin_intent(leader, me, near, far, d2, reason)
  local urgent = d2 > far * far
  local intent = {
    kind = "move_to_unit",
    unit_id = leader.id,
    stop_range = near,
    urgent = urgent,
    reason = reason or "rejoin_formation",
  }
  -- Stale party xy+fake z must not become destination moves: they walk to a
  -- frozen square and then hold:in_formation while the human is far away.
  -- Stock follow tracks the live party unit in the client.
  if not leader_pos_reliable(leader) or not has_z(leader) then
    if not leader_pos_reliable(leader) then
      intent.urgent = true
      intent.reason = (reason or "rejoin_formation") .. "_stale_follow"
    end
    return intent
  end
  intent.x = leader.x
  intent.y = leader.y
  intent.z = leader.z
  if leader.map_id ~= nil then
    intent.map_id = leader.map_id
  elseif me and me.map_id ~= nil then
    intent.map_id = me.map_id
  else
    intent.map_id = 0
  end
  local vertical = false
  if me and has_z(me) then
    local dz = leader.z - me.z
    if dz < 0 then dz = -dz end
    vertical = dz > VERTICAL_DEST_DZ
  end
  if vertical then
    intent.reason = (reason or "rejoin_formation") .. "_vertical"
  elseif urgent then
    intent.reason = (reason or "rejoin_formation") .. "_urgent_dest"
  else
    intent.reason = (reason or "rejoin_formation") .. "_dest"
  end
  return intent
end

local function guid_nonzero(g)
  if g == nil then return false end
  local s = tostring(g)
  return s ~= "" and s ~= "0"
end

local function lower(s)
  return tostring(s or ""):lower()
end

local function name_matches(spell_name, want)
  local n = lower(spell_name)
  local w = lower(want)
  return n == w or n:find(w, 1, true) ~= nil
end

local function find_attackable_by_guid(attackable, guid)
  if not attackable or not guid_nonzero(guid) then return nil end
  local want = tostring(guid)
  for i = 1, #attackable do
    local u = attackable[i]
    if u and u.guid ~= nil and tostring(u.guid) == want then
      return u
    end
  end
  return nil
end

-- Invite allowlist: fail-closed when empty (kb/nim-control-v2-no-select.md).
local function invite_names(args, party)
  local list = args and (args.allowlist or args.invite_allowlist)
  if type(list) == "table" and #list > 0 then return list end
  local names = {}
  if args and args.leader and tostring(args.leader) ~= "" then
    names[#names + 1] = tostring(args.leader)
  end
  if party and party.leader_name and tostring(party.leader_name) ~= "" then
    names[#names + 1] = tostring(party.leader_name)
  end
  return names
end

local function should_accept_invite(party, args)
  if not party or not party.invite_pending then return false end
  local from = lower(party.invite_from)
  if from == "" then return false end
  local names = invite_names(args, party)
  if #names == 0 then return false end
  for i = 1, #names do
    if from == lower(names[i]) then return true end
  end
  return false
end

-- v2 projectV2: leader_unit is top-level; legacy frames nest under party.
local function resolve_leader(frame)
  if frame.leader_unit ~= nil then return frame.leader_unit end
  if frame.party and frame.party.leader_unit ~= nil then
    return frame.party.leader_unit
  end
  return nil
end

local function pick_cast(casts, target_id, priority)
  if not casts then return nil end
  for pi = 1, #priority do
    local want = priority[pi]
    for i = 1, #casts do
      local c = casts[i]
      if c and c.target == target_id and name_matches(c.name, want) then
        return c
      end
    end
  end
  return nil
end

local function pick_self_cast(casts, priority)
  return pick_cast(casts, 0, priority)
end

local function is_offensive_cast(c)
  if not c or not c.target or c.target <= 0 then return false end
  local n = lower(c.name)
  if name_matches(n, "shadow bolt") then return true end
  if name_matches(n, "corruption") then return true end
  if name_matches(n, "immolate") then return true end
  if name_matches(n, "curse of agony") then return true end
  if name_matches(n, "shoot") then return true end
  if name_matches(n, "drain") then return true end
  if name_matches(n, "searing pain") then return true end
  if name_matches(n, "smite") then return true end
  if name_matches(n, "mind blast") then return true end
  if name_matches(n, "shadow word: pain") then return true end
  if name_matches(n, "heroic strike") then return true end
  if name_matches(n, "sunder") then return true end
  if name_matches(n, "revenge") then return true end
  if name_matches(n, "thunder clap") then return true end
  return false
end

local function warlock_rotation(casts, target_id, mana_pct)
  if (mana_pct or 100) < OOM_MANA then
    local wand = pick_cast(casts, target_id, WAND_PRIORITY)
    if wand then return wand, "wand_oom" end
    return nil, nil
  end
  local dot = pick_cast(casts, target_id, DOT_PRIORITY)
  if dot then return dot, "apply_dot" end
  local bolt = pick_cast(casts, target_id, FILLER_PRIORITY)
  if bolt then return bolt, "shadow_bolt" end
  local wand = pick_cast(casts, target_id, WAND_PRIORITY)
  if wand then return wand, "wand" end
  return nil, nil
end

local function cast_intent(c, why)
  return {
    kind = "cast_spell",
    unit_id = c.target,
    spell = c.spell,
    reason = (why or "cast") .. ":" .. lower(c.name),
  }
end

local function any_offensive_on_target(casts, target_id)
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target == target_id and is_offensive_cast(c) then
      return c
    end
  end
  return nil
end

local function tank_rotation(casts, target_id)
  local threat = pick_cast(casts, target_id, TANK_THREAT_PRIORITY)
  if threat then return threat, "tank_threat" end
  -- Battle Shout is often self-target (0).
  local shout = pick_self_cast(casts, { "battle shout" })
  if shout then return shout, "tank_buff" end
  return nil, nil
end

local function healer_rotation(casts, target_id, mana_pct, hp_pct)
  -- Prefer heals/shields on any cast-mask target (self=0 or party indices).
  for pi = 1, #HEAL_PRIORITY do
    local want = HEAL_PRIORITY[pi]
    for i = 1, #casts do
      local c = casts[i]
      if c and name_matches(c.name, want) then
        -- Skip expensive heals when full health and cast is self-only.
        if (hp_pct or 100) >= 95 and (c.target or 0) == 0
            and not name_matches(c.name, "shield") then
          -- fall through
        else
          return c, "heal"
        end
      end
    end
  end
  if target_id and target_id > 0 and (mana_pct or 100) >= OOM_MANA then
    local dmg = pick_cast(casts, target_id, PRIEST_DAMAGE_PRIORITY)
    if dmg then return dmg, "priest_dmg" end
  end
  return nil, nil
end

local function role_combat_intent(role, casts, target_id, mana_pct, hp_pct, focused)
  if not target_id or target_id <= 0 then
    return nil
  end
  if role == "tank" then
    local cast, why = tank_rotation(casts, target_id)
    if cast then return cast_intent(cast, why) end
    if focused then
      return {
        kind = "attack_unit",
        unit_id = focused.id,
        reason = "tank_melee",
      }
    end
    return {
      kind = "attack_unit",
      unit_id = target_id,
      reason = "tank_melee",
    }
  end
  if role == "healer" then
    local cast, why = healer_rotation(casts, target_id, mana_pct, hp_pct)
    if cast then return cast_intent(cast, why) end
    local any = any_offensive_on_target(casts, target_id)
    if any then return cast_intent(any, "cast_any") end
    return nil
  end
  -- dps (warlock / default)
  local cast, why = warlock_rotation(casts, target_id, mana_pct)
  if cast then return cast_intent(cast, why) end
  local any = any_offensive_on_target(casts, target_id)
  if any then return cast_intent(any, "cast_any") end
  return nil
end

local function any_shadow_bolt(casts)
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target and c.target > 0 and name_matches(c.name, "shadow bolt") then
      return c
    end
  end
  return nil
end

local function any_offensive(casts)
  for i = 1, #casts do
    local c = casts[i]
    if is_offensive_cast(c) then
      return c
    end
  end
  return nil
end

local function has_cast_on(casts, target_id)
  if not casts or not target_id or target_id <= 0 then return false end
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target == target_id then
      return true
    end
  end
  return false
end

-- Ghost corpse run: hop toward the body instead of one long blocked move.
local function ghost_corpse_move(me, corpse)
  local cx = corpse.x
  local cy = corpse.y
  local cz = corpse.z or 0
  local map_id = corpse.map_id or 0
  if not me or me.x == nil or me.y == nil then
    return {
      kind = "move_to_corpse",
      map_id = map_id,
      x = cx, y = cy, z = cz,
      reason = "move_to_corpse",
    }
  end
  local dx = cx - me.x
  local dy = cy - me.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= CORPSE_HOP + 2.0 then
    return {
      kind = "move_to_corpse",
      map_id = map_id,
      x = cx, y = cy, z = cz,
      reason = "move_to_corpse",
    }
  end
  local scale = CORPSE_HOP / d
  local mx = me.z or cz
  return {
    kind = "move_to_corpse",
    map_id = map_id,
    x = me.x + dx * scale,
    y = me.y + dy * scale,
    z = mx + (cz - mx) * scale,
    reason = "move_to_corpse_hop",
  }
end

-- Defensive: nearest attackable hostile (2d). Used when fighting with no focus.
local function nearest_attackable(me, attackable)
  if not attackable then return nil end
  local best, best_d2 = nil, nil
  for i = 1, #attackable do
    local u = attackable[i]
    if u and u.id and u.id > 0 then
      if me and u.x ~= nil and u.y ~= nil and me.x ~= nil and me.y ~= nil then
        local d2 = dist2(me, u)
        if best_d2 == nil or d2 < best_d2 then
          best, best_d2 = u, d2
        end
      elseif best == nil then
        best = u
      end
    end
  end
  return best
end

local function unit_range(me, u)
  if not me or not u or me.x == nil or u.x == nil or me.y == nil or u.y == nil then
    return nil
  end
  return math.sqrt(dist2(me, u))
end

-- Walk into cast range of a hostile. Prefer destination move when xy known
-- (stock follow on mobs is flaky); graft self z when unit z missing.
local function approach_unit(me, u, reason)
  local intent = {
    kind = "move_to_unit",
    unit_id = u.id,
    stop_range = CAST_APPROACH * 0.55,
    urgent = true,
    reason = reason or "approach_cast_range",
  }
  if u.x ~= nil and u.y ~= nil then
    intent.x = u.x
    intent.y = u.y
    intent.z = u.z
    if intent.z == nil and me and me.z ~= nil then
      intent.z = me.z
    end
    if intent.z == nil then
      intent.z = 0
    end
    intent.map_id = u.map_id or (me and me.map_id) or 0
  end
  return intent
end

local function find_attackable_by_id(attackable, id)
  if not attackable or not id then return nil end
  for i = 1, #attackable do
    local u = attackable[i]
    if u and u.id == id then return u end
  end
  return nil
end

-- Cast on a masked target that sits near the leader (join his pull only).
local function join_leader_cast(casts, attackable, leader)
  if not casts or not leader or leader.x == nil then return nil end
  local band2 = JOIN_LEADER_BAND * JOIN_LEADER_BAND
  local best, best_d2 = nil, nil
  for i = 1, #casts do
    local c = casts[i]
    if is_offensive_cast(c) and c.target and c.target > 0 then
      local u = find_attackable_by_id(attackable, c.target)
      if u and u.x ~= nil and u.y ~= nil then
        local d2 = dist2(leader, u)
        if d2 <= band2 and (best_d2 == nil or d2 < best_d2) then
          best, best_d2 = c, d2
        end
      end
    end
  end
  return best
end

-- Nearest attackable within band of the leader (join pull, not free-fire zone).
local function nearest_near_leader(leader, attackable, band)
  if not leader or leader.x == nil or not attackable then return nil end
  local band2 = (band or JOIN_LEADER_BAND) * (band or JOIN_LEADER_BAND)
  local best, best_d2 = nil, nil
  for i = 1, #attackable do
    local u = attackable[i]
    if u and u.id and u.id > 0 and u.x ~= nil and not u.lootable then
      local d2 = dist2(leader, u)
      if d2 ~= nil and d2 <= band2 and (best_d2 == nil or d2 < best_d2) then
        best, best_d2 = u, d2
      end
    end
  end
  return best
end

return registry.register({
  name = "escort_leader",
  when = "In party with a human leader: formation + role combat (tank/healer/dps).",
  decide = function(frame, args)
    args = args or {}
    local near = args.near or DEFAULT_NEAR
    local far = args.far or DEFAULT_FAR
    local me = frame.self_unit
    local party = frame.party or {}
    local leader = resolve_leader(frame)
    local combat = frame.combat or {}
    local casts = combat.casts or {}
    local mana = combat.mana_pct or 100
    local hp = combat.health_pct or 100
    local death = frame.death or {}
    local role = args.role or role_for_class(me and me.class_id or args.class_id)

    -- Death recovery FIRST (fair-play only). Never assist/cast while dead/ghost.
    if death.is_dead and not death.is_ghost then
      if death.can_release_spirit then
        return { kind = "release_spirit", reason = "release_spirit" }
      end
      return { kind = "hold", reason = "dead_waiting_release" }
    end
    if death.is_ghost then
      if death.can_reclaim_corpse and death.can_reclaim_action then
        return { kind = "reclaim_corpse", reason = "reclaim_corpse" }
      end
      local corpse = death.corpse
      if death.can_move and corpse and corpse.x ~= nil and corpse.y ~= nil then
        return ghost_corpse_move(me, corpse)
      end
      return { kind = "hold", reason = "ghost_waiting_corpse" }
    end

    -- Accept invite from allowlist (fail-closed). v2 party.invite_*.
    if should_accept_invite(party, args) then
      return { kind = "accept_party", reason = "accept_invite_allowlist" }
    end

    if not me then return nil end
    if not leader or not leader.visible then
      return { kind = "hold", reason = "leader_not_visible" }
    end

    -- Party packets freeze leader xy (classic human has no control overlay).
    -- Do not trust dist/hold while position_reliable is false — stock follow.
    local pos_ok = leader_pos_reliable(leader)
    if not pos_ok then
      -- v2: no auto_attack_guid; in_combat alone is the engaged signal.
      local engaged_early = combat.in_combat or guid_nonzero(combat.auto_attack_guid)
      if not engaged_early then
        return rejoin_intent(leader, me, near, far, far * far + 1, "rejoin_stale")
      end
    end

    -- Hostile focus: legacy frames use auto_attack_guid/focus_guid + attackable.guid;
    -- projectV2 only provides combat.focus_id + attackable[].id (no guids).
    local prefer = combat.auto_attack_guid
    if not guid_nonzero(prefer) then
      prefer = combat.focus_guid
    end
    local focused = find_attackable_by_guid(combat.attackable, prefer)
    local target_id = focused and focused.id or nil
    if (not target_id or target_id == 0) and combat.focus_id and combat.focus_id > 0 then
      local fid = combat.focus_id
      local still_attackable = false
      for i = 1, #(combat.attackable or {}) do
        local u = combat.attackable[i]
        if u and u.id == fid then
          still_attackable = true
          target_id = fid
          focused = u
          break
        end
      end
      if not still_attackable then
        -- Stale focus_id (self/party/corpse): ignore.
        target_id = nil
      end
    end

    -- Engaged = we are in combat or already swinging. OOC focus is kept only
    -- when it resolves to an attackable (client target) — not wiped, so assist
    -- handoff and sticky targets work; we never free-fire non-focus casts OOC.
    local engaged = combat.in_combat or guid_nonzero(combat.auto_attack_guid)

    -- Defensive: in combat with no usable focus → nearest attackable.
    if (not target_id or target_id == 0) and combat.in_combat then
      local near_h = nearest_attackable(me, combat.attackable)
      if near_h then
        focused = near_h
        target_id = near_h.id
      end
    end

    local d2 = dist2(me, leader)
    local dz = 0
    if has_z(me) and has_z(leader) then
      dz = leader.z - me.z
      if dz < 0 then dz = -dz end
    end
    local out_of_near = (d2 > near * near) or (dz > 2.5)
    local out_of_leash = (d2 > COMBAT_LEASH * COMBAT_LEASH) or (dz > 4.0)
    local out_of_far = (d2 > far * far) or (dz > 8.0)

    -- Life Tap when dry (casters only) — still beats combat spam.
    if role ~= "tank" and mana < LIFE_TAP_MANA and hp >= LIFE_TAP_MIN_HP then
      local tap = pick_self_cast(casts, { "life tap" })
      if tap then
        return cast_intent(tap, "life_tap")
      end
    end

    -- FORMATION FIRST: lost the human → rejoin. Beats combat thrash while
    -- Murist runs ahead (live: tank 80yd behind still swinging).
    if out_of_far or (out_of_leash and not engaged) then
      return rejoin_intent(leader, me, near, far, d2, "rejoin_far")
    end
    if out_of_leash and engaged then
      return rejoin_intent(leader, me, near, far, d2, "rejoin_leash")
    end

    -- OOC: join hostiles near the leader BEFORE soft rejoin. Soft rejoin used
    -- to monopolize 8–18y formation gaps and starve combat join forever.
    -- When already engaged, fall through to focus/defend combat paths.
    -- Live OOC: attack kind is often FALSE (empty attackable); assist on the
    -- leader remains masked. Join via assist when leader is fighting — never
    -- when he is full-health idle (that freezes seats with assist-spam).
    if not engaged then
      local join = join_leader_cast(casts, combat.attackable, leader)
      if join then
        return cast_intent(join, "join_leader_band")
      end
      local near_l = nearest_near_leader(leader, combat.attackable, JOIN_LEADER_BAND)
      if near_l then
        local on = any_offensive_on_target(casts, near_l.id)
        if on then
          return cast_intent(on, "join_leader_hostile")
        end
        local rng = unit_range(me, near_l)
        if rng == nil or rng > MELEE_RANGE then
          return approach_unit(me, near_l, "join_leader_approach")
        end
        return {
          kind = "attack_unit",
          unit_id = near_l.id,
          reason = "join_leader_attack",
        }
      end
      -- Assist is a hand-off into leader combat, not a steady state.
      -- Prefer near-leader cast/attack/approach (above). Require real damage
      -- on the leader (health_pct < 99.5). Full-HP in_combat is sticky AA
      -- theater and must not spam assist every ready frame.
      -- Also skip assist when we already have a client focus/AA guid even if
      -- not yet marked engaged (hand-off already started).
      local leader_hp = tonumber(leader.health_pct)
      local leader_damaged = leader_hp ~= nil and leader_hp < 99.5
      -- v2: focus_id path already resolved into target_id; guids are legacy-only.
      local has_focus = (target_id and target_id > 0)
        or guid_nonzero(combat.focus_guid)
        or guid_nonzero(combat.auto_attack_guid)
      if leader_damaged and leader.assistable and leader.id and leader.id > 0
          and not has_focus then
        return {
          kind = "assist_unit",
          unit_id = leader.id,
          reason = "join_leader_assist",
        }
      end
    end

    -- Soft rejoin when outside near band (OOC or not on a real focus).
    if out_of_near and (not engaged or not target_id or target_id == 0) then
      return rejoin_intent(leader, me, near, far, d2, "rejoin_formation")
    end

    -- === Combat on a real focus (in combat / AA / client focus on attackable) ===
    if target_id and target_id > 0 and (engaged or has_cast_on(casts, target_id)) then
      local combat_intent = role_combat_intent(
        role, casts, target_id, mana, hp, focused
      )
      if combat_intent then
        return combat_intent
      end
      if role ~= "tank" then
        local on_focus = any_offensive_on_target(casts, target_id)
        if on_focus then
          return cast_intent(on_focus, "cast_focus")
        end
        local rng = focused and unit_range(me, focused) or nil
        if focused and (rng == nil or rng > MELEE_RANGE) then
          return approach_unit(me, focused, "approach_cast_range")
        end
        if focused and engaged then
          local wand = pick_cast(casts, target_id, WAND_PRIORITY)
          if wand then
            return cast_intent(wand, "wand_melee_band")
          end
          return {
            kind = "attack_unit",
            unit_id = target_id,
            reason = "caster_melee_band",
          }
        end
      end
      if role == "tank" and engaged then
        return {
          kind = "attack_unit",
          unit_id = target_id,
          reason = "defend_melee_fallback",
        }
      end
    end

    -- Mirror leader target only while already engaged (OOC assist freezes seats).
    if combat.in_combat
        and (not target_id or target_id == 0)
        and leader.assistable then
      return {
        kind = "assist_unit",
        unit_id = leader.id,
        reason = "mirror_leader_target",
      }
    end

    -- In combat, no focus: defend nearest (only while engaged).
    if combat.in_combat and (not target_id or target_id == 0) then
      local near_h = nearest_attackable(me, combat.attackable)
      if near_h then
        local cast = any_offensive_on_target(casts, near_h.id)
        if cast then
          return cast_intent(cast, "defend_cast_nearest")
        end
        if role ~= "tank" then
          local rng = unit_range(me, near_h)
          if rng == nil or rng > MELEE_RANGE then
            return approach_unit(me, near_h, "approach_cast_range")
          end
        end
        return {
          kind = "attack_unit",
          unit_id = near_h.id,
          reason = "defend_nearest_hostile",
        }
      end
      return { kind = "hold", reason = "in_combat_no_hostile" }
    end

    -- OOM on engaged focus only.
    if role == "dps" and engaged and mana < OOM_MANA and target_id and target_id > 0 then
      local wand = pick_cast(casts, target_id, WAND_PRIORITY)
      if wand then
        return cast_intent(wand, "wand_oom")
      end
      local rng = focused and unit_range(me, focused) or nil
      if focused and (rng ~= nil and rng <= MELEE_RANGE) then
        return {
          kind = "attack_unit",
          unit_id = focused.id,
          reason = "dagger_oom_only",
        }
      end
      if focused then
        return approach_unit(me, focused, "approach_cast_range")
      end
    end

    if not engaged then
      local buffs = BUFF_PRIORITY
      if role == "healer" then
        buffs = PRIEST_BUFF_PRIORITY
      elseif role == "tank" then
        buffs = { "battle shout" }
      end
      local buff = pick_self_cast(casts, buffs)
      if buff then
        return cast_intent(buff, "self_buff")
      end
    end

    -- Never idle-hold on untrusted leader coords (live failure mode).
    if not pos_ok then
      return rejoin_intent(leader, me, near, far, far * far + 1, "rejoin_stale")
    end

    return { kind = "hold", reason = "in_formation" }
  end,
})
