#!/usr/bin/env bash
#
# The one owner of how a resolved binary xcframework is read.
#
# Two pinned dependencies resolve as binary xcframeworks the app embeds and
# signs: the updater (scripts/sparkle.sh) and the mascot's animation runtime
# (scripts/rive.sh). Each of those files owns its own facts — where SwiftPM
# unpacks it, what its framework is called, which Mach-O it carries — and both
# ask this file the one question they share: which directory of the xcframework
# holds the macOS framework. Two copies of that answer would drift apart the
# first time one of them was fixed.
#
# Usage:  source "$(dirname "${BASH_SOURCE[0]}")/xcframework.sh"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "xcframework.sh: must be sourced from bash" >&2
  exit 1
fi

# The framework directory of the one macOS slice of a resolved xcframework.
#
# SwiftPM unpacks a binary target under <build-path>/artifacts/<package>/<target>,
# and the xcframework's own Info.plist is what says which directory holds the
# macOS slice and what the framework inside it is called. Reading it is one
# question asked of the artifact instead of two names written by hand that a
# dependency's release could invalidate silently.
#
# Usage: xcframework_macos_framework <owner> <xcframework-path>
#   <owner>  the name every refusal is reported under, the caller's own
xcframework_macos_framework() {
  local owner="${1:?xcframework_macos_framework: <owner> is required}"
  local xcframework="${2:?xcframework_macos_framework: <xcframework-path> is required}"
  local identifier library

  if [ ! -f "$xcframework/Info.plist" ]; then
    echo "$owner: the resolved artifact is not at $xcframework" >&2
    echo "$owner: run swift build so SwiftPM downloads the pinned binary target" >&2
    return 1
  fi

  read -r identifier library <<SLICE
$(xcframework_macos_slice "$xcframework/Info.plist")
SLICE
  if [ -z "$identifier" ] || [ -z "$library" ]; then
    echo "$owner: $xcframework publishes no macOS slice" >&2
    return 1
  fi

  if [ ! -d "$xcframework/$identifier/$library" ]; then
    echo "$owner: $xcframework declares $identifier/$library, which is not there" >&2
    return 1
  fi

  printf '%s\n' "$xcframework/$identifier/$library"
}

# The library identifier and library path of the one macOS slice, as two words.
# A slice with a platform variant (Catalyst) is not the macOS one.
xcframework_macos_slice() {
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
