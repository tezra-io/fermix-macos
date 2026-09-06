#!/usr/bin/env python3
"""The facts verify_staged_app.sh's release gate asks of a staged bundle.

Read from the staged records rather than restated in the shell: the contract
provenance says which contracts the app speaks, whether any of them is a draft
and whether any was taken from an upstream working tree rather than from a
commit, and the engine manifest says which management protocol the engine beside
it serves. A number written into the gate instead would be a second source of
truth for something the checksum-pinned artifacts already carry.

Usage:
  contract_release_facts.py drafts <SOURCE.json>            names every draft
  contract_release_facts.py unpublished <SOURCE.json>       names every unpinnable one
  contract_release_facts.py speaks <SOURCE.json>            the protocol spoken
  contract_release_facts.py serves <manifest> <version>     ok, or no
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


def speaks(path):
    """The highest management protocol version the staged app is built against."""
    management = [
        entry for entry in contracts(path)
        if entry["vendored_directory"].startswith("management")
    ]
    if not management:
        raise SystemExit("no management contract is staged")

    return str(max(entry["protocol_version"] for entry in management))


def serves(path, version):
    """Whether the bundled engine's management window contains that version.

    The manifest publishes `minimum_version` / `maximum_version` /
    `current_version`, which is the same spelling `EngineManifest.swift` reads.
    A missing key raises rather than defaulting: a window this gate cannot read
    is a manifest it must not pass.
    """
    with open(path, encoding="utf-8") as handle:
        window = json.load(handle)["protocols"]["management"]

    return "ok" if window["minimum_version"] <= int(version) <= window["maximum_version"] else "no"


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)

    verb, path = argv[1], argv[2]
    if verb == "drafts":
        print(drafts(path))
    elif verb == "unpublished":
        print(unpublished(path))
    elif verb == "speaks":
        print(speaks(path))
    elif verb == "serves":
        if len(argv) < 4:
            raise SystemExit(__doc__)
        print(serves(path, argv[3]))
    else:
        raise SystemExit(f"unknown verb {verb}")


if __name__ == "__main__":
    main(sys.argv)
