# fermix-macos

Native macOS apps for [Fermix](https://github.com/tezra-io/fermix), built,
Developer-ID signed, notarized, and distributed as drag-to-Applications DMGs +
Homebrew casks. Product-neutral: each app lives under `Apps/` and shares one
signing / notarization / release pipeline.

## Apps

| App | Path | Cask | Tag namespace |
|---|---|---|---|
| **FermixPet** — floating voice companion | `Apps/FermixPet/` | `Casks/fermixpet.rb` | `fermixpet-v*` |

## Layout

```
Apps/<App>/            SwiftPM package for each app
scripts/               keychain.sh, package_release.sh (build→sign→notarize→staple→DMG),
                       verify_protocol_contract.sh
.github/workflows/     ci.yml (PR gates), notarize.yml (reusable signing), release-<app>.yml
Casks/                 Homebrew cask templates (rendered at release with the real sha)
docs/realtime-contract/  vendored copy of Fermix's realtime wire contract, pinned by checksum
```

## Releasing an app

1. Push a tag `fermixpet-vX.Y.Z` (maintainers only — protected-tag ruleset).
2. `release-fermixpet.yml` builds universal2, signs with Developer ID, notarizes +
   staples (two-pass: app then DMG), runs the Gatekeeper quarantine-acceptance gate,
   then publishes a GitHub Release (**not** marked latest) with the DMG, its sha256,
   a keyless cosign signature, and the rendered cask.
3. Signing waits on the protected **`release-macos`** environment — a required
   reviewer must approve before the Apple secrets are exposed.

Installing (once a release exists and the repo/release is public):

```sh
brew install --cask tezra-io/tap/fermixpet   # or the local Casks/fermixpet.rb
```

## Development

Local, unsigned build (self-signed identity, no notarization):

```sh
Apps/FermixPet/script/build_and_run.sh run
```

`ci.yml` proves the universal2 build (`arm64` + `x86_64`) and the static
runtime-policy / build-harness checks on every PR, before any signed release.

## The realtime wire contract

FermixPet speaks the newline-delimited JSON protocol defined canonically by
`FermixCore.Realtime.Protocol` in the fermix repo. `docs/realtime-contract/` is a
vendored copy pinned by checksum; `scripts/verify_protocol_contract.sh` (run in CI)
fails if it drifts. Bump order across the two repos: **ship daemon support first,
then the pet** — see `docs/realtime-contract/PROTOCOL.md`.

## Required repo secrets (release only)

`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`,
`MACOS_DEVELOPER_ID`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (all seven,
scoped to the `release-macos` environment). Optional: `HOMEBREW_TAP_TOKEN` to
auto-publish the cask to `tezra-io/homebrew-tap`.
