#!/usr/bin/env bash
#
# Build Fermix and stage an UNSIGNED .app bundle.
#
# Shared by package_release.sh (which then signs, notarizes, and DMGs), by
# .github/workflows/fermix-app.yml (which stages + adhoc-signs on every push, so
# a build or bundle-layout regression is caught in ungated CI instead of only at
# a gated signed release), and by dev_run.sh (a local ad-hoc bundle). No
# credentials required.
#
# Product identity, executable names, the resource bundle name, the icon, and
# the engine and tools slots all come from Product.json through
# scripts/product_config.sh; the two property lists are rendered by
# scripts/render_info_plist.sh and scripts/render_launch_agent_plist.sh; and the
# staged result is checked by scripts/verify_staged_app.sh. Nothing about the
# product is restated here.
#
# Usage: stage_app.sh <version> <build_number> <out_app_path> <architectures>
#          [--configuration <debug|release>] [--engine <release-tree>]...
#          [--cosign <binary>]
#   <architectures>  universal  arm64 + x86_64, what a release and CI build
#                    native     this machine's slice only, for the dev loop
#   --configuration  release (the default) or debug. The DEVELOPMENT audience
#              only: the app's fixture and development-engine configurations
#              compile into debug builds alone, so `scripts/dev_e2e.sh` needs a
#              debug bundle to open with `--development-engine`.
#              package_release.sh never passes it, and
#              `verify_staged_app.sh <app> <arch> <sig> release` asserts a
#              shipped binary carries neither configuration.
#   --engine   a daemon app-engine release tree (carries engine-manifest.json);
#              repeat once per architecture. Without it the slot stages empty,
#              which remains the pre-Stage-0 declared state.
#   --cosign   the bundled plugin-verification tool for the Tools slot.
set -euo pipefail

USAGE="usage: stage_app.sh <version> <build_number> <out_app_path> <architectures> [--configuration <debug|release>] [--engine <tree>]... [--cosign <binary>]"
VERSION="${1:?$USAGE}"
BUILD_NUMBER="${2:?$USAGE}"
OUT_APP="${3:?$USAGE}"
ARCHITECTURES="${4:?$USAGE}"
shift 4

# The build step changes directory, so a relative out-path would silently land
# inside the package. Resolve it against the caller's directory first.
case "$OUT_APP" in
  /*) ;;
  *) OUT_APP="$PWD/$OUT_APP" ;;
esac

ENGINE_TREES=()
COSIGN_BIN=""
CONFIGURATION="release"
while [ $# -gt 0 ]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?--configuration needs debug or release}"
      case "$CONFIGURATION" in
        debug | release) ;;
        *)
          echo "stage_app: unknown configuration '$CONFIGURATION' (expected debug or release)" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --engine) ENGINE_TREES+=("${2:?--engine needs a release tree path}"); shift 2 ;;
    --cosign) COSIGN_BIN="${2:?--cosign needs a binary path}"; shift 2 ;;
    *) echo "stage_app: unknown argument '$1'" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/sparkle.sh
source "$ROOT_DIR/scripts/sparkle.sh"

GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
RESOURCE_BUNDLE_NAME="$(product_config swift_resource_bundle_name)"
ICON_NAME="$(product_config icon_file).icns"
AGENT_LABEL="$(product_config agent_service_label)"
ENGINE_RELATIVE_PATH="$(product_config engine_relative_path)"
TOOLS_RELATIVE_PATH="$(product_config tools_relative_path)"
FRAMEWORKS_RELATIVE_PATH="$(product_config frameworks_relative_path)"

APP_DIR="$ROOT_DIR/Apps/Fermix"
BUILD_PATH="$APP_DIR/.build-$CONFIGURATION"

fail() {
  echo "stage_app: $*" >&2
  exit 1
}

# One build invocation with one set of flags, decided once. The two modes are
# configurations of the same path, never a retry: universal is what ships, and
# native is the slice the dev loop declines to pay twice for.
case "$ARCHITECTURES" in
  universal) BUILD_FLAGS=(--arch arm64 --arch x86_64) ;;
  native) BUILD_FLAGS=(--arch "$(uname -m)") ;;
  *) fail "unknown architecture mode '$ARCHITECTURES' (expected universal or native)" ;;
esac

build() {
  cd "$APP_DIR"
  swift build -c "$CONFIGURATION" "${BUILD_FLAGS[@]}" --build-path "$BUILD_PATH"

  BIN_DIR="$(swift build -c "$CONFIGURATION" "${BUILD_FLAGS[@]}" --build-path "$BUILD_PATH" --show-bin-path)"
  GUI_BIN="$BIN_DIR/$GUI_EXECUTABLE"
  AGENT_BIN="$BIN_DIR/$AGENT_EXECUTABLE"
  RESOURCE_BUNDLE="$BIN_DIR/$RESOURCE_BUNDLE_NAME"

  [ -x "$GUI_BIN" ] || fail "built GUI binary missing: $GUI_BIN"
  [ -x "$AGENT_BIN" ] || fail "built agent binary missing: $AGENT_BIN"
  [ -d "$RESOURCE_BUNDLE" ] || fail "resource bundle missing: $RESOURCE_BUNDLE"
}

stage() {
  rm -rf "$OUT_APP"
  mkdir -p "$OUT_APP/Contents/MacOS" "$OUT_APP/Contents/Resources" \
    "$OUT_APP/Contents/Library/LaunchAgents"
  cp "$GUI_BIN" "$OUT_APP/Contents/MacOS/$GUI_EXECUTABLE"
  cp "$AGENT_BIN" "$OUT_APP/Contents/MacOS/$AGENT_EXECUTABLE"
  chmod 0755 "$OUT_APP/Contents/MacOS/$GUI_EXECUTABLE" "$OUT_APP/Contents/MacOS/$AGENT_EXECUTABLE"
  # The app icon comes from source, not the built bundle: the universal (xcbuild)
  # build nests it under the resource bundle's Contents/Resources (a structured
  # bundle), unlike the flat single-arch layout, so the source path is the one
  # stable location across both build systems.
  cp "$APP_DIR/Sources/FermixAppCore/Resources/$ICON_NAME" "$OUT_APP/Contents/Resources/$ICON_NAME"
  cp -R "$RESOURCE_BUNDLE" "$OUT_APP/Contents/Resources/$RESOURCE_BUNDLE_NAME"
  "$ROOT_DIR/scripts/render_info_plist.sh" "$VERSION" "$BUILD_NUMBER" "$OUT_APP/Contents/Info.plist"
  # SMAppService.agent(plistName:) reads this exact path out of the bundle.
  "$ROOT_DIR/scripts/render_launch_agent_plist.sh" \
    "$OUT_APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"
  # The two slots Product.json declares are always created. Without --engine
  # and --cosign they stage EMPTY — the pre-Stage-0 declared state — because
  # absence and emptiness mean different things: an absent slot is a staging
  # bug, an empty one is a deliberate state, and verify_staged_app.sh asserts
  # exactly that difference either way.
  mkdir -p "$OUT_APP/$ENGINE_RELATIVE_PATH" "$OUT_APP/$TOOLS_RELATIVE_PATH"
}

# The updater framework, embedded where the GUI's runtime search path looks for
# it. The GUI binary is linked against @rpath/Sparkle.framework/… with an rpath
# of @executable_path/../Frameworks (Package.swift and project.yml both set it),
# so an app without this directory launches to a dyld failure.
#
# `ditto` rather than `cp -R`: the framework's own signature seals its extended
# attributes, and one pass that reproduces the tree exactly — links, modes,
# attributes and resource forks together — is what keeps that seal valid. A copy
# that dropped an attribute stages and signs and then fails codesign --verify.
#
# The framework is not a slot like the engine and tools: it is a build product
# of the pinned dependency, so an absent one is a broken build rather than a
# declared empty state.
stage_sparkle() {
  local source destination version pinned
  source="$(sparkle_framework_source "$BUILD_PATH")" ||
    fail "the pinned updater framework is not in the resolved artifacts"

  pinned="$(product_config sparkle_version)"
  version="$(sparkle_embedded_version "$source")" ||
    fail "the resolved updater framework declares no version: $source"
  [ "$version" = "$pinned" ] ||
    fail "the resolved updater framework is $version, but Product.json pins $pinned"

  destination="$OUT_APP/$FRAMEWORKS_RELATIVE_PATH"
  mkdir -p "$destination"
  ditto "$source" "$destination/$SPARKLE_FRAMEWORK_NAME"
}

engine_manifest_architecture() {
  python3 - "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["identity"]["architecture"])
except Exception:
    sys.exit(1)
PY
}

stage_engine_and_tools() {
  local tree arch destination
  for tree in ${ENGINE_TREES[@]+"${ENGINE_TREES[@]}"}; do
    [ -f "$tree/engine-manifest.json" ] ||
      fail "engine tree carries no engine-manifest.json: $tree"
    [ -x "$tree/bin/fermix_app_engine" ] ||
      fail "engine tree carries no executable bin/fermix_app_engine: $tree"
    arch="$(engine_manifest_architecture "$tree/engine-manifest.json")" ||
      fail "engine manifest is not readable JSON with an architecture: $tree"
    case "$arch" in
      arm64 | x86_64) ;;
      *) fail "engine manifest declares unsupported architecture '$arch': $tree" ;;
    esac
    destination="$OUT_APP/$ENGINE_RELATIVE_PATH/$arch"
    [ ! -e "$destination" ] || fail "two engine trees declare architecture $arch"
    mkdir -p "$destination"
    cp -R "$tree/." "$destination/"
    # A release tree's tmp/ is runtime scratch, not product content; ship the
    # declared empty directory, never a build machine's leftovers.
    rm -rf "$destination/tmp"
    mkdir -p "$destination/tmp"
  done

  if [ -n "$COSIGN_BIN" ]; then
    [ -x "$COSIGN_BIN" ] || fail "cosign binary is not executable: $COSIGN_BIN"
    cp "$COSIGN_BIN" "$OUT_APP/$TOOLS_RELATIVE_PATH/cosign"
    chmod 0755 "$OUT_APP/$TOOLS_RELATIVE_PATH/cosign"
  fi
}

build
stage
stage_sparkle
stage_engine_and_tools
"$ROOT_DIR/scripts/verify_staged_app.sh" "$OUT_APP" "$ARCHITECTURES" unsigned
echo "stage_app: staged $OUT_APP ($CONFIGURATION)"
