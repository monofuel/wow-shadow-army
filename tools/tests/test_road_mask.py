#!/usr/bin/env python3
"""Unit tests for tools/road_mask.py.

Transform maths run everywhere; the anchor tests skip cleanly when the flat
Kalimdor ADT dump is not present.
"""
from __future__ import annotations

import json
import math
import random
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import bake_road_waypoints as bake  # noqa: E402
import road_mask as rmask  # noqa: E402

ADT_DIR = rmask.DEFAULT_ADT_DIR
HAVE_ADT = ADT_DIR.is_dir() and any(ADT_DIR.glob("kalimdor_*.adt"))
skip_no_adt = unittest.skipUnless(HAVE_ADT, f"no Kalimdor ADTs at {ADT_DIR}")
AZEROTH_DIR = rmask.DEFAULT_ADT_DIR.parent / "azeroth"
HAVE_AZEROTH = AZEROTH_DIR.is_dir() and any(AZEROTH_DIR.glob("azeroth_*.adt"))
skip_no_azeroth = unittest.skipUnless(
    HAVE_AZEROTH, f"no Azeroth ADTs at {AZEROTH_DIR}"
)


class TestTransformMath(unittest.TestCase):
    """Pure coordinate maths -- no ADT files touched."""

    def test_tile_indices_of_calibration_anchors(self) -> None:
        cases = {
            (1191.7, -2261.3): (36, 29),  # Ashenvale
            (5792.0, -1204.8): (34, 21),  # Felwood north
            (6502.9, -2063.7): (35, 19),  # Timbermaw
            (6069.0, -1305.0): (34, 20),  # Felwood forest
            (-6711.4, -4868.5): (41, 44),  # ocean / beach
        }
        for (x, y), expected in cases.items():
            self.assertEqual(rmask.tile_indices(x, y), expected, msg=f"{x},{y}")

    def test_tile_index_first_comes_from_y_second_from_x(self) -> None:
        """The axis swap: a tracks world Y, b tracks world X."""
        a0, b0 = rmask.tile_indices(0.0, 0.0)
        a_dx, b_dx = rmask.tile_indices(rmask.TILE_YD, 0.0)
        a_dy, b_dy = rmask.tile_indices(0.0, rmask.TILE_YD)
        self.assertEqual(a_dx, a0)
        self.assertEqual(b_dx, b0 - 1)
        self.assertEqual(a_dy, a0 - 1)
        self.assertEqual(b_dy, b0)

    def test_tile_origin_is_max_corner(self) -> None:
        for x, y in [(1191.7, -2261.3), (5792.0, -1204.8), (-6711.4, -4868.5)]:
            a, b = rmask.tile_indices(x, y)
            max_x, max_y = rmask.tile_origin(a, b)
            self.assertGreaterEqual(max_x, x)
            self.assertGreaterEqual(max_y, y)
            self.assertLess(max_x - x, rmask.TILE_YD)
            self.assertLess(max_y - y, rmask.TILE_YD)

    def test_chunk_origin_brackets_the_point(self) -> None:
        for x, y in [
            (1191.7, -2261.3),
            (5792.0, -1204.8),
            (6502.9, -2063.7),
            (-6711.4, -4868.5),
            (0.5, 0.5),
        ]:
            a, b = rmask.tile_indices(x, y)
            ix, iy = rmask.chunk_indices(x, y)
            ox, oy = rmask.chunk_origin(a, b, ix, iy)
            self.assertGreaterEqual(ox, x)
            self.assertLess(ox - rmask.CHUNK_YD, x)
            self.assertGreaterEqual(oy, y)
            self.assertLess(oy - rmask.CHUNK_YD, y)

    def test_chunk_indices_known_values(self) -> None:
        self.assertEqual(rmask.chunk_indices(1191.7, -2261.3), (3, 12))
        self.assertEqual(rmask.chunk_indices(5792.0, -1204.8), (4, 2))
        self.assertEqual(rmask.chunk_indices(6502.9, -2063.7), (13, 12))

    def test_chunk_array_index_is_iy_major(self) -> None:
        self.assertEqual(rmask.chunk_array_index(0, 0), 0)
        self.assertEqual(rmask.chunk_array_index(1, 0), 1)
        self.assertEqual(rmask.chunk_array_index(0, 1), 16)
        self.assertEqual(rmask.chunk_array_index(3, 12), 195)
        self.assertEqual(rmask.chunk_array_index(13, 12), 205)

    def test_chunk_indices_are_clamped_in_range(self) -> None:
        for x, y in [(1200.0, -2233.3334), (1.0e-6, -1.0e-6), (-17000.0, 17000.0)]:
            ix, iy = rmask.chunk_indices(x, y)
            self.assertTrue(0 <= ix < 16, msg=f"{x},{y} ix={ix}")
            self.assertTrue(0 <= iy < 16, msg=f"{x},{y} iy={iy}")

    def test_cell_indices_count_down_both_axes(self) -> None:
        # A chunk's max corner is cell (0,0); moving to smaller x/y raises the
        # index. Use a chunk-interior base point so nothing crosses a boundary.
        base_x, base_y = 1190.0, -2260.0
        cx0, cy0 = rmask.cell_indices(base_x, base_y)
        cx1, _ = rmask.cell_indices(base_x - 5.0, base_y)
        _, cy1 = rmask.cell_indices(base_x, base_y - 5.0)
        self.assertGreater(cx1, cx0)
        self.assertGreater(cy1, cy0)

    def test_cell_indices_at_chunk_max_corner_are_zero(self) -> None:
        a, b = rmask.tile_indices(1191.7, -2261.3)
        ix, iy = rmask.chunk_indices(1191.7, -2261.3)
        ox, oy = rmask.chunk_origin(a, b, ix, iy)
        self.assertEqual(rmask.cell_indices(ox - 1e-6, oy - 1e-6), (0, 0))

    def test_cell_indices_stay_in_range(self) -> None:
        for i in range(64):
            x = 1200.0 - i * (rmask.CHUNK_YD / 64.0) - 1e-6
            cx, cy = rmask.cell_indices(x, -2261.3)
            self.assertTrue(0 <= cx < 64)
            self.assertTrue(0 <= cy < 64)

    def test_alpha_index_is_x_major(self) -> None:
        self.assertEqual(rmask.alpha_index(0, 0), 0)
        self.assertEqual(rmask.alpha_index(0, 1), 1)
        self.assertEqual(rmask.alpha_index(1, 0), 64)
        self.assertEqual(rmask.alpha_index(63, 63), 4095)

    def test_anchor_cells_match_calibration(self) -> None:
        self.assertEqual(rmask.cell_indices(1191.7, -2261.3), (15, 53))
        self.assertEqual(rmask.cell_indices(5792.0, -1204.8), (15, 9))
        self.assertEqual(rmask.cell_indices(6502.9, -2063.7), (58, 58))

    def test_is_road_texture(self) -> None:
        self.assertTrue(rmask.is_road_texture("Tileset\\Felwood\\FelwoodRoad.blp"))
        self.assertTrue(rmask.is_road_texture("tileset/ashenvale/ashenvaleroad.blp"))
        self.assertTrue(rmask.is_road_texture("Tileset\\Barrens\\BarrensRoad01.blp"))
        self.assertTrue(rmask.is_road_texture("KalidarRoad.blp"))
        self.assertTrue(
            rmask.is_road_texture("Tileset\\Elwynn\\ElwynnCobbleStoneBase.blp")
        )
        self.assertTrue(
            rmask.is_road_texture("Tileset\\Duskwood\\DuskwoodCobblestone.blp")
        )
        self.assertTrue(
            rmask.is_road_texture("Tileset\\Tanaris\\TanarisDirtFootprint.blp")
        )
        # overlay-only: still a road marker; Probe.sample ignores it as base.
        self.assertTrue(
            rmask.is_road_texture(
                "Tileset\\ThousandNeedles\\ThousandNeedlesRockHighlight02.blp"
            )
        )
        self.assertTrue(
            rmask.is_overlay_only_texture(
                "Tileset\\ThousandNeedles\\ThousandNeedlesRockHighlight02.blp"
            )
        )
        # substring specificity: Highlight (no 02) must not match Highlight02.
        self.assertFalse(
            rmask.is_road_texture(
                "Tileset\\ThousandNeedles\\ThousandNeedlesRockHighlight.blp"
            )
        )
        # thousandneedlesdirt was tried (base=canyon floor, overlay=cliffs)
        # and removed. Do not flip this back.
        self.assertFalse(
            rmask.is_road_texture(
                "Tileset\\ThousandNeedles\\ThousandNeedlesDirt.blp"
            )
        )
        self.assertFalse(
            rmask.is_overlay_only_texture(
                "Tileset\\ThousandNeedles\\ThousandNeedlesDirt.blp"
            )
        )
        self.assertFalse(rmask.is_road_texture("Tileset\\Felwood\\FelwoodDirt.blp"))
        self.assertFalse(rmask.is_road_texture("Tileset\\Generic\\Black.blp"))
        self.assertFalse(
            rmask.is_road_texture("Tileset\\Duskwood\\DuskwoodGrassBase.blp")
        )
        self.assertTrue(
            rmask.is_overlay_only_texture(
                "Tileset\\Tanaris\\TanarisDirtFootprint.blp"
            )
        )
        self.assertFalse(rmask.is_overlay_only_texture("KalidarRoad.blp"))
        self.assertFalse(
            rmask.is_overlay_only_texture(
                "Tileset\\Elwynn\\ElwynnCobbleStoneBase.blp"
            )
        )
        self.assertFalse(
            rmask.is_overlay_only_texture("Tileset\\Felwood\\FelwoodDirt.blp")
        )
        for marker in rmask.OVERLAY_ONLY_MARKERS:
            self.assertTrue(rmask.is_road_texture(marker))

    def test_tile_path_infers_map_name_from_dir(self) -> None:
        mask = rmask.RoadMask(Path("/nonexistent/azeroth"), map_name=None)
        self.assertTrue(str(mask.tile_path(28, 28)).endswith("azeroth_28_28.adt"))

    def test_explicit_map_name_overrides_dir(self) -> None:
        mask = rmask.RoadMask(Path("/nonexistent/wrong"), map_name="azeroth")
        self.assertTrue(str(mask.tile_path(28, 28)).endswith("azeroth_28_28.adt"))


class TestMclqTileFlags(unittest.TestCase):
    """Pure unit tests of MCLQ 8x8 tile-flag decoding -- no ADT files."""

    def test_low_nibble_0f_is_dry(self) -> None:
        self.assertFalse(rmask.mclq_tile_has_liquid(0x0F))
        self.assertFalse(rmask.mclq_tile_has_liquid(0x4F))  # fatigue bit + no-liquid

    def test_ocean_paint_0x41_is_wet(self) -> None:
        self.assertTrue(rmask.mclq_tile_has_liquid(0x41))
        self.assertTrue(rmask.mclq_tile_has_liquid(0x01))
        self.assertTrue(rmask.mclq_tile_has_liquid(0x40))  # low nibble 0, not 0xF

    def test_synthetic_grid_x_major_index(self) -> None:
        # 8x8 grid: dry everywhere except (lx=3, ly=5) = 0x41.
        tiles = bytearray([0x0F] * 64)
        tiles[rmask.liquid_tile_index(3, 5)] = 0x41
        self.assertEqual(rmask.liquid_tile_index(0, 0), 0)
        self.assertEqual(rmask.liquid_tile_index(1, 0), 8)
        self.assertEqual(rmask.liquid_tile_index(3, 5), 3 * 8 + 5)
        self.assertTrue(rmask.mclq_tile_has_liquid(tiles[3 * 8 + 5]))
        self.assertFalse(rmask.mclq_tile_has_liquid(tiles[0]))
        self.assertFalse(rmask.mclq_tile_has_liquid(tiles[5 * 8 + 3]))  # swapped axes dry

    def test_liquid_cell_helpers_match_alpha_axes(self) -> None:
        # Chunk max corner -> cell (0,0); step down x/y raises indices.
        base_x, base_y = 1190.0, -2260.0
        lx0, ly0 = rmask.liquid_cell_indices(base_x, base_y)
        lx1, _ = rmask.liquid_cell_indices(base_x - 5.0, base_y)
        _, ly1 = rmask.liquid_cell_indices(base_x, base_y - 5.0)
        self.assertGreater(lx1, lx0)
        self.assertGreater(ly1, ly0)
        for lx, ly in [(0, 0), (7, 7), (3, 5)]:
            self.assertTrue(0 <= rmask.liquid_tile_index(lx, ly) < 64)


class TestAlphaDecode(unittest.TestCase):
    def test_uncompressed_4bit_low_nibble_first(self) -> None:
        raw = bytes([0x21]) + bytes(rmask.ALPHA_BYTES_4BIT - 1)
        data, note = rmask._decode_alpha_map(
            raw, 0, rmask.ALPHA_BYTES_4BIT, rmask.LAYER_USE_ALPHA
        )
        self.assertEqual(note, "")
        self.assertEqual(len(data), rmask.ALPHA_BYTES_8BIT)
        self.assertEqual(data[0], 1 * 17)
        self.assertEqual(data[1], 2 * 17)
        self.assertEqual(data[2], 0)

    def test_full_nibble_scales_to_255(self) -> None:
        raw = bytes([0xFF]) * rmask.ALPHA_BYTES_4BIT
        data, _ = rmask._decode_alpha_map(
            raw, 0, rmask.ALPHA_BYTES_4BIT, rmask.LAYER_USE_ALPHA
        )
        self.assertEqual(set(data), {255})

    def test_short_budget_is_reported_not_crashed(self) -> None:
        data, note = rmask._decode_alpha_map(bytes(16), 0, 16, rmask.LAYER_USE_ALPHA)
        self.assertEqual(len(data), rmask.ALPHA_BYTES_8BIT)
        self.assertEqual(set(data), {0})
        self.assertIn("unreadable", note)

    def test_compressed_rle_is_decoded(self) -> None:
        # 0x80|64 fill of 0x11, then a 0x40 fill... build a full 4096 map.
        raw = bytearray()
        while len(raw) < 66:
            raw += bytes([0x80 | 127, 0x11])
        data, note = rmask._decode_alpha_map(
            bytes(raw), 0, len(raw), rmask.LAYER_USE_ALPHA | rmask.LAYER_ALPHA_COMPRESSED
        )
        self.assertEqual(len(data), rmask.ALPHA_BYTES_8BIT)
        self.assertEqual(data[0], 0x11)
        self.assertIn("compressed", note)


class TestRoadSampleSelection(unittest.TestCase):
    def _probe(self, layers: list[rmask.LayerProbe]) -> rmask.Probe:
        return rmask.Probe(
            x=0.0,
            y=0.0,
            tile=(0, 0),
            chunk=(0, 0),
            chunk_index=0,
            cell=(0, 0),
            alpha_index=0,
            layers=layers,
        )

    def _layer(self, index, road, alpha, texture="tex") -> rmask.LayerProbe:
        return rmask.LayerProbe(
            index=index,
            texture_id=index,
            texture=texture,
            flags=0,
            alpha_offset=0,
            alpha=alpha,
            is_road=road,
        )

    def test_base_layer_road_is_full_coverage(self) -> None:
        probe = self._probe([self._layer(0, True, 255, "Road.blp")])
        self.assertEqual(probe.sample, (True, "Road.blp", 255))

    def test_alpha_above_threshold_is_road(self) -> None:
        probe = self._probe(
            [self._layer(0, False, 255), self._layer(1, True, 102, "Road.blp")]
        )
        self.assertEqual(probe.sample, (True, "Road.blp", 102))

    def test_alpha_at_or_below_threshold_is_not_road(self) -> None:
        probe = self._probe(
            [self._layer(0, False, 255), self._layer(1, True, 64, "Road.blp")]
        )
        sample = probe.sample
        self.assertFalse(sample.is_road)
        self.assertEqual(sample.alpha, 64)
        self.assertEqual(sample.texture, "Road.blp")

    def test_strongest_road_layer_wins(self) -> None:
        probe = self._probe(
            [
                self._layer(0, False, 255),
                self._layer(1, True, 34, "Weak.blp"),
                self._layer(2, True, 204, "Strong.blp"),
            ]
        )
        self.assertEqual(probe.sample, (True, "Strong.blp", 204))

    def test_no_road_layers_reports_nothing(self) -> None:
        probe = self._probe([self._layer(0, False, 255), self._layer(1, False, 200)])
        self.assertEqual(probe.sample, (False, None, 0))

    def test_base_layer_overlay_only_hl02_is_not_road(self) -> None:
        hl02 = r"Tileset\ThousandNeedles\ThousandNeedlesRockHighlight02.blp"
        probe = self._probe([self._layer(0, True, 255, hl02)])
        self.assertEqual(probe.sample, (False, None, 0))

    def test_overlay_hl02_on_base_hl02_is_road(self) -> None:
        hl02 = r"Tileset\ThousandNeedles\ThousandNeedlesRockHighlight02.blp"
        probe = self._probe(
            [self._layer(0, True, 255, hl02), self._layer(1, True, 200, hl02)]
        )
        self.assertEqual(probe.sample, (True, hl02, 200))

    def test_overlay_hl02_at_threshold_is_not_road(self) -> None:
        hl02 = r"Tileset\ThousandNeedles\ThousandNeedlesRockHighlight02.blp"
        probe = self._probe(
            [self._layer(0, False, 255), self._layer(1, True, 64, hl02)]
        )
        sample = probe.sample
        self.assertFalse(sample.is_road)
        self.assertEqual(sample.alpha, 64)
        self.assertEqual(sample.texture, hl02)

    def test_base_kalidar_road_still_full_coverage(self) -> None:
        probe = self._probe([self._layer(0, True, 255, "KalidarRoad.blp")])
        self.assertEqual(probe.sample, (True, "KalidarRoad.blp", 255))


class TestLegReport(unittest.TestCase):
    def _samples(self, flags: list[bool]) -> list[rmask.LegSample]:
        return [
            rmask.LegSample(
                float(i * 5), 0.0, float(i * 5), rmask.RoadSample(flag, None, 0)
            )
            for i, flag in enumerate(flags)
        ]

    def test_on_road_fraction(self) -> None:
        report = rmask.LegReport(self._samples([True, True, False, False]), 15.0)
        self.assertAlmostEqual(report.on_road_fraction, 0.5)

    def test_off_road_spans_interior(self) -> None:
        report = rmask.LegReport(
            self._samples([True, False, False, True, True]), 20.0
        )
        self.assertEqual(report.off_road_spans(), [(5.0, 10.0, 5.0)])

    def test_off_road_span_reaching_the_end(self) -> None:
        report = rmask.LegReport(self._samples([True, False, False]), 10.0)
        self.assertEqual(report.off_road_spans(), [(5.0, 10.0, 5.0)])

    def test_fully_on_road_has_no_spans(self) -> None:
        report = rmask.LegReport(self._samples([True, True]), 5.0)
        self.assertEqual(report.off_road_spans(), [])
        self.assertAlmostEqual(report.on_road_fraction, 1.0)

    def test_empty_leg_is_zero_fraction(self) -> None:
        self.assertAlmostEqual(rmask.LegReport([], 0.0).on_road_fraction, 0.0)


class TestGridPoints(unittest.TestCase):
    def test_grid_is_inclusive_and_orientation_free(self) -> None:
        pts = list(rmask.grid_points(10.0, 0.0, 0.0, 10.0, 5.0))
        self.assertEqual(len(pts), 9)
        self.assertIn((0.0, 0.0), pts)
        self.assertIn((10.0, 10.0), pts)

    def test_degenerate_box_is_one_point(self) -> None:
        self.assertEqual(list(rmask.grid_points(1.0, 2.0, 1.0, 2.0, 5.0)), [(1.0, 2.0)])


@skip_no_adt
class TestCalibrationAgainstAdt(unittest.TestCase):
    """The transform must agree with what the ADT files themselves say."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.mask = rmask.RoadMask(ADT_DIR)

    def test_chunk_header_position_matches_computed_origin(self) -> None:
        """MCNK header + 0x68 holds (max x, max y, z) of the very chunk we pick."""
        for x, y in [
            (1191.7, -2261.3),
            (5792.0, -1204.8),
            (6502.9, -2063.7),
            (6069.0, -1305.0),
            (-6711.4, -4868.5),
        ]:
            a, b = rmask.tile_indices(x, y)
            ix, iy = rmask.chunk_indices(x, y)
            tile = self.mask.tile(a, b)
            self.assertIsNotNone(tile, msg=f"missing kalimdor_{a}_{b}.adt")
            chunk = tile.chunks[rmask.chunk_array_index(ix, iy)]
            ox, oy = rmask.chunk_origin(a, b, ix, iy)
            self.assertAlmostEqual(chunk.position[0], ox, delta=0.01)
            self.assertAlmostEqual(chunk.position[1], oy, delta=0.01)

    def test_chunk_terrain_height_matches_recorded_beat_z(self) -> None:
        """Chunk corner z lands on the hand-recorded beat z (independent check)."""
        for x, y, beat_z, delta in [
            (1191.7, -2261.3, 92.6, 3.0),  # ashenvale_south_road
            (5792.0, -1204.8, 402.9, 3.0),  # felwood_north_road_2
            (6502.9, -2063.7, 576.0, 12.0),  # felwood_cave_entrance
        ]:
            a, b = rmask.tile_indices(x, y)
            ix, iy = rmask.chunk_indices(x, y)
            chunk = self.mask.tile(a, b).chunks[rmask.chunk_array_index(ix, iy)]
            self.assertAlmostEqual(chunk.position[2], beat_z, delta=delta)

    def test_vanilla_alpha_maps_are_uncompressed_2048(self) -> None:
        tile = self.mask.tile(36, 29)
        for chunk in tile.chunks:
            if chunk.n_layers < 2:
                continue
            self.assertEqual(chunk.mcal_size, rmask.ALPHA_BYTES_4BIT * (chunk.n_layers - 1))
            for layer in chunk.layers[1:]:
                self.assertFalse(layer.flags & rmask.LAYER_ALPHA_COMPRESSED)
                self.assertTrue(layer.flags & rmask.LAYER_USE_ALPHA)
            self.assertEqual(chunk.layers[0].alpha_offset, 0)


@skip_no_adt
class TestAnchors(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mask = rmask.RoadMask(ADT_DIR)

    def test_road_negative_forest(self) -> None:
        sample = self.mask.is_road(6069.0, -1305.0)
        self.assertFalse(sample.is_road)
        self.assertIsNone(sample.texture)

    def test_road_negative_ocean_beach(self) -> None:
        sample = self.mask.is_road(-6711.4, -4868.5)
        self.assertFalse(sample.is_road)
        self.assertIsNone(sample.texture)

    def test_road_positive_points(self) -> None:
        """One verified on-paint point per calibration region.

        These sit on the paint the three "road-positive" beats were meant to
        name; see TestBeatAnchorsAreBesideThePaint for the measured offsets.
        """
        cases = {
            (1211.7, -2265.3): "BarrensRoad01",  # Ashenvale south road
            (3519.1, -1515.0): "FelwoodRoad",  # felwood_south_road beat
            (4750.1, -753.8): "FelwoodRoad",  # by felwood_ridge_dodge
            (5230.0, -714.0): "FelwoodRoad",  # by felwood_ooze_dodge
            (6546.9, -2055.7): "FelwoodRoad",  # Timbermaw road
        }
        for (x, y), texture in cases.items():
            sample = self.mask.is_road(x, y)
            self.assertTrue(sample.is_road, msg=f"({x},{y}) read as off-road")
            self.assertIn(texture, sample.texture or "")
            self.assertGreater(sample.alpha, rmask.ROAD_ALPHA_THRESHOLD)

    def test_felwood_south_road_beat_is_on_paint(self) -> None:
        """The one land beat that really does sit on painted road."""
        sample = self.mask.is_road(3519.1, -1515.0)
        self.assertEqual(
            sample, (True, "Tileset\\Felwood\\FelwoodRoad.blp", 102)
        )


@skip_no_adt
class TestBeatAnchorsAreBesideThePaint(unittest.TestCase):
    """Measured, not assumed: the three "road-positive" beats are off the paint.

    Each was handed over as a road-positive calibration anchor. With the
    transform validated to 1.02 yd rms against 228 navmesh waypoints (see the
    road_mask module docstring) they still read off-road, because the beats sit
    beside the painted road rather than on it. These tests pin the observed
    offsets so a future transform change that "fixes" them is noticed.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.mask = rmask.RoadMask(ADT_DIR)

    def test_ashenvale_beat_is_about_20_yd_west_of_the_paint(self) -> None:
        self.assertFalse(self.mask.is_road(1191.7, -2261.3).is_road)
        near = self.mask.nearest_road(1191.7, -2261.3, radius=40.0, step=1.0)
        self.assertIsNotNone(near)
        dist, nx, _ny, texture = near
        self.assertAlmostEqual(dist, 19.0, delta=3.0)
        self.assertGreater(nx, 1191.7)  # paint lies east (higher x)
        self.assertIn("Road", texture)

    def test_timbermaw_cave_beat_is_about_45_yd_from_the_paint(self) -> None:
        self.assertFalse(self.mask.is_road(6502.9, -2063.7).is_road)
        near = self.mask.nearest_road(6502.9, -2063.7, radius=60.0, step=1.0)
        self.assertIsNotNone(near)
        self.assertAlmostEqual(near[0], 44.7, delta=4.0)

    def test_felwood_north_beat_tile_paints_no_road_at_all(self) -> None:
        """kalimdor_34_21 has no road tileset in MTEX -- nothing to detect."""
        self.assertFalse(self.mask.is_road(5792.0, -1204.8).is_road)
        tile = self.mask.tile(34, 21)
        self.assertEqual(tile.road_texture_ids, frozenset())
        self.assertIn("Tileset\\Felwood\\FelwoodDirt.blp", tile.textures)
        self.assertIsNone(self.mask.nearest_road(5792.0, -1204.8, radius=60.0, step=2.0))


@skip_no_adt
class TestLegSampling(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mask = rmask.RoadMask(ADT_DIR)

    def test_leg_along_painted_road_is_mostly_on_road(self) -> None:
        report = rmask.sample_leg(self.mask, 4750.1, -753.8, 4780.0, -757.0, 2.0)
        self.assertGreater(report.on_road_fraction, 0.5)

    def test_timbermaw_climb_leg_is_entirely_off_road(self) -> None:
        report = rmask.sample_leg(
            self.mask, 5995.7, -1485.6, 6124.0, -1818.9, 5.0
        )
        self.assertEqual(report.on_road_fraction, 0.0)
        spans = report.off_road_spans()
        self.assertEqual(len(spans), 1)
        self.assertGreater(spans[0][2], 300.0)


@skip_no_adt
class TestWaterAnchors(unittest.TestCase):
    """Five calibration anchors for MCLQ liquid presence (do not fudge)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.mask = rmask.RoadMask(ADT_DIR)

    def test_ocean_tele_is_water(self) -> None:
        # Bot tele lands swimming here; ocean flag + full 0x41 tile paint.
        sample = self.mask.is_water(-6711.4, -4868.5)
        self.assertTrue(sample.is_water, msg=f"sample={sample}")
        self.assertGreater(sample.depth, 0.0)
        probe = self.mask.water_probe(-6711.4, -4868.5)
        self.assertTrue(probe.mcnk_flags & rmask.MCNK_FLAG_OCEAN)
        self.assertGreater(probe.size_liquid, 8)
        self.assertIsNotNone(probe.tile_flag)
        self.assertTrue(rmask.mclq_tile_has_liquid(probe.tile_flag))

    def test_shallow_coast_is_water(self) -> None:
        sample = self.mask.is_water(-4627.0, -4869.5)
        self.assertTrue(sample.is_water, msg=f"sample={sample}")
        self.assertGreater(sample.depth, 0.0)
        probe = self.mask.water_probe(-4627.0, -4869.5)
        self.assertTrue(probe.mcnk_flags & rmask.MCNK_FLAG_OCEAN)

    def test_beach_sand_is_dry(self) -> None:
        # Same ocean-flagged chunk family, but this cell's tile flag is 0x0F.
        sample = self.mask.is_water(-6784.5, -4833.9)
        self.assertFalse(sample.is_water, msg=f"sample={sample}")
        probe = self.mask.water_probe(-6784.5, -4833.9)
        self.assertGreater(probe.size_liquid, 8)  # MCLQ present but cell dry
        self.assertIsNotNone(probe.tile_flag)
        self.assertFalse(rmask.mclq_tile_has_liquid(probe.tile_flag))

    def test_inland_barrens_is_dry(self) -> None:
        sample = self.mask.is_water(1071.6, -2303.4)
        self.assertFalse(sample.is_water, msg=f"sample={sample}")
        probe = self.mask.water_probe(1071.6, -2303.4)
        self.assertLessEqual(probe.size_liquid, 8)

    def test_felwood_road_is_dry(self) -> None:
        sample = self.mask.is_water(6502.9, -2063.7)
        self.assertFalse(sample.is_water, msg=f"sample={sample}")
        probe = self.mask.water_probe(6502.9, -2063.7)
        self.assertLessEqual(probe.size_liquid, 8)


@skip_no_azeroth
class TestAzerothAdt(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mask = rmask.RoadMask(AZEROTH_DIR)

    def test_tile_28_28_has_tirisfall_road_textures(self) -> None:
        tile = self.mask.tile(28, 28)
        self.assertIsNotNone(tile)
        self.assertTrue(tile.road_texture_ids)
        self.assertTrue(any("tirisfall" in name.lower() for name in tile.textures))

    def test_tile_coords_includes_28_28(self) -> None:
        coords = self.mask.tile_coords()
        self.assertTrue(coords)
        self.assertIn((28, 28), coords)
        self.assertEqual(coords, sorted(coords))


class TestBakeRoadWaypoints(unittest.TestCase):
    """Pure-math bake pipeline — synthetic cells, no ADT files."""

    def _l_cells(self, arm: int = 12, z: float = 10.0) -> dict[tuple[int, int], float]:
        cells: dict[tuple[int, int], float] = {}
        for i in range(arm):
            cells[(i, 0)] = z
        for j in range(1, arm):
            cells[(0, j)] = z
        return cells

    def test_l_shape_is_one_segment_tip_to_tip(self) -> None:
        step = 4.0
        arm = 12
        segs = bake.bake_from_cells(
            self._l_cells(arm), step=step, min_cells=6, min_component_length=0.0
        )
        self.assertEqual(len(segs), 1)
        pts = segs[0]["pts"]
        tips = {
            (0.0, (arm - 1) * step),
            ((arm - 1) * step, 0.0),
        }
        ends = {(pts[0][0], pts[0][1]), (pts[-1][0], pts[-1][1])}
        self.assertEqual(ends, tips)

    def test_two_disjoint_blobs_are_two_segments(self) -> None:
        cells: dict[tuple[int, int], float] = {}
        for i in range(8):
            cells[(i, 0)] = 1.0
        for i in range(8):
            cells[(i + 40, 50)] = 2.0
        segs = bake.bake_from_cells(
            cells, step=4.0, min_cells=6, min_length=0.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 2)

    def test_plus_shape_splits_spur_after_erasure(self) -> None:
        step = 4.0
        cells: dict[tuple[int, int], float] = {}
        for i in range(-12, 13):
            cells[(i, 0)] = 5.0
        for j in range(-12, 13):
            cells[(0, j)] = 5.0
        paths, discarded, _dropped, _short = bake.extract_centerlines(
            set(cells), step, min_cells=6
        )
        self.assertGreaterEqual(len(paths), 2)
        path_xy = [(i * step, j * step) for path in paths for i, j in path]
        small = set()
        for rem in discarded:
            small.update(rem)
        for i, j in cells:
            x, y = i * step, j * step
            dmin = min(math.hypot(x - px, y - py) for px, py in path_xy)
            if dmin > bake.ERASE_YD:
                self.assertIn((i, j), small)

    def test_determinism_bytes_and_insertion_order(self) -> None:
        cells = self._l_cells()
        for i in range(8):
            cells[(i + 30, 20)] = 3.0
        a = bake.bake_from_cells(cells, min_length=0.0, min_component_length=0.0)
        b = bake.bake_from_cells(cells, min_length=0.0, min_component_length=0.0)
        meta = bake.make_meta("kalimdor", 4.0, 10.0, 6)
        bytes_a = bake.render_artifact(meta, [], a).encode("utf-8")
        bytes_b = bake.render_artifact(meta, [], b).encode("utf-8")
        self.assertEqual(bytes_a, bytes_b)
        items = list(cells.items())
        random.Random(0).shuffle(items)
        c = bake.bake_from_cells(
            dict(items), min_length=0.0, min_component_length=0.0
        )
        self.assertEqual(bake.render_artifact(meta, [], c).encode("utf-8"), bytes_a)

    def test_merge_preserves_hand_line_bytes_drops_stale_baked(self) -> None:
        hand_raw = (
            '{"id": "h_bridge",  "source":"hand","note": "odd keys", '
            '"pts": [[1, 2, 3], [4,5,6]]}'
        )
        existing = "\n".join(
            [
                '{"meta": 1, "map": "kalimdor", "map_id": 1}',
                hand_raw,
                '{"id": "b0099", "source": "baked", "pts": [[0, 0, 0], [9, 9, 9]]}',
            ]
        ) + "\n"
        meta = bake.make_meta("kalimdor", 4.0, 10.0, 6)
        baked = [
            {
                "id": "b0001",
                "source": "baked",
                "pts": [[0.0, 0.0, 1.0], [10.0, 0.0, 1.0]],
            }
        ]
        out = bake.render_artifact(meta, bake.read_hand_lines(existing), baked)
        lines = out.splitlines()
        self.assertEqual(json.loads(lines[0])["meta"], 1)
        self.assertEqual(lines[1], hand_raw)
        self.assertNotIn("b0099", out)
        self.assertEqual(json.loads(lines[2])["id"], "b0001")
        self.assertTrue(out.endswith("\n"))

    def test_meta_line_fields_match_args(self) -> None:
        meta = bake.make_meta("kalimdor", 4.0, 10.0, 6)
        obj = json.loads(json.dumps(meta))
        self.assertEqual(obj["meta"], 1)
        self.assertEqual(obj["map"], "kalimdor")
        self.assertEqual(obj["map_id"], 1)
        self.assertEqual(obj["generator"], "tools/bake_road_waypoints.py")
        self.assertEqual(obj["alpha_threshold"], 64)
        self.assertEqual(obj["step"], 4.0)
        self.assertEqual(obj["decimate_yd"], 10.0)
        self.assertEqual(obj["min_cells"], 6)
        self.assertEqual(obj["min_length_yd"], 30.0)
        self.assertEqual(obj["max_water_depth"], 0.5)
        self.assertEqual(obj["max_width_yd"], 28.0)
        self.assertEqual(obj["max_grade"], 0.55)
        self.assertEqual(obj["min_component_length_yd"], 150.0)
        self.assertEqual(obj["markers"], list(rmask.ROAD_TEXTURE_MARKERS))
        self.assertIn("thousandneedlesrockhighlight02", obj["markers"])
        self.assertNotIn("thousandneedlesdirt", obj["markers"])
        self.assertEqual(
            obj["overlay_only_markers"], list(rmask.OVERLAY_ONLY_MARKERS)
        )
        azeroth = json.loads(json.dumps(bake.make_meta("azeroth", 4.0, 15.0, 8)))
        self.assertEqual(azeroth["map_id"], 0)
        self.assertEqual(azeroth["decimate_yd"], 15.0)
        self.assertEqual(azeroth["min_cells"], 8)

    def test_decimate_keeps_ends_and_interior_spacing(self) -> None:
        chain = [(float(i), 0.0, 0.0) for i in range(56)]
        kept = bake.decimate(chain, 10.0)
        self.assertEqual(kept[0], chain[0])
        self.assertEqual(kept[-1], chain[-1])
        self.assertGreaterEqual(len(kept), 2)
        for prev, cur in zip(kept[:-2], kept[1:-1]):
            self.assertGreaterEqual(
                math.hypot(cur[0] - prev[0], cur[1] - prev[1]), 10.0
            )


class TestThinning(unittest.TestCase):
    """Zhang-Suen thinning — synthetic cells, no ADT files."""

    def _bar(self, length: int, width: int) -> set[tuple[int, int]]:
        return {(i, j) for i in range(length) for j in range(width)}

    def test_thick_bar_skeleton_is_one_wide(self) -> None:
        skel = bake.thin_cells(self._bar(15, 5))
        for i, j in skel:
            n = sum(
                1 for di, dj in bake.NEIGH8 if (i + di, j + dj) in skel
            )
            self.assertLessEqual(n, 2, msg=f"cell {(i, j)} neighbors={n}")

    def test_skeleton_subset_and_one_component(self) -> None:
        bar = self._bar(15, 5)
        skel = bake.thin_cells(bar)
        self.assertTrue(skel.issubset(bar))
        self.assertEqual(len(bake.connected_components(skel)), 1)

    def test_annihilated_blob_does_not_crash_extraction(self) -> None:
        # A 2x2 block thins to the empty set; extract_centerlines must skip
        # it instead of crashing on sort(key=min) over an empty set.
        self.assertEqual(bake.thin_cells(self._bar(2, 2)), set())
        blob = self._bar(2, 2)
        bar = {(i + 10, 0) for i in range(12)}
        paths, _, _, _ = bake.extract_centerlines(blob | bar, step=4.0, min_cells=4)
        self.assertEqual(len(paths), 1)

    def test_one_wide_l_and_plus_are_fixed_points(self) -> None:
        ell: set[tuple[int, int]] = set()
        for i in range(8):
            ell.add((i, 0))
        for j in range(1, 8):
            ell.add((0, j))
        self.assertEqual(bake.thin_cells(ell), ell)
        plus: set[tuple[int, int]] = set()
        for i in range(-4, 5):
            plus.add((i, 0))
        for j in range(-4, 5):
            plus.add((0, j))
        self.assertEqual(bake.thin_cells(plus), plus)

    def test_determinism_under_insertion_order(self) -> None:
        bar = self._bar(15, 5)
        expected = bake.thin_cells(set(bar))
        items = list(bar)
        for seed in range(8):
            random.Random(seed).shuffle(items)
            built: set[tuple[int, int]] = set()
            for cell in items:
                built.add(cell)
            self.assertEqual(bake.thin_cells(built), expected)

    def test_thick_bar_bakes_to_one_segment(self) -> None:
        cells = {(i, j): 10.0 for i in range(16) for j in range(5)}
        segs = bake.bake_from_cells(
            cells, min_length=0.0, max_width=0.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 1)

    def test_thick_l_is_single_segment_tip_to_tip(self) -> None:
        arm = 20
        width = 5
        cells: dict[tuple[int, int], float] = {}
        for i in range(arm):
            for j in range(width):
                cells[(i, j)] = 10.0
        for j in range(width, arm):
            for i in range(width):
                cells[(i, j)] = 10.0
        segs = bake.bake_from_cells(cells, min_length=0.0, min_component_length=0.0)
        self.assertEqual(len(segs), 1)
        pts = segs[0]["pts"]
        step = 4.0
        tips = (
            ((arm - 1) * step, (width // 2) * step),
            ((width // 2) * step, (arm - 1) * step),
        )
        ends = ((pts[0][0], pts[0][1]), (pts[-1][0], pts[-1][1]))

        def _near(end: tuple[float, float]) -> float:
            return min(math.hypot(end[0] - t[0], end[1] - t[1]) for t in tips)

        self.assertLessEqual(_near(ends[0]), 12.0)
        self.assertLessEqual(_near(ends[1]), 12.0)
        self.assertNotEqual(
            min(range(2), key=lambda k: math.hypot(ends[0][0] - tips[k][0], ends[0][1] - tips[k][1])),
            min(range(2), key=lambda k: math.hypot(ends[1][0] - tips[k][0], ends[1][1] - tips[k][1])),
        )


class _FakeMask:
    """Duck-typed RoadMask for sample_road_cells water/grade tests."""

    def __init__(
        self,
        road_rect: tuple[float, float, float, float],
        water: dict[tuple[float, float], rmask.WaterSample] | None = None,
        ground_fn=None,
    ) -> None:
        self._road_rect = road_rect
        self._water = water or {}
        self._ground_fn = ground_fn
        layer = type("Layer", (), {"texture_id": 0})()
        chunk = type("Chunk", (), {"layers": [layer]})()
        self._tile = type(
            "Tile",
            (),
            {"road_texture_ids": {0}, "chunks": [chunk] * 256},
        )()

    def tile_coords(self) -> list[tuple[int, int]]:
        return [(0, 0)]

    def tile(self, a: int, b: int) -> object:
        return self._tile

    def is_road(self, x: float, y: float) -> rmask.RoadSample:
        x0, y0, x1, y1 = self._road_rect
        inside = x0 <= x <= x1 and y0 <= y <= y1
        return rmask.RoadSample(inside, "road" if inside else None, 255 if inside else 0)

    def is_water(self, x: float, y: float) -> rmask.WaterSample:
        return self._water.get((x, y), rmask.WaterSample(False, 0.0, 0.0))

    def ground_z(self, x: float, y: float) -> float | None:
        if self._ground_fn is not None:
            return self._ground_fn(x, y)
        return 10.0


def _tile00_lattice(count: int, step: float = 4.0) -> list[tuple[float, float]]:
    max_x, max_y = rmask.tile_origin(0, 0)
    min_x = max_x - rmask.TILE_YD
    min_y = max_y - rmask.TILE_YD
    i0 = math.ceil(min_x / step - 1e-9)
    j0 = math.ceil(min_y / step - 1e-9)
    return [((i0 + k) * step, j0 * step) for k in range(count)]


class TestWaterExclusion(unittest.TestCase):
    """sample_road_cells water skip — fake mask, no ADT files."""

    def _setup(
        self, n: int = 8
    ) -> tuple[_FakeMask, list[tuple[float, float]], tuple[float, float, float, float]]:
        pts = _tile00_lattice(n)
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        rect = (min(xs), min(ys), max(xs), max(ys))
        water = {
            pts[0]: rmask.WaterSample(True, 12.0, 2.0),
            pts[1]: rmask.WaterSample(True, 12.0, 2.0),
            pts[2]: rmask.WaterSample(True, 12.0, 2.0),
            pts[3]: rmask.WaterSample(True, 10.3, 0.3),
        }
        bbox = (min(xs) - 1.0, min(ys) - 1.0, max(xs) + 1.0, max(ys) + 1.0)
        return _FakeMask(rect, water), pts, bbox

    def test_deep_water_skipped_shallow_kept(self) -> None:
        mask, pts, bbox = self._setup()
        cells, stats = bake.sample_road_cells(mask, 4.0, bbox=bbox)
        self.assertEqual(stats["water_skipped"], 3)
        self.assertEqual(len(cells), 5)
        step = 4.0
        deep_keys = {(int(round(p[0] / step)), int(round(p[1] / step))) for p in pts[:3]}
        shallow_key = (int(round(pts[3][0] / step)), int(round(pts[3][1] / step)))
        self.assertTrue(deep_keys.isdisjoint(cells))
        self.assertIn(shallow_key, cells)

    def test_max_water_depth_zero_disables(self) -> None:
        mask, _pts, bbox = self._setup()
        cells, stats = bake.sample_road_cells(
            mask, 4.0, bbox=bbox, max_water_depth=0.0
        )
        self.assertEqual(stats["water_skipped"], 0)
        self.assertEqual(len(cells), 8)

    def test_water_skipped_in_stats(self) -> None:
        mask, _pts, bbox = self._setup()
        _cells, stats = bake.sample_road_cells(mask, 4.0, bbox=bbox)
        self.assertIn("water_skipped", stats)
        self.assertEqual(stats["water_skipped"], 3)


class TestMaxWidth(unittest.TestCase):
    """max_width filter — synthetic cells, no ADT files."""

    def _block(self) -> dict[tuple[int, int], float]:
        # Solid squares collapse under Zhang-Suen to 1 cell (no path, gate
        # never fires). A 20x8 rectangle thins to a real centerline ~58 yd wide.
        return {(i, j): 1.0 for i in range(20) for j in range(8)}

    def test_solid_block_dropped_at_default(self) -> None:
        segs = bake.bake_from_cells(
            self._block(), min_length=0.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 0)

    def test_max_width_zero_keeps_block(self) -> None:
        segs = bake.bake_from_cells(
            self._block(), min_length=0.0, max_width=0.0, min_component_length=0.0
        )
        self.assertGreaterEqual(len(segs), 1)

    def test_thin_bar_kept_at_default(self) -> None:
        cells = {(i, j): 1.0 for i in range(50) for j in range(3)}
        segs = bake.bake_from_cells(
            cells, min_length=0.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 1)

    def test_extract_dropped_wide_counts(self) -> None:
        block = set(self._block())
        bar = {(i, j) for i in range(50) for j in range(3)}
        _, _, dropped_block, _ = bake.extract_centerlines(
            block, step=4.0, min_cells=6, max_width=28.0
        )
        self.assertEqual(dropped_block, 1)
        _, _, dropped_bar, _ = bake.extract_centerlines(
            bar, step=4.0, min_cells=6, max_width=28.0
        )
        self.assertEqual(dropped_bar, 0)

    def test_block_dropped_thin_bar_survives(self) -> None:
        cells = self._block()
        for i in range(50):
            for j in range(3):
                cells[(i + 40, j)] = 1.0
        segs = bake.bake_from_cells(
            cells, min_length=0.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 1)
        pts = segs[0]["pts"]
        length = math.hypot(pts[-1][0] - pts[0][0], pts[-1][1] - pts[0][1])
        self.assertGreater(length, 100.0)


class TestMinLength(unittest.TestCase):
    """min_length filter — synthetic cells, no ADT files."""

    def test_short_segment_dropped_at_default(self) -> None:
        cells = {(i, 0): 1.0 for i in range(8)}
        segs = bake.bake_from_cells(cells, min_component_length=0.0)
        self.assertEqual(len(segs), 0)

    def test_min_length_zero_keeps_short(self) -> None:
        cells = {(i, 0): 1.0 for i in range(8)}
        segs = bake.bake_from_cells(cells, min_length=0.0, min_component_length=0.0)
        self.assertEqual(len(segs), 1)

    def test_zigzag_measured_before_decimate(self) -> None:
        cells: dict[tuple[int, int], float] = {}
        for i in range(7):
            cells[(i, 0)] = 1.0
        cells[(6, 1)] = 1.0
        for i in range(7):
            cells[(i, 2)] = 1.0
        segs = bake.bake_from_cells(
            cells, decimate_yd=100.0, min_length=30.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 1)
        pts = segs[0]["pts"]
        chord = math.hypot(pts[-1][0] - pts[0][0], pts[-1][1] - pts[0][1])
        self.assertLess(chord, 30.0)


class TestGradeFilter(unittest.TestCase):
    """sample_road_cells max_grade skip — fake mask, no ADT files."""

    def _split_pts(self, n: int = 8) -> tuple[list[tuple[float, float]], float]:
        pts = _tile00_lattice(n)
        mid = (pts[0][0] + pts[-1][0]) / 2.0
        return pts, mid

    def _mask(
        self, pts: list[tuple[float, float]], ground_fn
    ) -> tuple[_FakeMask, tuple[float, float, float, float]]:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        rect = (min(xs), min(ys), max(xs), max(ys))
        bbox = (min(xs) - 1.0, min(ys) - 1.0, max(xs) + 1.0, max(ys) + 1.0)
        return _FakeMask(rect, ground_fn=ground_fn), bbox

    def test_steep_cells_skipped_flat_kept(self) -> None:
        pts, mid = self._split_pts()

        def ground_fn(x: float, _y: float) -> float:
            return 0.0 if x < mid else x * 2.0

        mask, bbox = self._mask(pts, ground_fn)
        cells, stats = bake.sample_road_cells(mask, 4.0, bbox=bbox)
        step = 4.0
        # Cells within one stencil step of the split see a steep neighbor.
        flat_keys = {
            (int(round(p[0] / step)), int(round(p[1] / step)))
            for p in pts
            if p[0] < mid - 4.0
        }
        steep_keys = {
            (int(round(p[0] / step)), int(round(p[1] / step)))
            for p in pts
            if p[0] >= mid
        }
        self.assertTrue(flat_keys)
        self.assertTrue(flat_keys.issubset(cells))
        self.assertTrue(steep_keys.isdisjoint(cells))
        self.assertGreaterEqual(stats["grade_skipped"], len(steep_keys))
        self.assertGreater(stats["grade_skipped"], 0)

    def test_max_grade_zero_disables(self) -> None:
        pts, mid = self._split_pts()

        def ground_fn(x: float, _y: float) -> float:
            return 0.0 if x < mid else x * 2.0

        mask, bbox = self._mask(pts, ground_fn)
        cells, stats = bake.sample_road_cells(
            mask, 4.0, bbox=bbox, max_grade=0.0
        )
        self.assertEqual(stats["grade_skipped"], 0)
        self.assertEqual(len(cells), 8)

    def test_missing_neighbor_z_keeps_edge_cells(self) -> None:
        pts = _tile00_lattice(8)
        xs = [p[0] for p in pts]
        lo, hi = min(xs), max(xs)

        def ground_fn(x: float, _y: float) -> float | None:
            if x < lo or x > hi:
                return None
            return x * 2.0

        mask, bbox = self._mask(pts, ground_fn)
        cells, stats = bake.sample_road_cells(mask, 4.0, bbox=bbox)
        step = 4.0
        edge_keys = {
            (int(round(p[0] / step)), int(round(p[1] / step)))
            for p in pts
            if p[0] == lo or p[0] == hi
        }
        self.assertTrue(edge_keys.issubset(cells))
        self.assertEqual(stats["grade_skipped"], 6)
        self.assertEqual(len(cells), 2)


class TestMinComponentLength(unittest.TestCase):
    """min_component_length gate — synthetic cells, no ADT files."""

    def test_long_thin_bar_kept(self) -> None:
        # 50 cells at step 4: ~196 yd centerline, above the 150 yd gate.
        cells = {(i, 0): 1.0 for i in range(50)}
        segs = bake.bake_from_cells(cells, min_length=0.0)
        self.assertEqual(len(segs), 1)

    def test_short_bar_dropped_via_extract(self) -> None:
        # 26 cells at step 4: 100 yd, passes width, fails the 150 yd gate.
        bar = {(i, 0) for i in range(26)}
        paths, _, dropped_wide, dropped_short = bake.extract_centerlines(
            bar, step=4.0, min_cells=6, min_component_length=150.0
        )
        self.assertEqual(len(paths), 0)
        self.assertEqual(dropped_wide, 0)
        self.assertEqual(dropped_short, 1)

    def test_min_component_length_zero_disables(self) -> None:
        bar = {(i, 0) for i in range(26)}
        paths, _, _, dropped_short = bake.extract_centerlines(
            bar, step=4.0, min_cells=6, min_component_length=0.0
        )
        self.assertEqual(len(paths), 1)
        self.assertEqual(dropped_short, 0)
        segs = bake.bake_from_cells(
            {c: 1.0 for c in bar}, min_length=0.0, min_component_length=0.0
        )
        self.assertEqual(len(segs), 1)


if __name__ == "__main__":
    unittest.main()
