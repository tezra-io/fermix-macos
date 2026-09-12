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
# The updater facts are read directly below, so they are asked for directly
# rather than inherited through whatever fake_staged_app.sh happens to source.
# shellcheck source=scripts/sparkle.sh
source "$ROOT_DIR/scripts/sparkle.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"
RESOURCE_BUNDLE_NAME="$(product_config swift_resource_bundle_name)"

SOURCE_MARKS="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources/VendorMarks"
FRAMEWORKS_RELATIVE_PATH="$(product_config frameworks_relative_path)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "verify_staged_app_test: $*" >&2
  exit 1
}

# The two engine pins the release audience's engine cases stand on.
#
# The checked-in engine/PIN.json ships unpinned, because no engine release
# publishes the app-engine assets yet, so both states are written here instead:
# a filled pin that vouches for the identity a fixture engine tree declares, and
# an empty one. Standing on the repository's record would make these rows change
# meaning the day the engine is tagged — the filled row would compare a fixture
# tree against a real commit and the empty row would stop being empty.
#
# The digests are placeholders, and valid ones: this gate compares the commit
# and the version, and scripts/verify_engine_test.sh is where a digest decides
# anything.
FIXTURE_ENGINE_PIN="$WORK_DIR/engine-pin.json"
UNPINNED_ENGINE_PIN="$WORK_DIR/engine-pin-unpinned.json"
OTHER_ENGINE_SOURCE_COMMIT="fedcba9876543210fedcba9876543210fedcba98"

cat >"$FIXTURE_ENGINE_PIN" <<PIN
{
  "schema_version": 1,
  "repository": "tezra-io/fermix",
  "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
  "tag": "v$FAKE_APP_ENGINE_PRODUCT_VERSION",
  "source_commit": "$FAKE_APP_ENGINE_SOURCE_COMMIT",
  "certificate_identity": "https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v$FAKE_APP_ENGINE_PRODUCT_VERSION",
  "targets": {
    "macos_aarch64": {
      "asset": "fermix_app_engine_macos_aarch64.tar.gz",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "macos_x86_64": {
      "asset": "fermix_app_engine_macos_x86_64.tar.gz",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  },
  "note": "Fixture pin for scripts/verify_staged_app_test.sh."
}
PIN

cat >"$UNPINNED_ENGINE_PIN" <<'PIN'
{
  "schema_version": 1,
  "repository": "tezra-io/fermix",
  "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
  "tag": null,
  "source_commit": null,
  "certificate_identity": null,
  "targets": {
    "macos_aarch64": { "asset": null, "sha256": null },
    "macos_x86_64": { "asset": null, "sha256": null }
  },
  "note": "Unpinned fixture pin for scripts/verify_staged_app_test.sh."
}
PIN

# Each case gets its own copy of the reference bundle, so one mutation can never
# leak into the next.
fresh_bundle() {
  local name="$1" app
  app="$WORK_DIR/$name/$APP_BUNDLE_NAME"
  mkdir -p "$WORK_DIR/$name"
  cp -R "$REFERENCE/." "$WORK_DIR/$name/"
  printf '%s\n' "$app"
}

# The framework of a copy, which most updater cases mutate.
#
# Both halves are required to be non-empty: cases delete this path, and an empty
# interpolation is how a test once removed a root directory.
sparkle_framework() {
  printf '%s\n' "${1:?sparkle_framework: <app-path> is required}/${FRAMEWORKS_RELATIVE_PATH:?}/$SPARKLE_FRAMEWORK_NAME"
}

with_release_identity() {
  plutil -replace CFBundleShortVersionString -string "$(product_config marketing_version)" "$1/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$(product_config build_number)" "$1/Contents/Info.plist"
}

# Ad-hoc sign a copy inside-out, in sign_app.sh's order: the updater's helpers,
# then the framework, then the agent, then the app.
#
# Not a convenience — it is the only order that works. codesign refuses to seal
# an application over unsigned nested code, so a bundle carrying the updater
# cannot be signed outer-first at all.
#
# Every status is checked. codesign's own noise is suppressed because these
# cases are about the verifier's output, but a discarded status leaves the copy
# partly unsigned and the case then refuses for a reason nobody asked about.
adhoc_sign() {
  local app="$1" member framework
  framework="$(sparkle_framework "$app")"
  for member in "${SPARKLE_SIGNING_ORDER[@]}"; do
    codesign --force --timestamp=none --options runtime --sign - \
      "$framework/$member" >/dev/null 2>&1 ||
      fail "ad-hoc signing the updater's $member failed"
  done
  codesign --force --timestamp=none --options runtime --sign - \
    "$app/Contents/MacOS/$AGENT_EXECUTABLE" >/dev/null 2>&1 ||
    fail "ad-hoc signing the agent failed"
  codesign --force --timestamp=none --options runtime --sign - "$app" >/dev/null 2>&1 ||
    fail "ad-hoc signing the application failed"
}

expect_pass() {
  local what="$1"
  shift
  "$@" >/dev/null || fail "expected to pass: $what"
  echo "  ok   $what"
}

# Every GUI stand-in loads the updater the way the built GUI does.
#
# verify_staged_app.sh asks the binary itself which executable may load
# Sparkle, so a stand-in that linked nothing would refuse for that reason
# instead of the invariant its case is about. The flags land in
# FAKE_APP_SPARKLE_LINK because both are paths.
gui_stub_link_flags() {
  fake_app_sparkle_link_flags "${1%/Contents/MacOS/*}"
}

# A GUI stand-in that refuses every launch argument except one named here, the
# way a release build refuses it: the debug-only sentence on stderr, and exit 2.
# Each row of the release audience's configuration table can then be shown
# refusing on its own. `fake_app_build_stub` accepts everything, which only ever
# proves the first row.
#
# The exit status and the sentence are parameters so a stub can be built that
# exits non-zero WITHOUT refusing, which is what a crash and a signalled launch
# look like and what the gate used to count as a refusal.
build_argument_stub() {
  local out="$1" accepted="$2" status="${3:-2}" sentence="${4:-compiled into debug builds only}"
  local scratch
  scratch="$(dirname "$out")"
  mkdir -p "$scratch"
  cat >"$scratch/.argstub.c" <<'STUB'
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], ACCEPTED) != 0) {
            fprintf(stderr, "fermix: %s\n", SENTENCE);
            return STATUS;
        }
    }
    return 0;
}
STUB
  gui_stub_link_flags "$out"
  cc -DACCEPTED="\"$accepted\"" -DSTATUS="$status" -DSENTENCE="\"$sentence\"" \
    -arch arm64 -arch x86_64 "${FAKE_APP_SPARKLE_LINK[@]}" -o "$out" "$scratch/.argstub.c"
  rm -f "$scratch/.argstub.c"
}

# A stand-in that refuses both flags correctly and yet carries one of the
# debug-only configuration's own symbols, which is the half of the gate the
# binary's exit status cannot see. The symbol is defined with the exact mangled
# fragment the verifier greps for, so deleting either needle from the verifier
# makes one of these rows pass and the gate is shown to be load-bearing.
build_symbol_carrying_stub() {
  local out="$1" symbol="$2" scratch
  scratch="$(dirname "$out")"
  mkdir -p "$scratch"
  cat >"$scratch/.symstub.c" <<'STUB'
#include <stdio.h>
#include <string.h>

int CARRIED_SYMBOL(void) { return 0; }

int main(int argc, char **argv) {
    for (int index = 1; index < argc; index++) {
        fprintf(stderr, "fermix: compiled into debug builds only\n");
        return 2;
    }
    return CARRIED_SYMBOL();
}
STUB
  gui_stub_link_flags "$out"
  cc -DCARRIED_SYMBOL="$symbol" -arch arm64 -arch x86_64 \
    "${FAKE_APP_SPARKLE_LINK[@]}" -o "$out" "$scratch/.symstub.c"
  rm -f "$scratch/.symstub.c"
}

# A stand-in killed by a signal on every launch. Non-zero, and not a refusal:
# a headless runner or a crashing binary looks exactly like this, and reading it
# as "the flag was refused" is how a bundle carrying a debug configuration walks
# past the one gate that exists to catch it.
build_signalled_stub() {
  local out="$1" scratch
  scratch="$(dirname "$out")"
  mkdir -p "$scratch"
  cat >"$scratch/.sigstub.c" <<'STUB'
#include <signal.h>
#include <unistd.h>

int main(void) {
    kill(getpid(), SIGTERM);
    return 0;
}
STUB
  gui_stub_link_flags "$out"
  cc -arch arm64 -arch x86_64 "${FAKE_APP_SPARKLE_LINK[@]}" -o "$out" "$scratch/.sigstub.c"
  rm -f "$scratch/.sigstub.c"
}

# A GUI stand-in that never exits, which is what a build carrying the
# configuration actually does with the flag: it opens the application. Without
# the bound in the verifier this makes the gate hang instead of refusing.
build_never_exiting_stub() {
  local out="$1" scratch
  scratch="$(dirname "$out")"
  mkdir -p "$scratch"
  cat >"$scratch/.hangstub.c" <<'STUB'
#include <unistd.h>

int main(void) {
    for (;;) {
        sleep(60);
    }
    return 0;
}
STUB
  gui_stub_link_flags "$out"
  cc -arch arm64 -arch x86_64 "${FAKE_APP_SPARKLE_LINK[@]}" -o "$out" "$scratch/.hangstub.c"
  rm -f "$scratch/.hangstub.c"
}

# A copy of the reference bundle carrying a draft contract record, so the first
# release promise can be shown refusing. Nothing ships as a draft any more — the
# engine published protocol 2 and the app vendors it — and a gate that can never
# fire is a gate nobody has checked. The record is rewritten in the copy; the
# source tree is never touched, and SOURCE.json is not one of the files
# CHECKSUMS.txt pins.
draft_declaring_bundle() {
  local name="$1" app
  app="$(fresh_bundle "$name")"
  with_release_identity "$app"
  python3 - "$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/Contracts/SOURCE.json" <<'ADD_DRAFT'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
record["contracts"].append(
    {
        "name": "management_draft_v3",
        "draft": True,
        "source_directory": "apps/fermix_core/priv/management",
        "vendored_directory": "management",
        "protocol_version": 3,
        "committed_upstream": False,
        "files": [],
    }
)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
ADD_DRAFT
  printf '%s\n' "$app"
}

# A copy of the reference bundle whose contract records claim to have been
# vendored from a COMMIT, so the release audience's other promises can be shown
# on their own.
#
# The tree's real records say `committed_upstream: false` today — the engine's
# protocol 2 is published from a working tree and the pin has to be re-taken from
# the commit that carries it before a release. That is a fact about the tree, not
# a defect in the gate, and it is asserted in its own row below.
# The reference bundle with every contract's provenance set one way: published
# (committed upstream) or unpublished (a working-tree pin). The tree's own
# record is a commit today, so the refusal row edits a copy rather than
# depending on the state of the tree.
provenance_bundle() {
  local name="$1" committed="$2" app
  app="$(fresh_bundle "$name")"
  with_release_identity "$app"
  python3 - "$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/Contracts/SOURCE.json" "$committed" <<'PROVENANCE'
import json
import sys

path = sys.argv[1]
committed = sys.argv[2] == "true"
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
for contract in record["contracts"]:
    contract["committed_upstream"] = committed
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
PROVENANCE
  printf '%s\n' "$app"
}

published_bundle() { provenance_bundle "$1" true; }
unpublished_bundle() { provenance_bundle "$1" false; }

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

app="$(fresh_bundle wrong-resource-bundle-name)"
plutil -replace FermixResourceBundleName -string "Elsewhere.bundle" "$app/Contents/Info.plist"
expect_refusal "an app pointing at a different resource bundle is refused" \
  "FermixResourceBundleName is 'Elsewhere.bundle'" \
  "$VERIFY" "$app" universal unsigned

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

echo "verify_staged_app_test: the updater framework"

app="$(fresh_bundle no-sparkle)"
rm -rf "$(sparkle_framework "$app")"
expect_refusal "a bundle without the updater framework is refused" \
  "$SPARKLE_FRAMEWORK_NAME is not staged" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-frameworks-slot)"
rm -rf "${app:?}/${FRAMEWORKS_RELATIVE_PATH:?}"
expect_refusal "a bundle without the framework slot is refused" \
  "updater framework slot is missing" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle framework-stowaway)"
touch "$app/$FRAMEWORKS_RELATIVE_PATH/Extra.framework"
expect_refusal "a second framework beside the updater is refused" \
  "Contents/Frameworks holds 2 entries" \
  "$VERIFY" "$app" universal unsigned

# The failure a copy that resolved the framework's symbolic links produces: a
# tree that stages and signs and then cannot be loaded, because the install
# name resolves through Versions/Current.
app="$(fresh_bundle flattened-framework)"
framework="$(sparkle_framework "$app")"
rm "$framework/Versions/Current"
cp -R "$framework/Versions/B" "$framework/Versions/Current"
expect_refusal "a framework whose version link was flattened is refused" \
  "the framework was flattened and cannot load" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-autoupdate)"
rm "$(sparkle_framework "$app")/Versions/B/Autoupdate"
expect_refusal "an updater framework missing a retained helper is refused" \
  "carries no executable Versions/B/Autoupdate" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle thin-updater)"
fake_app_build_stub "$(sparkle_framework "$app")/Versions/B/Autoupdate" -arch arm64
expect_refusal "a single-slice updater helper is refused in universal mode" \
  "is missing the x86_64 slice" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle unpinned-updater)"
plutil -replace CFBundleShortVersionString -string "9.9.9" \
  "$(sparkle_framework "$app")/Versions/B/Resources/Info.plist"
expect_refusal "an updater framework that is not the pinned version is refused" \
  "but Product.json pins" \
  "$VERIFY" "$app" universal unsigned

# Which executable may load the updater, asked of the binaries. M34 section 6
# allows the GUI and forbids the agent, and both link the same core library,
# so the whole separation is one dependency edit away from being undone.
app="$(fresh_bundle gui-without-updater)"
fake_app_build_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" -arch arm64 -arch x86_64
expect_refusal "a GUI that does not link the updater is refused" \
  "the GUI does not link $SPARKLE_FRAMEWORK_NAME" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle agent-with-updater)"
fake_app_sparkle_link_flags "$app"
fake_app_build_stub "$app/Contents/MacOS/$AGENT_EXECUTABLE" \
  -arch arm64 -arch x86_64 "${FAKE_APP_SPARKLE_LINK[@]}"
expect_refusal "an agent that links the updater is refused" \
  "the agent links $SPARKLE_FRAMEWORK_NAME; only the GUI may" \
  "$VERIFY" "$app" universal unsigned

echo "verify_staged_app_test: the update policy in the Info.plist"

app="$(fresh_bundle wrong-feed)"
plutil -replace SUFeedURL -string "https://example.invalid/appcast.xml" \
  "$app/Contents/Info.plist"
expect_refusal "a feed url that drifted from the configuration is refused" \
  "SUFeedURL is" \
  "$VERIFY" "$app" universal unsigned

app="$(fresh_bundle no-public-key)"
plutil -remove SUPublicEDKey "$app/Contents/Info.plist"
expect_refusal "a bundle carrying no update public key is refused" \
  "carries no update public key" \
  "$VERIFY" "$app" universal unsigned

# Automatic installation is unavailable in this release: a replacement of the
# bundle has to run inside the update transaction that stops the engine first.
app="$(fresh_bundle automatic-installation)"
plutil -replace SUAllowsAutomaticUpdates -bool YES "$app/Contents/Info.plist"
expect_refusal "a bundle offering automatic installation is refused" \
  "SUAllowsAutomaticUpdates is 'true'" \
  "$VERIFY" "$app" universal unsigned

# The check preference belongs to the person: Sparkle asks once when the key
# is absent, and a pinned value answers for them on every launch.
app="$(fresh_bundle pinned-check-preference)"
plutil -insert SUEnableAutomaticChecks -bool YES "$app/Contents/Info.plist"
expect_refusal "a bundle pinning the automatic-check preference is refused" \
  "pins SUEnableAutomaticChecks" \
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

# The same invariant over a mark that is not an SVG. The enumeration was
# `*.svg` alone, so the seven PNG marks and the one WEBP the tree ships were
# never asserted staged and shipped as blank tiles when they went missing.
app="$(fresh_bundle no-raster-mark)"
raster="$(cd "$SOURCE_MARKS" && find . -type f ! -name '*.json' ! -name '*.svg' | sed 's|^\./||' | head -1)"
[ -n "$raster" ] || fail "the tree ships no non-SVG vendor mark to remove"
rm "$app/Contents/Resources/$RESOURCE_BUNDLE_NAME/VendorMarks/$raster"
expect_refusal "a non-SVG vendor mark that did not reach the bundle is refused" \
  "$raster is not staged" \
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
adhoc_sign "$app"
expect_pass "an ad-hoc signed bundle verifies" \
  "$VERIFY" "$app" universal signed

app="$(fresh_bundle adhoc-then-modified)"
adhoc_sign "$app"
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

expect_refusal "an unknown audience is refused" \
  "unknown audience" \
  "$VERIFY" "$REFERENCE/$APP_BUNDLE_NAME" universal unsigned staging

# The release audience's own promises (M34 section 15.0). The reference bundle
# ships the tree's real contract records, which no longer include a draft, so it
# is a release bundle once its provenance is a commit and its binary refuses the
# debug-only flags.
echo "verify_staged_app_test: the release audience"

expect_pass "the reference bundle verifies as a development bundle" \
  "$VERIFY" "$REFERENCE/$APP_BUNDLE_NAME" universal unsigned development

app="$(draft_declaring_bundle release-declaring-a-draft)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
expect_refusal "a release bundle speaking a draft contract is refused" \
  "speaks a draft contract" \
  "$VERIFY" "$app" universal unsigned release

# The provenance promise, both ways. The tree's own pin is the engine commit
# that publishes protocol 2, so a bundle built from it is a release bundle; a
# pin taken from a working tree is refused, on a copy whose record says so.
app="$(fresh_bundle release-from-a-committed-pin)"
with_release_identity "$app"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
expect_pass "a release bundle vendored from a committed upstream pin verifies" \
  "$VERIFY" "$app" universal unsigned release

app="$(unpublished_bundle release-from-an-uncommitted-tree)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
expect_refusal "a release bundle vendored from an uncommitted upstream tree is refused" \
  "vendored from an uncommitted upstream tree" \
  "$VERIFY" "$app" universal unsigned release

# The two debug-only configurations, one row at a time. Each is proven
# separately because a stub that refused everything would let a deleted row pass
# unnoticed, which is how the fixture row spent its whole life grepping for a
# symbol no build has ever carried.
app="$(published_bundle release-refusing-both-flags)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
expect_pass "a release bundle whose binary refuses both flags verifies" \
  "$VERIFY" "$app" universal unsigned release

app="$(published_bundle release-accepts-fixture)"
expect_refusal "a release bundle whose binary accepts --fixture is refused" \
  "accepted --fixture" \
  "$VERIFY" "$app" universal unsigned release

app="$(published_bundle release-accepts-development-engine)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" --development-engine
expect_refusal "a release bundle whose binary accepts --development-engine is refused" \
  "accepted --development-engine" \
  "$VERIFY" "$app" universal unsigned release

# A binary that opens the application instead of refusing is the shape a debug
# build actually has, and an unbounded launch made this row hang rather than
# fail. The refusal has to arrive inside the bound or the flag counts as
# accepted.
app="$(published_bundle release-never-exits)"
build_never_exiting_stub "$app/Contents/MacOS/$GUI_EXECUTABLE"
expect_refusal "a release bundle whose binary never exits is refused, not waited on" \
  "accepted --fixture" \
  "$VERIFY" "$app" universal unsigned release

# The same bundle is a perfectly good development one: the audience is what
# separates them, not a strictness dial.
expect_pass "a bundle carrying a debug-only configuration verifies as a development bundle" \
  "$VERIFY" "$app" universal unsigned development

# Non-zero is not a refusal. A binary that died of a signal and one that exited
# on some other status are both reported for what they are, because "any
# non-zero exit passes" is how a crashing launch counted as proof that the
# configuration is absent.
app="$(published_bundle release-signalled-launch)"
build_signalled_stub "$app/Contents/MacOS/$GUI_EXECUTABLE"
expect_refusal "a release bundle whose binary dies of a signal is refused as such" \
  "died of signal" \
  "$VERIFY" "$app" universal unsigned release

app="$(published_bundle release-wrong-refusal-status)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none 1
expect_refusal "a release bundle whose binary exits on the wrong status is refused" \
  "a release refusal exits 2" \
  "$VERIFY" "$app" universal unsigned release

app="$(published_bundle release-silent-refusal)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none 2 "something else went wrong"
expect_refusal "a release bundle that exits 2 without the debug-only sentence is refused" \
  "without saying it is a debug-only build" \
  "$VERIFY" "$app" universal unsigned release

# The symbol half of the same gate, which the exit status cannot see: a binary
# that refuses both flags and still carries the configuration's own code. Two
# rows, one per needle, so deleting either from the verifier fails here.
app="$(published_bundle release-carries-fixture-symbols)"
build_symbol_carrying_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" \
  "_\$s13FermixAppCore14FixtureMachineCACycfC"
expect_refusal "a release bundle carrying the fixture configuration's symbols is refused" \
  "so --fixture is compiled into it" \
  "$VERIFY" "$app" universal unsigned release

app="$(published_bundle release-carries-development-engine-symbols)"
build_symbol_carrying_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" \
  "_\$s13FermixAppCore0B11EnvironmentV17developmentEngineACyFZ"
expect_refusal "a release bundle carrying the development configuration's symbols is refused" \
  "so --development-engine is compiled into it" \
  "$VERIFY" "$app" universal unsigned release

# The second release promise: the engine beside the app serves the protocol the
# app speaks. The manifest is the real shape (`minimum_version` /
# `maximum_version`, which is what the daemon's release writes) because the gate
# read `minimum` / `maximum` for its whole life and raised a KeyError the first
# time a populated engine slot reached it.
app="$(published_bundle release-engine-serves-the-protocol)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64 1 2
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64 1 2
expect_pass "a release bundle whose engine window contains the version it speaks verifies" \
  "$VERIFY" "$app" universal unsigned release --engine-pin "$FIXTURE_ENGINE_PIN"

app="$(published_bundle release-engine-behind-the-app)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64 1 1
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64 1 1
expect_refusal "a release bundle whose engine does not serve the version it speaks is refused" \
  "does not serve management protocol" \
  "$VERIFY" "$app" universal unsigned release --engine-pin "$FIXTURE_ENGINE_PIN"

# The third release promise: the engine inside the bundle is the engine
# engine/PIN.json names. Both rows stand on the fixture pin, which vouches for
# the commit and version a fixture engine tree declares; the repository's own
# pin ships unpinned, and a gate proven only against an unpinned record is a
# gate that has never compared anything.
app="$(published_bundle release-engine-on-the-pin)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64 1 2
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64 1 2
expect_pass "a release bundle whose engine trees are the pinned engine verifies" \
  "$VERIFY" "$app" universal unsigned release --engine-pin "$FIXTURE_ENGINE_PIN"

# One tree off the pin is enough: a bundle whose two halves came from different
# engine commits is exactly what a re-staged release produces.
app="$(published_bundle release-engine-off-the-pin)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64 1 2 \
  "$OTHER_ENGINE_SOURCE_COMMIT"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64 1 2
expect_refusal "a release bundle whose engine was built from another commit is refused" \
  "and the engine pin names $FAKE_APP_ENGINE_SOURCE_COMMIT" \
  "$VERIFY" "$app" universal unsigned release --engine-pin "$FIXTURE_ENGINE_PIN"

# The state the repository ships in, asserted rather than assumed: an engine in
# the slot and no pin behind it is refused, so nothing can be staged into a
# release bundle before the engine tag is written down.
app="$(published_bundle release-engine-with-no-pin)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64 1 2
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/x86_64" x86_64 1 2
expect_refusal "a release bundle carrying an engine no pin vouches for is refused" \
  "is unpinned" \
  "$VERIFY" "$app" universal unsigned release --engine-pin "$UNPINNED_ENGINE_PIN"

# A release bundle is Developer ID signed, and the reason is mechanical: under
# the hardened runtime an ad-hoc signature has no team, so macOS refuses to map
# the embedded updater framework into the process and the app cannot launch at
# all. Without this the launch probe reports a binary that died of a signal,
# which is true and names the wrong cause.
app="$(published_bundle release-signed-ad-hoc)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
adhoc_sign "$app"
expect_refusal "an ad-hoc signed bundle is refused by the release audience" \
  "a release bundle is ad-hoc signed" \
  "$VERIFY" "$app" universal signed release

expect_pass "the same bundle verifies as a signed development bundle" \
  "$VERIFY" "$app" universal signed development

# The fourth release promise: an update this app is offered can be verified.
# Product.json carries the production key, so every other case stands on a
# bundle that already has one and this case writes the tripwire into its own
# copy. Reading the refusal off the rendered default is what tied this row to
# whatever Product.json happened to carry: the day the real key landed the row
# failed, and the cases after it never ran at all.
app="$(published_bundle release-with-the-placeholder-key)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
plutil -replace SUPublicEDKey -string "$SPARKLE_PLACEHOLDER_PUBLIC_ED_KEY" \
  "$app/Contents/Info.plist"
expect_refusal "a release bundle carrying the placeholder public key is refused" \
  "carries the placeholder SUPublicEDKey" \
  "$VERIFY" "$app" universal unsigned release

expect_pass "the same bundle is a perfectly good development one" \
  "$VERIFY" "$app" universal unsigned development

app="$(published_bundle release-with-an-invalid-key)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
plutil -replace SUPublicEDKey -string "not-base64" "$app/Contents/Info.plist"
expect_refusal "a malformed production public key is refused" \
  "32-byte Ed25519 public key" \
  "$VERIFY" "$app" universal unsigned release

app="$(published_bundle release-with-a-different-build)"
build_argument_stub "$app/Contents/MacOS/$GUI_EXECUTABLE" none
plutil -replace CFBundleVersion -string "999" "$app/Contents/Info.plist"
expect_refusal "a release build must match the product configuration" \
  "CFBundleVersion is" \
  "$VERIFY" "$app" universal unsigned release

echo "verify_staged_app_test: ok"
