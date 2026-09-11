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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "fake_staged_app.sh: must be sourced from bash" >&2
  exit 1
fi

FAKE_APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_APP_RESOURCES="$FAKE_APP_ROOT/Apps/Fermix/Sources/FermixAppCore/Resources"
# shellcheck source=scripts/sparkle.sh
source "$FAKE_APP_ROOT/scripts/sparkle.sh"

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

# The release identity a fixture engine tree declares unless a case overrides
# it. The harnesses write their fixture engine pin from these two values, so the
# pin and the tree it vouches for agree without either being typed twice.
FAKE_APP_ENGINE_SOURCE_COMMIT="1234567890abcdef1234567890abcdef12345678"
FAKE_APP_ENGINE_PRODUCT_VERSION="9.9.9"

# A minimal engine tree the way the daemon's app-engine release lays it out:
# the manifest at the root, the shell-script launcher at bin/fermix_app_engine
# (a mix release's bin entry is a script, sealed as a resource, never signable
# code), and a real single-arch Mach-O VM so file/codesign answer truthfully.
# The protocol block is the shape the daemon's release writes and the shape the
# release audience reads: `minimum_version` / `maximum_version` /
# `current_version`, never `minimum` / `maximum`. It is a parameter so a case can
# stage an engine whose window excludes the version the app speaks.
#
# The source commit is a parameter for the same reason: the release audience
# refuses a tree built from a commit the engine pin does not name, so a case has
# to be able to stage that disagreement.
fake_app_build_engine_tree() {
  local tree="$1" arch="$2" management_minimum="${3:-1}" management_maximum="${4:-2}"
  local source_commit="${5:-$FAKE_APP_ENGINE_SOURCE_COMMIT}"
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
    "engine_id": "fermix-core",
    "product_version": "$FAKE_APP_ENGINE_PRODUCT_VERSION",
    "source_commit": "$source_commit"
  },
  "protocols": {
    "management": {
      "current_version": $management_maximum,
      "minimum_version": $management_minimum,
      "maximum_version": $management_maximum
    },
    "realtime": {
      "current_version": 1,
      "minimum_version": 1,
      "maximum_version": 1
    }
  }
}
MANIFEST
}

# A stand-in for the pinned updater framework, in the layout the real one has:
# a versioned bundle behind Versions/Current, four helper programs beside the
# library, and the top-level symbolic links the @rpath install name resolves
# through. The library is a real universal dylib carrying Sparkle's own install
# name, and the helpers are real universal Mach-O, so file, lipo, otool, and
# codesign all answer truthfully about them.
#
# The version is a parameter so a case can stage a framework the product
# configuration does not pin.
fake_app_build_sparkle_framework() {
  local framework="$1" version="$2" scratch
  scratch="$(dirname "$framework")"
  mkdir -p "$framework/Versions/B/Resources" \
    "$framework/Versions/B/Updater.app/Contents/MacOS" \
    "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS"

  printf 'int SUFakeUpdater(void) { return 0; }\n' >"$scratch/.sparkle.c"
  cc -dynamiclib -arch arm64 -arch x86_64 \
    -install_name "@rpath/$SPARKLE_FRAMEWORK_NAME/Versions/B/Sparkle" \
    -o "$framework/Versions/B/Sparkle" "$scratch/.sparkle.c"
  rm -f "$scratch/.sparkle.c"

  fake_app_build_stub "$framework/Versions/B/Autoupdate" -arch arm64 -arch x86_64
  fake_app_build_stub "$framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
    -arch arm64 -arch x86_64
  fake_app_build_stub "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    -arch arm64 -arch x86_64
  fake_app_build_stub "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    -arch arm64 -arch x86_64

  fake_app_write_bundle_plist "$framework/Versions/B/Resources/Info.plist" \
    Sparkle org.sparkle-project.Sparkle FMWK "$version"
  fake_app_write_bundle_plist "$framework/Versions/B/Updater.app/Contents/Info.plist" \
    Updater org.sparkle-project.Sparkle.Updater APPL "$version"
  fake_app_write_bundle_plist \
    "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist" \
    Downloader org.sparkle-project.Downloader XPC! "$version"
  fake_app_write_bundle_plist \
    "$framework/Versions/B/XPCServices/Installer.xpc/Contents/Info.plist" \
    Installer org.sparkle-project.InstallerConnection XPC! "$version"

  ln -sfn B "$framework/Versions/Current"
  ln -sfn Versions/Current/Sparkle "$framework/Sparkle"
  ln -sfn Versions/Current/Resources "$framework/Resources"
  ln -sfn Versions/Current/Autoupdate "$framework/Autoupdate"
  ln -sfn Versions/Current/Updater.app "$framework/Updater.app"
  ln -sfn Versions/Current/XPCServices "$framework/XPCServices"
}

fake_app_write_bundle_plist() {
  local out="$1" executable="$2" identifier="$3" package_type="$4" version="$5"
  cat >"$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundleName</key><string>$executable</string>
  <key>CFBundlePackageType</key><string>$package_type</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
</dict>
</plist>
PLIST
}

# The two link arguments that make a GUI stand-in load the staged updater
# framework the way the built GUI does.
#
# verify_staged_app.sh asks the binaries themselves which executable may load
# Sparkle — M34 section 6 allows the GUI and forbids the agent — so a stand-in
# that linked nothing would fail that gate for a reason the case under test
# never touched. They arrive in an array because both are paths, and a string
# split on spaces breaks the first time a scratch directory has one.
fake_app_sparkle_link_flags() {
  local app="${1:?fake_app_sparkle_link_flags: <app-path> is required}"
  FAKE_APP_SPARKLE_LINK=(
    "$app/$(product_config frameworks_relative_path)/$SPARKLE_FRAMEWORK_NAME/Versions/B/Sparkle"
    "-Wl,-rpath,@executable_path/../Frameworks"
  )
}

fake_app_build_bundle() {
  local app="$1" resources
  # shellcheck source=scripts/product_config.sh
  source "$FAKE_APP_ROOT/scripts/product_config.sh"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
    "$app/Contents/Library/LaunchAgents" \
    "$app/$(product_config engine_relative_path)" \
    "$app/$(product_config tools_relative_path)" \
    "$app/$(product_config frameworks_relative_path)"

  # The framework first: the GUI stand-in links against it, exactly as the
  # built GUI links the pinned one.
  fake_app_build_sparkle_framework \
    "$app/$(product_config frameworks_relative_path)/$SPARKLE_FRAMEWORK_NAME" \
    "$(product_config sparkle_version)"
  fake_app_sparkle_link_flags "$app"
  fake_app_build_stub "$app/Contents/MacOS/$(product_config gui_executable_name)" \
    -arch arm64 -arch x86_64 "${FAKE_APP_SPARKLE_LINK[@]}"
  fake_app_build_stub "$app/Contents/MacOS/$(product_config agent_executable_name)" \
    -arch arm64 -arch x86_64

  resources="$app/Contents/Resources/$(product_config swift_resource_bundle_name)"
  mkdir -p "$resources/en.lproj"
  cp -R "$FAKE_APP_RESOURCES/Contracts" "$resources/Contracts"
  cp -R "$FAKE_APP_RESOURCES/VendorMarks" "$resources/VendorMarks"
  cp "$FAKE_APP_RESOURCES/Product.json" "$resources/Product.json"
  cp "$FAKE_APP_RESOURCES/en.lproj/Localizable.strings" "$resources/en.lproj/Localizable.strings"
  cp "$FAKE_APP_RESOURCES/MenuBarTemplate/FermixMarkTemplate.png" "$resources/FermixMarkTemplate.png"
  cp "$FAKE_APP_RESOURCES/$(product_config icon_file).icns" \
    "$app/Contents/Resources/$(product_config icon_file).icns"

  "$FAKE_APP_ROOT/scripts/render_info_plist.sh" "9.9.9" "424242" "$app/Contents/Info.plist"
  "$FAKE_APP_ROOT/scripts/render_launch_agent_plist.sh" \
    "$app/Contents/Library/LaunchAgents/$(product_config agent_service_label).plist"
}
