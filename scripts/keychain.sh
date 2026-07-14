#!/usr/bin/env bash
#
# Import the "Developer ID Application" certificate into an ephemeral CI keychain
# so headless codesign can use it, then set the partition list (without which the
# first codesign call blocks forever on a UI prompt). Follows the proven compux
# release flow, with an explicit PKCS#12 format so import never depends on the
# temp file's extension.
#
# Usage: keychain.sh import
# Required env: MACOS_CERT_P12_BASE64  MACOS_CERT_PASSWORD  MACOS_KEYCHAIN_PASSWORD
set -euo pipefail

KEYCHAIN="${FERMIX_KEYCHAIN:-build.keychain}"

import_cert() {
  : "${MACOS_CERT_P12_BASE64:?MACOS_CERT_P12_BASE64 is required}"
  : "${MACOS_CERT_PASSWORD:?MACOS_CERT_PASSWORD is required}"
  : "${MACOS_KEYCHAIN_PASSWORD:?MACOS_KEYCHAIN_PASSWORD is required}"

  local tmpdir p12
  tmpdir="$(mktemp -d)"
  # The `.p12` name AND the explicit `-f pkcs12` on import both matter: on an
  # extension-less temp file, `security import` fails format inference with
  # "Unknown format in import" even for a valid PKCS#12. `tr -d` strips any
  # whitespace from wrapped/pasted base64 so the decoded bytes are exact.
  p12="$tmpdir/cert.p12"
  printf '%s' "$MACOS_CERT_P12_BASE64" | tr -d '[:space:]' | base64 --decode >"$p12"

  # Non-secret sanity line: a Developer ID .p12 is binary ("data"), a few KB. A
  # tiny or text result means MACOS_CERT_P12_BASE64 is not a base64-encoded .p12.
  echo "certificate: decoded $(wc -c <"$p12" | tr -d ' ') bytes, type: $(file -b "$p12" 2>/dev/null || echo unknown)"

  security create-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security default-keychain -s "$KEYCHAIN"
  security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$p12" -f pkcs12 -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

  rm -rf "$tmpdir"
}

case "${1:-import}" in
  import) import_cert ;;
  *)
    echo "usage: keychain.sh import" >&2
    exit 2
    ;;
esac
