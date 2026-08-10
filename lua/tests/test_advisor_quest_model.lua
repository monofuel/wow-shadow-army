local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.questModel

local zones = { [14] = "Durotar", [215] = "Mulgore" }
local taurenData = {
  ["The Hunt Begins"] = {
    zone = 215,
    objectives = {
      {
        label = "Plainstrider Feather", count = 7,
        spots = { { zone = 215, x = 48, y = 62 } },
      },
    },
    turnIn = { label = "Grull Hawkwind", zone = 215, x = 44, y = 76 },
  },
}

local r = model.build({
  quests = {
    {
      title = "The Hunt Begins", header = "Red Cloud Mesa",
      objectives = { { text = "Plainstrider Feather: 2/7", have = 2, need = 7 } },
    },
  },
  data = taurenData, zoneNames = zones, currentZone = "Mulgore",
  pos = { x = 45, y = 70 },
})
check(#r.list == 1, "Tauren quest remains listed across subzone header")
check(#r.list[1].objs == 1 and r.list[1].objs[1].text == "Plainstrider Feather: 2/7",
  "live objective text is authoritative")
check(r.list[1].objs[1].dist ~= nil and #r.candidates == 1,
  "Mulgore parent-zone waypoint enriches Red Cloud Mesa quest")

r = model.build({
  quests = {
    { title = "Unknown Quest", header = "Mulgore", objectives = {
      { text = "Do the unknown thing: 1/4", have = 1, need = 4 },
    } },
  },
  data = {}, currentZone = "Mulgore",
})
check(#r.list == 1 and #r.list[1].objs == 1, "missing QuestData never hides quest")
check(#r.candidates == 0 and r.list[1].objs[1].dist == nil,
  "missing position/data produces no misleading marker")

r = model.build({
  quests = {
    { title = "The Hunt Begins", header = "Red Cloud Mesa", objectives = {
      { text = "Plainstrider Feather: 2/7", have = 2, need = 7 },
    } },
  },
  data = taurenData, zoneNames = zones, currentZone = "Durotar",
  pos = { x = 45, y = 70 },
})
check(#r.list == 1 and #r.candidates == 0, "out-of-zone objective remains without pin")
check(r.list[1].objs[1].zoneName == "Mulgore", "out-of-zone objective names destination")

r = model.build({
  quests = { { title = "The Hunt Begins", header = "Red Cloud Mesa", complete = true } },
  data = taurenData, zoneNames = zones, currentZone = "Mulgore",
  pos = { x = 45, y = 70 },
})
check(r.list[1].complete and r.list[1].objs[1].turnIn, "complete quest shows turn-in row")
check(r.list[1].objs[1].text == "Turn in: Grull Hawkwind" and #r.candidates == 1,
  "mapped local turn-in is enriched")

r = model.build({ quests = { { title = "No Data Complete", complete = true } } })
check(#r.list == 1 and r.list[1].objs[1].text == "Ready to turn in",
  "unmapped complete quest still shows ready status")

r = model.build({ quests = { { title = "No Objectives Yet" } } })
check(#r.list == 1 and #r.list[1].objs == 0 and r.list[1].status == "In progress",
  "zero-objective accepted quest remains listed")

r = model.build({
  quests = { { title = "The Hunt Begins", failed = true, objectives = {
    { text = "Plainstrider Feather: 2/7", have = 2, need = 7 },
  } } },
  data = taurenData, zoneNames = zones, currentZone = "Mulgore",
  pos = { x = 45, y = 70 },
})
check(r.list[1].failed and r.list[1].status == "Failed" and #r.candidates == 0,
  "failed quest remains listed without actionable markers")

local many = {}
local i = 1
while i <= 12 do
  many[i] = { title = "Quest " .. i, objectives = { { text = "Objective " .. i } } }
  i = i + 1
end
r = model.build({ quests = many })
check(#r.list == 12, "complete model does not cap quests to compact panel size")

-- Synthetic vanilla log: collapsed Red Cloud Mesa initially hides its quest.
local expanded = false
local selected = 1
local function entries()
  if expanded then
    return {
      { "Red Cloud Mesa", true, false },
      { "The Hunt Begins", false, false },
      { "Mulgore", true, false },
      { "A Task", false, false },
    }
  end
  return {
    { "Red Cloud Mesa", true, true },
    { "Mulgore", true, false },
    { "A Task", false, false },
  }
end
local live = model.readLog({
  selection = function() return selected end,
  numEntries = function() return #entries() end,
  title = function(index)
    local e = entries()[index]
    return e[1], nil, nil, e[2], e[3], false
  end,
  expand = function() expanded = true end,
  collapse = function() expanded = false end,
  select = function(index) selected = index end,
  watched = function() return {} end,
  boards = function(index)
    if entries()[index][1] == "The Hunt Begins" then
      return { { text = "Plainstrider Feather: 2/7", have = 2, need = 7 } }, 1
    end
    return {}, 0
  end,
})
check(#live == 2 and live[1].title == "The Hunt Begins",
  "collapsed header quests are included")
check(not expanded and selected == 1, "collapsed state and selection are restored")

print("test_advisor_quest_model: " .. passed .. " checks passed")
