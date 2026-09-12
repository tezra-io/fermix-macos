# Stage 0 runbook

M34 section 1 calls Stage 0 "the smallest production-shaped signed artifact",
and its nine gates are evidence gates rather than architecture alternatives: a
failure stops implementation and reopens the affected identity, entitlement,
platform, or service decision. There is no unsigned, Burrito, alternate bundle
identifier, or reduced-architecture fallback to retreat to.

This runbook is the interactive hour that produces that evidence. Every command
here needs a human at a real Mac: a Developer ID certificate, an Apple notary
account, System Settings consent prompts, and a login-item registration. None of
it can run in CI, and none of it has run yet.

The evidence table it fills in is in
`/Users/sujshe/projects/fermix/docs/design/MILESTONE_34_UNIFIED_MACOS_APP_IMPLEMENTATION.md`,
under **Stage 0 evidence**.

---

## 0. Before you start

### 0.1 The rename has landed

`Product.json` declares `"app_bundle_name": "Fermix.app"`, and the bundle
identifier is deliberately still `io.tezra.FermixPet` because M34 gate 5 depends
on retaining it.

Gate 5 reads "retaining `io.tezra.FermixPet` preserves the existing microphone
grant **after renaming the app and executable to Fermix**", so there is now a
real rename for it to survive: the shipped pet installs `FermixPet.app` from the
`fermixpet` cask, this bundle installs `Fermix.app` from `fermix`, and both
carry the same identifier.

The gate names every file that has to move with the bundle name:

```sh
scripts/check_product_config.sh
```

Two files cannot read `Product.json` at the moment they need it, a shell glob
and a cask stanza, so the gate holds them to it:
`.github/workflows/release.yml` and `Casks/fermix.rb.tmpl`.
`Apps/Fermix/script/build_and_run_test.sh` asserts the same values and fails on
its own in CI.

**Do gate 5 with the old bundle still installed and the new bundle staged.**

### 0.2 What this artifact is, and is not

The bundle these scripts stage carries the GUI, the signed agent, the
LaunchAgents property list, the vendored wire contracts, and the assets. Its
`Contents/Resources/Engine` and `Contents/Resources/Tools` slots exist and are
**empty**: the plain arm64 and x86_64 engine trees and the bundled `cosign` are
not built yet.

That splits the nine gates cleanly:

| Gate | Needs the engine | Covered by this runbook |
|---|---|---|
| Plain arm64 engine launch | yes | no |
| Plain x86_64 engine launch | yes | no |
| Nested signing inventory | yes | no |
| Minimal ERTS entitlements | yes | no |
| Microphone grant continuity | no | yes, section 4 |
| Independent login registrations | no | yes, section 5 |
| Stable App Management principal | no | yes, section 6 |
| Duplicate-copy refusal | no | section 7, and it is blocked |
| Quarantined DMG acceptance | no | yes, section 8 |

`scripts/sign_app.sh` refuses any Mach-O it finds in those two slots, naming the
file, because signing an Elixir release tree correctly needs the entitlement
inventory the first four gates produce. That refusal is what keeps the two halves
from being confused for one another. It is proven by `scripts/sign_app_test.sh`.

### 0.3 Preconditions

- A Mac you can leave in a changed state. M34 section 7 requires a dedicated
  clean physical Mac with a reproducible reset protocol for acceptance, never the
  maintainer's daily account. Section 9 below is the reset.
- A Developer ID Application certificate in the login keychain. It must be the
  **same team** that signed the shipped FermixPet, or gate 5 cannot pass: TCC
  keys the microphone grant to the designated requirement, which contains the
  team identifier. The import steps for a Command Line Tools-only Mac (Apple's
  intermediate first, then the `.p12`) are in E2E_RUNBOOK.md under "Importing
  your Developer ID on this Mac".
- Notary credentials: `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.
- An existing FermixPet install with a granted microphone permission, for gate 5.
  If the machine has never run FermixPet, install the released cask first, grant
  the microphone, and confirm a voice call captures audio.
- Full Disk Access for Terminal, if you want the TCC database corroboration in
  section 4.2. The behavioral evidence in 4.1 does not need it.

### 0.4 Record as you go

Every gate below names what to record. Fill the M34 table in as you finish each
one rather than at the end. A gate with a Pass and no evidence string is not a
passed gate.

---

## 1. Build and stage the artifact

Universal2 staging needs `xcbuild`, which ships only with Xcode.app. On a
Command Line Tools machine the universal build fails with
`xcbuild executable ... does not exist`, and the local mode is `native`.

On a machine with Xcode.app:

```sh
cd /Users/sujshe/projects/fermix-macos
source scripts/product_config.sh
bundle="$(product_config app_bundle_name)"
artifact="${bundle%.app}"
stage="$(mktemp -d)"
scripts/stage_app.sh 0.1.0 1 "$stage/$bundle" universal
```

`$bundle` and `$artifact` are used by every command below, so keep this shell
open or re-run these four lines in each new one.

On a Command Line Tools machine, substitute `native` and record that the
artifact is single-slice. An x86_64 gate cannot be run from a native arm64
artifact.

`stage_app.sh` runs `scripts/verify_staged_app.sh` itself, so a layout problem
stops here. Its final block is the signing, architecture, entitlement, and
artifact inventory M34 section 7 requires. **Save that output.** It is the
evidence string for every gate that describes the artifact rather than the
system's reaction to it.

For a quick local look at the same bundle, ad-hoc signed and not launched:

```sh
scripts/dev_run.sh
```

That prints the `open` command rather than running it, and prints the engine
prerequisites from the fermix checkout's `docs/DEVELOPMENT.md`. Note that an
ad-hoc signature has no stable designated requirement, so it is useless for
gates 5 and 7: both are properties of a real Developer ID signature.

---

## 2. Sign with Developer ID

```sh
scripts/sign_app.sh "$stage/$bundle" "Developer ID Application: <Name> (<TEAMID>)"
scripts/verify_staged_app.sh "$stage/$bundle" universal signed
```

`sign_app.sh` signs inside out and never uses `--deep`: the nested resource
bundle first, then the agent, then the app with the hardened runtime, the single
`com.apple.security.device.audio-input` entitlement, and an explicit
`--identifier` so the seal carries the configured identity rather than the
bundle's name on disk. It then asserts the microphone entitlement is present on
the GUI, absent on the agent, and that `get-task-allow` is absent.

Record the designated requirement of both executables now, because gate 7 needs
them and they are cheapest to capture here:

```sh
codesign -d -r- "$stage/$bundle"
codesign -d -r- "$stage/$bundle/Contents/MacOS/FermixAgent"
```

Save both requirement strings verbatim.

---

## 3. Notarize, staple, and build the DMG

```sh
export MACOS_DEVELOPER_ID="Developer ID Application: <Name> (<TEAMID>)"
export APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_PASSWORD=...
scripts/package_release.sh 0.1.0 1
```

This runs the whole path: stage, sign, notarize and staple the app, build the
drag-to-Applications DMG, sign it, notarize and staple that, validate both, and
write `dist/<artifact>-0.1.0.dmg` plus its `.sha256`. Notarization is submit and
poll, bounded at 48 attempts of 150 seconds, so budget up to two hours in the
worst case and expect a few minutes in practice.

Record the DMG name, its sha256, and both notarization submission ids.

---

## 4. Gate: microphone grant continuity

Proves that renaming the app while retaining `io.tezra.FermixPet` keeps the
existing grant, so upgraders are not asked again.

### 4.1 Behavioral evidence, which is what the gate claims

1. Confirm the **old** FermixPet is installed and its microphone grant is
   present. In System Settings, Privacy and Security, Microphone, the row exists
   and is on.
2. Quit the old app. Do not remove its grant, do not run `tccutil`.
3. Install the new bundle from the DMG in the same location the old one occupied
   (`/Applications`).
4. Launch it and start a voice call.
5. **The gate passes if no microphone prompt appears and audio is captured.** A
   prompt means the designated requirement changed, which means the identifier,
   the team, or the certificate is not the one the grant was issued to.

Record: the old bundle name and version, the new bundle name and version, the
shared bundle identifier, whether a prompt appeared, and whether capture worked.

### 4.2 Corroboration, if Terminal has Full Disk Access

```sh
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, client_type, auth_value, datetime(last_modified,'unixepoch') \
   from access where client like '%FermixPet%';"
```

Run it before and after the replacement. The gate wants **one** row for
`kTCCServiceMicrophone` with `auth_value = 2`, and `last_modified` unchanged
across the replacement. A second row, or a bumped timestamp, means macOS treated
the new bundle as a new client.

### 4.3 If it fails

Stop. This reopens the bundle identifier decision, not the signing scripts.
Capture `codesign -d -r-` for both the old and the new bundle and diff the two
requirement strings: the difference is the answer.

---

## 5. Gate: independent login registrations

Proves `SMAppService.mainApp` and `SMAppService.agent` are two switches, and
that changing one never changes the other.

Register both from the app's Activate flow. Do not register anything by hand;
`ServiceController` is the only Swift owner of `SMAppService` mutation and the
gate is about what the product does.

```sh
# The system's own record of both principals.
sudo sfltool dumpbtm | grep -A 8 -i fermix

# The agent as launchd sees it.
launchctl print "gui/$(id -u)/io.tezra.FermixPet.agent"
```

Run this sequence, dumping after each step:

1. Both registrations enabled. Both records present, the agent job is loaded,
   and the daemon answers `daemon.sock`.
2. Disable **GUI login** only, from the app. The agent record is unchanged, the
   job is still loaded, and the daemon is still answering.
3. Re-enable GUI login. Disable the **background service** only, from the app.
   The GUI record is unchanged; the agent record is gone, the job is unloaded,
   the original daemon pid has exited, and `daemon.sock` is gone.
4. Re-enable the background service. Both back.

Record: the four `sfltool dumpbtm` extracts, the daemon pid before and after step
3, and confirmation that `daemon.sock` disappeared and returned.

The verb is Enable background service and Disable background service. If any
surface says Start or Stop, that is a section 4 defect, not a gate failure.

---

## 6. Gate: stable App Management principal across N to N+1

Proves that replacing the app does not mint a new TCC client, which is the
per-upgrade permission prompt that bit this project three times before.

The principal is the **signed agent**: it is what launchd starts, and the daemon
inherits its responsibility. The property that makes it stable is that its
designated requirement, not its path or cdhash, is what tccd keys on. An ad-hoc
or unsigned binary has no stable requirement, which is exactly why this gate can
only be run against a Developer ID signature.

1. Build and sign **N** and **N+1** into two directories, from the same source
   and the same identity, differing only in the build number:

   ```sh
   n="$(mktemp -d)"; n_next="$(mktemp -d)"
   scripts/stage_app.sh 0.1.0 1 "$n/$bundle" universal
   scripts/stage_app.sh 0.1.0 2 "$n_next/$bundle" universal
   scripts/sign_app.sh "$n/$bundle" "$MACOS_DEVELOPER_ID"
   scripts/sign_app.sh "$n_next/$bundle" "$MACOS_DEVELOPER_ID"
   ```

2. Capture the requirement of both agents:

   ```sh
   codesign -d -r- "$n/$bundle/Contents/MacOS/FermixAgent"
   codesign -d -r- "$n_next/$bundle/Contents/MacOS/FermixAgent"
   ```

   **They must be byte-identical.** A difference here fails the gate before the
   machine is touched.
3. Install N, register the background service, and let the daemon do something
   that needs App Management (or grant it once when asked).
4. Replace `/Applications/$bundle` with N+1 while the agent stays registered.
5. Relaunch. **The gate passes if no App Management prompt appears** and
   `sudo sfltool dumpbtm | grep -A 8 -i fermix` shows the same record rather than
   a second one.

Record: both requirement strings, both `CFBundleVersion` values, whether a
prompt appeared, and the dumpbtm extract after the replacement.

Note for the reset: a path-keyed TCC client cannot be reset individually
(`tccutil` answers OSStatus -10814); only a whole-service reset works. That is
the failure mode this gate exists to avoid, so if you see it, stop and record it.

---

## 7. Gate: duplicate-copy refusal

**This gate is blocked on implementation, not on evidence.**

M34 section 1 gate 9 requires that duplicate signed copies in `/Applications` and
`~/Applications` are detected and block activation instead of being selected
silently, and section 4 lists "Duplicate Fermix or FermixPet app copies" as a
migration-discovery state owned by `MigrationCoordinator`.

`MigrationCoordinator` has not been built. `ActivationCoordinator` reaches eight
named causes (`timedOut`, `approvalPending`, `backgroundItemDisabled`,
`incompatibleVersion`, `crashLoop`, `bindFailure`, `webUnavailable`,
`invalidPackage`) and none of them is a duplicate copy. There is no refusal to
witness.

What is worth doing in this hour is capturing the current behavior as the
baseline the implementation has to change:

```sh
cp -R "/Applications/$bundle" "$HOME/Applications/$bundle"
open -n "$HOME/Applications/$bundle"
# then, separately:
open -n "/Applications/$bundle"
```

Record which copy the menu bar item belongs to, which copy `sfltool dumpbtm`
attributes the registration to, and whether the microphone grant follows one copy
or both. Two copies sharing `io.tezra.FermixPet` fighting over one grant is the
documented FermixPet failure this gate generalizes.

Then remove the second copy before continuing.

Leave the M34 row as **Pending**, with the evidence column recording that the
detection does not exist yet. Do not record a Fail: nothing was tested and found
wanting.

---

## 8. Gate: quarantined DMG acceptance

Proves Gatekeeper accepts the artifact a user actually downloads. A headless
`spctl` never sees quarantine, so it has to be applied deliberately.

```sh
dmg="dist/$artifact-0.1.0.dmg"

# Simulate a browser download.
xattr -w com.apple.quarantine "0081;$(date +%s);Safari;$(uuidgen)" "$dmg"

# The disk image itself, assessed as an opened download.
spctl -a -t open --context context:primary-signature -vv "$dmg"

# The app inside it, assessed as an executable.
mp="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -mountpoint "$mp"
spctl -a -t exec -vv "$mp/$bundle"

# The stapled tickets, which is what makes first launch work offline.
xcrun stapler validate "$dmg"
xcrun stapler validate "$mp/$bundle"

hdiutil detach "$mp"
```

Both `spctl` calls must print `accepted` with `source=Notarized Developer ID`.

This is the same sequence `.github/workflows/notarize.yml` runs on the release
runner, so a green release job is corroboration, not a substitute: the gate is
about this machine's Gatekeeper accepting this artifact.

Record: both `spctl` verdicts verbatim, both stapler validations, and the DMG
sha256 they were run against.

---

## 9. Reset protocol

Run this between gates that need a clean starting state, and at the end. M34
section 7 requires it to be checked in beside the release scripts; it is written
out here until it is a script.

```sh
# 1. Disable the background service from the app's own control, so the
#    registration is withdrawn rather than orphaned.
#    Dragging the app to the Trash cannot do this: macOS keeps the Login Items
#    row and there is no bundle left to unregister it.

# 2. Confirm both registrations are gone.
sudo sfltool dumpbtm | grep -i fermix || echo "no records"

# 3. Remove every copy of the app.
rm -rf "/Applications/$bundle" "$HOME/Applications/$bundle"

# 4. Remove the bootstrap record and the CLI symlink the app created.
rm -f "$HOME/Library/Application Support/Fermix/launcher.json"
ls -l /usr/local/bin/fermix /opt/homebrew/bin/fermix 2>/dev/null

# 5. Remove the test Fermix home. NEVER point this at ~/.fermix on a machine
#    that carries real data.
rm -rf "$HOME/.fermix-stage0"

# 6. Last resort only, if a registration survives with no bundle to withdraw it.
#    This clears every app's background-item state, not just Fermix.
# sudo sfltool resetbtm
```

The microphone grant is deliberately **not** reset here: gate 5 depends on it
surviving. Reset it only when you are done with section 4, and only for the one
identifier:

```sh
tccutil reset Microphone io.tezra.FermixPet
```

---

## 10. Filling in the M34 table

Open
`/Users/sujshe/projects/fermix/docs/design/MILESTONE_34_UNIFIED_MACOS_APP_IMPLEMENTATION.md`
and edit the **Stage 0 evidence** table under section 1.

| Column | What goes in it |
|---|---|
| Gate | Leave as it is. |
| Result | `Pass`, `Fail`, or `Pending`. Only these three. |
| Evidence | The captured artifact: a requirement string, an `spctl` verdict, a dumpbtm extract, a sha256, or "no prompt appeared, capture worked". Not a description of having looked. |
| Decision impact | Empty on a pass. On a fail, the identity, entitlement, platform, or service decision this reopens. |

The four engine gates stay `Pending` after this hour, and their evidence column
should say why rather than staying blank: the engine trees are not built and the
signing inventory does not exist.

M34 is explicit that a failure stops implementation and reopens only the affected
decision. If a gate fails, record it, stop, and reopen that decision. Do not sign
around it, do not widen a gate to make it pass, and do not proceed to the next
one on the assumption that it is unrelated.
