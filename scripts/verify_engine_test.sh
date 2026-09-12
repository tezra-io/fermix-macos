#!/usr/bin/env bash
#
# Harness for scripts/verify_engine.sh.
#
# The engine verifier's refusals all fire on the same day: the day a release
# would otherwise ship an engine nobody pinned. Nothing exercises them by
# accident, and the real assets they judge do not exist until the engine is
# tagged, so they are fired here on purpose against fixtures.
#
# Hermetic and offline. Every archive, pin and certificate is built inside one
# mktemp directory, and the verifier is handed a stub cosign on a path inside
# that directory rather than a real one: the question this harness asks is
# whether the gate refuses what the pin does not vouch for, and a real signature
# would need the network and a release that does not exist yet. The stub records
# the arguments it was called with, so the happy path also proves the pinned
# identity and issuer actually reach the verifier instead of being dropped.
#
# Usage: verify_engine_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT_DIR/scripts/verify_engine.sh"
# The checked-in pin is one of the fixtures: it ships unpinned, which is exactly
# the state the last case needs, and reading it here proves the record the
# repository carries is one this reader understands.
REPOSITORY_PIN="$ROOT_DIR/engine/PIN.json"
# shellcheck source=scripts/engine_pin.sh
source "$ROOT_DIR/scripts/engine_pin.sh"

# The facts every fixture pin and fixture tree agree on. They are written once
# here so a case that wants a disagreement has to state it.
FIXTURE_TAG="v1.2.3"
FIXTURE_VERSION="1.2.3"
FIXTURE_COMMIT="1111111111111111111111111111111111111111"
OTHER_COMMIT="2222222222222222222222222222222222222222"
# The one directory the engine's packager roots every archive at.
ARCHIVE_ROOT="fermix_app_engine"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

COSIGN_LOG="$WORK_DIR/cosign.log"

fail() {
  echo "verify_engine_test: $*" >&2
  exit 1
}

expect_pass() {
  local what="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "expected to pass: $what"
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

# A stand-in cosign that answers with a fixed status and records every call.
# Written to a private path and handed over with --cosign, so whatever the host
# has installed can neither rescue nor break a case.
build_cosign_stub() {
  local path="$1" status="$2"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$COSIGN_LOG"
exit $status
STUB
  chmod 0755 "$path"
}

# One app-engine tarball, laid out the way the engine's packager lays it out:
# every member under a single fermix_app_engine/ root, the manifest at that
# root, and the release's shell-script launcher at bin/.
#
# The manifest carries the identity block the verifier reads. Architecture,
# commit and version are parameters because three cases exist only to make one
# of them disagree with the pin.
build_archive() {
  local archive="$1" architecture="$2" commit="$3" version="$4" root
  root="$(mktemp -d "$WORK_DIR/tree.XXXXXX")"
  mkdir -p "$root/$ARCHIVE_ROOT/bin"
  printf '#!/bin/sh\nexit 0\n' >"$root/$ARCHIVE_ROOT/bin/fermix_app_engine"
  chmod 0755 "$root/$ARCHIVE_ROOT/bin/fermix_app_engine"
  cat >"$root/$ARCHIVE_ROOT/engine-manifest.json" <<MANIFEST
{
  "schema_version": 1,
  "identity": {
    "engine_id": "fermix-core",
    "product_version": "$version",
    "build_id": "fixture",
    "source_commit": "$commit",
    "distribution_identity": "macos_app",
    "architecture": "$architecture"
  },
  "protocols": {
    "management": { "current_version": 2, "minimum_version": 1, "maximum_version": 2 },
    "realtime": { "current_version": 1, "minimum_version": 1, "maximum_version": 1 }
  }
}
MANIFEST
  tar -czf "$archive" -C "$root" "$ARCHIVE_ROOT"
  rm -rf "$root"
}

# A download directory holding both targets' assets and the three sidecars each
# one travels with. The .sha256 is written in the release's own format even
# though the verifier never reads it: the point of the sha256 case below is that
# the pin decides, and a sidecar that was never there would not prove that.
build_download_dir() {
  local dir="$1" arm_commit="${2:-$FIXTURE_COMMIT}" arm_architecture="${3:-arm64}"
  local asset
  mkdir -p "$dir"
  build_archive "$dir/fermix_app_engine_macos_aarch64.tar.gz" \
    "$arm_architecture" "$arm_commit" "$FIXTURE_VERSION"
  build_archive "$dir/fermix_app_engine_macos_x86_64.tar.gz" \
    x86_64 "$FIXTURE_COMMIT" "$FIXTURE_VERSION"
  for asset in fermix_app_engine_macos_aarch64.tar.gz fermix_app_engine_macos_x86_64.tar.gz; do
    printf '%s  %s\n' "$(digest_of "$dir/$asset")" "$asset" >"$dir/$asset.sha256"
    printf 'fixture signature\n' >"$dir/$asset.sig"
    printf 'fixture certificate\n' >"$dir/$asset.pem"
  done
}

digest_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# A pin that vouches for the assets in one download directory. The digests are
# read off the fixtures rather than written down, so the happy path cannot pass
# by coincidence; a case that wants a mismatch passes its own digest.
build_pin() {
  local pin="$1" dir="$2" commit="$3" arm_digest="${4:-}" x86_digest="${5:-}"
  [ -n "$arm_digest" ] || arm_digest="$(digest_of "$dir/fermix_app_engine_macos_aarch64.tar.gz")"
  [ -n "$x86_digest" ] || x86_digest="$(digest_of "$dir/fermix_app_engine_macos_x86_64.tar.gz")"
  cat >"$pin" <<PIN
{
  "schema_version": 1,
  "repository": "tezra-io/fermix",
  "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
  "tag": "$FIXTURE_TAG",
  "source_commit": "$commit",
  "certificate_identity": "https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/$FIXTURE_TAG",
  "targets": {
    "macos_aarch64": {
      "asset": "fermix_app_engine_macos_aarch64.tar.gz",
      "sha256": "$arm_digest"
    },
    "macos_x86_64": {
      "asset": "fermix_app_engine_macos_x86_64.tar.gz",
      "sha256": "$x86_digest"
    }
  },
  "note": "Fixture pin for scripts/verify_engine_test.sh."
}
PIN
}

COSIGN_OK="$WORK_DIR/bin/cosign"
COSIGN_REFUSING="$WORK_DIR/refusing-bin/cosign"
build_cosign_stub "$COSIGN_OK" 0
build_cosign_stub "$COSIGN_REFUSING" 1

echo "verify_engine_test: a pinned engine release"

DOWNLOAD="$WORK_DIR/download"
build_download_dir "$DOWNLOAD"
PIN="$WORK_DIR/pin.json"
build_pin "$PIN" "$DOWNLOAD" "$FIXTURE_COMMIT"

expect_pass "the pinned assets verify and extract into one tree per target" \
  "$VERIFY" "$PIN" "$DOWNLOAD" "$WORK_DIR/out/happy" --cosign "$COSIGN_OK"

for target in macos_aarch64 macos_x86_64; do
  [ -f "$WORK_DIR/out/happy/$target/engine-manifest.json" ] ||
    fail "the $target tree was not extracted to the root of its output directory"
  [ -x "$WORK_DIR/out/happy/$target/bin/fermix_app_engine" ] ||
    fail "the $target tree carries no executable bin/fermix_app_engine"
done
echo "  ok   each tree is extracted with the archive root stripped"

# The identity and issuer are the whole point of the signature check, and a
# verifier that called cosign without them would pass every case here.
grep -qF -- \
  "--certificate-identity https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/$FIXTURE_TAG" \
  "$COSIGN_LOG" ||
  fail "cosign was not given the pinned certificate identity"
grep -qF -- "--certificate-oidc-issuer https://token.actions.githubusercontent.com" "$COSIGN_LOG" ||
  fail "cosign was not given the pinned OIDC issuer"
echo "  ok   cosign is called with the pinned identity and issuer"

echo "verify_engine_test: refusals"

# The digest in the pin decides, not the digest in the sidecar the release
# wrote. The sidecar in this directory agrees with the asset, and the pin does
# not, which is exactly the shape of a re-cut release.
PIN_WRONG_DIGEST="$WORK_DIR/pin-wrong-digest.json"
build_pin "$PIN_WRONG_DIGEST" "$DOWNLOAD" "$FIXTURE_COMMIT" \
  "0000000000000000000000000000000000000000000000000000000000000000"
expect_refusal "an asset whose sha256 is not the pinned one is refused" \
  "and the engine pin records" \
  "$VERIFY" "$PIN_WRONG_DIGEST" "$DOWNLOAD" "$WORK_DIR/out/digest" --cosign "$COSIGN_OK"

expect_refusal "an asset cosign will not verify is refused" \
  "carries no signature from" \
  "$VERIFY" "$PIN" "$DOWNLOAD" "$WORK_DIR/out/signature" --cosign "$COSIGN_REFUSING"

# A tree built from a commit the pin does not name: the release was re-cut, or
# the pin was bumped without the tag being bumped with it.
DOWNLOAD_OTHER_COMMIT="$WORK_DIR/download-other-commit"
build_download_dir "$DOWNLOAD_OTHER_COMMIT" "$OTHER_COMMIT"
PIN_OTHER_COMMIT="$WORK_DIR/pin-other-commit.json"
build_pin "$PIN_OTHER_COMMIT" "$DOWNLOAD_OTHER_COMMIT" "$FIXTURE_COMMIT"
expect_refusal "a tree built from a commit the pin does not name is refused" \
  "and the engine pin names $FIXTURE_COMMIT" \
  "$VERIFY" "$PIN_OTHER_COMMIT" "$DOWNLOAD_OTHER_COMMIT" "$WORK_DIR/out/commit" \
  --cosign "$COSIGN_OK"

# The two trees are staged into architecture-named slots, so an asset whose tree
# is the other architecture would ship an x86_64 engine to Apple silicon.
DOWNLOAD_WRONG_ARCH="$WORK_DIR/download-wrong-arch"
build_download_dir "$DOWNLOAD_WRONG_ARCH" "$FIXTURE_COMMIT" x86_64
PIN_WRONG_ARCH="$WORK_DIR/pin-wrong-arch.json"
build_pin "$PIN_WRONG_ARCH" "$DOWNLOAD_WRONG_ARCH" "$FIXTURE_COMMIT"
expect_refusal "a tree whose architecture is not the target's is refused" \
  "and macos_aarch64 is arm64" \
  "$VERIFY" "$PIN_WRONG_ARCH" "$DOWNLOAD_WRONG_ARCH" "$WORK_DIR/out/arch" \
  --cosign "$COSIGN_OK"

# A release that published one target and not the other. Without this the
# missing half would surface as a staging error about a directory that is not
# there, four steps later.
DOWNLOAD_INCOMPLETE="$WORK_DIR/download-incomplete"
build_download_dir "$DOWNLOAD_INCOMPLETE"
PIN_INCOMPLETE="$WORK_DIR/pin-incomplete.json"
build_pin "$PIN_INCOMPLETE" "$DOWNLOAD_INCOMPLETE" "$FIXTURE_COMMIT"
rm "$DOWNLOAD_INCOMPLETE/fermix_app_engine_macos_x86_64.tar.gz"
expect_refusal "a pinned asset that is not in the download directory is refused" \
  "fermix_app_engine_macos_x86_64.tar.gz is not in" \
  "$VERIFY" "$PIN_INCOMPLETE" "$DOWNLOAD_INCOMPLETE" "$WORK_DIR/out/incomplete" \
  --cosign "$COSIGN_OK"

# An unpinned pin is the declared state before an engine release carries the
# assets; there is nothing to verify against and saying so is the only honest
# answer. The fixture is the harness's own, so this row keeps its meaning
# whichever state the repository's record is in.
cat >"$WORK_DIR/unpinned.json" <<'PIN'
{
  "schema_version": 1,
  "repository": "tezra-io/fermix",
  "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
  "tag": null,
  "source_commit": null,
  "certificate_identity": null,
  "targets": {
    "macos_aarch64": { "asset": null, "sha256": null },
    "macos_x86_64": { "asset": null, "sha256": null }
  },
  "note": "Fixture: the unpinned state."
}
PIN
expect_refusal "an unpinned pin is refused rather than skipped" \
  "is unpinned, so there is no engine release to verify against" \
  "$VERIFY" "$WORK_DIR/unpinned.json" "$DOWNLOAD" "$WORK_DIR/out/unpinned" --cosign "$COSIGN_OK"

# The repository's own record is read the way every caller reads it: it is
# whole, and it answers one of the two states rather than a refusal.
repository_state="$(engine_pin_state "$REPOSITORY_PIN")" ||
  fail "the repository's engine pin does not parse"
case "$repository_state" in
  pinned|unpinned) echo "  ok   the repository's engine pin parses as $repository_state" ;;
  *) fail "the repository's engine pin answered '$repository_state'" ;;
esac

echo "verify_engine_test: ok"
