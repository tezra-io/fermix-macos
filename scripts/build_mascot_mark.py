#!/usr/bin/env python3
"""Derive the interim Fermix mark from the pet artwork.

The mark is the pet mascot in one ink. It is interim: the owner asked for
the mascot everywhere until there is a Fermix logo, at which point both masters
below are regenerated from that logo and nothing else changes.

There is exactly one drawing in the repo the mascot can be derived from, the
layered pet PNGs, and two of the listening pose's layers carry what makes it
the mascot:

  * `pet_listening_body.png` is the whole silhouette: one ink component around
    one enclosed hole, and that hole is the visor the face sits in.
  * `pet_listening_face.png` is the lens that fills the visor, carrying the two
    lit eyes. The eyes are the face, and without them the mark is a blank visor
    rather than a mascot.

The listening pose and not the idle one, because the listening pose is the face
the colour app icon carried: two open eyes, each a tall rounded slot, centred in
the visor. The idle pose draws the same pet asleep, its eyes two crescents a
quarter the height, sitting low in the visor. Set beside the icon this mark
stands in for, the idle face is a different expression, and at half the width
across its narrow direction it also gives up a tier earlier on the way down.
The two layers are taken as a pair: the bodies differ by twenty thousand pixels
and each face is drawn to register with its own body, so a mixed pair would set
the eyes off centre in the visor.

Because the eyes sit inside the hole and not on top of the ink, they stay ink
themselves: light eyes in a dark visor, which is what the colour icon showed.
There is no knockout to make, because the visor already is one.

The eyes are lifted from the face layer by luminance. They are the only lit
regions on the lens that come as a mirrored pair about its own centre line, and
that pairing is what tells them apart from the lens gloss, a single lit patch in
the upper left that reads as a smudge once colour is gone. The gloss is dropped.
So is the lens body, which would fill the visor and take the face with it. So
are the ring layer and the decor layers the speaking and thinking poses add:
those are a few source pixels wide and reduce to noise on the edge rather than
to anything the eye resolves.

Inside the two layers that are used, nothing is traced, thresholded to a hard
edge, or smoothed. The body's alpha is already a clean two-region shape with a
two-pixel antialiased edge and no glow, and the eyes keep the soft edge their
own glow gives them, so the whole transform is a crop to the body's support, a
centring in a square, and the union of the two layers at source resolution.

The eyes are about a fourteenth of the mark across their narrow direction. That
reads on the icon from the 128 tier up, where the Dock draws it, and thins to a
faint pair at 32, where each eye is a little over a pixel across. It reads on no
menu bar tier at all, which is why `scripts/build_menu_bar_template.py` redraws
the eyes at a floor below the size they stop reading at. The icon has no floor,
because every tier here is one downsample of one master, so the 16 tier carries
no face. A floor would not rescue that tier anyway: the visor is under four
pixels across at 16, and two eyes with a clear pixel between them need five.
The face reads at 32 and above without any help.

Two masters come out of it:

  * Resources/MenuBarTemplate/FermixMarkMaster.png, alpha only, the input
    `scripts/build_menu_bar_template.py` rasterizes the status-item templates
    from.
  * Resources/AppIcon/FermixMonochromeIcon.png, 1024 by 1024, the mark in one
    ink on a neutral ground inside the macOS icon grid's rounded square, which
    `scripts/build_app_icon.sh` turns into the .icns.

Output is deterministic, so scripts/check_brand_images.sh regenerates both and
diffs them byte for byte.

Usage: build_mascot_mark.py [--resources <dir>]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import NamedTuple

from brand_png import (
    Failure,
    Region,
    alpha_plane,
    read_rgba,
    regions,
    resample_alpha,
    write_rgba,
)

# The pet layers the mark comes from: the silhouette, and the face drawn in its
# visor opening. One pose, both layers. Each face registers with its own body,
# so these two names change together or the eyes land off centre in the visor.
SOURCE_BODY = "PetExpressions/pet_listening_body.png"
SOURCE_FACE = "PetExpressions/pet_listening_face.png"
MARK_MASTER = "MenuBarTemplate/FermixMarkMaster.png"
ICON_MASTER = "AppIcon/FermixMonochromeIcon.png"

# The macOS icon grid, at the 1024 tier: the rounded square is 824 wide with a
# 185 corner radius, and the 100 points around it are the space the system's
# shadow and selection ring live in. An icon drawn to the canvas edge is the
# one that looks wrong beside every other icon in the Dock.
ICON_CANVAS = 1024
ICON_SQUARE = 824
ICON_RADIUS = 185
# The mark inside that square. Larger and the lobes touch the corner radius;
# smaller and the icon reads as a logo floating in a box.
ICON_MARK = 512

# One ink, no colour (`Palette.ink` and `Palette.base100`, dark values). The
# dark ground is what the mark is drawn against everywhere else in the product,
# and a near-white icon ground reads as washed out on a Dock.
INK = (0xF4, 0xF5, 0xF7)
GROUND = (0x10, 0x10, 0x14)

# Corner coverage is sampled on this grid. 4 by 4 puts the quantization on the
# radius below one alpha step at 1024, so raising it changes nothing.
SAMPLES = 4

# A face pixel counts as lit when the lens under it is this opaque and it is
# this bright. The lens body sits near luminance 26 with its ninety-fifth
# percentile at 112, and the eyes run to 255, so the floor has a wide empty band
# to land in: moving it anywhere inside that band moves the eye edge by about a
# pixel. Coverage ramps from the floor to full over the glow's own falloff,
# which is what gives the eyes an antialiased edge without anything being
# smoothed.
FACE_OPAQUE = 200
LUMA_FLOOR = 160
LUMA_FULL = 230

# A lit region smaller than this is a stray sample on the lens rim rather than a
# feature. Each eye is over six thousand pixels and every stray is one or two.
LIT_MIN_AREA = 64

# How far off a true mirror the pair may sit, as a fraction of the face layer's
# own width. The eyes score under four pixels against their centre line; the
# nearest wrong pair, an eye with the gloss, scores over a hundred and forty,
# and the tolerance sits at twenty.
MIRROR_TOLERANCE = 0.05

# A pair of eyes is a matched pair. The larger may exceed the smaller by this
# much and no more, which is what stops a gloss that happened to land opposite
# an eye from being read as its twin. The drawn pair matches to within a third
# of one percent, so the whole allowance is headroom for a redraw.
EYE_AREA_RATIO = 1.25


class Frame(NamedTuple):
    """The square the mark is drawn in, and where the source sits inside it."""

    left: int
    top: int
    width: int
    height: int
    side: int
    offset_x: int
    offset_y: int


def support(plane: list[list[int]]) -> tuple[int, int, int, int]:
    """The bounding box of every pixel carrying any alpha at all.

    Any alpha, not a threshold: the box has to include the anti-aliased fringe,
    or the mark ends in a hard cut exactly where its edge should soften.
    """
    left, top, right, bottom = len(plane[0]), len(plane), -1, -1
    for y, row in enumerate(plane):
        for x, value in enumerate(row):
            if value == 0:
                continue
            left = min(left, x)
            right = max(right, x)
            top = min(top, y)
            bottom = max(bottom, y)

    if right < 0:
        raise Failure("the pet layer is fully transparent")

    return left, top, right, bottom


def frame(plane: list[list[int]]) -> Frame:
    """The square the body's support is centred in.

    Square because every consumer draws it in a square: a status-item image, an
    icon tier, a Dock tile. Centring here is what keeps each of them from
    inventing its own idea of where the mark sits. The body sets the frame and
    the face is placed into that same frame, so the eyes land where the drawing
    put them.
    """
    left, top, right, bottom = support(plane)
    width = right - left + 1
    height = bottom - top + 1
    side = max(width, height)

    return Frame(left, top, width, height, side, (side - width) // 2, (side - height) // 2)


def placed(plane: list[list[int]], box: Frame) -> list[list[int]]:
    """One source plane cropped to the frame and centred in its square."""
    rows = []
    for y in range(box.side):
        source_y = y - box.offset_y + box.top
        if not box.top <= source_y < box.top + box.height:
            rows.append([0] * box.side)
            continue

        line = plane[source_y]
        rows.append([
            line[x - box.offset_x + box.left] if 0 <= x - box.offset_x < box.width else 0
            for x in range(box.side)
        ])

    return rows


def union(one: list[list[int]], other: list[list[int]]) -> list[list[int]]:
    """Two planes in the same square, whichever covers more at each pixel."""
    return [
        [max(left, right) for left, right in zip(row, other_row)]
        for row, other_row in zip(one, other)
    ]


def luminance(red: int, green: int, blue: int) -> int:
    """Rec. 601 luma. The eyes are lit blue and the lens is dark blue, so a
    plain channel test would separate them by hue rather than by brightness and
    would take the lens rim with it."""
    return (299 * red + 587 * green + 114 * blue) // 1000


def lit_mask(width: int, height: int, pixels: bytes) -> bytearray:
    """Every face pixel bright enough to belong to a lit feature."""
    mask = bytearray(width * height)
    for index in range(width * height):
        base = index * 4
        if pixels[base + 3] < FACE_OPAQUE:
            continue
        if luminance(pixels[base], pixels[base + 1], pixels[base + 2]) >= LUMA_FLOOR:
            mask[index] = 1

    return mask


def eye_pair(found: list[Region], axis: float, span: int) -> tuple[Region, Region]:
    """The two lit regions that mirror each other about the face's centre line.

    Mirroring is the test because it is what makes a pair of eyes a pair, and it
    holds whatever the gloss happens to weigh. A size rank would not: on the
    idle pose, which this generator can be repointed at, the gloss lands within
    a hundred pixels of either eye, so the rank there is a coin flip.
    """
    candidates = [region for region in found if region.area >= LIT_MIN_AREA]
    if len(candidates) < 2:
        raise Failure(f"the face layer has {len(candidates)} lit regions; the eyes are a pair")

    scored = [
        (_mirror_score(one, other, axis), one, other)
        for index, one in enumerate(candidates)
        for other in candidates[index + 1:]
    ]
    score, one, other = min(scored, key=lambda entry: entry[0])
    if score > MIRROR_TOLERANCE * span:
        raise Failure(
            f"no mirrored pair on the face layer; the closest two lit regions are "
            f"{score:.0f} pixels off a mirror and the tolerance is {MIRROR_TOLERANCE * span:.0f}"
        )

    larger, smaller = max(one.area, other.area), min(one.area, other.area)
    if larger > EYE_AREA_RATIO * smaller:
        raise Failure(
            f"the mirrored lit regions are {larger} and {smaller} pixels; a pair of eyes is a matched pair"
        )

    return (one, other) if one.centre_x <= other.centre_x else (other, one)


def _mirror_score(one: Region, other: Region, axis: float) -> float:
    """How far two regions are from being each other's reflection, in pixels."""
    return abs(one.centre_x + other.centre_x - 2 * axis) + abs(one.centre_y - other.centre_y)


def eye_plane(width: int, height: int, pixels: bytes, pair: tuple[Region, Region]) -> list[list[int]]:
    """The two eyes as an alpha plane, their glow falloff carried into coverage."""
    members = pair[0].members | pair[1].members
    ramp = LUMA_FULL - LUMA_FLOOR
    plane = [[0] * width for _ in range(height)]
    for index in members:
        y, x = divmod(index, width)
        base = index * 4
        lit = luminance(pixels[base], pixels[base + 1], pixels[base + 2]) - LUMA_FLOOR
        coverage = min(lit / ramp, 1.0) * (pixels[base + 3] / 255)
        plane[y][x] = round(coverage * 255)

    return plane


def write_mark_master(plane: list[list[int]], path: Path) -> int:
    """The alpha-only master. Black pixels, coverage in the alpha channel."""
    rows = []
    for line in plane:
        row = bytearray()
        for value in line:
            row += bytes((0, 0, 0, value))
        rows.append(bytes(row))

    write_rgba(path, rows)

    return len(plane)


def rounded_square_coverage(size: int, square: int, radius: int) -> list[list[float]]:
    """Per-pixel coverage of the icon grid's rounded square, 0-1.

    Circular corners rather than a continuous-curve squircle: the difference is
    under a pixel at this radius, and an approximation somebody can read beats
    a superellipse constant nobody can check.
    """
    inset = (size - square) / 2
    left, top = inset, inset
    right, bottom = inset + square, inset + square
    step = 1.0 / SAMPLES
    offset = step / 2

    rows: list[list[float]] = []
    for pixel_y in range(size):
        row: list[float] = []
        for pixel_x in range(size):
            hits = 0
            for sample_y in range(SAMPLES):
                y = pixel_y + offset + sample_y * step
                for sample_x in range(SAMPLES):
                    x = pixel_x + offset + sample_x * step
                    if _inside(x, y, left, top, right, bottom, radius):
                        hits += 1
            row.append(hits / (SAMPLES * SAMPLES))
        rows.append(row)

    return rows


def _inside(x: float, y: float, left: float, top: float, right: float, bottom: float, radius: int) -> bool:
    if not (left <= x <= right and top <= y <= bottom):
        return False

    corner_x = min(max(x, left + radius), right - radius)
    corner_y = min(max(y, top + radius), bottom - radius)

    return (x - corner_x) ** 2 + (y - corner_y) ** 2 <= radius * radius


def write_icon_master(plane: list[list[int]], path: Path) -> None:
    """The 1024 icon master: one ink on a neutral ground, inside the grid."""
    ground = rounded_square_coverage(ICON_CANVAS, ICON_SQUARE, ICON_RADIUS)
    mark = resample_alpha(plane, ICON_MARK)
    origin = (ICON_CANVAS - ICON_MARK) // 2

    rows = []
    for y in range(ICON_CANVAS):
        row = bytearray()
        for x in range(ICON_CANVAS):
            base = ground[y][x]
            ink = 0.0
            if origin <= x < origin + ICON_MARK and origin <= y < origin + ICON_MARK:
                ink = mark[y - origin][x - origin]
            row += _composite(ink, base)
        rows.append(bytes(row))

    write_rgba(path, rows)


def _composite(ink: float, base: float) -> bytes:
    """The mark over the ground, source-over, non-premultiplied."""
    alpha = ink + base * (1 - ink)
    if alpha == 0:
        return bytes((0, 0, 0, 0))

    channels = tuple(
        round((INK[index] * ink + GROUND[index] * base * (1 - ink)) / alpha)
        for index in range(3)
    )

    return bytes(channels + (round(alpha * 255),))


def read_layer(path: Path) -> tuple[int, int, bytes]:
    """One pet layer, refused loudly rather than guessed at when it is missing."""
    if not path.is_file():
        raise Failure(f"the pet layer is missing at {path}")

    return read_rgba(path)


def build_mark(resources: Path) -> list[list[int]]:
    """The mark plane: the body silhouette with the face's eyes inside its visor."""
    body_width, body_height, body_pixels = read_layer(resources / SOURCE_BODY)
    face_width, face_height, face_pixels = read_layer(resources / SOURCE_FACE)
    if (face_width, face_height) != (body_width, body_height):
        raise Failure(
            f"the face layer is {face_width} by {face_height} and the body is "
            f"{body_width} by {body_height}; the layers must register"
        )

    body = alpha_plane(body_width, body_height, body_pixels)
    face = alpha_plane(face_width, face_height, face_pixels)
    left, _, right, _ = support(face)
    found = regions(lit_mask(face_width, face_height, face_pixels), face_width, face_height)
    pair = eye_pair(found, (left + right) / 2, right - left + 1)
    eyes = eye_plane(face_width, face_height, face_pixels, pair)

    kept = sum(region.area for region in pair)
    dropped = sum(region.area for region in found) - kept
    print(f"build_mascot_mark: kept the eye pair, {kept} lit pixels, and dropped {dropped} more")

    box = frame(body)

    return union(placed(body, box), placed(eyes, box))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--resources",
        default=str(Path(__file__).resolve().parent.parent
                    / "Apps/Fermix/Sources/FermixAppCore/Resources"),
        help="the resource directory the masters are written into",
    )
    arguments = parser.parse_args(argv)
    resources = Path(arguments.resources).resolve()

    try:
        plane = build_mark(resources)

        mark_path = resources / MARK_MASTER
        mark_path.parent.mkdir(parents=True, exist_ok=True)
        side = write_mark_master(plane, mark_path)
        print(f"build_mascot_mark: wrote {mark_path.name} at {side} by {side}")

        icon_path = resources / ICON_MASTER
        icon_path.parent.mkdir(parents=True, exist_ok=True)
        write_icon_master(plane, icon_path)
        print(f"build_mascot_mark: wrote {icon_path.name} at {ICON_CANVAS} by {ICON_CANVAS}")
    except Failure as failure:
        print(f"build_mascot_mark: {failure}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
