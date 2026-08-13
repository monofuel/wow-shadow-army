## Standalone bird's-eye GL viewer for continent WDL meshes.
## No fork renderer imports — pure OpenGL + vmath + windy input.

import
  std/[math, options, tables],
  opengl, vmath, windy,
  map_browser/[atlas, wdl_terrain]

const
  VertSrc = """
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
layout(location = 2) in vec3 aColor;
uniform mat4 uMVP;
out vec3 vColor;
out vec3 vNormal;
out vec2 vWorldXY;
void main() {
  gl_Position = uMVP * vec4(aPos, 1.0);
  vColor = aColor;
  vNormal = aNormal;
  vWorldXY = aPos.xy;
}
"""
  FragSrc = """
#version 330 core
in vec3 vColor;
in vec3 vNormal;
in vec2 vWorldXY;
uniform int uAtlasOn;
uniform sampler2D uAtlasTex;
uniform vec2 uAtlasU;
uniform vec2 uAtlasV;
out vec4 fragColor;
void main() {
  vec3 n = normalize(vNormal);
  float light = max(dot(n, normalize(vec3(0.35, 0.5, 0.8))), 0.25);
  vec3 base = vColor;
  if (uAtlasOn != 0) {
    vec2 uv = vec2(
      (uAtlasU.x - vWorldXY.y) * uAtlasU.y,
      (uAtlasV.x - vWorldXY.x) * uAtlasV.y
    );
    vec4 t = texture(uAtlasTex, uv);
    if (t.a > 0.5) base = t.rgb;
  }
  fragColor = vec4(base * light, 1.0);
}
"""
  ## Eye south of target looking north: world +X (north) up on screen,
  ## matching in-game map orientation.
  DefaultYaw* = -90.0'f32
  DefaultPitch* = -70.0'f32
  PitchMin* = -90.0'f32
  PitchMax* = -25.0'f32
  HeightMin* = 200.0'f32
  HeightMax* = 45000.0'f32
  FovyDeg* = 50.0'f32
  NearClip* = 10.0'f32
  FarClip* = 60000.0'f32
  PanSpeedScale* = 1.2'f32
  OrbitSens* = 0.18'f32
  DragPanSens* = 0.0018'f32
  WheelZoomFactor* = 0.9'f32
  VertexStride = 9 * sizeof(float32)

type
  MeshBounds* = object
    minX*, maxX*, minY*, maxY*, minZ*, maxZ*: float32

  BirdCamera* = object
    targetX*, targetY*, targetZ*: float32
    height*: float32
    yaw*, pitch*: float32

  GpuMesh* = object
    ready*: bool
    vao, vbo, ibo: GLuint
    indexCount: int
    mapId*: uint32
    name*: string
    tileCount*: int
    vertexCount*: int
    bounds*: MeshBounds

  AtlasGpu = object
    ready: bool
    tex: GLuint
    uOrigin, uScale, vOrigin, vScale: float32
    width, height: int

  TerrainGpu* = object
    program: GLuint
    mvpLoc: GLint
    atlasOnLoc: GLint
    atlasTexLoc: GLint
    atlasULoc: GLint
    atlasVLoc: GLint
    meshes: Table[uint32, GpuMesh]
    atlases: Table[uint32, AtlasGpu]
    currentMapId*: uint32

var
  terrainGpu*: TerrainGpu
  birdCam*: BirdCamera
  continentLoadError*: string
  atlasEnabled*: bool = true
  rightDragActive: bool

proc compileShader(kind: GLenum; source: string): GLuint =
  ## Compile one GLSL shader stage; quit on failure with log.
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
    echo "map_browser: shader compile failed:\n", log
    quit 1

proc linkProgram(vert, frag: GLuint): GLuint =
  ## Link vertex + fragment into a program; quit on failure with log.
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
    echo "map_browser: program link failed:\n", log
    quit 1
  glDeleteShader(vert)
  glDeleteShader(frag)

proc initTerrainGpu*() =
  ## Create the terrain GLSL program (call once after GL context is current).
  if terrainGpu.program != 0:
    return
  let
    vert = compileShader(GL_VERTEX_SHADER, VertSrc)
    frag = compileShader(GL_FRAGMENT_SHADER, FragSrc)
  terrainGpu.program = linkProgram(vert, frag)
  terrainGpu.mvpLoc = glGetUniformLocation(terrainGpu.program, "uMVP")
  terrainGpu.atlasOnLoc = glGetUniformLocation(terrainGpu.program, "uAtlasOn")
  terrainGpu.atlasTexLoc = glGetUniformLocation(terrainGpu.program, "uAtlasTex")
  terrainGpu.atlasULoc = glGetUniformLocation(terrainGpu.program, "uAtlasU")
  terrainGpu.atlasVLoc = glGetUniformLocation(terrainGpu.program, "uAtlasV")
  terrainGpu.meshes = initTable[uint32, GpuMesh]()
  terrainGpu.atlases = initTable[uint32, AtlasGpu]()

proc meshBounds(mesh: ContinentMesh): MeshBounds =
  ## Axis-aligned bounds of a continent mesh in VMaNGOS world coords.
  if mesh.vertices.len == 0:
    return MeshBounds()
  result.minX = mesh.vertices[0].x
  result.maxX = mesh.vertices[0].x
  result.minY = mesh.vertices[0].y
  result.maxY = mesh.vertices[0].y
  result.minZ = mesh.minZ
  result.maxZ = mesh.maxZ
  for v in mesh.vertices:
    result.minX = min(result.minX, v.x)
    result.maxX = max(result.maxX, v.x)
    result.minY = min(result.minY, v.y)
    result.maxY = max(result.maxY, v.y)

proc uploadContinentMesh*(mapId: uint32; mesh: ContinentMesh): bool =
  ## Upload a ContinentMesh into a static VAO/VBO/IBO; caches by mapId.
  initTerrainGpu()
  if mapId in terrainGpu.meshes and terrainGpu.meshes[mapId].ready:
    return true
  if mesh.vertices.len == 0 or mesh.indices.len == 0:
    return false

  var gpu = GpuMesh(
    ready: true,
    mapId: mapId,
    name: mesh.mapDirectory,
    tileCount: mesh.tileCount,
    vertexCount: mesh.vertices.len,
    bounds: meshBounds(mesh),
    indexCount: mesh.indices.len
  )

  glGenVertexArrays(1, gpu.vao.addr)
  glGenBuffers(1, gpu.vbo.addr)
  glGenBuffers(1, gpu.ibo.addr)
  glBindVertexArray(gpu.vao)

  glBindBuffer(GL_ARRAY_BUFFER, gpu.vbo)
  glBufferData(
    GL_ARRAY_BUFFER,
    GLsizeiptr(mesh.vertices.len * VertexStride),
    unsafeAddr mesh.vertices[0],
    GL_STATIC_DRAW
  )

  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gpu.ibo)
  glBufferData(
    GL_ELEMENT_ARRAY_BUFFER,
    GLsizeiptr(mesh.indices.len * sizeof(uint32)),
    unsafeAddr mesh.indices[0],
    GL_STATIC_DRAW
  )

  let stride = GLsizei(VertexStride)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](0))
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(
    1, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](3 * sizeof(float32))
  )
  glEnableVertexAttribArray(2)
  glVertexAttribPointer(
    2, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](6 * sizeof(float32))
  )

  glBindVertexArray(0)
  glBindBuffer(GL_ARRAY_BUFFER, 0)
  terrainGpu.meshes[mapId] = gpu
  terrainGpu.currentMapId = mapId
  true

proc uploadAtlas*(mapId: uint32) =
  ## Upload a minimap atlas texture for mapId if a baked PNG+JSON is present.
  initTerrainGpu()
  if mapId in terrainGpu.atlases and terrainGpu.atlases[mapId].ready:
    return
  let loaded = loadAtlas(mapId)
  if loaded.isNone:
    return
  let atlas = loaded.get()
  if atlas.image == nil or atlas.image.data.len == 0:
    return
  var maxSize: GLint
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, maxSize.addr)
  if atlas.width > maxSize or atlas.height > maxSize:
    stderr.writeLine(
      "map_browser: atlas ", atlasMapName(mapId), " ",
      atlas.width, "x", atlas.height,
      " exceeds GL_MAX_TEXTURE_SIZE ", maxSize
    )
    return
  let uv = atlasUvParams(atlas)
  var tex: GLuint
  glGenTextures(1, tex.addr)
  glBindTexture(GL_TEXTURE_2D, tex)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GLint(GL_RGBA8),
    GLsizei(atlas.width),
    GLsizei(atlas.height),
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    addr atlas.image.data[0]
  )
  glGenerateMipmap(GL_TEXTURE_2D)
  glBindTexture(GL_TEXTURE_2D, 0)
  terrainGpu.atlases[mapId] = AtlasGpu(
    ready: true,
    tex: tex,
    uOrigin: uv.uOrigin,
    uScale: uv.uScale,
    vOrigin: uv.vOrigin,
    vScale: uv.vScale,
    width: atlas.width,
    height: atlas.height
  )

proc hasAtlas*(mapId: uint32): bool =
  ## True when a GPU atlas texture is ready for this continent.
  mapId in terrainGpu.atlases and terrainGpu.atlases[mapId].ready

proc currentHasAtlas*(): bool =
  ## True when the active continent has a GPU atlas texture.
  hasAtlas(terrainGpu.currentMapId)

proc ensureContinent*(mapId: uint32): bool =
  ## Load + upload a continent mesh if not already cached.
  if mapId in terrainGpu.meshes and terrainGpu.meshes[mapId].ready:
    terrainGpu.currentMapId = mapId
    continentLoadError = ""
    uploadAtlas(mapId)
    return true
  try:
    let mesh = loadContinentMesh(mapId)
    result = uploadContinentMesh(mapId, mesh)
    if result:
      terrainGpu.currentMapId = mapId
      continentLoadError = ""
      uploadAtlas(mapId)
  except CatchableError as err:
    echo "map_browser: loadContinentMesh(", mapId, ") failed: ", err.msg
    continentLoadError = "map " & $mapId & " load failed: " & err.msg
    result = false

proc currentGpu*(): GpuMesh =
  ## GPU mesh for the active continent (empty if none).
  if terrainGpu.currentMapId in terrainGpu.meshes:
    result = terrainGpu.meshes[terrainGpu.currentMapId]

proc currentContinentName*(): string =
  ## Human label for the active continent.
  let g = currentGpu()
  if g.name.len > 0:
    return g.name
  continentDirectory(terrainGpu.currentMapId)

proc eyePos*(cam: BirdCamera): Vec3 =
  ## World-space eye from bird's-eye target / height / yaw / pitch (degrees).
  let
    yawR = cam.yaw.toRadians
    pitchR = cam.pitch.toRadians
    cp = cos(pitchR)
    sp = sin(pitchR)
  vec3(
    cam.targetX + cam.height * cp * sin(yawR),
    cam.targetY + cam.height * cp * cos(yawR),
    cam.targetZ + cam.height * (-sp)
  )

proc viewMatrix*(cam: BirdCamera): Mat4 =
  ## Look-at view with Z-up.
  lookAt(
    cam.eyePos,
    vec3(cam.targetX, cam.targetY, cam.targetZ),
    vec3(0'f32, 0'f32, 1'f32)
  )

proc projMatrix*(aspect: float32): Mat4 =
  ## Perspective projection for the bird's-eye viewer.
  perspective(FovyDeg, aspect, NearClip, FarClip)

proc viewProjMatrix*(cam: BirdCamera; aspect: float32): Mat4 =
  ## Combined view-projection for drawing and unprojection.
  projMatrix(aspect) * cam.viewMatrix

proc fitToBounds*(cam: var BirdCamera; bounds: MeshBounds; aspect: float32) =
  ## Frame the whole mesh AABB with default bird's-eye angles.
  discard aspect
  cam.targetX = (bounds.minX + bounds.maxX) * 0.5'f32
  cam.targetY = (bounds.minY + bounds.maxY) * 0.5'f32
  cam.targetZ = (bounds.minZ + bounds.maxZ) * 0.5'f32
  let
    span = max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
    halfFov = toRadians(FovyDeg * 0.5'f32)
  cam.height = clamp(
    (span * 0.55'f32) / max(tan(halfFov), 1e-4'f32),
    HeightMin,
    HeightMax
  )
  cam.yaw = DefaultYaw
  cam.pitch = DefaultPitch

proc fitCurrentContinent*(aspect: float32 = 16.0'f32 / 9.0'f32) =
  ## Reset birdCam to whole-continent framing of the active mesh.
  let g = currentGpu()
  if g.ready:
    birdCam.fitToBounds(g.bounds, aspect)

proc drawTerrain*(viewProj: Mat4) =
  ## Draw the active continent mesh with headlight shading.
  let g = currentGpu()
  if not g.ready or terrainGpu.program == 0:
    return
  glUseProgram(terrainGpu.program)
  var m = viewProj
  glUniformMatrix4fv(
    terrainGpu.mvpLoc,
    1,
    GL_FALSE,
    cast[ptr GLfloat](m.addr)
  )
  if atlasEnabled and hasAtlas(terrainGpu.currentMapId):
    let a = terrainGpu.atlases[terrainGpu.currentMapId]
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, a.tex)
    glUniform1i(terrainGpu.atlasOnLoc, 1)
    glUniform1i(terrainGpu.atlasTexLoc, 0)
    glUniform2f(terrainGpu.atlasULoc, a.uOrigin, a.uScale)
    glUniform2f(terrainGpu.atlasVLoc, a.vOrigin, a.vScale)
  else:
    glUniform1i(terrainGpu.atlasOnLoc, 0)
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LESS)
  glDisable(GL_BLEND)
  glBindVertexArray(g.vao)
  glDrawElements(
    GL_TRIANGLES,
    GLsizei(g.indexCount),
    GL_UNSIGNED_INT,
    nil
  )
  glBindVertexArray(0)
  glUseProgram(0)

proc worldToScreen*(
  viewProj: Mat4;
  windowSize: IVec2;
  x, y, z: float32
): tuple[ok: bool, pos: Vec2] =
  ## Project a world point to window pixels (origin top-left). Exported for T4.
  let clip = viewProj * vec4(x, y, z, 1.0'f32)
  if abs(clip.w) < 1e-8'f32:
    return (false, vec2(0, 0))
  let
    ndcX = clip.x / clip.w
    ndcY = clip.y / clip.w
    ndcZ = clip.z / clip.w
  if ndcZ < -1.0'f32 or ndcZ > 1.0'f32:
    return (false, vec2(0, 0))
  result.ok = true
  result.pos = vec2(
    (ndcX * 0.5'f32 + 0.5'f32) * float32(windowSize.x),
    (1.0'f32 - (ndcY * 0.5'f32 + 0.5'f32)) * float32(windowSize.y)
  )

proc planeHit*(
  cam: BirdCamera;
  viewProj: Mat4;
  windowSize: IVec2;
  mouse: IVec2
): tuple[ok: bool, x, y: float32] =
  ## Unproject mouse to the horizontal plane at cam.targetZ.
  if windowSize.x <= 0 or windowSize.y <= 0:
    return
  let
    ndcX = (float32(mouse.x) / float32(windowSize.x)) * 2.0'f32 - 1.0'f32
    ndcY = 1.0'f32 - (float32(mouse.y) / float32(windowSize.y)) * 2.0'f32
    inv = inverse(viewProj)
  var
    nearP = inv * vec4(ndcX, ndcY, -1.0'f32, 1.0'f32)
    farP = inv * vec4(ndcX, ndcY, 1.0'f32, 1.0'f32)
  if abs(nearP.w) < 1e-8'f32 or abs(farP.w) < 1e-8'f32:
    return
  nearP = nearP / nearP.w
  farP = farP / farP.w
  let dir = vec3(farP.x - nearP.x, farP.y - nearP.y, farP.z - nearP.z)
  if abs(dir.z) < 1e-8'f32:
    return
  let t = (cam.targetZ - nearP.z) / dir.z
  if t < 0.0'f32:
    return
  result.ok = true
  result.x = nearP.x + dir.x * t
  result.y = nearP.y + dir.y * t

proc panBasis(yawDeg: float32): tuple[forward, right: Vec2] =
  ## Camera-relative ground basis, Z-up world. The eye sits at
  ## target + (sin yaw, cos yaw)·r, so camera forward is the negation and
  ## screen-right is forward × up.
  let yawR = yawDeg.toRadians
  (
    vec2(-sin(yawR), -cos(yawR)),
    vec2(-cos(yawR), sin(yawR))
  )

proc windowAspect(window: Window): float32 =
  ## Safe width/height ratio for the projection matrix.
  if window.size.y > 0:
    float32(window.size.x) / float32(window.size.y)
  else:
    16.0'f32 / 9.0'f32

proc updateBirdCamera*(window: Window; dt: float32) =
  ## Apply WASD / LMB pan / wheel zoom / RMB orbit / Home / Tab for one frame.
  let
    aspect = window.windowAspect
    mouse = window.mousePos
    delta = window.mouseDelta
    scrollY = window.scrollDelta.y

  if window.buttonPressed[KeyHome]:
    fitCurrentContinent(aspect)

  if window.buttonPressed[KeyTab]:
    let next =
      if terrainGpu.currentMapId == 1'u32: 0'u32
      else: 1'u32
    if ensureContinent(next):
      fitCurrentContinent(aspect)

  if window.buttonDown[MouseRight]:
    if window.buttonPressed[MouseRight] or not rightDragActive:
      rightDragActive = true
    else:
      birdCam.yaw += float32(delta.x) * OrbitSens
      birdCam.pitch = clamp(
        birdCam.pitch - float32(delta.y) * OrbitSens,
        PitchMin,
        PitchMax
      )
  else:
    rightDragActive = false

  let vp = birdCam.viewProjMatrix(aspect)

  if window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
    let
      basis = panBasis(birdCam.yaw)
      scale = birdCam.height * DragPanSens
    birdCam.targetX -=
      (basis.right.x * float32(delta.x) -
        basis.forward.x * float32(delta.y)) * scale
    birdCam.targetY -=
      (basis.right.y * float32(delta.x) -
        basis.forward.y * float32(delta.y)) * scale

  let
    basis = panBasis(birdCam.yaw)
    speed = birdCam.height * PanSpeedScale * max(dt, 0.001'f32)
  if window.buttonDown[KeyW]:
    birdCam.targetX += basis.forward.x * speed
    birdCam.targetY += basis.forward.y * speed
  if window.buttonDown[KeyS]:
    birdCam.targetX -= basis.forward.x * speed
    birdCam.targetY -= basis.forward.y * speed
  if window.buttonDown[KeyA]:
    birdCam.targetX -= basis.right.x * speed
    birdCam.targetY -= basis.right.y * speed
  if window.buttonDown[KeyD]:
    birdCam.targetX += basis.right.x * speed
    birdCam.targetY += basis.right.y * speed

  if scrollY != 0.0'f32:
    let
      before = planeHit(birdCam, vp, window.size, mouse)
      notches = clamp(scrollY, -4.0'f32, 4.0'f32)
      factor = pow(WheelZoomFactor, notches)
    birdCam.height = clamp(birdCam.height * factor, HeightMin, HeightMax)
    let
      vp2 = birdCam.viewProjMatrix(aspect)
      after = planeHit(birdCam, vp2, window.size, mouse)
    if before.ok and after.ok:
      birdCam.targetX += before.x - after.x
      birdCam.targetY += before.y - after.y
