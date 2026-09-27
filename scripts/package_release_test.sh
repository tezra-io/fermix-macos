#!/usr/bin/env bash
#
# Harness for scripts/package_release.sh.
#
# A release runs the script as two steps so each sees only the credentials it
# needs: `build` stages and signs with the Developer ID alone, and `notarize` is
# the one step the notary password reaches. This harness proves that contract
# through the refusals that come before any download, build, signature or
# notarization, so it needs no network, no certificate and no Apple account.
#
# Hermetic and host-safe. Every run gets a scrubbed environment, so no
# credential of the host's reaches the script, and every stage directory lives
# inside one mktemp directory; nothing is written to the checkout's dist/.
#
# Usage: package_release_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT_DIR/scripts/package_release.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "package_release_test: $*" >&2
  exit 1
}

# Runs the script with PATH and a throwaway HOME, plus the assignments given.
package() {
  env -i PATH="$PATH" HOME="$WORK_DIR" "$@"
}

expect_refusal() {
  local what="$1" expected="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected a refusal: $what"
  printf '%s' "$output" | grep -qF -- "$expected" ||
    fail "$what refused for the wrong reason: wanted '$expected', got: $(printf '%s' "$output" | tail -3)"
  echo "  ok   $what"
}

NOTARY=(MACOS_DEVELOPER_ID=- APPLE_ID=release@example.invalid APPLE_TEAM_ID=TEAMID0000)

echo "package_release_test: the phase contract"

expect_refusal "no phase" "usage:" package "$PACKAGE"
expect_refusal "an unknown phase" "usage:" \
  package MACOS_DEVELOPER_ID=- "$PACKAGE" dmg 0.3.0 5 "$WORK_DIR/stage"
expect_refusal "build without its stage directory" "usage:" \
  package MACOS_DEVELOPER_ID=- "$PACKAGE" build 0.3.0 5
expect_refusal "notarize without its stage directory" "usage:" \
  package "${NOTARY[@]}" APPLE_APP_PASSWORD=unused "$PACKAGE" notarize 0.3.0

expect_refusal "build without the signing identity" "MACOS_DEVELOPER_ID is required" \
  package "$PACKAGE" build 0.3.0 5 "$WORK_DIR/stage"

# No notary credential is anywhere in this environment, and build still gets
# past its own credential check to the stage it refuses: it never needs one.
stale="$WORK_DIR/stale"
mkdir -p "$stale"
touch "$stale/leftover"
expect_refusal "build needs no notary credential and refuses a stale stage" \
  "the stage directory already holds files" \
  package MACOS_DEVELOPER_ID=- "$PACKAGE" build 0.3.0 5 "$stale"

expect_refusal "notarize without the notary password" "APPLE_APP_PASSWORD is required" \
  package "${NOTARY[@]}" "$PACKAGE" notarize 0.3.0 "$WORK_DIR/stage"
expect_refusal "notarize with no app staged" "run package_release.sh build first" \
  package "${NOTARY[@]}" APPLE_APP_PASSWORD=unused "$PACKAGE" notarize 0.3.0 "$WORK_DIR/empty"

echo "package_release_test: ok"
