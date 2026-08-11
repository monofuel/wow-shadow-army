#!/usr/bin/env python3
"""Unit tests for tools/road_mask.py.

Transform maths run everywhere; the anchor tests skip cleanly when the flat
Kalimdor ADT dump is not present.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import road_mask as rmask  # noqa: E402

ADT_DIR = rmask.DEFAULT_ADT_DIR
HAVE_ADT = ADT_DIR.is_dir() and any(ADT_DIR.glob("kalimdor_*.adt"))
skip_no_adt = unittest.skipUnless(HAVE_ADT, f"no Kalimdor ADTs at {ADT_DIR}")


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
        self.assertFalse(rmask.is_road_texture("Tileset\\Felwood\\FelwoodDirt.blp"))
        self.assertFalse(rmask.is_road_texture("Tileset\\Generic\\Black.blp"))


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


if __name__ == "__main__":
    unittest.main()
