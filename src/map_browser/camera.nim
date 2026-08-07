## Map-plane camera for the map browser: WASD pans, wheel zooms, RMB looks.
##
## Runs from the frameBoundary hook (fresh input, before simulation/draw) so
## motion applies to the frame being drawn — not one frame late from the UI
## pass. Velocity smoothing and an eased height target keep held keys and
## smooth-scroll wheels from teleporting the camera.

import
  std/[math, monotimes],
  vmath, windy,
  environment/client/renderer/cameras,
  environment/client/renderer/runtime,
  environment/client/wheel_input

const
  MapMinCameraHeight* = 30.0'f32
  MapLookSensitivity = 1.0'f32 / 340.0'f32
  ## Horizontal speed is proportional to height; vertical slightly slower.
  MapPanHeightSpeedScale = 1.1'f32
  MapVerticalSpeedScale = 0.9'f32
  MapPanSpeedMinHeight = 150.0'f32
  MapPanSpeedMaxHeight = 9000.0'f32
  ## Smoothing time constants (seconds).
  MapVelocityTau = 0.09'f32
  MapZoomTau = 0.12'f32
  MapWheelZoomFactor = 0.88'f32
  MapMaxWheelNotches = 4.0'f32
  MapDtClamp = 0.05'f32

type
  MapCamera* = object
    lastNs: int64
    vel: Vec3
    heightTarget: float32
    mouseLookActive: bool
    lastMousePos: IVec2

var cam: MapCamera

proc resetMapCamera*() =
  cam.lastNs = 0
  cam.vel = vec3(0, 0, 0)
  cam.heightTarget = 0.0'f32
  cam.mouseLookActive = false

proc mapPlaneBasis(): tuple[forward, right: Vec3] =
  ## Horizontal basis from yaw only — bird's-eye free-cam forward is mostly
  ## down, so pan on the map plane instead.
  let
    sy = sin(cameraYaw)
    cy = cos(cameraYaw)
  (
    vec3(sy, 0.0'f32, -cy),
    vec3(cy, 0.0'f32, sy)
  )

proc expApproach(current, target, dt, tau: float32): float32 =
  target + (current - target) * exp(-dt / tau)

proc updateMapPlaneCamera*(active: bool; maxHeight: float32) =
  ## Call once per app tick from frameBoundary.
  if window == nil or not active:
    resetMapCamera()
    return

  let nowNs = getMonoTime().ticks
  var dt = 1.0'f32 / 60.0'f32
  if cam.lastNs > 0:
    dt = float32(float64(nowNs - cam.lastNs) / 1e9)
  cam.lastNs = nowNs
  dt = clamp(dt, 0.001'f32, MapDtClamp)
  if cam.heightTarget <= 0.0'f32:
    cam.heightTarget = cameraPos.y

  let mouseLook = window.clientButtonDown(MouseRight)
  if mouseLook:
    if window.clientButtonPressed(MouseRight) or not cam.mouseLookActive:
      cam.lastMousePos = window.clientMousePos()
      cam.mouseLookActive = true
    else:
      let delta = window.clientMousePos() - cam.lastMousePos
      cam.lastMousePos = window.clientMousePos()
      if not delta.isMouseJump():
        cameraYaw += delta.x.float32 * MapLookSensitivity
        cameraPitch = clampCameraPitch(
          cameraPitch - delta.y.float32 * MapLookSensitivity
        )
  else:
    cam.mouseLookActive = false

  var speed = clamp(
    cameraPos.y, MapPanSpeedMinHeight, MapPanSpeedMaxHeight
  ) * MapPanHeightSpeedScale
  if window.clientButtonDown(KeyLeftShift):
    speed *= 3.0'f32
  if window.clientButtonDown(KeyLeftControl):
    speed *= 0.25'f32

  let basis = mapPlaneBasis()
  var targetVel = vec3(0, 0, 0)
  if window.clientButtonDown(KeyW):
    targetVel += basis.forward * speed
  if window.clientButtonDown(KeyS):
    targetVel -= basis.forward * speed
  if window.clientButtonDown(KeyA):
    targetVel -= basis.right * speed
  if window.clientButtonDown(KeyD):
    targetVel += basis.right * speed

  let vertSpeed = clamp(
    cameraPos.y, MapPanSpeedMinHeight, MapPanSpeedMaxHeight
  ) * MapVerticalSpeedScale
  if window.clientButtonDown(KeyQ) or window.clientButtonDown(KeyX):
    targetVel.y -= vertSpeed
  if window.clientButtonDown(KeyE) or window.clientButtonDown(KeySpace):
    targetVel.y += vertSpeed

  let blend = 1.0'f32 - exp(-dt / MapVelocityTau)
  cam.vel = mix(cam.vel, targetVel, blend)
  cameraPos += cam.vel * dt
  if targetVel.y != 0.0'f32:
    cameraPos.y = clamp(cameraPos.y, MapMinCameraHeight, maxHeight)
    cam.heightTarget = cameraPos.y

  let wheel = window.wheelDeltaY()
  if wheel != 0.0'f32:
    let notches = clamp(wheel, -MapMaxWheelNotches, MapMaxWheelNotches)
    cam.heightTarget = clamp(
      cam.heightTarget * pow(MapWheelZoomFactor, notches),
      MapMinCameraHeight,
      maxHeight
    )
  cameraPos.y = expApproach(cameraPos.y, cam.heightTarget, dt, MapZoomTau)
