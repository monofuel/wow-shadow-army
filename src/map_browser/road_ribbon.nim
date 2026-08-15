## Multi-scale visual detector for broad, light road ribbons in minimap art.
##
## This module deliberately knows nothing about Thousand Needles, endpoints,
## or routes.  It scores local image evidence only.  Terrain and topology are
## separate consumers of the score so neither can manufacture a road.

import
  std/[algorithm, math],
  pixie

type
  RibbonEvidence* = object
    score*: float32
    angleDeg*: float32
    halfWidthPx*: float32
    leftContrast*, rightContrast*: float32

  RibbonConfig* = object
    angleStepDeg*: int
    tangentRadiusPx*: int
    minHalfWidthPx*, maxHalfWidthPx*: int
    minSideContrast*: float32
    minScore*: float32

const DefaultRibbonConfig* = RibbonConfig(
  angleStepDeg: 15,
  tangentRadiusPx: 2,
  minHalfWidthPx: 2,
  maxHalfWidthPx: 6,
  minSideContrast: 3.0'f32,
  minScore: 8.0'f32
)

type ColorFeature = object
  luma, warmth, saturation: float32

proc clampPixel(value, limit: int): int {.inline.} =
  max(0, min(limit - 1, value))

proc feature(color: ColorRGBX): ColorFeature {.inline.} =
  let
    r = float32(color.r)
    g = float32(color.g)
    b = float32(color.b)
    hi = max(r, max(g, b))
    lo = min(r, min(g, b))
  result.luma = 0.299'f32 * r + 0.587'f32 * g + 0.114'f32 * b
  # Tan roads are not merely bright: relative to the red canyon floor they
  # gain green/blue while retaining r > g > b.  This rejects white mesa caps.
  result.warmth = (g + 0.55'f32 * b) - 0.72'f32 * r
  result.saturation = hi - lo

proc sampleFeature(image: Image; x, y: float32): ColorFeature {.inline.} =
  let
    ix = clampPixel(int(round(x)), image.width)
    iy = clampPixel(int(round(y)), image.height)
  feature(image.data[iy * image.width + ix])

proc stripMean(
  image: Image;
  x, y, tx, ty, nx, ny, normalOffset: float32;
  tangentRadius: int
): ColorFeature =
  var count = 0.0'f32
  for along in -tangentRadius .. tangentRadius:
    let f = sampleFeature(
      image,
      x + tx * float32(along) + nx * normalOffset,
      y + ty * float32(along) + ny * normalOffset
    )
    result.luma += f.luma
    result.warmth += f.warmth
    result.saturation += f.saturation
    count += 1.0'f32
  result.luma /= count
  result.warmth /= count
  result.saturation /= count

proc orientedEvidence(
  image: Image;
  x, y, angleRad, halfWidth: float32;
  config: RibbonConfig
): RibbonEvidence =
  let
    tx = cos(angleRad)
    ty = sin(angleRad)
    nx = -ty
    ny = tx
    center = stripMean(
      image, x, y, tx, ty, nx, ny, 0.0'f32, config.tangentRadiusPx)
    # Average two samples on each flank.  This makes the response stable over
    # the 12--40 yard road widths while still requiring two real boundaries.
    leftInner = stripMean(
      image, x, y, tx, ty, nx, ny, halfWidth + 1.0'f32,
      config.tangentRadiusPx)
    leftOuter = stripMean(
      image, x, y, tx, ty, nx, ny, halfWidth + 2.0'f32,
      config.tangentRadiusPx)
    rightInner = stripMean(
      image, x, y, tx, ty, nx, ny, -halfWidth - 1.0'f32,
      config.tangentRadiusPx)
    rightOuter = stripMean(
      image, x, y, tx, ty, nx, ny, -halfWidth - 2.0'f32,
      config.tangentRadiusPx)
    leftLuma = 0.5'f32 * (leftInner.luma + leftOuter.luma)
    rightLuma = 0.5'f32 * (rightInner.luma + rightOuter.luma)
    leftWarmth = 0.5'f32 * (leftInner.warmth + leftOuter.warmth)
    rightWarmth = 0.5'f32 * (rightInner.warmth + rightOuter.warmth)
    left = center.luma - leftLuma
    right = center.luma - rightLuma
    bilateral = min(left, right)
    asymmetry = abs(left - right)
    warmthGain = center.warmth - 0.5'f32 * (leftWarmth + rightWarmth)
    # Penalize very pale caps and salt flats unless the bilateral ribbon
    # contrast is also present.  Saturation itself is not a positive signal.
    palePenalty = max(0.0'f32, 18.0'f32 - center.saturation) * 0.12'f32
  result.leftContrast = left
  result.rightContrast = right
  result.score =
    1.35'f32 * bilateral + 0.32'f32 * warmthGain -
    0.22'f32 * asymmetry - palePenalty

proc orientedDarkEvidence(
  image: Image;
  x, y, angleRad, halfWidth: float32;
  config: RibbonConfig
): RibbonEvidence =
  ## Broad darker track on a pale field. This is deliberately separate from
  ## the normal bright/tan response so callers can require pale surroundings
  ## before accepting it; dark cliff shadows are otherwise common map art.
  let
    tx = cos(angleRad)
    ty = sin(angleRad)
    nx = -ty
    ny = tx
    center = stripMean(
      image, x, y, tx, ty, nx, ny, 0.0'f32, config.tangentRadiusPx)
    leftInner = stripMean(
      image, x, y, tx, ty, nx, ny, halfWidth + 1.0'f32,
      config.tangentRadiusPx)
    leftOuter = stripMean(
      image, x, y, tx, ty, nx, ny, halfWidth + 2.0'f32,
      config.tangentRadiusPx)
    rightInner = stripMean(
      image, x, y, tx, ty, nx, ny, -halfWidth - 1.0'f32,
      config.tangentRadiusPx)
    rightOuter = stripMean(
      image, x, y, tx, ty, nx, ny, -halfWidth - 2.0'f32,
      config.tangentRadiusPx)
    leftLuma = 0.5'f32 * (leftInner.luma + leftOuter.luma)
    rightLuma = 0.5'f32 * (rightInner.luma + rightOuter.luma)
    left = leftLuma - center.luma
    right = rightLuma - center.luma
    bilateral = min(left, right)
    asymmetry = abs(left - right)
  result.leftContrast = left
  result.rightContrast = right
  result.score = 1.35'f32 * bilateral - 0.25'f32 * asymmetry

proc ribbonEvidence*(
  image: Image;
  x, y: int;
  config = DefaultRibbonConfig
): RibbonEvidence =
  ## Best broad-ribbon response over the configured orientations and widths.
  ## A one-sided edge always scores zero, regardless of its brightness.
  if image.isNil or image.width == 0 or image.height == 0:
    return
  result.score = 0.0'f32
  for angleDeg in countup(0, 179, config.angleStepDeg):
    let angle = float32(angleDeg) * PI.float32 / 180.0'f32
    var
      angleBest: RibbonEvidence
      persistentScales = 0
      widest = 0
    for halfWidth in config.minHalfWidthPx .. config.maxHalfWidthPx:
      var evidence = orientedEvidence(
        image, float32(x), float32(y), angle, float32(halfWidth), config)
      if evidence.leftContrast < config.minSideContrast or
          evidence.rightContrast < config.minSideContrast:
        evidence.score = 0.0'f32
      if evidence.score >= config.minScore:
        inc persistentScales
        widest = halfWidth
      if evidence.score > angleBest.score:
        angleBest = evidence
    # The road is a broad band.  Requiring the bilateral response to persist
    # across widths rejects the many single-pixel decorative contour lines.
    angleBest.score += 2.5'f32 * float32(persistentScales)
    if angleBest.score > result.score:
      result = angleBest
      result.angleDeg = float32(angleDeg)
      result.halfWidthPx = float32(widest)

proc darkRibbonEvidence*(
  image: Image;
  x, y: int;
  config = DefaultRibbonConfig
): RibbonEvidence =
  ## Best broad dark-ribbon response. Consumers must constrain it to an
  ## appropriate pale surface; it is not globally road-like on its own.
  if image.isNil or image.width == 0 or image.height == 0:
    return
  var darkConfig = config
  darkConfig.minSideContrast = 1.5'f32
  darkConfig.minScore = 3.0'f32
  darkConfig.maxHalfWidthPx = max(config.maxHalfWidthPx, 8)
  for angleDeg in countup(0, 179, darkConfig.angleStepDeg):
    let angle = float32(angleDeg) * PI.float32 / 180.0'f32
    var
      angleBest: RibbonEvidence
      persistentScales = 0
      widest = 0
    for halfWidth in darkConfig.minHalfWidthPx .. darkConfig.maxHalfWidthPx:
      var evidence = orientedDarkEvidence(
        image, float32(x), float32(y), angle, float32(halfWidth), darkConfig)
      if evidence.leftContrast < darkConfig.minSideContrast or
          evidence.rightContrast < darkConfig.minSideContrast:
        evidence.score = 0.0'f32
      if evidence.score >= darkConfig.minScore:
        inc persistentScales
        widest = halfWidth
      if evidence.score > angleBest.score:
        angleBest = evidence
    angleBest.score += 1.5'f32 * float32(persistentScales)
    if angleBest.score > result.score:
      result = angleBest
      result.angleDeg = float32(angleDeg)
      result.halfWidthPx = float32(widest)

proc nonMaximumRibbon*(
  scores, angles: openArray[float32];
  width, height, x, y: int
): bool =
  ## Keep only the strongest response across the estimated road normal.
  let index = y * width + x
  if width <= 0 or height <= 0 or index < 0 or index >= scores.len or
      angles.len != scores.len or scores[index] <= 0.0'f32:
    return false
  let
    angle = angles[index] * PI.float32 / 180.0'f32
    nx = -sin(angle)
    ny = cos(angle)
    x0 = clampPixel(int(round(float32(x) + nx)), width)
    y0 = clampPixel(int(round(float32(y) + ny)), height)
    x1 = clampPixel(int(round(float32(x) - nx)), width)
    y1 = clampPixel(int(round(float32(y) - ny)), height)
  scores[index] >= scores[y0 * width + x0] and
    scores[index] >= scores[y1 * width + x1]

proc percentile*(values: openArray[float32]; fraction: float32): float32 =
  ## Deterministic percentile helper used to calibrate a zone from its own art.
  if values.len == 0:
    return 0.0'f32
  var ordered = @values
  ordered.sort()
  let f = max(0.0'f32, min(1.0'f32, fraction))
  ordered[int(round(f * float32(ordered.high)))]

proc blockGreenContrast*(image: Image; x, y: int; radius = 8): float32 =
  ## Green-channel gain over the local block median. Thousand Needles' tan
  ## road is subtle in luma but consistently greener than the surrounding red
  ## floor. Sparse sampling keeps the full-atlas scan inexpensive.
  if image.isNil or image.width == 0 or image.height == 0:
    return
  var background: seq[float32]
  for dy in countup(-radius, radius, 2):
    for dx in countup(-radius, radius, 2):
      let color = image.data[
        clampPixel(y + dy, image.height) * image.width +
        clampPixel(x + dx, image.width)]
      background.add color.g.float32
  var center = 0.0'f32
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      center += image.data[
        clampPixel(y + dy, image.height) * image.width +
        clampPixel(x + dx, image.width)].g.float32
  center /= 9.0'f32
  center - background.percentile(0.5'f32)
