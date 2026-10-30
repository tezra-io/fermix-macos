#!/usr/bin/env bash
#
# Inside-out sign a staged Fermix app bundle, then verify.
#
# Shared by package_release.sh (real Developer ID), dev_run.sh, and
# .github/workflows/fermix-app.yml (adhoc "-", no credentials) so the signing
# STRUCTURE — nested code signed first, hardened runtime, the single microphone
# entitlement on the GUI only, no get-task-allow — is exercised on every push,
# not only at a gated release.
#
# Identity and layout come from Product.json through scripts/product_config.sh.
#
# It verifies its own output, which is a narrower job than
# scripts/verify_staged_app.sh: this script proves the signature it just applied
# is valid and carries the right entitlements, while the verifier proves the
# whole bundle is the product the configuration declares.
#
# Two declared configurations of the GUI's signature (M84 D6):
#   without a profile  the base entitlements (Fermix.entitlements) and no
#                      embedded profile: CI's ad-hoc check, dev_run.sh, and the
#                      Developer ID dev loop. These builds have no website
#                      login store.
#   with a profile     a Developer ID identity only: the base entitlements plus
#                      scripts/entitlements/release_keychain.entitlements (the
#                      login keychain access group and the identity keys that
#                      authorize it), and the profile embedded as
#                      Contents/embedded.provisionprofile. package_release.sh
#                      is the caller.
# The profile is proven to authorize those entitlements before anything is
# signed (scripts/provisioning_profile.py), and the signed result is proven
# again after: keychain entitlements without a matching embedded profile, or a
# profile without them, ship an app macOS kills at launch.
#
# Usage: sign_app.sh <app-path> <identity> [<provisioning-profile>]
#   <identity>  "Developer ID Application: <Name> (<TEAMID>)" for release,
#               or "-" for an ad-hoc signature (CI structure check).
#   <provisioning-profile>
#               the Developer ID provisioning profile for the product's bundle
#               identifier; refused with the ad-hoc identity.
set -euo pipefail

USAGE="usage: sign_app.sh <app-path> <identity> [<provisioning-profile>]"
APP="${1:?$USAGE}"
IDENTITY="${2:?$USAGE}"
PROFILE="${3:-}"
[ "$#" -le 3 ] || { echo "sign_app: unexpected arguments ($USAGE)" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/sparkle.sh
source "$ROOT_DIR/scripts/sparkle.sh"
# shellcheck source=scripts/rive.sh
source "$ROOT_DIR/scripts/rive.sh"

BUNDLE_ID="$(product_config bundle_identifier)"
RESOURCE_BUNDLE_NAME="$(product_config swift_resource_bundle_name)"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"
ENGINE_RELATIVE_PATH="$(product_config engine_relative_path)"
TOOLS_RELATIVE_PATH="$(product_config tools_relative_path)"
SPARKLE_FRAMEWORK="$(product_config frameworks_relative_path)/$SPARKLE_FRAMEWORK_NAME"
RIVE_FRAMEWORK="$(product_config frameworks_relative_path)/$RIVE_FRAMEWORK_NAME"
ENTITLEMENTS="$ROOT_DIR/Apps/Fermix/Sources/Fermix/Fermix.entitlements"
RELEASE_ENTITLEMENTS="$ROOT_DIR/scripts/entitlements/release_keychain.entitlements"
ENGINE_ENTITLEMENTS="$ROOT_DIR/scripts/entitlements/engine.entitlements"
PROFILE_CHECK="$ROOT_DIR/scripts/provisioning_profile.py"
EMBEDDED_PROFILE="$APP/Contents/embedded.provisionprofile"

# The GUI's entitlements and the post-sign evidence are written here, and the
# directory goes on every exit path.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "sign_app: $*" >&2
  exit 1
}

# Refuse Mach-O this script has no signing rule for, BEFORE signing anything.
#
# M34 section 7 requires a release to fail on unknown executable content rather
# than ship it unsigned. Five classes are known and every one of their
# members is signed individually below: the two Contents/MacOS executables,
# the engine trees under the Engine slot (ERTS executables, NIFs, dylibs —
# signed with the engine entitlement set on executables), the bundled
# cosign under the Tools slot, the updater framework's library with its
# four retained helpers, and the animation runtime's one library. Anything
# outside those classes stops the release instead of being signed with
# someone else's rules or skipped.
#
# The two frameworks' members are named one by one from scripts/sparkle.sh and
# scripts/rive.sh rather than admitted by a directory rule: "anything under
# Frameworks" would sign whatever a future dependency drops there, which is
# exactly what this refusal exists to prevent. A version that moves or adds a
# program fails here and is re-declared deliberately.
refuse_unknown_nested_code() {
  local unexpected known macho
  [ -d "$APP" ] || fail "no staged bundle at $APP"
  # One newline-separated allowlist, which is how grep -F reads a set of
  # fixed patterns. Held in a variable rather than a file so no error path
  # can leave one behind.
  known="Contents/MacOS/$GUI_EXECUTABLE"
  known+=$'\n'"Contents/MacOS/$AGENT_EXECUTABLE"
  known+=$'\n'"$TOOLS_RELATIVE_PATH/cosign"
  for macho in "${SPARKLE_MACHO_PATHS[@]}"; do
    known+=$'\n'"$SPARKLE_FRAMEWORK/$macho"
  done
  for macho in "${RIVE_MACHO_PATHS[@]}"; do
    known+=$'\n'"$RIVE_FRAMEWORK/$macho"
  done
  # `file` reports a universal binary once for the fat header and once per
  # slice, the per-slice lines carrying a " (for architecture x)" suffix, so the
  # suffix is stripped and the list deduplicated before anything is compared.
  unexpected="$(
    cd "$APP" &&
      find . -type f -print0 |
      xargs -0 file |
      grep 'Mach-O' |
      sed -e 's/:.*//' -e 's| (for architecture [^)]*)$||' -e 's|^\./||' |
      sort -u |
      grep -v "^$ENGINE_RELATIVE_PATH/" |
      grep -v -x -F "$known" || true
  )"
  [ -z "$unexpected" ] || fail "unknown nested executable content, which only a
declared signing class can sign:
$unexpected"
}

refuse_unknown_nested_code

# The GUI's entitlements for this signature, decided and proven before anything
# is signed, so a profile that cannot authorize the release leaves the bundle
# untouched.
#
# Without a profile the base set is the whole of it, and a bundle that already
# embeds a profile is refused: signing over it would seal a profile the
# signature does not use. With one, the identity must be a Developer ID (an
# ad-hoc signature has no team for a profile to name), the release-only keys
# are merged over the base set, the profile must authorize exactly that merged
# set for this bundle identifier, and only then is it embedded.
prepare_gui_entitlements() {
  if [ -z "$PROFILE" ]; then
    [ ! -e "$EMBEDDED_PROFILE" ] ||
      fail "the bundle already embeds a provisioning profile and none was given; stage a fresh bundle"
    GUI_ENTITLEMENTS="$ENTITLEMENTS"
    return 0
  fi

  [ "$IDENTITY" != "-" ] ||
    fail "an ad-hoc signature cannot carry a provisioning profile; the profile authorizes a Developer ID signature only"
  [ -f "$PROFILE" ] || fail "no provisioning profile at $PROFILE"
  [ -f "$RELEASE_ENTITLEMENTS" ] || fail "release entitlements missing at $RELEASE_ENTITLEMENTS"

  GUI_ENTITLEMENTS="$WORK_DIR/gui.entitlements"
  cp "$ENTITLEMENTS" "$GUI_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Merge $RELEASE_ENTITLEMENTS" "$GUI_ENTITLEMENTS" >/dev/null ||
    fail "could not merge the release entitlements"
  python3 "$PROFILE_CHECK" check --profile "$PROFILE" \
    --entitlements "$GUI_ENTITLEMENTS" --bundle-id "$BUNDLE_ID" ||
    fail "the provisioning profile does not authorize this release's entitlements; nothing was signed"
  cp "$PROFILE" "$EMBEDDED_PROFILE"
}

prepare_gui_entitlements

# A secure timestamp needs Apple's timestamp server, which rejects the ad-hoc
# identity; only request it for a real Developer ID signature.
timestamp=(--timestamp)
[ "$IDENTITY" = "-" ] && timestamp=(--timestamp=none)

nested="$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME"

# Inside-out: sign the nested resource bundle first. The universal (xcbuild) build
# emits a structured .bundle with its own Info.plist that `--verify --deep --strict`
# requires to carry a signature; signing only the outer app (deliberately without
# --deep) would leave it unsigned and fail verification.
if [ -d "$nested/Contents" ]; then
  codesign --force "${timestamp[@]}" --options runtime --sign "$IDENTITY" "$nested"
fi

# The engine trees and the bundled tool are the deepest nested code, so they
# are signed first, inside-out: non-executable Mach-O (NIFs, dylibs) with the
# hardened runtime and no entitlements, ERTS executables with the engine
# entitlement set (scripts/entitlements/engine.entitlements — the Stage 0
# discovery ladder, which starts empty and grows only on observed launch
# failures), and cosign as a plain hardened-runtime tool.
sign_engine_and_tools() {
  local engine_root="$APP/$ENGINE_RELATIVE_PATH" tools_root="$APP/$TOOLS_RELATIVE_PATH"
  local macho kind executables=()

  if [ -d "$engine_root" ] && [ -n "$(find "$engine_root" -mindepth 1 -print -quit)" ]; then
    [ -f "$ENGINE_ENTITLEMENTS" ] ||
      fail "engine entitlements missing at $ENGINE_ENTITLEMENTS"
    while IFS= read -r -d '' macho; do
      kind="$(file -b "$macho")"
      case "$kind" in
        *Mach-O*executable*) executables+=("$macho") ;;
        *Mach-O*)
          codesign --force "${timestamp[@]}" --options runtime --sign "$IDENTITY" "$macho" ||
            fail "could not sign engine library $macho"
          ;;
      esac
    done < <(find "$engine_root" -type f -print0)
    for macho in ${executables[@]+"${executables[@]}"}; do
      codesign --force "${timestamp[@]}" --options runtime \
        --entitlements "$ENGINE_ENTITLEMENTS" --sign "$IDENTITY" "$macho" ||
        fail "could not sign engine executable $macho"
    done
  fi

  if [ -x "$tools_root/cosign" ]; then
    codesign --force "${timestamp[@]}" --options runtime --sign "$IDENTITY" "$tools_root/cosign" ||
      fail "could not sign bundled cosign"
  fi
}

sign_engine_and_tools

# The updater framework, signed inside-out inside itself before the app
# seals it. Sparkle's four retained helpers are separate code — two XPC
# services, an updater application, and the Autoupdate tool — and each
# carries its own signature; signing only the framework would leave four
# unsigned programs macOS refuses to launch, which surfaces as an update
# that silently never installs. The order comes from scripts/sparkle.sh,
# deepest first.
#
# No entitlements: the app is not sandboxed, so Sparkle's sandboxed
# installer-launcher service is not in use, and none of these helpers is a
# microphone principal. The hardened runtime is required on all of them for
# notarization.
sign_sparkle() {
  local framework="$APP/$SPARKLE_FRAMEWORK" member
  [ -d "$framework" ] || fail "the updater framework is not staged at $SPARKLE_FRAMEWORK"
  for member in "${SPARKLE_SIGNING_ORDER[@]}"; do
    [ -e "$framework/$member" ] ||
      fail "the updater framework carries no $member; the pinned version moved it"
    codesign --force "${timestamp[@]}" --options runtime --sign "$IDENTITY" "$framework/$member" ||
      fail "could not sign updater component $member"
  done
}

sign_sparkle

# The animation runtime, signed before the app seals it, in the order
# scripts/rive.sh declares. It carries no program of its own, so its versioned
# bundle is the whole of it; left unsigned, codesign refuses to seal the app
# over it. No entitlements, and the hardened runtime for notarization, as the
# updater's members have.
sign_rive() {
  local framework="$APP/$RIVE_FRAMEWORK" member
  [ -d "$framework" ] || fail "the animation runtime is not staged at $RIVE_FRAMEWORK"
  for member in "${RIVE_SIGNING_ORDER[@]}"; do
    [ -e "$framework/$member" ] ||
      fail "the animation runtime carries no $member; the pinned version moved it"
    codesign --force "${timestamp[@]}" --options runtime --sign "$IDENTITY" "$framework/$member" ||
      fail "could not sign animation runtime component $member"
  done
}

sign_rive

# The agent is nested Mach-O inside Contents/MacOS, so it is signed before the
# outer bundle too. It carries no entitlements: the GUI is the only microphone
# principal, and one consent never implies another. Its signing identifier is
# the configured service label, not a value derived from this build's Mach-O.
agent="$APP/Contents/MacOS/$AGENT_EXECUTABLE"
[ -f "$agent" ] || fail "agent executable missing at $agent"
codesign --force "${timestamp[@]}" --options runtime \
  --identifier "$AGENT_LABEL" --sign "$IDENTITY" "$agent"

codesign --force "${timestamp[@]}" --options runtime \
  --entitlements "$GUI_ENTITLEMENTS" \
  --identifier "$BUNDLE_ID" \
  --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

# The signature as macOS will judge it at launch: the entitlements it actually
# carries against the profile actually embedded, and, with a profile, the
# certificate that made it. Read off the signed bundle rather than the inputs,
# so a merge, a copy or a codesign that did something else is caught here and
# not by the first person who opens the app.
check_signed_profile_match() {
  local signed="$WORK_DIR/signed.entitlements"
  codesign -d --entitlements - --xml "$APP" >"$signed" 2>/dev/null ||
    fail "could not read the signed entitlements"
  if [ ! -e "$EMBEDDED_PROFILE" ]; then
    python3 "$PROFILE_CHECK" absent --entitlements "$signed" >/dev/null ||
      fail "the signature carries keychain entitlements without an embedded provisioning profile"
    return 0
  fi
  codesign -d --extract-certificates="$WORK_DIR/certificate" "$APP" 2>/dev/null ||
    fail "could not read the signing certificate"
  [ -f "$WORK_DIR/certificate0" ] ||
    fail "the bundle embeds a provisioning profile and its signature carries no certificate"
  python3 "$PROFILE_CHECK" check --profile "$EMBEDDED_PROFILE" --entitlements "$signed" \
    --bundle-id "$BUNDLE_ID" --certificate "$WORK_DIR/certificate0" ||
    fail "the signed entitlements and the embedded provisioning profile do not match"
}

check_signed_profile_match

agent_signature="$(codesign -dv "$agent" 2>&1)"
printf '%s\n' "$agent_signature" | grep -qFx "Identifier=$AGENT_LABEL" ||
  fail "agent signing identifier does not match $AGENT_LABEL"

codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.device.audio-input" \
  || fail "microphone entitlement absent after signing"
if codesign -d --entitlements - "$APP" 2>&1 | grep -q '"get-task-allow"'; then
  fail "get-task-allow present — not a release build"
fi
if codesign -d --entitlements - "$agent" 2>&1 | grep -q "com.apple.security.device.audio-input"; then
  fail "agent carries the microphone entitlement — only the GUI may"
fi

# Every retained helper is sealed on its own. `--verify --deep` above walks
# the app's nested code and a helper that failed to sign would surface
# there; this says so in the updater's own words, per member, so a Sparkle
# upgrade that quietly stops shipping one is not read as success. The
# animation runtime's one member is said the same way, in its own words.
for member in "${SPARKLE_SIGNING_ORDER[@]}"; do
  codesign --verify --strict "$APP/$SPARKLE_FRAMEWORK/$member" ||
    fail "updater component $member is not validly signed"
done
for member in "${RIVE_SIGNING_ORDER[@]}"; do
  codesign --verify --strict "$APP/$RIVE_FRAMEWORK/$member" ||
    fail "animation runtime component $member is not validly signed"
done

echo "sign_app: signed $APP (identity: $IDENTITY)"
