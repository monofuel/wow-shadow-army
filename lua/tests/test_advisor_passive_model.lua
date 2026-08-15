local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.passiveModel

local function snapshot(extra)
  local s = {
    classToken = "WARLOCK",
    known = { ["summon imp"] = true, ["demon skin"] = true },
    buffs = {},
    hasPet = false, inCombat = false, dead = false,
  }
  if extra then for k, v in pairs(extra) do s[k] = v end end
  return s
end

local function armor(extra)
  local b = {
    id = "armor", label = "Demon Skin", autoLabel = "armor",
    spell = "Demon Skin", missing = true, expiring = false, auto = false,
  }
  if extra then for k, v in pairs(extra) do b[k] = v end end
  if b.spell == false then b.spell = nil end -- pairs() cannot carry a nil override
  return b
end

local function button(result, id)
  for _, b in ipairs(result.buttons) do if b.id == id then return b end end
  return nil
end

local r = model.evaluate(snapshot({ hasPet = true }))
check(#r.buttons == 0 and #r.notes == 0, "nothing pending yields no buttons and no notes")
check(r.ok, "quiet state reports ok")

r = model.evaluate(snapshot())
check(button(r, "summon") ~= nil, "petless Warlock gets a summon button")
check(button(r, "summon").spell == "Summon Imp", "summon button casts Summon Imp")
check(button(r, "summon").label == "Summon Imp", "summon button is labelled with the ability")
check(not r.ok, "a pending button clears the ok flag")

r = model.evaluate(snapshot({ hasPet = true }))
check(button(r, "summon") == nil, "an active minion hides the summon button")

r = model.evaluate(snapshot({ inCombat = true }))
check(button(r, "summon") == nil, "combat hides the summon button")

r = model.evaluate(snapshot({ dead = true }))
check(button(r, "summon") == nil, "a dead player gets no summon button")

r = model.evaluate(snapshot({ known = {} }))
check(button(r, "summon") == nil, "an untrained summon is never offered")

r = model.evaluate(snapshot({ classToken = "WARRIOR" }))
check(#r.buttons == 0, "a class with no summon profile gets no summon button")

r = model.evaluate(snapshot({ hasPet = true, buffs = { armor() } }))
check(button(r, "buff:armor") ~= nil, "a missing self-buff becomes a cast button")
check(button(r, "buff:armor").spell == "Demon Skin", "buff button casts the trained rank")
check(button(r, "buff:armor").label == "Demon Skin", "buff button is labelled with the ability")
check(button(r, "buff:armor").selfCast, "buff button self-casts")
check(#r.notes == 0, "a buff with a button needs no warning note")

r = model.evaluate(snapshot({ hasPet = true,
  buffs = { armor({ spell = "Demon Armor" }) } }))
check(button(r, "buff:armor").spell == "Demon Armor",
  "buff button follows the preferred trained rank")

r = model.evaluate(snapshot({ hasPet = true, buffs = { armor({ auto = true }) } }))
check(#r.buttons == 0, "an auto-cast buff never becomes a button")
check(r.notes[1].text == "armor: auto (Demon Skin)", "auto-cast buff keeps its status note")
check(r.notes[1].tone == "ok", "auto-cast note stays green")

r = model.evaluate(snapshot({ hasPet = true,
  buffs = { armor({ auto = true, spell = false }) } }))
check(r.notes[1].text == "armor: auto (untrained)", "auto note is honest about untrained spells")

r = model.evaluate(snapshot({ hasPet = true, buffs = { armor({ spell = false }) } }))
check(#r.buttons == 0, "an untrained buff offers no button")
check(r.notes[1].text == "Demon Skin MISSING" and r.notes[1].tone == "bad",
  "an untrained missing buff falls back to the warning note")

r = model.evaluate(snapshot({ hasPet = true, buffs = {
  armor({ spell = false, missing = false, expiring = true, minutes = 3 }) } }))
check(r.notes[1].text == "Demon Skin 3m left" and r.notes[1].tone == "warn",
  "an expiring untrained buff reports minutes left")

r = model.evaluate(snapshot({ buffs = { armor() } }))
check(r.buttons[1].id == "buff:armor" and r.buttons[2].id == "summon",
  "buff upkeep is offered before the summon")
-- r47 (ticket 0049): key 2 casts result.buttons[1] and nothing re-sorts the
-- row on the way, so "which spell does key 2 fire" is decided RIGHT HERE.
check(#r.buttons == 2 and r.buttons[1].spell == "Demon Skin" and r.buttons[1].selfCast,
  "key 2 takes the first model button: the buff, self-cast, ahead of the summon")

r = model.evaluate(snapshot({ hasPet = true }))
check(r.buttons[1] == nil, "a quiet passive row leaves key 2 with nothing to cast")

r = model.evaluate(snapshot({ hasPet = true, buffs = {
  armor({ missing = false, expiring = true, minutes = 4, spell = "Demon Armor" }) } }))
check(button(r, "buff:armor") ~= nil, "an expiring trained buff becomes a cast button")
check(button(r, "buff:armor").label == "Demon Armor",
  "the expiring-buff button is labelled with the trained rank")
check(#r.notes == 0, "an expiring buff with a button raises no note")

r = model.evaluate(snapshot({ buffs = {
  armor(),
  armor({ id = "ward", label = "Shadow Ward", spell = "Shadow Ward" }) } }))
check(#r.buttons == 3, "two missing buffs plus the summon make three buttons")
check(r.buttons[1].id == "buff:armor" and r.buttons[2].id == "buff:ward",
  "both missing buffs get their own button, in snapshot order")
check(r.buttons[3].id == "summon", "the summon stays last behind both buffs")

r = model.evaluate(snapshot({ hasPet = true, dead = true, buffs = { armor() } }))
check(#r.buttons == 0, "a dead player gets no buff button")
check(r.notes[1].text == "Demon Skin MISSING", "a dead player still sees the warning")

print("test_advisor_passive_model: " .. passed .. " checks passed")
