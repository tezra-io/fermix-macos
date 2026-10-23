#!/usr/bin/env python3
"""The facts verify_staged_app.sh's release gate asks of a staged bundle.

Read from the staged records rather than restated in the shell: the contract
provenance says which contracts the app speaks, whether any of them is a draft
and whether any was taken from an upstream working tree rather than from a
commit, and the engine manifest says which protocols the engine beside it
serves. A number written into the gate instead would be a second source of
truth for something the checksum-pinned artifacts already carry.

Usage:
  contract_release_facts.py drafts <SOURCE.json>            names every draft
  contract_release_facts.py unpublished <SOURCE.json>       names every unpinnable one
  contract_release_facts.py serves <manifest> <SOURCE.json> ok, or what it does not serve
"""

import json
import sys


def contracts(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)["contracts"]


def drafts(path):
    """Every contract entry marked draft, by name. Empty where none is."""
    return " ".join(entry["name"] for entry in contracts(path) if entry.get("draft"))


def unpublished(path):
    """Every contract vendored from an upstream working tree, by name.

    `committed_upstream: false` says the bytes came from a tree with
    uncommitted changes, so the commit the record names does not carry them and
    nobody downstream can re-take the pin or prove what shipped. Absent means
    committed, which is what every record written before the field existed was.
    """
    return " ".join(
        entry["name"] for entry in contracts(path) if not entry.get("committed_upstream", True)
    )


def serves(manifest_path, record_path):
    """Whether the bundled engine serves every protocol the staged app speaks.

    Each contract the app speaks is held to the engine manifest's window of the
    same name, wherever the manifest publishes one: management, realtime,
    companion, browser_host and native_host, as present. The app declares its
    contract's `protocol_version` and a daemon whose window stops below it
    refuses the connection outright (Chat's hello is refused with
    client_too_new and never retried), so the version has to sit inside the
    window. Answers `ok`, or one sentence per contract it does not serve,
    naming the contract, the version, the app's window and the engine's.

    The manifest publishes `minimum_version` / `maximum_version` /
    `current_version`, which is the same spelling `EngineManifest.swift` reads.
    A missing key raises rather than defaulting: a window this gate cannot read
    is a manifest it must not pass. Draft entries are refused by `drafts`
    before this runs and are not held to a window here.
    """
    with open(manifest_path, encoding="utf-8") as handle:
        windows = json.load(handle)["protocols"]

    refusals = []
    for entry in contracts(record_path):
        name = entry["name"]
        if entry.get("draft") or name not in windows:
            continue

        window = windows[name]
        version = int(entry["protocol_version"])
        if window["minimum_version"] <= version <= window["maximum_version"]:
            continue

        spoken = entry["supported_version_range"]
        refusals.append(
            f"does not serve {name} protocol {version}: the app speaks "
            f"{spoken['minimum']} to {spoken['maximum']}, the engine "
            f"{window['minimum_version']} to {window['maximum_version']}"
        )

    return "; ".join(refusals) if refusals else "ok"


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)

    verb, path = argv[1], argv[2]
    if verb == "drafts":
        print(drafts(path))
    elif verb == "unpublished":
        print(unpublished(path))
    elif verb == "serves":
        if len(argv) < 4:
            raise SystemExit(__doc__)
        print(serves(path, argv[3]))
    else:
        raise SystemExit(f"unknown verb {verb}")


if __name__ == "__main__":
    main(sys.argv)
