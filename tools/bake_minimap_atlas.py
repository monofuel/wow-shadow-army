#!/usr/bin/env python3
"""Stitch vanilla 1.12 minimap BLP tiles into one downscaled RGBA atlas.

Offline baker: the only BLP consumer. Nim reads the PNG + JSON, never BLP.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import minimap_mask as mmask

HAVE_PILLOW = mmask.HAVE_PILLOW
if HAVE_PILLOW:
    from PIL import Image
else:
    Image = None  # type: ignore[misc, assignment]

MAP_IDS = {"kalimdor": 1, "azeroth": 0}
DEFAULT_PX_PER_TILE = 128
MAX_ATLAS_DIM = 16384
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = REPO_ROOT / "local_data" / "map_browser"
PILLOW_REQUIRED = (
    "minimap atlas bake needs Pillow for BLP decode - "
    "run under: nix-shell -p python3Packages.pillow"
)


def require_pillow() -> None:
    if not HAVE_PILLOW:
        raise RuntimeError(PILLOW_REQUIRED)


def map_entries(
    index: dict[tuple[str, int, int], str], map_name: str
) -> dict[tuple[int, int], str]:
    name = map_name.lower()
    return {
        (a, b): md5_name
        for (mp, a, b), md5_name in index.items()
        if mp == name
    }


def tile_extents(
    entries: dict[tuple[int, int], str],
) -> tuple[int, int, int, int]:
    if not entries:
        raise RuntimeError("no minimap tiles in trs for this map")
    aa = [a for a, _ in entries]
    bb = [b for _, b in entries]
    return min(aa), max(aa), min(bb), max(bb)


def atlas_size(
    a_min: int, a_max: int, b_min: int, b_max: int, px_per_tile: int
) -> tuple[int, int]:
    width = (a_max - a_min + 1) * px_per_tile
    height = (b_max - b_min + 1) * px_per_tile
    return width, height


def open_tile(path: Path):
    """RGBA 256x256, or None if the file is missing / undecodable."""
    if not path.is_file():
        return None
    try:
        with Image.open(path) as src:
            image = src.convert("RGBA")
    except (OSError, ValueError, SyntaxError):
        return None
    if image.size != (mmask.TILE_PX, mmask.TILE_PX):
        raise RuntimeError(
            f"minimap tile {path.name} decoded at {image.size}, "
            f"expected ({mmask.TILE_PX}, {mmask.TILE_PX})"
        )
    return image


def stitch_atlas(
    entries: dict[tuple[int, int], str],
    tiles_dir: str | Path,
    px_per_tile: int,
    extents: tuple[int, int, int, int] | None = None,
):
    """Compose the continent atlas. Returns (image, placed, missing).

    Two distinct conventions — do not conflate them.

    Per-tile pixel mapping (world -> pixel WITHIN a tile): landmark-verified
    (Great Lift dock). Image row = x north->south, image col = y west->east.
    BLPs are already oriented this way; paste each tile as-is.

    Band arrangement (tile -> position in a continuous mosaic): seam-verified
    2026-08-12. Index A advances the horizontal axis (A is y-derived); index
    B advances the vertical axis (B is x-derived). A previous "verified
    convention" claim conflated these two; per-tile checks cannot catch
    band scrambling.

    tile (a, b) pastes at ((a - a_min) * px, (b - b_min) * px).
    Atlas width = aCount * px, height = bCount * px.
    """
    require_pillow()
    if px_per_tile < 1:
        raise ValueError("px_per_tile must be >= 1")
    a_min, a_max, b_min, b_max = (
        extents if extents is not None else tile_extents(entries)
    )
    width, height = atlas_size(a_min, a_max, b_min, b_max, px_per_tile)
    if width > MAX_ATLAS_DIM or height > MAX_ATLAS_DIM:
        raise RuntimeError(
            f"atlas {width}x{height} exceeds {MAX_ATLAS_DIM} on an axis"
        )
    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    tiles_dir = Path(tiles_dir)
    placed = 0
    missing = 0
    for a, b in sorted(entries):
        tile = open_tile(tiles_dir / entries[(a, b)])
        if tile is None:
            missing += 1
            continue
        if px_per_tile != mmask.TILE_PX:
            tile = tile.resize((px_per_tile, px_per_tile), Image.LANCZOS)
        x = (a - a_min) * px_per_tile
        y = (b - b_min) * px_per_tile
        atlas.paste(tile, (x, y))
        placed += 1
    return atlas, placed, missing


def atlas_metadata(
    map_name: str,
    px_per_tile: int,
    a_min: int,
    a_max: int,
    b_min: int,
    b_max: int,
    width: int,
    height: int,
) -> dict:
    return {
        "a_max": a_max,
        "a_min": a_min,
        "b_max": b_max,
        "b_min": b_min,
        "height": height,
        "map": map_name,
        "map_id": MAP_IDS[map_name],
        "px_per_tile": px_per_tile,
        "tile_yd": mmask.TILE_YD,
        "width": width,
    }


def bake_atlas(
    map_name: str,
    assets_dir: str | Path | None = None,
    px_per_tile: int = DEFAULT_PX_PER_TILE,
    out_dir: str | Path | None = None,
    trs_path: str | Path | None = None,
    tiles_dir: str | Path | None = None,
) -> dict:
    """Stitch one continent and write PNG + JSON. Returns the metadata dict."""
    require_pillow()
    map_name = map_name.lower()
    if map_name not in MAP_IDS:
        raise ValueError(f"map must be kalimdor or azeroth, got {map_name!r}")
    if px_per_tile < 1:
        raise ValueError("px_per_tile must be >= 1")
    assets = Path(assets_dir) if assets_dir is not None else mmask.DEFAULT_ASSETS_DIR
    trs = (
        Path(trs_path)
        if trs_path is not None
        else assets / "ui_dedicated" / "minimap" / "md5translate.trs"
    )
    tiles = (
        Path(tiles_dir)
        if tiles_dir is not None
        else assets / "textures" / "minimap"
    )
    dest = Path(out_dir) if out_dir is not None else DEFAULT_OUT_DIR
    entries = map_entries(mmask.parse_trs(trs), map_name)
    a_min, a_max, b_min, b_max = tile_extents(entries)
    atlas, placed, missing = stitch_atlas(
        entries, tiles, px_per_tile, extents=(a_min, a_max, b_min, b_max)
    )
    width, height = atlas.size
    meta = atlas_metadata(
        map_name, px_per_tile, a_min, a_max, b_min, b_max, width, height
    )
    dest.mkdir(parents=True, exist_ok=True)
    png_path = dest / f"minimap_atlas_{map_name}.png"
    json_path = dest / f"minimap_atlas_{map_name}.json"
    atlas.save(png_path, format="PNG")
    json_path.write_text(
        json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    nbytes = png_path.stat().st_size
    print(
        f"minimap atlas {map_name}: placed={placed} missing={missing} "
        f"{width}x{height} {nbytes} bytes",
        file=sys.stderr,
    )
    return meta


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--map", required=True, choices=sorted(MAP_IDS), help="continent"
    )
    parser.add_argument(
        "--assets-dir",
        type=Path,
        default=mmask.DEFAULT_ASSETS_DIR,
    )
    parser.add_argument(
        "--px-per-tile",
        type=int,
        default=DEFAULT_PX_PER_TILE,
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    bake_atlas(
        args.map,
        assets_dir=args.assets_dir,
        px_per_tile=args.px_per_tile,
        out_dir=args.out_dir,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
