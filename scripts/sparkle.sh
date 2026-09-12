#!/usr/bin/env bash
#
# shellcheck disable=SC2034
# Every constant in this file is read by the scripts that source it, which is
# the whole reason it exists; shellcheck cannot see across that boundary.
#
# The one owner of the Sparkle facts the packaging scripts share.
#
# Three scripts need the same answers and none of them may hold its own copy:
# stage_app.sh embeds the framework, sign_app.sh signs its retained helpers
# inside-out, and verify_staged_app.sh proves the staged bundle carries exactly
# them. A list typed out three times is a list that rots on the first upgrade.
#
# Usage:  source "$(dirname "$0")/sparkle.sh"
#
# The version itself is NOT here: Product.json owns it, Package.swift and
# project.yml restate it because neither build system can read JSON at the
# moment it needs the value, and scripts/check_product_config.sh gates all
# three against each other.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "sparkle.sh: must be sourced from bash" >&2
  exit 1
fi

# The embedded framework's directory name, which is also its name inside the
# resolved xcframework and the name its @rpath install name resolves through.
SPARKLE_FRAMEWORK_NAME="Sparkle.framework"

# The retained helpers, named one by one.
#
# Sparkle ships four helper programs beside its library, and every one of them
# is Mach-O that macOS will refuse to run unsigned. They are enumerated rather
# than matched by a wildcard under Frameworks/ deliberately: an allowlist that
# said "anything nested in the framework" would sign whatever a future version
# adds without anyone deciding to, which is the opposite of what the nested-code
# refusal exists for. A Sparkle upgrade that moves or adds one of these fails
# the gate loudly and is re-declared here on purpose.
#
# Paths are relative to the framework directory. `Versions/B` is Sparkle 2's own
# version letter, not a placeholder.
SPARKLE_MACHO_PATHS=(
  "Versions/B/Sparkle"
  "Versions/B/Autoupdate"
  "Versions/B/Updater.app/Contents/MacOS/Updater"
  "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
)

# What codesign is pointed at, deepest first. The XPC services and Updater.app
# are bundles and are signed as bundles (signing their inner Mach-O directly
# would leave the bundle's own seal stale); Autoupdate is a plain executable;
# `Versions/B` is the framework's versioned bundle and is signed last, sealing
# everything above it. The outer app is signed after all of them by sign_app.sh.
SPARKLE_SIGNING_ORDER=(
  "Versions/B/XPCServices/Downloader.xpc"
  "Versions/B/XPCServices/Installer.xpc"
  "Versions/B/Updater.app"
  "Versions/B/Autoupdate"
  "Versions/B"
)

# The symlinks that make a framework a framework. A copy that flattened them —
# an unzip, a rsync without `-l`, a tool that follows links — produces a
# directory tree that looks complete and cannot be loaded, because the install
# name resolves through `Versions/Current`.
SPARKLE_REQUIRED_SYMLINKS=(
  "Sparkle"
  "Resources"
  "Versions/Current"
)

# The tripwire, not a default. Product.json carries the production public key,
# so nothing checked in renders this value any more; it stays here because the
# release audience of verify_staged_app.sh refuses a bundle whose Info.plist
# carries it, and a refusal needs the exact string it refuses. An app shipped
# with this in its Info.plist can verify no update at all.
SPARKLE_PLACEHOLDER_PUBLIC_ED_KEY="replace-with-the-production-sparkle-public-key"

# Where the resolved binary artifact keeps the macOS slice of the xcframework.
#
# SwiftPM unpacks a binary target under <build-path>/artifacts/<package>/<target>,
# and the xcframework's own Info.plist is what says which directory holds the
# macOS slice and what the framework inside it is called. Reading it is one
# question asked of the artifact instead of two names written here that a
# Sparkle release could invalidate silently.
#
# Usage: sparkle_framework_source <swiftpm-build-path>
sparkle_framework_source() {
  local build_path="${1:?sparkle_framework_source: <swiftpm-build-path> is required}"
  local xcframework identifier library

  xcframework="$build_path/artifacts/sparkle/Sparkle/Sparkle.xcframework"
  if [ ! -f "$xcframework/Info.plist" ]; then
    echo "sparkle: the resolved Sparkle artifact is not at $xcframework" >&2
    echo "sparkle: run swift build so SwiftPM downloads the pinned binary target" >&2
    return 1
  fi

  read -r identifier library <<SLICE
$(sparkle_macos_slice "$xcframework/Info.plist")
SLICE
  if [ -z "$identifier" ] || [ -z "$library" ]; then
    echo "sparkle: $xcframework publishes no macOS slice" >&2
    return 1
  fi

  if [ ! -d "$xcframework/$identifier/$library" ]; then
    echo "sparkle: $xcframework declares $identifier/$library, which is not there" >&2
    return 1
  fi

  printf '%s\n' "$xcframework/$identifier/$library"
}

# The library identifier and library path of the one macOS slice, as two words.
# A slice with a platform variant (Catalyst) is not the macOS one.
sparkle_macos_slice() {
  python3 - "$1" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    document = plistlib.load(source)

slices = [
    entry
    for entry in document.get("AvailableLibraries", [])
    if entry.get("SupportedPlatform") == "macos" and not entry.get("SupportedPlatformVariant")
]
if len(slices) != 1:
    sys.exit(f"expected exactly one macos slice, found {len(slices)}")
print(slices[0]["LibraryIdentifier"], slices[0]["LibraryPath"])
PY
}

# The version an embedded framework declares, read from the framework itself.
# `verify_staged_app.sh` compares it with the pin in Product.json, so a bundle
# carrying a framework nobody pinned is refused rather than shipped.
sparkle_embedded_version() {
  local framework="${1:?sparkle_embedded_version: <framework-path> is required}"
  plutil -extract CFBundleShortVersionString raw -o - \
    "$framework/Versions/B/Resources/Info.plist" 2>/dev/null
}
