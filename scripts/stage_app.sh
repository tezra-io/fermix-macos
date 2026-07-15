#!/usr/bin/env bash
#
# Build FermixPet universal2 and stage an UNSIGNED .app bundle.
#
# Shared by package_release.sh (which then signs, notarizes, and DMGs) and by
# ci.yml (which stages + adhoc-signs on every push, so a build or bundle-layout
# regression is caught in ungated CI instead of only at a gated signed release).
# No credentials required.
#
# Usage: stage_app.sh <version> <build_number> <out_app_path>
set -euo pipefail

VERSION="${1:?usage: stage_app.sh <version> <build_number> <out_app_path>}"
BUILD_NUMBER="${2:?usage: stage_app.sh <version> <build_number> <out_app_path>}"
OUT_APP="${3:?usage: stage_app.sh <version> <build_number> <out_app_path>}"

APP_NAME="FermixPet"
BUNDLE_ID="io.tezra.FermixPet"
DISPLAY_NAME="Fermix"
MIN_SYSTEM_VERSION="13.0"
RESOURCE_BUNDLE_NAME="FermixPet_FermixPet.bundle"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PET_DIR="$ROOT_DIR/Apps/$APP_NAME"
BUILD_PATH="$PET_DIR/.build-release"

fail() {
  echo "stage_app: $*" >&2
  exit 1
}

build_universal() {
  cd "$PET_DIR"
  swift build -c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH"

  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH" --show-bin-path)"
  BIN="$BIN_DIR/$APP_NAME"
  RESOURCE_BUNDLE="$BIN_DIR/$RESOURCE_BUNDLE_NAME"

  [ -x "$BIN" ] || fail "built binary missing: $BIN"
  [ -d "$RESOURCE_BUNDLE" ] || fail "resource bundle missing: $RESOURCE_BUNDLE"
  lipo -info "$BIN" | grep -q "arm64" || fail "binary is missing the arm64 slice"
  lipo -info "$BIN" | grep -q "x86_64" || fail "binary is missing the x86_64 slice"
}

write_info_plist() {
  cat >"$OUT_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>FermixPet</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSMicrophoneUsageDescription</key><string>FermixPet uses microphone input only while you explicitly start a voice call.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
}

stage() {
  rm -rf "$OUT_APP"
  mkdir -p "$OUT_APP/Contents/MacOS" "$OUT_APP/Contents/Resources"
  cp "$BIN" "$OUT_APP/Contents/MacOS/$APP_NAME"
  chmod 0755 "$OUT_APP/Contents/MacOS/$APP_NAME"
  # The app icon comes from source, not the built bundle: the universal (xcbuild)
  # build nests it under the resource bundle's Contents/Resources (a structured
  # bundle), unlike the flat single-arch layout, so the source path is the one
  # stable location across both build systems.
  cp "$PET_DIR/Sources/FermixPet/Resources/FermixPet.icns" "$OUT_APP/Contents/Resources/FermixPet.icns"
  cp -R "$RESOURCE_BUNDLE" "$OUT_APP/Contents/Resources/$RESOURCE_BUNDLE_NAME"
  write_info_plist
}

verify_layout() {
  [ -x "$OUT_APP/Contents/MacOS/$APP_NAME" ] || fail "app binary not staged"
  [ -f "$OUT_APP/Contents/Resources/FermixPet.icns" ] || fail "app icon not staged"
  [ -d "$OUT_APP/Contents/Resources/$RESOURCE_BUNDLE_NAME" ] || fail "resource bundle not staged"
  plutil -lint "$OUT_APP/Contents/Info.plist" >/dev/null || fail "staged Info.plist is invalid"
  lipo -info "$OUT_APP/Contents/MacOS/$APP_NAME" | grep -q "arm64" || fail "staged binary missing arm64"
  lipo -info "$OUT_APP/Contents/MacOS/$APP_NAME" | grep -q "x86_64" || fail "staged binary missing x86_64"
}

build_universal
stage
verify_layout
echo "stage_app: staged $OUT_APP"
