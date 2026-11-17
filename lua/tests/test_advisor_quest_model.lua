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
check(#r.list[1].objs == 2 and r.list[1].objs[1].text == "Plainstrider Feather: 2/7",
  "live objective text is authoritative")
check(r.list[1].objs[1].dist ~= nil and #r.candidates == 2,
  "Mulgore parent-zone waypoint enriches Red Cloud Mesa quest")
-- r54: an in-progress quest also gets its delivery row + pin, marked pending
-- so it can never take the route line off a live objective.
check(r.list[1].objs[2].turnIn and r.list[1].objs[2].delivery
  and r.list[1].objs[2].text == "Deliver: Grull Hawkwind",
  "in-progress quest carries a delivery row for its ender")
check(r.list[1].objs[2].dist ~= nil,
  "same-zone delivery of an in-progress quest is measured")
local pend = nil
for _, c in ipairs(r.candidates) do if c.delivery then pend = c end end
check(pend and pend.pending and pend.turnIn,
  "delivery candidate of an unfinished quest is marked pending")
check(r.list[1].minDist == r.list[1].objs[1].dist,
  "a pending delivery never lowers the checklist sort distance")
check(r.list[1].objs[2].pending == true,
  "the delivery ROW is flagged pending too (the 210px panel skips those)")

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

-- Title collision chains: "Fields of Grief" is quest 365 (gather Tirisfal
-- Pumpkins, turn in to Johaan) AND quest 407 (deliver the Laced Pumpkin to
-- the Captured Scarlet Zealot). The generated entry carries 407 in alts;
-- the live leaderboard labels must pick the right variant.
local griefData = {
  ["Fields of Grief"] = {
    id = 365, level = 7, minLevel = 4, zone = 85,
    objectives = {
      { label = "Tirisfal Pumpkin", kind = "object", count = 10,
        spots = { { zone = 85, x = 32, y = 47 } } },
    },
    turnIn = { label = "Apothecary Johaan", zone = 85, x = 59.4, y = 52.4 },
    alts = {
      {
        id = 407, level = 7, minLevel = 4, zone = 85,
        turnIn = { label = "Captured Scarlet Zealot", zone = 85, x = 61.6, y = 51.5 },
      },
    },
  },
}
local griefZones = { [85] = "Tirisfal Glades" }

check(model.resolve(griefData["Fields of Grief"],
    { { text = "Tirisfal Pumpkin: 3/10" } }).id == 365,
  "part-1 boards resolve to the primary variant")
check(model.resolve(griefData["Fields of Grief"],
    { { text = "Laced Pumpkin: 1/1" } }).id == 407,
  "part-2 boards resolve to the alt variant")
check(model.resolve(griefData["The Missing"], {}) == nil,
  "resolve passes a missing entry through")
check(model.resolve(griefData["Fields of Grief"], nil).id == 407,
  "an empty log favors the variant with no tracked objectives")

r = model.build({
  quests = {
    { title = "Fields of Grief", header = "Tirisfal Glades", complete = true,
      objectives = { { text = "Laced Pumpkin: 1/1", have = 1, need = 1, done = true } } },
  },
  data = griefData, zoneNames = griefZones, currentZone = "Tirisfal Glades",
  pos = { x = 60, y = 52 },
})
check(r.list[1].objs[1].text == "Turn in: Captured Scarlet Zealot",
  "part-2 turn-in points at the Zealot, not part 1's Johaan")

r = model.build({
  quests = {
    { title = "Fields of Grief", header = "Tirisfal Glades", complete = true,
      objectives = { { text = "Tirisfal Pumpkin: 10/10", have = 10, need = 10, done = true } } },
  },
  data = griefData, zoneNames = griefZones, currentZone = "Tirisfal Glades",
  pos = { x = 60, y = 52 },
})
check(r.list[1].objs[1].text == "Turn in: Apothecary Johaan",
  "part-1 turn-in still points at Johaan")

-- `from` = who drops an item objective (QuestData, alphabetical, unranked).
local plagueZones = { [85] = "Tirisfal Glades" }
local plagueData = {
  ["A New Plague"] = {
    zone = 85,
    objectives = {
      {
        label = "Darkhound Blood", kind = "item", count = 5,
        from = { "Cursed Darkhound", "Decrepit Darkhound", "Ravenous Darkhound" },
        spots = { { zone = 85, x = 62.8, y = 38.1 } },
      },
    },
    turnIn = { label = "Apothecary Johaan", zone = 85, x = 59.4, y = 52.4 },
  },
}

r = model.build({
  quests = {
    { title = "A New Plague", header = "Tirisfal Glades", objectives = {
      { text = "Darkhound Blood: 2/5", have = 2, need = 5 },
    } },
  },
  data = plagueData, zoneNames = plagueZones, currentZone = "Tirisfal Glades",
  pos = { x = 60, y = 52 },
})
check(r.list[1].objs[1].from ~= nil, "item objective carries its hunt list")
check(#r.list[1].objs[1].from == 3 and r.list[1].objs[1].from[1] == "Cursed Darkhound",
  "hunt list passes through in QuestData order")

r = model.build({
  quests = {
    { title = "A New Plague", header = "Tirisfal Glades", objectives = {
      { text = "Darkhound Blood: 5/5", have = 5, need = 5, done = true },
    } },
  },
  data = plagueData, zoneNames = plagueZones, currentZone = "Tirisfal Glades",
  pos = { x = 60, y = 52 },
})
check(r.list[1].objs[1].done and r.list[1].objs[1].from == nil,
  "a done objective drops the hunt list")

r = model.build({
  quests = {
    { title = "The Hunt Begins", header = "Red Cloud Mesa", objectives = {
      { text = "Plainstrider Feather: 2/7", have = 2, need = 7 },
    } },
  },
  data = taurenData, zoneNames = zones, currentZone = "Mulgore",
  pos = { x = 45, y = 70 },
})
check(r.list[1].objs[1].from == nil, "an objective with no source list stays bare")

local ft = model.fromText
check(ft(nil) == nil, "no source list says nothing")
check(ft({}) == nil, "an empty source list says nothing")
check(ft({"Kobold Miner"}, 2, nil, " more") == "Kobold Miner",
  "one name renders bare")
check(ft({"Kobold Miner", "Kobold Digger"}, 2, nil, " more") == "Kobold Miner, Kobold Digger",
  "two names join with a comma")
check(ft({"A", "B", "C"}, 2, nil, " more") == "A, B +1 more",
  "the window spells the leftovers out")
check(ft({"Cracked Skull Soldier"}, 2, 24, "") == "Cracked Skull Soldier",
  "one name that fits the panel is untouched")
check(ft({"Cracked Skull Soldier", "Rattlecage Soldier"}, 2, 24, "") == "Cracked Skull Soldier +1",
  "a tight panel width drops the second name for a +1")
check(ft({"Cracked Skull Soldier", "Rattlecage Soldier", "C", "D", "E"}, 2, 24, "") == "Cracked Skull Soldier +4",
  "five names at panel width keep one name and a +4 count")
check(ft({"Extremely Long Mob Name Of Doom"}, 2, 12, "") == "Extremely L+",
  "a single name too long for the width is clipped with a +")
check(string.len(ft({"Cracked Skull Soldier", "Rattlecage Soldier", "C", "D", "E"}, 2, 24, "")) <= 24,
  "the panel hint never exceeds its character budget")

--------------------------------------------------------------------------
-- Identity filtering (ticket 0045). The audit found 336 alt groups where
-- EVERY variant has zero objectives: the label score is a tie for all of
-- them, so the primary always won and the turn-in marker pointed at the
-- other faction's city half the time. The game gates those on race/class,
-- so the player's own identity is the discriminator labels never had.
--------------------------------------------------------------------------

-- Mask arithmetic first: bit = 1 << (id - 1), docs/world-db-queries.md.
check(model.maskBit(1) == 1 and model.maskBit(6) == 32 and model.maskBit(9) == 256,
  "mask bit is 1 << (id - 1)")
check(model.maskBit(nil) == nil and model.maskBit(0) == nil,
  "no id is no bit")
check(model.maskAllows(nil, 32) and model.maskAllows(0, 32),
  "an absent or zero mask is 'anyone' — the generator omits 0 columns")
check(model.maskAllows(-1, 32), "AllowableClass -1 is everyone")
check(model.maskAllows(178, nil),
  "an unknown player bit never excludes a variant")
check(model.maskAllows(178, 32) and not model.maskAllows(178, 1),
  "a Horde race mask admits Tauren and refuses Human")
check(model.maskAllows(1024, 1024) and not model.maskAllows(1024, 512),
  "the high class bits (druid 1024) test cleanly without bitwise ops")

-- Tokens -> bits. UnitRace answers the localized name on this 1.12 build and
-- the CamelCase token on later ones; both have to land on the same id.
local ident = model.identity("Tauren", "WARLOCK")
check(ident.race == 32 and ident.class == 256, "Tauren warlock maps to its bits")
check(model.identity("Night Elf").race == 8 and model.identity("NightElf").race == 8,
  "spaced and squashed race names agree")
check(model.identity("Undead").race == 16 and model.identity("Scourge").race == 16,
  "Undead and Scourge are the same race id")
check(model.identity(nil, "Warlock").class == 256,
  "the class token is matched case-insensitively")
check(model.identity("Murloc", nil) == nil,
  "nothing recognized means no identity, and resolve filters nothing")

-- The faction-mirror shape: one title, two variants, NO objectives on either,
-- different turn-in NPCs, opposing race masks. Alliance = human+dwarf+
-- nightelf+gnome (1+4+8+64), Horde = orc+undead+tauren+troll (2+16+32+128).
local mirror = {
  id = 8, races = 77,
  turnIn = { label = "Stormwind Quartermaster", zone = 1519, x = 60, y = 70 },
  alts = {
    { id = 9, races = 178,
      turnIn = { label = "Orgrimmar Quartermaster", zone = 1637, x = 40, y = 30 } },
  },
}

check(model.resolve(mirror, {}).id == 8,
  "with no identity the mirror still falls back to the primary (old behavior)")
check(model.resolve(mirror, {}, model.identity("Tauren")).id == 9,
  "a Tauren resolves the faction mirror by identity alone, labels never used")
check(model.resolve(mirror, {}, model.identity("Human")).id == 8,
  "a Human resolves the same mirror to the Alliance variant")
check(model.resolve(mirror, { { text = "anything at all" } },
    model.identity("Troll", "WARLOCK")).id == 9,
  "board text cannot outvote identity when only one variant survives")

-- Class gating works the same way (warlock 256 vs mage 128).
local classMirror = {
  id = 20, classes = 256, turnIn = { label = "Demon Trainer" },
  alts = { { id = 21, classes = 128, turnIn = { label = "Portal Trainer" } } },
}
check(model.resolve(classMirror, {}, model.identity("Human", "MAGE")).id == 21,
  "a mage takes the mage variant of a class-gated pair")
check(model.resolve(classMirror, {}, model.identity("Human", "WARLOCK")).id == 20,
  "a warlock takes the warlock variant")

-- Data that excludes everybody is a generator bug, not an answer: fall back
-- to the label path rather than returning something arbitrary.
check(model.resolve(classMirror, {}, model.identity("Human", "DRUID")).id == 20,
  "masks that exclude every variant fall back to label scoring")

-- Identity and labels compose: the filter narrows, the labels decide.
local composed = {
  id = 30, races = 77,
  objectives = { { label = "Silverpine Cloth" } },
  alts = {
    { id = 31, races = 178, objectives = { { label = "Silverpine Cloth" } } },
    { id = 32, races = 178, objectives = { { label = "Laced Pumpkin" } } },
  },
}
check(model.resolve(composed, { { text = "Laced Pumpkin: 1/1" } },
    model.identity("Orc")).id == 32,
  "identity narrows to the Horde pair, labels pick which of the two")
check(model.resolve(composed, { { text = "Silverpine Cloth: 2/6" } },
    model.identity("Orc")).id == 31,
  "the other board text picks the other Horde variant")
check(model.resolve(composed, { { text = "Laced Pumpkin: 1/1" } },
    model.identity("Gnome")).id == 30,
  "an Alliance player never reaches the Horde variants the labels prefer")

-- Maskless data must behave EXACTLY as it did before identity existed.
local taurenIdent = model.identity("Tauren", "WARLOCK")
check(model.resolve(griefData["Fields of Grief"],
    { { text = "Tirisfal Pumpkin: 3/10" } }, taurenIdent).id == 365,
  "maskless variants ignore identity: part-1 boards still resolve to 365")
check(model.resolve(griefData["Fields of Grief"],
    { { text = "Laced Pumpkin: 1/1" } }, taurenIdent).id == 407,
  "maskless variants ignore identity: part-2 boards still resolve to 407")
check(model.resolve(griefData["Fields of Grief"], nil, taurenIdent).id == 407,
  "maskless variants ignore identity: an empty log scores the same as ever")
check(model.resolve(griefData["The Missing"], {}, taurenIdent) == nil,
  "a missing entry still passes through with an identity in hand")

-- End to end through build(): the turn-in marker follows identity.
r = model.build({
  quests = {
    { title = "Quartermaster's Due", header = "Orgrimmar", complete = true,
      objectives = {} },
  },
  data = { ["Quartermaster's Due"] = mirror },
  zoneNames = { [1637] = "Orgrimmar" }, currentZone = "Orgrimmar",
  identity = model.identity("Tauren", "WARRIOR"),
})
check(r.list[1].objs[1].text == "Turn in: Orgrimmar Quartermaster",
  "build() sends a Tauren to the Horde turn-in of a faction mirror")

r = model.build({
  quests = {
    { title = "Quartermaster's Due", header = "Stormwind City", complete = true,
      objectives = {} },
  },
  data = { ["Quartermaster's Due"] = mirror },
  zoneNames = { [1519] = "Stormwind City" }, currentZone = "Stormwind City",
  identity = model.identity("Gnome", "MAGE"),
})
check(r.list[1].objs[1].text == "Turn in: Stormwind Quartermaster",
  "and a Gnome to the Alliance one")


-- ------------------------------------------------- r54: monofuel's log ---
-- The exact quest log that produced "2 days of map paths being broken"
-- (2026-08-16, guid 1000007, standing in Brill): two same-zone Tirisfal
-- quests, one Silverpine delivery, one Orgrimmar delivery. Generated
-- QuestData.lua is local-only (copyright hygiene), so the regression runs
-- against a tiny synthetic table with the same shape: two Tirisfal enders,
-- one Silverpine ender, one Orgrimmar ender. When a locally generated
-- QuestData.lua is present, the same scenario also runs against it.
local brillData = {
  ["Speak with Sevren"] = {
    id = 355, level = 5, minLevel = 3, zone = 85,
    turnIn = { label = "Magistrate Sevren", zone = 85, x = 61.3, y = 50.8 },
  },
  ["At War With The Scarlet Crusade"] = {
    id = 372, level = 8, minLevel = 5, zone = 85,
    objectives = {
      { label = "Captain Melrache", kind = "kill", count = 1,
        spots = { { zone = 85, x = 34.0, y = 60.0 } } },
    },
    turnIn = { label = "Executor Zygand", zone = 85, x = 60.0, y = 51.0 },
  },
  ["Delivery to Silverpine Forest"] = {
    id = 445, level = 10, minLevel = 5, zone = 85,
    turnIn = { label = "Silverpine Courier", zone = 130, x = 44.0, y = 40.0 },
  },
  ["The Horde Needs Your Help!"] = {
    id = 8792, level = 10, minLevel = 10, zone = 1637,
    turnIn = { label = "Warlord Gorchuk", zone = 1637, x = 50.0, y = 50.0 },
  },
}
local brillZones = {
  [85] = "Tirisfal Glades", [130] = "Silverpine Forest", [1637] = "Orgrimmar",
}

local function brillScenario(source, data, zoneNames)
  -- Prefix every check so a failure names the dataset that produced it.
  local function bcheck(cond, name) check(cond, source .. ": " .. name) end

  local brill = model.build({
    quests = {
      { key = 1, title = "Speak with Sevren", header = "Tirisfal Glades",
        objectives = {} },
      { key = 2, title = "At War With The Scarlet Crusade",
        header = "Tirisfal Glades",
        objectives = { { text = "Captain Melrache slain: 0/1", have = 0, need = 1 } } },
      { key = 3, title = "Delivery to Silverpine Forest", header = "Tirisfal Glades",
        objectives = {} },
      { key = 4, title = "The Horde Needs Your Help!", header = "Orgrimmar",
        objectives = {} },
    },
    data = data, zoneNames = zoneNames,
    currentZone = "Tirisfal Glades", pos = { x = 61.0, y = 52.0 },
  })

  bcheck(#brill.list == 4, "all four of monofuel's quests are listed")

  local byTitle = {}
  for _, c in ipairs(brill.candidates) do
    byTitle[c.title] = byTitle[c.title] or {}
    table.insert(byTitle[c.title], c)
  end

  local function delivery(title)
    for _, c in ipairs(byTitle[title] or {}) do
      if c.delivery then return c end
    end
    return nil
  end

  bcheck(delivery("Speak with Sevren"),
    "355 Speak with Sevren gets a same-zone delivery pin (Magistrate Sevren)")
  bcheck(delivery("At War With The Scarlet Crusade"),
    "372 At War With The Scarlet Crusade gets a delivery pin (Executor Zygand)")
  bcheck(delivery("Speak with Sevren").pending == false,
    "an objective-less delivery is actionable, not pending")
  bcheck(delivery("At War With The Scarlet Crusade").pending == true,
    "a delivery behind unfinished objectives is pending")
  bcheck(not delivery("Delivery to Silverpine Forest"),
    "445 invents no Tirisfal coordinate for its Silverpine ender")
  bcheck(not delivery("The Horde Needs Your Help!"),
    "8792 invents no Tirisfal coordinate for its Orgrimmar ender")

  local target = model.pickTarget(brill.list, brill.candidates)
  bcheck(target ~= nil, "the Brill log routes somewhere (r53 drew nothing here)")
  bcheck(target.title == brill.list[1].title,
    "the route serves the top quest of the checklist")
  bcheck(target.pending ~= true, "the route never serves a pending delivery")

  local away = model.awayRows(brill.list, "Tirisfal Glades")
  bcheck(#away == 2, "exactly the two cross-zone quests get breadcrumbs")
  local dest = {}
  for _, a in ipairs(away) do dest[a.title] = a end
  bcheck(dest["Delivery to Silverpine Forest"]
    and dest["Delivery to Silverpine Forest"].zoneName == "Silverpine Forest"
    and dest["Delivery to Silverpine Forest"].turnIn,
    "445 breadcrumbs to Silverpine Forest")
  bcheck(dest["The Horde Needs Your Help!"]
    and dest["The Horde Needs Your Help!"].zoneName == "Orgrimmar",
    "8792 breadcrumbs to Orgrimmar")
  bcheck(dest["The Horde Needs Your Help!"].label == "Warlord Gorchuk",
    "the breadcrumb names the ender it read from the data")
  bcheck(not dest["Speak with Sevren"] and not dest["At War With The Scarlet Crusade"],
    "quests that DO have local pins are not also breadcrumbed")
end

brillScenario("synthetic", brillData, brillZones)

-- Local-only inputs live under $WSA_PRIVATE_INPUTS (default the repo root).
local privateRoot = os.getenv("WSA_PRIVATE_INPUTS")
if privateRoot == nil or privateRoot == "" then privateRoot = "." end
local localQuestData = privateRoot .. "/addons/ShadowArmy/QuestData.lua"
local localQuestFile = io.open(localQuestData, "r")
if localQuestFile then
  localQuestFile:close()
  dofile(localQuestData)
  brillScenario("local QuestData", ShadowArmyQuestData, ShadowArmyQuestZones)
else
  print("test_advisor_quest_model: SKIP local QuestData Brill scenario ("
    .. localQuestData .. " not present)")
end

-- ------------------------------------------------ r54: pickTarget rules ---
-- Pure ordering rules, independent of any data file. Candidates arrive
-- distance-sorted, so index order is nearest-first here too.
local list = { { title = "top" }, { title = "second" } }
check(model.pickTarget(list, {}) == nil, "no candidates means no target")

local cands = {
  { title = "second", dist = 10 },
  { title = "top", dist = 40 },
}
check(model.pickTarget(list, cands).title == "top",
  "the top quest wins even when another quest is nearer")

cands = { { title = "second", dist = 10 }, { title = "third", dist = 40 } }
check(model.pickTarget(list, cands).title == "second",
  "a top quest with no waypoint falls back to the nearest quest that has one")

cands = {
  { title = "top", dist = 5, pending = true },
  { title = "second", dist = 40 },
}
check(model.pickTarget(list, cands).title == "second",
  "a live objective outranks the top quest's pending delivery")

cands = {
  { title = "second", dist = 40, pending = true },
  { title = "top", dist = 50, pending = true },
}
check(model.pickTarget(list, cands).title == "top",
  "when everything is pending the top quest still wins")

cands = { { title = "third", dist = 40, pending = true } }
check(model.pickTarget(list, cands).title == "third",
  "a pending delivery beats drawing nothing at all")

-- Capital/parent overlay: Bethor sits in Undercity's box but QuestData
-- often stores him as Tirisfal 65.7,68.8 (ZoneOrSort=85).
local ucZones = { [85] = "Tirisfal Glades", [1497] = "Undercity" }
local bx, by = model.overlayPercent(85, 65.7, 68.8, 1497)
check(bx and by, "Bethor Tirisfal 65.7,68.8 remaps into Undercity")
check(bx > 83.5 and bx < 85.0 and by > 16.8 and by < 18.2,
  "Bethor remaps near UC 84.1,17.4")
local rx, ry = model.overlayPercent(1497, 84.1, 17.4, 85)
check(rx and ry and rx > 65.0 and rx < 66.5 and ry > 68.0 and ry < 69.5,
  "inverse UC 84.1,17.4 remaps onto Tirisfal ruins")
check(model.overlayPercent(85, 61.3, 50.8, 1497) == nil,
  "Brill does not become an Undercity pin")

local lichTirisfal = {
  ["The Prodigal Lich"] = {
    zone = 85,
    turnIn = { label = "Bethor Iceshard", zone = 85, x = 65.7, y = 68.8 },
  },
}
r = model.build({
  quests = { { title = "The Prodigal Lich", header = "Tirisfal Glades",
    complete = true } },
  data = lichTirisfal, zoneNames = ucZones, currentZone = "Undercity",
  pos = { x = 84.0, y = 17.0 },
})
check(#r.candidates == 1, "in Undercity, Tirisfal-coded Bethor is an in-zone pin")
check(r.candidates[1].x > 83 and r.candidates[1].x < 85
    and r.candidates[1].y > 16.5 and r.candidates[1].y < 18.5,
  "the pin uses remapped Undercity percent")
check(model.pickTarget(r.list, r.candidates) ~= nil,
  "a remapped in-zone target exists so the HUD needle stays up")
check(#model.awayRows(r.list, "Undercity") == 0,
  "remapped Bethor is not a breadcrumb")

local lichUC = {
  ["The Prodigal Lich"] = {
    zone = 85,
    turnIn = { label = "Bethor Iceshard", zone = 1497, x = 84.1, y = 17.4 },
  },
}
r = model.build({
  quests = { { title = "The Prodigal Lich", header = "Tirisfal Glades",
    complete = true } },
  data = lichUC, zoneNames = ucZones, currentZone = "Tirisfal Glades",
  pos = { x = 61.0, y = 52.0 },
})
check(#r.candidates == 1,
  "in Tirisfal, Undercity-coded Bethor remaps onto the ruins overlay")
check(r.candidates[1].x > 65.0 and r.candidates[1].x < 66.5,
  "inverse pin is on the Tirisfal map")

print("test_advisor_quest_model: " .. passed .. " checks passed")
