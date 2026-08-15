local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

dofile("addons/ShadowArmy/ShadowArmy.lua")
local model = ShadowArmy.routeModel

-- Flat {x1,y1,x2,y2,...} polyline, the shape RoadData.lua emits.
local function seg(pts)
  local flat = {}
  for _, p in ipairs(pts) do
    flat[#flat + 1] = p[1]
    flat[#flat + 1] = p[2]
  end
  return flat
end

-- A road down x=10 then east along y=90: the classic "the freeway is an L,
-- the crow flies the diagonal" case.
local function column(x, y0, y1)
  local pts = {}
  local y = y0
  while y <= y1 do
    pts[#pts + 1] = { x, y }
    y = y + 10
  end
  return seg(pts)
end

local function row(y, x0, x1)
  local pts = {}
  local x = x0
  while x <= x1 do
    pts[#pts + 1] = { x, y }
    x = x + 10
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

local elbow = { column(10, 10, 90), row(90, 10, 90) }
local graph = model.build(elbow)
check(graph.n == 18, "every polyline point becomes a node")
check(hasEdge(graph, 1, 2), "consecutive points of one polyline are an edge")

local cornerA = nodeAt(graph, 10, 90)
local cornerB = nil
for i = 1, graph.n do
  if graph.nodes[i].x == 10 and graph.nodes[i].y == 90 and i ~= cornerA then
    cornerB = i
  end
end
check(cornerA and cornerB, "both polylines contribute a point at the corner")
check(hasEdge(graph, cornerA, cornerB) and hasEdge(graph, cornerB, cornerA),
  "junction joining connects two segments within junctionDist")

check(model.build(nil).n == 0, "a zone with no road data builds an empty graph")
check(model.build({}).n == 0, "an empty segment list builds an empty graph")

local apart = model.build({ column(10, 10, 90), row(90, 30, 90) })
check(not hasEdge(apart, nodeAt(apart, 10, 90), nodeAt(apart, 30, 90)),
  "points further apart than junctionDist are not joined")

-- ---------------------------------------------------------------- route ---

local start = { x = 10, y = 10 }
local goal = { x = 90, y = 90 }

-- Straight is 113 units; the road is 160. At the default 1.6 off-road penalty
-- the diagonal costs 181, so the freeway wins despite being longer.
local pts, meta = model.route(graph, start, goal)
check(not meta.straight and meta.reason == "road", "the road beats the diagonal")
check(#pts > 2, "a road route carries intermediate waypoints")
check(pts[1].x == 10 and pts[1].y == 10, "route starts at the player")
check(pts[#pts].x == 90 and pts[#pts].y == 90, "route ends at the goal")
local sawCorner = false
for _, p in ipairs(pts) do
  if p.x == 10 and p.y == 90 then sawCorner = true end
end
check(sawCorner, "the route rounds the elbow instead of cutting it")
check(meta.length > 150, "the road route is honestly longer than the crow flies")

-- With no off-road penalty a road is just a longer walk.
local flatPts, flatMeta = model.route(graph, start, goal, { penalty = 1.0 })
check(flatMeta.straight and flatMeta.reason == "straight-cheaper",
  "with no penalty the diagonal wins and the route is straight")
check(#flatPts == 2, "a straight route is exactly start and goal")

-- Short hop: the objective is two steps away, the road is across the zone.
local far = model.build({ row(90, 10, 90) })
local hopPts, hopMeta = model.route(far, { x = 10, y = 10 }, { x = 12, y = 12 })
check(hopMeta.straight and hopMeta.reason == "short-hop",
  "a target nearer than the road returns the straight line")
check(#hopPts == 2 and hopPts[2].x == 12, "short hop is start then goal")

-- Disconnected: start snaps to one island, goal to another.
local islands = model.build({ column(0, 0, 40), column(60, 0, 40) })
local dPts, dMeta = model.route(islands, { x = 0, y = 0 }, { x = 60, y = 40 })
check(dMeta.straight and dMeta.reason == "disconnected",
  "a road network that does not connect falls back to the straight line")
check(#dPts == 2, "the disconnected fallback is start then goal")

-- Budget overflow: one settled node cannot reach anything.
local bPts, bMeta = model.route(graph, start, goal, { nodeBudget = 1 })
check(bMeta.straight and bMeta.reason == "budget",
  "blowing the node budget bails to the straight line")
check(#bPts == 2, "the budget fallback is start then goal")

-- No data at all is the same fallback, never an error.
local nPts, nMeta = model.route(nil, start, goal)
check(nMeta.straight and nMeta.reason == "no-roads" and #nPts == 2,
  "a missing graph degrades to straight-line behaviour")

-- Determinism: the same inputs give the same route, twice, and a freshly
-- built graph over the same data agrees with the cached one.
local again = model.route(graph, start, goal)
check(samePath(pts, again), "the same graph and endpoints give the same route")
local rebuilt = model.route(model.build(elbow), start, goal)
check(samePath(pts, rebuilt), "a rebuilt graph gives the same route")

-- ------------------------------------------------------------ nextPoint ---

local nx, ny, ni = model.nextPoint(pts, 10, 10, 1.0)
check(ni and ni > 1, "the go bearing skips the waypoint under the player")
check(nx == 10 and ny == 20, "the go bearing takes the next point up the road")

nx, ny = model.nextPoint(pts, 10, 85, 1.0)
check(nx == 10 and ny == 90, "off-route drift snaps forward, not back to the start")

nx, ny = model.nextPoint(pts, 90, 90, 1.0)
check(nx == 90 and ny == 90, "standing on the goal keeps pointing at the goal")

check(model.nextPoint(nil, 0, 0, 1.0) == nil, "no route means no route bearing")
check(model.nextPoint({ { x = 1, y = 1 } }, 0, 0, 1.0) == nil,
  "a one-point route means no route bearing")

-- --------------------------------------------------------------- sample ---
-- The world-map road layer: every segment of a zone thinned to a dot budget.

local sPts, sN = model.sample(elbow, 180)
check(sN == #sPts, "sample returns its own count")
check(sN == 18, "a zone that fits the budget is drawn whole (9 + 9 points)")
check(sPts[1].x == 10 and sPts[1].y == 10, "the first point survives thinning")
check(sPts[sN].x == 90 and sPts[sN].y == 90, "the last point survives thinning")

-- Over budget: never more dots than asked for, and no segment vanishes.
local big = {}
for i = 1, 40 do big[i] = column(i, 0, 90) end -- 40 segments x 10 points
local bN
sPts, bN = model.sample(big, 180)
check(bN <= 180, "sampling never exceeds the dot budget (" .. bN .. ")")
check(bN >= 80, "every segment still gets at least its two endpoints")
local seen = {}
for _, p in ipairs(sPts) do seen[p.x] = (seen[p.x] or 0) + 1 end
local missing = 0
for i = 1, 40 do
  if not seen[i] then missing = missing + 1 end
end
check(missing == 0, "no segment is thinned out of existence")

-- More segments than the budget can seat: still bounded, still spread out.
local many = {}
for i = 1, 300 do many[i] = row(i, 0, 10) end
local mPts, mN = model.sample(many, 180)
check(mN <= 180 and mN > 0, "a zone with more segments than dots stays bounded")
check(#mPts == mN, "the overflow case still returns a dense array")

-- Absent or degenerate data is empty, never an error.
local zPts, zN = model.sample(nil, 180)
check(zN == 0 and #zPts == 0, "no road data means no dots")
zPts, zN = model.sample(elbow, 0)
check(zN == 0 and #zPts == 0, "a zero budget draws nothing")

print("test_advisor_route_model: " .. passed .. " checks passed")
