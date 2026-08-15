local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.combatModel

local function state(extra)
  local s = { known = true, usable = true, range = "in", cooldown = 0 }
  if extra then for k, v in pairs(extra) do s[k] = v end end
  return s
end

local function snapshot(classToken, actions)
  return {
    classToken = classToken, form = "humanoid",
    hpPct = 100, powerPct = 100, targetHpPct = 100,
    hasTarget = true, hostile = true, targetDead = false,
    moving = false, casting = false, playerDead = false,
    danger = false, combo = 0, hasWand = true,
    actions = actions or {},
  }
end

local function row(result, id)
  for _, r in ipairs(result.rows) do if r.id == id then return r end end
  return nil
end

local s = snapshot("WARLOCK", {
  corruption = state(), agony = state(),
  shadowbolt = state(), shoot = state(), melee = state(),
})
local r = model.evaluate(s)
check(r.nextId == "corruption", "Warlock opens with missing Corruption")
check(r.rows[1].id == "corruption", "recommended ability is promoted to the first row")
local initialOrder = {}
for i, ability in ipairs(r.rows) do initialOrder[i] = ability.id end
s.casting = true
r = model.evaluate(s)
check(r.nextId == "corruption" and row(r, "corruption").usable,
  "casting does not grey or reorder the recommendation table")
for i, ability in ipairs(r.rows) do
  check(ability.id == initialOrder[i], "casting preserves row " .. i)
end
s.casting = false
s.actions.corruption.cooldown = 1.2
s.actions.corruption.gcd = true
r = model.evaluate(s)
check(r.nextId == "corruption" and row(r, "corruption").usable,
  "global cooldown does not grey the recommendation table")
for i, ability in ipairs(r.rows) do
  check(ability.id == initialOrder[i], "global cooldown preserves row " .. i)
end
s.actions.corruption.cooldown = 0
s.actions.corruption.gcd = false
s.actions.corruption.debuff = true
r = model.evaluate(s)
check(r.nextId == "agony", "Warlock advances after Corruption is present")
check(r.rows[1].id == "agony", "new recommendation replaces the first row")

s.actions.agony.debuff = true
s.moving = true
r = model.evaluate(s)
check(r.nextId == "shoot", "moving Warlock falls back from cast to wand")
check(row(r, "shadowbolt").reason == "stand still", "cast reports movement block")

s.moving = false
s.hpPct = 40
s.actions.drainlife = state()
r = model.evaluate(s)
check(r.nextId == "drainlife", "low-health Warlock prioritizes Drain Life")

s.hpPct, s.powerPct = 80, 10
s.actions.drainlife = nil
s.actions.lifetap = state()
r = model.evaluate(s)
check(r.nextId == "lifetap", "safe low-mana Warlock prioritizes Life Tap")

s.powerPct = 100
s.actions.lifetap = nil
s.actions.corruption.debuff = false
s.actions.corruption.range = "out"
r = model.evaluate(s)
check(not row(r, "corruption").usable and row(r, "corruption").reason == "out of range",
  "exact out-of-range state blocks recommendation")
s.actions.corruption.range = "approx_far"
r = model.evaluate(s)
check(row(r, "corruption").usable and r.nextId == "corruption",
  "approximate far state stays honest and clickable")

s.actions.corruption.cooldown = 2.4
r = model.evaluate(s)
check(string.find(row(r, "corruption").reason, "cooldown", 1, true) ~= nil,
  "cooldown is surfaced")
s.actions.corruption.cooldown = 0
s.actions.corruption.noResource = true
s.actions.corruption.resourceReason = "mana low"
r = model.evaluate(s)
check(row(r, "corruption").reason == "mana low", "resource block is surfaced")

local d = snapshot("DRUID", {
  healingtouch = state(), rejuvenation = state(), moonfire = state(),
  wrath = state(), catform = state(), bearform = state(), melee = state(),
})
d.hasTarget, d.hostile, d.hpPct = false, false, 35
r = model.evaluate(d)
check(r.nextId == "healingtouch", "Druid can receive self-heal advice without a target")
check(row(r, "moonfire").reason == "need target", "hostile Druid spell still requires target")
check(row(r, "catform").usable, "humanoid Druid can click into Cat Form")

d.hasTarget, d.hostile, d.hpPct, d.form = true, true, 100, "cat"
d.combo = 4
d.actions = {
  rip = state(), rake = state(), claw = state(), tigersfury = state(),
  bearform = state(), melee = state(),
}
r = model.evaluate(d)
check(r.nextId == "rip", "Cat spends four combo points with Rip")
d.actions.rip.debuff = true
r = model.evaluate(d)
check(r.nextId == "rake", "Cat maintains Rake after Rip")
d.actions.rake.debuff = true
r = model.evaluate(d)
check(r.nextId == "claw", "Cat builds with Claw after bleeds")

d.form = "bear"
d.actions = { demoroar = state(), maul = state(), catform = state(), melee = state() }
r = model.evaluate(d)
check(r.nextId == "demoroar", "Bear maintains Demoralizing Roar")
d.actions.demoroar.debuff = true
r = model.evaluate(d)
check(r.nextId == "maul", "Bear uses Maul after roar")

-- r46 (ticket 0041): resource gates read cast cost, not percent of pool.
-- Live report: 80/272 mana (29%) with a 40-mana Shadow Bolt — two bolts
-- affordable — and the coach recommending a dagger swing.
local function warlockCostSnapshot(actions)
  local s = snapshot("WARLOCK", actions)
  s.hasWand = false -- monofuel owns no wand; melee is the real bottom rung
  s.powerMax = 272
  return s
end

local function setPower(s, points)
  s.power = points
  s.powerPct = points / s.powerMax * 100
end

local m = warlockCostSnapshot({
  lifetap = state(), corruption = state({ debuff = true }),
  agony = state({ debuff = true }), immolate = state({ debuff = true }),
  shadowbolt = state(), melee = state(),
})
m.costs = { shadowbolt = 40, immolate = 55, lifetap = 0 }
setPower(m, 80)
r = model.evaluate(m)
check(r.nextId == "shadowbolt", "affordable Shadow Bolt is recommended inside the old percent dead band")
check(r.rows[1].id == "shadowbolt", "affordable bolt is promoted above melee")
check(row(r, "shadowbolt").reason == "nuke", "affordable bolt reads as a nuke")
check(row(r, "lifetap").reason == "mana OK", "Life Tap stays quiet while a bolt is affordable")

setPower(m, 30)
r = model.evaluate(m)
check(r.nextId == "lifetap", "unaffordable bolt with healthy health turns Life Tap on")
check(row(r, "shadowbolt").reason == "not enough mana",
  "unaffordable bolt reports cost, not policy")

m.hpPct = 50
r = model.evaluate(m)
check(r.nextId ~= "lifetap", "Life Tap stays off when health cannot pay for it")
check(row(r, "lifetap").reason == "health too low", "blocked Life Tap explains why")
m.hpPct = 100

local im = warlockCostSnapshot({
  lifetap = state(), corruption = state({ debuff = true }),
  agony = state({ debuff = true }), immolate = state(), shadowbolt = state(),
  melee = state(),
})
im.costs = { shadowbolt = 40, immolate = 55 }
setPower(im, 95)
r = model.evaluate(im)
check(r.nextId == "immolate", "Immolate fires when a bolt still fits in reserve")
setPower(im, 94)
r = model.evaluate(im)
check(r.nextId == "shadowbolt", "Immolate yields to the bolt when the reserve would break")
check(row(r, "immolate").reason == "bolt reserve", "held Immolate names the bolt reserve")

-- Cost data is allowed to be missing (tooltip would not populate, spell not in
-- the book yet). That must degrade to the OLD percent gates, never to
-- always-recommend.
local fb = warlockCostSnapshot({
  lifetap = state(), corruption = state({ debuff = true }),
  agony = state({ debuff = true }), shadowbolt = state(), melee = state(),
})
fb.costs = nil
setPower(fb, 80) -- 29%: under the old 35% bolt gate, over the old 20% tap gate
r = model.evaluate(fb)
check(r.nextId ~= "shadowbolt", "absent costs fall back to the old percent bolt gate")
check(row(r, "shadowbolt").reason == "save mana", "percent fallback keeps the old bolt reason")
check(row(r, "lifetap").reason == "mana OK", "percent fallback keeps the old Life Tap gate")
fb.costs = { immolate = 55 } -- table present, this spell's entry missing
r = model.evaluate(fb)
check(row(r, "shadowbolt").reason == "save mana",
  "a costs table missing this spell still falls back to percent")
fb.costs = { shadowbolt = 40 }
fb.power = nil -- cost known, current mana unknown
r = model.evaluate(fb)
check(row(r, "shadowbolt").reason == "save mana", "unknown current mana falls back to percent")
fb.costs = nil
setPower(fb, 40) -- 14%: under the old 20% Life Tap gate
r = model.evaluate(fb)
check(r.nextId == "lifetap", "percent fallback still taps below the old threshold")

local w = snapshot("DRUID", {
  moonfire = state({ debuff = true }), wrath = state(), catform = state(),
  bearform = state(), melee = state(),
})
w.powerMax, w.power, w.powerPct = 200, 50, 25
w.costs = { wrath = 30 }
r = model.evaluate(w)
check(r.nextId == "wrath", "Druid Wrath fires at 25% mana because it is affordable")
check(row(r, "wrath").reason == "nuke", "affordable Wrath reads as a nuke")
w.power, w.powerPct = 20, 10
r = model.evaluate(w)
check(r.nextId ~= "wrath", "unaffordable Wrath is not recommended")
check(row(r, "wrath").reason == "not enough mana", "unaffordable Wrath reports cost")
w.costs = nil
w.power, w.powerPct = 100, 50
r = model.evaluate(w)
check(r.nextId == "wrath", "Druid falls back to the old percent gate without cost data")

local codes = {
  ["You are facing the wrong way!"] = "facing",
  ["Target not in line of sight"] = "los",
  ["Out of range"] = "range",
}
check(model.classifyFailure("You are facing the wrong way!", codes).label == "turn to face target",
  "facing failure is classified")
check(model.classifyFailure("Target not in line of sight", codes).code == "los",
  "line-of-sight failure is classified")
check(model.classifyFailure("Out of range", codes).code == "range",
  "range failure is classified")
check(model.classifyFailure("Unknown error", codes) == nil, "unknown failures are ignored")

r = model.evaluate(snapshot("WARRIOR", {}))
check(r.warning == "no combat profile for this class", "unsupported class is explicit")

print("test_advisor_combat_model: " .. passed .. " checks passed")
