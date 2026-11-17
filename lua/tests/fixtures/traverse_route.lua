-- Synthetic Petrel route for the traverse unit tests.
--
-- The real route tables (lua/config/traverse_*beats.lua) are recorded route
-- data and stay local-only (AGENTS.md copyright hygiene). This fixture gives
-- the brain the same route SHAPE: two dry land legs, a wet ribbon, a coast
-- chain with westward hook beats, a wet departure line, a Barrens connector,
-- a sparse northern road with hook beats down to a cave mouth, a dense walked
-- interior chain, and a finale line. Anchor poses are the ones the tests
-- already name; everything between them is evenly interpolated filler.
--
-- select() picks the route the tests run on: the local recorded route when
-- it is present (under $WSA_PRIVATE_INPUTS, default the repo root), else this
-- synthetic route. TRAVERSE_ROUTE=synthetic forces the synthetic route so a
-- checkout holding local data still exercises both (make test-lua does).
-- install() registers every synthetic route under package.preload, so
-- require("config.traverse_*beats") resolves here.

local M = {}

local function beat(id, x, y, z, radius, extra)
  local b = { id = id, x = x, y = y, z = z, radius = radius }
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end

-- Evenly spaced points strictly between a and b, at most `spacing` apart.
local function between(a, b, spacing)
  local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
  local steps = math.ceil(math.sqrt(dx * dx + dy * dy) / spacing)
  local out = {}
  for i = 1, steps - 1 do
    local t = i / steps
    out[#out + 1] = { a[1] + dx * t, a[2] + dy * t, a[3] + dz * t }
  end
  return out
end

-- Append the anchor chain to `beats`, densifying each leg to `spacing`.
-- `name(n)` labels the n-th beat appended by this call.
local function chain(beats, anchors, spacing, radius, name, extra)
  local n = 0
  local function push(p)
    n = n + 1
    beats[#beats + 1] = beat(name(n), p[1], p[2], p[3], radius, extra and extra(n))
  end
  for i, a in ipairs(anchors) do
    if i > 1 then
      for _, p in ipairs(between(anchors[i - 1], a, spacing)) do push(p) end
    end
    push(a)
  end
end

local function numbered(prefix)
  return function(n) return string.format("%s_%02d", prefix, n) end
end

function M.routes()
  -- Tanaris land legs, then the wet ribbon to the Dustwallow coast.
  local route = {
    goal_id = "duskwallow_coast", map_id = 1,
    beats = {
      beat("land_approach", -7100.0, -4600.0, 10.0, 40.0),
      beat("water_entry", -6784.5, -4833.9, 0.7, 50.0),
    },
  }
  local ribbon = {
    { -6737.63, -4860.0, -1.0 }, { -6680.0, -4870.0, -4.0 },
    { -6630.0, -4875.0, -6.0 }, { -6584.86, -4880.0, -7.45 },
    { -6540.0, -4890.0, -7.0 }, { -6480.0, -4900.0, -6.0 },
    { -6430.0, -4910.0, -5.0 }, { -6413.2, -4935.0, -5.0 },
  }
  for i, p in ipairs(ribbon) do
    route.beats[#route.beats + 1] = beat(string.format("ribbon_%02d", i),
      p[1], p[2], p[3], 25.0, { wet = true })
  end
  local tail = {}
  chain(tail, { { -6413.2, -4935.0, -5.0 }, { -4627.01, -4869.45, -2.37 } },
    150.0, 25.0, numbered("ribbon_tail"), function() return { wet = true } end)
  table.remove(tail, 1) -- the shared anchor is already ribbon_08
  tail[#tail].id = "duskwallow_coast"
  for _, b in ipairs(tail) do route.beats[#route.beats + 1] = b end

  -- Coast chain to Merchant Bay; the last two beats hook west into the bay.
  local coast = { goal_id = "merchant_coast", map_id = 1, beats = {} }
  chain(coast.beats, {
    { -4363.6, -4903.7, -2.0 }, { -4125.7, -4841.2, -2.0 },
    { -1533.0, -4088.0, -3.0 },
  }, 300.0, 25.0, numbered("coast"), function() return { wet = true } end)
  coast.beats[#coast.beats].id = "bay_center"
  coast.beats[#coast.beats + 1] = beat("sandbar_saddle", -1652.0, -4010.0, -2.0,
    25.0, { wet = true, hook = true })
  coast.beats[#coast.beats + 1] = beat("merchant_coast", -1816.8, -3899.5, -1.0,
    25.0, { wet = true, hook = true })

  -- Wet departure line out of the bay to the Barrens beach lip.
  local connectWet = { goal_id = "barrens_beach_lip", map_id = 1, beats = {} }
  chain(connectWet.beats, {
    { -1805.0, -3870.0, -3.0 }, { -950.0, -3850.0, -3.0 },
  }, 200.0, 25.0, numbered("departure"), function() return { wet = true } end)
  connectWet.beats[1].id = "inlet_out"
  connectWet.beats[#connectWet.beats + 1] = beat("barrens_beach_lip",
    -910.0, -3800.0, -1.0, 25.0, { wet = true })

  -- Dry Barrens connector; the first leg hooks west off the beach.
  local connectLand = {
    goal_id = "top_barrens", map_id = 1,
    beats = {
      beat("barrens_lower_road", -950.0, -3700.0, 5.0, 25.0, { hook = true }),
      beat("barrens_road_02", -700.0, -3400.0, 20.0, 25.0),
      beat("barrens_road_03", -300.0, -3000.0, 40.0, 25.0),
      beat("barrens_road_04", 200.0, -2700.0, 60.0, 25.0),
      beat("barrens_road_05", 650.0, -2450.0, 80.0, 25.0),
      beat("top_barrens", 1071.6, -2303.4, 91.7, 25.0),
    },
  }

  -- Sparse northern road: x strictly increases until the hook descent.
  local land = {
    goal_id = "felwood_cave_entrance", map_id = 1, start_x = 1000.0,
    beats = {
      beat("ashenvale_south_road", 1191.7, -2250.0, 95.0, 25.0),
      beat("ashenvale_road_02", 1700.0, -2000.0, 110.0, 25.0),
      beat("ashenvale_road_03", 2300.0, -1800.0, 130.0, 25.0),
      beat("ashenvale_pass_1", 2900.0, -1700.0, 150.0, 25.0),
      beat("ashenvale_pass_2", 3250.0, -1660.0, 170.0, 25.0),
      beat("felwood_south_road", 3450.0, -1560.0, 190.0, 25.0),
      beat("felwood_road_climb", 3700.0, -1360.0, 210.0, 25.0),
      beat("felwood_road_bend", 3813.0, -1324.0, 220.0, 25.0),
      beat("felwood_road_04", 4100.0, -1250.0, 240.0, 25.0),
      beat("felwood_road_05", 4600.0, -1000.0, 280.0, 25.0),
      beat("felwood_road_06", 5100.0, -800.0, 320.0, 25.0),
      beat("timbermaw_road_01", 5450.0, -700.0, 360.0, 25.0),
      beat("timbermaw_road_02", 5600.0, -650.0, 380.0, 25.0),
      beat("timbermaw_road_03", 5850.0, -700.0, 400.0, 25.0),
      beat("timbermaw_road_04", 6050.0, -850.0, 420.0, 25.0),
      beat("timbermaw_road_05", 6250.0, -1000.0, 440.0, 25.0),
      beat("timbermaw_road_06", 6400.0, -1150.0, 460.0, 25.0),
      beat("timbermaw_road_07", 6500.0, -1250.0, 480.0, 25.0),
      beat("timbermaw_road_08", 6580.0, -1330.0, 500.0, 25.0),
      beat("timbermaw_road_09", 6625.0, -1400.0, 510.0, 25.0),
      beat("timbermaw_road_10", 6640.0, -1540.0, 520.0, 25.0),
      beat("timbermaw_road_11", 6612.0, -1600.0, 530.0, 25.0, { hook = true }),
      beat("timbermaw_road_12", 6580.0, -1750.0, 545.0, 25.0, { hook = true }),
      beat("timbermaw_road_13", 6540.0, -1900.0, 560.0, 25.0, { hook = true }),
      beat("felwood_cave_entrance", 6502.937, -2063.74, 576.017, 25.0,
        { hook = true }),
    },
  }

  -- Walked Timbermaw interior: dense hook beats for the WMO, a hold chamber
  -- past the ramp, then the exit-tunnel line to the tunnel mouth.
  local interior = { goal_id = "timbermaw_tunnel_mouth", map_id = 1, beats = {} }
  local function interiorExtra(n)
    return { hook = true, navigation_mode = "local_steer",
      allow_jump = n <= 5 or nil }
  end
  -- Spacing sits just outside the 8 yd capture radius, so standing on one
  -- beat never captures its neighbour and the 15 yd lookahead is exercised.
  chain(interior.beats, {
    { 6500.0, -2060.0, 576.0 }, { 6854.6, -2114.7, 590.0 },
  }, 9.0, 8.0, numbered("timbermaw"), interiorExtra)
  local walked = {
    { 6865.3, -2115.25, 591.0 }, { 6876.1, -2115.8, 592.0 },
    { 6886.6, -2104.7, 596.0 },
  }
  for _, p in ipairs(walked) do
    local n = #interior.beats + 1
    interior.beats[n] = beat(string.format("timbermaw_%02d", n),
      p[1], p[2], p[3], 8.0, interiorExtra(n))
  end
  local descent = {}
  chain(descent, { { 6886.6, -2104.7, 596.0 }, { 6875.1, -2306.2, 610.0 } },
    8.0, 8.0, function() return "" end)
  table.remove(descent, 1) -- the hold chamber beat is already in the chain
  for _, b in ipairs(descent) do
    local n = #interior.beats + 1
    b.id = string.format("timbermaw_%02d", n)
    for k, v in pairs(interiorExtra(n)) do b[k] = v end
    interior.beats[n] = b
  end
  local tunnel = {}
  chain(tunnel, { { 6875.1, -2306.2, 610.0 }, { 6606.3, -2363.0, 620.0 } },
    8.0, 8.0, numbered("timbermaw_tunnel"), interiorExtra)
  table.remove(tunnel, 1) -- the last walked beat opens the tunnel line
  tunnel[#tunnel].id = "timbermaw_tunnel_mouth"
  for i, b in ipairs(tunnel) do
    if i < #tunnel then b.id = string.format("timbermaw_tunnel_%02d", i) end
    b.allow_jump = nil
    interior.beats[#interior.beats + 1] = b
  end

  -- Winterspring finale from the tunnel bridge to Everlook.
  local finale = {
    goal_id = "everlook", map_id = 1,
    beats = {
      beat("timbermaw_north_tunnel", 6606.3, -2363.0, 620.0, 15.0),
      beat("winterspring_west_entry", 6600.0, -2450.0, 640.0, 25.0),
      beat("winterspring_road_02", 6620.0, -3000.0, 680.0, 25.0),
      beat("winterspring_road_03", 6650.0, -3800.0, 700.0, 25.0),
      beat("everlook", 6687.333052, -4647.667, 721.678, 25.0),
    },
  }

  return {
    ["config.traverse_beats"] = route,
    ["config.traverse_coast_beats"] = coast,
    ["config.traverse_connector_wet_beats"] = connectWet,
    ["config.traverse_connector_land_beats"] = connectLand,
    ["config.traverse_land_beats"] = land,
    ["config.traverse_finale_interior_beats"] = interior,
    ["config.traverse_finale_beats"] = finale,
  }
end

-- `routes` (module name -> table) defaults to this fixture's own routes, so
-- other route generations can reuse the same local/synthetic selection.
function M.install(routes)
  for name, cfg in pairs(routes or M.routes()) do
    package.loaded[name] = nil
    package.preload[name] = function() return cfg end
  end
end

-- Root of the local-only inputs tree (mirrors the repo layout).
function M.localRoot()
  local root = os.getenv("WSA_PRIVATE_INPUTS")
  if root == nil or root == "" then return "." end
  return root
end

local function localPath(root, name)
  return root .. "/lua/" .. name:gsub("%.", "/") .. ".lua"
end

-- True when every recorded route module exists under root.
function M.hasLocal(root, routes)
  for name in pairs(routes or M.routes()) do
    local f = io.open(localPath(root, name), "r")
    if not f then return false end
    f:close()
  end
  return true
end

-- Register the recorded route modules from root under package.preload.
function M.installLocal(root, routes)
  for name in pairs(routes or M.routes()) do
    local path = localPath(root, name)
    package.loaded[name] = nil
    package.preload[name] = function() return dofile(path) end
  end
end

-- Install the route the tests should run on; returns "local route" or
-- "synthetic".
function M.select(routes)
  routes = routes or M.routes()
  local root = M.localRoot()
  if os.getenv("TRAVERSE_ROUTE") ~= "synthetic" and M.hasLocal(root, routes) then
    M.installLocal(root, routes)
    return "local route"
  end
  M.install(routes)
  return "synthetic"
end

return M
