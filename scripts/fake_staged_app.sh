#!/usr/bin/env bash
#
# Test helper: build a staged Fermix bundle without building Fermix.
#
# Sourced by scripts/verify_staged_app_test.sh and scripts/sign_app_test.sh so
# both harnesses exercise their gate against the same reference layout. It is a
# helper, not a gate: nothing in CI or in a release calls it.
#
# The bundle it produces is the layout stage_app.sh produces, assembled from the
# real product configuration, the real rendered property lists, and the real
# staged resources — so a gate cannot pass here and fail on a real bundle for a
# reason the harness never modelled. Only the two executables are stand-ins, and
# they are real universal Mach-O rather than shell scripts, so lipo, file, and
# codesign all answer truthfully about them.
#
# Usage:  source "$(dirname "$0")/fake_staged_app.sh"
#         fake_app_build_stub <out> [cc flags...]
#         fake_app_build_bundle <app-path> <scratch-dir>

if [ -z "${BASH_SOURCE[0]:-}" ]; then
  echo "fake_staged_app.sh: must be sourced from bash" >&2
  return 1 2>/dev/null || exit 1
fi

FAKE_APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_APP_RESOURCES="$FAKE_APP_ROOT/Apps/Fermix/Sources/FermixAppCore/Resources"

# A real universal Mach-O, so lipo answers truthfully. A shell script with a
# +x bit would satisfy an executable-bit check and prove nothing about slices.
fake_app_build_stub() {
  local out="$1" scratch
  shift
  scratch="$(dirname "$out")"
  mkdir -p "$scratch"
  printf 'int main(void) { return 0; }\n' >"$scratch/.stub.c"
  cc "$@" -o "$out" "$scratch/.stub.c"
  rm -f "$scratch/.stub.c"
}

# A minimal engine tree the way the daemon's app-engine release lays it out:
# the manifest at the root, the shell-script launcher at bin/fermix_app_engine
# (a mix release's bin entry is a script, sealed as a resource, never signable
# code), and a real single-arch Mach-O VM so file/codesign answer truthfully.
fake_app_build_engine_tree() {
  local tree="$1" arch="$2"
  mkdir -p "$tree/bin" "$tree/lib" "$tree/erts-0.0/bin"
  printf '#!/bin/sh\nexit 0\n' >"$tree/bin/fermix_app_engine"
  chmod 0755 "$tree/bin/fermix_app_engine"
  fake_app_build_stub "$tree/erts-0.0/bin/beam.smp" -arch "$arch"
  cat >"$tree/engine-manifest.json" <<MANIFEST
{
  "schema_version": 1,
  "identity": {
    "architecture": "$arch",
    "distribution_identity": "macos_app",
    "engine_id": "fermix-core"
  }
}
MANIFEST
}

fake_app_build_bundle() {
  local app="$1" resources
  # shellcheck source=scripts/product_config.sh
  source "$FAKE_APP_ROOT/scripts/product_config.sh"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
    "$app/Contents/Library/LaunchAgents" \
    "$app/$(product_config engine_relative_path)" \
    "$app/$(product_config tools_relative_path)"

  fake_app_build_stub "$app/Contents/MacOS/$(product_config gui_executable_name)" \
    -arch arm64 -arch x86_64
  fake_app_build_stub "$app/Contents/MacOS/$(product_config agent_executable_name)" \
    -arch arm64 -arch x86_64

  resources="$app/Contents/Resources/$(product_config swift_resource_bundle_name)"
  mkdir -p "$resources/en.lproj"
  cp -R "$FAKE_APP_RESOURCES/Contracts" "$resources/Contracts"
  cp -R "$FAKE_APP_RESOURCES/VendorMarks" "$resources/VendorMarks"
  cp "$FAKE_APP_RESOURCES/Product.json" "$resources/Product.json"
  cp "$FAKE_APP_RESOURCES/en.lproj/Localizable.strings" "$resources/en.lproj/Localizable.strings"
  cp "$FAKE_APP_RESOURCES/MenuBarTemplate/FermixBoltTemplate.png" "$resources/FermixBoltTemplate.png"
  cp "$FAKE_APP_RESOURCES/$(product_config icon_file).icns" \
    "$app/Contents/Resources/$(product_config icon_file).icns"

  "$FAKE_APP_ROOT/scripts/render_info_plist.sh" "9.9.9" "424242" "$app/Contents/Info.plist"
  "$FAKE_APP_ROOT/scripts/render_launch_agent_plist.sh" \
    "$app/Contents/Library/LaunchAgents/$(product_config agent_service_label).plist"
}
