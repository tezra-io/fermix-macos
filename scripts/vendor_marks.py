#!/usr/bin/env python3
"""Vendor mark provenance: the offline gate and the network refresh.

`check` proves the checked-in record is complete and true of the bytes on
disk. It runs offline and is the gate.

`fetch` re-retrieves every mark from the vendor URL recorded beside it and
compares the result with the recorded hash. It touches the network, so it is
an owner-run step, never a build gate.

Two records, so neither can be edited alone:

  PROVENANCE.json  one record per vendor, and the hash of the roster below
  ROSTER.json      the vendored snapshot of fermix's provider and channel sets

Completeness is checked against ROSTER.json and runs everywhere, including on a
runner with no fermix checkout. The only thing a checkout adds is *upstream
drift* — whether fermix has moved since the roster was vendored — and that check
names itself when it is skipped, so it can never be mistaken for the
completeness gate it is not.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

SCHEMA_VERSION = 1
ROSTER_SCHEMA_VERSION = 1
ROSTER_FILE = "ROSTER.json"
# The two records, which describe the tree rather than living in it.
RECORD_FILES = ("PROVENANCE.json", ROSTER_FILE)
KINDS = ("provider", "channel")
TREATMENTS = ("vendor_mark", "vendor_text_with_symbol")
ASSET_ROLES = ("color", "light", "dark", "monochrome")
FALLBACK_REASONS = ("unretrievable_official_asset", "no_published_brand_kit")

# One neutral symbol per roster kind. A per-vendor symbol would be an invented
# identity, which is exactly what section 7 forbids.
NEUTRAL_SYMBOL = {
    "provider": "cpu",
    "channel": "bubble.left.and.bubble.right",
}

REQUIRED_TEXT_FIELDS = (
    "key",
    "kind",
    "display_name",
    "accessibility_label",
    "treatment",
    "source_url",
    "source_retrieved_on",
    "usage_terms",
    "permitted_treatment",
    "dark_mode_policy",
)

DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
PROVIDER_ID = re.compile(r"^\s*id: :([a-z0-9_]+),\s*$", re.MULTILINE)
CHANNEL_KEY = re.compile(r"^\s*([a-z0-9_]+): [a-z0-9_]+_form\(channels\),?\s*$", re.MULTILINE)

# Product copy rules from M34: these strings must not reach a shipping resource.
FORBIDDEN_COPY = ("—", "!", "please wait", "FermixPet", "TODO", "TBD")

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)


class Failure(Exception):
    """A gate failure with an operator-readable sentence."""


def load(marks_dir: Path) -> dict:
    path = marks_dir / "PROVENANCE.json"
    if not path.is_file():
        raise Failure(f"provenance record is missing at {path}")
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise Failure(f"provenance record is not valid JSON: {error}") from error
    if record.get("schema_version") != SCHEMA_VERSION:
        raise Failure(
            f"provenance schema {record.get('schema_version')!r} is not supported "
            f"(this gate reads {SCHEMA_VERSION})"
        )
    return record


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_copy(marks_dir: Path) -> None:
    text = (marks_dir / "PROVENANCE.json").read_text(encoding="utf-8")
    for banned in FORBIDDEN_COPY:
        if banned in text:
            raise Failure(f"provenance record carries forbidden copy {banned!r}")


def check_mark_fields(mark: dict) -> None:
    key = mark.get("key", "<unnamed>")
    for field in REQUIRED_TEXT_FIELDS:
        value = mark.get(field)
        if not isinstance(value, str) or not value.strip():
            raise Failure(f"{key}: field {field} is missing or empty")
    if mark["kind"] not in KINDS:
        raise Failure(f"{key}: kind {mark['kind']!r} is not one of {KINDS}")
    if mark["treatment"] not in TREATMENTS:
        raise Failure(f"{key}: treatment {mark['treatment']!r} is not one of {TREATMENTS}")
    if not DATE.match(mark["source_retrieved_on"]):
        raise Failure(f"{key}: source_retrieved_on {mark['source_retrieved_on']!r} is not YYYY-MM-DD")
    if not mark["source_url"].startswith("https://"):
        raise Failure(f"{key}: source_url is not an https URL")


def check_assets(mark: dict, marks_dir: Path, claimed: set[str]) -> None:
    key = mark["key"]
    assets = mark.get("assets") or []
    if mark["treatment"] == "vendor_text_with_symbol":
        if assets:
            raise Failure(
                f"{key}: declares the text treatment but ships {len(assets)} asset(s); "
                "a vendor without a retrievable mark ships no file"
            )
        return
    if not assets:
        raise Failure(f"{key}: declares a vendor mark but ships no asset")
    seen_roles: set[str] = set()
    for asset in assets:
        role = asset.get("role")
        if role not in ASSET_ROLES:
            raise Failure(f"{key}: asset role {role!r} is not one of {ASSET_ROLES}")
        if role in seen_roles:
            raise Failure(f"{key}: asset role {role!r} is declared twice")
        seen_roles.add(role)

        relative = asset.get("path")
        if not isinstance(relative, str) or not relative:
            raise Failure(f"{key}: asset {role} has no path")
        path = marks_dir / relative
        if not path.is_file():
            raise Failure(f"{key}: asset {role} is recorded at {relative} but no such file exists")
        actual = sha256_of(path.read_bytes())
        if actual != asset.get("sha256"):
            raise Failure(
                f"{key}: asset {relative} hashes to {actual} "
                f"but the record pins {asset.get('sha256')}"
            )
        url = asset.get("asset_url", "")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise Failure(f"{key}: asset {role} has no https asset_url")
        if not DATE.match(asset.get("retrieved_on", "")):
            raise Failure(f"{key}: asset {role} has no YYYY-MM-DD retrieved_on")
        claimed.add(relative)


def check_fallback(mark: dict) -> None:
    key = mark["key"]
    fallback = mark.get("fallback")
    if mark["treatment"] == "vendor_mark":
        if fallback is not None:
            raise Failure(f"{key}: ships a vendor mark and must not also declare a fallback")
        return
    if not isinstance(fallback, dict):
        raise Failure(f"{key}: declares the text treatment but records no fallback")
    expected = NEUTRAL_SYMBOL[mark["kind"]]
    if fallback.get("sf_symbol") != expected:
        raise Failure(
            f"{key}: fallback symbol {fallback.get('sf_symbol')!r} is not the neutral "
            f"{mark['kind']} symbol {expected!r}"
        )
    if fallback.get("reason") not in FALLBACK_REASONS:
        raise Failure(f"{key}: fallback reason {fallback.get('reason')!r} is not one of {FALLBACK_REASONS}")
    detail = fallback.get("detail")
    if not isinstance(detail, str) or not detail.strip():
        raise Failure(f"{key}: fallback records no detail explaining why the mark is absent")


def check_no_orphans(marks_dir: Path, claimed: set[str]) -> None:
    on_disk = {
        str(path.relative_to(marks_dir))
        for path in marks_dir.rglob("*")
        if path.is_file() and path.name not in RECORD_FILES
    }
    undeclared = sorted(on_disk - claimed)
    if undeclared:
        raise Failure(
            "these files sit in VendorMarks but no record claims them: " + ", ".join(undeclared)
        )
    missing = sorted(claimed - on_disk)
    if missing:
        raise Failure("these recorded assets are absent: " + ", ".join(missing))


def load_roster(marks_dir: Path, record: dict) -> dict:
    """The vendored roster, proven to be the bytes PROVENANCE.json pinned.

    Two records that must agree is the point: dropping a vendor means editing
    both files *and* re-pinning the hash, which is a deliberate re-vendor rather
    than an edit that slips past a count the same file declares about itself.
    """
    path = marks_dir / ROSTER_FILE
    if not path.is_file():
        raise Failure(f"roster snapshot is missing at {path}")

    payload = path.read_bytes()
    pinned = (record.get("roster_source") or {}).get("roster_sha256")
    actual = sha256_of(payload)
    if actual != pinned:
        raise Failure(
            f"{ROSTER_FILE} hashes to {actual} but PROVENANCE.json pins {pinned}; "
            "re-vendor the roster rather than editing one record alone"
        )

    try:
        roster = json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as error:
        raise Failure(f"{ROSTER_FILE} is not valid JSON: {error}") from error
    if roster.get("schema_version") != ROSTER_SCHEMA_VERSION:
        raise Failure(
            f"roster schema {roster.get('schema_version')!r} is not supported "
            f"(this gate reads {ROSTER_SCHEMA_VERSION})"
        )
    for kind in KINDS:
        keys = roster.get(f"{kind}s")
        if not isinstance(keys, list) or not keys:
            raise Failure(f"{ROSTER_FILE} carries no {kind} roster")
    return roster


def check_roster(record: dict, roster: dict) -> None:
    """Every vendor the roster names has a record, and no record invents one.

    This is the completeness gate, and it runs offline: it compares the marks
    against a second checked-in file rather than against a count PROVENANCE.json
    declares about itself.
    """
    source = record.get("roster_source") or {}
    marks = record["marks"]
    for kind, declared_count in (("provider", "provider_count"), ("channel", "channel_count")):
        keys = sorted(m["key"] for m in marks if m["kind"] == kind)
        expected = sorted(roster[f"{kind}s"])
        if keys != expected:
            missing = sorted(set(expected) - set(keys))
            extra = sorted(set(keys) - set(expected))
            raise Failure(
                f"{kind} roster drifted from {ROSTER_FILE}: "
                f"missing {missing}, unrecorded {extra}"
            )
        if len(keys) != source.get(declared_count):
            raise Failure(
                f"{len(keys)} {kind} records against a declared count of {source.get(declared_count)}"
            )


def check_upstream(roster: dict, fermix_repo: Path | None) -> None:
    """Whether fermix has moved since the roster was vendored.

    This is the only check that needs the upstream repository, and it is about
    drift rather than completeness — `check_roster` has already proven the
    records are complete against the vendored snapshot.
    """
    if fermix_repo is None:
        print(
            "check_vendor_marks: upstream-drift check skipped, no fermix checkout at the "
            "resolved path (set --fermix-repo to run it). Completeness was checked "
            f"against {ROSTER_FILE}."
        )
        return

    source = roster["source"]
    descriptor = fermix_repo / source["providers"]["path"]
    setup_live = fermix_repo / source["channels"]["path"]
    for path in (descriptor, setup_live):
        if not path.is_file():
            raise Failure(f"roster source is missing at {path}")

    upstream_providers = sorted(set(PROVIDER_ID.findall(descriptor.read_text(encoding="utf-8"))))
    if upstream_providers != sorted(roster["providers"]):
        raise Failure(
            "provider roster drifted: fermix publishes "
            f"{upstream_providers} and {ROSTER_FILE} carries {sorted(roster['providers'])}"
        )

    excluded = set((roster.get("channel_exclusions") or {}).keys())
    upstream_channels = set(CHANNEL_KEY.findall(setup_live.read_text(encoding="utf-8"))) - excluded
    if sorted(upstream_channels) != sorted(roster["channels"]):
        raise Failure(
            "channel roster drifted: fermix publishes "
            f"{sorted(upstream_channels)} and {ROSTER_FILE} carries {sorted(roster['channels'])}"
        )

    for kind in KINDS:
        path = fermix_repo / source[f"{kind}s"]["path"]
        actual = sha256_of(path.read_bytes())
        if actual != source[f"{kind}s"]["sha256"]:
            raise Failure(
                f"{path} hashes to {actual} but {ROSTER_FILE} pins "
                f"{source[f'{kind}s']['sha256']}; re-vendor the roster"
            )


def resolve_fermix_repo(marks_dir: Path, override: str | None) -> Path | None:
    if override:
        path = Path(override).expanduser().resolve()
        if not path.is_dir():
            raise Failure(f"--fermix-repo points at {path}, which is not a directory")
        return path
    sibling = marks_dir.parents[5].parent / "fermix"
    return sibling if sibling.is_dir() else None


def run_check(marks_dir: Path, fermix_repo_override: str | None) -> None:
    record = load(marks_dir)
    check_copy(marks_dir)
    marks = record.get("marks")
    if not isinstance(marks, list) or not marks:
        raise Failure("provenance record carries no marks")

    keys: set[str] = set()
    labels: set[str] = set()
    claimed: set[str] = set()
    for mark in marks:
        check_mark_fields(mark)
        if mark["key"] in keys:
            raise Failure(f"{mark['key']}: recorded twice")
        keys.add(mark["key"])
        label = mark["accessibility_label"]
        if label in labels:
            raise Failure(f"{mark['key']}: accessibility label {label!r} is not unique")
        labels.add(label)
        check_assets(mark, marks_dir, claimed)
        check_fallback(mark)

    check_no_orphans(marks_dir, claimed)
    roster = load_roster(marks_dir, record)
    check_roster(record, roster)
    check_upstream(roster, resolve_fermix_repo(marks_dir, fermix_repo_override))

    shipped = sum(1 for m in marks if m["treatment"] == "vendor_mark")
    print(
        f"check_vendor_marks: {len(marks)} marks recorded, {shipped} ship a vendor asset, "
        f"{len(marks) - shipped} render as vendor text with a neutral symbol"
    )


def download(url: str) -> bytes:
    """Fetch through the system curl.

    Not urllib: a Homebrew python3 has no CA bundle of its own and fails every
    https request with CERTIFICATE_VERIFY_FAILED, which would make the refresh
    depend on which python3 is first on PATH. /usr/bin/curl uses the system
    trust store, so the result is the same on any Mac.
    """
    completed = subprocess.run(
        [
            "/usr/bin/curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--max-time",
            "60",
            "--user-agent",
            USER_AGENT,
            url,
        ],
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip() or f"curl exit {completed.returncode}"
        raise Failure(f"{url} could not be fetched: {detail}")
    return completed.stdout


def member_bytes(payload: bytes, member: str) -> bytes:
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        names = set(archive.namelist())
        if member not in names:
            raise Failure(f"archive does not contain {member}")
        return archive.read(member)


def run_fetch(marks_dir: Path, write: bool) -> int:
    record = load(marks_dir)
    changed = 0
    blocked = []
    for mark in record["marks"]:
        if mark["treatment"] != "vendor_mark":
            blocked.append(mark)
            continue
        for asset in mark["assets"]:
            url = asset["asset_url"]
            try:
                payload = download(url)
            except Failure as error:
                raise Failure(f"{mark['key']} {asset['role']}: {error}") from error
            if asset.get("asset_member"):
                payload = member_bytes(payload, asset["asset_member"])
            actual = sha256_of(payload)
            target = marks_dir / asset["path"]
            if actual == asset["sha256"]:
                print(f"unchanged  {mark['key']:<10} {asset['role']:<10} {asset['path']}")
                continue
            changed += 1
            print(
                f"CHANGED    {mark['key']:<10} {asset['role']:<10} {asset['path']}\n"
                f"           recorded {asset['sha256']}\n"
                f"           upstream {actual}"
            )
            if write:
                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as handle:
                    handle.write(payload)
                    temporary = Path(handle.name)
                temporary.replace(target)
                print(f"           wrote {target}")

    for mark in blocked:
        fallback = mark["fallback"]
        print(
            f"no asset   {mark['key']:<10} {fallback['reason']}\n"
            f"           official page: {mark['source_url']}"
        )

    if changed:
        print(
            f"\nfetch_vendor_marks: {changed} asset(s) differ from the record. "
            "A vendor updated its mark. Review the new file, then update PROVENANCE.json "
            "with the new hash and retrieval date."
        )
        return 2
    print("\nfetch_vendor_marks: every recorded asset matches its vendor source")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "fetch"))
    parser.add_argument("--marks-dir", required=True)
    parser.add_argument("--fermix-repo", default=None)
    parser.add_argument(
        "--write",
        action="store_true",
        help="fetch only: overwrite a changed asset instead of only reporting it",
    )
    arguments = parser.parse_args(argv)

    marks_dir = Path(arguments.marks_dir).resolve()
    if not marks_dir.is_dir():
        print(f"vendor_marks: {marks_dir} is not a directory", file=sys.stderr)
        return 1

    try:
        if arguments.command == "check":
            run_check(marks_dir, arguments.fermix_repo)
            return 0
        return run_fetch(marks_dir, arguments.write)
    except Failure as failure:
        print(f"vendor_marks: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
