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
# Usage: verify_staged_app.sh <app-path> <architectures> <signature>
#   <architectures>  universal  both slices required (release and CI)
#                    native     the building machine's slice only (dev_run.sh)
#   <signature>      unsigned   straight out of stage_app.sh
#                    signed     after sign_app.sh, ad-hoc or Developer ID
set -euo pipefail

APP="${1:?usage: verify_staged_app.sh <app-path> <architectures> <signature>}"
ARCHITECTURES="${2:?usage: verify_staged_app.sh <app-path> <architectures> <signature>}"
SIGNATURE="${3:?usage: verify_staged_app.sh <app-path> <architectures> <signature>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

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
  require_plist_value "$plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION"
  require_plist_value "$plist" NSMicrophoneUsageDescription "$MICROPHONE_USAGE"
  # LSUIElement must be ABSENT: the code sets the accessory policy at launch
  # and promotes to a Dock app while a window is open; the plist key pins
  # UIElement and defeats that promotion (observed live on macOS 26.5).
  [ -z "$(plist_value "$plist" LSUIElement 2>/dev/null)" ] ||
    fail "staged Info.plist carries LSUIElement; activation policy is code-owned"
  require_plist_value "$plist" CFBundleURLTypes.0.CFBundleURLSchemes.0 "$URL_SCHEME"

  [ -n "$(plist_value "$plist" CFBundleShortVersionString)" ] ||
    fail "staged Info.plist carries no marketing version"
  [ -n "$(plist_value "$plist" CFBundleVersion)" ] ||
    fail "staged Info.plist carries no build number"
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
  # Fed through a here-document rather than a pipe: a pipeline would run the
  # loop in a subshell, where fail() could not stop this script.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$marks/$name" ] || fail "vendor mark $name is not staged"
  done <<MARKS
$(cd "$source_marks" && find . -name '*.svg' | sed 's|^\./||')
MARKS
  for asset in "Product.json" "en.lproj/Localizable.strings" "FermixBoltTemplate.png"; do
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
check_launch_agent
check_vendored_contracts
check_staged_assets
check_engine_slot
check_signature
print_inventory
echo "verify_staged_app: ok"
