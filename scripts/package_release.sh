#!/usr/bin/env bash
#
# Build -> sign -> notarize -> staple -> DMG for the Fermix application.
#
# Release-only. Signing is MANDATORY: this fails loud if the Developer ID / notary
# environment is incomplete. There is NO ad-hoc fallback here — local unsigned
# builds are `scripts/dev_run.sh`'s job.
#
# The build+stage and the inside-out signing are shared with CI via
# scripts/stage_app.sh + scripts/sign_app.sh (CI runs them ad-hoc and ungated, so
# a build / bundle-layout / signing-structure regression is caught without a
# gated release). This script adds the credentialed notarization (submit-then-poll,
# never `--wait`), two-pass stapling, and the signed drag-to-Applications DMG.
#
# The engine inside the bundle comes from engine/PIN.json, and only from there:
# the pinned release's two app-engine assets are downloaded by
# scripts/fetch_engine.sh and proven to be the pinned ones by
# scripts/verify_engine.sh before anything is staged, and an unpinned pin
# refuses the build. Downloading needs `gh` with a token and verifying needs
# cosign, so a release host provides both alongside the Apple credentials below.
#
# The bundle name, the DMG name, and the disk image's volume name all come from
# Product.json through scripts/product_config.sh. The artifact name is therefore
# whatever `app_bundle_name` says without its .app suffix — and because
# release.yml and the cask template match that name literally,
# scripts/check_product_config.sh gates both files against this configuration.
#
# Usage: package_release.sh <version> <build_number>
#   <version>       marketing version, e.g. 0.2.0 (from the release tag)
#   <build_number>  monotonic CFBundleVersion, e.g. the CI run number
#
# Required env:
#   MACOS_DEVELOPER_ID  "Developer ID Application: <Name> (<TEAMID>)"
#   APPLE_ID  APPLE_TEAM_ID  APPLE_APP_PASSWORD   notarytool credentials
#
# Produces: dist/<artifact>-<version>.dmg (+ .sha256), stapled app + DMG.
set -euo pipefail

VERSION="${1:?usage: package_release.sh <version> <build_number>}"
BUILD_NUMBER="${2:?usage: package_release.sh <version> <build_number>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/engine_pin.sh
source "$ROOT_DIR/scripts/engine_pin.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
ARTIFACT_NAME="${APP_BUNDLE_NAME%.app}"
DISPLAY_NAME="$(product_config product_name)"

DIST="$ROOT_DIR/dist"
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_BUNDLE_NAME"
DMG="$DIST/$ARTIFACT_NAME-$VERSION.dmg"
ENGINE_DOWNLOAD="$STAGE/engine-download"
ENGINE_TREES="$STAGE/engine"
ENGINE_FLAGS=()

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

# The engine this release ships, downloaded and verified before anything is
# built.
#
# A release without an engine is not a release: the app reads nothing itself,
# so a DMG with an empty engine slot installs a client with no daemon to talk
# to. The engine is therefore taken from the pinned engine release and proven
# to be that release — digest against the pin, cosign against the pinned
# certificate identity, and the extracted tree's own commit and version — and a
# pin that names no release refuses the build here rather than producing a
# bundle nobody can support. The pin is bumped by editing engine/PIN.json; there
# is no way to ask for a different engine from the command line, because the
# engine a release shipped has to be readable off the commit that cut it.
prepare_engine() {
  local state target
  state="$(engine_pin_state "$ENGINE_PIN_DEFAULT_PATH")" || exit 1
  [ "$state" = "pinned" ] ||
    fail "a release ships an engine; engine/PIN.json is unpinned"

  "$ROOT_DIR/scripts/fetch_engine.sh" "$ENGINE_PIN_DEFAULT_PATH" "$ENGINE_DOWNLOAD"
  "$ROOT_DIR/scripts/verify_engine.sh" "$ENGINE_PIN_DEFAULT_PATH" \
    "$ENGINE_DOWNLOAD" "$ENGINE_TREES"

  for target in "${ENGINE_PIN_TARGETS[@]}"; do
    ENGINE_FLAGS+=(--engine "$ENGINE_TREES/$target")
  done
}

main() {
  mkdir -p "$DIST"
  prepare_engine
  "$ROOT_DIR/scripts/stage_app.sh" "$VERSION" "$BUILD_NUMBER" "$APP" universal \
    "${ENGINE_FLAGS[@]}"
  "$ROOT_DIR/scripts/sign_app.sh" "$APP" "$MACOS_DEVELOPER_ID"
  # The composed gate over the signed bundle: layout, configured identity, both
  # property lists, the vendored contracts, the assets, the declared slots, and
  # the signing/architecture/entitlement inventory this release records.
  "$ROOT_DIR/scripts/verify_staged_app.sh" "$APP" universal signed release

  # Two-pass staple: notarize + staple the app first (offline-robust first launch),
  # then package it into a DMG and notarize + staple the DMG.
  ditto -c -k --keepParent "$APP" "$STAGE/$ARTIFACT_NAME.zip"
  notarize_and_wait "$STAGE/$ARTIFACT_NAME.zip"
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
