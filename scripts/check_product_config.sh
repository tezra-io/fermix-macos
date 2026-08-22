#!/usr/bin/env bash
#
# Gate: nothing restates a value Product.json already owns.
#
# Product.json is the single source of truth. Four places cannot read it at the
# moment they need it, so each one is checked here against the configuration
# rather than trusted:
#
#   1. Apps/Fermix/Sources/Fermix/Info.plist — linked into the GUI binary at
#      link time, so it must exist on disk before the build. It is regenerated
#      here and compared byte for byte.
#   2. Apps/Fermix/Package.swift — SwiftPM caches a manifest by its own
#      contents, so a manifest that read Product.json would be served a stale
#      platform floor (measured: editing only Product.json left
#      `swift package dump-package` reporting the previous version).
#   3. Apps/Fermix/project.yml — XcodeGen substitutes an undefined ${VAR} with
#      an empty string instead of failing, so the values are written literally
#      and checked here.
#   4. The legacy FermixPet release path — notarize.yml, release-fermixpet.yml,
#      and Casks/fermixpet.rb.tmpl. Those three name the released artifact
#      literally, in shell globs and in a cask stanza, and they run only on a
#      release tag. Ungated, renaming the app bundle would break the release
#      channel at the one moment nobody can afford it, so the artifact name
#      package_release.sh derives from `app_bundle_name` is required to appear
#      in each of them. Apps/Fermix/script/build_and_run_test.sh asserts the
#      same values but is a test, so it fails on its own in CI.
#
# Every expected string below is derived from Product.json, not typed twice.
#
# Usage: check_product_config.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/Apps/Fermix"
PLIST="$APP_DIR/Sources/Fermix/Info.plist"
MANIFEST="$APP_DIR/Package.swift"
PROJECT_SPEC="$APP_DIR/project.yml"
NOTARIZE_WORKFLOW="$ROOT_DIR/.github/workflows/notarize.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release-fermixpet.yml"
CASK_TEMPLATE="$ROOT_DIR/Casks/fermixpet.rb.tmpl"

# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "check_product_config: $*" >&2
  exit 1
}

require_literal() {
  local file="$1" expected="$2" what="$3"
  grep -F -q -- "$expected" "$file" ||
    fail "$(basename "$file") does not carry $what from Product.json: expected '$expected'"
}

check_linked_info_plist() {
  [ -f "$PLIST" ] || fail "linked Info.plist is missing at $PLIST"
  "$ROOT_DIR/scripts/render_info_plist.sh" \
    "$(product_config marketing_version)" \
    "$(product_config build_number)" \
    "$TMP_DIR/Info.plist"
  diff -u "$TMP_DIR/Info.plist" "$PLIST" ||
    fail "linked Info.plist is stale; regenerate it with scripts/render_info_plist.sh"
}

check_manifest_platform() {
  local min_version major
  min_version="$(product_config minimum_system_version)"
  major="${min_version%%.*}"
  require_literal "$MANIFEST" "platforms: [.macOS(.v$major)]" "the macOS deployment floor"
}

check_project_spec() {
  [ -f "$PROJECT_SPEC" ] || fail "XcodeGen spec is missing at $PROJECT_SPEC"
  require_literal "$PROJECT_SPEC" "macOS: \"$(product_config minimum_system_version)\"" \
    "the macOS deployment floor"
  require_literal "$PROJECT_SPEC" "PRODUCT_BUNDLE_IDENTIFIER: $(product_config bundle_identifier)" \
    "the bundle identifier"
  require_literal "$PROJECT_SPEC" "MARKETING_VERSION: \"$(product_config marketing_version)\"" \
    "the marketing version"
  require_literal "$PROJECT_SPEC" "CURRENT_PROJECT_VERSION: \"$(product_config build_number)\"" \
    "the build number"
  require_literal "$PROJECT_SPEC" "name: $(product_config product_name)" "the product name"
}

# The artifact name package_release.sh writes is the bundle name without its
# .app suffix, so both forms are checked wherever the release path names one.
check_legacy_release_path() {
  local bundle artifact
  bundle="$(product_config app_bundle_name)"
  artifact="${bundle%.app}"

  for workflow in "$NOTARIZE_WORKFLOW" "$RELEASE_WORKFLOW"; do
    [ -f "$workflow" ] || fail "release workflow is missing at $workflow"
    require_literal "$workflow" "dist/$artifact-*.dmg" "the released DMG name"
    require_literal "$workflow" "/$bundle" "the released bundle name"
  done

  [ -f "$CASK_TEMPLATE" ] || fail "cask template is missing at $CASK_TEMPLATE"
  require_literal "$CASK_TEMPLATE" "$artifact-#{version}.dmg" "the released DMG name"
  require_literal "$CASK_TEMPLATE" "app \"$bundle\"" "the released bundle name"
  require_literal "$CASK_TEMPLATE" "$(product_config bundle_identifier)" "the bundle identifier"
}

check_linked_info_plist
check_manifest_platform
check_project_spec
check_legacy_release_path
echo "check_product_config: ok"
