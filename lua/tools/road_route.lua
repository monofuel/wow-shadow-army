-- World-space road router for the bots: google-maps pathing over the baked
-- road polylines (lua/data/bot_roads.lua, tools/gen_bot_road_data.py).
--
-- Roads are freeways. A road yard costs FEWER hit points than an off-road
-- yard -- fewer patrols, fewer adds, fewer corpse runs -- so the search
-- happily walks extra distance to use one. That is the entire idea: a long
-- rejoin that crows straight through a mob field arrives at 30% health if it
-- arrives at all, and the same walk down the road arrives whole.
--
-- This is a world-coordinate port of the addon's percent-space RouteModel
-- (addons/ShadowArmy/ShadowArmy.lua). Same algorithm, same bail taxonomy, but
-- it speaks the coordinates the Observation mirror and `navigate` intents
-- already speak, so nothing here converts anything. Divergences from the
-- addon, all forced by the change of space:
--
--   * points are x,y,z triples (stride 3), because a navigate intent wants a
--     z and the bake has one. Cost is still measured in the horizontal plane:
--     a switchback's climb is not extra walking, and letting z into the metric
--     would make mountain roads look expensive precisely where they are the
--     only sane way through;
--   * every tunable is in YARDS instead of percent-of-zone (junction 25 yd,
--     lookahead 20 yd, epsilon 1 yd);
--   * segments are keyed by continent map id, not by zone id, so a route may
--     cross zone borders freely. The addon could not do that -- percent space
--     is only meaningful inside one zone -- and it is most of the value here,
--     since the leader is usually a zone or two away;
--   * no sample(): that exists to draw the addon's world-map overlay.
--
-- Pure Lua over plain tables: no wow API beyond an optional wow.log, so
-- lua/tests exercises it on host Lua.
--
-- Every failure mode -- no data, a hole in the bake, a road network that does
-- not connect, a road that would not actually help -- returns straight = true
-- with the two-point crow line, which is exactly what the caller would have
-- walked without this module. A bail is never an error.
--
-- How often it actually fires, measured 2026-08-16 on the shipped bake at the
-- home seats' live position in Tirisfal (2316, 1561), which sits 221 yd off
-- the nearest baked road:
--   * leader somewhere ON the road network, 150-2000 yd out (a human running
--     the roads, which is what humans do): 47% road, mean 1.25x detour.
--   * both ends dropped up to 250 yd off the network at 150-1500 yd apart:
--     21% road on Azeroth, 30% on Kalimdor, mean 1.29x detour.
-- The rest bail honestly: when the bot AND the leader are both a couple of
-- hundred yards into the wilderness, the road IS the long way round and the
-- crow line is the right answer. Raising offRoadPenalty buys more road at a
-- worse detour (2.0 -> 32%/1.37x, 3.0 -> 39%/1.48x on Azeroth) and does NOT
-- rescue those cases, because past a point the comparison stops being about
-- the penalty at all: it is the road's own length that loses.

local M = {}

-- Points from DIFFERENT polylines closer than this are the same junction. The
-- bake cuts a road wherever the mask breaks (bridges, crossings, tunnels,
-- water), so without this the network is a pile of disconnected sticks. It
-- must clear the 20 yd decimation spacing -- a crossing road's nearest baked
-- point can be half a spacing off the junction -- without being so wide it
-- fuses two roads that merely run near each other (the bake caps a road at
-- 28 yd wide, so anything much past that is inventing pavement).
M.junctionDist = 25.0
-- Off-road yards cost this much more than road yards. 1.0 would make roads
-- irrelevant; the higher it goes the more detour the router accepts to reach
-- one. Same 1.6 the addon shipped.
M.offRoadPenalty = 1.6
-- Dijkstra settle cap. A continent graph is ~2700 nodes (see the generated
-- file's header), so hitting this means something is wrong with the data, and
-- a stuck bot is worse than a straight line.
M.nodeBudget = 8000
-- "The road is further away than the thing I want" -- skip routing entirely.
M.shortHopFactor = 1.25
-- Lookahead for the point to actually walk at: the first route point this far
-- ahead. Roughly one decimation step, so the bot always has a waypoint in
-- front of it rather than one under its feet.
M.leadYards = 20.0
-- Two waypoints closer than this are one waypoint.
M.epsilon = 1.0

local sqrt, floor = math.sqrt, math.floor

local function dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return sqrt(dx * dx + dy * dy)
end

local function key(cx, cy)
  return cx .. ":" .. cy
end

local function edge(graph, a, b)
  local na, nb = graph.nodes[a], graph.nodes[b]
  local w = dist2(na.x, na.y, nb.x, nb.y)
  local la = graph.adj[a]
  la[#la + 1] = { to = b, w = w }
  local lb = graph.adj[b]
  lb[#lb + 1] = { to = a, w = w }
end

-- segments is one map's entry from bot_roads: an array of flat
-- {x1,y1,z1,x2,y2,z2,...} world polylines. The result is a plain adjacency
-- graph; build it ONCE per map and cache it, because this is the only
-- expensive call in the module.
function M.build(segments, opts)
  opts = opts or {}
  local join = opts.junctionDist or M.junctionDist
  -- os.clock, not wow.time: wow.time is the simulation clock, which does not
  -- advance inside one decide() call and would report every build as free.
  local started = (os and os.clock and os.clock()) or nil
  local graph = { nodes = {}, adj = {}, n = 0, cell = join, grid = {} }
  if not segments then return graph end

  local nodes, adj, grid = graph.nodes, graph.adj, graph.grid
  local nn = 0
  for si = 1, #segments do
    local flat = segments[si]
    local prev = nil
    local fi = 1
    local nf = #flat
    while fi + 2 <= nf do
      local x, y, z = flat[fi], flat[fi + 1], flat[fi + 2]
      nn = nn + 1
      nodes[nn] = { x = x, y = y, z = z, seg = si }
      adj[nn] = {}
      local bkey = key(floor(x / join), floor(y / join))
      local bucket = grid[bkey]
      if not bucket then bucket = {}; grid[bkey] = bucket end
      bucket[#bucket + 1] = nn
      graph.n = nn
      if prev then edge(graph, prev, nn) end
      prev = nn
      fi = fi + 3
    end
  end

  -- Junction pass. The spatial hash keeps this linear-ish: only the 3x3 cell
  -- neighbourhood can hold a point within `join`, so a continent does not turn
  -- graph construction into a visible stall.
  for i = 1, nn do
    local a = nodes[i]
    local cx, cy = floor(a.x / join), floor(a.y / join)
    for ox = -1, 1 do
      for oy = -1, 1 do
        local bucket = grid[key(cx + ox, cy + oy)]
        if bucket then
          for bi = 1, #bucket do
            local j = bucket[bi]
            -- j > i emits each pair once; different seg only, because points
            -- inside one polyline are already chained.
            if j > i and nodes[j].seg ~= a.seg
                and dist2(a.x, a.y, nodes[j].x, nodes[j].y) <= join then
              edge(graph, i, j)
            end
          end
        end
      end
    end
  end

  if started then graph.built_ms = (os.clock() - started) * 1000.0 end
  -- Once per map, because build() is called once per map and cached. A seat
  -- that starts logging this every tick has lost its cache.
  if wow and wow.log then
    wow.log(string.format("road graph built: %d segments, %d nodes, %.0f ms",
      #segments, graph.n, graph.built_ms or -1))
  end
  return graph
end

-- Nearest graph node to a point. A continent tops out around 2700 nodes and a
-- route already pays a Dijkstra over all of them, so the straight scan is both
-- predictable and irrelevant to the cost; a ring search over the build grid
-- would only add an early-exit bound to get wrong. Always returns the lowest
-- index on a tie (determinism).
local function nearest(graph, x, y)
  local best, bestD = nil, nil
  for i = 1, graph.n do
    local nd = graph.nodes[i]
    local d = dist2(x, y, nd.x, nd.y)
    if bestD == nil or d < bestD then best, bestD = i, d end
  end
  return best, bestD
end
M.nearest = nearest

-- Binary min-heap over node indices. Ties break on the lower node index so two
-- equal-cost paths always resolve the same way.
local function heapLess(h, a, b)
  if h.cost[a] ~= h.cost[b] then return h.cost[a] < h.cost[b] end
  return h.node[a] < h.node[b]
end

local function heapPush(h, node, cost)
  local n = h.n + 1
  h.n = n
  h.node[n] = node
  h.cost[n] = cost
  while n > 1 do
    local p = floor(n / 2)
    if not heapLess(h, n, p) then break end
    h.node[p], h.node[n] = h.node[n], h.node[p]
    h.cost[p], h.cost[n] = h.cost[n], h.cost[p]
    n = p
  end
end

local function heapPop(h)
  if h.n == 0 then return nil end
  local top = h.node[1]
  h.node[1], h.cost[1] = h.node[h.n], h.cost[h.n]
  h.node[h.n], h.cost[h.n] = nil, nil
  h.n = h.n - 1
  local i = 1
  while true do
    local l, r = i * 2, i * 2 + 1
    local best = i
    if l <= h.n and heapLess(h, l, best) then best = l end
    if r <= h.n and heapLess(h, r, best) then best = r end
    if best == i then break end
    h.node[best], h.node[i] = h.node[i], h.node[best]
    h.cost[best], h.cost[i] = h.cost[i], h.cost[best]
    i = best
  end
  return top
end

local function append(pts, x, y, z, eps)
  local n = #pts
  if n > 0 and dist2(pts[n].x, pts[n].y, x, y) < eps then return end
  pts[n + 1] = { x = x, y = y, z = z }
end

-- route(graph, start, goal) -> waypoints, meta
--   waypoints : { {x=,y=,z=}, ... } always at least start and goal
--   meta      : { straight = bool, reason = string, cost, length, nodes }
-- Never errors and never returns nil. reason is one of:
--   "road"             a road route: walk the waypoints
--   "no-roads"         no graph for this map (missing data, or an ocean map)
--   "short-hop"        the road is further away than the goal is
--   "straight-cheaper" the detour costs more than the crow line even at 1.6x
--   "disconnected"     start and goal snap to road islands that do not meet
--                      (a hole in the bake -- docs/road-data.md 'Known gaps')
--   "budget"           settle cap hit; treat as a data bug
--   "no-path"          malformed graph, belt-and-braces
function M.route(graph, start, goal, opts)
  opts = opts or {}
  local penalty = opts.penalty or M.offRoadPenalty
  local budget = opts.nodeBudget or M.nodeBudget
  local shortHop = opts.shortHopFactor or M.shortHopFactor
  local eps = opts.epsilon or M.epsilon
  local sx, sy, sz = start.x, start.y, start.z
  local gx, gy, gz = goal.x, goal.y, goal.z
  local straightLen = dist2(sx, sy, gx, gy)

  local function bail(reason)
    local pts = {}
    append(pts, sx, sy, sz, eps)
    append(pts, gx, gy, gz, eps)
    return pts, {
      straight = true, reason = reason,
      length = straightLen, cost = straightLen * penalty, nodes = 0,
    }
  end

  if not graph or (graph.n or 0) < 2 then return bail("no-roads") end
  local entry, dEntry = nearest(graph, sx, sy)
  local goalNode, dExit = nearest(graph, gx, gy)
  if not entry or not goalNode then return bail("no-roads") end
  -- The goal is closer than the nearest tarmac: walking to a road to walk back
  -- is exactly the detour nobody wants.
  if straightLen <= dEntry * shortHop then return bail("short-hop") end
  -- Even a free road cannot beat the straight line once both off-road legs
  -- already cost more than the whole trip.
  if straightLen <= dEntry + dExit then return bail("short-hop") end

  local dist, prev, done = {}, {}, {}
  local h = { n = 0, node = {}, cost = {} }
  dist[entry] = 0
  heapPush(h, entry, 0)
  local settled, reached, overflow = 0, false, false
  while h.n > 0 and not reached and not overflow do
    local u = heapPop(h)
    if not done[u] then
      done[u] = true
      settled = settled + 1
      if settled > budget then
        overflow = true
      elseif u == goalNode then
        reached = true
      else
        local es = graph.adj[u]
        for ei = 1, #es do
          local e = es[ei]
          local nd = dist[u] + e.w
          if dist[e.to] == nil or nd < dist[e.to] then
            dist[e.to] = nd
            prev[e.to] = u
            heapPush(h, e.to, nd)
          end
        end
      end
    end
  end
  if overflow then return bail("budget") end
  if not reached then return bail("disconnected") end

  local roadCost = dist[goalNode]
  local total = (dEntry + dExit) * penalty + roadCost
  if total >= straightLen * penalty then return bail("straight-cheaper") end

  -- Walk prev back to the entry node; the guard is belt-and-braces against a
  -- malformed graph, since Dijkstra's tree cannot contain a cycle.
  local back, nb = {}, 0
  local u = goalNode
  while u and nb <= graph.n do
    nb = nb + 1
    back[nb] = u
    if u == entry then u = nil else u = prev[u] end
  end
  if back[nb] ~= entry then return bail("no-path") end

  local pts = {}
  append(pts, sx, sy, sz, eps)
  for i = nb, 1, -1 do
    local nd = graph.nodes[back[i]]
    append(pts, nd.x, nd.y, nd.z, eps)
  end
  append(pts, gx, gy, gz, eps)

  local length = 0
  for i = 2, #pts do
    length = length + dist2(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y)
  end
  return pts, {
    straight = false, reason = "road",
    length = length, cost = total, nodes = settled,
  }
end

-- The point to actually walk at right now: snap to the nearest route point,
-- then walk FORWARD along the path until `lead` yards of route are behind us.
-- Measuring progress along the route rather than as-the-crow-flies is what
-- stops a bot standing just past a waypoint from being told to turn around and
-- walk back to it.
-- -> x, y, z, index  (nil when there is no usable route)
function M.nextPoint(pts, x, y, lead)
  if not pts then return nil end
  local n = #pts
  if n < 2 then return nil end
  lead = lead or M.leadYards
  local near, nearD = 1, nil
  for i = 1, n do
    local d = dist2(x, y, pts[i].x, pts[i].y)
    if nearD == nil or d < nearD then near, nearD = i, d end
  end
  local acc = 0
  for i = near + 1, n do
    acc = acc + dist2(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y)
    if acc > lead then return pts[i].x, pts[i].y, pts[i].z, i end
  end
  return pts[n].x, pts[n].y, pts[n].z, n
end

-- How far the point is off the route it is supposed to be walking. The caller
-- uses it to decide a cached route has stopped describing the walk.
function M.offRoute(pts, x, y)
  if not pts or #pts == 0 then return nil end
  local bestD = nil
  for i = 1, #pts do
    local d = dist2(x, y, pts[i].x, pts[i].y)
    if bestD == nil or d < bestD then bestD = d end
  end
  return bestD
end

M.distance = dist2

return M
