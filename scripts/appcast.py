#!/usr/bin/env python3
"""The Sparkle appcast for the Fermix macOS app: one item, then the cumulative feed.

Two subcommands, because the two halves run in different jobs with different
access. `item` runs inside the notarize job, the only job that may read the
ed25519 private key and the only one holding the stapled disk image together
with the app it carries. `merge` runs in the publish job, which has the previous
release's feed, a token, and no environment secrets at all. Neither subcommand
restates anything the other knows.

Every fact has exactly one owner and none of them is typed in by hand: the
marketing version, the build number and the system floor come from the app's own
Info.plist, the engine build from the engine trees' own manifests, the signing
identity from codesign, the digest from the disk image bytes, and the signature
and byte length from sign_update. A release that cannot answer one of them is
refused here rather than published as a guess, because the app refuses a feed
entry that omits any of the four Fermix elements and there is no way to correct
a feed a client has already read.

The private key arrives on standard input and is passed straight into
sign_update's standard input. It is never a command-line argument (every process
on the machine can read those), never an environment variable this script reads,
never written to disk, and never printed, not even inside a refusal.

Usage:
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | appcast.py item \\
      --dmg dist/FermixPet-0.1.0.dmg --app /Volumes/x/FermixPet.app \\
      --tag fermixpet-v0.1.0 --sign-update <path>/bin/sign_update \\
      --out appcast-item.xml
  appcast.py merge --item appcast-item.xml [--previous appcast.xml] \\
      --out appcast.xml
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple, Optional, Sequence
from urllib.parse import quote, urlsplit

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

# Ours, and deliberately not Sparkle's. Sparkle rewrites the prefix of a node in
# its own namespace to the literal `sparkle:` and keys every other node by the
# qualified name the feed wrote (-[SUAppcast sparkleNamespacedNameOfNode:]), and
# FermixSparkle looks the four elements up as `fermix:<name>` in
# SUAppcastItem.propertiesDictionary. So the prefix has to be exactly `fermix`
# and the namespace has to be one Sparkle does not own: publishing these
# elements in Sparkle's namespace would key them as `sparkle:engineBuildId` and
# the app would refuse every entry in the feed.
FERMIX_NAMESPACE = "https://fermix.ai/xml-namespaces/appcast"

# The channel is fixed: the feed describes one product at one address, and a
# release that could change either would be describing something else.
CHANNEL_TITLE = "Fermix"
CHANNEL_LINK = "https://fermix.ai"
CHANNEL_DESCRIPTION = "Updates for the Fermix macOS app."

# Where a release asset lives. An argument rather than a constant because it is
# the one fact about the enclosure that a caller can get wrong, and the https
# refusal below has to be reachable.
DEFAULT_RELEASE_BASE = "https://github.com/tezra-io/fermix-macos/releases/download"

ENCLOSURE_TYPE = "application/octet-stream"

# The engine's own name for its metadata, which is the only layout fact needed
# to find the trees. Asking for the manifest by name rather than walking to
# Product.json's engine slot keeps this script out of the bundle-layout
# business: a slot that moves, or a third architecture, changes nothing here.
ENGINE_MANIFEST_NAME = "engine-manifest.json"

# codesign prints the leaf certificate first, which is the Developer ID
# Application identity the bundle was signed with.
AUTHORITY_PREFIX = "Authority="

# What Sparkle can order releases by, and the only shape the app accepts.
BUILD_NUMBER = re.compile(r"[1-9][0-9]*")

SIGNATURE_ATTRIBUTE = re.compile(r'sparkle:edSignature="([^"]+)"')
LENGTH_ATTRIBUTE = re.compile(r'(?:^|\s)length="([0-9]+)"')


class Refusal(Exception):
    """One published-release defect, in one sentence an operator can act on."""


class AppFacts(NamedTuple):
    marketing_version: str
    build_number: str
    minimum_system_version: str


class EngineFacts(NamedTuple):
    build_id: str
    product_version: str


def sparkle(name: str) -> str:
    return f"{{{SPARKLE_NAMESPACE}}}{name}"


def fermix(name: str) -> str:
    return f"{{{FERMIX_NAMESPACE}}}{name}"


# MARK: - Reading the release


def read_app_facts(app: Path) -> AppFacts:
    """The three version facts, from the bundle that is being published."""
    plist = app / "Contents" / "Info.plist"
    if not plist.is_file():
        raise Refusal(f"the app at {app} carries no Contents/Info.plist")

    with plist.open("rb") as source:
        document = plistlib.load(source)

    marketing = str(document.get("CFBundleShortVersionString", "")).strip()
    build = str(document.get("CFBundleVersion", "")).strip()
    minimum = str(document.get("LSMinimumSystemVersion", "")).strip()

    if not marketing:
        raise Refusal(f"{plist} carries no CFBundleShortVersionString, so the release has no version to show")
    if not BUILD_NUMBER.fullmatch(build):
        raise Refusal(
            f"the build number '{build}' in {plist} is not a plain positive integer, "
            "which is the only thing Sparkle and the app order releases by"
        )
    if not minimum:
        raise Refusal(
            f"{plist} carries no LSMinimumSystemVersion, so the feed cannot say "
            "which Macs may take this update"
        )

    return AppFacts(marketing, build, minimum)


def read_engine_facts(app: Path) -> EngineFacts:
    """The one engine build the bundle carries, proved by every tree in it.

    Both architectures ship the same engine release, and the launch reconcile
    compares the arriving bundle against the build named here, so two trees that
    disagree mean the feed would name an engine half the users do not have.
    """
    manifests = sorted(app.rglob(ENGINE_MANIFEST_NAME))
    if not manifests:
        raise Refusal(f"the app at {app} carries no {ENGINE_MANIFEST_NAME}, so it has no engine to name")

    found = [(path, engine_identity(path)) for path in manifests]
    first_path, expected = found[0]
    for path, facts in found[1:]:
        if facts != expected:
            raise Refusal(
                f"the engine trees disagree: {first_path} declares build {expected.build_id} "
                f"of {expected.product_version} and {path} declares build {facts.build_id} "
                f"of {facts.product_version}"
            )

    return expected


def engine_identity(manifest: Path) -> EngineFacts:
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as failure:
        raise Refusal(f"the engine manifest at {manifest} cannot be read as json: {failure}") from failure

    identity = document.get("identity")
    if not isinstance(identity, dict):
        raise Refusal(f"the engine manifest at {manifest} carries no identity block")

    build_id = str(identity.get("build_id", "")).strip()
    product_version = str(identity.get("product_version", "")).strip()
    if not build_id or not product_version:
        raise Refusal(f"the engine manifest at {manifest} names no build_id and product_version pair")

    return EngineFacts(build_id, product_version)


def read_signing_identity(app: Path) -> str:
    """The Developer ID authority the bundle is actually signed with.

    Read from the signature rather than configured, so the feed cannot vouch for
    an identity the artifact does not carry. codesign is invoked by name so a
    harness can answer with a stub on PATH: a test bundle is not Developer ID
    signed and never will be.
    """
    try:
        result = subprocess.run(
            ["codesign", "-dvv", str(app)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as failure:
        raise Refusal(f"codesign could not be run: {failure}") from failure

    # codesign prints its display to standard error. Both streams are read so the
    # parse does not depend on which one this version of the tool chose.
    display = result.stdout + result.stderr
    if result.returncode != 0:
        raise Refusal(f"codesign could not read the signature of {app}: {one_line(display)}")

    authorities = [
        line[len(AUTHORITY_PREFIX) :].strip()
        for line in display.splitlines()
        if line.startswith(AUTHORITY_PREFIX)
    ]
    if not authorities or not authorities[0]:
        raise Refusal(f"codesign names no signing authority for {app}, so the feed would vouch for nothing")

    return authorities[0]


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)

    return digest.hexdigest()


def enclosure_url(base: str, tag: str, file_name: str) -> str:
    url = f"{base.rstrip('/')}/{quote(tag)}/{quote(file_name)}"
    if urlsplit(url).scheme != "https":
        raise Refusal(f"the enclosure url {url} is not https, and the update is downloaded from it")

    return url


def sign_disk_image(sign_update: Path, dmg: Path, private_key: bytes) -> tuple[str, str]:
    """The EdDSA signature and byte length, from the tool that produced them.

    The key is handed over on standard input, which is the only supported way to
    pass it: `-s` is deprecated and an argument is world readable. Both values
    come from this one call so the pair cannot disagree.
    """
    result = subprocess.run(
        [str(sign_update), "--ed-key-file", "-", str(dmg)],
        input=private_key,
        capture_output=True,
        check=False,
    )
    printed = result.stdout.decode("utf-8", "replace")
    if result.returncode != 0:
        # sign_update reports what is wrong with the key by shape, never by
        # value, so quoting it here leaks nothing and is the only way an
        # operator learns why a release stopped.
        raise Refusal(
            f"sign_update refused to sign {dmg.name}: "
            f"{one_line(result.stderr.decode('utf-8', 'replace') + printed)}"
        )

    signature = attribute(SIGNATURE_ATTRIBUTE, "sparkle:edSignature attribute", printed)
    length = attribute(LENGTH_ATTRIBUTE, "length attribute carrying a byte count", printed)
    return signature, length


def attribute(pattern: re.Pattern, description: str, printed: str) -> str:
    found = pattern.search(printed)
    if not found:
        raise Refusal(f"sign_update printed no {description}: {one_line(printed)}")

    return found.group(1)


def one_line(text: str) -> str:
    return " ".join(text.split()) or "it printed nothing"


# MARK: - Writing the item


def item_element(
    app: AppFacts,
    engine: EngineFacts,
    identity: str,
    digest: str,
    url: str,
    signature: str,
    length: str,
    critical: bool,
) -> ET.Element:
    """One appcast item, carrying everything both readers require.

    There is deliberately no pubDate: Sparkle reads it only for a phased
    rollout, which this feed does not use, and leaving it out makes the item a
    pure function of the artifact it describes, so the same release always
    produces the same bytes.
    """
    item = ET.Element("item")
    with_text(item, "title", f"Version {app.marketing_version}")
    with_text(item, sparkle("version"), app.build_number)
    with_text(item, sparkle("shortVersionString"), app.marketing_version)
    with_text(item, sparkle("minimumSystemVersion"), app.minimum_system_version)
    if critical:
        ET.SubElement(item, sparkle("criticalUpdate"))

    with_text(item, fermix("engineBuildId"), engine.build_id)
    with_text(item, fermix("engineVersion"), engine.product_version)
    with_text(item, fermix("sha256"), digest)
    with_text(item, fermix("signingIdentity"), identity)

    ET.SubElement(
        item,
        "enclosure",
        {
            "url": url,
            "length": length,
            "type": ENCLOSURE_TYPE,
            sparkle("edSignature"): signature,
        },
    )
    return item


def with_text(parent: ET.Element, name: str, value: str) -> ET.Element:
    child = ET.SubElement(parent, name)
    child.text = value
    return child


def write_document(element: ET.Element, out: Path) -> None:
    if not out.parent.is_dir():
        raise Refusal(f"there is no directory to write {out} into")

    # ElementTree keys a name by its namespace uri and decides the prefix at
    # serialization time from this table. The prefix is not cosmetic here: the
    # app looks the Fermix elements up by their qualified name, and an
    # unregistered namespace would serialize as `ns0:` and be refused by every
    # client that read it.
    ET.register_namespace("sparkle", SPARKLE_NAMESPACE)
    ET.register_namespace("fermix", FERMIX_NAMESPACE)

    tree = ET.ElementTree(element)
    ET.indent(tree, space="  ")
    tree.write(str(out), encoding="utf-8", xml_declaration=True)


# MARK: - Merging the cumulative feed


def read_item(path: Path) -> ET.Element:
    root = parse_document(path)
    if root.tag != "item":
        raise Refusal(f"{path} is not one appcast item, its root element is <{root.tag}>")

    return root


def read_previous_items(previous: Optional[str]) -> list[ET.Element]:
    """Every item the last published feed carried.

    The feed is cumulative by contract: the app refuses an update unless the
    feed also describes the build that is installed, so dropping an old item
    strands everyone still running it. The first release has no previous feed,
    which is a state, not a failure.
    """
    if previous is None:
        return []

    path = existing_file(Path(previous), "the previous appcast")
    root = parse_document(path)
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise Refusal(
            f"{path} is not an rss feed with a channel, so the releases it "
            "describes cannot be carried forward"
        )

    items = channel.findall("item")
    if not items:
        raise Refusal(f"{path} describes no release, so it is not a feed any client could have read")

    return list(items)


def refuse_unless_newer(build: int, marketing: str, previous: Sequence[ET.Element]) -> None:
    """The two rules that keep a feed orderable and honest.

    A reused or decreasing build number is the defect a client cannot recover
    from: Sparkle orders candidates by it, so a second release published under
    a build that is already out there is invisible to everyone who took the
    first one.
    """
    for entry in previous:
        published = item_build(entry)
        if build <= published:
            raise Refusal(
                f"the published build number {build} is not greater than {published}, "
                "which the feed already describes"
            )
        if marketing == item_marketing(entry):
            raise Refusal(f"the marketing version {marketing} is already published as build {published}")


def feed_element(items: Sequence[ET.Element]) -> ET.Element:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    with_text(channel, "title", CHANNEL_TITLE)
    with_text(channel, "link", CHANNEL_LINK)
    with_text(channel, "description", CHANNEL_DESCRIPTION)
    for entry in sorted(items, key=item_build, reverse=True):
        channel.append(entry)

    return rss


def item_build(entry: ET.Element) -> int:
    value = element_text(entry, sparkle("version"), "build number")
    if not BUILD_NUMBER.fullmatch(value):
        raise Refusal(f"the feed carries the build number '{value}', which is not a plain positive integer")

    return int(value)


def item_marketing(entry: ET.Element) -> str:
    return element_text(entry, sparkle("shortVersionString"), "marketing version")


def element_text(entry: ET.Element, name: str, description: str) -> str:
    found = entry.find(name)
    value = (found.text or "").strip() if found is not None else ""
    if not value:
        raise Refusal(f"an appcast item names no {description}")

    return value


def parse_document(path: Path) -> ET.Element:
    # Both documents this reads are assets this script itself wrote and this
    # repository's own release published, which is why the standard library
    # parser is enough: nothing here ever parses a feed from somewhere else.
    try:
        return ET.parse(str(path)).getroot()
    except (OSError, ET.ParseError) as failure:
        raise Refusal(f"{path} is not readable xml: {failure}") from failure


# MARK: - Arguments and the two runs


def existing_file(path: Path, description: str) -> Path:
    if not path.is_file():
        raise Refusal(f"{description} is not a file at {path}")

    return path


def existing_bundle(path: Path) -> Path:
    if not path.is_dir():
        raise Refusal(f"the app bundle is not a directory at {path}")

    return path


def executable_file(path: Path) -> Path:
    existing_file(path, "sign_update")
    if not path.stat().st_mode & 0o111:
        raise Refusal(f"sign_update at {path} is not executable")

    return path


def private_key_from_stdin() -> bytes:
    key = sys.stdin.buffer.read()
    if not key.strip():
        raise Refusal("the ed25519 private key did not arrive on standard input")

    return key


def run_item(arguments: argparse.Namespace) -> None:
    dmg = existing_file(Path(arguments.dmg), "the disk image")
    app = existing_bundle(Path(arguments.app))
    sign_update = executable_file(Path(arguments.sign_update))
    private_key = private_key_from_stdin()

    # Everything readable locally is read first, so a release with a defect in
    # what it published is refused before the signing key is used at all.
    app_facts = read_app_facts(app)
    engine = read_engine_facts(app)
    identity = read_signing_identity(app)
    digest = sha256_of(dmg)
    url = enclosure_url(arguments.release_base, arguments.tag, dmg.name)
    signature, length = sign_disk_image(sign_update, dmg, private_key)

    element = item_element(
        app=app_facts,
        engine=engine,
        identity=identity,
        digest=digest,
        url=url,
        signature=signature,
        length=length,
        critical=arguments.critical,
    )
    write_document(element, Path(arguments.out))


def run_merge(arguments: argparse.Namespace) -> None:
    item = read_item(existing_file(Path(arguments.item), "the appcast item"))
    previous = read_previous_items(arguments.previous)
    refuse_unless_newer(item_build(item), item_marketing(item), previous)
    write_document(feed_element([item, *previous]), Path(arguments.out))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    item = commands.add_parser("item", help="write one appcast item for a stapled release")
    item.add_argument("--dmg", required=True, help="the stapled disk image that is being published")
    item.add_argument("--app", required=True, help="the app bundle that image carries")
    item.add_argument("--tag", required=True, help="the release tag the asset is published under")
    item.add_argument("--sign-update", required=True, help="Sparkle's sign_update binary")
    item.add_argument("--release-base", default=DEFAULT_RELEASE_BASE, help="the release download base url")
    item.add_argument(
        "--critical",
        action="store_true",
        help="mark the release critical, which offers the person no skip",
    )
    item.add_argument("--out", required=True, help="where to write the item document")
    item.set_defaults(run=run_item)

    merge = commands.add_parser("merge", help="merge one item into the cumulative feed")
    merge.add_argument("--item", required=True, help="the item document to publish")
    merge.add_argument("--previous", help="the last published feed; omit for the first release")
    merge.add_argument("--out", required=True, help="where to write the feed")
    merge.set_defaults(run=run_merge)

    return parser


def main(argv: Sequence[str]) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        arguments.run(arguments)
    except Refusal as refusal:
        print(f"appcast: {refusal}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
