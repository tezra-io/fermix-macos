# fermix-macos

Native macOS apps for [Fermix](https://github.com/tezra-io/fermix), built,
Developer-ID signed, notarized, and distributed as drag-to-Applications DMGs +
Homebrew casks. Product-neutral: each app lives under `Apps/` and shares one
signing / notarization / release pipeline.

## Apps

| App | Path | Cask | Tag namespace |
|---|---|---|---|
| **Fermix** — the macOS app (voice companion today, the unified surface in progress) | `Apps/Fermix/` | `Casks/fermixpet.rb` | `fermixpet-v*` |

## Layout

```
Apps/<App>/            SwiftPM package for each app, plus its XcodeGen project.yml
Apps/Fermix/Sources/FermixAppCore/Resources/Product.json
                       the one product configuration: identity, layout, versions,
                       agent label, engine + Tools paths. Swift and the scripts
                       both read it; no plist is written anywhere else.
scripts/               product_config.sh + render_info_plist.sh + check_product_config.sh,
                       keychain.sh, package_release.sh (build→sign→notarize→staple→DMG),
                       verify_protocol_contract.sh
.github/workflows/     ci.yml (PR gates), notarize.yml (reusable signing), release-<app>.yml
Casks/                 Homebrew cask templates (rendered at release with the real sha)
Apps/Fermix/Sources/FermixAppCore/Resources/Contracts/
                       vendored copies of Fermix's management and realtime wire
                       contracts, pinned by CHECKSUMS.txt + SOURCE.json
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
Apps/Fermix/script/build_and_run.sh run
```

Gates:

```sh
cd Apps/Fermix && swift build && script/swift_test.sh
xcodegen generate                 # validates project.yml
../../scripts/check_product_config.sh
```

`script/swift_test.sh` supplies the swift-testing search path and rpaths that
Command Line Tools need and a full Xcode toolchain does not.

`ci.yml` proves the universal2 build (`arm64` + `x86_64`) and the static
runtime-policy / build-harness checks on every PR, before any signed release.

## The wire contracts

The app speaks two socket protocols defined canonically in the fermix repo: the
packet-4 management protocol on `daemon.sock` and the newline-delimited realtime
protocol on `realtime.sock`. Both are vendored under
`Apps/Fermix/Sources/FermixAppCore/Resources/Contracts/` and pinned by
`CHECKSUMS.txt` plus `SOURCE.json`; `scripts/verify_protocol_contract.sh` (run in
CI) fails if either drifts, and `--source <fermix-checkout>` additionally proves
the copy is byte-identical to upstream. Bump order across the two repos: **ship
daemon support first, then the app** — see each `PROTOCOL.md`.

## Required repo secrets (release only)

`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`,
`MACOS_DEVELOPER_ID`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (all seven,
scoped to the `release-macos` environment). Optional: `HOMEBREW_TAP_TOKEN` to
auto-publish the cask to `tezra-io/homebrew-tap`.
