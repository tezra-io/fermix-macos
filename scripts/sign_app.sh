#!/usr/bin/env bash
#
# Inside-out sign a staged FermixPet.app, then verify.
#
# Shared by package_release.sh (real Developer ID) and ci.yml (adhoc "-", no
# credentials) so the signing STRUCTURE — nested resource bundle signed first,
# hardened runtime, the single microphone entitlement, no get-task-allow — is
# exercised on every push, not only at a gated release.
#
# Usage: sign_app.sh <app-path> <identity>
#   <identity>  "Developer ID Application: <Name> (<TEAMID>)" for release,
#               or "-" for an ad-hoc signature (CI structure check).
set -euo pipefail

APP="${1:?usage: sign_app.sh <app-path> <identity>}"
IDENTITY="${2:?usage: sign_app.sh <app-path> <identity>}"

BUNDLE_ID="io.tezra.FermixPet"
RESOURCE_BUNDLE_NAME="FermixPet_FermixPet.bundle"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/Apps/FermixPet/Sources/FermixPet/FermixPet.entitlements"

fail() {
  echo "sign_app: $*" >&2
  exit 1
}

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

codesign --force "${timestamp[@]}" --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --identifier "$BUNDLE_ID" \
  --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.device.audio-input" \
  || fail "microphone entitlement absent after signing"
if codesign -d --entitlements - "$APP" 2>&1 | grep -q '"get-task-allow"'; then
  fail "get-task-allow present — not a release build"
fi

echo "sign_app: signed $APP (identity: $IDENTITY)"
