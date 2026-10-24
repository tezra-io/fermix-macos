#!/usr/bin/env bash
#
# Publishes a release's files to download.fermix.ai, the host every public
# download comes from: the update feed's enclosures, the Homebrew cask and the
# site's links all point there, so they keep working once the repository is
# private.
#
# Each file goes to the R2 bucket behind the host as <prefix>/<file name>, and
# is written once: the upload only lands on a key that holds nothing, and the
# bucket's lock rule keeps a published version's files for good. A key that
# already holds the same bytes is a re-run of the same tag and is accepted; a
# key that holds other bytes refuses, because a published file never changes
# under the people who already downloaded it. Every file is then read back
# through the public host and its sha256 compared, so the release only goes on
# with bytes a user would actually receive.
#
# The credentials are the release environment's R2_ACCESS_KEY_ID,
# R2_SECRET_ACCESS_KEY and R2_ENDPOINT (the account's S3 endpoint).
#
# Usage: publish_downloads.sh <prefix> <file>...
set -euo pipefail

BUCKET="fermix-downloads"
PUBLIC_BASE="https://download.fermix.ai"
# A published file never changes, so any cache may keep it for a year.
CACHE_CONTROL="public, max-age=31536000, immutable"

fail() {
  echo "publish_downloads: $*" >&2
  exit 1
}

[ "$#" -ge 2 ] || fail "usage: publish_downloads.sh <prefix> <file>..."
PREFIX="$1"
shift
case "$PREFIX" in
  "" | /* | */) fail "the prefix '$PREFIX' must name a folder, such as macos/v1.2.3" ;;
esac

for name in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT; do
  [ -n "${!name:-}" ] || fail "$name is required"
done

# The types the earlier releases' files were uploaded with, so every version
# is served the same way.
content_type() {
  case "$1" in
    *.dmg) echo "application/x-apple-diskimage" ;;
    *.pem) echo "application/x-pem-file" ;;
    *.sha256 | *.sig) echo "text/plain" ;;
    *.md) echo "text/markdown; charset=utf-8" ;;
    *) return 1 ;;
  esac
}

# Every file is checked before the first upload, so a release never publishes
# half of its files.
for file in "$@"; do
  [ -f "$file" ] || fail "no file at $file"
  content_type "$file" >/dev/null || fail "no content type for $file"
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# R2 speaks the S3 API in the region "auto". The CLI adds checksums only where
# an operation requires one, the settings the bucket was proven with.
s3() {
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws s3api "$@" --endpoint-url "$R2_ENDPOINT" --bucket "$BUCKET"
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# The retries cover the moment between the upload and the host serving it.
public_sha256() {
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "$PUBLIC_BASE/$1" | shasum -a 256 | awk '{print $1}'
}

publish() {
  local file="$1" key state want got
  key="$PREFIX/$(basename "$file")"
  if s3 put-object --key "$key" --body "$file" --content-type "$(content_type "$file")" \
    --cache-control "$CACHE_CONTROL" --if-none-match '*' >/dev/null 2>"$WORK_DIR/put.err"; then
    state="published"
  elif grep -qF "(PreconditionFailed)" "$WORK_DIR/put.err"; then
    state="already published"
  else
    fail "could not upload $key: $(tail -1 "$WORK_DIR/put.err")"
  fi

  want="$(sha256_of "$file")"
  got="$(public_sha256 "$key")" || fail "could not read $PUBLIC_BASE/$key back"
  if [ "$got" != "$want" ]; then
    [ "$state" = "published" ] && fail "$PUBLIC_BASE/$key serves sha256 $got, not the uploaded $want"
    fail "$key already holds other bytes (sha256 $got), not $file's $want; a published file is never replaced"
  fi
  echo "$state $PUBLIC_BASE/$key"
}

for file in "$@"; do
  publish "$file"
done
