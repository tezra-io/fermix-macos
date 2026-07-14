#!/usr/bin/env bash
#
# Verify the vendored realtime wire contract matches its recorded checksums.
#
# The canonical source of the contract is `FermixCore.Realtime.Protocol` in the
# fermix repo. The files under docs/realtime-contract/ are VENDORED copies pinned
# by checksum so an accidental edit — or drift introduced by a re-vendor — is
# caught here. Re-vendoring is a deliberate, reviewed step: copy the fresh files
# from fermix `priv/realtime/` and regenerate CHECKSUMS.txt in the same change.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/docs/realtime-contract"

shasum -a 256 -c CHECKSUMS.txt
echo "realtime wire contract: checksums OK"
