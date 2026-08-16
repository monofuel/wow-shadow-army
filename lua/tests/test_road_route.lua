-- World-space road router (lua/tools/road_route.lua). The canonical fixture is
-- the addon's own (lua/tests/test_advisor_route_model.lua): a freeway shaped
-- like an L against a crow line down the diagonal, restated in yards.

wow = {
  log = function() end,
  time = function() return 0 end,
}

local rr = require("road_route")

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

-- Flat {x1,y1,z1,x2,y2,z2,...} polyline, the shape bot_roads.lua emits.
local function seg(pts)
  local flat = {}
  for _, p in ipairs(pts) do
    flat[#flat + 1] = p[1]
    flat[#flat + 1] = p[2]
    flat[#flat + 1] = p[3] or 0
  end
  return flat
end

local STEP = 20 -- the generated decimation spacing

local function column(x, y0, y1, z)
  local pts = {}
  local y = y0
  while y <= y1 do
    pts[#pts + 1] = { x, y, z or 50 }
    y = y + STEP
  end
  return seg(pts)
end

local function row(y, x0, x1, z)
  local pts = {}
  local x = x0
  while x <= x1 do
    pts[#pts + 1] = { x, y, z or 50 }
    x = x + STEP
  end
  return seg(pts)
end

local function nodeAt(graph, x, y)
  for i = 1, graph.n do
    local n = graph.nodes[i]
    if n.x == x and n.y == y then return i end
  end
  return nil
end

local function hasEdge(graph, a, b)
  for _, e in ipairs(graph.adj[a] or {}) do
    if e.to == b then return true end
  end
  return false
end

local function samePath(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].x ~= b[i].x or a[i].y ~= b[i].y then return false end
  end
  return true
end

-- ---------------------------------------------------------------- build ---
-- Road down x=1000 then east along y=1800: 800 yd + 800 yd of freeway against
-- an 1131 yd diagonal.

local elbow = { column(1000, 1000, 1800), row(1800, 1000, 1800) }
local graph = rr.build(elbow)
check(graph.n == 82, "every polyline point becomes a node (41 + 41)")
check(hasEdge(graph, 1, 2), "consecutive points of one polyline are an edge")
check(graph.nodes[1].z == 50, "nodes carry the baked z")

local cornerA = nodeAt(graph, 1000, 1800)
local cornerB = nil
for i = 1, graph.n do
  if graph.nodes[i].x == 1000 and graph.nodes[i].y == 1800 and i ~= cornerA then
    cornerB = i
  end
end
check(cornerA and cornerB, "both polylines contribute a point at the corner")
check(hasEdge(graph, cornerA, cornerB) and hasEdge(graph, cornerB, cornerA),
  "junction joining connects two segments within junctionDist")

check(rr.build(nil).n == 0, "a map with no road data builds an empty graph")
check(rr.build({}).n == 0, "an empty segment list builds an empty graph")

-- 30 yd apart clears the 25 yd junction distance: two roads that merely pass
-- near each other are not welded together.
local apart = rr.build({ column(1000, 1000, 1800), row(1800, 1030, 1800) })
check(not hasEdge(apart, nodeAt(apart, 1000, 1800), nodeAt(apart, 1030, 1800)),
  "points further apart than junctionDist are not joined")

-- ---------------------------------------------------------------- route ---

local start = { x = 1000, y = 1000, z = 50 }
local goal = { x = 1800, y = 1800, z = 50 }

-- Straight is 1131 yd; the road is 1600. At the default 1.6 off-road penalty
-- the diagonal costs 1810, so the freeway wins despite being longer.
local pts, meta = rr.route(graph, start, goal)
check(not meta.straight and meta.reason == "road", "the road beats the diagonal")
check(#pts > 2, "a road route carries intermediate waypoints")
check(pts[1].x == 1000 and pts[1].y == 1000, "route starts at the bot")
check(pts[#pts].x == 1800 and pts[#pts].y == 1800, "route ends at the leader")
local sawCorner = false
for _, p in ipairs(pts) do
  if p.x == 1000 and p.y == 1800 then sawCorner = true end
end
check(sawCorner, "the route rounds the elbow instead of cutting it")
check(meta.length > 1500, "the road route is honestly longer than the crow flies")
local zEverywhere = true
for _, p in ipairs(pts) do
  if p.z == nil then zEverywhere = false end
end
check(zEverywhere, "every waypoint carries a z for the navigate intent")

-- With no off-road penalty a road is just a longer walk.
local flatPts, flatMeta = rr.route(graph, start, goal, { penalty = 1.0 })
check(flatMeta.straight and flatMeta.reason == "straight-cheaper",
  "with no penalty the diagonal wins and the route is straight")
check(#flatPts == 2, "a straight route is exactly start and goal")

-- Short hop: the leader is two steps away, the road is across the zone.
local far = rr.build({ row(1800, 1000, 1800) })
local hopPts, hopMeta = rr.route(far, { x = 1000, y = 1000, z = 0 },
  { x = 1040, y = 1040, z = 0 })
check(hopMeta.straight and hopMeta.reason == "short-hop",
  "a leader nearer than the road returns the straight line")
check(#hopPts == 2 and hopPts[2].x == 1040, "short hop is start then goal")

-- Disconnected: start snaps to one island, goal to another. This is what a
-- hole in the bake looks like from the router's side.
local islands = rr.build({ column(0, 0, 800), column(1200, 0, 800) })
local dPts, dMeta = rr.route(islands, { x = 0, y = 0, z = 0 },
  { x = 1200, y = 800, z = 0 })
check(dMeta.straight and dMeta.reason == "disconnected",
  "a road network that does not connect falls back to the straight line")
check(#dPts == 2, "the disconnected fallback is start then goal")

-- Budget overflow: one settled node cannot reach anything.
local bPts, bMeta = rr.route(graph, start, goal, { nodeBudget = 1 })
check(bMeta.straight and bMeta.reason == "budget",
  "blowing the node budget bails to the straight line")
check(#bPts == 2, "the budget fallback is start then goal")

-- No data at all is the same fallback, never an error.
local nPts, nMeta = rr.route(nil, start, goal)
check(nMeta.straight and nMeta.reason == "no-roads" and #nPts == 2,
  "a missing graph degrades to straight-line behaviour")

-- Determinism: same inputs, same route, and a freshly built graph over the
-- same data agrees with the cached one.
check(samePath(pts, rr.route(graph, start, goal)),
  "the same graph and endpoints give the same route")
check(samePath(pts, rr.route(rr.build(elbow), start, goal)),
  "a rebuilt graph gives the same route")

-- Cost is horizontal: a mountain road is not penalised for climbing.
local steep = rr.build({ column(1000, 1000, 1800, 400), row(1800, 1000, 1800, 400) })
local sPts, sMeta = rr.route(steep, start, goal)
check(not sMeta.straight and math.abs(sMeta.length - meta.length) < 0.01,
  "z does not enter the cost, only the waypoints")
check(sPts[2].z == 400, "the climb still reaches the intent as a z")

-- ------------------------------------------------------------ nextPoint ---

local nx, ny, nz, ni = rr.nextPoint(pts, 1000, 1000, 20)
check(ni and ni > 1, "the walk target skips the waypoint under the bot")
check(nx == 1000 and ny > 1000 and ny <= 1060,
  "the walk target is the next point up the road, about a lookahead ahead")
check(nz == 50, "the walk target carries its z")

nx, ny = rr.nextPoint(pts, 1000, 1780, 20)
check(nx >= 1000 and ny == 1800,
  "off-route drift snaps forward, not back to the start")

nx, ny = rr.nextPoint(pts, 1800, 1800, 20)
check(nx == 1800 and ny == 1800, "standing on the leader keeps pointing there")

check(rr.nextPoint(nil, 0, 0, 20) == nil, "no route means no walk target")
check(rr.nextPoint({ { x = 1, y = 1, z = 0 } }, 0, 0, 20) == nil,
  "a one-point route means no walk target")

-- ------------------------------------------------------------- offRoute ---

check(rr.offRoute(pts, 1000, 1000) == 0, "standing on the route is zero off it")
check(math.abs(rr.offRoute(pts, 1100, 1000) - 100) < 0.01,
  "off-route distance is to the nearest waypoint")
check(rr.offRoute(nil, 0, 0) == nil, "no route means no off-route distance")

print("test_road_route: " .. passed .. " checks passed")
