#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
SCRIPT="$ROOT_DIR/script/build_and_run.sh"
# The pinned updater version, read from the one place that owns it: the stand-in
# for `swift build` has to produce an artifact the staging step accepts, and a
# version written here would be a third copy of the pin.
# shellcheck source=../../scripts/product_config.sh
source "$REPO_ROOT/scripts/product_config.sh"
SPARKLE_VERSION="$(product_config sparkle_version)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/install"

cat >"$TMP_DIR/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >>"$FAKE_SWIFT_LOG"

BUILD_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-path)
      BUILD_PATH="$2"
      shift 2
      ;;
    --show-bin-path)
      echo "$BUILD_PATH/arm64-apple-macosx/debug"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$BUILD_PATH" ]]; then
  echo "missing --build-path" >&2
  exit 1
fi

BUILD_DIR="$BUILD_PATH/arm64-apple-macosx/debug"
RESOURCE_DIR="$BUILD_DIR/Fermix_FermixAppCore.bundle"
mkdir -p "$RESOURCE_DIR"
printf '#!/usr/bin/env bash\n' >"$BUILD_DIR/Fermix"
printf '#!/usr/bin/env bash\n' >"$BUILD_DIR/FermixAgent"
chmod +x "$BUILD_DIR/Fermix" "$BUILD_DIR/FermixAgent"
printf 'icon\n' >"$RESOURCE_DIR/FermixPet.icns"

# The pinned updater, where SwiftPM unpacks a binary target. Real `swift build`
# resolves it before compiling, and the staging step reads the xcframework's own
# Info.plist to find the macOS slice, so the stand-in publishes the same shape.
SLICE="$BUILD_PATH/artifacts/sparkle/Sparkle/Sparkle.xcframework"
FRAMEWORK="$SLICE/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$FRAMEWORK/Versions/B/Resources"
printf 'library\n' >"$FRAMEWORK/Versions/B/Sparkle"
printf 'autoupdate\n' >"$FRAMEWORK/Versions/B/Autoupdate"
ln -sfn B "$FRAMEWORK/Versions/Current"
ln -sfn Versions/Current/Sparkle "$FRAMEWORK/Sparkle"
cat >"$FRAMEWORK/Versions/B/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key><string>$FAKE_SPARKLE_VERSION</string>
</dict>
</plist>
PLIST
cat >"$SLICE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>LibraryIdentifier</key><string>macos-arm64_x86_64</string>
      <key>LibraryPath</key><string>Sparkle.framework</string>
      <key>SupportedPlatform</key><string>macos</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
</dict>
</plist>
PLIST
SH

cat >"$TMP_DIR/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH

# Hermetic signing stubs: this harness tests the build/stage/install plumbing,
# not code signing. Claim the dev identity already exists so
# ensure_signing_identity never touches the host keychain (CI runners and
# clean machines lack the identity, and tests must not mutate host state).
cat >"$TMP_DIR/bin/security" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "find-identity" ]]; then
  echo '  1) 0000000000000000000000000000000000000000 "FermixPet Dev"'
fi
exit 0
SH

cat >"$TMP_DIR/bin/codesign" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$TMP_DIR/bin/swift" "$TMP_DIR/bin/pgrep" \
  "$TMP_DIR/bin/security" "$TMP_DIR/bin/codesign"

export FAKE_SWIFT_LOG="$TMP_DIR/swift.log"
export FAKE_SPARKLE_VERSION="$SPARKLE_VERSION"
export FERMIXPET_INSTALL_DIR="$TMP_DIR/install"

HOME="$TMP_DIR/home" \
PATH="$TMP_DIR/bin:$PATH" \
  "$SCRIPT" install

EXPECTED_BUILD_PATH="$TMP_DIR/home/Library/Caches/io.tezra.FermixPet/swiftpm-build"
INSTALLED_APP="$TMP_DIR/install/FermixPet.app"

test -x "$INSTALLED_APP/Contents/MacOS/Fermix"
test -x "$INSTALLED_APP/Contents/MacOS/FermixAgent"
test -f "$INSTALLED_APP/Contents/Info.plist"
# The updater is embedded where the GUI's runtime search path looks, with its
# version link intact: a dev install without it launches to a dyld failure, and
# one whose symbolic links were resolved cannot load the framework at all.
test -d "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework"
test -L "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
test -f "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
# The dev install carries exactly the identity Product.json declares.
grep -F "<key>CFBundleIdentifier</key><string>io.tezra.FermixPet</string>" \
  "$INSTALLED_APP/Contents/Info.plist" >/dev/null
grep -F "<key>CFBundleExecutable</key><string>Fermix</string>" \
  "$INSTALLED_APP/Contents/Info.plist" >/dev/null
grep -F "<key>LSMinimumSystemVersion</key><string>15.0</string>" \
  "$INSTALLED_APP/Contents/Info.plist" >/dev/null
# The app registers its url scheme, and carries NO LSUIElement: the accessory
# policy is set in code as the first AppKit act, and the window host promotes to
# a Dock app while a window is open, which the plist key would pin against.
# `verify_staged_app.sh` asserts the same absence for a staged bundle.
if grep -F "<key>LSUIElement</key>" "$INSTALLED_APP/Contents/Info.plist" >/dev/null; then
  echo "build_and_run_test: the installed Info.plist carries LSUIElement; the activation policy is code-owned" >&2
  exit 1
fi
grep -F "<string>fermix</string>" "$INSTALLED_APP/Contents/Info.plist" >/dev/null
# SMAppService.agent reads exactly this path, pointing at exactly this program.
AGENT_PLIST="$INSTALLED_APP/Contents/Library/LaunchAgents/io.tezra.FermixPet.agent.plist"
test -f "$AGENT_PLIST"
grep -F "<key>BundleProgram</key><string>Contents/MacOS/FermixAgent</string>" "$AGENT_PLIST" >/dev/null
grep -F "<key>Label</key><string>io.tezra.FermixPet.agent</string>" "$AGENT_PLIST" >/dev/null
grep -F -- "--build-path $EXPECTED_BUILD_PATH" "$FAKE_SWIFT_LOG" >/dev/null
grep -F -- "-c release" "$FAKE_SWIFT_LOG" >/dev/null

echo "build_and_run_test: ok"
