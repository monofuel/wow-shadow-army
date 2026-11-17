-- Synthetic Petrel route for the petrel unit tests.
--
-- petrel.lua reads its recorded route from lua/config/petrel/, which stays
-- local-only like every other route table (AGENTS.md copyright hygiene). This
-- fixture gives that brain the same route SHAPE on top of the synthetic
-- traverse route (tests/fixtures/traverse_route.lua): a sparse spawn corridor
-- that hands off to the land approach, refill shelf beats in the wet ribbon,
-- an east-only Merchant Bay and Ratchet connector, the walked Barrens climb,
-- and the Timbermaw hold junction. Anchor poses are the ones the petrel tests
-- already name; everything between them is invented or evenly interpolated
-- filler.
--
-- select() picks the local recorded route when every module is present
-- under $WSA_PRIVATE_INPUTS/lua/config/petrel/ (default the repo root), else
-- this synthetic route; TRAVERSE_ROUTE=synthetic forces the synthetic route.

local base = require("tests.fixtures.traverse_route")

local M = {}

local function beat(id, x, y, z, radius, extra)
  local b = { id = id, x = x, y = y, z = z, radius = radius }
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end

-- Anchor chain densified to at most `spacing` between anchors. Each anchor
-- is { id, x, y, z [, extra] }; filler beats are named after the anchor
-- they lead to and carry `fill` (e.g. { wet = true }). An anchor marked
-- `direct = true` is reached on one chord, with no filler before it.
local function corridor(anchors, spacing, radius, fill)
  local beats = {}
  for i, a in ipairs(anchors) do
    if i > 1 and not a.direct then
      local p = anchors[i - 1]
      local dx, dy, dz = a[2] - p[2], a[3] - p[3], a[4] - p[4]
      local steps = math.ceil(math.sqrt(dx * dx + dy * dy) / spacing)
      for s = 1, steps - 1 do
        local t = s / steps
        beats[#beats + 1] = beat(string.format("%s_lead_%02d", a[1], s),
          p[2] + dx * t, p[3] + dy * t, p[4] + dz * t, radius, fill)
      end
    end
    local extra = {}
    for k, v in pairs(fill or {}) do extra[k] = v end
    for k, v in pairs(a[5] or {}) do extra[k] = v end
    beats[#beats + 1] = beat(a[1], a[2], a[3], a[4], radius, extra)
  end
  return beats
end

function M.routes()
  local generic = base.routes()

  -- Spawn corridor: strictly increasing x from the spawn dunes to the land
  -- approach handoff. The farmhouse exits (dune2 west, gazer2 south) are
  -- the ids petrel.lua names.
  local spawn = {
    goal_id = "spawn_7240", map_id = 1,
    beats = corridor({
      { "spawn_dodge_pose_a", -9131.6, -2625.9, 12.0 },
      { "spawn_dodge_pose_b", -9059.0, -2704.9, 12.0 },
      { "spawn_8740", -8743.9, -2977.5, 10.0 },
      { "spawn_dodge_8740_dune2", -8574.7, -3050.9, 9.0 },
      { "spawn_dodge_8740_gazer2", -8566.0, -3130.8, 9.0 },
      { "spawn_8490", -8506.0, -3221.2, 9.0 },
      { "spawn_7990", -7993.8, -3776.6, 8.0 },
      { "spawn_7740", -7734.8, -3942.8, 8.0, direct = true },
      { "spawn_7700", -7698.4, -4080.0, 8.0 },
      { "spawn_7240", -7240.0, -4480.0, 8.0 },
    }, 150.0, 20.0),
  }

  -- Wet ribbon tail: the 0062 refill touches sit on the shelf west (026)
  -- and east (031) of the aquatic patrol band, never inside it.
  local wet = { wet = true }
  local route = generic["config.traverse_beats"]
  for i = #route.beats, 1, -1 do
    if route.beats[i].id == "ribbon_08" then break end
    table.remove(route.beats, i)
  end
  local ribbonEnd = route.beats[#route.beats]
  local tail = corridor({
    { "ribbon_08", ribbonEnd.x, ribbonEnd.y, ribbonEnd.z },
    { "ribbon_025", -5950.0, -4800.0, -5.0 },
    { "ribbon_026", -5868.0, -4736.0, -2.0, { refill = true } },
    { "ribbon_027", -5810.0, -4800.0, -5.0 },
    { "ribbon_028", -5720.0, -4830.0, -5.0 },
    { "ribbon_029", -5680.0, -4830.0, -5.0 },
    { "ribbon_030", -5650.0, -4830.0, -5.0 },
    { "ribbon_031", -5600.0, -4790.0, -2.0, { refill = true } },
    { "duskwallow_coast", -4627.01, -4869.45, -2.37 },
  }, 150.0, 25.0, wet)
  table.remove(tail, 1) -- ribbon_08 is already the route's last beat
  for _, b in ipairs(tail) do route.beats[#route.beats + 1] = b end

  -- Merchant Bay recut: the coast chain runs the direct race line east
  -- through the bay corridor, crosses the sandbar once at its saddle, and
  -- ends on the merchant water goal. No beat hooks back west.
  generic["config.traverse_coast_beats"] = {
    goal_id = "merchant_coast", map_id = 1,
    beats = corridor({
      { "coast_01", -4363.6, -4903.7, -2.0 },
      { "coast_02", -4125.7, -4841.2, -2.0 },
      { "bay_corridor_west", -1760.0, -4240.0, -3.0 },
      { "bay_corridor_east", -1688.0, -4170.0, -3.0 },
      { "sandbar_saddle", -1650.0, -4095.0, -2.0 },
      { "merchant_coast", -1581.0, -4070.0, -2.0 },
    }, 300.0, 25.0, wet),
  }

  -- Ratchet connector: east from the merchant goal to the Barrens beach lip.
  local connectWet = corridor({
    { "connector_swim_01", -1400.0, -3990.0, -3.0 },
    { "connector_swim_last", -950.0, -3850.0, -3.0 },
  }, 200.0, 25.0, wet)
  connectWet[#connectWet + 1] = beat("barrens_beach_lip", -910.0, -3800.0,
    -1.0, 25.0, wet)
  generic["config.traverse_connector_wet_beats"] = {
    goal_id = "barrens_beach_lip", map_id = 1, beats = connectWet,
  }

  -- Land connector: from the Ratchet shore up the walked Barrens climb to
  -- top_barrens. The westward first legs off the beach are hooks.
  generic["config.traverse_connector_land_beats"] = {
    goal_id = "top_barrens", map_id = 1,
    beats = {
      beat("barrens_shore_land", -905.0, -3765.0, 2.0, 25.0),
      beat("barrens_lower_road", -950.0, -3650.0, 5.0, 25.0, { hook = true }),
      beat("barrens_road_west", -1000.0, -3500.0, 10.0, 25.0, { hook = true }),
      beat("barrens_road_02", -950.0, -3250.0, 15.0, 25.0),
      beat("barrens_road_03", -800.0, -3050.0, 20.0, 25.0),
      beat("barrens_road_04", -620.1, -3058.9, 25.0, 25.0),
      beat("barrens_road_05", 22.8, -2723.1, 50.0, 25.0),
      beat("barrens_road_06", 674.9, -2393.2, 80.0, 25.0),
      beat("barrens_climb_01", 738.0, -2302.0, 85.0, 25.0),
      beat("barrens_climb_02", 827.0, -2289.0, 88.0, 25.0),
      beat("barrens_climb_03", 901.0, -2291.0, 90.0, 25.0),
      beat("barrens_climb_04", 990.0, -2288.0, 91.0, 25.0),
      beat("top_barrens", 1071.6, -2303.4, 91.7, 25.0),
    },
  }

  -- Hold junction: timbermaw_42 sits on the test's standing pose, 43 is
  -- 7.4 yd on (inside the 8 yd capture radius) and 44 is 14.5 yd on, so the
  -- 42 -> 45 chord a 15 yd lookahead would take is visible. The walked hold
  -- beats behind it shift one id along.
  local interior = generic["config.traverse_finale_interior_beats"].beats
  local b42, b44 = interior[42], interior[43]
  b42.x, b42.y = 6861.7, -2117.5
  local dx, dy = b44.x - b42.x, b44.y - b42.y
  local len = math.sqrt(dx * dx + dy * dy)
  local b43 = {}
  for k, v in pairs(b44) do b43[k] = v end
  b43.x, b43.y = b42.x + dx / len * 7.4, b42.y + dy / len * 7.4
  table.insert(interior, 43, b43)
  for i = 43, #interior do
    if interior[i].id:match("^timbermaw_%d+$") then
      interior[i].id = string.format("timbermaw_%02d", i)
    end
  end

  local routes = { ["config.petrel.traverse_spawn_beats"] = spawn }
  for name, cfg in pairs(generic) do
    routes[(name:gsub("^config%.", "config.petrel."))] = cfg
  end
  return routes
end

function M.select()
  return base.select(M.routes())
end

return M
