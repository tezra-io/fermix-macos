#!/usr/bin/env bash
#
# Harness for scripts/sign_app.sh.
#
# The signing script's refusals are the ones nobody exercises by accident: they
# fire only on a release that is already going wrong. This harness fires them on
# purpose, against the same reference bundle the verifier harness uses.
#
# Hermetic and host-safe. Everything happens inside one mktemp directory, the
# only identity used is ad-hoc ("-"), which needs no certificate and never
# touches the keychain, and nothing is installed, registered, or launched.
#
# Usage: sign_app_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN="$ROOT_DIR/scripts/sign_app.sh"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/fake_staged_app.sh
source "$ROOT_DIR/scripts/fake_staged_app.sh"
# The two frameworks' lists are read directly below, so they are asked for
# directly rather than inherited through whatever fake_staged_app.sh sources.
# shellcheck source=scripts/sparkle.sh
source "$ROOT_DIR/scripts/sparkle.sh"
# shellcheck source=scripts/rive.sh
source "$ROOT_DIR/scripts/rive.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
BUNDLE_ID="$(product_config bundle_identifier)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"
SPARKLE_FRAMEWORK="$(product_config frameworks_relative_path)/$SPARKLE_FRAMEWORK_NAME"
RIVE_FRAMEWORK="$(product_config frameworks_relative_path)/$RIVE_FRAMEWORK_NAME"

WORK_DIR="$(mktemp -d)"
# The harness passes only by reaching its end. The bash macOS ships reports 0
# for a script an unset variable stopped once an EXIT trap has run, even to the
# trap's own $?, so the trap refuses a run that never finished.
trap 'rm -rf "$WORK_DIR"; [ "${harness_finished:-}" = 1 ] || exit 1' EXIT

fail() {
  echo "sign_app_test: $*" >&2
  exit 1
}

fresh_bundle() {
  local name="$1"
  mkdir -p "$WORK_DIR/$name"
  cp -R "$REFERENCE/." "$WORK_DIR/$name/"
  printf '%s\n' "$WORK_DIR/$name/$APP_BUNDLE_NAME"
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

REFERENCE="$WORK_DIR/reference"
mkdir -p "$REFERENCE"
fake_app_build_bundle "$REFERENCE/$APP_BUNDLE_NAME"

echo "sign_app_test: the signing structure"

app="$(fresh_bundle adhoc)"
expect_pass "a staged bundle signs ad-hoc and verifies" "$SIGN" "$app" -

# The GUI is the only microphone principal, and the seal is over the app's own
# identifier rather than whatever the bundle happens to be called on disk.
gui_entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
agent_entitlements="$(codesign -d --entitlements - "$app/Contents/MacOS/$AGENT_EXECUTABLE" 2>&1)"
printf '%s' "$gui_entitlements" | grep -q "com.apple.security.device.audio-input" ||
  fail "the signed GUI does not carry the microphone entitlement"
if printf '%s' "$agent_entitlements" | grep -q "com.apple.security.device.audio-input"; then
  fail "the signed agent carries the microphone entitlement"
fi
# Captured before matching: `grep -q` exits at the first hit, which SIGPIPEs
# codesign, and pipefail would read that as a failed check.
signature="$(codesign -dv "$app" 2>&1)"
printf '%s' "$signature" | grep -q "Identifier=$BUNDLE_ID" ||
  fail "the signed bundle does not carry the configured identifier"
echo "  ok   the GUI is the only microphone principal, sealed under $BUNDLE_ID"

agent_signature="$(codesign -dv "$app/Contents/MacOS/$AGENT_EXECUTABLE" 2>&1)"
printf '%s\n' "$agent_signature" | grep -qFx "Identifier=$AGENT_LABEL" ||
  fail "the signed agent does not carry the configured identifier $AGENT_LABEL"
echo "  ok   the agent carries the stable configured identifier $AGENT_LABEL"

# A signature without a profile is the dev and CI configuration: it embeds no
# profile and claims none of the keys only a profile can authorize (M84 D6).
[ ! -e "$app/Contents/embedded.provisionprofile" ] ||
  fail "an ad-hoc signature embedded a provisioning profile"
for key in keychain-access-groups com.apple.application-identifier com.apple.developer.team-identifier; do
  if printf '%s' "$gui_entitlements" | grep -qF "$key"; then
    fail "an ad-hoc signature carries $key"
  fi
done
echo "  ok   a signature without a profile carries no keychain entitlements and embeds no profile"

# The two updater lists have to agree, and nothing else compares them: one
# names the Mach-O programs the framework must carry, the other the bundles and
# executables codesign is handed, deepest first. A Sparkle upgrade that added a
# helper to the inventory alone would stage and verify and then ship it
# unsigned, which surfaces as an update that downloads and never installs. So
# every inventoried program must be, or live inside, something that gets signed.
for member in "${SPARKLE_MACHO_PATHS[@]}"; do
  covered=""
  for signed in "${SPARKLE_SIGNING_ORDER[@]}"; do
    case "$member" in
      "$signed" | "$signed"/*)
        covered=1
        break
        ;;
    esac
  done
  [ -n "$covered" ] ||
    fail "updater program $member is inventoried and under nothing sign_app.sh signs"
done
echo "  ok   every inventoried updater program lives under a signed path"

# The same agreement for the animation runtime's two lists, for the same
# reason: a library inventoried and under nothing signed would stage, verify,
# and ship unsigned.
for member in "${RIVE_MACHO_PATHS[@]}"; do
  covered=""
  for signed in "${RIVE_SIGNING_ORDER[@]}"; do
    case "$member" in
      "$signed" | "$signed"/*)
        covered=1
        break
        ;;
    esac
  done
  [ -n "$covered" ] ||
    fail "animation runtime program $member is inventoried and under nothing sign_app.sh signs"
done
echo "  ok   every inventoried animation runtime program lives under a signed path"

# The updater's four retained helpers are separate code, and each has to carry
# its own signature: macOS refuses to launch an unsigned helper, which surfaces
# as an update that downloads and then silently never installs. The framework
# itself is signed last of the five, so the seal covers them.
for member in "${SPARKLE_SIGNING_ORDER[@]}"; do
  codesign --verify --strict "$app/$SPARKLE_FRAMEWORK/$member" ||
    fail "updater component $member is not validly signed"
done
echo "  ok   every retained updater helper carries a valid signature"

for member in "${RIVE_SIGNING_ORDER[@]}"; do
  codesign --verify --strict "$app/$RIVE_FRAMEWORK/$member" ||
    fail "animation runtime component $member is not validly signed"
done
echo "  ok   the animation runtime carries a valid signature"

echo "sign_app_test: refusals"

app="$(fresh_bundle no-agent)"
rm "$app/Contents/MacOS/$AGENT_EXECUTABLE"
expect_refusal "a bundle with no agent to sign is refused" \
  "agent executable missing" \
  "$SIGN" "$app" -

# The engine and bundled-tools slots are declared signing classes: everything
# under them is signed individually — executables with the engine entitlement
# ladder, libraries and the bundled tool plain — instead of refusing the bundle.
app="$(fresh_bundle engine-tree)"
fake_app_build_engine_tree "$app/$(product_config engine_relative_path)/arm64" arm64
fake_app_build_stub "$app/$(product_config tools_relative_path)/cosign" -arch arm64 -arch x86_64
expect_pass "a populated engine slot signs as its own class" "$SIGN" "$app" -
codesign --verify --strict \
  "$app/$(product_config engine_relative_path)/arm64/erts-0.0/bin/beam.smp" ||
  fail "the engine VM is not validly signed"
codesign --verify --strict "$app/$(product_config tools_relative_path)/cosign" ||
  fail "the bundled cosign is not validly signed"
echo "  ok   engine VM and bundled cosign carry valid signatures"

app="$(fresh_bundle stowaway)"
fake_app_build_stub "$app/Contents/Resources/helper" -arch arm64 -arch x86_64
expect_refusal "a stowaway Mach-O anywhere in the bundle is refused" \
  "Contents/Resources/helper" \
  "$SIGN" "$app" -

# The same refusal inside the updater framework, which is the case a directory
# rule would miss: "anything under Frameworks" would sign this without anyone
# deciding to. The allowlist names Sparkle's five Mach-O files and nothing
# else, so a sixth stops the release.
app="$(fresh_bundle updater-stowaway)"
fake_app_build_stub "$app/$SPARKLE_FRAMEWORK/Versions/B/Sneak" -arch arm64 -arch x86_64
expect_refusal "a stowaway Mach-O inside the updater framework is refused" \
  "$SPARKLE_FRAMEWORK/Versions/B/Sneak" \
  "$SIGN" "$app" -

# A Sparkle version that moved or dropped a helper fails loudly here rather
# than shipping an updater with an unsigned program inside it.
app="$(fresh_bundle updater-missing-helper)"
rm "$app/$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
expect_refusal "an updater framework missing a retained helper is refused" \
  "carries no Versions/B/Autoupdate" \
  "$SIGN" "$app" -

app="$(fresh_bundle no-updater)"
rm -rf "${app:?}/${SPARKLE_FRAMEWORK:?}"
expect_refusal "a bundle with no updater framework to sign is refused" \
  "the updater framework is not staged" \
  "$SIGN" "$app" -

# The same allowlist inside the animation runtime: it names one library, so a
# second Mach-O stops the release instead of being signed by a directory rule.
app="$(fresh_bundle rive-stowaway)"
fake_app_build_stub "$app/$RIVE_FRAMEWORK/Versions/A/Sneak" -arch arm64 -arch x86_64
expect_refusal "a stowaway Mach-O inside the animation runtime is refused" \
  "$RIVE_FRAMEWORK/Versions/A/Sneak" \
  "$SIGN" "$app" -

# A runtime without the versioned bundle its signing order names fails loudly
# here rather than shipping a framework nothing signed. One that moved its
# library to another version letter is refused earlier, as undeclared Mach-O,
# by the stowaway rule above.
app="$(fresh_bundle rive-missing-version)"
rm -rf "${app:?}/${RIVE_FRAMEWORK:?}/Versions/A"
expect_refusal "an animation runtime missing its versioned bundle is refused" \
  "the animation runtime carries no Versions/A" \
  "$SIGN" "$app" -

app="$(fresh_bundle no-rive)"
rm -rf "${app:?}/${RIVE_FRAMEWORK:?}"
expect_refusal "a bundle with no animation runtime to sign is refused" \
  "the animation runtime is not staged" \
  "$SIGN" "$app" -

expect_refusal "a missing bundle is refused rather than silently signing nothing" \
  "no staged bundle at" \
  "$SIGN" "$WORK_DIR/absent.app" -

echo "sign_app_test: the keychain profile (M84 D6)"

# Fake provisioning profiles, CMS-wrapped with a throwaway key so the script
# decodes them through the same `security cms -D` a real one goes through.
# Nothing here is Apple-signed and nothing reaches a keychain: openssl writes
# every key and certificate into the work directory.
PROFILE_CHECK="$ROOT_DIR/scripts/provisioning_profile.py"
# Read with plistlib: plutil's key paths split on the dots these keys contain.
entitlement_value() {
  python3 -c 'import plistlib, sys; value = plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]]; print(value[0] if isinstance(value, list) else value)' \
    "$1" "$2"
}
# The bundle identifier an overlay names, read through the one reader in a
# subshell of its own, as each script that is handed the overlay reads it.
bundle_identifier_with() {
  (
    PRODUCT_CONFIG_OVERLAY="$1"
    # shellcheck source=scripts/product_config.sh
    source "$ROOT_DIR/scripts/product_config.sh"
    product_config bundle_identifier
  )
}

# Each identity signs with the keychain entitlements named for its bundle
# identifier: the released app's and the dev loop's. Each names its own app id,
# the team and that bundle identifier, and a group under that app id, so a login
# saved under one identity is never in the other's group.
DEV_OVERLAY="$ROOT_DIR/scripts/product.dev.json"
for overlay in "" "$DEV_OVERLAY"; do
  identity="$(bundle_identifier_with "$overlay")"
  file="$ROOT_DIR/scripts/entitlements/keychain/$identity.entitlements"
  [ -f "$file" ] || fail "no keychain entitlements for $identity at $file"
  team="$(entitlement_value "$file" com.apple.developer.team-identifier)"
  app_id="$(entitlement_value "$file" com.apple.application-identifier)"
  group="$(entitlement_value "$file" keychain-access-groups)"
  [ "$app_id" = "$team.$identity" ] || fail "$file names $app_id, and the bundle is $team.$identity"
  [ "$group" = "$app_id.logins" ] || fail "$file names the group $group"
  echo "  ok   $identity's keychain entitlements name $app_id and $group"
done
DEV_BUNDLE_ID="$(bundle_identifier_with "$DEV_OVERLAY")"
[ "$DEV_BUNDLE_ID" != "$BUNDLE_ID" ] || fail "the dev overlay does not name another bundle identifier"

KEYCHAIN_ENTITLEMENTS="$ROOT_DIR/scripts/entitlements/keychain/$BUNDLE_ID.entitlements"
TEAM="$(entitlement_value "$KEYCHAIN_ENTITLEMENTS" com.apple.developer.team-identifier)"
APP_ID="$(entitlement_value "$KEYCHAIN_ENTITLEMENTS" com.apple.application-identifier)"
GROUP="$(entitlement_value "$KEYCHAIN_ENTITLEMENTS" keychain-access-groups)"

PROFILES="$WORK_DIR/profiles"
mkdir -p "$PROFILES"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=fake profile signer" \
  -keyout "$PROFILES/signer.key" -out "$PROFILES/signer.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Developer ID Application: Fixture (TEAMID0000)" \
  -keyout "$PROFILES/developer.key" -outform DER -out "$PROFILES/developer.der" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Developer ID Application: Other (TEAMID0000)" \
  -keyout "$PROFILES/other.key" -outform DER -out "$PROFILES/other.der" >/dev/null 2>&1

# fake_profile <name> [field=value ...]: a Developer ID profile for this
# product, expiring in a year and listing developer.der, with any field
# replaced: team, app_id, groups (comma-separated), all_devices, platform,
# expires_days.
fake_profile() {
  local name="$1"
  shift
  python3 - "$PROFILES/$name.plist" "$TEAM" "$APP_ID" "$GROUP" "$PROFILES/developer.der" "$@" <<'PY'
import datetime
import plistlib
import sys

out, team, app_id, group, certificate = sys.argv[1:6]
fields = dict(argument.split("=", 1) for argument in sys.argv[6:])
team = fields.get("team", team)
expires = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=int(fields.get("expires_days", "365")))
with open(certificate, "rb") as handle:
    der = handle.read()
profile = {
    "Name": "Fermix Developer ID fixture",
    "UUID": "00000000-0000-4000-8000-000000000000",
    "TeamIdentifier": [team],
    "Platform": [fields.get("platform", "OSX")],
    "ProvisionsAllDevices": fields.get("all_devices", "true") == "true",
    "ExpirationDate": expires,
    "DeveloperCertificates": [der],
    "Entitlements": {
        "com.apple.application-identifier": fields.get("app_id", app_id),
        "com.apple.developer.team-identifier": team,
        "keychain-access-groups": fields.get("groups", f"{team}.*").split(","),
    },
}
with open(out, "wb") as handle:
    plistlib.dump(profile, handle)
PY
  openssl smime -sign -binary -nodetach -outform DER -signer "$PROFILES/signer.pem" \
    -inkey "$PROFILES/signer.key" -in "$PROFILES/$name.plist" -out "$PROFILES/$name.provisionprofile"
  printf '%s\n' "$PROFILES/$name.provisionprofile"
}

# What an identity signs: the base set with its keychain keys merged over it,
# as sign_app.sh merges them.
signed_set() {
  local out="$PROFILES/$1.entitlements"
  cp "$ROOT_DIR/Apps/Fermix/Sources/Fermix/Fermix.entitlements" "$out"
  /usr/libexec/PlistBuddy -c "Merge $ROOT_DIR/scripts/entitlements/keychain/$1.entitlements" "$out" >/dev/null
  printf '%s\n' "$out"
}
RELEASE_SET="$(signed_set "$BUNDLE_ID")"
DEV_SET="$(signed_set "$DEV_BUNDLE_ID")"

check_profile() {
  python3 "$PROFILE_CHECK" check --profile "$1" --entitlements "$RELEASE_SET" --bundle-id "$BUNDLE_ID" "${@:2}"
}

good="$(fake_profile good)"
expect_pass "a Developer ID profile granting the team's groups authorizes the release" check_profile "$good"
dev_profile="$(fake_profile dev "app_id=$TEAM.$DEV_BUNDLE_ID")"
expect_pass "the development identity's profile authorizes the dev loop's own set" \
  python3 "$PROFILE_CHECK" check --profile "$dev_profile" --entitlements "$DEV_SET" --bundle-id "$DEV_BUNDLE_ID"
expect_refusal "the release's profile does not authorize the dev loop's set" \
  "the profile is for the app id" \
  python3 "$PROFILE_CHECK" check --profile "$good" --entitlements "$DEV_SET" --bundle-id "$DEV_BUNDLE_ID"
expect_pass "a profile granting exactly the group authorizes it too" \
  check_profile "$(fake_profile exact "groups=$GROUP")"
expect_pass "the profile lists the certificate that signed" \
  check_profile "$good" --certificate "$PROFILES/developer.der"

expect_refusal "a profile that does not list the signing certificate is refused" \
  "does not list the certificate that signed" \
  check_profile "$good" --certificate "$PROFILES/other.der"

# Each mismatch, through sign_app.sh itself. The identity is a Developer ID
# name no keychain holds, which is safe because the profile is judged before
# codesign is ever asked to sign: every case below must refuse with the
# profile's reason and leave the bundle unsigned with no profile embedded.
FAKE_IDENTITY="Developer ID Application: Fixture ($TEAM)"
expect_profile_refusal() {
  local what="$1" expected="$2" profile="$3" app
  app="$(fresh_bundle "profile-$(printf '%s' "$what" | tr -c 'a-z0-9' '-')")"
  expect_refusal "$what" "$expected" "$SIGN" "$app" "$FAKE_IDENTITY" "$profile"
  [ ! -e "$app/Contents/embedded.provisionprofile" ] || fail "$what: a refused profile was embedded"
  # A sealed bundle carries _CodeSignature; the stand-in executables are
  # linker-signed on their own, so codesign -dv would answer for them instead.
  [ ! -d "$app/Contents/_CodeSignature" ] ||
    fail "$what: the bundle was signed although its profile was refused"
}

expect_profile_refusal "a profile for another team is refused" \
  "the profile is for team" "$(fake_profile team team=OTHERTEAM1)"
expect_profile_refusal "a profile for another app id is refused" \
  "the profile is for the app id" "$(fake_profile app "app_id=$TEAM.io.tezra.FermixPet.dev")"
expect_profile_refusal "a profile that does not grant the logins group is refused" \
  "does not authorize the keychain access group $GROUP" "$(fake_profile groups "groups=$TEAM.io.tezra.other")"
expect_profile_refusal "a profile with no keychain group at all is refused" \
  "does not authorize the keychain access group" "$(fake_profile nogroups groups=)"
expect_profile_refusal "an expired profile is refused" \
  "the profile expired on" "$(fake_profile expired expires_days=-1)"
expect_profile_refusal "a development profile, which lists its Macs, is refused" \
  "not a Developer ID profile" "$(fake_profile development all_devices=false)"
expect_profile_refusal "a profile for another platform is refused" \
  "not macOS" "$(fake_profile ios platform=iOS)"

printf 'not a profile\n' >"$PROFILES/garbage.provisionprofile"
expect_profile_refusal "a file that is not a provisioning profile is refused" \
  "is not a provisioning profile" "$PROFILES/garbage.provisionprofile"
expect_profile_refusal "a missing profile is refused" \
  "no provisioning profile at" "$PROFILES/absent.provisionprofile"

# An identity with no keychain entitlements of its own is refused before
# anything is signed, rather than signed with another identity's group.
printf '{"bundle_identifier": "%s.unlisted"}\n' "$BUNDLE_ID" >"$WORK_DIR/unlisted.json"
app="$(fresh_bundle unlisted-identity)"
expect_refusal "a bundle identifier with no keychain entitlements is refused" \
  "no keychain entitlements for $BUNDLE_ID.unlisted" \
  env PRODUCT_CONFIG_OVERLAY="$WORK_DIR/unlisted.json" "$SIGN" "$app" "$FAKE_IDENTITY" "$good"
[ ! -e "$app/Contents/embedded.provisionprofile" ] || fail "an unlisted identity embedded a profile"
[ ! -d "$app/Contents/_CodeSignature" ] || fail "an unlisted identity was signed"

app="$(fresh_bundle adhoc-with-profile)"
expect_refusal "an ad-hoc signature with a profile is refused" \
  "an ad-hoc signature cannot carry a provisioning profile" \
  "$SIGN" "$app" - "$good"
[ ! -e "$app/Contents/embedded.provisionprofile" ] || fail "an ad-hoc signature embedded a profile"

app="$(fresh_bundle stale-profile)"
cp "$good" "$app/Contents/embedded.provisionprofile"
expect_refusal "a bundle that already embeds a profile is refused when none is given" \
  "already embeds a provisioning profile" \
  "$SIGN" "$app" -

# The other half of the match: a signature carrying the keychain entitlements
# without an embedded profile is refused after signing, whatever put them
# there. The base set, as every profile-less signature carries it, passes.
expect_refusal "keychain entitlements without a profile are refused" \
  "embeds no provisioning profile" \
  python3 "$PROFILE_CHECK" absent --entitlements "$RELEASE_SET"
expect_pass "the base entitlements need no profile" \
  python3 "$PROFILE_CHECK" absent --entitlements "$ROOT_DIR/Apps/Fermix/Sources/Fermix/Fermix.entitlements"
expect_refusal "entitlements claiming another app id are refused against a good profile" \
  "and this bundle is $APP_ID" \
  python3 "$PROFILE_CHECK" check --profile "$good" --entitlements "$RELEASE_SET" --bundle-id "$BUNDLE_ID.dev"

harness_finished=1
echo "sign_app_test: ok"
