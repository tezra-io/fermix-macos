#!/usr/bin/env bash
#
# Gate: every generated brand image on disk is the one its generator produces.
#
# The two masters, the six menu bar templates and the app icon are build outputs
# that happen to be checked in, because the release scripts stage them from
# source and this machine cannot compile an asset catalog. A checked-in build
# output rots the moment someone edits an input and forgets to rebuild, so the
# whole chain is regenerated here into a temporary directory and compared byte
# for byte:
#
#   pet artwork -> the two masters -> the templates and the .icns
#
# Every generator is deterministic. sips plus iconutil produce identical bytes
# across runs, and the mark generator and the template rasterizer are pure
# arithmetic over the input pixels.
#
# Usage: check_brand_images.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources"
TEMPLATE_DIR="$RESOURCES_DIR/MenuBarTemplate"
ICON_DIR="$RESOURCES_DIR/AppIcon"
MARK_MASTER="FermixMarkMaster.png"
ICON_MASTER="FermixMonochromeIcon.png"

# The three states the rasterizer publishes, each with its @2x sibling.
TEMPLATES=(
  FermixMarkTemplate
  FermixMarkStartingTemplate
  FermixMarkAttentionTemplate
)

# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "check_brand_images: $*" >&2
  exit 1
}

# The alpha of one PNG's top-left pixel. A template image is tinted from its
# alpha channel, so a stray opaque background renders as a filled square in the
# menu bar.
top_left_alpha() {
  python3 -c '
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
pos, idat = 8, b""
while pos < len(data):
    length, kind = struct.unpack(">I", data[pos:pos + 4])[0], data[pos + 4:pos + 8]
    payload = data[pos + 8:pos + 8 + length]
    if kind == b"IDAT":
        idat += payload
    pos += length + 12
raw = zlib.decompress(idat)
if raw[0] != 0:
    raise SystemExit(f"unexpected PNG filter {raw[0]} on the first scanline")
print(raw[4])
' "$1"
}

# The masters come first: everything below is generated from them, so a stale
# master would otherwise be reported as three stale outputs.
check_masters() {
  # The generator reads its one input from the resource directory it writes
  # into, so the regeneration gets a directory that carries the pet artwork and
  # nothing else: the shipped masters stay untouched whatever it produces.
  mkdir -p "$WORK_DIR/masters"
  ln -s "$RESOURCES_DIR/PetExpressions" "$WORK_DIR/masters/PetExpressions"
  "$ROOT_DIR/scripts/build_mascot_mark.py" --resources "$WORK_DIR/masters" >/dev/null

  [ -f "$TEMPLATE_DIR/$MARK_MASTER" ] || fail "the mark master is missing at $TEMPLATE_DIR/$MARK_MASTER"
  cmp -s "$WORK_DIR/masters/MenuBarTemplate/$MARK_MASTER" "$TEMPLATE_DIR/$MARK_MASTER" ||
    fail "$MARK_MASTER is stale; rebuild it with scripts/build_mascot_mark.py"

  [ -f "$ICON_DIR/$ICON_MASTER" ] || fail "the icon master is missing at $ICON_DIR/$ICON_MASTER"
  cmp -s "$WORK_DIR/masters/AppIcon/$ICON_MASTER" "$ICON_DIR/$ICON_MASTER" ||
    fail "$ICON_MASTER is stale; rebuild it with scripts/build_mascot_mark.py"
}

check_app_icon() {
  local shipped="$RESOURCES_DIR/$(product_config icon_file).icns"
  [ -f "$shipped" ] || fail "application icon is missing at $shipped"
  "$ROOT_DIR/scripts/build_app_icon.sh" "$WORK_DIR/AppIcon.icns" >/dev/null
  cmp -s "$WORK_DIR/AppIcon.icns" "$shipped" ||
    fail "$(basename "$shipped") is stale; rebuild it with scripts/build_app_icon.sh"
}

check_menu_bar_templates() {
  "$ROOT_DIR/scripts/build_menu_bar_template.py" \
    --master "$TEMPLATE_DIR/$MARK_MASTER" \
    --out-dir "$WORK_DIR/template" >/dev/null

  local state name corner
  for state in "${TEMPLATES[@]}"; do
    for name in "$state.png" "$state@2x.png"; do
      [ -f "$TEMPLATE_DIR/$name" ] || fail "menu bar template $name is missing"
      cmp -s "$WORK_DIR/template/$name" "$TEMPLATE_DIR/$name" ||
        fail "$name is stale; rebuild it with scripts/build_menu_bar_template.py"

      corner="$(top_left_alpha "$TEMPLATE_DIR/$name")"
      [ "$corner" = "0" ] ||
        fail "$name has a non-transparent top-left pixel (alpha $corner); a template image must be alpha only"
    done
  done
}

check_masters
check_app_icon
check_menu_bar_templates
echo "check_brand_images: ok"
