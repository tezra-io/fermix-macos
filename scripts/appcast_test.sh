#!/usr/bin/env bash
#
# Harness for scripts/appcast.py.
#
# The appcast is the one release artifact nobody can correct after the fact: a
# client that read a feed describing the wrong build, or an entry missing one of
# the four Fermix elements, is stranded on the version it has. So every refusal
# the writer owns is fired here on purpose, and the feed it produces is parsed
# back and checked against the values that went in.
#
# Hermetic, offline and host-safe. Everything happens inside one mktemp
# directory; the app bundles are hand-made rather than built, because the only
# things the writer reads from a bundle are its Info.plist and its engine
# manifests; sign_update and codesign are stubs on PATH, so no signing key and
# no keychain are involved at any point. Nothing is installed, registered or
# launched, and nothing reaches the network.
#
# Usage: appcast_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="$ROOT_DIR/scripts/appcast.py"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

# The real engine slot, asked for rather than typed, so the fake bundles carry
# their manifests where a staged bundle carries them.
ENGINE_RELATIVE_PATH="$(product_config engine_relative_path)"
ARCHITECTURES=(arm64 x86_64)

ENGINE_BUILD_ID="2026081901"
ENGINE_VERSION="0.9.0"
SIGNING_IDENTITY="Developer ID Application: Tezra Labs LLC (ABCDE12345)"
# A stand-in for a signature, never a real one: the stub below prints it instead
# of signing, so this harness needs no key and cannot touch the login keychain.
FAKE_SIGNATURE="c2lnbmF0dXJlLXN0YW5kLWluLW5vdC1hLXJlYWwtb25l"
FAKE_PRIVATE_KEY="not-a-key-the-stub-only-proves-it-arrives-on-stdin"
RELEASE_BASE="https://github.com/tezra-io/fermix-macos/releases/download"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Captured before PATH is ever overridden, so a stub directory replaces one
# entry instead of becoming the whole search path.
BASE_PATH="$PATH"

fail() {
  echo "appcast_test: $*" >&2
  exit 1
}

expect_pass() {
  local what="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "expected to pass: $what"
  echo "  ok   $what"
}

expect_refusal() {
  local what="$1" expected="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected a refusal: $what"
  printf '%s' "$output" | grep -qF -- "$expected" ||
    fail "$what refused for the wrong reason: wanted '$expected', got: $(printf '%s' "$output" | tail -3)"
  echo "  ok   $what"
}

# MARK: - The stubs

# sign_update, as the release calls it: the key on standard input, the signature
# and the file's real byte length on standard output. A run that passed the key
# any other way gets a refusal from this stub rather than a signature.
write_sign_update_stub() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  cat >"$out" <<'STUB'
#!/bin/sh
set -eu
key="$(cat)"
[ -n "$key" ] || { echo "no private key arrived on standard input" >&2; exit 1; }
for file in "$@"; do :; done
printf 'sparkle:edSignature="%s" length="%s"\n' \
  "$APPCAST_TEST_SIGNATURE" "$(wc -c <"$file" | tr -d ' ')"
STUB
  chmod 0755 "$out"
}

# The same tool having said something that is not a signature, which is the
# shape a wrong flag or a future version change would take.
write_garbled_sign_update_stub() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  cat >"$out" <<'STUB'
#!/bin/sh
set -eu
cat >/dev/null
echo "signed ok"
STUB
  chmod 0755 "$out"
}

# codesign -dvv, which prints its display to standard error. The authority line
# is what the feed publishes, so one stub prints the real shape and one prints
# an empty authority: a fake bundle is not Developer ID signed, and signing one
# for real would need a certificate and the keychain.
write_codesign_stub() {
  local dir="$1" authority="$2"
  mkdir -p "$dir"
  cat >"$dir/codesign" <<STUB
#!/bin/sh
echo "Identifier=$(product_config bundle_identifier)" >&2
echo "Authority=$authority" >&2
echo "Authority=Developer ID Certification Authority" >&2
echo "TeamIdentifier=ABCDE12345" >&2
STUB
  chmod 0755 "$dir/codesign"
}

# MARK: - The reference bundles

# The two facts the writer reads out of a bundle, and nothing else: a rendered
# Info.plist and one engine manifest per architecture.
make_app() {
  local app="$1" marketing="$2" build="$3" build_id="${4:-$ENGINE_BUILD_ID}"
  mkdir -p "$app/Contents"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$(product_config bundle_identifier)</string>
  <key>CFBundleShortVersionString</key><string>$marketing</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>$(product_config minimum_system_version)</string>
</dict>
</plist>
PLIST

  local architecture
  for architecture in "${ARCHITECTURES[@]}"; do
    make_engine_manifest "$app/$ENGINE_RELATIVE_PATH/$architecture" "$architecture" "$build_id"
  done
}

make_engine_manifest() {
  local tree="$1" architecture="$2" build_id="$3"
  mkdir -p "$tree"
  cat >"$tree/engine-manifest.json" <<MANIFEST
{
  "schema_version": 1,
  "identity": {
    "engine_id": "fermix-core",
    "product_version": "$ENGINE_VERSION",
    "build_id": "$build_id",
    "source_commit": "9f1c0f4a1c6f4b2d8e3a5c7b9d1e3f5a7c9b1d3e",
    "distribution_identity": "macos_app",
    "artifact_target": "macos_aarch64",
    "architecture": "$architecture"
  }
}
MANIFEST
}

make_disk_image() {
  local dmg="$1"
  printf 'stand-in for a stapled disk image, %s\n' "$(basename "$dmg")" >"$dmg"
}

# MARK: - The two invocations under test

# Every item row goes through here: the key on standard input and a stub
# directory at the front of PATH, which is the only way a codesign read can be
# answered for a bundle nobody signed.
appcast_item() {
  local stub_dir="$1"
  shift
  printf '%s' "$FAKE_PRIVATE_KEY" |
    APPCAST_TEST_SIGNATURE="$FAKE_SIGNATURE" PATH="$stub_dir:$BASE_PATH" \
      "$APPCAST" item "$@"
}

appcast_merge() {
  "$APPCAST" merge "$@"
}

SIGN_UPDATE="$WORK_DIR/tools/sign_update"
GARBLED_SIGN_UPDATE="$WORK_DIR/tools/sign_update_garbled"
write_sign_update_stub "$SIGN_UPDATE"
write_garbled_sign_update_stub "$GARBLED_SIGN_UPDATE"
write_codesign_stub "$WORK_DIR/bin" "$SIGNING_IDENTITY"
write_codesign_stub "$WORK_DIR/bin-unsigned" ""

echo "appcast_test: one item"

APP="$WORK_DIR/release-1/Fermix.app"
DMG="$WORK_DIR/release-1/Fermix-0.1.0.dmg"
mkdir -p "$WORK_DIR/release-1"
make_app "$APP" "0.1.0" "1"
make_disk_image "$DMG"
ITEM_ONE="$WORK_DIR/item-1.xml"

item_one=(
  --dmg "$DMG" --app "$APP" --tag "v0.1.0"
  --sign-update "$SIGN_UPDATE" --out "$ITEM_ONE"
)
expect_pass "a stapled image and the app it carries produce one signed item" \
  appcast_item "$WORK_DIR/bin" "${item_one[@]}"

echo "appcast_test: refusals in the item"

app="$WORK_DIR/bad-build/Fermix.app"
make_app "$app" "0.1.0" "0.1.0"
expect_refusal "a build number that is not a plain positive integer is refused" \
  "is not a plain positive integer" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG" --app "$app" --tag "v0.1.0" \
  --sign-update "$SIGN_UPDATE" --out "$WORK_DIR/refused.xml"

app="$WORK_DIR/no-engine/Fermix.app"
make_app "$app" "0.1.0" "1"
rm -r "${app:?}/${ENGINE_RELATIVE_PATH:?}"
expect_refusal "a bundle with an empty engine slot is refused" \
  "carries no engine-manifest.json" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG" --app "$app" --tag "v0.1.0" \
  --sign-update "$SIGN_UPDATE" --out "$WORK_DIR/refused.xml"

app="$WORK_DIR/split-engine/Fermix.app"
make_app "$app" "0.1.0" "1"
make_engine_manifest "$app/$ENGINE_RELATIVE_PATH/x86_64" x86_64 "2026081902"
expect_refusal "two engine trees that name different builds are refused" \
  "the engine trees disagree" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG" --app "$app" --tag "v0.1.0" \
  --sign-update "$SIGN_UPDATE" --out "$WORK_DIR/refused.xml"

expect_refusal "an enclosure url that is not https is refused" \
  "is not https" \
  appcast_item "$WORK_DIR/bin" "${item_one[@]}" \
  --release-base "http://github.com/tezra-io/fermix-macos/releases/download"

expect_refusal "a sign_update that printed no signature is refused" \
  "printed no sparkle:edSignature attribute" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG" --app "$APP" --tag "v0.1.0" \
  --sign-update "$GARBLED_SIGN_UPDATE" --out "$WORK_DIR/refused.xml"

expect_refusal "a bundle whose signature names no authority is refused" \
  "names no signing authority" \
  appcast_item "$WORK_DIR/bin-unsigned" "${item_one[@]}"

echo "appcast_test: the cumulative feed"

FEED_ONE="$WORK_DIR/appcast-1.xml"
expect_pass "the first release starts a new feed" \
  appcast_merge --item "$ITEM_ONE" --out "$FEED_ONE"

APP_TWO="$WORK_DIR/release-2/Fermix.app"
DMG_TWO="$WORK_DIR/release-2/Fermix-0.2.0.dmg"
mkdir -p "$WORK_DIR/release-2"
make_app "$APP_TWO" "0.2.0" "2"
make_disk_image "$DMG_TWO"
ITEM_TWO="$WORK_DIR/item-2.xml"
expect_pass "a critical release produces its own item" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG_TWO" --app "$APP_TWO" --tag "v0.2.0" \
  --sign-update "$SIGN_UPDATE" --critical --out "$ITEM_TWO"

FEED_TWO="$WORK_DIR/appcast-2.xml"
expect_pass "the next release carries the published one forward" \
  appcast_merge --item "$ITEM_TWO" --previous "$FEED_ONE" --out "$FEED_TWO"

echo "appcast_test: refusals in the merge"

app="$WORK_DIR/reused/Fermix.app"
make_app "$app" "0.3.0" "2"
item="$WORK_DIR/item-reused.xml"
expect_pass "an item under an already published build number is written" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG_TWO" --app "$app" --tag "v0.3.0" \
  --sign-update "$SIGN_UPDATE" --out "$item"
expect_refusal "a reused build number is refused" \
  "is not greater than 2" \
  appcast_merge --item "$item" --previous "$FEED_TWO" --out "$WORK_DIR/refused.xml"

expect_refusal "a build number below the published one is refused" \
  "is not greater than 2" \
  appcast_merge --item "$ITEM_ONE" --previous "$FEED_TWO" --out "$WORK_DIR/refused.xml"

app="$WORK_DIR/duplicate-version/Fermix.app"
make_app "$app" "0.2.0" "3"
item="$WORK_DIR/item-duplicate.xml"
expect_pass "an item reusing a published marketing version is written" \
  appcast_item "$WORK_DIR/bin" --dmg "$DMG_TWO" --app "$app" --tag "v0.2.1" \
  --sign-update "$SIGN_UPDATE" --out "$item"
expect_refusal "a marketing version that is already published is refused" \
  "is already published as build 2" \
  appcast_merge --item "$item" --previous "$FEED_TWO" --out "$WORK_DIR/refused.xml"

echo "appcast_test: what the feed says"

# The one row that reads the product rather than the exit status. Both readers
# are modelled: the app looks the four Fermix elements up by their qualified
# name in SUAppcastItem.propertiesDictionary, so the literal `fermix:` prefix
# and its declaration are asserted on the bytes; everything else is asserted
# through a namespace-aware parse, which is what Sparkle itself does.
FEED="$FEED_TWO" \
  EXPECTED_SIGNATURE="$FAKE_SIGNATURE" \
  EXPECTED_IDENTITY="$SIGNING_IDENTITY" \
  EXPECTED_ENGINE_BUILD_ID="$ENGINE_BUILD_ID" \
  EXPECTED_ENGINE_VERSION="$ENGINE_VERSION" \
  EXPECTED_SHA256="$(shasum -a 256 "$DMG_TWO" | awk '{print $1}')" \
  EXPECTED_LENGTH="$(wc -c <"$DMG_TWO" | tr -d ' ')" \
  EXPECTED_URL="$RELEASE_BASE/v0.2.0/$(basename "$DMG_TWO")" \
  EXPECTED_MINIMUM="$(product_config minimum_system_version)" \
  python3 - <<'PY' || fail "the produced feed does not carry what went into it"
import os
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FERMIX = "https://fermix.ai/xml-namespaces/appcast"

path = os.environ["FEED"]
raw = open(path, encoding="utf-8").read()
root = ET.parse(path).getroot()
items = root.findall("channel/item")


def refuse(sentence):
    print(f"appcast_test: {sentence}", file=sys.stderr)
    raise SystemExit(1)


def text(item, namespace, name):
    found = item.find(f"{{{namespace}}}{name}")
    return None if found is None else (found.text or "").strip()


if root.tag != "rss" or root.get("version") != "2.0":
    refuse(f"the feed root is <{root.tag}> version {root.get('version')}")
if len(items) != 2:
    refuse(f"the feed describes {len(items)} releases, not the two that were published")

# Newest first, and the older release is still described: the app refuses an
# update unless the feed also carries the build that is installed.
builds = [text(item, SPARKLE, "version") for item in items]
if builds != ["2", "1"]:
    refuse(f"the feed orders its builds {builds}, not newest first")

offered, installed = items
if text(offered, SPARKLE, "shortVersionString") != "0.2.0":
    refuse("the offered release carries the wrong marketing version")
if text(offered, SPARKLE, "minimumSystemVersion") != os.environ["EXPECTED_MINIMUM"]:
    refuse("the offered release does not carry the bundle's system floor")
if offered.find(f"{{{SPARKLE}}}criticalUpdate") is None:
    refuse("the critical release is not marked critical")
if installed.find(f"{{{SPARKLE}}}criticalUpdate") is not None:
    refuse("the ordinary release is marked critical")

expected_elements = {
    "engineBuildId": os.environ["EXPECTED_ENGINE_BUILD_ID"],
    "engineVersion": os.environ["EXPECTED_ENGINE_VERSION"],
    "sha256": os.environ["EXPECTED_SHA256"],
    "signingIdentity": os.environ["EXPECTED_IDENTITY"],
}
for name, expected in expected_elements.items():
    for item in items:
        if text(item, FERMIX, name) in (None, ""):
            refuse(f"an item carries no fermix:{name}")
    found = text(offered, FERMIX, name)
    if found != expected:
        refuse(f"fermix:{name} is '{found}', not '{expected}'")

enclosure = offered.find("enclosure")
if enclosure is None:
    refuse("the offered release has no enclosure")
if enclosure.get("url") != os.environ["EXPECTED_URL"]:
    refuse(f"the enclosure url is {enclosure.get('url')}")
if enclosure.get("length") != os.environ["EXPECTED_LENGTH"]:
    refuse("the enclosure length is not the disk image's own byte count")
if enclosure.get(f"{{{SPARKLE}}}edSignature") != os.environ["EXPECTED_SIGNATURE"]:
    refuse("the enclosure carries the wrong signature")
if enclosure.get("type") != "application/octet-stream":
    refuse("the enclosure declares the wrong content type")

if f'xmlns:fermix="{FERMIX}"' not in raw:
    refuse("the feed declares no fermix namespace, so the elements are not addressable")
if f'xmlns:sparkle="{SPARKLE}"' not in raw:
    refuse("the feed declares no sparkle namespace")
for name in expected_elements:
    if not re.search(rf"<fermix:{name}>", raw):
        refuse(f"the feed spells fermix:{name} under some other prefix")
if "<sparkle:version>" not in raw or "sparkle:edSignature=" not in raw:
    refuse("the feed spells Sparkle's own fields under some other prefix")
PY
echo "  ok   the feed carries both releases, newest first, with every element the app reads"

echo "appcast_test: ok"
