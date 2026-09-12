# Shipping the Fermix macOS app

How a person gets the app from fermix.ai onto a Mac, what CI already does, what is missing, and the order it lands in. The order is M34 section 7 of the engine's implementation spec; this document is the operational view of it as of 2026-09-06.

## What exists today

**The app release rail, in this repository.** Pushing a tag `vX.Y.Z` runs `release.yml`, which calls `notarize.yml` inside the protected `release-macos` environment and then publishes:

1. `scripts/package_release.sh`: universal2 build, `stage_app.sh`, Developer ID signing inside out (`sign_app.sh`), notarization by submit and poll, two-pass stapling, a drag-to-Applications DMG, and `verify_staged_app.sh universal signed release`.
2. A Gatekeeper quarantine-acceptance gate on the stapled DMG.
3. A GitHub Release carrying the DMG, its sha256, a keyless cosign signature and certificate, and the rendered Homebrew cask; a smoke install of that cask from a scratch tap; a pull request against `tezra-io/homebrew-tap` when `HOMEBREW_TAP_TOKEN` is set.

So the answer to "does CI build the app and the file people download" is yes: the DMG is the download, and it is signed, notarized and stapled, which is what makes it open without a warning on a Mac that has never seen Fermix.

**What that rail does not do yet.**

- It stages an empty engine slot. `package_release.sh` calls `stage_app.sh` without `--engine`, so the DMG it produces today is an app with no engine inside. A user who installs it has nothing to run.
- The update feed is not published. The app carries the feed URL and the public key, and the release rail signs the DMG and attaches the merged `appcast.xml` to the release (section 4), but nothing copies that file to the site yet.
- The engine is not pinned in this repository. The dev loop passes a locally built tree.

**The engine release rail, in the fermix repository.** On `feat/m34-management-v2` the release workflow gained an `app-engine` job: it builds `fermix_app_engine_<target>.tar.gz` for `macos_aarch64` (macos-15) and `macos_x86_64` (macos-15-intel), cosign-signs and sha256s them beside the formula binaries, and publishes them as assets of the same tag. That branch is pushed and not yet merged into `dev`, so no engine release carries those assets yet.

**The site.** `fermix-site` is Astro on Cloudflare Workers (`wrangler deploy`). The docs mention the FermixPet cask and the GitHub release DMG; there is no download page. Workers static assets are limited to 25 MiB per file, so the DMG, which will be well over 100 MB with two engine architectures inside, cannot be served by the site itself. The site links to the bytes; it does not host them.

## The order

The daemon ships first, always: a released daemon cannot answer the app's `hello` until it has been restarted onto a build that speaks protocol 2, and the app refuses an engine outside its window.

### 1. The engine lands on `dev` and releases

- Merge `feat/m34-management-v2` into `dev`. The base branch carries nine commits `dev` never received, and a trial merge shows about 26 conflicting hunks against the 13 newer `dev` commits, so this is a sit-down merge, not a button.
- Re-pin compux to a released 0.7.4 that carries protocol 6 (the current pin is an unreleased commit, which is why computer use refuses with a protocol mismatch).
- Cut the formula release. Its assets now include the two app-engine trees, cosign-signed, from the same tag and commit as the formula binaries. Brew users upgrade and restart onto protocol 2 before any app exists.

### 2. The app pins that engine

- Add an engine pin to this repository: the fermix tag, the source commit, the protocol window, and the sha256 of each architecture's tree. One file, checked in, changed by a deliberate commit.
- `package_release.sh` downloads both trees from that tag's release, verifies each sha256 and the cosign signature against the release workflow's identity, extracts them, and passes `--engine` twice to `stage_app.sh`. `verify_staged_app.sh universal signed release` already asserts, for a populated slot, that every tree carries the pinned product version and source commit, that both architectures share one commit, and that the engine serves the protocol the app speaks.
- The PR staging dry run stages the pinned engine too, so a pin that drifts from the contract fails on the pull request rather than at release time.

### 3. The bundle becomes `Fermix.app` and the cask becomes `fermix` (done)

Spec step 8 puts this in the first public release, and nothing public depends on the old name except the pet cask, so doing it now avoids a second migration later:

- `Product.json` carries `app_bundle_name` `Fermix.app` and `icon_file` `Fermix`; the identifier `io.tezra.FermixPet` and the agent label stay, so the microphone and App Management grants, the login item and the coexistence preflight carry over. Every script that names the bundle reads it from there, and the two files that cannot read it at the moment they need it — `release.yml` and the cask template — are gated against it by `check_product_config.sh`.
- The cask is `Casks/fermix.rb.tmpl`: token `fermix`, `app "Fermix.app"`, `depends_on macos: :sequoia`, an `early_script` uninstall running the bundle's own `--unregister-login-items` entry point before `quit`, and a `zap` naming the Fermix home, the bootstrap record and the cache. `early_script` rather than `script` because Homebrew runs uninstall directives in a fixed order and only that one runs before `quit`.
- The tag namespace is plain `vX.Y.Z`, as in the engine repository, and the workflow is `release.yml`. The DMG artifact is `Fermix-<version>.dmg`. The protected-tag ruleset has to name `v*` before the first tag is pushed, and the branch protection on `main` names the cask check, which is now "Fermix cask (style)".

Two pieces are deliberately deferred, and neither blocks a release:

- **The `fermix` command-line launcher and the cask's `binary` stanza.** A third executable target staging a universal `fermix` beside the app and the agent, and the staged-executable gate becoming three named entries, are a later release. Until then the cask links nothing onto `PATH`.
- **Retiring the `fermixpet` token.** That is a change in `tezra-io/homebrew-tap`, carried by the tap pull request rather than by anything here: the old token moves to the tap's migrations file so an existing install upgrades onto `fermix`. Decide the macOS floor policy for the pet cask before the token moves (freeze it as a terminal release for pre-Sequoia Macs, or raise its floor behind a caveat first).

### 4. Updates

A person who downloads a DMG needs a reliable way to discover future fixes. The first public macOS release accompanying core 0.10.0 must include update discovery and safe, user-initiated installation.

**What the rail does now.** The public key and the feed URL are rendered into Info.plist from `Product.json`. The private key is `SPARKLE_ED_PRIVATE_KEY` in the protected `release-macos` environment, which only the notarize job can read, and `notarize.yml` refuses before it builds anything if the secret is unset.

1. After stapling and the Gatekeeper gate, `notarize.yml` mounts the published DMG, signs those exact bytes with `sign_update --ed-key-file -`, and writes `appcast-item.xml` through `scripts/appcast.py item`. The key goes from the environment into the script's standard input, so it is never an argument, a file, or an echo. Every value in the item is read from the artifact rather than configured: the marketing version, build number and system floor from the mounted app's Info.plist, the engine build and product version from the engine trees' own manifests, the signing authority from `codesign`, the sha256 from the DMG bytes, and the signature and byte length from `sign_update`. The item is uploaded as its own artifact.
2. The publish job merges that item into the cumulative feed with `scripts/appcast.py merge`, before the release is created, so a refusal publishes nothing. It lists the newest app release's assets first, which makes "the previous release carries no `appcast.xml`" a declared state rather than a download whose failure reads as no updates; the first Sparkle release starts the feed. The merge refuses a build number that is not strictly greater than every build already published, and a marketing version that is already in the feed.
3. `appcast.xml` and `appcast-item.xml` are attached to the release. The feed carries every earlier item forward because the app refuses an update unless the feed also describes the build that is installed, and the next release merges onto this release's own asset.
4. `scripts/appcast_test.sh` fires every one of those refusals offline, against hand-made bundles with a stubbed `sign_update` and `codesign`, and parses the produced feed back to check the four `fermix:` elements, Sparkle's own fields and the enclosure against the values that went in. No signing key is involved, so it runs anywhere.

**What remains.**

- Publishing the feed is by hand: copy the release's `appcast.xml` to `fermix-site` `public/appcast.xml` and deploy. The release prints a notice naming that step. A future feed migration must keep the old endpoint available so installed clients can reach the release containing the new URL. [Sparkle feed migration](https://sparkle-project.org/documentation/publishing/#upgrading-to-newer-features)
- Key custody. The private key needs an offline backup and a written rotation procedure. Losing it ends update discovery for every client that already trusts the public key, and there is no second path to those Macs.
- Test through an isolated feed before promoting the accepted artifact and metadata to production. Nothing in CI decides that a release is critical either: `appcast.py item --critical` writes `sparkle:criticalUpdate` and no workflow passes it, so marking one needs a deliberate maintainer input first.
- The R3 installation boundary is still the release decision. The app journals the update, stops its engine at the extraction barrier and recovers an interrupted update before ordinary UI, which is the half that had to ship in release one: a coordinator introduced in the next binary cannot protect its own installation. What is not proved is that a failed shutdown prevents replacement on every permitted Sparkle path, because the pinned delegate has no asynchronous veto before installer arming and the postponed-relaunch callback alone cannot provide that guarantee. [Sparkle delegate contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)

If safe installation is not ready, explicitly reduce scope to informational updates linking to the signed DMG, with a tested manual-upgrade procedure, or defer the macOS release. Do not ship unrestricted installation and defer its safety work to release two. Production key custody, feed publication, and signed update acceptance remain release work; passing unit tests does not complete them.

### 5. Acceptance on a clean Mac

`docs/STAGE0_RUNBOOK.md` sections 4 to 8, on a Mac or account that has never run the app: fresh install and onboarding; a Homebrew install adopted in place by the app (the migration path, which is tomorrow's test); a signed N to N+1 update with the microphone and App Management grants intact; the duplicate-copy refusal; the quarantined DMG opening clean; uninstall. The evidence goes into the M34 table.

### 6. Publish

Push the tag `vX.Y.Z`. CI produces the DMG, named `Fermix-<version>.dmg`, its checksum and cosign signature, the rendered cask, the signed appcast item and the merged cumulative feed, and attaches all of them to the release. Then, by hand and in this order: mark the GitHub Release as latest, merge the tap pull request, copy the release's `appcast.xml` to `fermix-site` `public/appcast.xml` and deploy the site, then the download page. The feed goes after the release is marked latest and the tap has the cask, because publishing it is the moment installed clients start being offered the release.

### 7. The site

- A download page at `fermix.ai/download` with one button, "Download for Mac", requirements (macOS 15 or later, Apple silicon and Intel in one file), the sha256 and how to check it, and the two alternatives: `brew install --cask tezra-io/tap/fermix`, and for an existing Homebrew install, that the app adopts it in place. The old `fermixpet` token keeps working until the tap's migration lands, and reads as the pet cask until then.
- The button points at `https://fermix.ai/download/macos`, a route the site's Worker answers with a redirect to the pinned release asset on GitHub. The URL on the page never changes, the release assets stay immutable, and moving people to a new version is a one-line change in the site's config, deployed with the site. The Worker is already the site's runtime, so this is a route, not new infrastructure.
- The docs pages that mention FermixPet (installation, distribution and upgrade, realtime voice) change to the app, its cask and the adoption of a brew home; the `fermix-site-docs` skill carries the routing table and the writing rules.
- The bytes stay on GitHub Releases: free, on a CDN, and already the artifact of record with a cosign signature. If we later want the download to stay on our domain end to end, a Cloudflare R2 bucket behind `download.fermix.ai` mirrors the same file at about a cent and a half per gigabyte a month with no egress charge; nothing in the plan above changes except the redirect target.

## Decisions to take

| Decision | Recommendation |
| --- | --- |
| Rename to `Fermix.app` in the first public release | Yes. Nothing public depends on the old name except the pet cask, which migrates once. |
| Sparkle in the first public release | Discovery and safe installation, including the journal and recovery. Discovery-only requires an explicit scope decision. |
| Pet cask macOS floor policy | Freeze the pet cask as a terminal release for pre-Sequoia Macs; the unified app has a macOS 15 floor. |
| Where the bytes live | GitHub Releases now, behind a `fermix.ai/download/macos` redirect. R2 mirror later if wanted. |
| App version | Its own marketing version, 0.1.0 with the rename. The app shows the engine's build separately. |

## Effort, roughly

| Step | Size |
| --- | --- |
| Engine merge and release | A working session for the merge, then the normal release |
| Engine pin, download and verification in packaging | One slice, with harness rows in `verify_staged_app_test.sh` |
| Rename, launcher, cask, migration, tag namespace | One to two slices |
| Sparkle feed, keys, appcast job, safe installation and recovery | Required before release; estimate after resolving the installer boundary and signed acceptance coverage |
| Site download page, redirect route, docs | One slice |
| Clean-Mac acceptance | A day, by hand, with the runbook |
