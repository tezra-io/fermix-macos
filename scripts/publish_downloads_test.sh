#!/usr/bin/env bash
#
# Harness for scripts/publish_downloads.sh.
#
# The publisher's refusals guard files that can never be taken back: once a
# version is on download.fermix.ai, the bucket's lock rule keeps it, and the
# feed, the cask and the site point people at it. So each refusal is fired here
# on purpose: a key that already holds other bytes, a host that serves something
# other than what was uploaded, a failed upload, and a missing credential.
#
# Hermetic and offline. The script is handed an `aws` and a `curl` that stand in
# for the bucket and the public host, backed by one folder inside a mktemp
# directory: the stand-in `aws` writes a key only when it holds nothing and
# answers PreconditionFailed otherwise, as R2 does for --if-none-match '*', and
# the stand-in `curl` serves what that folder holds. Every run gets a scrubbed
# environment, so no credential of the host's reaches the script.
#
# Usage: publish_downloads_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$ROOT_DIR/scripts/publish_downloads.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BIN="$WORK_DIR/bin"
BUCKET="$WORK_DIR/bucket"
CONTROL="$WORK_DIR/control"
AWS_LOG="$WORK_DIR/aws.log"
PREFIX="macos/v1.2.3"

fail() {
  echo "publish_downloads_test: $*" >&2
  exit 1
}

mkdir -p "$BIN" "$BUCKET" "$CONTROL"

# The bucket. put-object records its arguments and the credentials it was
# given, then writes the body under the key; asked to write once, it refuses a
# key that holds something.
cat >"$BIN/aws" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$AWS_LOG"
printf 'env %s %s %s\n' "\$AWS_ACCESS_KEY_ID" "\$AWS_SECRET_ACCESS_KEY" "\$AWS_DEFAULT_REGION" >>"$AWS_LOG"
if [ -e "$CONTROL/denied" ]; then
  echo "An error occurred (AccessDenied) when calling the PutObject operation: Access Denied" >&2
  exit 254
fi
key="" body="" once=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --key) key="\$2"; shift 2 ;;
    --body) body="\$2"; shift 2 ;;
    --if-none-match) once="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "\$once" = "*" ] && [ -e "$BUCKET/\$key" ]; then
  echo "An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold" >&2
  exit 254
fi
mkdir -p "\$(dirname "$BUCKET/\$key")"
cp "\$body" "$BUCKET/\$key"
echo '{"ETag": "\\"stand-in\\""}'
STUB

# The public host: the last argument is the url, served from the bucket folder,
# altered on the way or not served at all when a case asks for it.
cat >"$BIN/curl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
[ ! -e "$CONTROL/unserved" ] || exit 22
for url in "\$@"; do :; done
path="$BUCKET/\${url#https://download.fermix.ai/}"
[ "\$url" != "\${url#https://download.fermix.ai/}" ] && [ -f "\$path" ] || exit 22
cat "\$path"
[ ! -e "$CONTROL/altered" ] || printf 'altered'
STUB
chmod 0755 "$BIN/aws" "$BIN/curl"

CREDENTIALS=(R2_ACCESS_KEY_ID=key-id R2_SECRET_ACCESS_KEY=secret R2_ENDPOINT=https://account.r2.example.invalid)

# Runs the script with the stand-ins first on PATH and a throwaway HOME.
publish() {
  env -i PATH="$BIN:$PATH" HOME="$WORK_DIR" "$@"
}

expect_pass() {
  local what="$1"
  shift
  "$@" >"$WORK_DIR/out" 2>&1 || fail "expected to pass: $what: $(tail -3 "$WORK_DIR/out")"
  echo "  ok   $what"
}

expect_refusal() {
  local what="$1" expected="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected a refusal: $what"
  printf '%s' "$output" | grep -qF -- "$expected" ||
    fail "$what refused for the wrong reason: wanted '$expected', got: $(printf '%s' "$output" | tail -3)"
  echo "  ok   $what"
}

# Clears the bucket, the log and the switches between cases.
fresh() {
  rm -rf "$BUCKET" "$CONTROL" "$AWS_LOG"
  mkdir -p "$BUCKET" "$CONTROL"
}

# One release's files, as the release job has them.
FILES="$WORK_DIR/dist"
mkdir -p "$FILES"
printf 'disk image bytes' >"$FILES/Fermix-1.2.3.dmg"
printf 'abc  Fermix-1.2.3.dmg\n' >"$FILES/Fermix-1.2.3.dmg.sha256"
printf 'signature' >"$FILES/Fermix-1.2.3.dmg.sig"
printf -- '-----BEGIN CERTIFICATE-----\n' >"$FILES/Fermix-1.2.3.dmg.pem"
printf -- '- What changed.\n' >"$FILES/RELEASE_NOTES.md"
RELEASE=("$FILES/Fermix-1.2.3.dmg" "$FILES/Fermix-1.2.3.dmg.sha256" "$FILES/Fermix-1.2.3.dmg.sig"
  "$FILES/Fermix-1.2.3.dmg.pem" "$FILES/RELEASE_NOTES.md")

echo "publish_downloads_test: what is refused before anything is uploaded"

expect_refusal "no arguments" "usage:" publish "${CREDENTIALS[@]}" "$PUBLISH"
expect_refusal "a prefix and no file" "usage:" publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX"
expect_refusal "a prefix ending in a slash" "must name a folder" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX/" "${RELEASE[@]}"
for missing in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT; do
  given=()
  for credential in "${CREDENTIALS[@]}"; do
    [ "${credential%%=*}" = "$missing" ] || given+=("$credential")
  done
  expect_refusal "no $missing" "$missing is required" publish "${given[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"
done
fresh
expect_refusal "a file that is not there" "no file at $FILES/Fermix-1.2.4.dmg" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}" "$FILES/Fermix-1.2.4.dmg"
[ ! -e "$AWS_LOG" ] || fail "a missing file still let something upload"
touch "$FILES/notes.txt"
expect_refusal "a file with no content type" "no content type for $FILES/notes.txt" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}" "$FILES/notes.txt"
[ ! -e "$AWS_LOG" ] || fail "a file with no content type still let something upload"

echo "publish_downloads_test: a release's files"

fresh
expect_pass "every file is uploaded and read back" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"
for file in "${RELEASE[@]}"; do
  cmp -s "$file" "$BUCKET/$PREFIX/$(basename "$file")" || fail "$(basename "$file") is not in the bucket under $PREFIX"
  grep -qF "published https://download.fermix.ai/$PREFIX/$(basename "$file")" "$WORK_DIR/out" ||
    fail "$(basename "$file") was not reported as published"
done
grep -q -- "--key $PREFIX/Fermix-1.2.3.dmg .*--content-type application/x-apple-diskimage --cache-control public, max-age=31536000, immutable --if-none-match \* --endpoint-url https://account.r2.example.invalid --bucket fermix-downloads" "$AWS_LOG" ||
  fail "the disk image was not written once, with its type and cache lifetime, to fermix-downloads: $(head -1 "$AWS_LOG")"
grep -q -- "--key $PREFIX/Fermix-1.2.3.dmg.pem .*--content-type application/x-pem-file " "$AWS_LOG" || fail "the certificate's type"
grep -q -- "--key $PREFIX/Fermix-1.2.3.dmg.sig .*--content-type text/plain " "$AWS_LOG" || fail "the signature's type"
grep -q -- "--key $PREFIX/RELEASE_NOTES.md .*--content-type text/markdown; charset=utf-8 " "$AWS_LOG" || fail "the notes' type"
grep -qx "env key-id secret auto" "$AWS_LOG" || fail "the R2 credentials and region did not reach aws"
echo "  ok   with their types, the year-long cache lifetime and the R2 credentials"

expect_pass "a re-run of the same tag accepts the same bytes" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"
grep -qF "already published https://download.fermix.ai/$PREFIX/Fermix-1.2.3.dmg" "$WORK_DIR/out" ||
  fail "the re-run did not report the disk image as already published"

echo "publish_downloads_test: what is refused while publishing"

fresh
mkdir -p "$BUCKET/$PREFIX"
printf 'other bytes' >"$BUCKET/$PREFIX/Fermix-1.2.3.dmg"
expect_refusal "a key that already holds other bytes" "already holds other bytes" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"
[ "$(cat "$BUCKET/$PREFIX/Fermix-1.2.3.dmg")" = "other bytes" ] || fail "the published file was replaced"

fresh
touch "$CONTROL/altered"
expect_refusal "a host that serves other bytes than were uploaded" "serves sha256" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"

fresh
touch "$CONTROL/denied"
expect_refusal "an upload the bucket refuses" "could not upload $PREFIX/Fermix-1.2.3.dmg: An error occurred (AccessDenied)" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"

fresh
touch "$CONTROL/unserved"
expect_refusal "a file the host does not serve" "could not read https://download.fermix.ai/$PREFIX/Fermix-1.2.3.dmg back" \
  publish "${CREDENTIALS[@]}" "$PUBLISH" "$PREFIX" "${RELEASE[@]}"

echo "publish_downloads_test: ok"
