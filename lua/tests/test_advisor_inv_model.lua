-- Inventory-over-chat encoder (ticket 0052). The transport is the addon's
-- one outbound channel — F.emit -> SendChatMessage(SAY) -> Chat.log -> The
-- System's tail — so everything that decides what goes ON that line is here,
-- pure, and checked on host Lua.
local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.invModel

local function count(t)
  local n = 0
  while t[n + 1] ~= nil do n = n + 1 end
  return n
end

-- Rejoin a whole line-set back into the tokens it carried, checking the
-- <seq>/<total> header on the way. This is the exact inverse of what the
-- System-side parser has to do.
local function decode(lines, n, kind)
  local tokens, nt = {}, 0
  local i = 1
  while i <= n do
    local line = model.chatLine(kind, lines[i])
    check(string.len(line) <= model.LINE_MAX,
      "every " .. kind .. " line fits LINE_MAX (line " .. i .. ")")
    local _, _, seq, total, payload = string.find(lines[i], "^(%d+)/(%d+) ?(.*)$")
    check(tonumber(seq) == i and tonumber(total) == n,
      "line " .. i .. " is numbered " .. i .. "/" .. n)
    if payload ~= "" then
      local pos = 1
      while pos do
        local comma = string.find(payload, ",", pos, true)
        nt = nt + 1
        tokens[nt] = string.sub(payload, pos, comma and (comma - 1) or -1)
        pos = comma and (comma + 1) or nil
      end
    end
    i = i + 1
  end
  return tokens, nt
end

local function joined(tokens, n)
  local out = ""
  local i = 1
  while i <= n do
    out = out .. (i > 1 and "," or "") .. tokens[i]
    i = i + 1
  end
  return out
end

--------------------------------------------------------------------------
-- aggregate: bag slots -> one count per item id
--------------------------------------------------------------------------

local agg = model.aggregate({
  { id = 2589, count = 20 },   -- Linen Cloth, bag 0
  { id = 4306, count = 5 },
  { id = 2589, count = 12 },   -- ... and a second stack in bag 1
  { id = 6948 },               -- Hearthstone: no count field
})
check(agg[2589] == 32, "stacks of the same id across bags sum into one count")
check(agg[4306] == 5 and agg[6948] == 1, "a countless slot counts as one")

check(count(model.snapshotTokens(model.aggregate({ { count = 4 } }))) == 0,
  "a bag slot whose link did not parse is dropped, not sent as item nil")
check(count(model.snapshotTokens(model.aggregate({}))) == 0,
  "no bag slots aggregate to nothing")

--------------------------------------------------------------------------
-- full snapshot: encoding, ordering, chunking math
--------------------------------------------------------------------------

local lines, n = model.snapshotLines(agg)
check(n == 1 and lines[1] == "1/1 2589:32,4306:5,6948:1",
  "a small inventory is one ascending id:count line")
check(model.chatLine("inv", lines[1]) == "<SA> inv 1/1 2589:32,4306:5,6948:1",
  "the wire line is <SA> inv <seq>/<total> <pairs>")

lines, n = model.snapshotLines({})
check(n == 1 and lines[1] == "1/1",
  "empty bags still send one line — empty is a fact, not silence")

-- 200 distinct items is well past what 16-slot vanilla bags hold; the point
-- is that the chunker is the thing keeping us inside the chat line limit,
-- not the size of a real inventory.
local big = {}
local i = 1
while i <= 200 do
  big[1000 + i] = 20 + i
  i = i + 1
end
lines, n = model.snapshotLines(big)
check(n > 1, "an inventory past one line's budget splits across numbered lines")
local tokens, nt = decode(lines, n, "inv")
check(nt == 200, "every item survives the split exactly once")
check(tokens[1] == "1001:21" and tokens[200] == "1200:220",
  "split lines stay in one ascending id order end to end")
check(count(lines) == n, "the returned line count matches the array")

-- The ~28-items-per-line figure the ticket sizes the design around.
local perLine = 0
local _, _, firstPayload = string.find(lines[1], "^%d+/%d+ (.*)$")
i = 1
while i <= string.len(firstPayload) do
  if string.sub(firstPayload, i, i) == "," then perLine = perLine + 1 end
  i = i + 1
end
check(perLine + 1 >= 25, "a full line carries ~28 id:count pairs, not a handful")

-- Budget is a parameter so the packing can be proven at a size a test can read.
lines, n = model.snapshotLines(big, 40)
check(n > 20, "a tiny line budget produces many small lines")
tokens, nt = decode(lines, n, "inv")
check(nt == 200, "shrinking the budget never loses an item")
check(model.budget("inv") == model.LINE_MAX - string.len("<SA> inv ") - model.HEADER_MAX,
  "payload budget = line max minus the emit prefix minus the widest header")
check(model.budget("invd") == model.budget("inv") - 1,
  "the delta kind is one char wider and gets one char less payload")

--------------------------------------------------------------------------
-- deltas: two bag states in, a patch out
--------------------------------------------------------------------------

local before = { [2589] = 32, [4306] = 5, [6948] = 1 }
local after  = { [2589] = 40, [6948] = 1, [7005] = 1 }

lines, n = model.deltaLines(before, after)
check(n == 1 and lines[1] == "1/1 +2589:40,-4306,+7005:1",
  "a delta sets new totals with +id:count and drops ids with -id")
check(model.chatLine("invd", lines[1]) == "<SA> invd 1/1 +2589:40,-4306,+7005:1",
  "the wire line is <SA> invd <seq>/<total> <changes>")

tokens, nt = model.deltaTokens(before, after)
check(nt == 3, "unchanged ids (6948) produce no token at all")

lines, n = model.deltaLines(before, before)
check(n == 0 and count(lines) == 0,
  "an unchanged bag emits nothing — no line, not an empty one")

tokens, nt = model.deltaTokens(nil, after)
check(joined(tokens, nt) == "+2589:40,+6948:1,+7005:1",
  "with no previous state every item is an add")

tokens, nt = model.deltaTokens(before, {})
check(joined(tokens, nt) == "-2589,-4306,-6948",
  "emptying the bags removes every id")

-- A loot burst debounced into one delta can outgrow a line just like a
-- snapshot can, so deltas are numbered and chunked by the same code.
local bigAfter = {}
i = 1
while i <= 200 do
  bigAfter[1000 + i] = 400 + i   -- every count differs from `big`'s 20 + i
  i = i + 1
end
lines, n = model.deltaLines(big, bigAfter)
check(n > 1, "a large delta splits across numbered lines too")
tokens, nt = decode(lines, n, "invd")
check(nt == 200 and tokens[1] == "+1001:401",
  "every changed id survives the delta split")

print("test_advisor_inv_model: " .. passed .. " checks passed")
