# Fermix app e2e session runbook

One sitting, roughly two hours hands-on. It chains three things in order: the
signed-artifact build (now with the engine inside), the Stage 0 evidence gates
(`docs/STAGE0_RUNBOOK.md` owns their detail), and the full product journey.
Yesterday's smoke test covered the UI shell against an external engine; this
session is the real thing — signed app, embedded engine, real activation, real
TCC prompts.

Record everything in the M34 Stage 0 evidence table as you go
(`~/projects/fermix/docs/design/MILESTONE_34_UNIFIED_MACOS_APP_IMPLEMENTATION.md`).

**Just want the dev loop?** That is one command, not this document:
`scripts/dev_e2e.sh up` builds the engine from your own worktree at
`~/.cache/fermix-engine-m34` exactly as it stands (uncommitted work included —
it neither syncs nor resets it, and refuses if it is not there), stages the app
as a debug build, signs it with the one Developer ID Application identity in
your login keychain, points it at the `~/.fermix-macos` dev home, then opens the
app through Launch Services with `--development-engine
--register-background-service`. The opened GUI registers the bundled background
agent on port 4530 through its normal lifecycle; a separate maintenance process
is not used for startup. Manual launches with only `--development-engine` do not
enable the background service. Once the engine passes its health check, the
script reopens the existing GUI to refresh Home.
The port is written into the development agent's plist before signing, so
Restart in the app returns on the same port. `down`
unregisters that agent before stopping the engine and restoring the original
bootstrap record. `up` refuses services belonging to another app bundle before
building or changing anything; it unregisters its own old agent before replacing
the bundle. `status` tells the truth,
including which branch the engine is built from, which identity signs, and
whether the running app actually carries the flag. This runbook is for the
Stage 0 acceptance session below.

**Why the dev loop signs with your Developer ID and never ad hoc.** The
background agent is registered through SMAppService, and macOS keys that
registration on the Team ID of the code it registered: the launch constraint
launchd keeps for the agent and the bundle the agent is looked up in both derive
from it. An ad-hoc signature carries no Team ID, so its only identity is the
cdhash of one build; every rebuild is a different program to the constraint
launchd kept (AMFI "Launch Constraint Violation", the agent dies at spawn), and
once the bundle directory has been replaced the retained item cannot find its
bundle at all (exit 78, "The specified path is not a bundle"). Both were
observed on every rebuild on 2026-09-05; the analysis is
`docs/design/M34_MACOS_APP_RCA_2026-09-05.md`. `up` therefore refuses without
exactly one Developer ID Application identity (import it as STAGE0_RUNBOOK §0
says; no notarization is needed for a local launch). One-time step after the
ad-hoc era on a Mac that ran the old loop: reset Background Task Management
once so no item derived from an ad-hoc build is reused, `sudo sfltool resetbtm`
followed by a restart of the Mac, then `up`.

**Importing your Developer ID on this Mac, once.** The release workflow imports
the same certificate into a throwaway keychain from its secrets
(`scripts/keychain.sh`); locally it lives in your login keychain. You need the
`.p12` that bundles the Developer ID Application certificate with its private
key (the file the `MACOS_CERT_P12_BASE64` secret was made from) and its
password. Keep the folder you made it in; on this Mac that is `~/apple_cert`.

1. Install Apple's Developer ID intermediate certificate. Xcode installs it;
   Command Line Tools never do, and without it the identity imports but
   `find-identity -v` calls it invalid and reports zero identities:

   ```sh
   curl -O https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
   security import DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db
   ```

2. Import the identity and let `codesign` use its key:

   ```sh
   security import cert.p12 -f pkcs12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
   ```

   It asks for the `.p12` password. If you only have the certificate and the
   key as separate PEM files, make the `.p12` first:
   `openssl pkcs12 -export -inkey developer_id.key -in developer_id.pem -out cert.p12`.

3. Check:

   ```sh
   security find-identity -v -p codesigning
   ```

   must print `1 valid identities found` with one
   `Developer ID Application: <Name> (<TEAMID>)` line. If it prints zero but
   the same command without `-v` lists the identity, step 1 is missing. Two
   identities make the dev loop refuse; delete the one you do not release with
   in Keychain Access.

4. The first signature may show a dialog asking whether `codesign` may use the
   key; choose Always Allow. Signing with a real identity also requests a
   secure timestamp from Apple, so the Mac must be online for `up`.

5. If this Mac ever ran the ad-hoc loop, reset Background Task Management once
   as described above (`sudo sfltool resetbtm`, restart).

6. `scripts/dev_e2e.sh up`. Its last lines print `signed  Developer ID
   Application: …`, and
   `codesign -dvv Apps/Fermix/dist-e2e/FermixPet.app/Contents/MacOS/FermixAgent`
   shows `TeamIdentifier=<TEAMID>`. From now on every rebuild keeps the same
   identity, so registrations, restarts and the microphone grant survive it.

Each development rebuild also gets a new `CFBundleVersion`, calculated before
the old bundle is replaced: the greater of its previous build number plus one
and the current UTC epoch seconds. Rebuilds within the same second still advance;
an invalid previous build number is refused. Production versioning is unchanged.

## 0. Decide before starting

1. **Bundle file name** — STAGE0_RUNBOOK §0.1. The staged bundle still ships as
   `FermixPet.app` (deliberate, gated); gate 5 is meaningless until the rename
   decision is made. Decide it first.
2. **Which account runs the journey.**
   - **Path A (recommended): a fresh macOS test account** on this Mac. Closest
     honest stand-in for a clean machine: its own `~/.fermix`, its own
     SMAppService registrations, mostly its own TCC rows. Create it in System
     Settings → Users & Groups before starting.
   - **Path B: your own account via `fermix migrate-to-app`.** This is the real
     brew-user migration e2e — it drains and retires your live Telegram daemon's
     launchd unit. Bigger, and your daemon stays down until you restore it.
     Recommended only after Path A has passed once.
3. **The port conflict is real either way**: the engine binds `127.0.0.1:4030`,
   which your live daemon owns machine-wide. For Path A, stop the live daemon
   for the session (`fermix stop` from your account; restore afterwards with
   `fermix start`). Telegram is down while it is stopped — pick your window.
4. Have ready: your Developer ID identity (`security find-identity -p
   codesigning -v`), notarytool credentials (STAGE0 §3), one provider API key
   or a ChatGPT/Claude login for setup, and about 3 GB free disk.

## 1. Build the artifact with the engine inside

From `~/projects/fermix` (the engine; use a real commit once the M34 tree is
committed — the all-zero marker is fine for a local session, refused by
release automation):

```bash
# Compile-time identity literals: deleting the beam is the reliable
# invalidation (a touch is not — proven 2026-08-21); only _build/prod is affected.
rm -f _build/prod/lib/fermix_core/ebin/Elixir.FermixCore.BuildInfo.beam
FERMIX_BUILD_ID=e2e-$(date +%Y%m%d) \
FERMIX_BUILD_SOURCE_COMMIT=0000000000000000000000000000000000000000 \
FERMIX_BUILD_DISTRIBUTION=macos_app \
FERMIX_BUILD_TARGET=macos_aarch64 \
MIX_ENV=prod mix release fermix_app_engine --overwrite
rm -f _build/prod/lib/fermix_core/ebin/Elixir.FermixCore.BuildInfo.beam   # next prod build re-derives its identity
```

From `~/projects/fermix-macos` (stage with the engine and the bundled cosign,
sign, verify — `native` covers this Apple-silicon session; `universal` is the
release shape):

```bash
scripts/stage_app.sh 0.1.0 1 Apps/Fermix/dist/FermixPet.app native \
  --engine ~/projects/fermix/_build/prod/rel/fermix_app_engine \
  --cosign "$(which cosign)"
scripts/sign_app.sh Apps/Fermix/dist/FermixPet.app "Developer ID Application: <You> (<TEAMID>)"
scripts/verify_staged_app.sh Apps/Fermix/dist/FermixPet.app native signed
```

Then STAGE0_RUNBOOK §3: notarize, staple, DMG, quarantined Gatekeeper gate.

## 2. The entitlement discovery ladder — two rungs already climbed

`scripts/entitlements/engine.entitlements` was climbed empirically on
2026-08-21 under the AD-HOC identity (each rung observed as a real failure
first; comments in the file carry the evidence):

- Rung 1, **keep**: `allow-unsigned-executable-memory` — BEAM's JIT failed
  W+X allocation without it.
- Rung 2, **retry without under Developer ID**: `disable-library-validation`
  — NIF dlopen refused with "different Team IDs", which ad-hoc signatures
  cause by carrying no team. Your Developer ID signs everything with one
  team, so this session FIRST removes that key, re-signs, and relaunches; it
  goes back only if the load still fails, and the outcome either way is the
  gate-3 record.

Any further failure: add exactly one observed key, `sign_app.sh` again (it
re-signs the whole engine class), relaunch, record.

Verified working ad-hoc end to end already: agent → embedded engine → live in
about 2 seconds → management `hello` reports the build id and `macos_app` —
and `epmd -names` stays EMPTY (the engine release now pins
`RELEASE_DISTRIBUTION=none`; a populated epmd during the session means a
stray engine is running). Verify all three the same way after the signed
build.

## 3. Stage 0 gates

Run STAGE0_RUNBOOK §§4–8 in order (mic-grant continuity, independent login
registrations, stable App Management principal across N→N+1, duplicate-copy
refusal — record `Pending, unimplemented` per its note — and quarantined DMG
acceptance). Gates 1–2 (engine launch per arch) are satisfied by this
session's §1 artifact plus the CI x86_64 leg.

## 4. The product journey (the e2e itself)

In the test account, with the DMG installed to `/Applications`:

| Step | Expect | Evidence |
|---|---|---|
| First launch | Welcome renders; Dock icon while the window is open | screenshot |
| Set up Fermix | Activate ladder runs for real: service registered → daemon starting → preparing; macOS shows the background-item notification | screenshot + `sfltool dumpbtm` row |
| Engine boot | `~/.fermix` created by the engine; `daemon.sock` appears; `/health/live` answers on 4030 | `curl 127.0.0.1:4030/health/live` |
| Configure | Hosted Setup loads (one-use session); OAuth hands off to the browser; provider saved | screenshot |
| Ready | Requires the provider; pet moment plays; CLI row unchecked with copyable command | screenshot |
| Home | Running state, uptime, Runtime/Attention populated from the live daemon | screenshot |
| Doctor | Local checks run against the daemon; network scope only behind its button | output |
| Logs | Live entries, filters, pause, load older | eyeball |
| Pet + voice | Mic prompt fires at first voice start, not before — the JIT rule | screenshot of prompt |
| Close window | Menu-bar-only (bolt stays); Dock icon leaves; daemon keeps answering | `curl` again |
| Quit GUI | Daemon still answers (GUI quit is never a daemon command) | `curl` again |
| Relaunch + login toggles | Both toggles independent; disable each, verify the other holds | Settings pane |
| Disable background service | Drain → unregister → socket released; Home shows the disabled state truthfully | `ls ~/.fermix/daemon.sock` |
| Uninstall | `--unregister-login-items`, then trash; data survives in `~/.fermix` | `sfltool dumpbtm` |

Anything that deviates: screenshot it, note it in the M34 log, keep moving —
tomorrow is for evidence, fixes come after.

## 5. Restore

- Your account: `fermix start` (the live daemon returns; check Telegram).
- Test account: leave it for the next session, or delete it in Users & Groups.
- The signed `/Applications` copy can stay for N→N+1 update testing later —
  that is the next session's artifact, not garbage.

## Custom dev home (no code, one record)

For dev testing you can point the whole app — GUI, agent, and engine — at a
separate home. The production bootstrap record IS the configuration surface;
there is no env var or flag to maintain:

```bash
printf '{"fermix_home":"/Users/sujshe/.fermix-macos","schema_version":1}' \
  > ~/Library/Application\ Support/Fermix/launcher.json
```

Activation confirms a recorded home rather than replacing it (`~/.fermix` is
only the fresh-account default), and the engine's first boot creates the
folder. Delete the record to return to defaults. The production agent still
binds port 4030; the dev loop alone stages a `PORT=4530` environment value in
its bundled agent plist.

On an account with a Homebrew install the SHIPPED activation still refuses by
design — the app is not in `/Applications`, a legacy launch agent is
registered, and a second copy exists — which is why the dev loop opens the app
in its **development configuration**: `open …/FermixPet.app --args
--development-engine`, a debug-only launch that skips those three refusals and
uses its own bundled background agent. It still
probes the recorded home's daemon identity, waits for the socket, negotiates
`hello` and reads what is set up, so activation proves everything it can
prove here. A release build refuses the flag and exits 2, and
`scripts/verify_staged_app.sh <app> <arch> <sig> release` asserts a shipped
binary carries none of that configuration. The dev home and port are validated
before registration; the GUI login item is not registered by this dev loop.
Restarting and disabling the background service from the app exercise the same
agent lifecycle as production, while the Homebrew daemon on 4030 stays separate.

The host-safe script regression suite is `bash scripts/dev_e2e_test.sh`. It uses
command doubles and temporary Unix socket files; it never registers a real
service, launches an app, or touches the account's bootstrap record.

## Known-open items this session does not cover

Sparkle updates and the update journal (M34 §6, unbuilt), `migrate-to-app`
live-fire (Path B, deliberately second), diagnostics export UI, and the
clean-second-Mac acceptance pass that GA requires. The management contract is
vendored from the engine's own export on `feat/m34-management-v2` — protocol 2,
all 42 methods — and the app no longer authors a draft of it. That branch is
still uncommitted upstream, so the pin records its base commit with a dirty
working tree: committing the M34 trees and re-taking the pin from the commit
that publishes them remains the release prerequisite for everything pinned.
