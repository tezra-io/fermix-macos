#!/usr/bin/env bash
#
# Render the one Info.plist definition from Product.json.
#
# This is the only place an Info.plist is written. Its callers are:
#   * scripts/check_product_config.sh — regenerates the checked-in
#     Apps/Fermix/Sources/Fermix/Info.plist (linked into the GUI binary's
#     __TEXT,__info_plist section) and fails if it drifted from Product.json.
#   * scripts/stage_app.sh — writes Contents/Info.plist of the staged bundle.
#   * Apps/Fermix/script/build_and_run.sh — the same, for a local dev install.
#
# The version and build number are arguments rather than configuration reads
# because a release stamps them from its tag, while the checked-in copy carries
# the product version declared in Product.json.
#
# Usage: render_info_plist.sh <version> <build_number> <out_plist_path>
set -euo pipefail

VERSION="${1:?usage: render_info_plist.sh <version> <build_number> <out_plist_path>}"
BUILD_NUMBER="${2:?usage: render_info_plist.sh <version> <build_number> <out_plist_path>}"
OUT="${3:?usage: render_info_plist.sh <version> <build_number> <out_plist_path>}"

# shellcheck source=scripts/product_config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/product_config.sh"

# CFBundleVersion is the app's identity to the update feed, which orders release
# candidates by it numerically. Anything but a plain positive integer — a
# version triple, a padded digit, a tag name — either compares as older than
# itself or does not compare at all, and the mistake is invisible until an
# update fails to be offered. Product.json carries the checked-in value and
# scripts/check_product_config.sh gates it; this refuses the same shape for
# every caller that stamps one from somewhere else.
case "$BUILD_NUMBER" in
  0 | *[!0-9]* | 0*)
    echo "render_info_plist: build number '$BUILD_NUMBER' is not a positive integer" >&2
    exit 1
    ;;
esac

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

PRODUCT_NAME="$(xml_escape "$(product_config product_name)")"
BUNDLE_ID="$(xml_escape "$(product_config bundle_identifier)")"
GUI_EXECUTABLE="$(xml_escape "$(product_config gui_executable_name)")"
ICON_FILE="$(xml_escape "$(product_config icon_file)")"
MIN_SYSTEM_VERSION="$(xml_escape "$(product_config minimum_system_version)")"
MICROPHONE_USAGE="$(xml_escape "$(product_config microphone_usage_description)")"
URL_SCHEME="$(xml_escape "$(product_config url_scheme)")"
SPARKLE_FEED_URL="$(xml_escape "$(product_config sparkle_feed_url)")"
SPARKLE_PUBLIC_ED_KEY="$(xml_escape "$(product_config sparkle_public_ed_key)")"
RESOURCE_BUNDLE_NAME="$(xml_escape "$(product_config swift_resource_bundle_name)")"
VERSION_ESCAPED="$(xml_escape "$VERSION")"
BUILD_ESCAPED="$(xml_escape "$BUILD_NUMBER")"

cat >"$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleExecutable</key><string>$GUI_EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>$ICON_FILE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$PRODUCT_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>FermixResourceBundleName</key><string>$RESOURCE_BUNDLE_NAME</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$URL_SCHEME</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key><string>$VERSION_ESCAPED</string>
  <key>CFBundleVersion</key><string>$BUILD_ESCAPED</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <!-- No LSUIElement: FermixApp.main() sets the accessory policy as its first
       AppKit act, and the window host promotes to a Dock app while a real
       window is open. The plist key would pin UIElement and (observed live on
       macOS 26.5) defeat that runtime promotion. -->
  <key>NSMicrophoneUsageDescription</key><string>$MICROPHONE_USAGE</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- The update policy (M34 section 6), declared rather than set at runtime:
       resetting a preference on every launch would overwrite the choice the
       person made. The feed is fixed and the public key is what verifies its
       enclosure, so an update that is not signed by the matching private key
       cannot install.

       SUEnableAutomaticChecks is deliberately ABSENT: with no value Sparkle
       asks once, and the answer is the person's to give and to change.

       Both automatic-installation keys are off, and the second is what makes
       the first stick: without SUAllowsAutomaticUpdates Sparkle still offers
       an opt-in to installing updates by itself, and an installation that
       replaces this bundle has to run inside the update transaction that stops
       the engine first. -->
  <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
</dict>
</plist>
PLIST

plutil -lint "$OUT" >/dev/null
