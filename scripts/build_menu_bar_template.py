#!/usr/bin/env python3
"""Rasterize the Fermix mark into the menu bar's three template images.

The master is FermixMarkMaster.png, the mascot
`scripts/build_mascot_mark.py` derives from the pet artwork: the silhouette,
with the visor opening cut through it, and the face's two eyes as ink inside
that opening. It is an alpha plane, and so is everything written here: a
template image carries shape, not colour, and macOS tints it from the alpha
channel for the current menu bar appearance. That is what makes the status item
look like every other one in the bar, including the glass behind the menu it
opens.

The eyes need a rule of their own. They are about a fourteenth of the mark
across their narrow direction, which is a pixel and a fifth at the size a status
item is drawn, so a plain downsample turns the face into a faint wash inside the
visor and the glyph goes back to reading as a blob. So the mark is taken apart
into its body and its two eyes, and the eyes are drawn under one rule keyed on
the target size: at whatever size the master gives them, unless that puts their
narrow direction below `MIN_EYE_POINTS`, in which case each becomes a disc at
that floor on the eye's own centre, snapped to the pixel grid. The floor binds
under about 27 points of mark, and every menu bar tier is far under that, so in
practice the templates always take the floored branch. It is still one rule
rather than a second generator, which is what stops the two sizes from drifting
apart the next time the mark is redrawn.

Three images, one per state (`M34_DESIGN_SYSTEM_REDLINES.md` §5.10), because
the status item is an `NSImage` the system draws and sizes: the state has to be
in the image rather than in a view layered over it.

  * FermixMarkTemplate, running: the mark.
  * FermixMarkStartingTemplate, starting: the mark at the redline's lighter
    ink. Static, because nothing about the menu bar animates, so Reduce Motion
    needs no second rendering.
  * FermixMarkAttentionTemplate, attention: the mark with a badge disc cut into
    the same alpha, separated from the mark by a transparent ring. It is a
    shape, so it tints with everything else and is never a colour cue.

Every tier is 18 by 18 points, the canonical menu bar template size, so the
system's own layout has room for it and nothing is clipped. The size is not a
flag: the badge, the inset and the mark are all laid out against it, and a
second size would be a second geometry nobody looks at.

Output is deterministic, so scripts/check_brand_images.sh can regenerate and
diff byte for byte.

Usage: build_menu_bar_template.py --master <png> --out-dir <dir>
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import NamedTuple

from brand_png import Failure, alpha_plane, read_rgba, regions, resample_alpha, write_rgba

# The image box, in points. 18 is the canonical menu bar template size and the
# largest that clears the bar's own vertical padding, so nothing is cut.
IMAGE_POINTS = 18

# The clear space around the mark inside the image box, in points.
INSET_POINTS = 1

# The starting state's ink, as a fraction of the running state's. It is the
# redline's own glyph-pulse floor (§6, `MenuBarGlyphInk.startingOpacity`),
# spent on a static lighter mark rather than on the trough of an animation.
STARTING_INK = 0.45

# The attention badge, in the top trailing corner: a disc with a transparent
# ring holding it off the mark. The redline's 7 by 1.5 was a badge that overhung
# a 16-point glyph, which is what the status button clipped; cut into
# the template it has to live inside the box, and at 7 points it swallows the
# mark's whole trailing lobe and the mascot stops being recognisable. 4.5, 5.0,
# 5.5 and 7.0 were rendered at both scales and 5.0 is the largest that still
# reads as a badge on a mark rather than as a bite out of it.
#
# Being inside the box has a consequence worth stating plainly: the attention
# state is not the running outline plus a dot. The ring clears the mark's
# top-trailing pixels, so that corner of the silhouette is replaced rather than
# overlaid. It is the same trade the 18-point ceiling forces everywhere else:
# the badge is a shape in the same alpha, tinted with everything else, and it
# cannot both sit outside the box and survive the button's clipping.
#
# The badge sits in the top trailing corner and the eyes sit in the middle of
# the visor, so the two never meet.
BADGE_DIAMETER = 5.0
BADGE_RING = 1.0

# The smallest an eye may be drawn across its narrow direction, in points. The
# visor opening is only about six points across at 1x, so the pair has very
# little room and the floor is the whole design. What has to survive is two
# gaps: the clear pixel between the eyes, and the clear pixel between an eye and
# the visor rim. Lose either and the pair stops being two eyes.
#
# 1.5, 2.0, 2.5 and 3.0 were rendered at both scales. At 1.5 the trailing eye
# sits against the rim at 1x with nothing between them. At 2.5 and 3.0 the gap
# between the pair closes to nothing at 1x and the two read as one bar. Only 2.0
# holds both gaps at both scales, so it is the floor.
MIN_EYE_POINTS = 2.0

# Alpha at or above this belongs to a shape rather than to a shape's fringe.
# Used only to tell the eyes from the body, never to draw: what is drawn is the
# master's own alpha, fringe included.
LABEL_FLOOR = 8

# A labelled island smaller than this is not an eye. Each eye is over six
# thousand master pixels, so this only ever rejects a stray sample.
ISLAND_MIN_AREA = 16

# Supersampling grid for the badge and eye edges. 8 by 8 puts the quantization
# below one alpha step at these sizes.
SAMPLES = 8


class Eye(NamedTuple):
    """One eye in the master's own pixels: where it sits and how big it is."""

    centre_x: float
    centre_y: float
    width: int
    height: int


def running(mark: list[list[float]]) -> list[list[float]]:
    return mark


def starting(mark: list[list[float]]) -> list[list[float]]:
    return [[value * STARTING_INK for value in row] for row in mark]


def attention(mark: list[list[float]]) -> list[list[float]]:
    """The mark, its badge, and the transparent ring that separates them."""
    size = len(mark)
    scale = size / IMAGE_POINTS
    centre_x = (IMAGE_POINTS - INSET_POINTS - BADGE_DIAMETER / 2) * scale
    centre_y = (INSET_POINTS + BADGE_DIAMETER / 2) * scale
    badge = (BADGE_DIAMETER / 2) * scale
    gap = badge + BADGE_RING * scale

    rows: list[list[float]] = []
    for y in range(size):
        row: list[float] = []
        for x in range(size):
            # Clear the gap out of the mark first, then put the badge back, so
            # the ring is transparent whichever of the two the mark ran under.
            cleared = mark[y][x] * (1 - _disc_coverage(x, y, centre_x, centre_y, gap))
            row.append(max(cleared, _disc_coverage(x, y, centre_x, centre_y, badge)))
        rows.append(row)

    return rows


def _disc_coverage(pixel_x: int, pixel_y: int, centre_x: float, centre_y: float, radius: float) -> float:
    """How much of one pixel a disc covers, 0-1."""
    step = 1.0 / SAMPLES
    offset = step / 2
    hits = 0
    for sample_y in range(SAMPLES):
        y = pixel_y + offset + sample_y * step
        for sample_x in range(SAMPLES):
            x = pixel_x + offset + sample_x * step
            if (x - centre_x) ** 2 + (y - centre_y) ** 2 <= radius * radius:
                hits += 1

    return hits / (SAMPLES * SAMPLES)


# The three states, in the order the redline lists them. The names are the
# resource names `MenuBarGlyphImage` loads, so a state added here without a
# Swift case fails that mapping's own test rather than shipping unreferenced.
STATES = (
    ("FermixMarkTemplate", running),
    ("FermixMarkStartingTemplate", starting),
    ("FermixMarkAttentionTemplate", attention),
)


def split(plane: list[list[int]]) -> tuple[list[list[int]], list[list[int]], list[Eye]]:
    """The master's body, its two eyes, and where the eyes sit.

    The eyes are islands by construction: they are drawn inside the visor
    opening, which is a hole in the body, so no ink joins them to it. The body
    is the largest run of ink and the eyes are what is left. Deriving them from
    the master rather than repeating their coordinates here is what keeps this
    generator from drifting when the mark is redrawn.
    """
    size = len(plane)
    mask = bytearray(size * size)
    for y in range(size):
        base = y * size
        row = plane[y]
        for x in range(size):
            mask[base + x] = 1 if row[x] >= LABEL_FLOOR else 0

    found = sorted(regions(mask, size, size), key=lambda region: region.area, reverse=True)
    if not found:
        raise Failure("the master carries no ink")

    islands = [region for region in found[1:] if region.area >= ISLAND_MIN_AREA]
    if len(islands) != 2:
        raise Failure(
            f"the master has {len(islands)} islands inside its silhouette; the mark carries two eyes"
        )

    members = islands[0].members | islands[1].members
    eyes = [
        Eye(island.centre_x, island.centre_y,
            island.right - island.left + 1, island.bottom - island.top + 1)
        for island in islands
    ]

    return _without(plane, members), _only(plane, members), eyes


def _without(plane: list[list[int]], members: frozenset[int]) -> list[list[int]]:
    """The plane with the labelled pixels cleared."""
    size = len(plane)

    return [
        [0 if y * size + x in members else plane[y][x] for x in range(size)]
        for y in range(size)
    ]


def _only(plane: list[list[int]], members: frozenset[int]) -> list[list[int]]:
    """The plane with everything but the labelled pixels cleared."""
    size = len(plane)

    return [
        [plane[y][x] if y * size + x in members else 0 for x in range(size)]
        for y in range(size)
    ]


def eye_layer(eyes: list[list[int]], marks: list[Eye], span: int, scale: int) -> list[list[float]]:
    """The eyes at the drawn size, floored to the size they stop reading below.

    One rule, keyed on the target. Measure what the narrower eye would come out
    at; if that clears the floor it goes through the same area resample the body
    does, and if it does not, each eye is replaced by a disc at the floor on its
    own centre.

    A disc, where the drawing has a tall rounded slot: at the floor the eye is
    two pixels across, and two pixels have no aspect to keep. Holding the slot's
    proportion instead would make it four pixels tall, which is the whole height
    of the visor opening at 1x, so the eyes would reach the rim above and below
    and the face would close up. Round is the shape that fits.
    """
    source = len(eyes)
    narrow = min(min(mark.width, mark.height) for mark in marks) * span / source
    if narrow >= MIN_EYE_POINTS * scale:
        return resample_alpha(eyes, span)

    return _eye_discs(marks, span, source, MIN_EYE_POINTS * scale)


def _eye_discs(marks: list[Eye], span: int, source: int, diameter: float) -> list[list[float]]:
    """Each eye as one antialiased disc, on the centre the master gives it.

    The centre is snapped to the grid the diameter wants before the disc is
    drawn. Off the grid, a two-pixel eye lands as one solid pixel with grey on
    three sides of it, and at this size that fringe is the difference between an
    eye and a smudge: it spends the one clear pixel between the pair and the one
    between an eye and the visor rim, which are the only two gaps the face has.
    Snapping costs a third of a pixel of position and buys both back.
    """
    radius = diameter / 2
    centres = [
        (_snapped(mark.centre_x * span / source, diameter),
         _snapped(mark.centre_y * span / source, diameter))
        for mark in marks
    ]

    rows: list[list[float]] = []
    for y in range(span):
        rows.append([
            max(_disc_coverage(x, y, centre_x, centre_y, radius) for centre_x, centre_y in centres)
            for x in range(span)
        ])

    return rows


def _snapped(centre: float, diameter: float) -> float:
    """One coordinate moved onto the grid a disc of this diameter sits on.

    Pixel `n` spans `n` to `n + 1`, so an even diameter fills whole pixels when
    it is centred on a boundary and an odd one when it is centred in a pixel.
    A non-integer diameter has no such grid and is left where it is.
    """
    pixels = round(diameter)
    if abs(diameter - pixels) > 1e-9:
        return centre

    return round(centre) if pixels % 2 == 0 else math.floor(centre) + 0.5


def framed(body: list[list[int]], eyes: list[list[int]], marks: list[Eye], scale: int) -> list[list[float]]:
    """The mark, resampled and centred inside the image box with its inset."""
    size = IMAGE_POINTS * scale
    inset = INSET_POINTS * scale
    span = size - 2 * inset
    silhouette = resample_alpha(body, span)
    face = eye_layer(eyes, marks, span, scale)
    mark = [
        [max(left, right) for left, right in zip(row, face_row)]
        for row, face_row in zip(silhouette, face)
    ]

    rows: list[list[float]] = []
    for y in range(size):
        inside_y = inset <= y < size - inset
        rows.append([
            mark[y - inset][x - inset] if inside_y and inset <= x < size - inset else 0.0
            for x in range(size)
        ])

    return rows


def to_alpha_rows(coverage: list[list[float]]) -> list[bytes]:
    """Coverage to alpha-only scanlines: black pixels, coverage in the alpha."""
    rows = []
    for line in coverage:
        row = bytearray()
        for value in line:
            row += bytes((0, 0, 0, round(min(max(value, 0.0), 1.0) * 255)))
        rows.append(bytes(row))

    return rows


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", required=True)
    parser.add_argument("--out-dir", required=True)
    arguments = parser.parse_args(argv)

    master = Path(arguments.master).resolve()
    out_dir = Path(arguments.out_dir).resolve()

    try:
        if not master.is_file():
            raise Failure(f"master is missing at {master}")

        width, height, pixels = read_rgba(master)
        if width != height:
            raise Failure(f"{master} is {width} by {height}; the master must be square")

        body, eyes, marks = split(alpha_plane(width, height, pixels))
        out_dir.mkdir(parents=True, exist_ok=True)

        for name, state in STATES:
            for scale, suffix in ((1, ""), (2, "@2x")):
                rows = to_alpha_rows(state(framed(body, eyes, marks, scale)))
                write_rgba(out_dir / f"{name}{suffix}.png", rows)
            print(f"build_menu_bar_template: wrote {name} at {IMAGE_POINTS} by {IMAGE_POINTS} points")
    except Failure as failure:
        print(f"build_menu_bar_template: {failure}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
