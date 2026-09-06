# Shipping the Fermix macOS app

How a person gets the app from fermix.com onto a Mac, what CI already does, what is missing, and the order it lands in. The order is M34 section 7 of the engine's implementation spec; this document is the operational view of it as of 2026-09-06.

## What exists today

**The app release rail, in this repository.** Pushing a tag `fermixpet-vX.Y.Z` runs `release-fermixpet.yml`, which calls `notarize.yml` inside the protected `release-macos` environment and then publishes:

1. `scripts/package_release.sh`: universal2 build, `stage_app.sh`, Developer ID signing inside out (`sign_app.sh`), notarization by submit and poll, two-pass stapling, a drag-to-Applications DMG, and `verify_staged_app.sh universal signed release`.
2. A Gatekeeper quarantine-acceptance gate on the stapled DMG.
3. A GitHub Release carrying the DMG, its sha256, a keyless cosign signature and certificate, and the rendered Homebrew cask; a smoke install of that cask from a scratch tap; a pull request against `tezra-io/homebrew-tap` when `HOMEBREW_TAP_TOKEN` is set.

So the answer to "does CI build the app and the file people download" is yes: the DMG is the download, and it is signed, notarized and stapled, which is what makes it open without a warning on a Mac that has never seen Fermix.

**What that rail does not do yet.**

- It stages an empty engine slot. `package_release.sh` calls `stage_app.sh` without `--engine`, so the DMG it produces today is an app with no engine inside. A user who installs it has nothing to run.
- The bundle is still `FermixPet.app`, the cask is still `fermixpet`, and the tag namespace is `fermixpet-v*`.
- There is no update channel. Sparkle (spec section 6) is unbuilt: no feed URL, no signing key, no appcast.
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

### 3. The bundle becomes `Fermix.app` and the cask becomes `fermix`

Spec step 8 puts this in the first public release, and nothing public depends on the old name except the pet cask, so doing it now avoids a second migration later:

- `Product.json` `app_bundle_name` becomes `Fermix.app`; the identifier `io.tezra.FermixPet` and the agent label stay, so the microphone and App Management grants and the login item carry over.
- A third executable target stages a universal `fermix` launcher beside the app and agent, and the staged-executable gate becomes three named entries.
- The unified cask: `app` stanza, `binary` stanza linking `fermix` onto `PATH`, an early `uninstall` running the bundle's own unregister entry point, and a `zap` naming the Fermix home. The `fermixpet` token moves to the tap's migrations file. Decide the macOS floor policy for the pet cask before the token moves (frozen terminal release for pre-Sequoia, or a raised floor shipped with a caveat first).
- The tag namespace becomes `app-vX.Y.Z` with its own protected ruleset, and the workflow is renamed to match. The DMG artifact becomes `Fermix-<version>.dmg`.

### 4. Updates

A person who downloads a DMG has no `brew upgrade`. Without an update channel they never learn a newer build exists, so Sparkle belongs in the first public release rather than the second:

- Generate the EdDSA key pair once; the private key lives in the `release-macos` environment with a backup and a written rotation procedure; the public key is embedded in Info.plist.
- A fixed HTTPS feed URL under our domain, `https://fermix.com/appcast.xml`, baked into the app from release one, because the feed URL cannot change once a build is in the wild.
- The release job generates the appcast entry from the notarized DMG and publishes it only after the DMG and the acceptance evidence are live. The appcast is a few kilobytes and is served by the site as a static asset.
- The spec's update transaction (section 6: the journal, the reconcile after a failed update) is the app-side half. If it is not ready for release one, ship Sparkle's own flow and add the journal in the next release; either way the feed exists from day one.

### 5. Acceptance on a clean Mac

`docs/STAGE0_RUNBOOK.md` sections 4 to 8, on a Mac or account that has never run the app: fresh install and onboarding; a Homebrew install adopted in place by the app (the migration path, which is tomorrow's test); a signed N to N+1 update with the microphone and App Management grants intact; the duplicate-copy refusal; the quarantined DMG opening clean; uninstall. The evidence goes into the M34 table.

### 6. Publish

Push the tag. CI produces the DMG, its checksum and signature, the cask and the appcast entry. Mark the GitHub Release as latest, merge the tap pull request, then publish the appcast, then the site.

### 7. The site

- A download page at `fermix.com/download` with one button, "Download for Mac", requirements (macOS 15 or later, Apple silicon and Intel in one file), the sha256 and how to check it, and the two alternatives: `brew install --cask tezra-io/tap/fermix`, and for an existing Homebrew install, that the app adopts it in place.
- The button points at `https://fermix.com/download/macos`, a route the site's Worker answers with a redirect to the pinned release asset on GitHub. The URL on the page never changes, the release assets stay immutable, and moving people to a new version is a one-line change in the site's config, deployed with the site. The Worker is already the site's runtime, so this is a route, not new infrastructure.
- The docs pages that mention FermixPet (installation, distribution and upgrade, realtime voice) change to the app, its cask and the adoption of a brew home; the `fermix-site-docs` skill carries the routing table and the writing rules.
- The bytes stay on GitHub Releases: free, on a CDN, and already the artifact of record with a cosign signature. If we later want the download to stay on our domain end to end, a Cloudflare R2 bucket behind `download.fermix.com` mirrors the same file at about a cent and a half per gigabyte a month with no egress charge; nothing in the plan above changes except the redirect target.

## Decisions to take

| Decision | Recommendation |
| --- | --- |
| Rename to `Fermix.app` in the first public release | Yes. Nothing public depends on the old name except the pet cask, which migrates once. |
| Sparkle in the first public release | Yes. A DMG user without a feed never learns about updates. The journal can follow. |
| Pet cask macOS floor policy | Freeze the pet cask as a terminal release for pre-Sequoia Macs; the unified app has a macOS 15 floor. |
| Where the bytes live | GitHub Releases now, behind a `fermix.com/download/macos` redirect. R2 mirror later if wanted. |
| App version | Its own marketing version, starting at 1.0.0 with the rename. The app shows the engine's build separately. |

## Effort, roughly

| Step | Size |
| --- | --- |
| Engine merge and release | A working session for the merge, then the normal release |
| Engine pin, download and verification in packaging | One slice, with harness rows in `verify_staged_app_test.sh` |
| Rename, launcher, cask, migration, tag namespace | One to two slices |
| Sparkle feed, keys, appcast job | One to two slices; the update journal is a third if it ships in release one |
| Site download page, redirect route, docs | One slice |
| Clean-Mac acceptance | A day, by hand, with the runbook |
