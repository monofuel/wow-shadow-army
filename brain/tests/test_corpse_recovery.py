"""Unit tests for pure corridor helpers (shipped module, no socket)."""

from __future__ import annotations

import unittest

from brain.corpse_recovery_path import (
    DEATHKNELL_NE_CORPSE_ANCHORS,
    anchor_corridor_to_corpse,
    gap_2d,
    is_direct_line_policy,
    next_corridor_index,
    should_reclaim,
    subsample_corridor,
)


class TestGap2d(unittest.TestCase):
    def test_distance(self) -> None:
        self.assertAlmostEqual(gap_2d(0, 0, 3, 4), 5.0)


class TestCorridorOrder(unittest.TestCase):
    def test_subsample_preserves_order_and_end(self) -> None:
        raw = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (20.0, 0.0, 0.0), (40.0, 5.0, 1.0)]
        out = subsample_corridor(raw, min_spacing=8.0)
        self.assertEqual(out[0], (0.0, 0.0, 0.0))
        self.assertEqual(out[-1], (40.0, 5.0, 1.0))
        self.assertGreaterEqual(len(out), 2)
        # no direct collapse of first to last
        self.assertLess(out[1][0], out[-1][0])

    def test_next_corridor_advances(self) -> None:
        c = [(0.0, 0.0, 0.0), (20.0, 0.0, 0.0), (40.0, 0.0, 0.0)]
        self.assertEqual(next_corridor_index(1, 0, c, 0, arrive=5), 1)
        self.assertEqual(next_corridor_index(20, 0, c, 1, arrive=5), 2)
        self.assertEqual(next_corridor_index(40, 0, c, 2, arrive=5), 3)

    def test_anchor_corridor_ends_on_corpse_not_direct_only(self) -> None:
        # Ghost where prior thrash was; corpse NE elevated.
        corridor = anchor_corridor_to_corpse(
            1972.0, 1720.0, 87.0, 2043.0, 1841.0, 107.0, min_spacing=8.0
        )
        self.assertGreaterEqual(len(corridor), 4)
        self.assertAlmostEqual(corridor[-1][0], 2043.0)
        self.assertAlmostEqual(corridor[-1][1], 1841.0)
        # First legs should not be the corpse itself.
        self.assertLess(corridor[0][1], 1841.0)
        # Path goes east/north via anchors, not a single hop.
        xs = [p[0] for p in corridor[:-1]]
        self.assertTrue(any(x >= 2020 for x in xs) or any(x >= 2000 for x in xs))

    def test_anchors_table_nonempty(self) -> None:
        self.assertGreaterEqual(len(DEATHKNELL_NE_CORPSE_ANCHORS), 5)

    def test_should_reclaim(self) -> None:
        self.assertTrue(should_reclaim(can_reclaim=True, gap=5.0))
        self.assertFalse(should_reclaim(can_reclaim=True, gap=50.0))

    def test_direct_line_policy_flag(self) -> None:
        self.assertTrue(is_direct_line_policy("move_to_corpse_hop"))
        self.assertFalse(is_direct_line_policy("corridor_leg_3"))


if __name__ == "__main__":
    unittest.main()
