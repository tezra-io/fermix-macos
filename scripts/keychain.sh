#!/usr/bin/env bash
#
# Import the "Developer ID Application" certificate into an ephemeral CI keychain
# so headless codesign can use it, then set the partition list (without which the
# first codesign call blocks forever on a UI prompt). Ported verbatim from the
# proven compux release flow.
#
# Usage: keychain.sh import
# Required env: MACOS_CERT_P12_BASE64  MACOS_CERT_PASSWORD  MACOS_KEYCHAIN_PASSWORD
set -euo pipefail

KEYCHAIN="${FERMIX_KEYCHAIN:-build.keychain}"

import_cert() {
  : "${MACOS_CERT_P12_BASE64:?MACOS_CERT_P12_BASE64 is required}"
  : "${MACOS_CERT_PASSWORD:?MACOS_CERT_PASSWORD is required}"
  : "${MACOS_KEYCHAIN_PASSWORD:?MACOS_KEYCHAIN_PASSWORD is required}"

  local p12
  p12="$(mktemp)"
  printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode >"$p12"

  security create-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security default-keychain -s "$KEYCHAIN"
  security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$p12" -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

  rm -f "$p12"
}

case "${1:-import}" in
  import) import_cert ;;
  *)
    echo "usage: keychain.sh import" >&2
    exit 2
    ;;
esac
