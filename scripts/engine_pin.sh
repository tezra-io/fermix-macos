#!/usr/bin/env bash
#
# shellcheck disable=SC2034
# The constants in this file are read by the scripts that source it, which is
# the whole reason it exists; shellcheck cannot see across that boundary.
#
# The one owner of the engine pin: which engine release this app ships.
#
# engine/PIN.json is the record, and four scripts need the same answers from it
# without any of them holding a second copy: fetch_engine.sh downloads the
# pinned assets, verify_engine.sh proves what arrived is what was pinned,
# package_release.sh refuses to build a release without a pin, and the release
# audience of verify_staged_app.sh proves the engine inside a staged bundle is
# the pinned one. A value typed out four times is a value that rots the first
# time a pin is bumped.
#
# Usage:  source "$(dirname "$0")/engine_pin.sh"
#         engine_pin_state <pin.json>                    -> pinned | unpinned
#         engine_pin_field <pin.json> <field>            -> repository,
#                            certificate_oidc_issuer, tag, source_commit,
#                            certificate_identity, version
#         engine_pin_target_field <pin.json> <target> <asset|sha256>
#         engine_pin_architecture <target>               -> arm64 | x86_64
#
# Every reader refuses loudly rather than answering approximately: a pin that is
# neither fully filled nor fully empty, a tag that is not an engine release tag,
# a certificate identity that does not belong to the tag, a target nobody
# publishes. A half-filled pin is the dangerous state — it looks pinned to a
# glance and names an engine nothing can verify — so it is the one this file
# exists to stop.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "engine_pin.sh: must be sourced from bash" >&2
  exit 1
fi

# The two targets the engine's release workflow publishes app-engine trees for.
# Enumerated rather than globbed out of the pin so a pin that grew a third key
# fails the reader instead of silently shipping whatever it found.
ENGINE_PIN_TARGETS=(macos_aarch64 macos_x86_64)

# The pin every caller means unless it is handed another one. Only the harnesses
# hand over another: they need a filled pin to prove the gates fire, and the
# checked-in record ships unpinned.
ENGINE_PIN_DEFAULT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/engine/PIN.json"

# The engine release names its macOS targets after the toolchain triple and its
# manifests after the Mach-O architecture, so the two vocabularies have to be
# translated somewhere. Here, once, as an exact-match allowlist: the pin records
# release facts and nothing else, and a target nobody publishes is a refusal
# rather than a directory name that happens to have no tree in it.
engine_pin_architecture() {
  case "${1:?engine_pin_architecture: <target> is required}" in
    macos_aarch64) printf '%s\n' "arm64" ;;
    macos_x86_64) printf '%s\n' "x86_64" ;;
    *)
      echo "engine_pin: no app-engine target is published for '$1'" >&2
      return 1
      ;;
  esac
}

engine_pin_state() {
  engine_pin_read "${1:?engine_pin_state: <pin.json> is required}" state
}

engine_pin_field() {
  engine_pin_read "${1:?engine_pin_field: <pin.json> is required}" \
    "${2:?engine_pin_field: <field> is required}"
}

engine_pin_target_field() {
  engine_pin_read "${1:?engine_pin_target_field: <pin.json> is required}" \
    "target:${2:?engine_pin_target_field: <target> is required}:${3:?engine_pin_target_field: <field> is required}"
}

# The whole pin is validated on every read, not only on the first one.
#
# Reading one field at a time means each read is its own process, and a
# validator that ran only for `state` would let a caller that asks for a tag
# straight away walk past every consistency check. Validating each time costs a
# python start and makes every answer mean the same thing.
engine_pin_read() {
  python3 - "$1" "$2" <<'PY'
import json
import re
import sys

path, request = sys.argv[1], sys.argv[2]

TARGETS = ("macos_aarch64", "macos_x86_64")
TARGET_FIELDS = ("asset", "sha256")
ALWAYS_FILLED = ("repository", "certificate_oidc_issuer")
PINNED_ONLY = ("tag", "source_commit", "certificate_identity")
WORKFLOW = ".github/workflows/release.yml"


def refuse(sentence):
    sys.exit(f"engine_pin: {sentence}")


try:
    with open(path, encoding="utf-8") as handle:
        pin = json.load(handle)
except OSError as error:
    refuse(f"cannot read the engine pin at {path}: {error}")
except json.JSONDecodeError as error:
    refuse(f"the engine pin at {path} is not valid JSON: {error}")

if not isinstance(pin, dict):
    refuse(f"the engine pin at {path} is not a JSON object")
if pin.get("schema_version") != 1:
    refuse(
        f"the engine pin declares schema_version {pin.get('schema_version')!r}, "
        "and this reader understands 1"
    )
for field in ALWAYS_FILLED:
    if not isinstance(pin.get(field), str) or not pin[field]:
        refuse(f"the engine pin carries no {field}")
if not isinstance(pin.get("note"), str) or not pin["note"]:
    refuse("the engine pin carries no note saying how to fill it")

targets = pin.get("targets")
if not isinstance(targets, dict) or sorted(targets) != sorted(TARGETS):
    refuse("the engine pin must carry exactly the targets " + ", ".join(TARGETS))
for target in TARGETS:
    entry = targets[target]
    if not isinstance(entry, dict) or sorted(entry) != sorted(TARGET_FIELDS):
        refuse(f"target {target} must carry exactly " + " and ".join(TARGET_FIELDS))

# Pinned or unpinned, with nothing in between. A pin with a tag and no digest,
# or a digest for one architecture only, names an engine that cannot be verified
# while reading as a pin to anyone who glances at it.
filled = [field for field in PINNED_ONLY if pin[field] is not None]
filled += [
    f"{target}.{field}"
    for target in TARGETS
    for field in TARGET_FIELDS
    if targets[target][field] is not None
]
complete = list(PINNED_ONLY) + [
    f"{target}.{field}" for target in TARGETS for field in TARGET_FIELDS
]
if filled and sorted(filled) != sorted(complete):
    missing = ", ".join(field for field in complete if field not in filled)
    refuse(
        f"the engine pin is half filled: {missing} must be filled in too, "
        "or every pinned field must be null"
    )

pinned = bool(filled)

if pinned:
    tag = pin["tag"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        refuse(f"the engine pin's tag '{tag}' is not an engine release tag (vX.Y.Z)")
    commit = pin["source_commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        refuse(f"the engine pin's source_commit '{commit}' is not a 40-character commit")
    identity = f"https://github.com/{pin['repository']}/{WORKFLOW}@refs/tags/{tag}"
    if pin["certificate_identity"] != identity:
        refuse(
            f"the engine pin's certificate_identity is '{pin['certificate_identity']}', "
            f"and {tag} in {pin['repository']} signs as '{identity}'"
        )
    for target in TARGETS:
        asset = f"fermix_app_engine_{target}.tar.gz"
        if targets[target]["asset"] != asset:
            refuse(
                f"target {target} names asset '{targets[target]['asset']}', "
                f"and the engine release publishes '{asset}'"
            )
        digest = targets[target]["sha256"]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            refuse(f"target {target}'s sha256 '{digest}' is not a 64-character digest")

if request == "state":
    print("pinned" if pinned else "unpinned")
    sys.exit(0)
if request in ALWAYS_FILLED:
    print(pin[request])
    sys.exit(0)
if not pinned:
    refuse(f"the engine pin is unpinned, so it names no {request}")
if request == "version":
    # The product version an engine tree declares is the tag without its v, so
    # the tag is the only thing written down.
    print(pin["tag"][1:])
    sys.exit(0)
if request in PINNED_ONLY:
    print(pin[request])
    sys.exit(0)
if request.startswith("target:"):
    parts = request.split(":")
    if len(parts) != 3 or parts[1] not in TARGETS or parts[2] not in TARGET_FIELDS:
        refuse(f"'{request}' is not a target field this pin carries")
    print(targets[parts[1]][parts[2]])
    sys.exit(0)
refuse(f"'{request}' is not a field of the engine pin")
PY
}
