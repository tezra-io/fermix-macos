#!/usr/bin/env bash
#
# Gate: the vendor mark provenance record is complete, and every claim in it
# is true of the files on disk.
#
# M34 section 7 requires that provider and channel marks come only from
# official vendor brand resources and that each one records source URL,
# retrieval date, usage terms, permitted treatment, dark-mode policy, and
# accessibility label. That is a promise about bytes, so it is checked against
# bytes: every declared asset must exist and hash to its recorded sha256, and
# every vendor that has no retrievable mark must declare the text-plus-symbol
# treatment instead of shipping a file.
#
# The check is offline and hermetic. Refreshing the marks from the vendors is
# scripts/fetch_vendor_marks.sh, which is a separate, owner-run, network step.
#
# Usage: check_vendor_marks.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKS_DIR="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources/VendorMarks"

python3 "$ROOT_DIR/scripts/vendor_marks.py" check --marks-dir "$MARKS_DIR"
echo "check_vendor_marks: ok"
