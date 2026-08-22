#!/usr/bin/env bash
#
# Run the FermixAppCore suite.
#
# The suite is swift-testing. Command Line Tools ship Testing.framework and
# lib_TestingInterop.dylib in two directories SwiftPM does not search, and SIP
# strips DYLD_FRAMEWORK_PATH from swiftpm-testing-helper, so the framework
# search path and both rpaths have to be baked in at link time. A full Xcode
# toolchain supplies them itself and needs none of these flags.
#
# Usage: script/swift_test.sh [additional swift test arguments]
set -euo pipefail

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIBRARIES="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
    -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_LIBRARIES" \
    "$@"
fi

if [ ! -d "$(xcode-select -p)/Platforms/MacOSX.platform" ]; then
  echo "swift_test: no swift-testing framework found in the Command Line Tools" >&2
  echo "swift_test: and $(xcode-select -p) is not an Xcode toolchain" >&2
  exit 1
fi

exec swift test "$@"
