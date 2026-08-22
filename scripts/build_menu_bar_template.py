#!/usr/bin/env python3
"""Rasterize the Fermix bolt into the menu bar template images.

The master is FermixBoltTemplate.svg, whose path is the M33 redline verbatim.
The bolt is a closed straight-line polygon, so it is rasterized here rather
than shelled out to a converter: a CommandLineTools-only Mac has no SVG
rasterizer that produces a clean transparent result, and inventing one would
put the shipping glyph at the mercy of a thumbnailer.

A template image carries alpha only. Every pixel is written black with its
coverage as the alpha value, which is exactly what macOS tints.

Output is deterministic, so scripts/check_brand_images.sh can regenerate and
diff byte for byte.
"""

from __future__ import annotations

import argparse
import re
import struct
import sys
import zlib
from pathlib import Path

# Supersampling grid per pixel. 8 by 8 puts the edge quantization below one
# alpha step at these sizes, so raising it changes nothing and lowering it
# shows on the diagonal.
SAMPLES = 8

PATH_D = re.compile(r'\sd="([^"]+)"')
VIEWBOX = re.compile(r'\sviewBox="([^"]+)"')
COMMAND = re.compile(r"([MLHVZmlhvz])([^MLHVZmlhvz]*)")


class Failure(Exception):
    """A build failure with an operator-readable sentence."""


def parse_polygon(d: str) -> list[tuple[float, float]]:
    """Read a closed polygon out of an absolute straight-line path.

    Curves are rejected rather than approximated: this rasterizer draws
    straight edges, and silently flattening a curve would ship a glyph that is
    not the one in the master.
    """
    points: list[tuple[float, float]] = []
    cursor = (0.0, 0.0)
    closed = False
    for command, raw in COMMAND.findall(d):
        if command in "mlhv":
            raise Failure(f"path uses relative command {command!r}; the master is absolute")
        numbers = [float(value) for value in re.split(r"[,\s]+", raw.strip()) if value]
        if command == "M":
            if len(numbers) != 2:
                raise Failure("M takes exactly one point in this master")
            cursor = (numbers[0], numbers[1])
            points.append(cursor)
        elif command == "L":
            if len(numbers) != 2:
                raise Failure("L takes exactly one point in this master")
            cursor = (numbers[0], numbers[1])
            points.append(cursor)
        elif command == "H":
            if len(numbers) != 1:
                raise Failure("H takes exactly one coordinate in this master")
            cursor = (numbers[0], cursor[1])
            points.append(cursor)
        elif command == "V":
            if len(numbers) != 1:
                raise Failure("V takes exactly one coordinate in this master")
            cursor = (cursor[0], numbers[0])
            points.append(cursor)
        else:
            closed = True
    if not closed:
        raise Failure("path is not closed; a template glyph must be a closed shape")
    if len(points) < 3:
        raise Failure(f"path has {len(points)} points, which cannot enclose an area")
    return points


def read_master(path: Path) -> tuple[list[tuple[float, float]], float, float]:
    text = path.read_text(encoding="utf-8")
    box = VIEWBOX.search(text)
    if not box:
        raise Failure(f"{path} has no viewBox")
    parts = [float(value) for value in box.group(1).split()]
    if len(parts) != 4 or parts[0] != 0 or parts[1] != 0:
        raise Failure(f"{path} viewBox must start at the origin")
    match = PATH_D.search(text)
    if not match:
        raise Failure(f"{path} has no path")
    return parse_polygon(match.group(1)), parts[2], parts[3]


def inside(polygon: list[tuple[float, float]], x: float, y: float) -> bool:
    """Even-odd crossing test."""
    result = False
    count = len(polygon)
    for index in range(count):
        x0, y0 = polygon[index]
        x1, y1 = polygon[(index + 1) % count]
        if (y0 > y) != (y1 > y):
            crossing = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
            if x < crossing:
                result = not result
    return result


def coverage_rows(polygon, view_w: float, view_h: float, size: int) -> list[bytes]:
    scale_x = view_w / size
    scale_y = view_h / size
    step = 1.0 / SAMPLES
    offset = step / 2.0
    rows: list[bytes] = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            hits = 0
            for sy in range(SAMPLES):
                y = (py + offset + sy * step) * scale_y
                for sx in range(SAMPLES):
                    x = (px + offset + sx * step) * scale_x
                    if inside(polygon, x, y):
                        hits += 1
            alpha = round(hits * 255 / (SAMPLES * SAMPLES))
            row += bytes((0, 0, 0, alpha))
        rows.append(bytes(row))
    return rows


def write_png(path: Path, rows: list[bytes], size: int) -> None:
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--points", type=int, default=16)
    arguments = parser.parse_args(argv)

    master = Path(arguments.master).resolve()
    out_dir = Path(arguments.out_dir).resolve()
    if not master.is_file():
        print(f"build_menu_bar_template: master is missing at {master}", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        polygon, view_w, view_h = read_master(master)
        for scale, suffix in ((1, ""), (2, "@2x")):
            size = arguments.points * scale
            rows = coverage_rows(polygon, view_w, view_h, size)
            target = out_dir / f"{master.stem}{suffix}.png"
            write_png(target, rows, size)
            print(f"build_menu_bar_template: wrote {target.name} at {size} by {size}")
    except Failure as failure:
        print(f"build_menu_bar_template: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
