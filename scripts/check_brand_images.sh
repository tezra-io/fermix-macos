#!/usr/bin/env bash
#
# Gate: every generated brand image on disk is the one its generator produces.
#
# The app icon and the menu bar template are build outputs that happen to be
# checked in, because the release scripts stage them from source and this
# machine cannot compile an asset catalog. A checked-in build output rots the
# moment someone edits the master and forgets to rebuild, so both are
# regenerated here into a temporary directory and compared byte for byte.
#
# Both generators are deterministic. sips plus iconutil produce identical
# bytes across runs, and the template rasterizer is pure arithmetic.
#
# Usage: check_brand_images.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources"
TEMPLATE_DIR="$RESOURCES_DIR/MenuBarTemplate"

# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "check_brand_images: $*" >&2
  exit 1
}

check_app_icon() {
  local shipped="$RESOURCES_DIR/$(product_config icon_file).icns"
  [ -f "$shipped" ] || fail "application icon is missing at $shipped"
  "$ROOT_DIR/scripts/build_app_icon.sh" "$WORK_DIR/AppIcon.icns" >/dev/null
  cmp -s "$WORK_DIR/AppIcon.icns" "$shipped" ||
    fail "$(basename "$shipped") is stale; rebuild it with scripts/build_app_icon.sh"
}

check_menu_bar_template() {
  "$ROOT_DIR/scripts/build_menu_bar_template.py" \
    --master "$TEMPLATE_DIR/FermixBoltTemplate.svg" \
    --out-dir "$WORK_DIR/template" >/dev/null
  local name
  for name in FermixBoltTemplate.png FermixBoltTemplate@2x.png; do
    [ -f "$TEMPLATE_DIR/$name" ] || fail "menu bar template $name is missing"
    cmp -s "$WORK_DIR/template/$name" "$TEMPLATE_DIR/$name" ||
      fail "$name is stale; rebuild it with scripts/build_menu_bar_template.py"
  done
  # A template image is tinted from its alpha channel, so a stray opaque
  # background would render as a filled square in the menu bar.
  local corner
  corner="$(python3 -c '
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
pos, idat, width = 8, b"", 0
while pos < len(data):
    length, kind = struct.unpack(">I", data[pos:pos + 4])[0], data[pos + 4:pos + 8]
    payload = data[pos + 8:pos + 8 + length]
    if kind == b"IHDR":
        width = struct.unpack(">I", payload[0:4])[0]
    if kind == b"IDAT":
        idat += payload
    pos += length + 12
raw = zlib.decompress(idat)
if raw[0] != 0:
    raise SystemExit(f"unexpected PNG filter {raw[0]} on the first scanline")
print(raw[4])
' "$TEMPLATE_DIR/FermixBoltTemplate.png")"
  [ "$corner" = "0" ] ||
    fail "menu bar template has a non-transparent top-left pixel (alpha $corner); a template image must be alpha only"
}

check_app_icon
check_menu_bar_template
echo "check_brand_images: ok"
