#!/usr/bin/env python3
"""Road detection for vanilla 1.12 Kalimdor, straight off the painted ADT terrain.

Roads in 1.12 are not data, they are paint: a tile's MTEX names one or more
road tilesets (``Tileset\\Kalidar\\KalidarRoad.blp``,
``Tileset\\Felwood\\FelwoodRoad.blp``, ...) and each 33.33 yd MCNK sub-chunk
blends up to four of those textures through 64x64 MCAL alpha maps. A world
point is "on road" when a road-textured layer is painted at that alpha cell.

CALIBRATION (verified, do not re-derive by guessing)
----------------------------------------------------
Tile file name: ``kalimdor_<a>_<b>.adt`` with

    a = floor(32 - y / 533.3333)      # first index comes from world Y
    b = floor(32 - x / 533.3333)      # second index comes from world X

Tile north-west origin (its maximum x and y corner):

    tile_max_x = (32 - b) * 533.3333
    tile_max_y = (32 - a) * 533.3333

Sub-chunk selection (chunk position stored at MCNK header + 0x68 is the
chunk's own maximum-x / maximum-y corner, i.e. both axes count *down*):

    iy = floor((tile_max_x - x) / 33.3333)   # x axis -> header IndexY
    ix = floor((tile_max_y - y) / 33.3333)   # y axis -> header IndexX
    mcnk_array_index = iy * 16 + ix

Cell inside a chunk's 64x64 alpha map -- the first index strides by 64 and
counts down x, the second counts down y (same convention MCVT uses with a
stride of 17):

    cx = floor(((tile_max_x - iy*33.3333) - x) / 33.3333 * 64)
    cy = floor(((tile_max_y - ix*33.3333) - y) / 33.3333 * 64)
    alpha_index = cx * 64 + cy

How this was pinned down (2026-08-11):
  * Tile/chunk selection and the "position is the max corner" reading were
    confirmed against the MCNK header world position, which matches
    (tile_max_x - iy*33.33, tile_max_y - ix*33.33) exactly on every probe.
  * The full transform *including* both in-chunk axis directions was then
    validated by interpolating MCVT terrain heights at 228 VMaNGOS Detour
    navmesh waypoints across Ashenvale/Felwood: rms 1.02 yd, median 0.92 yd
    (the navmesh floats ~1 yd over terrain). All seven other row/column
    orderings score 12.8-25.0 yd rms, so the choice is unambiguous.
  * The MCAL orientation was cross-checked independently by cross-seam
    continuity of the painted road over tiles 35_19 and 36_29: this ordering
    scores seam-cost ~= interior-cost (ratio 1.10-1.16), every other ordering
    1.68-2.65 (visible 64-cell tearing).

Format notes worth remembering:
  * FourCCs are byte-reversed on disk; the file opens with "REVM" (MVER).
  * MCNK header sub-offsets (ofsLayer/ofsAlpha/ofsHeight/ofsLiquid) are relative
    to the start of the MCNK *chunk header* (the FourCC), and point AT the
    sub-chunk's own FourCC -- add 8 to reach its payload.
  * Never scan MCNK sub-chunks sequentially: MCNR carries 13 undocumented
    padding bytes that desynchronise a scan. Use the header offsets only.
  * Vanilla alpha maps are uncompressed 2048 bytes (64x64, 4 bits per cell,
    low nibble first). sizeAlpha counts the 8-byte MCAL header too, so a
    4-layer chunk reports 3*2048 + 8 = 6152.
  * Layer 0 is the base layer: full coverage, no alpha map.

Liquid (MCLQ) -- confirmed on Kalimdor hex 2026-08-11:
  * MCNK +0x60 ofsLiquid, +0x64 sizeLiquid. sizeLiquid > 8 means MCLQ present
    (size counts the 8-byte FourCC header; the on-disk MCLQ size field is 0).
  * MCNK flags liquid bits: river 0x4, ocean 0x8, magma 0x10. Ocean chunks often
    set 0x8|0x1 with a full 812-byte MCLQ (sea level height 0.0).
  * Payload after the FourCC header (sizeLiquid-8 bytes):
        float minHeight; float maxHeight;          // 8 bytes
        WaterVert verts[9*9];                      // 648 bytes
        uint8 tiles[8*8];                          // 64 bytes
        // then ~84 bytes trailing (often zero) -- ignored
    WaterVert = 4 bytes (depth/flow/light) + float height (world Z absolute).
    Magma uses a different 8-byte vertex; only water/ocean/river matter here.
  * tiles[i]: low nibble 0x0F = no liquid in that 8x8 cell; 0x41 is common
    ocean/coast paint (0x40 = fatigue bit on some data). Index is x-major then
    y, same axis directions as the 64x64 alpha map (count down x, then y from
    the chunk max corner). The 9x9 vertex grid shares that orientation.
  * MCVT heights are relative to MCNK position.z; MCLQ vertex heights are
    absolute world Z. depth = liquid_height - (position.z + mcvt_rel).
"""
from __future__ import annotations

import argparse
import math
import os
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, NamedTuple, Sequence

TILE_YD = 533.3333333333333
CHUNK_YD = TILE_YD / 16.0  # 33.3333 yd
ALPHA_DIM = 64
ALPHA_BYTES_4BIT = ALPHA_DIM * ALPHA_DIM // 2  # 2048
ALPHA_BYTES_8BIT = ALPHA_DIM * ALPHA_DIM  # 4096
MCNK_HEADER_SIZE = 128
LIQUID_DIM = 8  # 8x8 tile-flag grid per MCNK
LIQUID_VERT_DIM = 9  # 9x9 height vertices
MCVT_COUNT = 145  # 9*9 outer + 8*8 holes
# MCLQ payload layout (after FourCC+size)
MCLQ_HEADER_FLOATS = 8  # minHeight + maxHeight
MCLQ_VERT_BYTES = LIQUID_VERT_DIM * LIQUID_VERT_DIM * 8  # 648
MCLQ_TILE_BYTES = LIQUID_DIM * LIQUID_DIM  # 64
MCLQ_LAYER_BYTES = MCLQ_HEADER_FLOATS + MCLQ_VERT_BYTES + MCLQ_TILE_BYTES  # 720
# MCLY flags
LAYER_USE_ALPHA = 0x100
LAYER_ALPHA_COMPRESSED = 0x200
# MCNK header flags -- liquid type bits
MCNK_FLAG_RIVER = 0x4
MCNK_FLAG_OCEAN = 0x8
MCNK_FLAG_MAGMA = 0x10
# MCLQ tile flag: low nibble 0x0F means no liquid in that cell
MCLQ_TILE_NO_LIQUID = 0x0F

# A road layer counts as "on road" above this alpha (0-255).
ROAD_ALPHA_THRESHOLD = 64

DEFAULT_ADT_DIR = Path(
    os.environ.get(
        "VANILLA_WOW_ADT_DIR",
        "/home/monofuel/src/wow-coworld/local_data/player/assets-flat"
        "/world/maps/kalimdor",
    )
)


class RoadSample(NamedTuple):
    """(road?, road texture that won, alpha 0-255). Unpacks as a 3-tuple."""

    is_road: bool
    texture: str | None
    alpha: int


class WaterSample(NamedTuple):
    """(water?, liquid surface height, depth = height - ground). Unpacks as 3-tuple."""

    is_water: bool
    height: float
    depth: float


@dataclass
class LayerProbe:
    index: int
    texture_id: int
    texture: str
    flags: int
    alpha_offset: int
    alpha: int
    is_road: bool
    note: str = ""


@dataclass
class Probe:
    x: float
    y: float
    tile: tuple[int, int]
    chunk: tuple[int, int]
    chunk_index: int
    cell: tuple[int, int]
    alpha_index: int
    layers: list[LayerProbe] = field(default_factory=list)
    road_textures: list[str] = field(default_factory=list)

    @property
    def sample(self) -> RoadSample:
        best: LayerProbe | None = None
        for layer in self.layers:
            if not layer.is_road:
                continue
            if layer.index == 0:
                # Base layer road paint covers the whole chunk.
                return RoadSample(True, layer.texture, 255)
            if best is None or layer.alpha > best.alpha:
                best = layer
        if best is None:
            return RoadSample(False, None, 0)
        return RoadSample(best.alpha > ROAD_ALPHA_THRESHOLD, best.texture, best.alpha)


# --------------------------------------------------------------------------
# Pure transform math (no file access; unit tested on its own)
# --------------------------------------------------------------------------


def tile_indices(x: float, y: float) -> tuple[int, int]:
    """(a, b) of kalimdor_<a>_<b>.adt covering world point (x, y)."""
    return (
        int(math.floor(32.0 - y / TILE_YD)),
        int(math.floor(32.0 - x / TILE_YD)),
    )


def tile_origin(a: int, b: int) -> tuple[float, float]:
    """Maximum-x / maximum-y corner of tile kalimdor_<a>_<b>."""
    return ((32.0 - b) * TILE_YD, (32.0 - a) * TILE_YD)


def chunk_indices(x: float, y: float) -> tuple[int, int]:
    """(ix, iy) sub-chunk indices; ix counts down y, iy counts down x."""
    a, b = tile_indices(x, y)
    max_x, max_y = tile_origin(a, b)
    iy = int(math.floor((max_x - x) / CHUNK_YD))
    ix = int(math.floor((max_y - y) / CHUNK_YD))
    return (min(15, max(0, ix)), min(15, max(0, iy)))


def chunk_array_index(ix: int, iy: int) -> int:
    """Index of an MCNK in file order (matches header IndexX/IndexY)."""
    return iy * 16 + ix


def chunk_origin(a: int, b: int, ix: int, iy: int) -> tuple[float, float]:
    """Maximum-x / maximum-y corner of one sub-chunk."""
    max_x, max_y = tile_origin(a, b)
    return (max_x - iy * CHUNK_YD, max_y - ix * CHUNK_YD)


def cell_indices(x: float, y: float) -> tuple[int, int]:
    """(cx, cy) inside the 64x64 alpha map; cx counts down x, cy counts down y."""
    a, b = tile_indices(x, y)
    ix, iy = chunk_indices(x, y)
    origin_x, origin_y = chunk_origin(a, b, ix, iy)
    cx = int((origin_x - x) / CHUNK_YD * ALPHA_DIM)
    cy = int((origin_y - y) / CHUNK_YD * ALPHA_DIM)
    return (min(ALPHA_DIM - 1, max(0, cx)), min(ALPHA_DIM - 1, max(0, cy)))


def alpha_index(cx: int, cy: int) -> int:
    """Flat index into a 64x64 alpha map: x-major, then y."""
    return cx * ALPHA_DIM + cy


def liquid_cell_indices(x: float, y: float) -> tuple[int, int]:
    """(lx, ly) inside the 8x8 MCLQ tile-flag grid; same axes as alpha cells."""
    a, b = tile_indices(x, y)
    ix, iy = chunk_indices(x, y)
    origin_x, origin_y = chunk_origin(a, b, ix, iy)
    lx = int((origin_x - x) / CHUNK_YD * LIQUID_DIM)
    ly = int((origin_y - y) / CHUNK_YD * LIQUID_DIM)
    return (min(LIQUID_DIM - 1, max(0, lx)), min(LIQUID_DIM - 1, max(0, ly)))


def liquid_tile_index(lx: int, ly: int) -> int:
    """Flat index into an 8x8 MCLQ tile-flag grid: x-major, then y."""
    return lx * LIQUID_DIM + ly


def liquid_vert_coords(x: float, y: float) -> tuple[float, float]:
    """Fractional 9x9 vertex coords (0..8) from the chunk max corner."""
    a, b = tile_indices(x, y)
    ix, iy = chunk_indices(x, y)
    origin_x, origin_y = chunk_origin(a, b, ix, iy)
    vx = (origin_x - x) / CHUNK_YD * (LIQUID_VERT_DIM - 1)
    vy = (origin_y - y) / CHUNK_YD * (LIQUID_VERT_DIM - 1)
    return (
        min(float(LIQUID_VERT_DIM - 1), max(0.0, vx)),
        min(float(LIQUID_VERT_DIM - 1), max(0.0, vy)),
    )


def is_road_texture(name: str) -> bool:
    return "road" in name.lower()


def mclq_tile_has_liquid(flag: int) -> bool:
    """True when the MCLQ 8x8 tile flag marks liquid (low nibble != 0x0F)."""
    return (flag & 0x0F) != MCLQ_TILE_NO_LIQUID


# --------------------------------------------------------------------------
# ADT parsing
# --------------------------------------------------------------------------


def iter_chunks(buf: bytes, start: int = 0) -> Iterator[tuple[str, int, int]]:
    """Yield (fourcc, payload_offset, size). FourCCs are reversed on disk."""
    pos = start
    end = len(buf)
    while pos + 8 <= end:
        magic = buf[pos : pos + 4][::-1].decode("ascii", "replace")
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        yield magic, pos + 8, size
        pos += 8 + size


def _decode_alpha_map(
    buf: bytes, start: int, budget: int, flags: int
) -> tuple[bytes, str]:
    """Return (4096 bytes of 0-255 alpha, note). Defensive about the variants."""
    if budget >= ALPHA_BYTES_4BIT and not (flags & LAYER_ALPHA_COMPRESSED):
        raw = buf[start : start + ALPHA_BYTES_4BIT]
        out = bytearray(ALPHA_BYTES_8BIT)
        for i, byte in enumerate(raw):
            out[2 * i] = (byte & 0x0F) * 17
            out[2 * i + 1] = (byte >> 4) * 17
        return bytes(out), ""
    if flags & LAYER_ALPHA_COMPRESSED:
        # Not seen in vanilla Kalimdor, but decode the RLE form rather than
        # silently reporting "no road here".
        out = bytearray()
        pos = start
        limit = start + budget
        while len(out) < ALPHA_BYTES_8BIT and pos < limit:
            control = buf[pos]
            pos += 1
            count = control & 0x7F
            if control & 0x80:
                if pos >= limit:
                    break
                out.extend(bytes([buf[pos]]) * count)
                pos += 1
            else:
                out.extend(buf[pos : pos + count])
                pos += count
        if len(out) < ALPHA_BYTES_8BIT:
            out.extend(bytes(ALPHA_BYTES_8BIT - len(out)))
            return bytes(out[:ALPHA_BYTES_8BIT]), "truncated compressed alpha"
        return bytes(out[:ALPHA_BYTES_8BIT]), "compressed alpha"
    return bytes(ALPHA_BYTES_8BIT), f"unreadable alpha (budget={budget})"


@dataclass
class Layer:
    index: int
    texture_id: int
    flags: int
    alpha_offset: int


@dataclass
class Chunk:
    offset: int
    n_layers: int
    layers: list[Layer]
    mcal_start: int
    mcal_size: int
    position: tuple[float, float, float]
    flags: int = 0
    mcvt_start: int = 0  # payload start (past MCVT FourCC), 0 if missing
    mclq_start: int = 0  # payload start (past MCLQ FourCC), 0 if missing
    mclq_size: int = 0  # payload bytes (sizeLiquid - 8)
    size_liquid: int = 0  # raw MCNK sizeLiquid field


@dataclass
class WaterProbe:
    x: float
    y: float
    tile: tuple[int, int]
    chunk: tuple[int, int]
    chunk_index: int
    liquid_cell: tuple[int, int]
    mcnk_flags: int
    size_liquid: int
    min_height: float | None
    max_height: float | None
    tile_flag: int | None
    liquid_height: float | None
    ground_z: float | None
    sample: WaterSample


class Tile:
    """One parsed ADT: texture list plus the 256 MCNK layer/alpha descriptors."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._buf = path.read_bytes()
        self.textures: list[str] = []
        self.chunks: list[Chunk] = []
        self._alpha_cache: dict[tuple[int, int], tuple[bytes, str]] = {}
        self._mcvt_cache: dict[int, tuple[float, ...]] = {}
        self._mclq_cache: dict[int, tuple[float, float, tuple[float, ...], bytes] | None] = {}
        self._parse()
        self.road_texture_ids = frozenset(
            i for i, name in enumerate(self.textures) if is_road_texture(name)
        )

    def _parse(self) -> None:
        buf = self._buf
        mcnk_offsets: list[int] = []
        for magic, off, size in iter_chunks(buf):
            if magic == "MTEX":
                self.textures = [
                    part.decode("ascii", "replace").strip()
                    for part in buf[off : off + size].split(b"\0")
                    if part
                ]
            elif magic == "MCNK":
                mcnk_offsets.append(off)
        for off in mcnk_offsets:
            self.chunks.append(self._parse_chunk(off))

    def _parse_chunk(self, off: int) -> Chunk:
        buf = self._buf
        flags = struct.unpack_from("<I", buf, off)[0]
        header = struct.unpack_from("<16I", buf, off)
        n_layers = header[3]
        ofs_height = header[5]
        ofs_layer = header[7]
        ofs_alpha = header[9]
        size_alpha = header[10]
        ofs_liquid = struct.unpack_from("<I", buf, off + 0x60)[0]
        size_liquid = struct.unpack_from("<I", buf, off + 0x64)[0]
        pos = struct.unpack_from("<3f", buf, off + 0x68)
        # Sub-chunk offsets are relative to the MCNK chunk header (the FourCC),
        # not to the 128-byte MCNK header that follows it.
        base = off - 8
        layers: list[Layer] = []
        if n_layers and buf[base + ofs_layer : base + ofs_layer + 4][::-1] == b"MCLY":
            entry = base + ofs_layer + 8
            for index in range(n_layers):
                tid, layer_flags, alpha_off, _effect = struct.unpack_from(
                    "<4I", buf, entry + index * 16
                )
                layers.append(Layer(index, tid, layer_flags, alpha_off))
        mcal_start = 0
        mcal_size = 0
        if size_alpha > 8 and buf[base + ofs_alpha : base + ofs_alpha + 4][::-1] == (
            b"MCAL"
        ):
            mcal_start = base + ofs_alpha + 8
            mcal_size = size_alpha - 8
        mcvt_start = 0
        if ofs_height and buf[base + ofs_height : base + ofs_height + 4][::-1] == b"MCVT":
            mcvt_start = base + ofs_height + 8
        mclq_start = 0
        mclq_size = 0
        if size_liquid > 8 and buf[base + ofs_liquid : base + ofs_liquid + 4][::-1] == (
            b"MCLQ"
        ):
            mclq_start = base + ofs_liquid + 8
            mclq_size = size_liquid - 8
        return Chunk(
            off,
            n_layers,
            layers,
            mcal_start,
            mcal_size,
            pos,
            flags=flags,
            mcvt_start=mcvt_start,
            mclq_start=mclq_start,
            mclq_size=mclq_size,
            size_liquid=size_liquid,
        )

    def alpha_map(self, chunk_index: int, layer_index: int) -> tuple[bytes, str]:
        key = (chunk_index, layer_index)
        cached = self._alpha_cache.get(key)
        if cached is not None:
            return cached
        chunk = self.chunks[chunk_index]
        layer = chunk.layers[layer_index]
        if not chunk.mcal_size:
            return bytes(ALPHA_BYTES_8BIT), "no MCAL"
        budget = chunk.mcal_size - layer.alpha_offset
        if budget <= 0:
            return bytes(ALPHA_BYTES_8BIT), "alpha offset past MCAL"
        result = _decode_alpha_map(
            self._buf, chunk.mcal_start + layer.alpha_offset, budget, layer.flags
        )
        self._alpha_cache[key] = result
        return result

    def mcvt_heights(self, chunk_index: int) -> tuple[float, ...] | None:
        """145 MCVT relative heights, or None if the chunk has no MCVT."""
        cached = self._mcvt_cache.get(chunk_index)
        if cached is not None:
            return cached
        chunk = self.chunks[chunk_index]
        if not chunk.mcvt_start:
            return None
        end = chunk.mcvt_start + MCVT_COUNT * 4
        if end > len(self._buf):
            return None
        heights = struct.unpack_from(f"<{MCVT_COUNT}f", self._buf, chunk.mcvt_start)
        self._mcvt_cache[chunk_index] = heights
        return heights

    def ground_height(self, chunk_index: int, x: float, y: float) -> float | None:
        """World Z of the MCVT surface at (x, y); None if unreadable."""
        heights = self.mcvt_heights(chunk_index)
        if heights is None:
            return None
        chunk = self.chunks[chunk_index]
        a, b = tile_indices(x, y)
        ix, iy = chunk_indices(x, y)
        origin_x, origin_y = chunk_origin(a, b, ix, iy)
        fx = (origin_x - x) / CHUNK_YD
        fy = (origin_y - y) / CHUNK_YD
        # Outer 9x9 grid: vertex (i=y, j=x) lives at heights[i * 17 + j].
        gx = min(8.0, max(0.0, fx * 8.0))
        gy = min(8.0, max(0.0, fy * 8.0))
        j0 = min(7, int(math.floor(gx)))
        i0 = min(7, int(math.floor(gy)))
        tx = gx - j0
        ty = gy - i0

        def outer(i: int, j: int) -> float:
            return heights[i * 17 + j]

        h00 = outer(i0, j0)
        h10 = outer(i0, j0 + 1)
        h01 = outer(i0 + 1, j0)
        h11 = outer(i0 + 1, j0 + 1)
        rel = (
            h00 * (1.0 - tx) * (1.0 - ty)
            + h10 * tx * (1.0 - ty)
            + h01 * (1.0 - tx) * ty
            + h11 * tx * ty
        )
        return chunk.position[2] + rel

    def mclq_layer(
        self, chunk_index: int
    ) -> tuple[float, float, tuple[float, ...], bytes] | None:
        """(min_h, max_h, 81 vertex heights, 64 tile flags) or None."""
        if chunk_index in self._mclq_cache:
            return self._mclq_cache[chunk_index]
        chunk = self.chunks[chunk_index]
        if chunk.mclq_size < MCLQ_LAYER_BYTES:
            self._mclq_cache[chunk_index] = None
            return None
        start = chunk.mclq_start
        buf = self._buf
        min_h, max_h = struct.unpack_from("<2f", buf, start)
        verts: list[float] = []
        vbase = start + MCLQ_HEADER_FLOATS
        for i in range(LIQUID_VERT_DIM * LIQUID_VERT_DIM):
            # WaterVert: 4 bytes depth/flow + float height (absolute world Z).
            h = struct.unpack_from("<f", buf, vbase + i * 8 + 4)[0]
            verts.append(h)
        tbase = vbase + MCLQ_VERT_BYTES
        tiles = bytes(buf[tbase : tbase + MCLQ_TILE_BYTES])
        result = (min_h, max_h, tuple(verts), tiles)
        self._mclq_cache[chunk_index] = result
        return result

    def liquid_height(self, chunk_index: int, x: float, y: float) -> float | None:
        """Bilinear MCLQ surface height (world Z), or None if no layer."""
        layer = self.mclq_layer(chunk_index)
        if layer is None:
            return None
        _min_h, _max_h, verts, _tiles = layer
        vx, vy = liquid_vert_coords(x, y)
        j0 = min(7, int(math.floor(vx)))
        i0 = min(7, int(math.floor(vy)))
        tx = vx - j0
        ty = vy - i0

        def vert(i: int, j: int) -> float:
            return verts[i * LIQUID_VERT_DIM + j]

        h00, h10 = vert(i0, j0), vert(i0, j0 + 1)
        h01, h11 = vert(i0 + 1, j0), vert(i0 + 1, j0 + 1)
        # FLT_MAX marks missing magma/slime verts -- fall back to nearest finite.
        candidates = (h00, h10, h01, h11)
        if not all(math.isfinite(h) and abs(h) < 1.0e30 for h in candidates):
            finite = [h for h in candidates if math.isfinite(h) and abs(h) < 1.0e30]
            if not finite:
                return None
            return finite[0]
        return (
            h00 * (1.0 - tx) * (1.0 - ty)
            + h10 * tx * (1.0 - ty)
            + h01 * (1.0 - tx) * ty
            + h11 * tx * ty
        )


class RoadMask:
    """is_road() / is_water() over a directory of Kalimdor ADTs, with tile caching."""

    def __init__(self, adt_dir: Path | str = DEFAULT_ADT_DIR) -> None:
        self.adt_dir = Path(adt_dir)
        self._tiles: dict[tuple[int, int], Tile | None] = {}

    def tile_path(self, a: int, b: int) -> Path:
        return self.adt_dir / f"kalimdor_{a}_{b}.adt"

    def tile(self, a: int, b: int) -> Tile | None:
        key = (a, b)
        if key not in self._tiles:
            path = self.tile_path(a, b)
            self._tiles[key] = Tile(path) if path.is_file() else None
        return self._tiles[key]

    def probe(self, x: float, y: float) -> Probe:
        a, b = tile_indices(x, y)
        ix, iy = chunk_indices(x, y)
        index = chunk_array_index(ix, iy)
        cx, cy = cell_indices(x, y)
        probe = Probe(
            x=x,
            y=y,
            tile=(a, b),
            chunk=(ix, iy),
            chunk_index=index,
            cell=(cx, cy),
            alpha_index=alpha_index(cx, cy),
        )
        tile = self.tile(a, b)
        if tile is None or index >= len(tile.chunks):
            return probe
        probe.road_textures = [tile.textures[i] for i in sorted(tile.road_texture_ids)]
        chunk = tile.chunks[index]
        for layer in chunk.layers:
            name = (
                tile.textures[layer.texture_id]
                if layer.texture_id < len(tile.textures)
                else f"<texture {layer.texture_id}>"
            )
            road = layer.texture_id in tile.road_texture_ids
            note = ""
            if layer.index == 0:
                alpha = 255
            else:
                data, note = tile.alpha_map(index, layer.index)
                alpha = data[probe.alpha_index]
            probe.layers.append(
                LayerProbe(
                    index=layer.index,
                    texture_id=layer.texture_id,
                    texture=name,
                    flags=layer.flags,
                    alpha_offset=layer.alpha_offset,
                    alpha=alpha,
                    is_road=road,
                    note=note,
                )
            )
        return probe

    def is_road(self, x: float, y: float) -> RoadSample:
        return self.probe(x, y).sample

    def water_probe(self, x: float, y: float) -> WaterProbe:
        a, b = tile_indices(x, y)
        ix, iy = chunk_indices(x, y)
        index = chunk_array_index(ix, iy)
        lx, ly = liquid_cell_indices(x, y)
        empty = WaterProbe(
            x=x,
            y=y,
            tile=(a, b),
            chunk=(ix, iy),
            chunk_index=index,
            liquid_cell=(lx, ly),
            mcnk_flags=0,
            size_liquid=0,
            min_height=None,
            max_height=None,
            tile_flag=None,
            liquid_height=None,
            ground_z=None,
            sample=WaterSample(False, 0.0, 0.0),
        )
        tile = self.tile(a, b)
        if tile is None or index >= len(tile.chunks):
            return empty
        chunk = tile.chunks[index]
        ground_z = tile.ground_height(index, x, y)
        layer = tile.mclq_layer(index)
        if layer is None:
            return WaterProbe(
                x=x,
                y=y,
                tile=(a, b),
                chunk=(ix, iy),
                chunk_index=index,
                liquid_cell=(lx, ly),
                mcnk_flags=chunk.flags,
                size_liquid=chunk.size_liquid,
                min_height=None,
                max_height=None,
                tile_flag=None,
                liquid_height=None,
                ground_z=ground_z,
                sample=WaterSample(False, 0.0, 0.0),
            )
        min_h, max_h, _verts, tiles = layer
        flag = tiles[liquid_tile_index(lx, ly)]
        height = tile.liquid_height(index, x, y)
        wet = mclq_tile_has_liquid(flag) and height is not None
        if wet and height is not None:
            depth = height - ground_z if ground_z is not None else 0.0
            sample = WaterSample(True, height, depth)
        else:
            sample = WaterSample(False, height if height is not None else 0.0, 0.0)
        return WaterProbe(
            x=x,
            y=y,
            tile=(a, b),
            chunk=(ix, iy),
            chunk_index=index,
            liquid_cell=(lx, ly),
            mcnk_flags=chunk.flags,
            size_liquid=chunk.size_liquid,
            min_height=min_h,
            max_height=max_h,
            tile_flag=flag,
            liquid_height=height,
            ground_z=ground_z,
            sample=sample,
        )

    def is_water(self, x: float, y: float) -> WaterSample:
        return self.water_probe(x, y).sample

    def nearest_road(
        self, x: float, y: float, radius: float = 60.0, step: float = 1.0
    ) -> tuple[float, float, float, str] | None:
        """Closest road-positive sample within `radius` yd: (dist, x, y, texture)."""
        best: tuple[float, float, float, str] | None = None
        steps = int(radius / step)
        for i in range(-steps, steps + 1):
            for j in range(-steps, steps + 1):
                px, py = x + i * step, y + j * step
                dist = math.hypot(px - x, py - y)
                if dist > radius or (best is not None and dist >= best[0]):
                    continue
                sample = self.is_road(px, py)
                if sample.is_road:
                    best = (dist, px, py, sample.texture or "")
        return best


_DEFAULT_MASK: RoadMask | None = None


def is_road(x: float, y: float) -> RoadSample:
    """(bool, texture|None, alpha) for a Kalimdor world point."""
    global _DEFAULT_MASK
    if _DEFAULT_MASK is None:
        _DEFAULT_MASK = RoadMask()
    return _DEFAULT_MASK.is_road(x, y)


def is_water(x: float, y: float) -> WaterSample:
    """(bool, height, depth) for a Kalimdor world point."""
    global _DEFAULT_MASK
    if _DEFAULT_MASK is None:
        _DEFAULT_MASK = RoadMask()
    return _DEFAULT_MASK.is_water(x, y)


# --------------------------------------------------------------------------
# Leg / grid sampling
# --------------------------------------------------------------------------


class LegSample(NamedTuple):
    x: float
    y: float
    distance: float
    sample: RoadSample


@dataclass
class LegReport:
    samples: list[LegSample]
    length: float

    @property
    def on_road_fraction(self) -> float:
        if not self.samples:
            return 0.0
        hits = sum(1 for s in self.samples if s.sample.is_road)
        return hits / len(self.samples)

    def off_road_spans(self) -> list[tuple[float, float, float]]:
        """Contiguous off-road runs as (start_distance, end_distance, length)."""
        spans: list[tuple[float, float, float]] = []
        run_start: float | None = None
        prev = 0.0
        for s in self.samples:
            if not s.sample.is_road:
                if run_start is None:
                    run_start = s.distance
                prev = s.distance
            elif run_start is not None:
                spans.append((run_start, prev, prev - run_start))
                run_start = None
        if run_start is not None:
            spans.append((run_start, prev, prev - run_start))
        return spans


def sample_leg(
    mask: RoadMask, x0: float, y0: float, x1: float, y1: float, step: float
) -> LegReport:
    length = math.hypot(x1 - x0, y1 - y0)
    count = max(1, int(length / step))
    samples: list[LegSample] = []
    for i in range(count + 1):
        t = min(1.0, (i * step) / length) if length > 0 else 0.0
        px = x0 + (x1 - x0) * t
        py = y0 + (y1 - y0) * t
        samples.append(LegSample(px, py, t * length, mask.is_road(px, py)))
    return LegReport(samples, length)


def grid_points(
    x0: float, y0: float, x1: float, y1: float, step: float
) -> Iterator[tuple[float, float]]:
    lo_x, hi_x = sorted((x0, x1))
    lo_y, hi_y = sorted((y0, y1))
    nx = int((hi_x - lo_x) / step)
    ny = int((hi_y - lo_y) / step)
    for i in range(nx + 1):
        for j in range(ny + 1):
            yield (lo_x + i * step, lo_y + j * step)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def cmd_probe(mask: RoadMask, args: argparse.Namespace) -> int:
    probe = mask.probe(args.x, args.y)
    sample = probe.sample
    a, b = probe.tile
    ix, iy = probe.chunk
    cx, cy = probe.cell
    origin = chunk_origin(a, b, ix, iy)
    verdict = "ROAD" if sample.is_road else "off-road"
    print(f"({args.x:.2f}, {args.y:.2f}) -> {verdict}")
    print(f"  texture={sample.texture} alpha={sample.alpha}")
    print(
        f"  tile=kalimdor_{a}_{b}.adt chunk=(ix={ix}, iy={iy}) "
        f"index={probe.chunk_index} cell=(cx={cx}, cy={cy}) "
        f"alpha_index={probe.alpha_index}"
    )
    print(f"  chunk max corner=({origin[0]:.3f}, {origin[1]:.3f})")
    if not probe.layers:
        print("  (no layers -- tile missing or unparsed)")
        return 0
    print(f"  road tilesets in tile: {probe.road_textures or 'none'}")
    for layer in probe.layers:
        tag = " ROAD" if layer.is_road else ""
        note = f" note={layer.note}" if layer.note else ""
        print(
            f"  layer{layer.index} tex={layer.texture_id} ({layer.texture}) "
            f"flags=0x{layer.flags:x} ofsAlpha={layer.alpha_offset} "
            f"alpha={layer.alpha}{tag}{note}"
        )
    if not sample.is_road and args.nearest:
        near = mask.nearest_road(args.x, args.y, radius=args.nearest)
        if near is None:
            print(f"  nearest road: none within {args.nearest:.0f} yd")
        else:
            dist, nx, ny, tex = near
            print(
                f"  nearest road: {dist:.1f} yd at ({nx:.1f}, {ny:.1f}) [{tex}]"
            )
    return 0


def cmd_leg(mask: RoadMask, args: argparse.Namespace) -> int:
    report = sample_leg(mask, args.x0, args.y0, args.x1, args.y1, args.step)
    print(
        f"leg ({args.x0:.1f}, {args.y0:.1f}) -> ({args.x1:.1f}, {args.y1:.1f}) "
        f"length={report.length:.1f} yd step={args.step:.1f} yd "
        f"samples={len(report.samples)}"
    )
    print(f"on-road fraction: {report.on_road_fraction * 100:.1f}%")
    spans = report.off_road_spans()
    if not spans:
        print("off-road spans: none")
    else:
        print(f"off-road spans: {len(spans)}")
        for start, end, length in spans:
            sx, sy = _point_at(args, start, report.length)
            ex, ey = _point_at(args, end, report.length)
            print(
                f"  {start:7.1f}..{end:7.1f} yd ({length:6.1f} yd) "
                f"({sx:.1f}, {sy:.1f}) -> ({ex:.1f}, {ey:.1f})"
            )
    if args.verbose:
        for s in report.samples:
            mark = "ROAD" if s.sample.is_road else "----"
            print(
                f"  {s.distance:7.1f} ({s.x:8.1f}, {s.y:9.1f}) {mark} "
                f"alpha={s.sample.alpha:3d} {s.sample.texture or ''}"
            )
    return 0


def _point_at(
    args: argparse.Namespace, distance: float, length: float
) -> tuple[float, float]:
    if length <= 0.0:
        return (args.x0, args.y0)
    t = distance / length
    return (args.x0 + (args.x1 - args.x0) * t, args.y0 + (args.y1 - args.y0) * t)


def cmd_dump(mask: RoadMask, args: argparse.Namespace) -> int:
    hits = 0
    for px, py in grid_points(args.x0, args.y0, args.x1, args.y1, args.step):
        sample = mask.is_road(px, py)
        if sample.is_road:
            hits += 1
            print(f"{px:.2f} {py:.2f} {sample.texture}")
    if hits == 0:
        print("# no road-positive samples in range", file=sys.stderr)
    return 0


def _liquid_type_name(flags: int) -> str:
    parts: list[str] = []
    if flags & MCNK_FLAG_RIVER:
        parts.append("river")
    if flags & MCNK_FLAG_OCEAN:
        parts.append("ocean")
    if flags & MCNK_FLAG_MAGMA:
        parts.append("magma")
    return "+".join(parts) if parts else "none"


def cmd_water_probe(mask: RoadMask, args: argparse.Namespace) -> int:
    probe = mask.water_probe(args.x, args.y)
    sample = probe.sample
    a, b = probe.tile
    ix, iy = probe.chunk
    lx, ly = probe.liquid_cell
    verdict = "WATER" if sample.is_water else "dry"
    print(f"({args.x:.2f}, {args.y:.2f}) -> {verdict}")
    print(
        f"  height={sample.height:.4f} depth={sample.depth:.4f} "
        f"ground_z={probe.ground_z if probe.ground_z is not None else 'n/a'}"
    )
    print(
        f"  tile=kalimdor_{a}_{b}.adt chunk=(ix={ix}, iy={iy}) "
        f"index={probe.chunk_index} liquid_cell=(lx={lx}, ly={ly})"
    )
    print(
        f"  mcnk_flags=0x{probe.mcnk_flags:x} ({_liquid_type_name(probe.mcnk_flags)}) "
        f"sizeLiquid={probe.size_liquid}"
    )
    if probe.min_height is not None:
        print(
            f"  MCLQ min={probe.min_height:.4f} max={probe.max_height:.4f} "
            f"tile_flag=0x{probe.tile_flag:02x} liquid_height={probe.liquid_height}"
        )
    else:
        print("  (no MCLQ layer)")
    return 0


def cmd_water_dump(mask: RoadMask, args: argparse.Namespace) -> int:
    hits = 0
    for px, py in grid_points(args.x0, args.y0, args.x1, args.y1, args.step):
        sample = mask.is_water(px, py)
        if sample.is_water:
            hits += 1
            print(f"{px:.2f} {py:.2f} {sample.height:.4f} {sample.depth:.4f}")
    if hits == 0:
        print("# no water-positive samples in range", file=sys.stderr)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--adt-dir", type=Path, default=DEFAULT_ADT_DIR)
    sub = parser.add_subparsers(dest="command", required=True)

    p_probe = sub.add_parser("probe", help="Road verdict plus tile/chunk/cell debug")
    p_probe.add_argument("x", type=float)
    p_probe.add_argument("y", type=float)
    p_probe.add_argument(
        "--nearest",
        type=float,
        default=0.0,
        metavar="RADIUS",
        help="If off-road, search this radius (yd) for the nearest paint",
    )
    p_probe.set_defaults(func=cmd_probe)

    p_leg = sub.add_parser("leg", help="On-road fraction and off-road spans")
    for name in ("x0", "y0", "x1", "y1"):
        p_leg.add_argument(name, type=float)
    p_leg.add_argument("--step", type=float, default=5.0)
    p_leg.add_argument("--verbose", action="store_true")
    p_leg.set_defaults(func=cmd_leg)

    p_dump = sub.add_parser("dump", help="Print road-positive grid samples")
    for name in ("x0", "y0", "x1", "y1"):
        p_dump.add_argument(name, type=float)
    p_dump.add_argument("--step", type=float, default=5.0)
    p_dump.set_defaults(func=cmd_dump)

    p_wprobe = sub.add_parser(
        "water-probe", help="Water verdict plus chunk/MCLQ/ground debug"
    )
    p_wprobe.add_argument("x", type=float)
    p_wprobe.add_argument("y", type=float)
    p_wprobe.set_defaults(func=cmd_water_probe)

    p_wdump = sub.add_parser("water-dump", help="Print water-positive grid samples")
    for name in ("x0", "y0", "x1", "y1"):
        p_wdump.add_argument(name, type=float)
    p_wdump.add_argument("--step", type=float, default=5.0)
    p_wdump.set_defaults(func=cmd_water_dump)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    if not args.adt_dir.is_dir():
        print(f"SKIP missing ADT dir: {args.adt_dir}", file=sys.stderr)
        return 0
    return int(args.func(RoadMask(args.adt_dir), args))


if __name__ == "__main__":
    sys.exit(main())
