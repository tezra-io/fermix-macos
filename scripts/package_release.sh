#!/usr/bin/env bash
#
# Build -> sign -> notarize -> staple -> DMG for FermixPet.
#
# Release-only. Signing is MANDATORY: this fails loud if the Developer ID / notary
# environment is incomplete. There is NO ad-hoc fallback here — local unsigned
# builds are `Apps/FermixPet/script/build_and_run.sh`'s job.
#
# The build+stage and the inside-out signing are shared with CI via
# scripts/stage_app.sh + scripts/sign_app.sh (CI runs them ad-hoc and ungated, so
# a build / bundle-layout / signing-structure regression is caught without a
# gated release). This script adds the credentialed notarization (submit-then-poll,
# never `--wait`), two-pass stapling, and the signed drag-to-Applications DMG.
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
DISPLAY_NAME="Fermix"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  "$ROOT_DIR/scripts/stage_app.sh" "$VERSION" "$BUILD_NUMBER" "$APP"
  "$ROOT_DIR/scripts/sign_app.sh" "$APP" "$MACOS_DEVELOPER_ID"

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
