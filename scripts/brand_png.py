"""PNG reading, writing, resampling, and labelling for the brand generators.

Two generators need the same four operations: decode an 8-bit RGBA PNG,
resample an alpha plane by exact area coverage, label the connected runs of a
pixel mask, and write an 8-bit RGBA PNG. They live here once rather than twice.
Nothing else is shared: each generator owns its own geometry, and each builds
its own mask before asking for labels.

Everything is stdlib. This Mac has CommandLineTools only, so there is no
Pillow, no ImageMagick, and no SVG rasterizer whose output could be trusted to
be byte-identical across machines. `sips` can resize but writes its own
metadata, which is the one thing a byte-for-byte gate cannot tolerate.

Every operation is pure arithmetic over the input bytes, so the output is
deterministic and `scripts/check_brand_images.sh` can regenerate and diff.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path
from typing import NamedTuple

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class Failure(Exception):
    """A build failure with an operator-readable sentence."""


class Region(NamedTuple):
    """One connected run of selected pixels: its box, centroid and members.

    `members` are flat `y * width + x` indices, so a caller can ask whether a
    pixel belongs to a region without carrying a second plane around.
    """

    area: int
    left: int
    top: int
    right: int
    bottom: int
    centre_x: float
    centre_y: float
    members: frozenset[int]


def read_rgba(path: Path) -> tuple[int, int, bytes]:
    """Decode an 8-bit, non-interlaced, truecolour-with-alpha PNG.

    Anything else is refused rather than guessed at: a generator that quietly
    accepted a palette image would write a mark nobody drew.
    """
    data = path.read_bytes()
    if data[:8] != PNG_SIGNATURE:
        raise Failure(f"{path} is not a PNG")

    width = height = 0
    compressed = bytearray()
    position = 8
    while position < len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            if (depth, colour, interlace) != (8, 6, 0):
                raise Failure(
                    f"{path} is depth {depth}, colour type {colour}, interlace {interlace}; "
                    "this reader takes 8-bit RGBA only"
                )
        if kind == b"IDAT":
            compressed += payload
        position += length + 12

    if width == 0 or height == 0:
        raise Failure(f"{path} has no IHDR")

    return width, height, _unfilter(zlib.decompress(bytes(compressed)), width, height)


def _unfilter(raw: bytes, width: int, height: int) -> bytes:
    """Undo the five PNG scanline filters. One pass, one row of history."""
    stride = width * 4
    pixels = bytearray(width * height * 4)
    previous = bytearray(stride)
    position = 0

    for row in range(height):
        method = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride
        _unfilter_line(method, line, previous, stride)
        pixels[row * stride:(row + 1) * stride] = line
        previous = line

    return bytes(pixels)


def _unfilter_line(method: int, line: bytearray, previous: bytearray, stride: int) -> None:
    """One scanline, in place. Split out so `_unfilter` stays one screen."""
    if method == 0:
        return
    if method == 1:
        for index in range(4, stride):
            line[index] = (line[index] + line[index - 4]) & 0xFF
        return
    if method == 2:
        for index in range(stride):
            line[index] = (line[index] + previous[index]) & 0xFF
        return
    if method == 3:
        for index in range(stride):
            left = line[index - 4] if index >= 4 else 0
            line[index] = (line[index] + ((left + previous[index]) >> 1)) & 0xFF
        return
    if method == 4:
        for index in range(stride):
            left = line[index - 4] if index >= 4 else 0
            up = previous[index]
            corner = previous[index - 4] if index >= 4 else 0
            line[index] = (line[index] + _paeth(left, up, corner)) & 0xFF
        return

    raise Failure(f"unknown PNG filter {method}")


def _paeth(left: int, up: int, corner: int) -> int:
    estimate = left + up - corner
    to_left = abs(estimate - left)
    to_up = abs(estimate - up)
    to_corner = abs(estimate - corner)
    if to_left <= to_up and to_left <= to_corner:
        return left

    return up if to_up <= to_corner else corner


def alpha_plane(width: int, height: int, pixels: bytes) -> list[list[int]]:
    """The alpha channel as rows of 0-255, which is all a silhouette is."""
    return [list(pixels[(row * width) * 4 + 3::4][:width]) for row in range(height)]


def resample_alpha(plane: list[list[int]], size: int) -> list[list[float]]:
    """Area-average a square alpha plane down to `size` by `size`, as 0-1.

    Exact box coverage, not nearest neighbour: a silhouette shrunk to 16 points
    by point sampling loses whole lobes, and the edge it keeps is jagged.
    Upscaling is refused because a mark drawn larger than its master is a blur
    that reads as a rendering fault.
    """
    source = len(plane)
    if size > source:
        raise Failure(f"cannot resample {source} up to {size}; supply a larger master")

    scale = source / size
    rows: list[list[float]] = []
    for out_y in range(size):
        top = out_y * scale
        bottom = top + scale
        row: list[float] = []
        for out_x in range(size):
            left = out_x * scale
            right = left + scale
            row.append(_box_average(plane, top, bottom, left, right) / 255)
        rows.append(row)

    return rows


def _box_average(plane: list[list[int]], top: float, bottom: float, left: float, right: float) -> float:
    """The alpha inside one source rectangle, weighted by partial coverage."""
    total = 0.0
    source_y = int(top)
    while source_y < bottom:
        height = min(source_y + 1, bottom) - max(source_y, top)
        line = plane[source_y]
        source_x = int(left)
        while source_x < right:
            width = min(source_x + 1, right) - max(source_x, left)
            total += line[source_x] * width * height
            source_x += 1
        source_y += 1

    return total / ((bottom - top) * (right - left))


def regions(mask: bytearray, width: int, height: int) -> list[Region]:
    """Every connected run of set pixels in `mask`, eight-connected.

    Eight-connected because a one-pixel diagonal step is how an antialiased
    stroke joins itself, and splitting one eye into two on that would be a
    labelling artefact rather than anything in the drawing.

    The caller decides what "set" means. Keeping the threshold out here is what
    lets one generator label by luminance and the other by alpha.
    """
    if len(mask) != width * height:
        raise Failure(f"mask is {len(mask)} pixels for a {width} by {height} image")

    seen = bytearray(width * height)
    found: list[Region] = []
    for start in range(width * height):
        if not mask[start] or seen[start]:
            continue
        found.append(_grow(mask, seen, width, height, start))

    return found


def _grow(mask: bytearray, seen: bytearray, width: int, height: int, start: int) -> Region:
    """One region, flood filled from `start`. Explicit stack, no recursion."""
    seen[start] = 1
    stack = [start]
    members: list[int] = []
    while stack:
        index = stack.pop()
        members.append(index)
        stack += _unseen_neighbours(mask, seen, width, height, index)

    xs = [index % width for index in members]
    ys = [index // width for index in members]

    return Region(
        len(members),
        min(xs), min(ys), max(xs), max(ys),
        sum(xs) / len(members), sum(ys) / len(members),
        frozenset(members),
    )


def _unseen_neighbours(mask: bytearray, seen: bytearray, width: int, height: int, index: int) -> list[int]:
    """The set, unvisited pixels touching one pixel. Marked seen on the way out.

    Marking here rather than at pop time is what keeps a pixel out of the stack
    twice, which is the difference between a bounded fill and a quadratic one.
    """
    y, x = divmod(index, width)
    out: list[int] = []
    for step_y in (-1, 0, 1):
        for step_x in (-1, 0, 1):
            near_y, near_x = y + step_y, x + step_x
            inside = 0 <= near_y < height and 0 <= near_x < width
            near = near_y * width + near_x if inside else -1
            if near >= 0 and mask[near] and not seen[near]:
                seen[near] = 1
                out.append(near)

    return out


def write_rgba(path: Path, rows: list[bytes]) -> None:
    """Write an 8-bit RGBA PNG: one IHDR, one IDAT, one IEND, no metadata.

    No timestamp and no text chunk, so two runs over the same input produce the
    same bytes.
    """
    height = len(rows)
    if height == 0:
        raise Failure(f"{path} would have no rows")
    width = len(rows[0]) // 4

    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(
        PNG_SIGNATURE
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
