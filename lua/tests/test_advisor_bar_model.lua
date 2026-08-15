local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.barModel

-- Stand-in for the addon's WATCHED_BUFFS (lives below the WoW UI guard).
local watches = { { id = "armor", spells = { "Demon Armor", "Demon Skin" } } }

-- ...and the REAL one, exported above the UI guard. Bind to it so renaming a
-- watched spell breaks tests instead of silently un-managing it.
local realWatches = ShadowArmy.watchedBuffs
check(realWatches and #realWatches > 0, "the addon exports its live buff watches")
local realManaged = model.managedNames("WARLOCK", realWatches)
check(realManaged["demon armor"] and realManaged["demon skin"],
  "the live buff-watch spells are managed by name")
check(realManaged["shadow bolt"] and realManaged["summon imp"],
  "the live managed set still covers coach spells and the summon")
local realOrder = model.managedOrder("WARLOCK", realWatches)
check(realOrder[1] == "drain life",
  "coach spells lead the shelf order — they are what reads exact telemetry")
check(realOrder[#realOrder] == "summon imp", "the summon trails the shelf order")
local seen = {}
for _, name in ipairs(realOrder) do
  check(not seen[name], "the shelf order never repeats a spell")
  check(name == string.lower(name), "the shelf order is lowercase")
  seen[name] = true
end

local managed = model.managedNames("WARLOCK", watches)
check(managed["shadow bolt"], "coach spells are managed")
check(managed["curse of agony"], "multi-word coach spells are managed")
check(managed["demon skin"], "passive buff ranks are managed even without a coach entry")
check(managed["demon armor"], "every rank of a watched buff is managed")
check(managed["summon imp"], "the class summon is managed")
check(not managed["melee attack"], "a non-spell coach row contributes no name")
check(not managed["hearthstone"], "unrelated abilities are never managed")

local druid = model.managedNames("DRUID", watches)
check(druid["moonfire"] and not druid["shadow bolt"],
  "managed names follow the player's class")
check(not druid["summon imp"], "a class with no summon profile adds none")

local hits = model.sweep({
  [1] = "Shadow Bolt",
  [2] = "Hearthstone",
  [7] = "Demon Skin",
  [12] = "Attack",
  [61] = "Summon Imp",
}, managed, 120)
check(#hits == 3, "only managed slots are swept")
check(hits[1] == 1 and hits[2] == 7 and hits[3] == 61,
  "swept slots come back in ascending slot order")

check(#model.sweep({}, managed, 120) == 0, "an empty bar sweeps nothing")
check(#model.sweep({ [3] = "Hearthstone", [4] = "Attack" }, managed, 120) == 0,
  "a bar of unmanaged actions is left alone")

hits = model.sweep({ [5] = "shadow bolt", [6] = "SUMMON IMP", [8] = "Demon SKIN" },
  managed, 120)
check(#hits == 3, "matching ignores case")

check(#model.sweep({ [9] = "Shadow Bolt of Doom", [10] = "Bolt" }, managed, 120) == 0,
  "matching is exact, not substring")

check(#model.sweep({ [119] = "Shadow Bolt", [121] = "Shadow Bolt" }, managed, 120) == 1,
  "the sweep stops at the last real slot")

--------------------------------------------------------------------------
-- plan(): removal scoped to the pressable pages, plus the telemetry shelf.
-- Macro skip is a UI-side concern (tooltips can't see through a macro), so
-- the model only ever sees "this slot named nothing" and leaves it alone.
--------------------------------------------------------------------------

local order = model.managedOrder("WARLOCK", watches)
local trained = { ["shadow bolt"] = true, ["curse of agony"] = true,
  ["demon skin"] = true, ["summon imp"] = true }

check(model.sweepMax == 72, "the sweep stops at the last pressable page")
check(model.shelfFirst == 109 and model.shelfLast == 120,
  "the telemetry shelf is the last bonus bank")

local plan = model.plan({
  [1] = "Shadow Bolt",
  [2] = "Hearthstone",
  [72] = "Curse of Agony",
  [73] = "Shadow Bolt",
  [80] = "Demon Skin",
}, managed, { order = order, trained = trained })
check(#plan.remove == 2, "only slots 1-72 are swept")
check(plan.remove[1] == 1 and plan.remove[2] == 72,
  "the last pressable slot is swept and the first bonus slot is not")
for _, slot in ipairs(plan.remove) do
  check(slot ~= 80, "a managed spell parked in a stance/bonus bank survives")
end

-- Shadow Bolt (73) and Demon Skin (80) already sit in the untouched banks, so
-- they still feed the coach and need no shelf copy.
local placedNames = {}
for _, entry in ipairs(plan.place) do placedNames[entry.name] = entry.slot end
check(not placedNames["shadow bolt"], "an already-shelved spell is not re-placed")
check(not placedNames["demon skin"], "any bonus-bank copy counts as shelved")
check(placedNames["curse of agony"] and placedNames["summon imp"],
  "trained managed spells with no surviving copy get shelved")
check(#plan.place == 2, "untrained managed spells are never placed")
check(placedNames["curse of agony"] == 109 and placedNames["summon imp"] == 110,
  "the shelf fills from its first free slot upward")
check(not plan.shelfFull, "a shelf with room to spare is not reported full")

-- Occupied shelf slots are skipped: a macro or an unreadable slot names
-- nothing, so only HasAction can say the space is taken.
plan = model.plan({}, managed,
  { order = order, trained = trained, occupied = { [109] = true, [110] = true } })
check(plan.place[1].slot == 111, "an occupied shelf slot is never overwritten")

-- Shelf-full truncation: four spells to shelve, two slots.
plan = model.plan({}, managed,
  { order = order, trained = trained, shelfFirst = 119, shelfLast = 120 })
check(#plan.place == 2, "placement stops when the shelf runs out")
check(plan.shelfFull, "a full shelf is reported so the coach can say why")
check(plan.place[1].name == "curse of agony" and plan.place[2].name == "shadow bolt",
  "shelf order decides who gets the last slots")

-- No trained set means "the player knows them all" (model-only convenience).
plan = model.plan({}, managed, { order = order })
check(#plan.place == #order or plan.shelfFull,
  "without a trained filter every managed spell wants a shelf slot")

check(#model.plan({}, managed, {}).place == 0,
  "no shelf order, no placement — a hash set has no stable fill order")

-- r44's unreadable-bar bug parked duplicate copies on the shelf (the sweep
-- could not read its own placements, so every run re-placed them). Once the
-- bar reads again, the same name in two shelf slots must simply stop the
-- placement, not crash and not remove anything: `kept` is a set.
plan = model.plan({
  [109] = "Curse of Agony", [110] = "Curse of Agony",
  [111] = "Summon Imp", [112] = "Summon Imp", [113] = "Summon Imp",
}, managed, { order = order, trained = trained,
  occupied = { [109] = true, [110] = true, [111] = true,
    [112] = true, [113] = true } })
check(#plan.remove == 0, "duplicate shelf copies are never removed")
placedNames = {}
for _, entry in ipairs(plan.place) do placedNames[entry.name] = entry.slot end
check(not placedNames["curse of agony"] and not placedNames["summon imp"],
  "a spell duplicated across two shelf slots is not placed a third time")
check(not plan.shelfFull,
  "duplicates left by a broken sweep do not report the shelf full")

print("test_advisor_bar_model: " .. passed .. " checks passed")
