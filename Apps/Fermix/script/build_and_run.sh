#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/product_config.sh
source "$REPO_ROOT/scripts/product_config.sh"
# shellcheck source=../../scripts/sparkle.sh
source "$REPO_ROOT/scripts/sparkle.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
BUNDLE_ID="$(product_config bundle_identifier)"
RESOURCE_BUNDLE_NAME="$(product_config swift_resource_bundle_name)"
ICON_NAME="$(product_config icon_file).icns"

HOME_DIR="${HOME:-}"
CACHE_ROOT="${FERMIXPET_CACHE_DIR:-$HOME_DIR/Library/Caches/$BUNDLE_ID}"
SWIFTPM_BUILD_PATH="${FERMIXPET_SWIFTPM_BUILD_PATH:-$CACHE_ROOT/swiftpm-build}"
STAGING_DIR="${FERMIXPET_STAGE_DIR:-$CACHE_ROOT/app}"
INSTALL_DIR="${FERMIXPET_INSTALL_DIR:-$HOME_DIR/Applications}"
BUILD_CONFIGURATION="${FERMIXPET_SWIFT_CONFIGURATION:-debug}"
SIGN_IDENTITY="${FERMIXPET_SIGN_IDENTITY:-FermixPet Dev}"

case "$MODE" in
  install|--install)
    BUILD_CONFIGURATION="${FERMIXPET_SWIFT_CONFIGURATION:-release}"
    ;;
esac

APP_BUNDLE="$STAGING_DIR/$APP_BUNDLE_NAME"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$GUI_EXECUTABLE"
AGENT_BINARY="$APP_MACOS/$AGENT_EXECUTABLE"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_FRAMEWORKS="$APP_BUNDLE/$(product_config frameworks_relative_path)"
AGENT_LABEL="$(product_config agent_service_label)"
APP_LAUNCH_AGENTS="$APP_CONTENTS/Library/LaunchAgents"
INSTALLED_APP="$INSTALL_DIR/$APP_BUNDLE_NAME"

fail() {
  echo "error: $*" >&2
  exit 1
}

validate_paths() {
  [[ -n "$HOME_DIR" ]] || fail "HOME is not set"
  [[ -n "$CACHE_ROOT" ]] || fail "FERMIXPET_CACHE_DIR must not be empty"
  [[ -n "$SWIFTPM_BUILD_PATH" ]] || fail "FERMIXPET_SWIFTPM_BUILD_PATH must not be empty"
  [[ -n "$STAGING_DIR" ]] || fail "FERMIXPET_STAGE_DIR must not be empty"
  [[ -n "$INSTALL_DIR" ]] || fail "FERMIXPET_INSTALL_DIR must not be empty"
  [[ "$BUILD_CONFIGURATION" == "debug" || "$BUILD_CONFIGURATION" == "release" ]] ||
    fail "FERMIXPET_SWIFT_CONFIGURATION must be debug or release"
}

stop_running_app() {
  if pgrep -x "$GUI_EXECUTABLE" >/dev/null; then
    pkill -x "$GUI_EXECUTABLE"
  fi
}

write_launch_agent_plist() {
  # The same plist SMAppService.agent(plistName:) reads out of a released
  # bundle, so a dev install can register the background service exactly as a
  # shipped one does.
  mkdir -p "$APP_LAUNCH_AGENTS"
  "$REPO_ROOT/scripts/render_launch_agent_plist.sh" "$APP_LAUNCH_AGENTS/$AGENT_LABEL.plist"
}

write_info_plist() {
  # One Info.plist definition for the whole repository, rendered from
  # Product.json. A dev install carries the product version declared there.
  "$REPO_ROOT/scripts/render_info_plist.sh" \
    "$(product_config marketing_version)" \
    "$(product_config build_number)" \
    "$INFO_PLIST"
}

ensure_signing_identity() {
  # `-v` lists valid (trusted) identities only; a self-signed cert is untrusted,
  # so match on the codesigning policy without `-v`.
  if security find-identity -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    return 0
  fi

  echo "Creating self-signed code-signing identity \"$SIGN_IDENTITY\" (one-time)..."
  local dir cnf kc
  dir="$(mktemp -d)"
  cnf="$dir/cert.cnf"
  kc="$HOME_DIR/Library/Keychains/login.keychain-db"

  cat >"$cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $SIGN_IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" \
    -out "$dir/cert.pem" -days 3650 -config "$cnf" >/dev/null 2>&1 ||
    { rm -rf "$dir"; fail "failed to generate self-signed certificate"; }
  openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -name "$SIGN_IDENTITY" -out "$dir/identity.p12" -passout pass:fermixpet >/dev/null 2>&1 ||
    { rm -rf "$dir"; fail "failed to package certificate"; }
  security import "$dir/identity.p12" -k "$kc" -P fermixpet -T /usr/bin/codesign >/dev/null 2>&1 ||
    { rm -rf "$dir"; fail "failed to import certificate into login keychain"; }
  rm -rf "$dir"

  security find-identity -p codesigning | grep -qF "$SIGN_IDENTITY" ||
    fail "certificate import did not register identity \"$SIGN_IDENTITY\""
  echo "Created \"$SIGN_IDENTITY\". macOS will ask for your login password the first"
  echo "time codesign uses it - enter it and click \"Always Allow\" (asked once)."
}

# The updater framework, embedded where the GUI's runtime search path looks.
#
# The GUI is linked against @rpath/Sparkle.framework/…, so a dev install
# without this directory launches to a dyld failure. `ditto` rather than
# `cp -R`: it reproduces the tree exactly in one pass, extended attributes
# included, which is what the framework's own signature seals.
embed_sparkle_framework() {
  local source version pinned
  source="$(sparkle_framework_source "$SWIFTPM_BUILD_PATH")" ||
    fail "the pinned updater framework is not in the resolved artifacts"
  pinned="$(product_config sparkle_version)"
  version="$(sparkle_embedded_version "$source")" ||
    fail "the resolved updater framework declares no version"
  [[ "$version" == "$pinned" ]] ||
    fail "the resolved updater framework is $version, but Product.json pins $pinned"
  mkdir -p "$APP_FRAMEWORKS"
  ditto "$source" "$APP_FRAMEWORKS/$SPARKLE_FRAMEWORK_NAME"
}

sign_app_bundle() {
  # macOS TCC keys the microphone grant to the app's designated requirement,
  # which derives from the code signature. An ad-hoc signature has no stable
  # requirement (only a cdhash that changes on every `swift build`), so a stored
  # mic grant stops matching after the next rebuild and the OS silently denies
  # capture. Signing with a stable self-signed identity gives a constant
  # requirement across rebuilds, so the grant survives.
  ensure_signing_identity

  # Inside-out, exactly as scripts/sign_app.sh does: the updater's helpers
  # before the framework, the framework and the nested agent binary before the
  # bundle that seals them. codesign refuses to seal an application over
  # unsigned nested code, so this order is the only one that works.
  #
  # Deliberately without `--options runtime`, which is the one way this differs
  # from sign_app.sh: under the hardened runtime macOS validates every library
  # against the loading process's team, and this self-signed dev identity has
  # none, so a hardened dev app cannot load the framework it just embedded. A
  # release is Developer ID signed and hardened, and verify_staged_app.sh
  # refuses a release bundle that is not.
  local member
  for member in "${SPARKLE_SIGNING_ORDER[@]}"; do
    codesign --force --sign "$SIGN_IDENTITY" \
      "$APP_FRAMEWORKS/$SPARKLE_FRAMEWORK_NAME/$member"
  done
  codesign --force --sign "$SIGN_IDENTITY" "$AGENT_BINARY"

  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE"
}

stage_app_bundle() {
  local build_binary="$1"
  local build_agent_binary="$2"
  local build_resource_bundle="$3"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  cp "$build_agent_binary" "$AGENT_BINARY"
  cp "$build_resource_bundle/$ICON_NAME" "$APP_RESOURCES/$ICON_NAME"
  cp -R "$build_resource_bundle" "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME"
  chmod +x "$APP_BINARY" "$AGENT_BINARY"
  embed_sparkle_framework
  write_info_plist
  write_launch_agent_plist
  sign_app_bundle
}

build_app_bundle() {
  cd "$ROOT_DIR"
  mkdir -p "$SWIFTPM_BUILD_PATH" "$STAGING_DIR"
  swift build --build-path "$SWIFTPM_BUILD_PATH" -c "$BUILD_CONFIGURATION"

  local build_dir
  build_dir="$(swift build --build-path "$SWIFTPM_BUILD_PATH" -c "$BUILD_CONFIGURATION" --show-bin-path)"

  local build_binary="$build_dir/$GUI_EXECUTABLE"
  local build_agent_binary="$build_dir/$AGENT_EXECUTABLE"
  local build_resource_bundle="$build_dir/$RESOURCE_BUNDLE_NAME"
  test -x "$build_binary"
  test -x "$build_agent_binary"
  test -d "$build_resource_bundle"
  test -f "$build_resource_bundle/$ICON_NAME"
  stage_app_bundle "$build_binary" "$build_agent_binary" "$build_resource_bundle"
}

install_app() {
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
  echo "Installed $INSTALLED_APP"
}

open_app() {
  # No FERMIX_HOME pass-through: the GUI takes its home from the bootstrap
  # record at ~/Library/Application Support/Fermix/launcher.json and reads no
  # environment home, so handing it one here would only look like it worked.
  /usr/bin/open -n "$APP_BUNDLE"
}

usage() {
  echo "usage: $0 [run|install|--debug|--logs|--telemetry|--verify]" >&2
}

validate_paths
stop_running_app
build_app_bundle

case "$MODE" in
  run)
    open_app
    ;;
  install|--install)
    install_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$GUI_EXECUTABLE\""
    ;;
  --telemetry|telemetry)
    open_app
    # The logging subsystem is FermixAppCore's own (see AppLog), which is
    # deliberately not the bundle identifier.
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "ai.fermix.app"' 
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$GUI_EXECUTABLE" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
