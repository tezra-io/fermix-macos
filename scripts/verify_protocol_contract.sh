#!/usr/bin/env bash
#
# Verify the vendored wire contracts.
#
# The canonical sources are `FermixCore.Management.Protocol` and
# `FermixCore.Realtime.Protocol` in the fermix repo. This repo carries one
# vendored tree, `Apps/Fermix/Sources/FermixAppCore/Resources/Contracts/`, which
# ships inside the application bundle and is pinned by two records:
#
#   CHECKSUMS.txt  the digest of every vendored file, in `shasum -a 256 -c` form
#   SOURCE.json    where each file came from and what it hashed to upstream
#
# Three checks always run:
#
#   1. the vendored bytes match CHECKSUMS.txt
#   2. the tree and CHECKSUMS.txt list exactly the same files, so a file cannot
#      be added or dropped without the pin noticing
#   3. CHECKSUMS.txt and SOURCE.json agree, so regenerating the checksums over a
#      locally edited file no longer verifies clean — which is the hole the
#      previous single-record pin had
#
# The fourth check needs the upstream repository and is therefore explicit:
#
#   verify_protocol_contract.sh --source <path-to-fermix-checkout>
#
# byte-compares every vendored file against the path SOURCE.json records. This
# is the only check that can see upstream moving ahead of the vendored copy, and
# it is what a re-vendor must be verified with.
#
# Every contract in the tree is vendored, and check 3 refuses a record that
# declares itself a DRAFT authored in this repository. The management protocol v2
# artifact was one until the engine published it; nothing is now, and this is the
# third gate saying so, beside `VendoredContractTests` and the release audience
# of `verify_staged_app.sh`. A draft has no `source_path` to compare against, so
# tolerating one here would have left check 4 with nothing to check on the one
# contract the app is built against.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$ROOT_DIR/Apps/Fermix/Sources/FermixAppCore/Resources/Contracts"
SOURCE_CHECKOUT=""

fail() {
  echo "verify_protocol_contract: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      [ $# -ge 2 ] || fail "--source needs a path to a fermix checkout"
      SOURCE_CHECKOUT="$2"
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -d "$CONTRACTS_DIR" ] || fail "vendored contract tree is missing at $CONTRACTS_DIR"

cd "$CONTRACTS_DIR"

# 1. The vendored bytes are the pinned bytes.
shasum -a 256 -c CHECKSUMS.txt

# 2. The manifest covers the tree exactly.
present="$(find . -type f ! -name CHECKSUMS.txt ! -name SOURCE.json |
  sed 's|^\./||' | LC_ALL=C sort)"
pinned="$(awk '{ print $2 }' CHECKSUMS.txt | LC_ALL=C sort)"
if [ "$present" != "$pinned" ]; then
  echo "vendored files:" >&2
  diff <(echo "$pinned") <(echo "$present") >&2 || true
  fail "CHECKSUMS.txt does not list exactly the files in the tree"
fi

# 3. The two records agree, file for file and digest for digest.
python3 - "$CONTRACTS_DIR" <<'PY'
import json, sys, pathlib

root = pathlib.Path(sys.argv[1])
provenance = json.loads((root / "SOURCE.json").read_text())

pinned = {}
for line in (root / "CHECKSUMS.txt").read_text().splitlines():
    if not line.strip():
        continue
    digest, path = line.split()
    pinned[path] = digest

recorded = {}
for contract in provenance["contracts"]:
    for entry in contract["files"]:
        recorded[entry["path"]] = entry["sha256"]

problems = []
for path in sorted(set(pinned) | set(recorded)):
    if path not in pinned:
        problems.append(f"{path}: in SOURCE.json but not in CHECKSUMS.txt")
    elif path not in recorded:
        problems.append(f"{path}: in CHECKSUMS.txt but not in SOURCE.json")
    elif pinned[path] != recorded[path]:
        problems.append(
            f"{path}: CHECKSUMS.txt has {pinned[path][:12]}, "
            f"SOURCE.json records {recorded[path][:12]}"
        )

if problems:
    for problem in problems:
        print(f"verify_protocol_contract: {problem}", file=sys.stderr)
    sys.exit(1)

drafts = [c["name"] for c in provenance["contracts"] if c.get("draft", False)]
if drafts:
    for name in drafts:
        print(
            f"verify_protocol_contract: the {name} contract declares itself a draft "
            f"authored from the design; a draft has no upstream to compare against, "
            f"so it is not shippable. Re-vendor it from the engine.",
            file=sys.stderr,
        )
    sys.exit(1)

for contract in provenance["contracts"]:
    if not contract.get("committed_upstream", True):
        print(
            f"verify_protocol_contract: note: the {contract['name']} contract was "
            f"vendored from an uncommitted upstream working tree "
            f"({provenance['upstream']['commit'][:12]}); re-take the pin from the "
            f"commit that publishes it before release"
        )
PY

echo "vendored wire contracts: checksums and provenance OK"

# 4. Optional, explicit: compare against the upstream checkout itself.
[ -n "$SOURCE_CHECKOUT" ] || exit 0
[ -d "$SOURCE_CHECKOUT" ] || fail "fermix checkout not found at $SOURCE_CHECKOUT"

python3 - "$CONTRACTS_DIR" "$SOURCE_CHECKOUT" <<'PY'
import json, sys, pathlib

root = pathlib.Path(sys.argv[1])
upstream = pathlib.Path(sys.argv[2])
provenance = json.loads((root / "SOURCE.json").read_text())

drift = []
for contract in provenance["contracts"]:
    for entry in contract["files"]:
        source = upstream / entry["source_path"]
        if not source.is_file():
            drift.append(f"{entry['source_path']}: missing from the upstream checkout")
        elif source.read_bytes() != (root / entry["path"]).read_bytes():
            drift.append(f"{entry['path']}: differs from {entry['source_path']}")

if drift:
    for line in drift:
        print(f"verify_protocol_contract: {line}", file=sys.stderr)
    print(
        "verify_protocol_contract: re-vendor the contract tree and regenerate "
        "CHECKSUMS.txt and SOURCE.json in the same change",
        file=sys.stderr,
    )
    sys.exit(1)
PY

pinned_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"]["commit"])' \
  "$CONTRACTS_DIR/SOURCE.json")"
head_commit="$(git -C "$SOURCE_CHECKOUT" rev-parse HEAD)"
if [ "$pinned_commit" != "$head_commit" ]; then
  echo "verify_protocol_contract: note: the checkout is at ${head_commit:0:12}," \
    "the pin records ${pinned_commit:0:12}; the bytes match, so update the pin" \
    "when you next re-vendor"
fi

echo "vendored wire contracts: byte-identical to $SOURCE_CHECKOUT"
