#!/usr/bin/env bash
#
# The release notes of one version, read from CHANGELOG.md.
#
# The changelog is kept as the work lands (AGENTS.md, working rules), and the
# release rail publishes a version's section as the GitHub Release's body
# rather than GitHub's own generated list of pull requests, which named the
# chore PR and nothing a person could read. A version with no section, or an
# empty one, refuses: a release without notes is a release nobody wrote down,
# and the rail asks this question before it signs anything.
#
# Prints the lines under `## <version> (<date>)`, up to the next `## ` heading
# or the end of the file, with leading and trailing blank lines dropped.
#
# Usage: changelog_section.sh <version> [changelog]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: changelog_section.sh <version> [changelog]}"
CHANGELOG="${2:-$ROOT_DIR/CHANGELOG.md}"

fail() {
  echo "changelog_section: $*" >&2
  exit 1
}

[ -f "$CHANGELOG" ] || fail "no changelog at $CHANGELOG"

section="$(awk -v version="$VERSION" '
  BEGIN { found = 0; inside = 0 }
  /^## / {
    if (inside) { exit }
    if (index($0, "## " version " (") == 1) { found = 1; inside = 1; next }
  }
  inside { print }
  END { if (!found) exit 2 }
' "$CHANGELOG")" || {
  status=$?
  [ "$status" -eq 2 ] && fail "CHANGELOG.md has no section for $VERSION; add '## $VERSION (YYYY-MM-DD)' with its lines before tagging"
  fail "could not read $CHANGELOG"
}

# Drop the blank lines around the section; what is left is the body.
section="$(printf '%s\n' "$section" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
[ -n "$section" ] || fail "the section for $VERSION in CHANGELOG.md is empty; write the release notes before tagging"

printf '%s\n' "$section"
