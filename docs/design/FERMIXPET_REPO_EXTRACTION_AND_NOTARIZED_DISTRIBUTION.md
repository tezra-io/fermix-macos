# FermixPet → `fermix-macos`: Repo Extraction + Notarized Distribution (Plan v2)

**Status:** Draft v2 (uncommitted; `docs/design/` is gitignored by repo convention — this is deliberate, not an oversight).
**Supersedes:** M9.4 §7.4's "separate workflow, same repo, single-app `pet-v*`" assumption.
**Depends on:** M9.4 Part C §7 for the base packaging recipe (entitlements, notarize, staple).
**Decisions locked (owner, 2026-07-12):** repo = **`tezra-io/fermix-macos`** (product-neutral, holds the pet *and* a future macOS companion app); artifacts = **universal2** (arm64 + x86_64).
**Gate already cleared:** Apple enrollment + Developer ID Application cert + notary secrets are provisioned and **proven on `tezra-io/compux`**. `compux/.github/workflows/release.yml` + `scripts/build_app.sh` are the portable reference.

> **v2 changelog:** product-neutral multi-app repo (was single-app `fermixpet`); universal2 (was silent → arm64-only); handshake redesigned from exact-match reject to a versioned **state machine with an N/N-1 window**; added **release-authority hardening**, **arch/cask/quarantine CI gates**, and a **review-disposition table** (§13). Driven by the Codex adversarial review — see §13.

---

## 1. Decision & thesis

Extract the pet into a **product-neutral macOS repo `tezra-io/fermix-macos`**, structured to hold multiple macOS apps under `Apps/`, cloned from the proven compux release skeleton. Ship each app **Developer ID-signed → notarized → stapled → universal2 DMG + Homebrew cask** via **app-scoped tags** (`fermixpet-v*`) on `macos-14`.

Why (owner's "shift and plug", made multi-app):
- **Zero build coupling.** Every inbound `FermixPet` reference in the Elixir tree is a doc, README, UI string, or comment (`openai_client.ex:72`, `home_live.ex:22`, `components.ex:988`, `SKILL.md:87`). `mix compile`/`mix test` are unaffected by the move.
- **A dedicated macOS repo is the right home for a growing app surface** — the pet today, a full companion app later, sharing one notarize/DMG/cask pipeline instead of a second migration.
- **The only real cost is protocol drift** (§7), which is boundable with a versioned wire contract.

iOS (M19 companion) is **out of scope** for this repo: App Store / TestFlight distribution shares none of the notarize-DMG-cask machinery, so it stays its own repo.

---

## 2. Repo shape (`fermix-macos`) — addresses Codex F1

A single-app repo rooted at `Package.swift` would collide the moment a second app lands. Product-neutral from day one:

```
tezra-io/fermix-macos
├── Apps/
│   ├── FermixPet/                 # SwiftPM package (moved from clients/macos/FermixPet)
│   │   ├── Package.swift
│   │   └── Sources/FermixPet/…  + FermixPet.entitlements
│   └── (FermixCompanion/)         # future app — drops in with zero repo surgery
├── scripts/
│   ├── package_release.sh         # shared: build → sign → notarize → staple → DMG → verify
│   └── keychain.sh                # shared: import cert into temp keychain, teardown
├── .github/workflows/
│   ├── notarize.yml               # reusable (workflow_call) — signing steps live ONCE
│   ├── release-fermixpet.yml      # trigger: tags 'fermixpet-v*.*.*'
│   └── ci.yml                     # macOS PR gates (build + tests + verify)
├── Casks/                         # per-app cask files pushed to the tap
├── PROTOCOL.md                    # the frozen realtime wire contract (§7)
└── README.md
```

Multi-app invariants baked in now (so the second app is additive, not another migration):
- **App-scoped tags:** `fermixpet-v*`, later `fermixcompanion-v*`. Never a bare `v*` (which the fermix CLI already owns) and never a shared `pet-v*`.
- **Per-app casks:** `Casks/fermixpet.rb`, later `Casks/fermixcompanion.rb`.
- **`--latest=false` on every app release.** A multi-product repo re-shares GitHub's repo-wide `/releases/latest`; no app claims it. Casks pin **fixed tag-scoped asset URLs**, so `latest` is never in the download path. *(This is the intra-repo version of the old B2 hijack — see §9.)*
- **Reusable `notarize.yml`** (`workflow_call`): the pet and the future app call it with `{app_name, bundle_id, entitlements}` inputs. Signing/notary steps exist once.

---

## 3. How FermixPet ships today

`clients/macos/FermixPet/script/build_and_run.sh`: `swift build` → hand-stage a `.app` → generate a throwaway **self-signed `FermixPet Dev`** identity (openssl → `security import`) → `codesign --force --sign "FermixPet Dev"` (**no hardened runtime, no entitlements**) → install to `~/Applications`. The self-signed identity exists only to give the mic TCC grant a stable-ish designated requirement across rebuilds. No notarization, no DMG, no CI; `Info.plist` hardcodes `0.1.0`/`1`. **Not distributable** (self-signed = DOA on Sequoia+; no entitlements/DMG/CI).

---

## 4. Target pipeline — port compux + pet-specific pieces

### 4.1 Port verbatim from compux
7-secret fail-loud guard (`release.yml:69-91`); temp-keychain import + `security set-key-partition-list` (`:93-107`, stops headless codesign hang); `codesign --options runtime --timestamp` (`build_app.sh:37-41`); **notarytool submit-then-poll, not `--wait`** (`:126-150`, the fix for a lost 75-min scan); `stapler staple` + `codesign --verify --deep --strict` (`:151-152`); `ditto -c -k --keepParent`; keyless cosign; `macos-14`.

### 4.2 Pet-specific new work
| Piece | Why |
|---|---|
| **`FermixPet.entitlements`** = `com.apple.security.device.audio-input: true` (only key) | **Blocker.** Hardened runtime hard-denies the mic even with `NSMicrophoneUsageDescription`. compux ships none (no audio). |
| **universal2 build** (Codex F4) | `swift build -c release --arch arm64 --arch x86_64` → one fat binary; `lipo -info`/`file` assert both arches; one universal DMG + one cask. macos-14 is arm64, so a plain build would strand Intel Macs the CLI supports. |
| **DMG** (`hdiutil create -format UDZO`, drag-to-Applications; two-pass staple) | compux ships a `.zip`. |
| **Homebrew cask** `Casks/fermixpet.rb` | tap ships a *formula* only; cask bump is a separate path (§9). |
| One-template `Info.plist` + tag-stamped versions | three plist sources diverge; versions hardcoded (§9). |

### 4.3 Signing + entitlements + TCC
Release sign:
```
codesign --force --timestamp --options runtime \
  --entitlements Apps/FermixPet/Sources/FermixPet/FermixPet.entitlements \
  --identifier io.tezra.FermixPet \
  --sign "Developer ID Application: <Name> (<TEAMID>)" FermixPet.app
```
No `--deep` for signing (verify-only). One entitlement only (AF_UNIX socket is unrestricted under hardened runtime; `otool -L` = only `/usr/lib`+`/System`). `get-task-allow` **absent** → always `-c release`, always explicit `--entitlements`, never `--preserve-metadata`. A real Developer ID gives a **Team-ID-anchored designated requirement** → the mic grant becomes durable across releases (the self-signed hack disappears). One-time cost: existing dev users get a single re-prompt on the identity switch. Bundle id + Team ID frozen after first release. No self-disclaim needed (LaunchServices-launched, not `posix_spawn`'d).

### 4.4 Notary auth — deviate from M9.4 §7.4
Reuse compux's **Apple-ID + app-password** set (`MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD MACOS_KEYCHAIN_PASSWORD MACOS_DEVELOPER_ID APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD`), not the ASC-API-key set — proven, and submit-then-poll is compux's own fix. Same Team-ID Developer ID Application cert is reusable across bundle ids. See §6 for how the secrets are *scoped*.

---

## 5. The extraction

### 5.1 What moves / stays
`clients/macos/FermixPet/**` → `Apps/FermixPet/` in the new repo. The **socket protocol stays defined daemon-side** (`apps/fermix_core/.../realtime/protocol.ex`, `local_voice_socket.ex`); the pet versions against it (§7).

### 5.2 Updates in the *same* change (fermix repo)
- **README.md** (`:170-182`, `:285`, `:400-401`) — repoint the build block to `fermix-macos` / the released DMG; drop `clients/macos/FermixPet` from the diagram.
- **`self_knowledge` SKILL.md** (`:85-87`) — Execution Contract requires it on an install-surface change: name the install method (brew cask / DMG), drop "source-build", **no version numbers**.
- **AGENTS.md / CLAUDE.md** doc index → repoint pet doc pointers.
- **Leave ARCHITECTURE.html + CHANGELOG history intact.**
- **Copy the gitignored M9.3/M9.4 (+ this) design docs into `fermix-macos`** — they're untracked, so `git mv` won't carry them.

---

## 6. Release authority & secret scope — addresses Codex F2

A tag-triggered signing workflow with org-shared credentials means *whoever can push a matching tag can sign+notarize+publish arbitrary code under Tezra's identity* — and org-level secrets extend the blast radius to compux. Harden before wiring:

- **Protected GitHub environment `release-macos`** with a required reviewer; **secrets scoped to that environment**, not repo-wide/org-wide. A random tag push cannot reach them without approval.
- **Protected-tag ruleset:** only maintainers may push `*-v*` tags.
- **Release-branch ancestry + strict version check:** the workflow asserts the tagged commit is an ancestor of `main` and `tag == Package.swift/Info.plist version` (mirror fermix `release.yml:23-34`) before exposing secrets.
- **Immutable action SHAs** (`actions/checkout@<sha>`, not `@v4`) — supply-chain pinning.
- **Cert-isolation decision (open):** reuse compux's Developer ID cert (simpler, shared blast radius) **vs** issue a dedicated `fermix-macos` Developer ID Application cert under the same Team (isolates a compromise). Default: reuse + protected environment; dedicated cert if org-level secrets are used. → §12.

---

## 7. The realtime wire contract — addresses Codex F3 (code-confirmed)

**Verified current behavior** (why exact-match rejection is wrong): the pet sets `connected = true; mode = .idle` and *then* fires `client_hello` (`CompanionState.swift:165-168`) — it never waits for or validates a reply; the daemon replies only `state:idle` and **drops `protocol_version`** (`local_voice_socket.ex:286-289`); and `call_start` runs with **no hello required** (`local_voice_socket.ex:291`; `protocol.ex` validates only the event *name*). Post-split, brew and the daemon upgrade independently, so an **exact-equality** version gate would guarantee an outage on any ordering skew.

Design a real handshake, frozen while both sides are still one commit:

1. **Mandatory hello-first state machine.** The daemon rejects `call_start`/audio/etc. until a valid `client_hello`; the pet must not set `connected = true` until it has received and **validated** the daemon's hello reply.
2. **Versioned negotiation with an N/N-1 window.** `client_hello` carries `protocol_version`; the daemon replies with its **supported range** (`{min, max}`), supporting the current *and* previous version. Each side accepts if its version ∈ the other's range; on mismatch it refuses to connect and shows *which side must update* (not a generic offline flicker).
3. **One canonical machine-readable contract.** `protocol.ex` is the source of truth, exported to a `PROTOCOL.md` + a JSON schema + golden JSONL fixtures; `fermix-macos` vendors the schema/fixtures **pinned by checksum** (not a hand-copied duplicate).
4. **Cross-repo compatibility tests.** Pet CI tests against the current *and* previous daemon contract; daemon CI tests it still accepts the previous pet contract.
5. **Documented rollout/rollback order:** bump the daemon to add `N+1` support (while keeping `N`) *before* shipping a pet that speaks `N+1`; never ship a pet requiring a version the released daemon lacks.
6. **Pet `default:`-log branch** for unrecognized server events (5 of 8 handled today, silently).

Cheapest first commit (in fermix, pre-split): daemon reads `protocol_version`, echoes its supported range, and gates events on a prior valid hello; pet waits+validates before `connected=true`.

---

## 8. CI & release gates — addresses Codex F5 + F6

The build passing is not the release being safe. Deterministic gates, at the seam where a bad artifact is actually *blocked*:

**Architecture (F4):** after build, `lipo -info FermixPet.app/Contents/MacOS/FermixPet` (or `file`) must show `arm64` **and** `x86_64`; fail otherwise. `codesign --verify --deep --strict` on the universal bundle.

**Notarization (headless, necessary):** `codesign --verify --deep --strict --verbose=2`; `xcrun stapler validate` on **both** app and DMG; `codesign -d --entitlements -` asserting `audio-input` present + `get-task-allow` absent.

**Quarantined-download acceptance (F6, the part headless checks miss):** headless `spctl` on a CI artifact never sees quarantine. So **simulate it deterministically**: `xattr -w com.apple.quarantine "0081;<ts>;Safari;<uuid>" FermixPet.dmg` → `hdiutil attach` → copy the `.app` out → then assess with the **correct contexts**: `spctl -a -t open --context context:primary-signature FermixPet.dmg` (disk image), `spctl -a -t exec -vv FermixPet.app` (app), plus `syspolicy_check distribution` on supported macOS → attempt a launch and assert not-blocked. Fail the job on any block. Keep one *manual* real-browser-download check per release as belt-and-suspenders, but the scripted quarantine gate is the enforced one. *(This change also deletes the README `xattr -dr` escape hatch, so the gate must be real.)*

**Cask integrity, gated where it blocks (F5):** compute the cask `sha256` from the **exact uploaded DMG bytes** inside `release-fermixpet.yml` (not fermix `ci.yml`, which never triggers on a tap push); then `brew audit --strict --cask Casks/fermixpet.rb` + `brew install --cask <local>` smoke on the runner; publish to the tap via a **PR with required tap-repo CI** (or push only after the smoke passes). A distinct **cask-specific** bump step — never the formula-only `bump.sh` (which no-ops on a cask and ships a zeroed sha).

**Tap push race:** `release-fermixpet.yml` and the CLI `release.yml` both bump `tezra-io/homebrew-tap`. Across separate repos a `concurrency:` group does **not** serialize them, so wrap the tap push in a bounded `fetch+rebase+retry` (≤3).

**macOS PR CI:** the new repo starts with none — stand up `ci.yml` running `swift build --arch arm64 --arch x86_64`, `build_and_run_test.sh`, `runtime_policy_test.sh`, and `codesign --verify --deep --strict` on every PR **before** any signed release.

---

## 9. Regression register

Grounded in real `file:line`. Codex findings are tagged `[Fn]`. Items marked **⚠verify** warrant a 2-min spot-check.

### Blockers
- **B1 — mic entitlement omitted → hardened runtime denies the mic for ALL users.** `AudioController.swift:68/73/133`; `build_and_run.sh:138-142` signs w/o runtime/entitlements. *Fix:* `FermixPet.entitlements` (audio-input); sign `--options runtime --entitlements`; gate `codesign -d --entitlements -` (audio-input present, get-task-allow absent) pre-notarize.
- **B2 — `/releases/latest` hijack.** Cross-repo: **eliminated** by the separate repo (fermix CLI's `manifest.ex:15`/`install.sh:22` are untouched). Intra-repo (pet vs future app): handled by `--latest=false` on all app releases + fixed tag-scoped cask URLs (§2).

### High
- **H1 [F3] — wire contract drift / brittle handshake.** §7. Exact-match reject → N/N-1 range + mandatory hello + client validates before connected.
- **H2 [F1] — single-app repo shape.** §2. Product-neutral `fermix-macos` + `Apps/` + app-scoped tags/casks + reusable notarize workflow.
- **H3 [F2] — unguarded signing authority.** §6. Protected environment + protected tags + ancestry/version check + immutable SHAs + scoped secrets.
- **H4 [F4] — arm64-only artifact strands Intel.** §4.2/§8. universal2 + `lipo` assert.
- **H5 [F5] — cask integrity gated in the wrong repo.** §8. Gate in `release-fermixpet.yml` from uploaded bytes + `brew audit`/install smoke + tap PR.
- **H6 [F6] — Gatekeeper test skips the quarantine path.** §8. Scripted quarantine → mount/copy/launch + correct spctl context.
- **H7 — tap push race** (`release.yml:133-144`, no rebase/retry). §8. Bounded fetch+rebase+retry (concurrency group won't work cross-repo).
- **H8 — two app copies → TCC silent deny.** `~/Applications` (source) vs `/Applications` (cask), same bundle id, different DR. *Fix:* cask `zap`/`caveats` + README preflight (`rm -rf ~/Applications/FermixPet.app`, `tccutil reset Microphone io.tezra.FermixPet`), /Applications-only.
- **H9 — self-signed→Developer ID switch re-prompts existing dev users.** DR changes → grant stops matching. *Fix:* one-time migration note (first launch re-prompts; `tccutil reset` if stuck); self-heals; surface a real "mic denied" pet state.

### Medium
- **M1 — release-script fallback.** `package_release.sh` validates all creds up front, fails loud, **no ad-hoc fallback**; dev (`build_and_run.sh`) unchanged.
- **M2 — get-task-allow reject.** Always `-c release` + explicit `--entitlements`; verify gate asserts absent.
- **M3 — secret scoping/auth mismatch.** compux secrets are repo-scoped + Apple-ID auth vs §7.4's ASC-API-key. Provision on `fermix-macos` (env-scoped, §6), one scheme, reconciled names, presence guard.
- **M4 — atomic paired protocol change lost.** Post-split, daemon+pet changes are two PRs across two repos. *Fix:* the `PROTOCOL_VERSION` bump + cross-repo compat tests (§7) are the enforced coordination point; CONTRIBUTING note naming the paired files.
- **M5 — silent server-event drop.** Pet handles 5/8 events, no `default:`. §7 item 6.
- **M6 — resource-bundle toolchain drift (⚠verify).** `FermixPet_FermixPet.bundle` is a flat PNG dir today → sealed as resources, passes verify (**confirmed, no action now**). `codesign --verify --deep --strict` catches a future structured-bundle layout; sign inside-out only if it fires.
- **M7 — three plist sources + hardcoded 0.1.0/1.** `build_and_run.sh` heredoc `CFBundleName=FermixPet` vs `Info.plist`=`Fermix`; `CFBundleVersion 1` can defeat LaunchServices "newer". *Fix:* one template; decide Fermix vs FermixPet (§12); stamp from tag + monotonic `CFBundleVersion`; embedded-vs-bundle identity-key diff gate.
- **M8 — GUI launch can't find a non-default daemon (⚠verify).** `defaultSocketPath()` is env-only (`CompanionState.swift:105-118`); a Finder/cask launch inherits no shell env → always `~/.fermix`, silently offline for dev/custom homes. *Fix:* persistent home setting (`defaults` key / read `~/.fermix` config), show resolved path in the offline tooltip, `fermix voice status` prints a `launchctl setenv` line.
- **M9 — Realtime Codex-OAuth footgun reaches non-technical users.** A one-click cask surfaces "Realtime needs an OpenAI Platform `sk-` key; Codex OAuth doesn't authorize it" with no diagnostic (`config.ex:31-38`, no key check in `voice_command.ex`/doctor). *Fix:* doctor `realtime` check + `fermix voice status` key line + setup-pane warning; map `:not_configured` to a human pet string.
- **M10 — README/self_knowledge/doc-index drift on move.** §5.2.
- **M11 — pet has no automated coverage.** §8 (macOS PR CI).

### Low
- **L1 — socket-path string duplicated** across repos → freeze in `PROTOCOL.md`.
- **L2 — gitignored design docs won't survive `git mv`** → copy manually. (Verified: `feat/computer-use-v2`, `feat/macos-tcc-unified-identity` carry **0** pet commits ahead of `dev` — no in-flight code stranded.)
- **L3 — shared `FermixPet.icns` coupling** with compux → pin as a versioned asset + documented resync owner.
- **L4 — `.p12`/bundle-id/Team-ID freeze** → back up `.p12` offline; never rename post-release.
- **L5 — pet cosign sig is decorative** (no Fermix verifier) → cask `sha256` (+ §8 check) is the real gate; keep cosign for uniformity only.
- **L6 — tag-glob isolation** — moot: separate repo + app-scoped `fermixpet-v*` tags.

### Cross-cutting themes
1. **The wire contract spans two independently-versioned repos** — needs one canonical versioned contract + N/N-1 window + cross-repo compat tests (H1/M4/M5/L1).
2. **"Silent mic deny" is the dominant failure family** — missing entitlement / identity switch / two copies. One entitlements file + one migration note + one install location resolves the cluster (B1/H8/H9).
3. **One release substrate now serves multiple artifact streams** — `/releases/latest`, the tap, the cert/secrets, the bump script all assumed one product. Separate + serialize: app-scoped tags, `--latest=false`, cask-specific bump, protected/scoped secrets (B2/H3/H5/H7).
4. **Rule #12 at every seam** — no ad-hoc signing fallback, CI *assesses* notarization (incl. real quarantine) rather than trusting a manual step, handshake *negotiates* rather than exact-rejects or silently ignores.

---

## 10. Phased rollout (lowest-regret order)
1. **Freeze the wire contract in fermix, pre-split** (§7): `PROTOCOL_VERSION` range + hello-first state machine + client validates before connected + canonical `PROTOCOL.md`/schema/fixtures + pet `default:`-log. *(H1/M4/M5/L1.)*
2. **Create `fermix-macos`** with the multi-app shape (§2); `git mv` the pet to `Apps/FermixPet`; copy the gitignored design docs; repoint fermix README + doc index + self_knowledge. *(H2/M10/L2, B2 intra-repo.)*
3. **Stand up macOS PR CI** (universal2 build + test scripts + verify) before any signed release. *(M11, H4 assert.)*
4. **Author `package_release.sh`** (universal2, entitlements, `-c release`, `--options runtime --entitlements`, no fallback, stamped plist, headless + quarantine notarization gates). *(B1/M1/M2/M6/M7/H4/H6.)*
5. **Harden release authority** (protected env + tags + ancestry/version + immutable SHAs) and **provision env-scoped Apple secrets**; pick cert reuse vs dedicated. *(H3/M3.)*
6. **Cask + tap** via reusable `notarize.yml` + `release-fermixpet.yml`: cask-specific bump, cask-sha==DMG + `brew audit`/install smoke via tap PR, bounded rebase-retry push. *(H5/H7.)*
7. **Migration + discoverability UX** with the first release: cask `zap`/caveats (`rm -rf ~/Applications/...` + `tccutil reset`), /Applications-only, doctor `realtime` + `fermix voice status` key check, persistent socket-home, visible "mic denied" state. *(H8/H9/M8/M9.)*
8. **Freeze identity**: back up `.p12`; freeze bundle id/Team ID; pin `FermixPet.icns` + resync owner. *(L3/L4.)*

First notarized universal2 DMG lands after step 4; cask after step 6.

---

## 11. Open decisions (§12)
1. **Cert isolation** — reuse compux's Developer ID cert (simpler) vs dedicated `fermix-macos` cert (isolates blast radius). Default reuse + protected env; dedicated if secrets go org-level.
2. **Display name freeze** — `CFBundleName` = **"Fermix"** (unifies the mic entry with compux's "Fermix" identity — recommended) vs "FermixPet". Frozen at first release.
3. **macOS floor** for `fermixpet-v0.2.0` — `:ventura` (13, today) vs `:sonoma` (14) if Rive/Part B is close, to avoid a second TCC/floor churn.
4. **Tap publish model** — direct push (with rebase-retry) vs PR-with-required-checks (stronger gate, slower). Recommended: PR for the cask.
5. **Sparkle** — stays deferred for v1 (monotonic `CFBundleVersion` from step 4 keeps it a drop-in). Confirm.

---

## 12. Codex adversarial-review dispositions
| Finding | Verdict | Where addressed |
|---|---|---|
| F1 single-app repo shape | **Valid** | §2 multi-app `fermix-macos` |
| F2 unguarded signing authority | **Valid (right-sized)** | §6 release authority |
| F3 handshake can't survive independent releases | **Valid — code-confirmed** (`CompanionState.swift:165-168`, `local_voice_socket.ex:286-291`) | §7 state machine + N/N-1 |
| F4 arm64-only artifact | **Valid** | §4.2/§8 universal2 |
| F5 cask checksum in wrong repo | **Valid** | §8 gate in release-fermixpet.yml + tap PR |
| F6 Gatekeeper skips quarantine | **Valid (nuance)** | §8 scripted quarantine acceptance |
| meta: "gitignored/untracked → commit it" | **Dismissed — context gap** | `docs/design/` is gitignored by repo convention (0 tracked design docs); the "absent from branch diff / no-ship" framing is an artifact of diff-reviewing a deliberately-untracked planning doc |

---

## 13. Implementation log — Phase 1 (wire-contract freeze), 2026-07-13

**Scope shipped:** step 1 of §10 only — the pre-split, in-`fermix` wire-contract
freeze (§7). Uncommitted, awaiting review. Steps 2–8 are **owner-side / external**
(create `tezra-io/fermix-macos`, Apple Developer secrets, Homebrew tap, notarize
CI) and cannot be executed from inside this repo; step 1 is the only
account-independent, testable, mandated-first piece. The daemon change is
**backward-compatible with the current pet** (pet sends hello first and ignores
unknown server events), so it satisfies the §7 daemon-first rollout rule and can
ship without the pet upgrade in lockstep.

**Files.** Modified: `realtime/protocol.ex`, `realtime/local_voice_socket.ex`,
`realtime/protocol_test.exs`, `realtime/local_voice_socket_test.exs`,
`FermixPet/Sources/FermixPet/CompanionState.swift`. New:
`fermix_core/priv/realtime/{PROTOCOL.md, protocol.schema.json,
fixtures/client_events.jsonl, fixtures/server_events.jsonl}`,
`realtime/protocol_contract_test.exs`.

**Deviations / decisions made within the design frame (for review):**
- **D1 — `server_hello` is a dedicated new server event** replacing the old
  `client_hello → {state:idle}` reply. §7 said "the daemon replies with its
  supported range" without naming the event; folding negotiation into the turn
  `state` event would conflate handshake with turn state, so the reply is now
  `server_hello {min_version, max_version}`. Hello-reply shape therefore changed
  (verified harmless to the current pet via its `default:` ignore).
- **D2 — N/N-1 window from one constant:** `@min_supported_version =
  max(1, @protocol_version - 1)` ⇒ range `{1, 1}` today; a future bump
  auto-accepts the prior version.
- **D3 — the `client_too_old` branch is unreachable over the wire today** (valid
  versions are ≥1 and the floor is 1) but kept: `negotiate/1` is the complete
  public function (unit-tested directly) and the branch goes live at the first
  `min > 1`. Not speculative — the correct complete negotiation.
- **D4 — pet handshake timeout = 3 s; a connected-but-silent daemon ⇒ "update
  Fermix"** (it predates the handshake). §7 left the pet-side timeout/old-daemon
  handling to implementation.
- **D5 — the canonical contract lives in `fermix_core/priv/realtime/`** (beside
  `protocol.ex`, the source of truth), not the repo-root `PROTOCOL.md` in the §2
  tree — §2's tree is the *`fermix-macos`* layout, and §7 item 3 has that repo
  *vendor* the contract (checksum-pinned) from the source of truth. So the
  canonical set is in `fermix`; the §2 root copy is the vendored one.
- **D6 — `self_knowledge` SKILL.md not touched.** The handshake is an internal
  wire detail, not a user-facing feature/config/CLI surface; its realtime line
  stays accurate. The §5.2 SKILL.md edit belongs to the install-surface change
  (step 2), not step 1.

**Self-review (Workflow, 4 lenses → adversarial verify) — 4 confirmed, all
resolved:**
- **F1 (daemon, fixed):** `server_hello` reply used a hard `:ok = send_event`; a
  peer that broke mid-handshake would raise `MatchError` past `cleanup_client`
  and leak the parent-owned accepted fd (rule #4). Now routes a failed write
  through `{:stop, state}` → cleanup. (Also removes the same latent leak the old
  `state:idle` hello reply carried.)
- **F4 (schema, fixed, medium):** the per-event `$defs` (required
  `protocol_version`, `audio`, `min/max`, …) were never `$ref`'d, so the exported
  schema validated only the `type` enum and accepted malformed frames the daemon
  rejects. Rewired via an `if/then` discriminator; **proven with a Draft-2020-12
  validator** (rejects all 7 daemon-rejected frames, accepts every golden
  fixture); guarded by two new `protocol_contract_test.exs` assertions
  (no-dangling-defs + required-fields).
- **F3 (coverage, test added):** added a pipelined "`client_hello` + `call_start`
  in one recv buffer, no wait for `server_hello`" test — the exact behavior of
  the already-shipped pet — guarding the daemon-first back-compat property.
- **F2 (noted, NOT fixed — out of scope):** the pre-existing "F-12 crash" test
  (`local_voice_socket_test.exs`) is vacuous (never triggers an abnormal exit);
  the review confirms the diff touches neither it nor the monitor source. Flagged
  for a separate cleanup (rule #10).

**Verification:** 121 realtime tests pass; `credo --strict` clean; `mix format`
clean; `mix compile --warnings-as-errors` clean; `swift build` clean; schema
validated against Draft-2020-12. Test run scoped to `test/fermix_core/realtime/`
(the change's blast radius) — a full `mix test` folds in unrelated in-progress
uncommitted work and the known host-config leak.

### 13.1 Remaining phases — what's implementable in-`fermix` vs owner-only

A second pass took the plan as far as code from inside this repo can. The bulk of
steps 2–8 are **owner-executed operations, not code** and cannot run from here:
create `tezra-io/fermix-macos` (repo create + push), provision the 7 Apple notary
secrets into a protected environment, publish the cask to `homebrew-tap`, set the
GitHub protected-tag ruleset, and run live notarization (needs the Developer ID
cert). No artifact I write performs those, and creating/pushing an org repo is an
irreversible outward action left to the owner.

**Implemented in-`fermix` this pass (account-independent, moves with the pet or
lives in the daemon):**
- **B1 — `FermixPet.entitlements`** (`Sources/FermixPet/`, the only key
  `com.apple.security.device.audio-input`). `plutil -lint` OK; excluded in
  `Package.swift` so `swift build` stays warning-free. This is the pure-code half
  of step 4 (`package_release.sh` consumes it at sign time in `fermix-macos`).
- **M9 (step 7 in-`fermix`) — `fermix doctor` `realtime voice` check + `fermix
  voice status` key line.** Both surface the footgun that Realtime needs an
  `openai` `sk-` key and a Codex subscription/OAuth login does **not** authorize
  it (`Checks.realtime/0` → ok/warn; `voice status` prints `realtime key:
  present | MISSING …` in human and `--json`). 3 new hermetic `checks_test`
  cases; 67 doctor tests pass, credo/format/compile clean.

**Verified-elsewhere-only (honest gaps):**
- **F4 universal2** (`swift build --arch arm64 --arch x86_64` + `lipo`) needs
  **full Xcode's xcbuild** — this box has only Command Line Tools, so the fat
  build is verifiable on the `macos-14` runner, not here. Single-arch `swift
  build` is green.
- The signing/notarization/DMG/cask pipeline is inherently unverifiable without
  the Apple Developer cert + secrets; the design ports the **proven** compux
  reference, but "done with proof" for it belongs to the owner's first run.

**Not done (deliberately):** the `fermix-macos` scaffold (repo structure, moved
pet, `package_release.sh`, CI, `notarize.yml`, cask, vendored checksummed
`PROTOCOL.md`) was **not** generated into this repo — it belongs in the new repo,
duplicating the pet here would create the two-copies-drift problem the split
exists to avoid (H8/L2), and its release scripts can't be run/proven from here.
Ready to author it as a standalone ready-to-push bundle on the owner's go.
M8 (persistent socket-home) and the mic-denied pet state are step-7 polish that
only bind once the cask ships; deferred with the release they support.
