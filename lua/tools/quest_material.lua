-- Ordinary quest-material procurement: pure facts, no state, no IO.
--
-- needs(view) lists accepted, unfailed quests' incomplete item objectives and
-- how many items are still missing. plan(view, need) prices the smallest legal
-- purchase from the OPEN merchant's observed rows, or says exactly why not.
-- Nothing here knows any quest, item, NPC, place or price; every number comes
-- from the view the host projected this tick.
local M = {}

local function int(v) return tonumber(v) and math.floor(tonumber(v)) or nil end

-- Carried count of one item id across bag rows, plus the room its existing
-- stacks still have. `room_known` is false when a row's stack size is unknown.
function M.carried(view, item_id)
  local count, room, room_known = 0, 0, true
  for _, row in ipairs(view.inventory_items or {}) do
    if int(row.item_id) == item_id then
      local n = int(row.count) or 0
      count = count + n
      local max_stack = int(row.max_stack_size) or 0
      if max_stack > 0 then
        room = room + math.max(0, max_stack - n)
      else
        room_known = false
      end
    end
  end
  return count, room, room_known
end

-- Keep even satisfied requirements until the accepted quest leaves the log:
-- ordinary trade goods, weapons and junk may also be turn-in objectives.
function M.objective_item_ids(view)
  local live, keep = {}, {}
  for _, q in ipairs(view.accepted_quests or {}) do
    live[int(q.quest_id) or 0] = true
  end
  for _, o in ipairs(view.quest_objectives or {}) do
    local item_id = int(o.item_id) or 0
    if item_id > 0 and live[int(o.quest_id) or 0] then keep[item_id] = true end
  end
  return keep
end

function M.needs(view)
  local live = {}
  for _, q in ipairs(view.accepted_quests or {}) do
    if not q.failed then live[int(q.quest_id) or 0] = true end
  end
  local out = {}
  for _, o in ipairs(view.quest_objectives or {}) do
    local quest_id, item_id = int(o.quest_id) or 0, int(o.item_id) or 0
    local required, current = int(o.required) or 0, int(o.current) or 0
    if live[quest_id] and item_id > 0 and not o.complete and required > current then
      -- The objective counter can lag a fresh purchase; carried items count.
      local have = math.max(current, (M.carried(view, item_id)))
      if have < required then
        out[#out + 1] = { quest_id = quest_id, item_id = item_id,
          required = required, have = have, missing = required - have }
      end
    end
  end
  return out
end

function M.offer(view, item_id)
  if not view.merchant_open then return nil end
  for _, row in ipairs(view.merchant_offers or {}) do
    if int(row.item_id) == item_id then return row end
  end
  return nil
end

-- Returns { bundles, items, cost, price } or nil, reason.
function M.plan(view, need)
  local row = M.offer(view, need.item_id)
  if not row then return nil, "not_listed" end
  local price = int(row.price)
  if price == nil then return nil, "price_unknown" end
  local per = math.max(1, int(row.buy_count) or 1)
  local bundles = math.ceil(need.missing / per)
  if bundles < 1 or bundles > 255 then return nil, "count_out_of_range" end
  local items = bundles * per
  local stock = int(row.stock)
  if stock == nil then return nil, "stock_unknown" end
  if stock ~= -1 and stock < items then return nil, "sold_out" end
  if not view.copper_known then return nil, "funds_unknown" end
  local cost = price * bundles
  if cost > (int(view.copper) or 0) then return nil, "insufficient_funds" end
  if not view.bag_space_known then return nil, "bags_unknown" end
  local _, room, room_known = M.carried(view, need.item_id)
  if room < items then
    local free = int(view.free_bag_slots) or 0
    local max_stack = int(row.max_stack_size) or 0
    if free > 0 and max_stack <= 0 then return nil, "stack_size_unknown" end
    if not room_known and free == 0 then return nil, "stack_room_unknown" end
    if room + free * max_stack < items then return nil, "bags_full" end
  end
  return { bundles = bundles, items = items, cost = cost, price = price }
end

return M
