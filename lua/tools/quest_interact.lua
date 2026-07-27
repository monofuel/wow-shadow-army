-- quest_interact: accept/turn-in when masked; otherwise approach questgivers.
-- Avoid sticky accept on empty gossip (dialog open, no offers → rotate NPC).
local registry = require("registry")

local function dist2(a, b)
  if not a or not b or not a.x or not b.x then return nil end
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function has_service(u, name)
  if not u or not u.services then return false end
  for i = 1, #u.services do
    if u.services[i] == name then return true end
  end
  return false
end

local function is_questgiver(u)
  if not u then return false end
  if u.is_questgiver then return true end
  return has_service(u, "questgiver")
end

local function pure_questgiver(u)
  if not is_questgiver(u) then return false end
  if has_service(u, "vendor") then return false end
  if has_service(u, "trainer") then return false end
  if has_service(u, "innkeeper") then return false end
  return true
end

local function pick_interactable(me, list, skip_id)
  local best, best_d2, best_rank = nil, nil, 99
  for i = 1, #(list or {}) do
    local u = list[i]
    if u and u.id and u.id > 0 and u.kind ~= "object" then
      if skip_id == nil or u.id ~= skip_id then
        local rank = 2
        if pure_questgiver(u) then
          rank = 0
        elseif is_questgiver(u) then
          rank = 1
        end
        local d2 = dist2(me, u)
        if best == nil or rank < best_rank or (rank == best_rank and d2 ~= nil and (best_d2 == nil or d2 < best_d2)) then
          best, best_d2, best_rank = u, d2, rank
        end
      end
    end
  end
  return best, best_d2
end

return registry.register({
  name = "quest_interact",
  when = "Open quest dialog and accept offers when masked; rotate empty gossip.",
  decide = function(frame, args)
    args = args or {}
    local me = frame.self_unit
    local quest = frame.quest or {}

    -- Offers: real quest_id only (v2 mapIntent → accept_quest.quest_id).
    -- Observation rows may use id or quest_id; never use quest_factor as the
    -- wire identity (factor was a v1 bindings.quests index).
    -- Discovery (quest_id=0): dialog open, first live offer — executor greets.
    if quest.offers and #quest.offers > 0 then
      local discovery = nil
      for i = 1, #quest.offers do
        local o = quest.offers[i]
        local qid = o.id or o.quest_id or 0
        if qid > 0 then
          return {
            kind = "accept_quest",
            quest_id = qid,
            unit_id = o.entity_id or o.unit_id or 0,
            reason = "accept_offer",
          }
        end
        if discovery == nil then discovery = o end
      end
      if discovery then
        return {
          kind = "accept_quest",
          quest_id = 0,
          unit_id = discovery.entity_id or discovery.unit_id or 0,
          reason = "accept_discovery",
        }
      end
    end

    if quest.turn_ins and #quest.turn_ins > 0 then
      local t = quest.turn_ins[1]
      local qid = t.id or t.quest_id or 0
      return {
        kind = "turn_in_quest",
        quest_id = qid,
        unit_id = t.entity_id or t.unit_id or 0,
        reason = "turn_in_offer",
      }
    end

    local best, best_d2 = pick_interactable(me, quest.interactables, nil)
    if best then
      if best_d2 ~= nil and best_d2 > (6 * 6) and best.x then
        return {
          kind = "move_to_unit",
          unit_id = best.id,
          map_id = best.map_id or (me and me.map_id) or 0,
          x = best.x, y = best.y, z = best.z or 0,
          reason = "approach_npc",
        }
      end
      return { kind = "interact_unit", unit_id = best.id, reason = "interact_npc" }
    end
    return { kind = "hold", reason = "no_quest_surface" }
  end,
})
