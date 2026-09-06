#!/usr/bin/env bash
#
# Build the application icon from the approved icon master.
#
# The output is a plain .icns rather than a compiled asset catalog. That is a
# toolchain fact, not a preference: actool requires a full Xcode.app and this
# machine has CommandLineTools only, where /usr/bin/actool is the xcrun shim
# and answers "tool 'actool' requires Xcode". iconutil is a real binary and is
# the whole pipeline here.
#
# The icon name comes from Product.json, so the bundle, the linked Info.plist,
# the staging script, and this generator all name the same file.
#
# Every tier is a downsample of one master. Nothing is upscaled: an upscaled
# 1024 tier is a blurry icon that looks like a rendering bug on a Retina Dock.
#
# Usage: build_app_icon.sh [output.icns]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources"
# The interim mark: the FermixPet mascot in one ink, generated from the pet
# artwork by scripts/build_mascot_mark.py. It stands in until the owner has a
# Fermix logo, at which point that generator is repointed and this is unchanged.
MASTER="$RESOURCES_DIR/AppIcon/FermixMonochromeIcon.png"

# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

OUT_ICNS="${1:-$RESOURCES_DIR/$(product_config icon_file).icns}"

# The largest tier macOS asks for. A master below this would have to be
# upscaled, so it is refused instead.
LARGEST_TIER=1024

TIERS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

fail() {
  echo "build_app_icon: $*" >&2
  exit 1
}

[ -f "$MASTER" ] || fail "icon master is missing at $MASTER"
command -v sips >/dev/null || fail "sips is not available"
command -v iconutil >/dev/null || fail "iconutil is not available"

master_width="$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/ {print $2}')"
master_height="$(sips -g pixelHeight "$MASTER" | awk '/pixelHeight/ {print $2}')"
[ "$master_width" = "$master_height" ] ||
  fail "icon master is ${master_width} by ${master_height}; it must be square"
[ "$master_width" -ge "$LARGEST_TIER" ] ||
  fail "icon master is ${master_width}px, below the ${LARGEST_TIER}px top tier; supply a larger master rather than upscaling"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

for tier in "${TIERS[@]}"; do
  size="${tier%%:*}"
  name="${tier##*:}"
  sips -s format png -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

iconutil --convert icns --output "$OUT_ICNS" "$ICONSET"
[ -f "$OUT_ICNS" ] || fail "iconutil produced no output at $OUT_ICNS"

echo "build_app_icon: wrote $OUT_ICNS from a ${master_width}px master, ${#TIERS[@]} tiers"
