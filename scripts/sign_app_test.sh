#!/usr/bin/env bash
#
# Harness for scripts/sign_app.sh.
#
# The signing script's refusals are the ones nobody exercises by accident: they
# fire only on a release that is already going wrong. This harness fires them on
# purpose, against the same reference bundle the verifier harness uses.
#
# Hermetic and host-safe. Everything happens inside one mktemp directory, the
# only identity used is ad-hoc ("-"), which needs no certificate and never
# touches the keychain, and nothing is installed, registered, or launched.
#
# Usage: sign_app_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN="$ROOT_DIR/scripts/sign_app.sh"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/fake_staged_app.sh
source "$ROOT_DIR/scripts/fake_staged_app.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
BUNDLE_ID="$(product_config bundle_identifier)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "sign_app_test: $*" >&2
  exit 1
}

fresh_bundle() {
  local name="$1"
  mkdir -p "$WORK_DIR/$name"
  cp -R "$REFERENCE/." "$WORK_DIR/$name/"
  printf '%s\n' "$WORK_DIR/$name/$APP_BUNDLE_NAME"
}

expect_pass() {
  local what="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "expected to pass: $what"
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

echo "sign_app_test: the signing structure"

app="$(fresh_bundle adhoc)"
expect_pass "a staged bundle signs ad-hoc and verifies" "$SIGN" "$app" -

# The GUI is the only microphone principal, and the seal is over the app's own
# identifier rather than whatever the bundle happens to be called on disk.
gui_entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
agent_entitlements="$(codesign -d --entitlements - "$app/Contents/MacOS/$AGENT_EXECUTABLE" 2>&1)"
printf '%s' "$gui_entitlements" | grep -q "com.apple.security.device.audio-input" ||
  fail "the signed GUI does not carry the microphone entitlement"
if printf '%s' "$agent_entitlements" | grep -q "com.apple.security.device.audio-input"; then
  fail "the signed agent carries the microphone entitlement"
fi
# Captured before matching: `grep -q` exits at the first hit, which SIGPIPEs
# codesign, and pipefail would read that as a failed check.
signature="$(codesign -dv "$app" 2>&1)"
printf '%s' "$signature" | grep -q "Identifier=$BUNDLE_ID" ||
  fail "the signed bundle does not carry the configured identifier"
echo "  ok   the GUI is the only microphone principal, sealed under $BUNDLE_ID"

agent_signature="$(codesign -dv "$app/Contents/MacOS/$AGENT_EXECUTABLE" 2>&1)"
printf '%s\n' "$agent_signature" | grep -qFx "Identifier=$AGENT_LABEL" ||
  fail "the signed agent does not carry the configured identifier $AGENT_LABEL"
echo "  ok   the agent carries the stable configured identifier $AGENT_LABEL"

echo "sign_app_test: refusals"

app="$(fresh_bundle no-agent)"
rm "$app/Contents/MacOS/$AGENT_EXECUTABLE"
expect_refusal "a bundle with no agent to sign is refused" \
  "agent executable missing" \
  "$SIGN" "$app" -

# The engine and bundled-tools slots are declared signing classes: everything
# under them is signed individually — executables with the engine entitlement
# ladder, libraries and the bundled tool plain — instead of refusing the bundle.
app="$(fresh_bundle engine-tree)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64
fake_app_build_stub "$app/$(product_config tools_relative_path)/cosign" -arch arm64 -arch x86_64
expect_pass "a populated engine slot signs as its own class" "$SIGN" "$app" -
codesign --verify --strict \
  "$app/$(product_config engine_relative_path)/arm64/erts-0.0/bin/beam.smp" ||
  fail "the engine VM is not validly signed"
codesign --verify --strict "$app/$(product_config tools_relative_path)/cosign" ||
  fail "the bundled cosign is not validly signed"
echo "  ok   engine VM and bundled cosign carry valid signatures"

app="$(fresh_bundle stowaway)"
fake_app_build_stub "$app/Contents/Resources/helper" -arch arm64 -arch x86_64
expect_refusal "a stowaway Mach-O anywhere in the bundle is refused" \
  "Contents/Resources/helper" \
  "$SIGN" "$app" -

expect_refusal "a missing bundle is refused rather than silently signing nothing" \
  "no staged bundle at" \
  "$SIGN" "$WORK_DIR/absent.app" -

echo "sign_app_test: ok"
