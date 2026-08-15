#!/usr/bin/env python3
"""Minimap luminance sampler for vanilla 1.12 tiles.

WoW 1.12 minimap tiles are pre-rendered ground truth of terrain blend colors.
This module is the sampler only: world (x, y) -> tile pixel -> ITU-R 601 luma.
"""
from __future__ import annotations

import math
import os
import re
from pathlib import Path

try:
    from PIL import Image
    HAVE_PILLOW = True
except ImportError:
    Image = None  # type: ignore[misc, assignment]
    HAVE_PILLOW = False

TILE_YD = 533.3333333333333
TILE_PX = 256
CACHE_MAX = 25
PILLOW_REQUIRED = (
    "minimap sampling needs Pillow for BLP decode - "
    "run under: nix-shell -p python3Packages.pillow"
)

DEFAULT_ASSETS_DIR = Path(
    os.environ.get(
        "VANILLA_WOW_ASSETS_DIR",
        "/home/monofuel/src/wow-coworld/local_data/player/assets-flat",
    )
)

_TRS_MAP = re.compile(
    r"^(?P<map>[^\\/]+)[\\/]map(?P<a>\d+)_(?P<b>\d+)\.blp$",
    re.IGNORECASE,
)


def parse_trs(path: str | Path) -> dict[tuple[str, int, int], str]:
    """Parse md5translate.trs into {(map_lower, A, B): md5_filename}."""
    index: dict[tuple[str, int, int], str] = {}
    for raw in Path(path).read_text(encoding="ascii", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.lower().startswith("dir:"):
            continue
        if "\t" not in line:
            continue
        left, right = line.split("\t", 1)
        match = _TRS_MAP.match(left.strip())
        if match is None:
            continue
        md5_name = right.strip()
        if not md5_name:
            continue
        index[
            (match.group("map").lower(), int(match.group("a")), int(match.group("b")))
        ] = md5_name
    return index


def tile_pixel(x: float, y: float) -> tuple[tuple[int, int], tuple[int, int]]:
    """World (x, y) -> ((a, b), (px, py)).

    THE TRANSFORM (verified empirically this session against terrain
    elevation and the Great Lift landmark — it reads "transposed" to
    intuition; DO NOT "normalize", "fix", or transpose it):
    """
    a = int(math.floor(32.0 - y / TILE_YD))  # tile row index  (from y, west-east axis)
    b = int(math.floor(32.0 - x / TILE_YD))  # tile col index  (from x, north-south axis)
    # within-tile ROW from x (north -> south)
    row_frac = ((32.0 - b) * TILE_YD - x) / TILE_YD
    # within-tile COL from y (west -> east)
    col_frac = ((32.0 - a) * TILE_YD - y) / TILE_YD
    py = int(row_frac * TILE_PX)  # nearest/floor pixel, NO resampling
    px = int(col_frac * TILE_PX)
    py = min(TILE_PX - 1, max(0, py))
    px = min(TILE_PX - 1, max(0, px))
    return ((a, b), (px, py))


def _luma(r: int, g: int, b: int) -> int:
    return (299 * r + 587 * g + 114 * b) // 1000


class MinimapSampler:
    """Lazy per-tile minimap luminance sampler for one continent."""

    def __init__(
        self,
        assets_dir: str | Path,
        map_name: str,
        trs_path: str | Path | None = None,
        tiles_dir: str | Path | None = None,
    ) -> None:
        if not HAVE_PILLOW:
            raise RuntimeError(PILLOW_REQUIRED)
        self.assets_dir = Path(assets_dir)
        self.map_name = map_name.lower()
        self.trs_path = (
            Path(trs_path)
            if trs_path is not None
            else self.assets_dir / "ui_dedicated" / "minimap" / "md5translate.trs"
        )
        self.tiles_dir = (
            Path(tiles_dir)
            if tiles_dir is not None
            else self.assets_dir / "textures" / "minimap"
        )
        self._index = parse_trs(self.trs_path)
        self._cache: dict[tuple[int, int], object] = {}

    def tile_pixel(self, x: float, y: float) -> tuple[tuple[int, int], tuple[int, int]]:
        return tile_pixel(x, y)

    def rgb(self, x: float, y: float) -> tuple[int, int, int] | None:
        (a, b), (px, py) = tile_pixel(x, y)
        image = self._load_tile(a, b)
        if image is None:
            return None
        r, g, b_ = image.getpixel((px, py))
        return (int(r), int(g), int(b_))

    def luminance(self, x: float, y: float) -> int | None:
        pixel = self.rgb(x, y)
        if pixel is None:
            return None
        return _luma(*pixel)

    def _load_tile(self, a: int, b: int):
        key = (a, b)
        cached = self._cache.get(key)
        if cached is not None:
            return cached
        md5_name = self._index.get((self.map_name, a, b))
        if md5_name is None:
            return None
        path = self.tiles_dir / md5_name
        if not path.is_file():
            return None
        image = Image.open(path).convert("RGB")
        if image.size != (TILE_PX, TILE_PX):
            raise RuntimeError(
                f"minimap tile {md5_name} decoded at {image.size}, "
                f"expected ({TILE_PX}, {TILE_PX})"
            )
        if len(self._cache) >= CACHE_MAX:
            self._cache.pop(next(iter(self._cache)))
        self._cache[key] = image
        return image
