#!/usr/bin/env python3
"""Whether a Developer ID provisioning profile authorizes the GUI's signature (M84 D6).

The website logins live in a keychain access group, and macOS admits a process
claiming one only when the bundle embeds a provisioning profile that authorizes
it: observed 2026-10-30, a Developer ID app carrying `keychain-access-groups`
without a profile is killed at launch (exit 137). A mismatch therefore ships an
app nobody can open, and the only place to stop it is before it is signed.
scripts/sign_app.sh is the one caller, twice: before signing, on the profile it
was handed and the entitlements it is about to sign with; after signing, on the
embedded copy, the entitlements the signature actually carries and the
certificate that made it.

Two subcommands:

  check   --profile P --entitlements E --bundle-id B [--certificate C]
          The profile authorizes E for bundle B: the same team, the explicit
          application identifier `<team>.<bundle>`, every keychain access
          group, a Developer ID profile (every device, macOS) that has not
          expired, and, given the signing certificate (DER), one that lists it.
  absent  --entitlements E
          E carries none of the keys only a profile can authorize, which is
          what every signature without an embedded profile must show.

A profile is read with `security cms -D`, which decodes the CMS envelope; whether
Apple signed it is macOS's question at launch, not this script's. Exit 0 with
one summary line, or 1 with the reason on stderr.
"""
from __future__ import annotations

import argparse
import datetime
import plistlib
import subprocess
import sys
from xml.parsers.expat import ExpatError

APPLICATION_IDENTIFIER = "com.apple.application-identifier"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"
ACCESS_GROUPS = "keychain-access-groups"
PROFILE_ONLY_KEYS = (APPLICATION_IDENTIFIER, TEAM_IDENTIFIER, ACCESS_GROUPS)


class Refusal(Exception):
    """A profile or a signature that must not ship, with the reason."""


def read_profile(path: str) -> dict:
    decoded = subprocess.run(
        ["security", "cms", "-D", "-i", path], capture_output=True, check=False
    )
    if decoded.returncode != 0 or not decoded.stdout:
        raise Refusal(f"{path} is not a provisioning profile: security cms could not decode it")
    try:
        profile = plistlib.loads(decoded.stdout)
    except (plistlib.InvalidFileException, ExpatError, ValueError) as error:
        raise Refusal(f"{path} decodes to no property list: {error}") from error
    if not isinstance(profile, dict) or not isinstance(profile.get("Entitlements"), dict):
        raise Refusal(f"{path} is not a provisioning profile: it carries no Entitlements")
    return profile


def read_entitlements(path: str) -> dict:
    try:
        with open(path, "rb") as handle:
            entitlements = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ExpatError, ValueError) as error:
        raise Refusal(f"{path} is not a readable entitlements file: {error}") from error
    if not isinstance(entitlements, dict):
        raise Refusal(f"{path} is not an entitlements dictionary")
    return entitlements


def authorizes(pattern: str, group: str) -> bool:
    """A profile's group entry admits a literal group, or a prefix ending `*`."""
    if pattern.endswith("*"):
        return group.startswith(pattern[:-1])
    return pattern == group


def require_team(profile: dict, entitlements: dict) -> str:
    team = entitlements.get(TEAM_IDENTIFIER)
    if not isinstance(team, str) or not team:
        raise Refusal(f"the entitlements carry no {TEAM_IDENTIFIER}")
    if team not in profile.get("TeamIdentifier", []):
        raise Refusal(f"the profile is for team {profile.get('TeamIdentifier')}, the signature's team is {team}")
    if profile["Entitlements"].get(TEAM_IDENTIFIER) != team:
        raise Refusal(f"the profile's {TEAM_IDENTIFIER} is {profile['Entitlements'].get(TEAM_IDENTIFIER)!r}, not {team}")
    return team


def require_application(profile: dict, entitlements: dict, team: str, bundle_id: str) -> None:
    expected = f"{team}.{bundle_id}"
    claimed = entitlements.get(APPLICATION_IDENTIFIER)
    if claimed != expected:
        raise Refusal(f"the entitlements' {APPLICATION_IDENTIFIER} is {claimed!r}, and this bundle is {expected}")
    granted = profile["Entitlements"].get(APPLICATION_IDENTIFIER)
    if granted != expected:
        raise Refusal(f"the profile is for the app id {granted!r}, and this bundle is {expected}")


def require_groups(profile: dict, entitlements: dict) -> list:
    claimed = entitlements.get(ACCESS_GROUPS)
    if not isinstance(claimed, list) or not claimed:
        raise Refusal(f"the entitlements carry no {ACCESS_GROUPS}")
    granted = profile["Entitlements"].get(ACCESS_GROUPS) or []
    missing = [group for group in claimed if not any(authorizes(entry, group) for entry in granted)]
    if missing:
        raise Refusal(f"the profile does not authorize the keychain access group {', '.join(missing)} (it grants {granted})")
    return claimed


def require_developer_id(profile: dict) -> None:
    if profile.get("ProvisionsAllDevices") is not True:
        raise Refusal("the profile is not a Developer ID profile: it does not provision every device, so the app would open only on the Macs it lists")
    if "OSX" not in profile.get("Platform", []):
        raise Refusal(f"the profile is for {profile.get('Platform')}, not macOS")


def require_unexpired(profile: dict) -> datetime.datetime:
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        raise Refusal("the profile carries no ExpirationDate")
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if expires <= now:
        raise Refusal(f"the profile expired on {expires:%Y-%m-%d}; create a new one in the developer account")
    return expires


def require_certificate(profile: dict, certificate_path: str) -> None:
    try:
        with open(certificate_path, "rb") as handle:
            certificate = handle.read()
    except OSError as error:
        raise Refusal(f"the signing certificate could not be read: {error}") from error
    if certificate not in profile.get("DeveloperCertificates", []):
        raise Refusal("the profile does not list the certificate that signed the app; regenerate it for the current Developer ID certificate")


def check(arguments: argparse.Namespace) -> str:
    profile = read_profile(arguments.profile)
    entitlements = read_entitlements(arguments.entitlements)
    team = require_team(profile, entitlements)
    require_application(profile, entitlements, team, arguments.bundle_id)
    groups = require_groups(profile, entitlements)
    require_developer_id(profile)
    expires = require_unexpired(profile)
    if arguments.certificate:
        require_certificate(profile, arguments.certificate)
    return (
        f"profile {profile.get('Name', '?')} ({profile.get('UUID', '?')}), team {team}, "
        f"expires {expires:%Y-%m-%d}, authorizes {', '.join(groups)}"
    )


def absent(arguments: argparse.Namespace) -> str:
    entitlements = read_entitlements(arguments.entitlements)
    present = [key for key in PROFILE_ONLY_KEYS if key in entitlements]
    if present:
        raise Refusal(f"the signature carries {', '.join(present)} and the bundle embeds no provisioning profile; macOS kills it at launch")
    return "no profile-only entitlements, and no profile"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("check")
    checking.add_argument("--profile", required=True)
    checking.add_argument("--entitlements", required=True)
    checking.add_argument("--bundle-id", required=True)
    checking.add_argument("--certificate")
    absence = commands.add_parser("absent")
    absence.add_argument("--entitlements", required=True)
    arguments = parser.parse_args()

    try:
        summary = check(arguments) if arguments.command == "check" else absent(arguments)
    except Refusal as refusal:
        print(f"provisioning_profile: {refusal}", file=sys.stderr)
        return 1
    print(f"provisioning_profile: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
