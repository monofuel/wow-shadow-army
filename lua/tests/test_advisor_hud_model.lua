-- HudModel (r56): the geometry behind the on-screen guidance arrow.
--
-- The arrow is the first advisor surface that lives in the 3D world instead
-- of on the world map, and it is the one surface a human FOLLOWS WITH HIS
-- FEET. A bearing that is plausible and wrong costs a real minute of running,
-- so everything here that can be checked without a client is checked here:
-- the north-up mapping, the zone's yards-per-percent skew, the player-space
-- rotation, the needle's shape, and the UV quad the arrowhead is drawn with.

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local function near(a, b, eps, name)
  if not a then
    io.stderr:write("FAIL: " .. name .. " (nil)\n")
    os.exit(1)
  end
  local d = a - b
  if d < 0 then d = -d end
  if d > (eps or 1e-6) then
    io.stderr:write(string.format("FAIL: %s (%.6f vs %.6f)\n", name, a, b))
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.hudModel
check(model ~= nil, "hudModel is exported")

-- The real constants the live half passes in: a zone is 3500 yards wide and
-- 2333 tall, so one percent east is HALF AGAIN as far as one percent south.
local YX, YY = 3500, 2333

--------------------------------------------------------------------------
-- bearing: 16 points, and the yard skew is respected
--------------------------------------------------------------------------

-- Map space is +x east, +y SOUTH, so dy < 0 is north.
check(model.bearing(0, -1, YX, YY) == "N", "due north")
check(model.bearing(0, 1, YX, YY) == "S", "due south")
check(model.bearing(1, 0, YX, YY) == "E", "due east")
check(model.bearing(-1, 0, YX, YY) == "W", "due west")

-- Square yards keep the percent diagonal a true 45 degrees.
check(model.bearing(1, -1, 100, 100) == "NE", "NE on square yards")
check(model.bearing(-1, -1, 100, 100) == "NW", "NW on square yards")
check(model.bearing(1, 1, 100, 100) == "SE", "SE on square yards")
check(model.bearing(-1, 1, 100, 100) == "SW", "SW on square yards")

-- The three-letter points, at their own middles rather than their edges.
check(model.bearing(0.4, -1, 100, 100) == "NNE", "NNE")
check(model.bearing(-0.4, -1, 100, 100) == "NNW", "NNW")
check(model.bearing(0.4, 1, 100, 100) == "SSE", "SSE")
check(model.bearing(1, -0.4, 100, 100) == "ENE", "ENE")
check(model.bearing(-1, -0.4, 100, 100) == "WNW", "WNW")
check(model.bearing(1, 0.4, 100, 100) == "ESE", "ESE")
check(model.bearing(-1, 0.4, 100, 100) == "WSW", "WSW")

-- THE skew test: the same percent delta is a different compass point once
-- the zone's real proportions are applied. 1.2 east / 1.0 north reads NE on a
-- square zone and ENE on a real one, because 1.2% east is 42 yards while 1%
-- north is only 23. Getting this wrong points the arrow at plausible
-- nonsense, which is the failure mode a guidance arrow may not have.
check(model.bearing(1.2, -1, 100, 100) == "NE", "square zone: NE")
check(model.bearing(1.2, -1, YX, YY) == "ENE", "real zone: ENE")

check(model.bearing(0, 0, YX, YY) == nil, "no bearing when standing on it")

--------------------------------------------------------------------------
-- aim: unit vector in screen space (+x right, +y UP)
--------------------------------------------------------------------------

local ux, uy = model.aim(0, -10, YX, YY)
near(ux, 0, 1e-9, "north aims at x=0")
near(uy, 1, 1e-9, "north aims UP the screen")

ux, uy = model.aim(10, 0, YX, YY)
near(ux, 1, 1e-9, "east aims right")
near(uy, 0, 1e-9, "east aims flat")

ux, uy = model.aim(0, 10, YX, YY)
near(uy, -1, 1e-9, "south aims DOWN the screen")

ux, uy = model.aim(-10, 0, YX, YY)
near(ux, -1, 1e-9, "west aims left")

-- Always unit length: the needle's pip radii are pixels, so a non-unit aim
-- would silently change the arrow's SIZE with the distance to the target.
local dirs = { {3, -7}, {-2, -1}, {5, 5}, {-9, 4}, {0.01, -0.01} }
for i = 1, #dirs do
  local x, y = model.aim(dirs[i][1], dirs[i][2], YX, YY)
  near(math.sqrt(x * x + y * y), 1, 1e-9, "aim is unit length #" .. i)
end

-- Skew again, in vector form: a 1:1 percent delta leans EAST once yards are
-- applied, because the zone is wider than it is tall.
ux, uy = model.aim(1, -1, YX, YY)
check(ux > uy, "aim applies the zone's yards-per-percent skew")

check(model.aim(0, 0, YX, YY) == nil, "no aim when standing on the target")

--------------------------------------------------------------------------
-- aim with a facing: the vector rotates INTO player space
--------------------------------------------------------------------------

local HALF_PI = math.pi / 2

-- Facing east, a target due north must appear on the LEFT of the screen.
ux, uy = model.aim(0, -10, YX, YY, HALF_PI, 1)
near(ux, -1, 1e-9, "facing east, north is to the left")
near(uy, 0, 1e-9, "facing east, north is not ahead")

-- Facing north, nothing moves.
ux, uy = model.aim(0, -10, YX, YY, 0, 1)
near(uy, 1, 1e-9, "facing north changes nothing")

-- Facing south, a target due north is BEHIND.
ux, uy = model.aim(0, -10, YX, YY, math.pi, 1)
near(uy, -1, 1e-9, "facing south, north is behind")

-- The sign flip is the whole point of the /sa arrow flip knob: an unknown
-- facing source that grows the other way must be correctable live, and it
-- must mirror EXACTLY, not approximately.
local ax, ay = model.aim(3, -7, YX, YY, 0.9, 1)
local bx, by = model.aim(3, -7, YX, YY, 0.9, -1)
local cx, cy = model.aim(3, -7, YX, YY, -0.9, 1)
near(bx, cx, 1e-9, "flip equals negating the angle (x)")
near(by, cy, 1e-9, "flip equals negating the angle (y)")
check(math.abs(ax - bx) > 1e-6, "flip actually changes the answer")

-- Rotation preserves length and the angle BETWEEN two targets: a rotation
-- that stretched or sheared would bend the whole readout.
local p1x, p1y = model.aim(0, -10, YX, YY, 1.2, 1)
local p2x, p2y = model.aim(10, 0, YX, YY, 1.2, 1)
near(math.sqrt(p1x * p1x + p1y * p1y), 1, 1e-9, "rotated aim stays unit")
near(p1x * p2x + p1y * p2y, 0, 1e-9, "rotation preserves the 90 deg between N and E")

--------------------------------------------------------------------------
-- relative: the plain-English word under the arrow (player mode only)
--------------------------------------------------------------------------

check(model.relative(0, 1) == "ahead", "straight up is ahead")
check(model.relative(0, -1) == "behind", "straight down is behind")
check(model.relative(1, 0) == "right", "right is right")
check(model.relative(-1, 0) == "left", "left is left")
check(model.relative(0.2, 0.98) == "ahead", "slightly off is still ahead")
check(model.relative(0.8, 0.6) == "right", "past 45 degrees is right")
check(model.relative(nil, nil) == nil, "no vector, no word")

--------------------------------------------------------------------------
-- needlePips: the shaft, and the pip arrowhead the art-less preset grows
--------------------------------------------------------------------------

local function pipRadius(p) return math.sqrt(p.x * p.x + p.y * p.y) end

local cfg = model.needle
local pips, np = model.needlePips(0, 1, cfg)
check(np == cfg.shaft, "default preset is shaft only (the art is the head)")
near(pipRadius(pips[1]), cfg.r0, 1e-9, "first pip sits at r0")
near(pipRadius(pips[np]), cfg.r1, 1e-9, "last pip sits at r1")
for i = 2, np do
  check(pipRadius(pips[i]) > pipRadius(pips[i - 1]), "pips march outward #" .. i)
  check(pips[i].size >= pips[i - 1].size, "pips taper fatter #" .. i)
end

-- Every shaft pip must lie ON the aim ray, not merely near it: a pip off the
-- line reads as a bent arrow.
local dx, dy = model.aim(4, -9, YX, YY)
pips, np = model.needlePips(dx, dy, cfg)
for i = 1, np do
  near(pips[i].x * dy - pips[i].y * dx, 0, 1e-9, "pip is on the ray #" .. i)
  check(pips[i].x * dx + pips[i].y * dy > 0, "pip is AHEAD of centre #" .. i)
end

-- The no-art preset has to stand alone: shaft + tip + two barbs.
local nac = model.needleNoArt
pips, np = model.needlePips(0, 1, nac)
check(np == nac.shaft + 3, "no-art preset grows a tip and two barbs")
local tip = pips[nac.shaft + 1]
check(tip.head, "the tip is flagged as head ink")
near(pipRadius(tip), nac.tip, 1e-9, "the tip sits at the tip radius")
local b1, b2 = pips[nac.shaft + 2], pips[nac.shaft + 3]
check(b1.head and b2.head, "barbs are head ink")
near(b1.x + b2.x, 2 * (0 * nac.barbR), 1e-9, "barbs are symmetric across the axis (x)")
near(b1.y + b2.y, 2 * (1 * nac.barbR), 1e-9, "barbs straddle the axis (y)")
check(pipRadius(b1) < pipRadius(tip), "barbs sit behind the tip")
near(pipRadius(b1), pipRadius(b2), 1e-9, "barbs are the same distance out")

check(select(2, model.needlePips(nil, nil, cfg)) == 0, "no aim, no pips")

--------------------------------------------------------------------------
-- texCoords: the 8-argument SetTexCoord quad that rotates the arrowhead
--------------------------------------------------------------------------

-- Argument order is the engine's own: ULx, ULy, LLx, LLy, URx, URy, LRx, LRy.
local function coords(x, y)
  local a, b, c, d, e, f, g, h = model.texCoords(x, y)
  return { UL = {a, b}, LL = {c, d}, UR = {e, f}, LR = {g, h} }
end

-- Pointing north is the identity quad: the art already points up.
local q = coords(0, 1)
near(q.UL[1], 0, 1e-9, "north UL x")
near(q.UL[2], 0, 1e-9, "north UL y")
near(q.LL[1], 0, 1e-9, "north LL x")
near(q.LL[2], 1, 1e-9, "north LL y")
near(q.UR[1], 1, 1e-9, "north UR x")
near(q.UR[2], 0, 1e-9, "north UR y")
near(q.LR[1], 1, 1e-9, "north LR x")
near(q.LR[2], 1, 1e-9, "north LR y")

-- Pointing EAST must turn the picture a quarter turn clockwise. The proof
-- that matters is where the ARROW'S POINT lands: the art's tip is the top
-- edge's midpoint (0.5, 0) in UV, so it must be sampled at the middle of the
-- quad's RIGHT edge — i.e. the tip is drawn pointing right.
local function edgeMid(a, b) return {(a[1] + b[1]) / 2, (a[2] + b[2]) / 2} end
q = coords(1, 0)
local right = edgeMid(q.UR, q.LR)
near(right[1], 0.5, 1e-9, "east: the art's tip is on the right edge (u)")
near(right[2], 0, 1e-9, "east: the art's tip is on the right edge (v)")

q = coords(-1, 0)
local left = edgeMid(q.UL, q.LL)
near(left[1], 0.5, 1e-9, "west: the art's tip is on the left edge (u)")
near(left[2], 0, 1e-9, "west: the art's tip is on the left edge (v)")

q = coords(0, -1)
local bottom = edgeMid(q.LL, q.LR)
near(bottom[1], 0.5, 1e-9, "south: the art's tip is on the bottom edge (u)")
near(bottom[2], 0, 1e-9, "south: the art's tip is on the bottom edge (v)")

-- A rotation, not a shear: all four corners stay exactly half a diagonal from
-- the texture centre at every angle, and the quad keeps its winding (a
-- mirrored quad would flip the arrow rather than turn it).
local angles = { 0, 0.3, 0.9, 1.7, 2.5, 3.9, 5.4, 6.1 }
for i = 1, #angles do
  local a = angles[i]
  local x, y = math.sin(a), math.cos(a)
  q = coords(x, y)
  local names = { "UL", "LL", "UR", "LR" }
  for j = 1, 4 do
    local c = q[names[j]]
    local rx, ry = c[1] - 0.5, c[2] - 0.5
    near(math.sqrt(rx * rx + ry * ry), math.sqrt(0.5), 1e-9,
      "corner keeps its radius " .. names[j] .. " @" .. a)
  end
  -- Winding: (UR-UL) x (LL-UL) has the same sign at every angle.
  local e1x, e1y = q.UR[1] - q.UL[1], q.UR[2] - q.UL[2]
  local e2x, e2y = q.LL[1] - q.UL[1], q.LL[2] - q.UL[2]
  check(e1x * e2y - e1y * e2x > 0, "quad is not mirrored @" .. a)
end

-- A nil aim still returns a legal quad: the caller must never hand SetTexCoord
-- a nil, and an unrotated arrow is the right thing to leave behind.
local a1 = model.texCoords(nil)
check(a1 == 0, "nil aim returns the identity quad")

--------------------------------------------------------------------------
-- facingSource: the ladder, which on stock 5875 always lands on "none"
--------------------------------------------------------------------------

check(model.facingSource({ api = true }) == "api", "a facing API wins")
check(model.facingSource({ api = true, model = true }) == "api", "API beats model")
check(model.facingSource({ model = true }) == "model", "a live model is second")
check(model.facingSource({}) == "none", "stock 1.12 has no facing source")
check(model.facingSource(nil) == "none", "no environment is no facing source")

print("test_advisor_hud_model: " .. passed .. " checks passed")
