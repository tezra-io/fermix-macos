#!/usr/bin/env bash
#
# Prove that the downloaded engine assets are the engine the pin names, then
# extract them into release trees the staging script can consume.
#
# This is the gate between "a tarball with the right file name arrived" and
# "this is the engine we decided to ship". Four things have to agree before an
# asset becomes a tree, and each disagreement is its own sentence:
#
#   1. the file's sha256 is the digest engine/PIN.json records. The .sha256
#      sidecar beside the asset is NOT what is checked: it is written by the
#      same release that wrote the asset, so a re-cut or replaced release
#      carries a sidecar that agrees with itself and with nothing we decided.
#      The pin is the only authority here.
#   2. cosign verifies the detached signature against the pinned certificate
#      identity and OIDC issuer, so the asset provably came out of the engine
#      repository's release workflow at that tag.
#   3. the tree inside carries the pinned source commit and the tag's product
#      version, which is what makes the DMG traceable to an engine commit.
#   4. the tree's architecture is the one the target promises, because the two
#      trees are staged into architecture-named slots and a swap would ship an
#      x86_64 engine to Apple silicon.
#
# No network, no token, no `gh`: everything it needs is the pin and the files
# scripts/fetch_engine.sh already put on disk. That is what makes every refusal
# above provable offline in scripts/verify_engine_test.sh.
#
# Usage: verify_engine.sh <pin.json> <download-dir> <out-dir> [--cosign <binary>]
#   <out-dir>   one extracted release tree per target, at <out-dir>/<target>,
#               each one a `--engine` argument for scripts/stage_app.sh
#   --cosign    the verifier to use. Defaults to cosign on PATH; the release
#               bundle stages one into its own Tools slot, and stage_app.sh
#               takes the same flag, so a caller that has a binary rather than
#               an installation points at it here.
set -euo pipefail

USAGE="usage: verify_engine.sh <pin.json> <download-dir> <out-dir> [--cosign <binary>]"

PIN="${1:?$USAGE}"
DOWNLOAD_DIR="${2:?$USAGE}"
OUT_DIR="${3:?$USAGE}"
shift 3

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/engine_pin.sh
source "$ROOT_DIR/scripts/engine_pin.sh"

# The single directory every app-engine tarball is rooted at, written by the
# engine's own packager (scripts/release/package_app_engine.py). It is the
# allowlist for the archive's contents: a member outside it would be extracted
# somewhere nobody asked for.
ARCHIVE_ROOT="fermix_app_engine"

COSIGN_BIN=""

fail() {
  echo "verify_engine: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cosign)
      COSIGN_BIN="${2:?--cosign needs a binary path}"
      shift 2
      ;;
    *) fail "unknown argument '$1' ($USAGE)" ;;
  esac
done

resolve_cosign() {
  if [ -n "$COSIGN_BIN" ]; then
    [ -x "$COSIGN_BIN" ] || fail "the cosign binary is not executable: $COSIGN_BIN"
    return 0
  fi
  COSIGN_BIN="$(command -v cosign)" ||
    fail "cosign is not on PATH, so a pinned asset's signature cannot be checked; pass --cosign <binary>"
}

# One field of the identity block of one manifest.
#
# The same two-line read as the one in stage_app.sh and verify_staged_app.sh.
# Each script owns its own deliberately: the value is one field of one file, and
# a shared helper for it would be more indirection than the read it replaces.
engine_manifest_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["identity"][sys.argv[2]])
except Exception:
    sys.exit(1)
PY
}

verify_target() {
  local target="$1"
  local asset archive expected actual escapees tree manifest
  local tree_commit tree_version tree_architecture architecture

  asset="$(engine_pin_target_field "$PIN" "$target" asset)"
  archive="$DOWNLOAD_DIR/$asset"
  [ -f "$archive" ] || fail "the pinned asset $asset is not in $DOWNLOAD_DIR"
  [ -f "$archive.sig" ] || fail "the pinned asset $asset has no $asset.sig beside it"
  [ -f "$archive.pem" ] || fail "the pinned asset $asset has no $asset.pem beside it"

  expected="$(engine_pin_target_field "$PIN" "$target" sha256)"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [ "$actual" = "$expected" ] ||
    fail "$asset hashes to $actual, and the engine pin records $expected"

  "$COSIGN_BIN" verify-blob \
    --certificate "$archive.pem" \
    --signature "$archive.sig" \
    --certificate-identity "$IDENTITY" \
    --certificate-oidc-issuer "$ISSUER" \
    "$archive" ||
    fail "$asset carries no signature from $IDENTITY issued by $ISSUER"

  # Counted before extracting, not repaired afterwards: a member outside the
  # archive's own root is extracted somewhere this script never chose.
  escapees="$(tar -tzf "$archive" |
    grep -c -v -e "^$ARCHIVE_ROOT\$" -e "^$ARCHIVE_ROOT/" || true)"
  [ "$escapees" -eq 0 ] ||
    fail "$asset carries $escapees entries outside its $ARCHIVE_ROOT/ root"

  tree="$OUT_DIR/$target"
  [ ! -e "$tree" ] || fail "the output directory already carries a $target tree: $tree"
  mkdir -p "$tree"
  tar -xzf "$archive" -C "$tree" --strip-components=1 ||
    fail "$asset does not extract"

  manifest="$tree/engine-manifest.json"
  [ -f "$manifest" ] || fail "$asset extracts to a tree with no engine-manifest.json"

  tree_commit="$(engine_manifest_field "$manifest" source_commit)" ||
    fail "the tree in $asset declares no source commit"
  [ "$tree_commit" = "$COMMIT" ] ||
    fail "the tree in $asset was built from commit $tree_commit, and the engine pin names $COMMIT"

  tree_version="$(engine_manifest_field "$manifest" product_version)" ||
    fail "the tree in $asset declares no product version"
  [ "$tree_version" = "$VERSION" ] ||
    fail "the tree in $asset is product version $tree_version, and the engine pin names tag $TAG"

  architecture="$(engine_pin_architecture "$target")" || exit 1
  tree_architecture="$(engine_manifest_field "$manifest" architecture)" ||
    fail "the tree in $asset declares no architecture"
  [ "$tree_architecture" = "$architecture" ] ||
    fail "the tree in $asset declares architecture $tree_architecture, and $target is $architecture"

  echo "verify_engine: $target verified from $asset ($architecture, $TAG, ${COMMIT:0:12}) -> $tree"
}

STATE="$(engine_pin_state "$PIN")" || exit 1
[ "$STATE" = "pinned" ] ||
  fail "$PIN is unpinned, so there is no engine release to verify against"

TAG="$(engine_pin_field "$PIN" tag)"
VERSION="$(engine_pin_field "$PIN" version)"
COMMIT="$(engine_pin_field "$PIN" source_commit)"
IDENTITY="$(engine_pin_field "$PIN" certificate_identity)"
ISSUER="$(engine_pin_field "$PIN" certificate_oidc_issuer)"

resolve_cosign
mkdir -p "$OUT_DIR"

for target in "${ENGINE_PIN_TARGETS[@]}"; do
  verify_target "$target"
done

echo "verify_engine: ok"
