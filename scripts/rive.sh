#!/usr/bin/env bash
#
# shellcheck disable=SC2034
# Every constant in this file is read by the scripts that source it, which is
# the whole reason it exists; shellcheck cannot see across that boundary.
#
# The one owner of the Rive facts the packaging scripts share.
#
# The mascot's animation runtime is the second binary framework the app embeds,
# and the three scripts that handle the updater need the same answers about it:
# stage_app.sh embeds the framework, sign_app.sh signs it inside-out, and
# verify_staged_app.sh proves the staged bundle carries exactly it. Only the GUI
# links it, through FermixRive, for the reason the updater has a target of its
# own: FermixAgent links FermixAppCore and must never load it.
#
# Usage:  source "$(dirname "$0")/rive.sh"
#
# The version itself is NOT here: Product.json owns it (`rive_runtime_version`),
# Package.swift and project.yml restate it because neither build system can read
# JSON at the moment it needs the value, and scripts/check_product_config.sh
# gates all three against each other.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "rive.sh: must be sourced from bash" >&2
  exit 1
fi

# shellcheck source=scripts/xcframework.sh
source "$(dirname "${BASH_SOURCE[0]}")/xcframework.sh"

# The embedded framework's directory name, which is also its name inside the
# resolved xcframework and the name its @rpath install name resolves through.
RIVE_FRAMEWORK_NAME="RiveRuntime.framework"

# The framework's Mach-O, named one by one.
#
# The runtime ships one library and no helper program, XPC service or tool. It
# is still enumerated rather than matched by a wildcard, for the reason the
# updater's helpers are (scripts/sparkle.sh): an allowlist that said "anything
# nested in the framework" would sign whatever a future version adds without
# anyone deciding to. A version that adds a program fails the nested-code
# refusal loudly and is re-declared here on purpose.
#
# Paths are relative to the framework directory. `Versions/A` is the runtime's
# own version letter, not a placeholder.
RIVE_MACHO_PATHS=(
  "Versions/A/RiveRuntime"
)

# What codesign is pointed at, deepest first. With no nested program the
# versioned bundle is the whole of it, and signing it seals the library and its
# resources together. The outer app is signed after it by sign_app.sh.
RIVE_SIGNING_ORDER=(
  "Versions/A"
)

# The symlinks that make a framework a framework. A copy that flattened them
# produces a tree that looks complete and cannot be loaded, because the install
# name resolves through `Versions/Current` (see scripts/sparkle.sh).
RIVE_REQUIRED_SYMLINKS=(
  "RiveRuntime"
  "Resources"
  "Versions/Current"
)

# Where the resolved binary artifact keeps the macOS framework: SwiftPM unpacks
# the `RiveRuntime` binary target of the `rive-ios` package here, and
# scripts/xcframework.sh reads the slice out of the xcframework's own Info.plist.
# The xcframework also carries iOS, tvOS, visionOS and Catalyst slices, none of
# which is the macOS one.
#
# Usage: rive_framework_source <swiftpm-build-path>
rive_framework_source() {
  local build_path="${1:?rive_framework_source: <swiftpm-build-path> is required}"
  xcframework_macos_framework rive "$build_path/artifacts/rive-ios/RiveRuntime/RiveRuntime.xcframework"
}

# The version an embedded framework declares, read from the framework itself.
# `verify_staged_app.sh` compares it with the pin in Product.json, so a bundle
# carrying a runtime nobody pinned is refused rather than shipped.
rive_embedded_version() {
  local framework="${1:?rive_embedded_version: <framework-path> is required}"
  plutil -extract CFBundleShortVersionString raw -o - \
    "$framework/Versions/A/Resources/Info.plist" 2>/dev/null
}
