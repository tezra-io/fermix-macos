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

# Sourcing from a non-bash shell would leave BASH_SOURCE unset and silently
# resolve the repository root one directory too high, so refuse instead.
if [ -z "${BASH_SOURCE[0]:-}" ]; then
  echo "product_config.sh: must be sourced from bash" >&2
  return 1 2>/dev/null || exit 1
fi

PRODUCT_CONFIG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_CONFIG_FILE="$PRODUCT_CONFIG_ROOT/Apps/Fermix/Sources/FermixAppCore/Resources/Product.json"
export PRODUCT_CONFIG_FILE

product_config() {
  local key="${1:?product_config: <key> is required}"
  local value

  if [ ! -f "$PRODUCT_CONFIG_FILE" ]; then
    echo "product_config: product configuration not found at $PRODUCT_CONFIG_FILE" >&2
    return 1
  fi

  if ! value="$(plutil -extract "$key" raw -o - "$PRODUCT_CONFIG_FILE" 2>/dev/null)"; then
    echo "product_config: key '$key' is absent from $PRODUCT_CONFIG_FILE" >&2
    return 1
  fi

  if [ -z "$value" ]; then
    echo "product_config: key '$key' is empty in $PRODUCT_CONFIG_FILE" >&2
    return 1
  fi

  printf '%s\n' "$value"
}
