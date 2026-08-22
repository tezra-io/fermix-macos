# Fermix app e2e session runbook

One sitting, roughly two hours hands-on. It chains three things in order: the
signed-artifact build (now with the engine inside), the Stage 0 evidence gates
(`docs/STAGE0_RUNBOOK.md` owns their detail), and the full product journey.
Yesterday's smoke test covered the UI shell against an external engine; this
session is the real thing — signed app, embedded engine, real activation, real
TCC prompts.

Record everything in the M34 Stage 0 evidence table as you go
(`~/projects/fermix/docs/design/MILESTONE_34_UNIFIED_MACOS_APP_IMPLEMENTATION.md`).

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

## Known-open items this session does not cover

Sparkle updates and the update journal (M34 §6, unbuilt), `migrate-to-app`
live-fire (Path B, deliberately second), diagnostics export UI, and the
clean-second-Mac acceptance pass that GA requires. The management contract is
still uncommitted upstream — committing the M34 trees remains the release
prerequisite for everything pinned.
