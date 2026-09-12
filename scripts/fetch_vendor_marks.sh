#!/usr/bin/env bash
#
# Refresh the vendor marks from the vendors' own official brand resources.
#
# This is the network half of the provenance contract and it is owner-run, not
# a build gate: scripts/check_vendor_marks.sh is the offline gate. Running this
# re-downloads every asset recorded in VendorMarks/PROVENANCE.json from the URL
# recorded beside it, and compares the bytes with the recorded sha256.
#
# It reports rather than mutates by default. A hash that moved means the vendor
# published a new mark, which is a design review, not a silent overwrite. Pass
# --write once the new file has been looked at.
#
# Marks whose bytes come from fermix itself are printed as pinned and are never
# downloaded: a plugin logo lives in fermix's checked-in catalog and a driver
# mark in its setup surface, so both are re-vendored there rather than fetched
# from a third party. Their records carry origin catalog or first_party.
#
# Vendors whose official asset could not be retrieved are printed at the end
# with their official page. Those render as the vendor text name beside a
# neutral SF Symbol until an owner retrieves the file interactively; nothing
# here invents a mark for them.
#
# Usage: fetch_vendor_marks.sh [--write]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKS_DIR="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources/VendorMarks"

python3 "$ROOT_DIR/scripts/vendor_marks.py" fetch --marks-dir "$MARKS_DIR" "$@"
