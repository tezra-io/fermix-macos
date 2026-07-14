#!/usr/bin/env bash
#
# Build -> sign -> notarize -> staple -> DMG for FermixPet.
#
# Release-only. Signing is MANDATORY: this fails loud if the Developer ID / notary
# environment is incomplete. There is NO ad-hoc fallback here — local, unsigned
# builds are `Apps/FermixPet/script/build_and_run.sh`'s job. Ported from the proven
# compux release flow (submit-then-poll notarization, never `--wait`), adapted for
# a universal2 SwiftPM app with a microphone entitlement and a drag-to-Applications
# DMG.
#
# Usage: package_release.sh <version> <build_number>
#   <version>       marketing version, e.g. 0.2.0 (from the fermixpet-vX.Y.Z tag)
#   <build_number>  monotonic CFBundleVersion, e.g. the CI run number
#
# Required env:
#   MACOS_DEVELOPER_ID  "Developer ID Application: <Name> (<TEAMID>)"
#   APPLE_ID  APPLE_TEAM_ID  APPLE_APP_PASSWORD   notarytool credentials
#
# Produces: dist/FermixPet-<version>.dmg (+ .sha256), stapled app + DMG.
set -euo pipefail

VERSION="${1:?usage: package_release.sh <version> <build_number>}"
BUILD_NUMBER="${2:?usage: package_release.sh <version> <build_number>}"

APP_NAME="FermixPet"
BUNDLE_ID="io.tezra.FermixPet"
DISPLAY_NAME="Fermix"
MIN_SYSTEM_VERSION="13.0"
RESOURCE_BUNDLE_NAME="FermixPet_FermixPet.bundle"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PET_DIR="$ROOT_DIR/Apps/$APP_NAME"
ENTITLEMENTS="$PET_DIR/Sources/FermixPet/FermixPet.entitlements"
BUILD_PATH="$PET_DIR/.build-release"
DIST="$ROOT_DIR/dist"
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

: "${MACOS_DEVELOPER_ID:?release signing is mandatory: MACOS_DEVELOPER_ID is required}"
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

fail() {
  echo "package_release: $*" >&2
  exit 1
}

build_universal() {
  cd "$PET_DIR"
  swift build -c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH"

  local bin_dir
  bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH" --show-bin-path)"
  BIN="$bin_dir/$APP_NAME"
  RESOURCE_BUNDLE="$bin_dir/$RESOURCE_BUNDLE_NAME"

  [ -x "$BIN" ] || fail "built binary missing: $BIN"
  [ -d "$RESOURCE_BUNDLE" ] || fail "resource bundle missing: $RESOURCE_BUNDLE"
  lipo -info "$BIN" | grep -q "arm64" || fail "binary is missing the arm64 slice"
  lipo -info "$BIN" | grep -q "x86_64" || fail "binary is missing the x86_64 slice"
}

write_info_plist() {
  cat >"$APP/Contents/Info.plist" <<PLIST
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

stage_app() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
  chmod 0755 "$APP/Contents/MacOS/$APP_NAME"
  cp "$RESOURCE_BUNDLE/FermixPet.icns" "$APP/Contents/Resources/FermixPet.icns"
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME"
  write_info_plist
}

sign_app() {
  # No --deep (Apple-discouraged; the resource bundle is a flat asset dir sealed
  # into CodeResources). One explicit entitlement; hardened runtime + timestamp.
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    --sign "$MACOS_DEVELOPER_ID" "$APP"

  codesign --verify --deep --strict --verbose=2 "$APP"

  codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.device.audio-input" \
    || fail "microphone entitlement absent after signing"
  if codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow"; then
    fail "get-task-allow present — not a release build"
  fi
}

# Submit to notarytool and poll (never --wait: it holds one HTTP loop open for the
# whole scan and dies on a transient runner blip). Bounded: 48 x 150s = 2h ceiling.
notarize_and_wait() {
  local submission="$1"
  local sub_id state attempt

  sub_id=$(xcrun notarytool submit "$submission" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
    --output-format json | jq -r '.id')
  echo "notarization submission ($submission): $sub_id"

  state="In Progress"
  for attempt in $(seq 1 48); do
    state=$(xcrun notarytool info "$sub_id" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
      --output-format json 2>/dev/null | jq -r '.status' || echo "network-error")
    echo "notarization status ($attempt/48): $state"
    case "$state" in
      "Accepted") break ;;
      "Invalid" | "Rejected") break ;;
      *) sleep 150 ;;
    esac
  done

  if [ "$state" != "Accepted" ]; then
    echo "::error title=Notarization failed::status=$state (submission $sub_id)"
    xcrun notarytool log "$sub_id" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" || true
    fail "notarization did not complete: $state"
  fi
}

build_dmg() {
  local dmg_stage
  dmg_stage="$(mktemp -d)"
  cp -R "$APP" "$dmg_stage/"
  ln -s /Applications "$dmg_stage/Applications"

  rm -f "$DMG"
  mkdir -p "$DIST"
  hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$dmg_stage" -ov -format UDZO "$DMG"
  rm -rf "$dmg_stage"

  # Sign the disk image itself so `spctl -t open` assesses a signed image.
  codesign --force --timestamp --sign "$MACOS_DEVELOPER_ID" "$DMG"
}

main() {
  mkdir -p "$DIST"
  build_universal
  stage_app
  sign_app

  # Two-pass staple: notarize + staple the app first (offline-robust first launch),
  # then package it into a DMG and notarize + staple the DMG.
  ditto -c -k --keepParent "$APP" "$STAGE/$APP_NAME.zip"
  notarize_and_wait "$STAGE/$APP_NAME.zip"
  xcrun stapler staple "$APP"

  build_dmg
  notarize_and_wait "$DMG"
  xcrun stapler staple "$DMG"

  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  codesign --verify --deep --strict --verbose=2 "$APP"

  shasum -a 256 "$DMG" | awk '{print $1}' >"$DMG.sha256"
  echo "package_release: built $(basename "$DMG") sha256=$(cat "$DMG.sha256")"
}

main
