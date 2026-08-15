## Minimap atlas UV math and JSON load for the map-browser terrain drape.
import
  std/[options, os, unittest],
  pixie,
  map_browser/atlas

const
  TileYd = 533.3333333333333'f32
  # Great Lift lower dock. Landmark-verified; do not "fix" the axes.
  LiftX = -4677.066'f32
  LiftY = -1853.667'f32

suite "atlas UV params":
  test "great lift lower dock sits inside the synthetic kalimdor window":
    let atlas = MinimapAtlas(
      mapId: 1'u32,
      pxPerTile: 256,
      aMin: 33,
      aMax: 40,
      bMin: 39,
      bMax: 44,
      width: 8 * 256,
      height: 6 * 256,
      tileYd: TileYd
    )
    let p = atlasUvParams(atlas)
    let
      u = (p.uOrigin - LiftY) * p.uScale
      v = (p.vOrigin - LiftX) * p.vScale
      aCount = float32(40 - 33 + 1)
      bCount = float32(44 - 39 + 1)
      expU = ((32.0'f32 - 33.0'f32) * TileYd - LiftY) / (aCount * TileYd)
      expV = ((32.0'f32 - 39.0'f32) * TileYd - LiftX) / (bCount * TileYd)
    check u > 0.0'f32 and u < 1.0'f32
    check v > 0.0'f32 and v < 1.0'f32
    check abs(u - expU) < 1e-5'f32
    check abs(v - expV) < 1e-5'f32

suite "atlas JSON load":
  test "bad JSON is none":
    check parseAtlasJson("{not json").isNone
    check parseAtlasJson("[]").isNone
    check parseAtlasJson("{}").isNone

  test "missing file is none":
    let tmp = getTempDir() / "wow_atlas_missing_" & $getCurrentProcessId()
    createDir(tmp)
    let prev = getEnv(AtlasDirEnv)
    putEnv(AtlasDirEnv, tmp)
    check loadAtlas(1'u32).isNone
    if prev.len > 0:
      putEnv(AtlasDirEnv, prev)
    else:
      delEnv(AtlasDirEnv)
    removeDir(tmp)

  test "valid JSON plus 1x1 PNG loads":
    let tmp = getTempDir() / "wow_atlas_ok_" & $getCurrentProcessId()
    createDir(tmp)
    let img = newImage(1, 1)
    img.fill(rgbx(255, 0, 0, 255))
    img.writeFile(tmp / "minimap_atlas_kalimdor.png")
    writeFile(
      tmp / "minimap_atlas_kalimdor.json",
      """{"map":"kalimdor","map_id":1,"px_per_tile":1,"a_min":33,"a_max":33,""" &
      """"b_min":39,"b_max":39,"width":1,"height":1,"tile_yd":533.3333333333333}"""
    )
    let prev = getEnv(AtlasDirEnv)
    putEnv(AtlasDirEnv, tmp)
    let loaded = loadAtlas(1'u32)
    check loaded.isSome
    let atlas = loaded.get()
    check atlas.width == 1
    check atlas.height == 1
    check atlas.mapId == 1'u32
    check atlas.image != nil
    check atlas.image.width == 1
    if prev.len > 0:
      putEnv(AtlasDirEnv, prev)
    else:
      delEnv(AtlasDirEnv)
    removeDir(tmp)

  test "size mismatch is none":
    let tmp = getTempDir() / "wow_atlas_mismatch_" & $getCurrentProcessId()
    createDir(tmp)
    let img = newImage(1, 1)
    img.fill(rgbx(0, 255, 0, 255))
    img.writeFile(tmp / "minimap_atlas_azeroth.png")
    writeFile(
      tmp / "minimap_atlas_azeroth.json",
      """{"map":"azeroth","map_id":0,"px_per_tile":8,"a_min":1,"a_max":2,""" &
      """"b_min":3,"b_max":4,"width":16,"height":16,"tile_yd":533.3333333333333}"""
    )
    let prev = getEnv(AtlasDirEnv)
    putEnv(AtlasDirEnv, tmp)
    check loadAtlas(0'u32).isNone
    if prev.len > 0:
      putEnv(AtlasDirEnv, prev)
    else:
      delEnv(AtlasDirEnv)
    removeDir(tmp)
