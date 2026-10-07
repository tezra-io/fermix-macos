# fermix-macos

The native macOS app for [Fermix](https://github.com/tezra-io/fermix), with the
engine bundled inside it. Built, Developer ID signed, notarized and shipped as a
DMG and a Homebrew cask. `AGENTS.md` holds the rules the code follows; this file
is how to build, test and release it.

## Layout

```
Apps/Fermix/                      SwiftPM package (plus project.yml for XcodeGen)
  Sources/FermixAppCore/          every view and behaviour
    Resources/Product.json        the one product configuration: identity, versions, paths
    Resources/Contracts/          vendored engine wire contracts (management, realtime,
                                  companion, browser_host), pinned by CHECKSUMS.txt + SOURCE.json
    Resources/VendorMarks/        vendor marks with their provenance and roster
  Sources/Fermix                  the GUI executable
  Sources/FermixAgent             the background agent launchd runs
  Sources/FermixBrowser           the WebKit browser behind the pane
  Tests/FermixAppCoreTests        swift-testing; run through script/swift_test.sh
engine/PIN.json                   which engine release the app ships
scripts/                          staging, signing, verification, release and dev-loop scripts
.github/workflows/                ci.yml (cask style), fermix-app.yml (PR gates),
                                  notarize.yml (reusable signing), release.yml (the rail)
Casks/                            Homebrew cask template, rendered at release
CHANGELOG.md                      the release notes, kept as the work lands
docs/design                       a link into the private docs repo: runbooks, SHIPPING.md, specs
```

## Testing locally with the latest engine

The dev loop builds the engine from a checkout of the
[fermix](https://github.com/tezra-io/fermix) repo, stages the app around it as a
separate development app (`Fermix Dev.app`, its own home at `~/.fermix-macos`,
port 4530), signs it and launches it. The installed Fermix app, its daemon and
its data are never touched.

You need: a `fermix` checkout, the Developer ID Application identity in your
login keychain (the loop refuses an ad-hoc signature, because macOS keys the
background agent on the Team ID), Elixir and Erlang for the engine build, and
either Xcode or the Command Line Tools with the macOS 26 SDK beside the 27 SDK
(the loop picks the right one).

```sh
# Once: give the loop its own engine worktree, on the engine ref you want to run.
git -C ~/projects/fermix fetch origin
git -C ~/projects/fermix worktree add ~/.cache/fermix-engine-m34 origin/main

# Each time: build the engine as that worktree stands, stage, sign and launch the app.
scripts/dev_e2e.sh up            # full engine build
scripts/dev_e2e.sh up --fast     # app only, reusing the built engine
scripts/dev_e2e.sh status        # what is running, and which engine commit
scripts/dev_e2e.sh down          # quit the app, unregister its agent, stop the engine
```

To run a different engine, move the worktree yourself and run `up` again:
`git -C ~/.cache/fermix-engine-m34 checkout --detach v0.14.0` for a release tag,
or `origin/dev` for the engine's tip. The loop never fetches, resets or moves
that checkout: it builds exactly what is there, uncommitted work included. Set
`FERMIX_REPO` if your checkout is not at `~/projects/fermix`.

The app opens on Chat; `open fermix-dev://settings/providers` and the other
`fermix-dev://` routes open a surface directly. `docs/design/E2E_RUNBOOK.md` is the full
acceptance session, and `docs/design/SHIPPING.md` the release plan.

## Building and the gates

```sh
cd Apps/Fermix
swift build                       # zero warnings is the bar
script/swift_test.sh              # the suite, with the paths Command Line Tools need
xcodegen generate                 # validates project.yml
```

On a Mac with only the Command Line Tools, whose default SDK is macOS 27, build
with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` and the
linker flags `-Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker 26.5`,
and give the test script the testing macros with
`script/swift_test.sh -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`;
the dev loop and CI do this for you. The full gate list before any PR is in
`AGENTS.md` under Working rules; `scripts/verify_protocol_contract.sh --source
<fermix checkout>` proves the vendored contracts are byte for byte the engine's,
and `scripts/check_vendor_marks.sh` compares the marks against the same checkout
at the pinned engine commit.

## Releasing

The app runs the engine it pins, never the newest engine. `AGENTS.md` under
"Cutting an app release" is the procedure; in short:

1. The engine releases first. Compare its wire exports since the pinned tag and
   re-vendor `Resources/Contracts` if they moved.
2. One chore PR on `dev`: move `engine/PIN.json` as a whole to the new release,
   bump `marketing_version` and `build_number` in `Product.json` and
   `project.yml`, regenerate `Info.plist` with `scripts/render_info_plist.sh`, and
   move the `CHANGELOG.md` entries under the new version heading. Prove it with
   `scripts/check_product_config.sh`, `scripts/fetch_engine.sh` and
   `scripts/verify_engine.sh` against the published engine release.
3. Open the PR from `dev` to `main`; merge on green.
4. A release owner pushes the tag `vX.Y.Z` on the merge commit (the
   `protected-release-tags` ruleset allows only that team). `release.yml`
   refuses a tag whose version has no changelog section, builds universal,
   signs, notarizes and staples, runs the Gatekeeper gate, pauses at the
   `release-macos` environment for approval, then publishes the GitHub Release
   with the DMG, its sha256, a cosign signature, the appcast and the cask, and
   opens the tap's cask PR.
5. Afterwards: mark the release latest, merge the tap PR, and put the release's
   `appcast.xml` into the site as `public/appcast.xml` on its `dev` branch. The
   app reads the feed at `https://fermix.ai/appcast.xml`.

Install a published release with:

```sh
brew install --cask tezra-io/tap/fermix
```

## Required repo secrets (release only)

`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`,
`MACOS_DEVELOPER_ID`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, scoped to
the `release-macos` environment. `HOMEBREW_TAP_TOKEN` lets the rail open the
cask PR on `tezra-io/homebrew-tap`.
