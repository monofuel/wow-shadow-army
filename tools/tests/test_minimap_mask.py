#!/usr/bin/env python3
"""Unit tests for tools/minimap_mask.py.

Transform maths and parse_trs run everywhere; Pillow / live-asset tests skip
cleanly when the decoder or the flat minimap dump is not present.
"""
from __future__ import annotations

import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import bake_minimap_atlas as baker  # noqa: E402
import minimap_mask as mmask  # noqa: E402

HAVE_PILLOW = mmask.HAVE_PILLOW
skip_no_pillow = unittest.skipUnless(HAVE_PILLOW, "Pillow not installed")

ASSETS_DIR = mmask.DEFAULT_ASSETS_DIR
TRS_PATH = ASSETS_DIR / "ui_dedicated" / "minimap" / "md5translate.trs"
TILES_DIR = ASSETS_DIR / "textures" / "minimap"
HAVE_MINIMAP = TRS_PATH.is_file() and TILES_DIR.is_dir()
skip_no_minimap = unittest.skipUnless(
    HAVE_PILLOW and HAVE_MINIMAP,
    f"need Pillow and minimap assets at {ASSETS_DIR}",
)

# Great Lift lower dock. Landmark-verified; do not "fix" the axes.
LIFT_DOCK = (-4677.066, -1853.667)


class TestTransformMath(unittest.TestCase):
    """Pure coordinate maths -- no Pillow, no files."""

    def test_tile_yd_is_the_adt_constant(self) -> None:
        self.assertEqual(mmask.TILE_YD, 533.3333333333333)

    def test_great_lift_lower_dock_pins_transform(self) -> None:
        # Landmark-verified against terrain elevation and the Great Lift.
        # Do not "fix" the axes.
        (a, b), (px, py) = mmask.tile_pixel(*LIFT_DOCK)
        self.assertEqual((a, b), (35, 40))
        self.assertAlmostEqual(px, 121, delta=1)
        self.assertAlmostEqual(py, 196, delta=1)

    def test_tile_36_41_formula_point(self) -> None:
        (a, b), (px, py) = mmask.tile_pixel(-5000.0, -2400.0)
        self.assertEqual((a, b), (36, 41))
        self.assertEqual((px, py), (128, 96))


class TestParseTrs(unittest.TestCase):
    """Synthetic trs -- no Pillow, no real assets."""

    def test_parse_trs_ignores_dir_and_non_map_lines(self) -> None:
        body = (
            "dir: Kalimdor\r\n"
            "Kalimdor\\map35_40.blp\tabcdef012345.blp\r\n"
            "Kalimdor\\not_a_map.blp\tignoreme.blp\r\n"
            "Azeroth\\map12_13.blp\txyz987.blp\r\n"
            "some junk without a tab\r\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "md5translate.trs"
            path.write_text(body, encoding="ascii")
            index = mmask.parse_trs(path)
        self.assertEqual(
            index,
            {
                ("kalimdor", 35, 40): "abcdef012345.blp",
                ("azeroth", 12, 13): "xyz987.blp",
            },
        )


@skip_no_pillow
class TestSyntheticLuminance(unittest.TestCase):
    """Known PNG pattern -- pixel addressing + ITU-R 601, no BLP files."""

    def _sampler(self, tmp: Path, img) -> mmask.MinimapSampler:
        tiles = tmp / "tiles"
        tiles.mkdir()
        name = "synthetic.png"
        img.save(tiles / name)
        trs = tmp / "md5translate.trs"
        trs.write_text("Kalimdor\\map36_41.blp\t" + name + "\n", encoding="ascii")
        return mmask.MinimapSampler(tmp, "kalimdor", trs_path=trs, tiles_dir=tiles)

    def test_luminance_at_painted_pixels(self) -> None:
        from PIL import Image

        img = Image.new("RGB", (256, 256), (0, 0, 0))
        img.putpixel((0, 0), (255, 0, 0))
        img.putpixel((128, 96), (100, 150, 200))
        img.putpixel((255, 255), (0, 0, 255))
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            sampler = self._sampler(tmp, img)
            # (-4800, -4*TILE_YD) -> tile (36, 41), pixel (0, 0)
            self.assertEqual(
                sampler.luminance(-4800.0, -4.0 * mmask.TILE_YD),
                (299 * 255 + 587 * 0 + 114 * 0) // 1000,
            )
            # formula point -> (128, 96)
            self.assertEqual(
                sampler.luminance(-5000.0, -2400.0),
                (299 * 100 + 587 * 150 + 114 * 200) // 1000,
            )
            # far corner of the same tile -> (255, 255)
            self.assertEqual(
                sampler.luminance(-5333.0, -2666.0),
                (299 * 0 + 587 * 0 + 114 * 255) // 1000,
            )

    def test_rgb_returns_planted_pixel(self) -> None:
        from PIL import Image

        img = Image.new("RGB", (256, 256), (0, 0, 0))
        img.putpixel((0, 0), (255, 0, 0))
        img.putpixel((128, 96), (100, 150, 200))
        img.putpixel((255, 255), (0, 0, 255))
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            sampler = self._sampler(tmp, img)
            self.assertEqual(sampler.rgb(-4800.0, -4.0 * mmask.TILE_YD), (255, 0, 0))
            self.assertEqual(sampler.rgb(-5000.0, -2400.0), (100, 150, 200))
            self.assertEqual(sampler.rgb(-5333.0, -2666.0), (0, 0, 255))

    def test_missing_tile_returns_none(self) -> None:
        from PIL import Image

        img = Image.new("RGB", (256, 256), (10, 10, 10))
        with tempfile.TemporaryDirectory() as raw:
            sampler = self._sampler(Path(raw), img)
            self.assertIsNone(sampler.luminance(0.0, 0.0))
            self.assertIsNone(sampler.luminance(1.0e6, 1.0e6))
            self.assertIsNone(sampler.rgb(0.0, 0.0))
            self.assertIsNone(sampler.rgb(1.0e6, 1.0e6))


@skip_no_pillow
class TestPillowRequired(unittest.TestCase):
    def test_wrong_tile_size_raises(self) -> None:
        from PIL import Image

        img = Image.new("RGB", (128, 128), (0, 0, 0))
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            tiles = tmp / "tiles"
            tiles.mkdir()
            img.save(tiles / "small.png")
            trs = tmp / "md5translate.trs"
            trs.write_text("Kalimdor\\map36_41.blp\tsmall.png\n", encoding="ascii")
            sampler = mmask.MinimapSampler(
                tmp, "kalimdor", trs_path=trs, tiles_dir=tiles
            )
            with self.assertRaises(RuntimeError):
                sampler.luminance(-5000.0, -2400.0)


@skip_no_minimap
class TestRealMinimap(unittest.TestCase):
    """Live Kalimdor tiles -- skipped without Pillow + assets."""

    def test_lift_dock_and_canyon_pixels_resolve(self) -> None:
        sampler = mmask.MinimapSampler(ASSETS_DIR, "kalimdor")
        dock = sampler.luminance(*LIFT_DOCK)
        self.assertIsInstance(dock, int)
        self.assertGreaterEqual(dock, 0)
        self.assertLessEqual(dock, 255)
        floor_luma = sampler.luminance(-4900.0, -2000.0)
        mesa_luma = sampler.luminance(-5128.0, -1954.0)
        self.assertIsInstance(floor_luma, int)
        self.assertIsInstance(mesa_luma, int)
        self.assertNotEqual(floor_luma, mesa_luma)
        dock_rgb = sampler.rgb(*LIFT_DOCK)
        self.assertIsInstance(dock_rgb, tuple)
        self.assertEqual(len(dock_rgb), 3)
        self.assertTrue(all(isinstance(c, int) for c in dock_rgb))


ATLAS_JSON_KEYS = {
    "a_max",
    "a_min",
    "b_max",
    "b_min",
    "height",
    "map",
    "map_id",
    "px_per_tile",
    "tile_yd",
    "width",
}


@skip_no_pillow
class TestMinimapAtlasBake(unittest.TestCase):
    """Synthetic 3-tile trs + 2 PNGs. Placement, schema, determinism."""

    PX = 32

    def _layout(self, tmp: Path):
        from PIL import Image

        tiles = tmp / "tiles"
        tiles.mkdir()
        Image.new("RGBA", (256, 256), (255, 0, 0, 255)).save(tiles / "t0.png")
        Image.new("RGBA", (256, 256), (0, 255, 0, 255)).save(tiles / "t1.png")
        trs = tmp / "md5translate.trs"
        trs.write_text(
            "Kalimdor\\map10_20.blp\tt0.png\n"
            "Kalimdor\\map10_21.blp\tt1.png\n"
            "Kalimdor\\map11_20.blp\tmissing.png\n"
            "Azeroth\\map1_2.blp\tother.png\n",
            encoding="ascii",
        )
        return trs, tiles

    def test_placement_extents_and_schema(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            trs, tiles = self._layout(tmp)
            out = tmp / "out"
            meta = baker.bake_atlas(
                "kalimdor",
                assets_dir=tmp,
                px_per_tile=self.PX,
                out_dir=out,
                trs_path=trs,
                tiles_dir=tiles,
            )
            self.assertEqual(meta["a_min"], 10)
            self.assertEqual(meta["a_max"], 11)
            self.assertEqual(meta["b_min"], 20)
            self.assertEqual(meta["b_max"], 21)
            self.assertEqual(meta["width"], 2 * self.PX)
            self.assertEqual(meta["height"], 2 * self.PX)
            self.assertEqual(meta["map"], "kalimdor")
            self.assertEqual(meta["map_id"], 1)
            self.assertEqual(meta["px_per_tile"], self.PX)
            self.assertEqual(meta["tile_yd"], mmask.TILE_YD)

            png_path = out / "minimap_atlas_kalimdor.png"
            json_path = out / "minimap_atlas_kalimdor.json"
            atlas = Image.open(png_path).convert("RGBA")
            self.assertEqual(atlas.size, (2 * self.PX, 2 * self.PX))
            # (a_min, b_min) band origin is atlas (0, 0).
            self.assertEqual(atlas.getpixel((0, 0)), (255, 0, 0, 255))
            # Old pins encoded the transposed layout that shipped garbled:
            # (a_min, b_min+1) at x-offset, (a_min+1, b_min) at y-offset.
            # Corrected arrangement: A horizontal, B vertical.
            self.assertEqual(atlas.getpixel((0, self.PX)), (0, 255, 0, 255))
            self.assertEqual(atlas.getpixel((self.PX, 0))[3], 0)

            raw_json = json_path.read_text(encoding="utf-8")
            data = json.loads(raw_json)
            self.assertEqual(set(data.keys()), ATLAS_JSON_KEYS)
            self.assertEqual(data, meta)
            self.assertEqual(
                raw_json, json.dumps(data, indent=2, sort_keys=True) + "\n"
            )

    def test_determinism(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            trs, tiles = self._layout(tmp)
            out_a = tmp / "a"
            out_b = tmp / "b"
            baker.bake_atlas(
                "kalimdor",
                assets_dir=tmp,
                px_per_tile=self.PX,
                out_dir=out_a,
                trs_path=trs,
                tiles_dir=tiles,
            )
            baker.bake_atlas(
                "kalimdor",
                assets_dir=tmp,
                px_per_tile=self.PX,
                out_dir=out_b,
                trs_path=trs,
                tiles_dir=tiles,
            )
            a_bytes = (out_a / "minimap_atlas_kalimdor.png").read_bytes()
            b_bytes = (out_b / "minimap_atlas_kalimdor.png").read_bytes()
            self.assertEqual(a_bytes, b_bytes)
            self.assertEqual(
                (out_a / "minimap_atlas_kalimdor.json").read_text(encoding="utf-8"),
                (out_b / "minimap_atlas_kalimdor.json").read_text(encoding="utf-8"),
            )


ATLAS_DIR = ROOT / "local_data" / "map_browser"
KALIMDOR_ATLAS_PNG = ATLAS_DIR / "minimap_atlas_kalimdor.png"
KALIMDOR_ATLAS_JSON = ATLAS_DIR / "minimap_atlas_kalimdor.json"
HAVE_KALIMDOR_ATLAS = (
    HAVE_PILLOW and KALIMDOR_ATLAS_PNG.is_file() and KALIMDOR_ATLAS_JSON.is_file()
)
skip_no_kalimdor_atlas = unittest.skipUnless(
    HAVE_KALIMDOR_ATLAS,
    "need Pillow and baked kalimdor atlas at local_data/map_browser/",
)

WORLD_TILE_ORIGIN = 32.0
SEAM_PAIR_N = 20
SEAM_RNG_SEED = 20260812

LANDMARKS = {
    "kalimdor": (
        (-4677.066, -1853.667),  # Great Lift dock
        (-5128.0, -1954.0),  # Freewind mesa
        (-4280.0, -776.0),  # Feralas junction
        (-6230.0, -3700.0),  # racetrack
        (-1000.0, -500.0),
        (2000.0, 1000.0),
    ),
    "azeroth": (
        (-8900.0, -100.0),  # Elwynn-ish
        (1800.0, 240.0),  # Tirisfal-ish
        (-14200.0, 300.0),
    ),
}


def _load_atlas_meta(map_name: str):
    json_path = ATLAS_DIR / f"minimap_atlas_{map_name}.json"
    png_path = ATLAS_DIR / f"minimap_atlas_{map_name}.png"
    if not json_path.is_file() or not png_path.is_file():
        return None
    meta = json.loads(json_path.read_text(encoding="utf-8"))
    from PIL import Image

    image = Image.open(png_path).convert("RGBA")
    return image, meta


def _trs_tiles(map_name: str) -> set[tuple[int, int]]:
    index = mmask.parse_trs(TRS_PATH)
    return {(a, b) for (mp, a, b) in index if mp == map_name}


def _band_origin(a: int, b: int, meta: dict) -> tuple[int, int]:
    px = meta["px_per_tile"]
    return ((a - meta["a_min"]) * px, (b - meta["b_min"]) * px)


def _column(image, x: int, y0: int, length: int):
    width, height = image.size
    if x < 0 or x >= width or y0 < 0 or y0 + length > height:
        return None
    return [image.getpixel((x, y0 + i))[:3] for i in range(length)]


def _row(image, y: int, x0: int, length: int):
    width, height = image.size
    if y < 0 or y >= height or x0 < 0 or x0 + length > width:
        return None
    return [image.getpixel((x0 + i, y))[:3] for i in range(length)]


def _is_flat(strip) -> bool:
    return strip is None or len(set(strip)) <= 1


def _mean_abs_rgb(left, right) -> float:
    acc = 0.0
    n = len(left)
    for p, q in zip(left, right):
        acc += abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])
    return acc / (n * 3.0)


def _edge_adjacent(t1: tuple[int, int], t2: tuple[int, int]) -> bool:
    (a1, b1), (a2, b2) = t1, t2
    return (a1 == a2 and abs(b1 - b2) == 1) or (b1 == b2 and abs(a1 - a2) == 1)


def _horiz_strips(image, a: int, b: int, meta: dict):
    px = meta["px_per_tile"]
    ox, oy = _band_origin(a, b, meta)
    left = _column(image, ox + px - 1, oy, px)
    right = _column(image, ox + px, oy, px)
    return left, right


def _vert_strips(image, a: int, b: int, meta: dict):
    px = meta["px_per_tile"]
    ox, oy = _band_origin(a, b, meta)
    bottom = _row(image, oy + px - 1, ox, px)
    top = _row(image, oy + px, ox, px)
    return bottom, top


def _atlas_uv_pixel(meta: dict, x: float, y: float) -> tuple[int, int]:
    t = float(meta["tile_yd"])
    a_count = meta["a_max"] - meta["a_min"] + 1
    b_count = meta["b_max"] - meta["b_min"] + 1
    u_origin = (WORLD_TILE_ORIGIN - meta["a_min"]) * t
    u_scale = 1.0 / (a_count * t)
    v_origin = (WORLD_TILE_ORIGIN - meta["b_min"]) * t
    v_scale = 1.0 / (b_count * t)
    u = (u_origin - y) * u_scale
    v = (v_origin - x) * v_scale
    px = int(u * meta["width"])
    py = int(v * meta["height"])
    return px, py


def _downscaled_tile_rgb_at(
    md5_name: str, px_per_tile: int, local_x: int, local_y: int
):
    from PIL import Image

    path = TILES_DIR / md5_name
    if not path.is_file():
        return None
    with Image.open(path) as src:
        tile = src.convert("RGBA")
        if px_per_tile != mmask.TILE_PX:
            tile = tile.resize((px_per_tile, px_per_tile), Image.LANCZOS)
        pix = tile.getpixel((local_x, local_y))
    return pix[:3]


@skip_no_kalimdor_atlas
class TestAtlasSeamContinuity(unittest.TestCase):
    """World-adjacent tile seams must beat random non-adjacent pairs.

    Fails on the transposed atlas that shipped garbled: that layout puts
    A-neighbors on the vertical axis, so the fixed-arrangement border
    strips are unrelated pixels.
    """

    def test_horizontal_and_vertical_seams_beat_random(self) -> None:
        if not HAVE_MINIMAP:
            self.skipTest(f"need minimap assets at {ASSETS_DIR}")
        loaded = _load_atlas_meta("kalimdor")
        self.assertIsNotNone(loaded)
        image, meta = loaded
        present = _trs_tiles("kalimdor")
        self._assert_direction(image, meta, present, horizontal=True)
        self._assert_direction(image, meta, present, horizontal=False)

    def _assert_direction(
        self, image, meta: dict, present: set, horizontal: bool
    ) -> None:
        adjacent = self._adjacent_pairs(image, meta, present, horizontal)
        random_pairs = self._random_pairs(image, meta, present, horizontal)
        self.assertGreaterEqual(
            len(adjacent),
            SEAM_PAIR_N,
            "not enough non-uniform adjacent pairs",
        )
        self.assertGreaterEqual(
            len(random_pairs),
            SEAM_PAIR_N,
            "not enough non-uniform random pairs",
        )
        adjacent_mean = sum(adjacent) / len(adjacent)
        random_mean = sum(random_pairs) / len(random_pairs)
        self.assertLess(adjacent_mean, 0.5 * random_mean)

    def _adjacent_pairs(
        self, image, meta: dict, present: set, horizontal: bool
    ) -> list[float]:
        mads: list[float] = []
        for a, b in sorted(present):
            neighbor = (a + 1, b) if horizontal else (a, b + 1)
            if neighbor not in present:
                continue
            left, right = (
                _horiz_strips(image, a, b, meta)
                if horizontal
                else _vert_strips(image, a, b, meta)
            )
            if _is_flat(left) or _is_flat(right):
                continue
            mads.append(_mean_abs_rgb(left, right))
            if len(mads) >= SEAM_PAIR_N:
                break
        return mads

    def _random_pairs(
        self, image, meta: dict, present: set, horizontal: bool
    ) -> list[float]:
        tiles = sorted(present)
        rng = random.Random(SEAM_RNG_SEED)
        mads: list[float] = []
        seen: set[tuple] = set()
        for _ in range(20000):
            if len(mads) >= SEAM_PAIR_N:
                break
            t1, t2 = rng.sample(tiles, 2)
            key = tuple(sorted((t1, t2)))
            if key in seen or _edge_adjacent(t1, t2):
                continue
            seen.add(key)
            a, b = t1
            na, nb = t2
            if horizontal:
                px = meta["px_per_tile"]
                ox, oy = _band_origin(a, b, meta)
                nox, noy = _band_origin(na, nb, meta)
                left = _column(image, ox + px - 1, oy, px)
                right = _column(image, nox, noy, px)
            else:
                px = meta["px_per_tile"]
                ox, oy = _band_origin(a, b, meta)
                nox, noy = _band_origin(na, nb, meta)
                left = _row(image, oy + px - 1, ox, px)
                right = _row(image, noy, nox, px)
            if _is_flat(left) or _is_flat(right):
                continue
            mads.append(_mean_abs_rgb(left, right))
        return mads


@skip_no_kalimdor_atlas
class TestAtlasLandmarkAgreement(unittest.TestCase):
    """Atlas UV sample equals the Lanczos-downscaled source tile pixel."""

    def test_landmarks_match_downscaled_tiles(self) -> None:
        if not HAVE_MINIMAP:
            self.skipTest(f"need minimap assets at {ASSETS_DIR}")
        index = mmask.parse_trs(TRS_PATH)
        checked = 0
        for map_name, points in LANDMARKS.items():
            loaded = _load_atlas_meta(map_name)
            if loaded is None:
                continue
            image, meta = loaded
            width, height = image.size
            px_per_tile = meta["px_per_tile"]
            for x, y in points:
                (a, b), _ = mmask.tile_pixel(x, y)
                md5_name = index.get((map_name, a, b))
                if md5_name is None:
                    continue
                ax, ay = _atlas_uv_pixel(meta, x, y)
                if ax < 0 or ay < 0 or ax >= width or ay >= height:
                    continue
                ox, oy = _band_origin(a, b, meta)
                self.assertTrue(
                    ox <= ax < ox + px_per_tile and oy <= ay < oy + px_per_tile,
                    f"{map_name} ({x}, {y}) UV atlas({ax}, {ay}) "
                    f"missed tile ({a}, {b}) origin ({ox}, {oy})",
                )
                expected = _downscaled_tile_rgb_at(
                    md5_name, px_per_tile, ax - ox, ay - oy
                )
                if expected is None:
                    continue
                actual = image.getpixel((ax, ay))[:3]
                self.assertEqual(
                    actual,
                    expected,
                    f"{map_name} ({x}, {y}) tile ({a}, {b}) "
                    f"atlas({ax}, {ay}) != downscaled",
                )
                checked += 1
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()

