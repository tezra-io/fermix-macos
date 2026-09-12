# Contributing

## The wire contracts are paired, cross-repo changes

Fermix and this app speak two socket protocols, both defined canonically in the
**fermix** repo:

| Protocol | Canonical source | Vendored copy |
|---|---|---|
| management (`daemon.sock`) | `FermixCore.Management.Protocol` | `Contracts/management/` |
| realtime (`realtime.sock`) | `FermixCore.Realtime.Protocol` | `Contracts/realtime/` |

`Contracts/` is `Apps/Fermix/Sources/FermixAppCore/Resources/Contracts/`. It
ships inside the application bundle, so the client reads its own bounds from the
same schema the tests do. Two records pin it:

- `CHECKSUMS.txt` — the digest of every vendored file
- `SOURCE.json` — the upstream commit, the path each file came from, the digest
  it had upstream, and each protocol's version range

Any wire-shape change touches **both repos as a pair**:

| Side | Files |
|---|---|
| daemon (fermix) | the protocol module, its socket, and `priv/<protocol>/{PROTOCOL.md, protocol.schema.json, fixtures/*.jsonl}` |
| app (this repo) | the declared version, the `Contracts/` re-vendor, and both pin records |

**Rollout order is fixed** (see either `PROTOCOL.md`):

1. Ship the daemon supporting `N+1` while keeping `N` (its window is N/N-1).
2. Only then ship an app speaking `N+1`.
3. Rollback is the reverse; never ship an app requiring a version the released
   daemon lacks.

To re-vendor a contract after a daemon-side change:

```sh
fermix=<path-to-fermix-checkout>
contracts=Apps/Fermix/Sources/FermixAppCore/Resources/Contracts
cp "$fermix"/apps/fermix_core/priv/management/{PROTOCOL.md,protocol.schema.json} \
  "$contracts/management/"
cp "$fermix"/apps/fermix_core/priv/management/fixtures/*.jsonl "$contracts/management/fixtures/"
(cd "$contracts" && shasum -a 256 $(find . -type f ! -name CHECKSUMS.txt ! -name SOURCE.json |
  sed 's|^\./||' | LC_ALL=C sort) > CHECKSUMS.txt)
# then update SOURCE.json: the upstream commit, the retrieval date, and the
# digest of every file you replaced
scripts/verify_protocol_contract.sh --source "$fermix"
```

`scripts/verify_protocol_contract.sh` runs in CI and fails on any drift between
the vendored bytes, `CHECKSUMS.txt`, and `SOURCE.json`. Checksums alone cannot
see upstream moving ahead of the copy — only `--source`, against a real fermix
checkout, can, which is why a re-vendor is verified with it.

## Releases

Tags are `vX.Y.Z` and maintainer-only, under a protected-tag ruleset. They name
releases of this app only; the engine's own tags live in the fermix repository.
Every release passes the protected `release-macos` environment before signing.
