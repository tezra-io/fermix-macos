#!/usr/bin/env bash
#
# Verify one staged Fermix application bundle against the product configuration.
#
# This is the single place that answers "is this bundle the product we declared?"
# Three callers run it, so a layout regression fails the same way everywhere:
#
#   * scripts/stage_app.sh        immediately after staging, unsigned
#   * scripts/dev_run.sh          after the local ad-hoc signature
#   * scripts/package_release.sh  after the Developer ID signature
#
# Everything it asserts is derived, never restated: identity and layout come from
# Product.json through scripts/product_config.sh, the vendored wire contracts are
# checked against the CHECKSUMS.txt that shipped inside the bundle, and the
# vendor marks are checked against the source tree rather than a hand-written
# list. A gate whose expectations are typed out by hand rots the moment someone
# adds a file; these expectations move with the product.
#
# It ends by printing the signing, architecture, entitlement, and artifact
# inventory M34 section 7 requires. That output is the evidence a release or a
# Stage 0 gate records — it is deliberately on stdout rather than in a file so
# it appears in the CI log and in the operator's terminal without a second
# artifact to keep in step.
#
# Usage: verify_staged_app.sh <app-path> <architectures> <signature> [audience]
#                             [--engine-pin <pin.json>]
#   <architectures>  universal  both slices required (release and CI)
#                    native     the building machine's slice only (dev_run.sh)
#   <signature>      unsigned   straight out of stage_app.sh
#                    signed     after sign_app.sh, ad-hoc or Developer ID
#   [audience]       development  the default: a bundle for this machine
#                    release      a bundle that will leave this machine
#   --engine-pin     the engine pin the staged engine is judged against.
#                    Defaults to the repository's engine/PIN.json, which is what
#                    every release and CI caller means; the harness hands over a
#                    filled fixture pin, because the checked-in record ships
#                    unpinned and a gate that cannot be shown refusing is a gate
#                    nobody has checked.
#
# Two declared configurations rather than a strictness dial. A release bundle
# carries four promises a development one deliberately does not: it speaks no
# draft contract, the engine beside it serves the protocol it speaks and is the
# engine the pin names, and it has none of the app's debug-only configurations
# compiled into it (M34 section 15.0). A development bundle is also the only one
# that may be built `--configuration debug`, which is what those configurations
# need.
set -euo pipefail

USAGE="usage: verify_staged_app.sh <app-path> <architectures> <signature> [audience] [--engine-pin <pin.json>]"

APP="${1:?$USAGE}"
ARCHITECTURES="${2:?$USAGE}"
SIGNATURE="${3:?$USAGE}"
AUDIENCE="${4:-development}"

case "$AUDIENCE" in
  development | release) ;;
  *)
    echo "verify_staged_app: unknown audience '$AUDIENCE' (expected development or release)" >&2
    exit 1
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/sparkle.sh
source "$ROOT_DIR/scripts/sparkle.sh"
# shellcheck source=scripts/engine_pin.sh
source "$ROOT_DIR/scripts/engine_pin.sh"

ENGINE_PIN_PATH="$ENGINE_PIN_DEFAULT_PATH"
if [ "$#" -ge 5 ]; then
  [ "$5" = "--engine-pin" ] ||
    { echo "verify_staged_app: unknown argument '$5' ($USAGE)" >&2; exit 1; }
  ENGINE_PIN_PATH="${6:?--engine-pin needs a pin path}"
  [ "$#" -eq 6 ] ||
    { echo "verify_staged_app: unexpected arguments after --engine-pin ($USAGE)" >&2; exit 1; }
fi

SOURCE_RESOURCES="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
PRODUCT_NAME="$(product_config product_name)"
BUNDLE_ID="$(product_config bundle_identifier)"
URL_SCHEME="$(product_config url_scheme)"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"
MIN_SYSTEM_VERSION="$(product_config minimum_system_version)"
MICROPHONE_USAGE="$(product_config microphone_usage_description)"
ICON_NAME="$(product_config icon_file).icns"
RESOURCE_BUNDLE_NAME="$(product_config swift_resource_bundle_name)"
ENGINE_DIR="$APP/$(product_config engine_relative_path)"
TOOLS_DIR="$APP/$(product_config tools_relative_path)"
FRAMEWORKS_DIR="$APP/$(product_config frameworks_relative_path)"
# The runtime search path that resolves the framework's @rpath install name,
# derived from the slot rather than typed out: the GUI is linked from
# Contents/MacOS, so the path is the frameworks slot's own directory name one
# level up. Package.swift and project.yml restate the literal because neither
# can read JSON at link time, and scripts/check_product_config.sh gates them
# against this same derivation.
FRAMEWORKS_RPATH="@executable_path/../$(basename "$(product_config frameworks_relative_path)")"
SPARKLE_DIR="$FRAMEWORKS_DIR/$SPARKLE_FRAMEWORK_NAME"
SPARKLE_VERSION="$(product_config sparkle_version)"
SPARKLE_FEED_URL="$(product_config sparkle_feed_url)"

fail() {
  echo "verify_staged_app: $*" >&2
  exit 1
}

# The resource root of a bundle is Contents/Resources when the bundle is
# structured and the bundle itself when it is flat. SwiftPM emits the flat form
# for a single-architecture build and the structured form for the universal
# (xcbuild) one, so the question has to be asked of the bundle rather than
# assumed from the build mode.
resource_root() {
  local bundle="$1"
  if [ -d "$bundle/Contents/Resources" ]; then
    printf '%s\n' "$bundle/Contents/Resources"
    return 0
  fi
  printf '%s\n' "$bundle"
}

plist_value() {
  local file="$1" key="$2" value
  value="$(plutil -extract "$key" raw -o - "$file" 2>/dev/null)" ||
    fail "$(basename "$file") has no $key"
  printf '%s\n' "$value"
}

require_plist_value() {
  local file="$1" key="$2" expected="$3" actual
  actual="$(plist_value "$file" "$key")"
  [ "$actual" = "$expected" ] ||
    fail "$(basename "$file") $key is '$actual', but Product.json declares '$expected'"
}

require_slices() {
  local binary="$1" info
  info="$(lipo -info "$binary")" || fail "$binary is not a Mach-O file"
  case "$ARCHITECTURES" in
    universal)
      printf '%s' "$info" | grep -q "arm64" || fail "$binary is missing the arm64 slice"
      printf '%s' "$info" | grep -q "x86_64" || fail "$binary is missing the x86_64 slice"
      ;;
    native)
      printf '%s' "$info" | grep -q "$(uname -m)" ||
        fail "$binary is missing the $(uname -m) slice this machine runs"
      ;;
    *)
      fail "unknown architecture mode '$ARCHITECTURES' (expected universal or native)"
      ;;
  esac
}

check_bundle_identity() {
  [ -d "$APP" ] || fail "no staged bundle at $APP"
  [ "$(basename "$APP")" = "$APP_BUNDLE_NAME" ] ||
    fail "bundle is named $(basename "$APP"), but Product.json declares $APP_BUNDLE_NAME"
}

# Exactly two executables ship, and nothing else lives in Contents/MacOS. The
# count is asserted rather than the two names alone, so a third binary added by
# a future build step cannot ride along unnoticed.
check_executables() {
  local macos_dir="$APP/Contents/MacOS" staged
  for name in "$GUI_EXECUTABLE" "$AGENT_EXECUTABLE"; do
    [ -x "$macos_dir/$name" ] || fail "executable $name is not staged at $macos_dir/$name"
    require_slices "$macos_dir/$name"
  done
  staged="$(find "$macos_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$staged" = "2" ] ||
    fail "Contents/MacOS holds $staged entries; exactly $GUI_EXECUTABLE and $AGENT_EXECUTABLE may ship"
}

# Every Info.plist value Product.json owns is compared to the configuration.
# The two version fields are deliberately not: a release stamps them from its
# tag, so only their presence is a product invariant.
check_info_plist() {
  local plist="$APP/Contents/Info.plist"
  [ -f "$plist" ] || fail "Info.plist is not staged at $plist"
  plutil -lint "$plist" >/dev/null || fail "staged Info.plist is invalid"

  require_plist_value "$plist" CFBundleName "$PRODUCT_NAME"
  require_plist_value "$plist" CFBundleDisplayName "$PRODUCT_NAME"
  require_plist_value "$plist" CFBundleIdentifier "$BUNDLE_ID"
  require_plist_value "$plist" CFBundleExecutable "$GUI_EXECUTABLE"
  require_plist_value "$plist" CFBundleIconFile "$(product_config icon_file)"
  require_plist_value "$plist" FermixResourceBundleName "$RESOURCE_BUNDLE_NAME"
  require_plist_value "$plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION"
  require_plist_value "$plist" NSMicrophoneUsageDescription "$MICROPHONE_USAGE"
  # LSUIElement must be ABSENT: the code sets the accessory policy at launch
  # and promotes to a Dock app while a window is open; the plist key pins
  # UIElement and defeats that promotion (observed live on macOS 26.5).
  [ -z "$(plist_value "$plist" LSUIElement 2>/dev/null)" ] ||
    fail "staged Info.plist carries LSUIElement; activation policy is code-owned"
  require_plist_value "$plist" CFBundleURLTypes.0.CFBundleURLSchemes.0 "$URL_SCHEME"

  # The update policy (M34 section 6). The feed and the key are what make an
  # update discoverable and verifiable; both automatic-installation keys are
  # off because a replacement of this bundle has to run inside the update
  # transaction, and SUEnableAutomaticChecks must be ABSENT so Sparkle asks
  # once instead of the app deciding for the person.
  require_plist_value "$plist" SUFeedURL "$SPARKLE_FEED_URL"
  require_plist_value "$plist" SUAutomaticallyUpdate false
  require_plist_value "$plist" SUAllowsAutomaticUpdates false
  [ -z "$(plist_value "$plist" SUEnableAutomaticChecks 2>/dev/null)" ] ||
    fail "staged Info.plist pins SUEnableAutomaticChecks; the check preference is the user's"

  [ -n "$(plist_value "$plist" CFBundleShortVersionString)" ] ||
    fail "staged Info.plist carries no marketing version"
  [ -n "$(plist_value "$plist" CFBundleVersion)" ] ||
    fail "staged Info.plist carries no build number"

  # The update public key is the third field whose presence is the product
  # invariant and whose value is not: Product.json carries the production key
  # and a release stamps it from there. The value is judged by the release
  # audience, which refuses the placeholder tripwire, because a bundle that can
  # verify no update is only a problem once it leaves this machine.
  [ -n "$(plist_value "$plist" SUPublicEDKey)" ] ||
    fail "staged Info.plist carries no update public key"
}

# The updater framework, its retained helpers, and the two facts that decide
# whether it can be loaded at all.
#
# A framework is a tree of symbolic links into Versions/Current, and a copy
# that resolved them into real directories produces a bundle that stages,
# signs, and then fails at dyld — so the links are asserted rather than the
# file count. The version is read out of the framework and compared with the
# pin, so a bundle carrying a build nobody pinned is refused here rather than
# discovered from a crash report.
check_sparkle_framework() {
  local staged member link version
  [ -d "$FRAMEWORKS_DIR" ] ||
    fail "the updater framework slot is missing at $FRAMEWORKS_DIR"
  [ -d "$SPARKLE_DIR" ] ||
    fail "$SPARKLE_FRAMEWORK_NAME is not staged at $SPARKLE_DIR"
  staged="$(find "$FRAMEWORKS_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$staged" = "1" ] ||
    fail "Contents/Frameworks holds $staged entries; only $SPARKLE_FRAMEWORK_NAME may ship"

  for link in "${SPARKLE_REQUIRED_SYMLINKS[@]}"; do
    [ -L "$SPARKLE_DIR/$link" ] ||
      fail "$SPARKLE_FRAMEWORK_NAME/$link is not a symbolic link; the framework was flattened and cannot load"
  done

  for member in "${SPARKLE_MACHO_PATHS[@]}"; do
    [ -x "$SPARKLE_DIR/$member" ] ||
      fail "the updater framework carries no executable $member"
    require_slices "$SPARKLE_DIR/$member"
  done

  version="$(sparkle_embedded_version "$SPARKLE_DIR")" ||
    fail "the staged updater framework declares no version"
  [ "$version" = "$SPARKLE_VERSION" ] ||
    fail "the staged updater framework is $version, but Product.json pins $SPARKLE_VERSION"
}

# Which executable may load the updater, asked of the built binaries rather
# than of the build files that were supposed to arrange it.
#
# M34 section 6: the daemon and the agent never load Sparkle. Both executables
# link the same core library, so the whole separation rests on the updater
# living in a target only the GUI links — a one-line dependency edit undoes it
# silently, and the agent would then carry an updater it must never run.
check_sparkle_linkage() {
  local gui agent
  gui="$APP/Contents/MacOS/$GUI_EXECUTABLE"
  agent="$APP/Contents/MacOS/$AGENT_EXECUTABLE"

  otool -L "$gui" | grep -q "$SPARKLE_FRAMEWORK_NAME" ||
    fail "the GUI does not link $SPARKLE_FRAMEWORK_NAME; the staged framework would never load"
  otool -l "$gui" | grep -q "$FRAMEWORKS_RPATH" ||
    fail "the GUI carries no $FRAMEWORKS_RPATH runtime search path"

  if otool -L "$agent" | grep -q "$SPARKLE_FRAMEWORK_NAME"; then
    fail "the agent links $SPARKLE_FRAMEWORK_NAME; only the GUI may"
  fi
}

# SMAppService.agent(plistName:) reads exactly this path out of the bundle, and
# launchd resolves BundleProgram against the bundle around it.
check_launch_agent() {
  local dir="$APP/Contents/Library/LaunchAgents" plist staged
  plist="$dir/$AGENT_LABEL.plist"
  [ -f "$plist" ] || fail "LaunchAgents plist is not staged at $plist"
  plutil -lint "$plist" >/dev/null || fail "staged LaunchAgents plist is invalid"
  require_plist_value "$plist" Label "$AGENT_LABEL"
  require_plist_value "$plist" BundleProgram "Contents/MacOS/$AGENT_EXECUTABLE"
  require_plist_value "$plist" AssociatedBundleIdentifiers.0 "$BUNDLE_ID"
  staged="$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$staged" = "1" ] || fail "Contents/Library/LaunchAgents holds $staged entries; only $AGENT_LABEL.plist may ship"
}

# The vendored wire contracts are checked against the CHECKSUMS.txt that shipped
# beside them, so the assertion covers every vendored file without this script
# holding a list of them.
check_vendored_contracts() {
  local resources contracts
  resources="$(resource_root "$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME")"
  contracts="$resources/Contracts"
  [ -d "$contracts" ] || fail "vendored wire contracts are not staged at $contracts"
  [ -f "$contracts/SOURCE.json" ] || fail "vendored contract provenance record is not staged"
  ( cd "$contracts" && shasum -a 256 -c CHECKSUMS.txt >/dev/null ) ||
    fail "staged wire contracts do not match the CHECKSUMS.txt shipped beside them"
}

# Every mark in the source tree must have reached the bundle, and the record
# that describes them must travel with them.
check_staged_assets() {
  local resources marks source_marks name record
  resources="$(resource_root "$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME")"
  marks="$resources/VendorMarks"
  # Both records travel with the marks: PROVENANCE.json describes each vendor,
  # and ROSTER.json is the vendored roster it is proven complete against.
  for record in PROVENANCE.json ROSTER.json; do
    [ -f "$marks/$record" ] || fail "vendor mark record $record is not staged at $marks"
  done
  source_marks="$SOURCE_RESOURCES/VendorMarks"
  # Every mark file, whatever it is drawn in. Enumerating `*.svg` alone left the
  # seven PNG marks and the one WEBP the tree ships unasserted, so a mark that
  # never reached the bundle shipped as a blank tile. The records themselves are
  # excluded: they are checked by name above.
  #
  # Fed through a here-document rather than a pipe: a pipeline would run the
  # loop in a subshell, where fail() could not stop this script.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$marks/$name" ] || fail "vendor mark $name is not staged"
  done <<MARKS
$(cd "$source_marks" && find . -type f ! -name '*.json' | sed 's|^\./||')
MARKS
  for asset in "Product.json" "en.lproj/Localizable.strings" "FermixMarkTemplate.png"; do
    [ -f "$resources/$asset" ] || fail "$asset is not staged in the resource bundle"
  done
  [ -f "$APP/Contents/Resources/$ICON_NAME" ] || fail "app icon is not staged at Contents/Resources/$ICON_NAME"
}

# The engine and tools slots are declared by Product.json. Each is in exactly
# one of two deliberate states: EMPTY (the pre-Stage-0 build) or POPULATED with
# the daemon's app-engine release trees / the bundled cosign, staged by
# stage_app.sh --engine/--cosign. Anything else — a file where a tree should
# be, an unknown architecture, a tree without its manifest — is a staging bug.
ENGINE_STATE="empty"
TOOLS_STATE="empty"

engine_manifest_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["identity"][sys.argv[2]])
except Exception:
    sys.exit(1)
PY
}

check_engine_slot() {
  [ -d "$ENGINE_DIR" ] || fail "declared slot is missing at $ENGINE_DIR"
  [ -d "$TOOLS_DIR" ] || fail "declared slot is missing at $TOOLS_DIR"

  if [ -n "$(find "$ENGINE_DIR" -mindepth 1 -print -quit)" ]; then
    check_engine_trees
  fi

  if [ -n "$(find "$TOOLS_DIR" -mindepth 1 -print -quit)" ]; then
    [ -x "$TOOLS_DIR/cosign" ] ||
      fail "the tools slot is populated but carries no executable cosign"
    local extra
    extra="$(find "$TOOLS_DIR" -mindepth 1 ! -name cosign -print -quit)"
    [ -z "$extra" ] || fail "unexpected content in the tools slot: $extra"
    TOOLS_STATE="cosign"
  fi
}

check_engine_trees() {
  local entry arch manifest found=""
  for entry in "$ENGINE_DIR"/*; do
    [ -d "$entry" ] || fail "unexpected file in the engine slot: $entry"
    arch="$(basename "$entry")"
    case "$arch" in
      arm64 | x86_64) ;;
      *) fail "engine slot carries unsupported architecture directory '$arch'" ;;
    esac
    manifest="$entry/engine-manifest.json"
    [ -f "$manifest" ] || fail "engine tree $arch carries no engine-manifest.json"
    [ "$(engine_manifest_field "$manifest" architecture)" = "$arch" ] ||
      fail "engine manifest in the $arch tree declares a different architecture"
    [ "$(engine_manifest_field "$manifest" distribution_identity)" = "macos_app" ] ||
      fail "engine tree $arch does not declare the macos_app distribution identity"
    [ -x "$entry/bin/fermix_app_engine" ] ||
      fail "engine tree $arch carries no executable bin/fermix_app_engine"
    found="$found $arch"
  done

  case "$ARCHITECTURES" in
    universal)
      case "$found" in
        *arm64*) ;;
        *) fail "a universal bundle's populated engine slot needs an arm64 tree (found:${found:- none})" ;;
      esac
      case "$found" in
        *x86_64*) ;;
        *) fail "a universal bundle's populated engine slot needs an x86_64 tree (found:${found:- none})" ;;
      esac
      ;;
    native)
      local host
      host="$(uname -m)"
      case "$found" in
        *"$host"*) ;;
        *) fail "a native bundle's engine slot must carry the $host tree this machine runs (found:${found:- none})" ;;
      esac
      ;;
  esac

  ENGINE_STATE="${found# }"
}

# The promises a release bundle makes and a development one does not: it speaks
# a published, non-draft contract, the engine beside it serves the protocol it
# speaks, it is Developer ID signed, it has none of the app's debug-only
# configurations compiled into it, and it can verify an update it is offered.
#
# Section 15.0's engine-first rule is procedural, and nothing in the repo gated
# it: an app built against the draft contract would launch a v1 engine while
# speaking v2, so every v2 read refuses, the assistant cannot finish, every pane
# says "Restart to finish updating", and the restart it asks for changes nothing
# because the build ids already match.
check_release_promises() {
  [ "$AUDIENCE" = "release" ] || return 0

  require_plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString "$(product_config marketing_version)"
  require_plist_value "$APP/Contents/Info.plist" CFBundleVersion "$(product_config build_number)"

  local resources contracts drafts unpublished speaks entry manifest window status
  resources="$(resource_root "$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME")"
  contracts="$resources/Contracts"

  drafts="$(python3 "$ROOT_DIR/scripts/contract_release_facts.py" drafts "$contracts/SOURCE.json")"
  [ -z "$drafts" ] || fail "a release bundle speaks a draft contract: $drafts"

  # A contract vendored from an upstream WORKING TREE is not a published one.
  # The bytes may be perfect and still name a commit that does not carry them,
  # so nothing downstream can ever re-take the pin or prove what shipped. The
  # pin has to be re-taken from the commit that publishes the protocol before a
  # release is cut; until then this refuses, which is the truth about the tree
  # and not a defect in the gate.
  unpublished="$(python3 "$ROOT_DIR/scripts/contract_release_facts.py" unpublished "$contracts/SOURCE.json")"
  [ -z "$unpublished" ] ||
    fail "a release bundle speaks a contract vendored from an uncommitted upstream tree: $unpublished"

  # The version the app speaks, read from the staged record rather than from a
  # number written here: one fact, in the checksum-pinned artifact.
  speaks="$(python3 "$ROOT_DIR/scripts/contract_release_facts.py" speaks "$contracts/SOURCE.json")"

  for entry in "$ENGINE_DIR"/*; do
    [ -d "$entry" ] || continue
    manifest="$entry/engine-manifest.json"
    window="$(python3 "$ROOT_DIR/scripts/contract_release_facts.py" serves "$manifest" "$speaks")"
    [ "$window" = "ok" ] ||
      fail "the engine in $(basename "$entry") does not serve management protocol $speaks"
  done

  check_engine_matches_pin
  check_release_signature
  check_debug_only_configurations
  check_production_update_key
}

# The engine staged inside a release bundle is the engine the pin names.
#
# scripts/verify_engine.sh already proves this at fetch time, and it proves it
# about a tarball. This proves it about the bundle that is actually about to be
# signed, which is the artifact that leaves the machine: a tree copied in by
# hand, a second stage_app.sh run with a stale --engine, or a pin bumped after
# the trees were extracted all produce a DMG whose engine no record vouches for.
# Two facts are compared because the pin carries two: the commit the engine was
# built from, which is what makes the DMG traceable, and the tag, which is what
# an upgrade and a support question are named by.
#
# An empty engine slot is the pre-Stage-0 declared state and has nothing to
# compare; a populated one with no pin behind it is refused rather than waved
# through, because "an engine nobody recorded" is the state this exists to stop.
check_engine_matches_pin() {
  local state commit version entry manifest tree_commit tree_version
  # Whether the slot is populated is check_engine_slot's answer, taken from it
  # rather than asked of the filesystem a second time.
  [ "$ENGINE_STATE" != "empty" ] || return 0

  state="$(engine_pin_state "$ENGINE_PIN_PATH")" || exit 1
  [ "$state" = "pinned" ] ||
    fail "a release bundle carries an engine and $ENGINE_PIN_PATH is unpinned"

  commit="$(engine_pin_field "$ENGINE_PIN_PATH" source_commit)"
  version="$(engine_pin_field "$ENGINE_PIN_PATH" version)"

  for entry in "$ENGINE_DIR"/*; do
    [ -d "$entry" ] || continue
    manifest="$entry/engine-manifest.json"
    tree_commit="$(engine_manifest_field "$manifest" source_commit)" ||
      fail "the engine in $(basename "$entry") declares no source commit"
    [ "$tree_commit" = "$commit" ] ||
      fail "the engine in $(basename "$entry") was built from $tree_commit, and the engine pin names $commit"
    tree_version="$(engine_manifest_field "$manifest" product_version)" ||
      fail "the engine in $(basename "$entry") declares no product version"
    [ "$tree_version" = "$version" ] ||
      fail "the engine in $(basename "$entry") is version $tree_version, and the engine pin names $version"
  done
}

# A release bundle is Developer ID signed.
#
# This is not a preference. Under the hardened runtime macOS validates every
# library a process loads against the process's own team, and an ad-hoc
# signature has no team at all, so an ad-hoc bundle carrying the updater
# framework cannot load it and cannot launch: dyld refuses the mapping and the
# process dies before main. The launch probe below would then report a binary
# that died of a signal, which is true and names the wrong cause.
#
# Only a signed bundle is judged. An unsigned one has no signature to read,
# and the kernel's own ad-hoc signature carries no hardened-runtime flag, so it
# loads its framework and launches.
check_release_signature() {
  local description
  [ "$SIGNATURE" = "signed" ] || return 0
  description="$(codesign -dv "$APP" 2>&1)" ||
    fail "a release bundle claims to be signed and carries no signature"
  if printf '%s\n' "$description" | grep -qFx "TeamIdentifier=not set"; then
    fail "a release bundle is ad-hoc signed; a release is Developer ID signed, and under the hardened runtime an ad-hoc signature cannot load the embedded $SPARKLE_FRAMEWORK_NAME"
  fi
}

# The app can verify an update it is offered.
#
# SUPublicEDKey is the only thing standing between the feed and arbitrary
# code. Product.json carries the production key, and sparkle.sh's placeholder
# is the tripwire this refuses: a bundle carrying it is not a weaker release,
# it is one whose updates can never install, and the failure would appear
# months later as a feed nobody can consume. The shape is checked too, so a
# key that is merely not the placeholder cannot pass for one.
check_production_update_key() {
  local staged
  staged="$(plist_value "$APP/Contents/Info.plist" SUPublicEDKey)"
  [ "$staged" != "$SPARKLE_PLACEHOLDER_PUBLIC_ED_KEY" ] ||
    fail "a release bundle carries the placeholder SUPublicEDKey; no update it is offered can be verified"
  python3 - "$staged" <<'PY' || fail "SUPublicEDKey must be a base64-encoded 32-byte Ed25519 public key"
import base64
import binascii
import sys

try:
    key = base64.b64decode(sys.argv[1], validate=True)
except (binascii.Error, ValueError):
    sys.exit(1)
sys.exit(0 if len(key) == 32 else 1)
PY
}

# The sentence a release build refuses a debug-only flag with, and the status it
# exits on. Both are asserted rather than "any non-zero exit": a binary that
# crashed, or that a headless runner signalled, exits non-zero too, and reading
# that as a refusal is how a build carrying the configuration passes the one
# gate that exists to catch it.
LAUNCH_REFUSAL_SENTENCE="compiled into debug builds only"
LAUNCH_REFUSAL_STATUS=2

# The app's debug-only configurations, and the two ways a release binary is
# asked whether it carries one: it must refuse the launch flag with the release
# build's own sentence and status, and it must carry none of that
# configuration's own symbols.
#
# Each symbol is measured rather than guessed, and each needle names ONE
# declaration rather than a word. `FixtureConfiguration` matched nothing in a
# debug build either, because it is a file name and not a type; a bare
# `developmentEngine` matched the two launch-request helpers that are compiled
# into EVERY build, so the row passed only because the optimiser inlined them.
# The mangled fragments below are `FermixAppCore.FixtureMachine` (the class the
# fixture configuration is built around) and
# `FermixAppCore.AppEnvironment.developmentEngine()` (the one entry point into
# the development configuration), neither of which a release build compiles.
#
# Fed through a here-document rather than a pipe: a pipeline would run the loop
# in a subshell, where fail() could not stop this script.
check_debug_only_configurations() {
  local flag symbol binary
  binary="$APP/Contents/MacOS/$GUI_EXECUTABLE"
  while read -r flag symbol; do
    [ -n "$flag" ] || continue
    refuses_flag "$binary" "$flag"
    ! nm -U "$binary" 2>/dev/null | grep -q "$symbol" ||
      fail "the staged binary carries $symbol symbols, so $flag is compiled into it"
  done <<CONFIGURATIONS
--fixture 14FixtureMachineC
--development-engine EnvironmentV17developmentEngine
CONFIGURATIONS
}

# How long a refusal is given to arrive. A release build prints one sentence and
# exits immediately; this is a bound, not a wait to tune.
LAUNCH_REFUSAL_DEADLINE=10

# Asserts the binary refuses this flag the way a release build refuses it,
# inside that bound. Fails with the reason it did not.
#
# A build that CARRIES the configuration does not exit at all: it opens the
# application and stays up, so an unbounded launch turns this gate into a hang
# rather than a refusal, which is what a debug bundle handed to the release
# audience did for the whole life of the check. Anything still running at the
# deadline has accepted the flag, and is killed rather than left behind.
refuses_flag() {
  local binary="$1" flag="$2" pid watchdog killed output status=0
  killed="$(mktemp -u)"
  output="$(mktemp)"
  "$binary" "$flag" >/dev/null 2>"$output" &
  pid=$!
  (
    sleep "$LAUNCH_REFUSAL_DEADLINE"
    kill -0 "$pid" 2>/dev/null || exit 0
    : >"$killed"
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  watchdog=$!

  wait "$pid" || status=$?
  kill -KILL "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  # Two shapes of acceptance: the binary opened the application and stayed up
  # until the watchdog killed it, or it ran the configuration and exited
  # cleanly. Both mean the flag named something this binary can do.
  if [ -f "$killed" ] || [ "$status" = "0" ]; then
    rm -f "$killed" "$output"
    fail "the staged binary accepted $flag; a release build has no such configuration"
  fi

  # A signal is not a refusal. Reported separately because the two have
  # different fixes: one is a bundle carrying a debug configuration, the other is
  # a binary this machine could not run at all.
  if [ "$status" -ge 128 ]; then
    rm -f "$output"
    fail "the staged binary died of signal $((status - 128)) on $flag rather than refusing it"
  fi

  if [ "$status" != "$LAUNCH_REFUSAL_STATUS" ]; then
    rm -f "$output"
    fail "the staged binary exited $status on $flag; a release refusal exits $LAUNCH_REFUSAL_STATUS"
  fi

  grep -qF -- "$LAUNCH_REFUSAL_SENTENCE" "$output" || {
    rm -f "$output"
    fail "the staged binary exited $status on $flag without saying it is a debug-only build"
  }
  rm -f "$output"
}

check_signature() {
  case "$SIGNATURE" in
    unsigned)
      return 0
      ;;
    signed)
      codesign --verify --deep --strict --verbose=2 "$APP" ||
        fail "staged bundle does not verify"
      # --deep seals resources, but the engine's VM is verified directly: an
      # unsigned beam.smp would otherwise surface only at the first
      # hardened-runtime launch. The bin/fermix_app_engine launcher is a shell
      # script — sealed as a resource, never itself signable code.
      if [ "$ENGINE_STATE" != "empty" ]; then
        local tree vm
        for tree in "$ENGINE_DIR"/*; do
          vm="$(find "$tree" -type f -name beam.smp -print -quit)"
          [ -n "$vm" ] || fail "engine tree carries no beam.smp: $tree"
          codesign --verify --strict "$vm" ||
            fail "engine VM is not validly signed: $vm"
        done
      fi
      ;;
    *)
      fail "unknown signature mode '$SIGNATURE' (expected unsigned or signed)"
      ;;
  esac
}

print_inventory() {
  echo "verify_staged_app: inventory for $APP"
  echo "  product        $PRODUCT_NAME ($BUNDLE_ID), scheme $URL_SCHEME"
  echo "  version        $(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString) build $(plist_value "$APP/Contents/Info.plist" CFBundleVersion)"
  echo "  floor          macOS $MIN_SYSTEM_VERSION, architectures $ARCHITECTURES"
  for name in "$GUI_EXECUTABLE" "$AGENT_EXECUTABLE"; do
    echo "  executable     $name: $(lipo -info "$APP/Contents/MacOS/$name" | sed 's/^.*are: //; s/^.*is architecture: //')"
  done
  echo "  login agent    $AGENT_LABEL.plist -> Contents/MacOS/$AGENT_EXECUTABLE"
  echo "  updater        $SPARKLE_FRAMEWORK_NAME $(sparkle_embedded_version "$SPARKLE_DIR"), GUI only"
  if [ "$ENGINE_STATE" = "empty" ]; then
    echo "  engine slot    empty (pre-Stage-0 declared state)"
  else
    echo "  engine slot    $ENGINE_STATE"
  fi
  if [ "$TOOLS_STATE" = "empty" ]; then
    echo "  tools slot     empty (pre-Stage-0 declared state)"
  else
    echo "  tools slot     $TOOLS_STATE"
  fi
  echo "  signature      $SIGNATURE"
  [ "$SIGNATURE" = "signed" ] || return 0
  codesign -d --entitlements - "$APP" 2>&1 | sed 's/^/  codesign       /'
}

check_bundle_identity
check_executables
check_info_plist
check_sparkle_framework
check_sparkle_linkage
check_launch_agent
check_vendored_contracts
check_staged_assets
check_engine_slot
check_release_promises
check_signature
print_inventory
echo "verify_staged_app: ok"
