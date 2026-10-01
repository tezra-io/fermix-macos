#!/usr/bin/env bash
#
# Harness for scripts/changelog_section.sh.
#
# The release rail publishes a version's changelog section as the release's
# body and refuses to sign a release that has none, so every answer the reader
# gives is fired here on purpose: the section between two headings, the last
# section of the file, a missing version, an empty section, and the Unreleased
# lines above a version, which must never leak into it.
#
# Hermetic and offline: one mktemp changelog, nothing else read or written.
#
# Usage: changelog_section_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READER="$ROOT_DIR/scripts/changelog_section.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "changelog_section_test: $*" >&2
  exit 1
}

cat > "$WORK/CHANGELOG.md" <<'EOF'
# Changelog

The release notes, kept as the work lands.

## Unreleased

- Something not yet released.

## 0.3.0 (2026-09-30)

- Chat: one conversation shared with the phone.
- Browser: a built-in pane beside the chat.

## 0.2.2 (2026-09-26)

- Onboarding: the Login Items cards name the pane.
EOF

expected_middle="$(printf '%s\n%s' "- Chat: one conversation shared with the phone." "- Browser: a built-in pane beside the chat.")"
actual="$("$READER" 0.3.0 "$WORK/CHANGELOG.md")"
[ "$actual" = "$expected_middle" ] || fail "the 0.3.0 section is not its two lines: $actual"

actual="$("$READER" 0.2.2 "$WORK/CHANGELOG.md")"
[ "$actual" = "- Onboarding: the Login Items cards name the pane." ] || fail "the last section is not read to the end of the file: $actual"

case "$actual" in *"not yet released"*) fail "the Unreleased lines leaked into a version's section" ;; esac

if "$READER" 0.9.9 "$WORK/CHANGELOG.md" >/dev/null 2>"$WORK/missing.err"; then
  fail "a version with no section was answered"
fi
grep -q 'no section for 0.9.9' "$WORK/missing.err" || fail "a missing section is not named: $(cat "$WORK/missing.err")"

printf '## 0.4.0 (2026-10-01)\n\n\n## 0.3.0 (2026-09-30)\n\n- A line.\n' > "$WORK/empty.md"
if "$READER" 0.4.0 "$WORK/empty.md" >/dev/null 2>"$WORK/empty.err"; then
  fail "an empty section was answered"
fi
grep -q 'is empty' "$WORK/empty.err" || fail "an empty section is not named: $(cat "$WORK/empty.err")"

if "$READER" 0.3.0 "$WORK/absent.md" >/dev/null 2>"$WORK/absent.err"; then
  fail "a missing changelog was answered"
fi
grep -q 'no changelog' "$WORK/absent.err" || fail "a missing changelog is not named: $(cat "$WORK/absent.err")"

echo "changelog_section_test: ok"
