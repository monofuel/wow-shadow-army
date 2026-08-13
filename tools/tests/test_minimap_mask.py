#!/usr/bin/env python3
"""Unit tests for tools/minimap_mask.py.

Transform maths and parse_trs run everywhere; Pillow / live-asset tests skip
cleanly when the decoder or the flat minimap dump is not present.
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
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


if __name__ == "__main__":
    unittest.main()
