import
  std/[math, unittest],
  pixie,
  map_browser/road_ribbon

proc syntheticRibbon(width = 96; height = 72): Image =
  result = newImage(width, height)
  result.fill(rgbx(112, 57, 32, 255))
  for x in 4 ..< width - 4:
    let center = height div 2 + int(round(7.0 * sin(float(x) / 15.0)))
    for y in center - 3 .. center + 3:
      result.data[y * width + x] = rgbx(188, 131, 72, 255)

suite "visual road ribbon detector":
  test "finds a curved bilateral tan ribbon":
    let image = syntheticRibbon()
    for x in countup(12, 80, 8):
      let y = image.height div 2 + int(round(7.0 * sin(float(x) / 15.0)))
      check ribbonEvidence(image, x, y).score >= DefaultRibbonConfig.minScore

  test "rejects a one-sided bright cliff edge":
    let image = newImage(96, 72)
    image.fill(rgbx(112, 57, 32, 255))
    for y in 0 ..< image.height:
      for x in image.width div 2 ..< image.width:
        image.data[y * image.width + x] = rgbx(205, 158, 99, 255)
    check ribbonEvidence(image, image.width div 2, image.height div 2).score == 0

  test "rejects a uniform pale salt field":
    let image = newImage(64, 64)
    image.fill(rgbx(210, 201, 174, 255))
    check ribbonEvidence(image, 32, 32).score == 0

  test "nonmaximum suppression keeps ribbon center":
    let
      width = 5
      height = 5
      scores = @[
        0'f32, 0, 0, 0, 0,
        0, 0, 2, 0, 0,
        0, 0, 7, 0, 0,
        0, 0, 3, 0, 0,
        0, 0, 0, 0, 0
      ]
      angles = newSeq[float32](scores.len) # tangent horizontal, normal vertical
    check nonMaximumRibbon(scores, angles, width, height, 2, 2)
    check not nonMaximumRibbon(scores, angles, width, height, 2, 1)

  test "percentile is deterministic":
    check percentile([1'f32, 8, 3, 5, 2], 0.5) == 3
