## Constant-color GL overlays for the bird's-eye map browser.
## Waypoints, taxi paths, roads, activity rings, and traverse-run trails.
## Built once per continent/toggle change; drawn after terrain.

import
  std/[math, tables],
  opengl, vmath,
  bots/real_playerbot/policy/world_catalog,
  map_browser/[roads, runs, waypoints]

const
  VertSrc = """
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
uniform mat4 uMVP;
uniform float uPointSize;
out vec3 vColor;
void main() {
  gl_Position = uMVP * vec4(aPos, 1.0);
  gl_PointSize = uPointSize;
  vColor = aColor;
}
"""
  FragSrc = """
#version 330 core
in vec3 vColor;
out vec4 fragColor;
void main() {
  fragColor = vec4(vColor, 1.0);
}
"""
  ZLift = 20.0'f32
  WalkColor = (0.92'f32, 0.78'f32, 0.25'f32)
  LiftColor = (0.72'f32, 0.32'f32, 0.95'f32)
  SpellColor = (0.30'f32, 0.55'f32, 0.95'f32)
  TaxiColor = (0.30'f32, 0.82'f32, 0.90'f32)
  RoadColor = (0.90'f32, 0.15'f32, 0.15'f32)
  RegionColor = (0.35'f32, 0.85'f32, 0.45'f32)
  BeatColor = (0.95'f32, 0.80'f32, 0.30'f32)
  StartColor = (0.20'f32, 1.00'f32, 0.35'f32)
  EndColor = (1.00'f32, 0.25'f32, 0.20'f32)
  CheckpointColor = (0.95'f32, 0.95'f32, 0.95'f32)
  NodePointSize = 9.0'f32
  RoadPointSize = 5.0'f32
  MarkerPointSize = 12.0'f32
  CheckpointPointSize = 10.0'f32
  CircleSegments = 32
  VertFloats = 6
  RunPalette* = [
    (0.95'f32, 0.30'f32, 0.25'f32),
    (0.30'f32, 0.90'f32, 0.40'f32),
    (0.35'f32, 0.55'f32, 0.98'f32),
    (0.95'f32, 0.65'f32, 0.20'f32),
    (0.90'f32, 0.35'f32, 0.90'f32),
    (0.30'f32, 0.90'f32, 0.90'f32)
  ]

type
  OverlayCounts* = object
    wpNodes*: int
    wpEdges*: int
    taxiPaths*: int
    roadSegments*: int
    roadPoints*: int
    runsLoaded*: int
    labels*: int

  EdgeLabel* = object
    x*, y*, z*: float32
    text*: string

  PointBatch = object
    vao, vbo: GLuint
    count: int
    pointSize: float32

  LineBatch = object
    vao, vbo: GLuint
    count: int

  OverlayGpu = object
    program: GLuint
    mvpLoc, pointSizeLoc: GLint
    lines: LineBatch
    nodePoints: PointBatch
    markerPoints: PointBatch
    checkpointPoints: PointBatch
    roadPoints: PointBatch
    builtMapId: uint32
    counts: OverlayCounts
    labels: seq[EdgeLabel]
    dirty: bool

var overlayGpu: OverlayGpu

proc compileShader(kind: GLenum; source: string): GLuint =
  ## Compile one GLSL stage; quit on failure with log.
  result = glCreateShader(kind)
  let srcArr = allocCStringArray([source])
  glShaderSource(result, 1, srcArr, nil)
  deallocCStringArray(srcArr)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var logLen: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, logLen.addr)
    var log = newString(max(logLen, 1))
    glGetShaderInfoLog(result, logLen, nil, log.cstring)
    echo "map_browser: overlay shader compile failed:\n", log
    quit 1

proc linkProgram(vert, frag: GLuint): GLuint =
  ## Link vertex + fragment; quit on failure with log.
  result = glCreateProgram()
  glAttachShader(result, vert)
  glAttachShader(result, frag)
  glLinkProgram(result)
  var ok: GLint
  glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var logLen: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, logLen.addr)
    var log = newString(max(logLen, 1))
    glGetProgramInfoLog(result, logLen, nil, log.cstring)
    echo "map_browser: overlay program link failed:\n", log
    quit 1
  glDeleteShader(vert)
  glDeleteShader(frag)

proc edgeColor(kind: WaypointEdgeKind): tuple[r, g, b: float32] =
  ## Color for a waypoint edge/node kind.
  case kind
  of wekWalk: WalkColor
  of wekLift: LiftColor
  of wekSpell: SpellColor

proc nodeKind(node: RealPlayerBotWorldNode): WaypointEdgeKind =
  ## Kind used to color a waypoint node marker.
  if node.greatLift:
    wekLift
  elif node.travelSpellId != 0'u32:
    wekSpell
  else:
    wekWalk

proc pushVert(
  verts: var seq[float32];
  x, y, z, r, g, b: float32
) =
  ## Append one interleaved pos+color vertex.
  verts.add x
  verts.add y
  verts.add z
  verts.add r
  verts.add g
  verts.add b

proc pushLine(
  verts: var seq[float32];
  ax, ay, az, bx, by, bz, r, g, b: float32
) =
  ## Append a GL_LINES segment (two vertices).
  pushVert(verts, ax, ay, az, r, g, b)
  pushVert(verts, bx, by, bz, r, g, b)

proc pushCircle(
  verts: var seq[float32];
  x, y, z, radius, r, g, b: float32;
  segments = CircleSegments
) =
  ## Append a line-loop circle in the XY plane as GL_LINES segments.
  if radius <= 0.0'f32:
    return
  let twoPi = float32(PI * 2.0)
  for i in 0 ..< segments:
    let
      a0 = float32(i) / float32(segments) * twoPi
      a1 = float32(i + 1) / float32(segments) * twoPi
    pushLine(
      verts,
      x + cos(a0) * radius, y + sin(a0) * radius, z,
      x + cos(a1) * radius, y + sin(a1) * radius, z,
      r, g, b
    )

proc ensureBatchVao(vao, vbo: var GLuint) =
  ## Allocate VAO/VBO once for a batch.
  if vao != 0:
    return
  glGenVertexArrays(1, vao.addr)
  glGenBuffers(1, vbo.addr)
  glBindVertexArray(vao)
  glBindBuffer(GL_ARRAY_BUFFER, vbo)
  let stride = GLsizei(VertFloats * sizeof(float32))
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](0))
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(
    1, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](3 * sizeof(float32))
  )
  glBindVertexArray(0)
  glBindBuffer(GL_ARRAY_BUFFER, 0)

proc uploadBatch(vao, vbo: var GLuint; verts: seq[float32]): int =
  ## Upload interleaved verts; returns vertex count.
  ensureBatchVao(vao, vbo)
  if verts.len == 0:
    return 0
  glBindBuffer(GL_ARRAY_BUFFER, vbo)
  glBufferData(
    GL_ARRAY_BUFFER,
    GLsizeiptr(verts.len * sizeof(float32)),
    unsafeAddr verts[0],
    GL_DYNAMIC_DRAW
  )
  glBindBuffer(GL_ARRAY_BUFFER, 0)
  verts.len div VertFloats

proc initOverlayGpu*() =
  ## Create the overlay GLSL program (call once after GL context is current).
  if overlayGpu.program != 0:
    return
  let
    vert = compileShader(GL_VERTEX_SHADER, VertSrc)
    frag = compileShader(GL_FRAGMENT_SHADER, FragSrc)
  overlayGpu.program = linkProgram(vert, frag)
  overlayGpu.mvpLoc = glGetUniformLocation(overlayGpu.program, "uMVP")
  overlayGpu.pointSizeLoc = glGetUniformLocation(overlayGpu.program, "uPointSize")
  overlayGpu.builtMapId = high(uint32)
  overlayGpu.dirty = true

proc markOverlaysDirty*() =
  ## Request a geometry rebuild on the next draw.
  overlayGpu.dirty = true

proc overlayCounts*(): OverlayCounts =
  ## Last-built overlay counts for stats JSON.
  overlayGpu.counts

proc edgeLabels*(): seq[EdgeLabel] =
  ## Lift/teleport label anchors for the silky UI pass.
  overlayGpu.labels

proc rebuildOverlays*(
  mapId: uint32;
  showWaypoints, showTaxi: bool;
  graph: WaypointGraph;
  taxi: seq[TaxiPolyline];
  regions: seq[RealPlayerBotActivityRegion];
  loadedRuns: Table[string, TraverseRun];
  selectedRuns: seq[string];
  beats: seq[TraverseBeat];
  checkpoints: seq[TraverseCheckpoint];
  showRoads: bool;
  roads: seq[RoadSegment]
) =
  ## Filter to mapId and rebuild dynamic VBOs for lines + points.
  initOverlayGpu()
  var
    lineVerts: seq[float32]
    nodeVerts: seq[float32]
    markerVerts: seq[float32]
    checkpointVerts: seq[float32]
    roadVerts: seq[float32]
    counts = OverlayCounts()
    labels: seq[EdgeLabel]

  if showWaypoints:
    for node in graph.nodes:
      if node.point.mapId != mapId:
        continue
      inc counts.wpNodes
      let c = edgeColor(nodeKind(node))
      pushVert(
        nodeVerts,
        node.point.x, node.point.y, node.point.z + 2.0'f32,
        c.r, c.g, c.b
      )
    for edge in graph.edges:
      if edge.a < 0 or edge.a >= graph.nodes.len or
          edge.b < 0 or edge.b >= graph.nodes.len:
        continue
      let
        a = graph.nodes[edge.a].point
        b = graph.nodes[edge.b].point
      if a.mapId != mapId or b.mapId != mapId:
        continue
      inc counts.wpEdges
      let c = edgeColor(edge.kind)
      pushLine(
        lineVerts,
        a.x, a.y, a.z + ZLift,
        b.x, b.y, b.z + ZLift,
        c.r, c.g, c.b
      )
      if edge.kind != wekWalk:
        inc counts.labels
        labels.add EdgeLabel(
          x: (a.x + b.x) * 0.5'f32,
          y: (a.y + b.y) * 0.5'f32,
          z: (a.z + b.z) * 0.5'f32 + ZLift,
          text: if edge.kind == wekLift: "LIFT" else: "TELEPORT"
        )
    for region in regions:
      if region.point.mapId != mapId:
        continue
      pushCircle(
        lineVerts,
        region.point.x, region.point.y, region.point.z + ZLift,
        region.entryRadius,
        RegionColor[0], RegionColor[1], RegionColor[2]
      )

  if showTaxi:
    for line in taxi:
      if line.mapId != mapId or line.points.len < 2:
        continue
      inc counts.taxiPaths
      for i in 0 ..< line.points.len - 1:
        let
          a = line.points[i]
          b = line.points[i + 1]
        pushLine(
          lineVerts,
          a.x, a.y, a.z + ZLift,
          b.x, b.y, b.z + ZLift,
          TaxiColor[0], TaxiColor[1], TaxiColor[2]
        )

  if showRoads:
    for segment in roads:
      if segment.mapId != mapId:
        continue
      inc counts.roadSegments
      for i in 0 ..< segment.points.len - 1:
        let
          a = segment.points[i]
          b = segment.points[i + 1]
        pushLine(
          lineVerts,
          a.x, a.y, a.z + ZLift,
          b.x, b.y, b.z + ZLift,
          RoadColor[0], RoadColor[1], RoadColor[2]
        )
      for point in segment.points:
        inc counts.roadPoints
        pushVert(
          roadVerts,
          point.x, point.y, point.z + ZLift + 2.0'f32,
          RoadColor[0], RoadColor[1], RoadColor[2]
        )

  for index, path in selectedRuns:
    if path notin loadedRuns:
      continue
    let run = loadedRuns[path]
    if not run.ok or run.mapId != mapId or run.points.len == 0:
      continue
    inc counts.runsLoaded
    let color = RunPalette[index mod RunPalette.len]
    for i in 0 ..< run.points.len - 1:
      let
        a = run.points[i]
        b = run.points[i + 1]
      pushLine(
        lineVerts,
        a.x, a.y, a.z + ZLift,
        b.x, b.y, b.z + ZLift,
        color[0], color[1], color[2]
      )
    let
      s = run.points[0]
      e = run.points[^1]
    pushVert(
      markerVerts,
      s.x, s.y, s.z + ZLift + 3.0'f32,
      StartColor[0], StartColor[1], StartColor[2]
    )
    pushVert(
      markerVerts,
      e.x, e.y, e.z + ZLift + 3.0'f32,
      EndColor[0], EndColor[1], EndColor[2]
    )

  if selectedRuns.len > 0:
    if mapId == 1'u32:
      for beat in beats:
        pushCircle(
          lineVerts,
          beat.x, beat.y, beat.z + ZLift,
          beat.radius,
          BeatColor[0], BeatColor[1], BeatColor[2]
        )
    for checkpoint in checkpoints:
      if checkpoint.mapId != mapId:
        continue
      pushVert(
        checkpointVerts,
        checkpoint.x, checkpoint.y, checkpoint.z + ZLift + 2.0'f32,
        CheckpointColor[0], CheckpointColor[1], CheckpointColor[2]
      )

  overlayGpu.lines.count = uploadBatch(
    overlayGpu.lines.vao, overlayGpu.lines.vbo, lineVerts
  )
  overlayGpu.nodePoints.count = uploadBatch(
    overlayGpu.nodePoints.vao, overlayGpu.nodePoints.vbo, nodeVerts
  )
  overlayGpu.nodePoints.pointSize = NodePointSize
  overlayGpu.markerPoints.count = uploadBatch(
    overlayGpu.markerPoints.vao, overlayGpu.markerPoints.vbo, markerVerts
  )
  overlayGpu.markerPoints.pointSize = MarkerPointSize
  overlayGpu.checkpointPoints.count = uploadBatch(
    overlayGpu.checkpointPoints.vao, overlayGpu.checkpointPoints.vbo,
    checkpointVerts
  )
  overlayGpu.checkpointPoints.pointSize = CheckpointPointSize
  overlayGpu.roadPoints.count = uploadBatch(
    overlayGpu.roadPoints.vao, overlayGpu.roadPoints.vbo, roadVerts
  )
  overlayGpu.roadPoints.pointSize = RoadPointSize
  overlayGpu.counts = counts
  overlayGpu.labels = labels
  overlayGpu.builtMapId = mapId
  overlayGpu.dirty = false

proc needsRebuild*(mapId: uint32): bool =
  ## True when geometry must be rebuilt for the active continent.
  overlayGpu.dirty or overlayGpu.builtMapId != mapId or overlayGpu.program == 0

proc drawPointBatch(batch: PointBatch; mvpLoc, sizeLoc: GLint; mvp: var Mat4) =
  ## Draw one GL_POINTS batch with a fixed screen-space point size.
  if batch.count <= 0 or batch.vao == 0:
    return
  glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, cast[ptr GLfloat](mvp.addr))
  glUniform1f(sizeLoc, batch.pointSize)
  glBindVertexArray(batch.vao)
  glDrawArrays(GL_POINTS, 0, GLsizei(batch.count))
  glBindVertexArray(0)

proc drawOverlays*(viewProj: Mat4; xray: bool) =
  ## Draw overlay lines/points after terrain. Xray disables depth test.
  if overlayGpu.program == 0:
    return
  if overlayGpu.lines.count == 0 and
      overlayGpu.nodePoints.count == 0 and
      overlayGpu.markerPoints.count == 0 and
      overlayGpu.checkpointPoints.count == 0 and
      overlayGpu.roadPoints.count == 0:
    return

  glUseProgram(overlayGpu.program)
  glEnable(GL_PROGRAM_POINT_SIZE)
  if xray:
    glDisable(GL_DEPTH_TEST)
  else:
    glEnable(GL_DEPTH_TEST)
    glDepthFunc(GL_LESS)
  glDisable(GL_BLEND)

  var mvp = viewProj
  if overlayGpu.lines.count > 0 and overlayGpu.lines.vao != 0:
    glUniformMatrix4fv(
      overlayGpu.mvpLoc, 1, GL_FALSE, cast[ptr GLfloat](mvp.addr)
    )
    glUniform1f(overlayGpu.pointSizeLoc, 1.0'f32)
    glBindVertexArray(overlayGpu.lines.vao)
    glDrawArrays(GL_LINES, 0, GLsizei(overlayGpu.lines.count))
    glBindVertexArray(0)

  drawPointBatch(
    overlayGpu.nodePoints, overlayGpu.mvpLoc, overlayGpu.pointSizeLoc, mvp
  )
  drawPointBatch(
    overlayGpu.markerPoints, overlayGpu.mvpLoc, overlayGpu.pointSizeLoc, mvp
  )
  drawPointBatch(
    overlayGpu.checkpointPoints, overlayGpu.mvpLoc, overlayGpu.pointSizeLoc, mvp
  )
  drawPointBatch(
    overlayGpu.roadPoints, overlayGpu.mvpLoc, overlayGpu.pointSizeLoc, mvp
  )

  glDisable(GL_PROGRAM_POINT_SIZE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(0)
