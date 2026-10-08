#!/usr/bin/env bash
#
# The one Developer ID Application identity in the login keychain.
#
# Shared by scripts/dev_e2e.sh and scripts/cloud_acceptance.sh, which both
# sign a bundle whose background agent is registered through SMAppService.
# macOS keys that registration on the Team ID of the signed code, so an ad-hoc
# signature (no Team ID) makes every rebuild a new program to launchd and the
# agent stops launching; docs/design/M34_MACOS_APP_RCA_2026-09-05.md has the
# evidence. Exactly one identity, or a refusal that says what to import: a
# second identity would make the choice silent.
#
# Usage:  source "$(dirname "$0")/signing_identity.sh"
#         identity="$(signing_identity)" || exit 1
#
# Prints the identity's common name, the string codesign takes as --sign. On a
# refusal it prints the reason to stderr and returns 1.
signing_identity() {
  local listing matches count
  listing="$(security find-identity -v -p codesigning 2>/dev/null)" || listing=""
  matches="$(printf '%s\n' "$listing" | grep -F 'Developer ID Application:' || true)"
  count="$(printf '%s' "$matches" | grep -c '"' || true)"
  case "$count" in
    1) printf '%s\n' "$matches" | sed -E 's/^[^"]*"([^"]*)".*$/\1/' ;;
    0)
      echo "no Developer ID Application identity in the login keychain. The background agent is registered through SMAppService, which keys on the Team ID of the signed code; an ad-hoc signature has none, so every rebuild is a new program to launchd and the agent stops launching. Import the certificate this team releases with (docs/design/E2E_RUNBOOK.md, \"Importing your Developer ID on this Mac\"), then run again" >&2
      return 1
      ;;
    *)
      echo "$count Developer ID Application identities in the login keychain; keep exactly one so the choice is not silent" >&2
      return 1
      ;;
  esac
}
