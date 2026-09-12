# Fermix macOS app

Native SwiftUI app with the Fermix engine bundled inside it. The app never reads config, secrets or state itself: everything it shows and changes goes over `daemon.sock` through the management protocol, and voice goes over the realtime wire. The engine repository (`tezra-io/fermix`) owns both contracts; this repository vendors them and pins the engine it ships.

## Layout
```
Apps/Fermix/Sources/FermixAppCore/   # every view and behaviour; Resources/ (Product.json, Contracts/, VendorMarks/, strings)
Apps/Fermix/Sources/Fermix           # the GUI executable
Apps/Fermix/Sources/FermixAgent      # the background agent launchd runs (SMAppService)
Apps/Fermix/Tests/FermixAppCoreTests # swift-testing; run through script/swift_test.sh (plain swift test misses the framework paths)
scripts/                             # stage_app.sh, sign_app.sh, verify_staged_app.sh, package_release.sh, dev_e2e.sh, the gates
docs/                                # ignored except the tracked runbooks, SHIPPING.md and the design redlines
```

## The contract with the engine
- `Resources/Contracts/management/` and `Resources/Contracts/realtime/` are byte-identical copies of the engine's `apps/fermix_core/priv/{management,realtime}/`, pinned by `CHECKSUMS.txt` and `SOURCE.json`. `scripts/verify_protocol_contract.sh` checks the pin; `--source <fermix-checkout>` byte-compares against the engine tree. A change to a descriptor, a sentence, a vocabulary or a method lands in the engine first, then is re-vendored here in one commit with the tests that follow the goldens. Never edit a vendored file by hand.
- `SOURCE.json` must pin a committed engine commit (`committed_upstream: true`). The release audience of `verify_staged_app.sh` refuses an unpublished pin, a draft contract, a debug-only configuration and an engine outside the protocol window, and CI's staging dry run runs that audience on every pull request.
- The app decodes the daemon's answers and renders its sentences. It never derives state the daemon publishes (`status_sentence`, `primary_action`, readiness, restart reasons), never authors a second copy of a descriptor, and switches on published action ids, never on verb words.
- The engine inside the bundle is a `fermix_app_engine` release tree per architecture, taken from the engine release's assets by a pinned tag and verified by checksum and cosign at staging (`docs/SHIPPING.md`). The app never builds an engine of its own.

## Shipping and upgrades
- A release is tag-driven and CI-built: universal build, Developer ID signing, notarization and stapling, a DMG, a Gatekeeper gate, a GitHub Release with sha256, cosign signature and the cask, then the tap pull request. `docs/SHIPPING.md` is the plan and `docs/STAGE0_RUNBOOK.md` the acceptance session.
- Any engine capability the app should expose ships as: engine change and export, engine release, app pin bump and re-vendor, app release. The daemon ships first; the app's window (`supported_version_range` in `SOURCE.json`) and the router's per-method minimum are what make an older app degrade to a sentence instead of a crash.
- `Product.json` is the one product configuration: bundle name, identifier `io.tezra.FermixPet`, agent label, floor, versions. The identifier and agent label never change: TCC grants, the login item and the coexistence preflight are keyed on them.

## Working rules
- Copy: sentence case, no em dashes, no exclamation marks, no version numbers; every string through `ProductStrings` and `Localizable.strings`; the copy deck is `docs/design/M34_DESIGN_SYSTEM_REDLINES.md`.
- Vendor marks ship only from the vendor's own host, byte for byte, with the provenance record in `VendorMarks/PROVENANCE.json`; nothing is redrawn or recoloured, and a vendor with no retrievable mark renders as text.
- The dev loop (`scripts/dev_e2e.sh up`) builds the engine from `~/.cache/fermix-engine-m34` as it stands, stages a debug bundle, signs it with the one Developer ID Application identity in the login keychain, and registers the real background agent on `~/.fermix-macos:4530` under its own secret profile (`[fermix_core] profile = "fermix-macos"`, so the app's secret writes never land in the live daemon's keychain items). It refuses without that identity: an ad-hoc signature has no Team ID, and macOS refuses an SMAppService agent from an ad-hoc app after every rebuild (`docs/E2E_RUNBOOK.md`).
- Tests never touch AppKit windows or host state (no keychain, no login items, no `~/.fermix*`). Gates before done: `swift build` with zero warnings, `script/swift_test.sh`, `xcodegen generate`, `scripts/check_product_config.sh`, `scripts/check_brand_images.sh`, `scripts/check_vendor_marks.sh`, `scripts/verify_protocol_contract.sh` in both modes, `scripts/verify_staged_app_test.sh`, `scripts/sign_app_test.sh`, `scripts/verify_engine_test.sh`, `scripts/appcast_test.sh`, `Apps/Fermix/script/build_and_run_test.sh`, `bash scripts/dev_e2e_test.sh`.
- Code: linear flow, small functions, one owner per concept, no fallbacks, surgical changes. No AI attribution anywhere.
