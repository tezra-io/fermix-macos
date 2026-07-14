# Contributing

## The realtime wire contract is a paired, cross-repo change

FermixPet's socket protocol is defined canonically in the **fermix** repo by
`FermixCore.Realtime.Protocol` (`apps/fermix_core/lib/fermix_core/realtime/protocol.ex`).
This repo carries a vendored, checksum-pinned copy under `docs/realtime-contract/`.

Any wire-shape change touches **both repos as a pair**:

| Side | Files |
|---|---|
| daemon (fermix) | `realtime/protocol.ex`, `realtime/local_voice_socket.ex`, `priv/realtime/{PROTOCOL.md, protocol.schema.json, fixtures/*.jsonl}` |
| pet (this repo) | `Apps/FermixPet/Sources/FermixPet/CompanionState.swift` (`protocolVersion`), `docs/realtime-contract/` re-vendor + `CHECKSUMS.txt` |

**Rollout order is fixed** (see `docs/realtime-contract/PROTOCOL.md`):

1. Ship the daemon supporting `N+1` while keeping `N` (its window is N/N-1).
2. Only then ship a pet speaking `N+1`.
3. Rollback is the reverse; never ship a pet requiring a version the released
   daemon lacks.

To re-vendor the contract after a daemon-side change:

```sh
cp <fermix>/apps/fermix_core/priv/realtime/PROTOCOL.md docs/realtime-contract/
cp <fermix>/apps/fermix_core/priv/realtime/protocol.schema.json docs/realtime-contract/
cp <fermix>/apps/fermix_core/priv/realtime/fixtures/*.jsonl docs/realtime-contract/fixtures/
(cd docs/realtime-contract && shasum -a 256 PROTOCOL.md protocol.schema.json \
  fixtures/client_events.jsonl fixtures/server_events.jsonl > CHECKSUMS.txt)
```

CI (`scripts/verify_protocol_contract.sh`) fails on any drift from the recorded
checksums, so an accidental edit of the vendored copy cannot land silently.

## Releases

Tags are app-scoped (`fermixpet-vX.Y.Z`) and maintainer-only. Never create a bare
`v*` tag here — that namespace belongs to the fermix CLI. Every release passes
the protected `release-macos` environment before signing.
