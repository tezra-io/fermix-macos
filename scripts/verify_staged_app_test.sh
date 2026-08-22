#!/usr/bin/env bash
#
# Harness for scripts/verify_staged_app.sh.
#
# The verifier is the only gate standing between a broken bundle layout and a
# signed release, so it is tested the way a gate has to be tested: a bundle that
# should pass is built from the real product configuration and the real staged
# assets, and then each invariant is broken one at a time and the verifier is
# required to refuse for that reason and no other. A gate that cannot be shown
# refusing is a gate nobody has checked.
#
# Hermetic and host-safe. Everything is built inside one mktemp directory,
# nothing is installed, nothing is launched, and the only signing is ad-hoc
# ("-"), which needs no identity and never touches the keychain.
#
# Usage: verify_staged_app_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT_DIR/scripts/verify_staged_app.sh"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/fake_staged_app.sh
source "$ROOT_DIR/scripts/fake_staged_app.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"
RESOURCE_BUNDLE_NAME="$(product_config swift_resource_bundle_name)"
ICON_NAME="$(product_config icon_file).icns"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "verify_staged_app_test: $*" >&2
  exit 1
}

# Each case gets its own copy of the reference bundle, so one mutation can never
# leak into the next.
fresh_bundle() {
  local name="$1" app
  app="$WORK_DIR/$name/$APP_BUNDLE_NAME"
  mkdir -p "$WORK_DIR/$name"
  cp -R "$REFERENCE/." "$WORK_DIR/$name/"
  printf '%s\n' "$app"
}

expect_pass() {
  local what="$1"
  shift
  "$@" >/dev/null || fail "expected to pass: $what"
  echo "  ok   $what"
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

REFERENCE="$WORK_DIR/reference"
mkdir -p "$REFERENCE"
fake_app_build_bundle "$REFERENCE/$APP_BUNDLE_NAME"

echo "verify_staged_app_test: a correctly staged bundle"
expect_pass "the reference bundle verifies unsigned and universal" \
  "$VERIFY" "$REFERENCE/$APP_BUNDLE_NAME" universal unsigned

echo "verify_staged_app_test: structure"

app="$(fresh_bundle wrong-name)"
mv "$app" "$(dirname "$app")/Wrong.app"
expect_refusal "a bundle named something else is refused" \
  "but Product.json declares $APP_BUNDLE_NAME" \
  "$VERIFY" "$(dirname "$app")/Wrong.app" universal unsigned

app="$(fresh_bundle no-agent)"
rm "$app/Contents/MacOS/$AGENT_EXECUTABLE"
expect_refusal "a missing agent executable is refused" \
  "executable $AGENT_EXECUTABLE is not staged" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle extra-binary)"
fake_app_build_stub "$app/Contents/MacOS/Extra" -arch arm64 -arch x86_64
expect_refusal "a third executable in Contents/MacOS is refused" \
  "Contents/MacOS holds 3 entries" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle thin-binary)"
fake_app_build_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" -arch arm64
expect_refusal "a single-slice binary is refused in universal mode" \
  "is missing the x86_64 slice" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle foreign-binary)"
fake_app_build_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" -arch x86_64
expect_refusal "a binary without this machine's slice is refused in native mode" \
  "slice this machine runs" \
  "$VERIFY" "$app" native unsigned

echo "verify_staged_app_test: identity from the product configuration"

app="$(fresh_bundle wrong-identifier)"
plutil -replace CFBundleIdentifier -string "io.example.Other" "$app/Contents/Info.plist"
expect_refusal "an Info.plist identity that is not the configured one is refused" \
  "CFBundleIdentifier is 'io.example.Other'" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle wrong-usage-copy)"
plutil -replace NSMicrophoneUsageDescription -string "FermixPet needs your microphone" \
  "$app/Contents/Info.plist"
expect_refusal "an Info.plist usage string that drifted from the configuration is refused" \
  "NSMicrophoneUsageDescription is" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-version)"
plutil -remove CFBundleVersion "$app/Contents/Info.plist"
expect_refusal "an Info.plist without a build number is refused" \
  "has no CFBundleVersion" \
  "$VERIFY" "$app" universal unsigned

echo "verify_staged_app_test: the login agent"

app="$(fresh_bundle no-launch-agent)"
rm "$app/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"
expect_refusal "a missing LaunchAgents plist is refused" \
  "LaunchAgents plist is not staged" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle wrong-bundle-program)"
plutil -replace BundleProgram -string "Contents/MacOS/Elsewhere" \
  "$app/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"
expect_refusal "a LaunchAgents plist pointing elsewhere is refused" \
  "BundleProgram is 'Contents/MacOS/Elsewhere'" \
  "$VERIFY" "$app" universal unsigned

echo "verify_staged_app_test: vendored contracts and assets"

app="$(fresh_bundle tampered-contract)"
printf '\n' >>"$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/Contracts/management/PROTOCOL.md"
expect_refusal "an edited vendored contract is refused" \
  "do not match the CHECKSUMS.txt shipped beside them" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-contracts)"
rm -rf "$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/Contracts"
expect_refusal "a bundle shipping no wire contracts is refused" \
  "vendored wire contracts are not staged" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-mark)"
rm "$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/VendorMarks/channels/telegram-color.svg"
expect_refusal "a vendor mark that did not reach the bundle is refused" \
  "channels/telegram-color.svg is not staged" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-strings)"
rm "$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/en.lproj/Localizable.strings"
expect_refusal "a bundle shipping no product copy is refused" \
  "en.lproj/Localizable.strings is not staged" \
  "$VERIFY" "$app" universal unsigned

echo "verify_staged_app_test: the engine and tools slots"

app="$(fresh_bundle no-engine-slot)"
rmdir "$app/$(product_config engine_relative_path)"
expect_refusal "a bundle without the declared engine slot is refused" \
  "declared slot is missing" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle loose-engine-file)"
fake_app_build_stub "$app/$(product_config engine_relative_path)/beam.smp" -arch arm64 -arch x86_64
expect_refusal "a loose file where an engine tree should be is refused" \
  "unexpected file in the engine slot" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle engine-native)"
host_arch="$(uname -m)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/$host_arch" "$host_arch"
expect_pass "a native bundle with this machine's engine tree verifies" \
  "$VERIFY" "$app" native unsigned

app="$(fresh_bundle engine-universal)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64
expect_pass "a universal bundle with both engine trees verifies" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle engine-one-tree-universal)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64
expect_refusal "a universal bundle with one engine tree is refused" \
  "needs an x86_64 tree" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle engine-arch-mismatch)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" arm64
expect_refusal "an engine manifest disagreeing with its directory is refused" \
  "declares a different architecture" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle engine-no-manifest)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64
rm "$app/$(product_config engine_relative_path)/arm64/engine-manifest.json"
expect_refusal "an engine tree without its manifest is refused" \
  "carries no engine-manifest.json" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle filled-tools-slot)"
fake_app_build_stub "$app/$(product_config tools_relative_path)/cosign" -arch arm64 -arch x86_64
expect_pass "a populated tools slot carrying exactly cosign verifies" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle tools-stowaway)"
fake_app_build_stub "$app/$(product_config tools_relative_path)/cosign" -arch arm64 -arch x86_64
touch "$app/$(product_config tools_relative_path)/extra"
expect_refusal "anything beside cosign in the tools slot is refused" \
  "unexpected content in the tools slot" \
  "$VERIFY" "$app" universal unsigned

echo "verify_staged_app_test: the signature"

app="$(fresh_bundle unsigned-claimed-signed)"
expect_refusal "an unsigned bundle claimed as signed is refused" \
  "staged bundle does not verify" \
  "$VERIFY" "$app" universal signed

app="$(fresh_bundle adhoc-signed)"
codesign --force --timestamp=none --options runtime --sign - \
  "$app/Contents/MacOS/$AGENT_EXECUTABLE" >/dev/null 2>&1
codesign --force --timestamp=none --options runtime --sign - "$app" >/dev/null 2>&1
expect_pass "an ad-hoc signed bundle verifies" \
  "$VERIFY" "$app" universal signed

app="$(fresh_bundle adhoc-then-modified)"
codesign --force --timestamp=none --options runtime --sign - \
  "$app/Contents/MacOS/$AGENT_EXECUTABLE" >/dev/null 2>&1
codesign --force --timestamp=none --options runtime --sign - "$app" >/dev/null 2>&1
printf 'x' >>"$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/Product.json"
expect_refusal "a bundle modified after signing is refused" \
  "staged bundle does not verify" \
  "$VERIFY" "$app" universal signed

echo "verify_staged_app_test: argument validation"

expect_refusal "an unknown architecture mode is refused" \
  "unknown architecture mode" \
  "$VERIFY" "$REFERENCE/$APP_BUNDLE_NAME" fat unsigned

expect_refusal "an unknown signature mode is refused" \
  "unknown signature mode" \
  "$VERIFY" "$REFERENCE/$APP_BUNDLE_NAME" universal notarized

echo "verify_staged_app_test: ok"
