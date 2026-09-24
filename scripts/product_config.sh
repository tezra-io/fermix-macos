#!/usr/bin/env bash
#
# Reader for the one checked-in product configuration.
#
# Product.json is the single source of truth for product identity, bundle
# layout, versions, and the helper label. Swift reads it through
# FermixAppCore.ProductConfiguration; every shell script reads it through here.
# Nothing restates a value it can read from this file.
#
# Usage:  source "$(dirname "$0")/product_config.sh"
#         name="$(product_config product_name)"
#
# Every lookup is fail-loud: a missing file, an unknown key, or an empty value
# is an error, never a default.
#
# PRODUCT_CONFIG_OVERLAY names a second document whose keys win.
#
# It exists for one case: the development bundle the dev loop stages has to be
# a DIFFERENT APP to macOS than the installed one. launchd keys the background
# agent on its label, LaunchServices and TCC key their records on the bundle
# identifier, and there is one bootstrap record per support folder — two bundles
# cannot share any of them. The overlay carries only the keys that differ
# (scripts/product.dev.json), so every script that reads a value through this
# reader sees the development identity with no per-script branch, and the
# release path is the same code with no overlay set. Export it: the staging,
# plist-rendering, signing and verification scripts are separate processes.
#
# The merge is one step at source time and every read then has one code path.
# An overlay key the base configuration does not declare is refused rather than
# added: a typo would otherwise override nothing and stage the production
# identity under a development name.

# Sourcing from a non-bash shell would leave BASH_SOURCE unset and silently
# resolve the repository root one directory too high, so refuse instead.
if [ -z "${BASH_SOURCE[0]:-}" ]; then
  echo "product_config.sh: must be sourced from bash" >&2
  return 1 2>/dev/null || exit 1
fi

PRODUCT_CONFIG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_CONFIG_FILE="$PRODUCT_CONFIG_ROOT/Apps/Fermix/Sources/FermixAppCore/Resources/Product.json"
PRODUCT_CONFIG_OVERLAY="${PRODUCT_CONFIG_OVERLAY:-}"
export PRODUCT_CONFIG_FILE

# The base document with the overlay's keys applied, printed once so every
# lookup reads the same bytes. Fails loudly on an unreadable document, an
# overlay that is not a JSON object, or an overlay key nothing declares.
product_config_merge() {
  python3 - "$PRODUCT_CONFIG_FILE" "$PRODUCT_CONFIG_OVERLAY" <<'MERGE'
import json
import sys

base_path, overlay_path = sys.argv[1], sys.argv[2]

try:
    with open(base_path, encoding="utf-8") as source:
        document = json.load(source)
except (OSError, ValueError) as error:
    sys.exit(f"product_config: {base_path} is not a readable product configuration: {error}")
if not isinstance(document, dict):
    sys.exit(f"product_config: {base_path} is not a JSON object")

if overlay_path:
    try:
        with open(overlay_path, encoding="utf-8") as source:
            overlay = json.load(source)
    except (OSError, ValueError) as error:
        sys.exit(f"product_config: {overlay_path} is not a readable overlay: {error}")
    if not isinstance(overlay, dict):
        sys.exit(f"product_config: {overlay_path} is not a JSON object")
    undeclared = sorted(set(overlay) - set(document))
    if undeclared:
        sys.exit(
            f"product_config: {overlay_path} declares keys the product configuration does not: "
            + ", ".join(undeclared)
        )
    document.update(overlay)

json.dump(document, sys.stdout, indent=2, sort_keys=False)
sys.stdout.write("\n")
MERGE
}

if [ ! -f "$PRODUCT_CONFIG_FILE" ]; then
  echo "product_config: product configuration not found at $PRODUCT_CONFIG_FILE" >&2
  return 1 2>/dev/null || exit 1
fi

if [ -n "$PRODUCT_CONFIG_OVERLAY" ]; then
  case "$PRODUCT_CONFIG_OVERLAY" in
    /*) ;;
    *)
      echo "product_config: PRODUCT_CONFIG_OVERLAY must be an absolute path, not '$PRODUCT_CONFIG_OVERLAY'" >&2
      return 1 2>/dev/null || exit 1
      ;;
  esac
  if [ ! -f "$PRODUCT_CONFIG_OVERLAY" ]; then
    echo "product_config: overlay not found at $PRODUCT_CONFIG_OVERLAY" >&2
    return 1 2>/dev/null || exit 1
  fi
  PRODUCT_CONFIG_SOURCE="$PRODUCT_CONFIG_FILE overlaid by $PRODUCT_CONFIG_OVERLAY"
else
  PRODUCT_CONFIG_SOURCE="$PRODUCT_CONFIG_FILE"
fi

# The configuration this process reads, as JSON. It is also what stage_app.sh
# writes into the staged bundle, so the app reads at runtime exactly the
# document these scripts staged it from.
if ! PRODUCT_CONFIG_DOCUMENT="$(product_config_merge)"; then
  return 1 2>/dev/null || exit 1
fi

product_config() {
  local key="${1:?product_config: <key> is required}"
  local value

  if ! value="$(plutil -extract "$key" raw -o - - <<<"$PRODUCT_CONFIG_DOCUMENT" 2>/dev/null)"; then
    echo "product_config: key '$key' is absent from $PRODUCT_CONFIG_SOURCE" >&2
    return 1
  fi

  if [ -z "$value" ]; then
    echo "product_config: key '$key' is empty in $PRODUCT_CONFIG_SOURCE" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

# Where a staged resource bundle keeps its files.
#
# SwiftPM emits the FLAT form for a single-architecture build and the
# STRUCTURED form (Contents/Resources) for the universal xcbuild one, so the
# question is asked of the bundle rather than assumed from the build mode.
# stage_app.sh writes the staged product configuration through this and
# verify_staged_app.sh reads the staged resources through it; a second copy of
# the answer would drift the day a build system changes.
product_config_resource_root() {
  local bundle="${1:?product_config_resource_root: <resource-bundle-path> is required}"

  if [ -d "$bundle/Contents/Resources" ]; then
    printf '%s\n' "$bundle/Contents/Resources"
    return 0
  fi

  printf '%s\n' "$bundle"
}
