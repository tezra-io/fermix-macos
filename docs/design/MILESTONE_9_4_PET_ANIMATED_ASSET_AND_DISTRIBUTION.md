# Milestone 9.4 — FermixPet: Animated Asset Upgrade + Installable Distribution

**Status:** Draft (design review pending)
**Date:** 2026-07-02
**Depends on:** M9.1 (realtime voice, shipped), M9.3 (procedural pet animation, P0 shipped)
**Gates:** Apple Developer Program enrollment (Developer ID) for Part C; Rive integration spike (§6.2) for Part B

---

## 1. Summary

FermixPet today is a layered-PNG mascot animated procedurally in SwiftUI (M9.3 P0), built
from source and signed with a throwaway self-signed identity. This milestone plans the two
upgrades the current posture defers:

- **Part A (now, no new assets):** squeeze the remaining life out of the existing PNG rig.
  A 3-lens review panel + judge audit (2026-07-02) concluded the animation **can** be
  meaningfully improved without bloat: ~230–280 LOC, concentrated in the two files that
  already own motion (PetView, MascotMotion) with small touches to CompanionState and
  FermixPetApp, zero new assets, zero dependencies. The defining limitation is architectural —
  five independently registered layers transform as one rigid sticker, and a free blink
  frame sits unused.
- **Part B (after Developer ID + artist commission):** replace the static-PNG pipeline with
  a **Rive (`.riv`) state-machine asset** — the format decision, the artist commission
  spec, and the runtime integration design.
- **Part C (after Developer ID enrollment):** replace the source-build/self-signed flow
  with a **Developer ID-signed, notarized, drag-to-Applications DMG** on GitHub Releases
  plus a Homebrew cask in the existing tap, built by a new tag-triggered CI job.

Parts B and C are independent of each other except that shipping the Rive runtime (a
dynamic framework) adds one inside-out signing step to Part C's pipeline; Part C should
land first so the first notarized release is the simplest possible app.

## 2. Current state (verified 2026-07-02)

### 2.1 Animation (M9.3 delta)

All four M9.3 **P0** items are shipped and match the doc's parameters:

| M9.3 item | Status | Where |
|---|---|---|
| PNG preload cache | shipped | `PetAssetCache.swift` (15 NSImages, dict lookup) |
| TimelineView sine motion (30fps) | shipped | `PetView.swift:103` `AnimatedMascot`, params in `MascotMotion.swift` |
| Expression cross-fade (0.28s + 0.97 scale) | shipped | `PetView.swift:136` `MascotCrossfade` |
| Audio-RMS speaking pulse (0.06 coeff) | shipped | `PetView.swift:117`, RMS from `AudioController` |

All three M9.3 **P2** polish items are unshipped: eye blink, one-shot event reactions,
interpolating-spring mode transitions (`PetView.swift:15` still `easeInOut(0.7)`). Part A
supersedes that P2 list with the audited set in §4.

### 2.2 The asset rig (visual probe results)

15 PNGs, all 1024×1024 with alpha, ~3.5 MB on disk, ~63 MB decoded. The mascot is a
tri-lobed translucent "cosmic jellyfish" shell (nebula fill) with a navy face capsule set
into a transparent center hole, a Saturn-style beaded orbit ring, and a separate head-pearl
orb (`pet_ball`). Probe facts that drive Part A:

- **All layers share one registered 1024px canvas** — they composite by plain stacking, so
  per-layer transforms stay aligned for free.
- **The idle face is a closed-eyes frame** (two glowing arcs); listening/thinking faces are
  wide open. A real blink is a face-layer swap, no new art needed.
- **Face bboxes are pixel-identical across idle/thinking**; the **speaking face is baked
  +12px right / −24px up** — a registration bug in the export, correctable with a
  compensating offset (~−1.3pt, +2.5pt at display scale).
- **The ring PNG has body-occlusion baked in** (rear arc erased where the body overlaps) —
  it was authored to draw **in front at 1.0×**, but the code draws it at the bottom of the
  ZStack scaled 1.20×, discarding the authored depth cue.
- Ring variants: idle and thinking rings are byte-identical; listening ring adds glow
  nodes; speaking ring sweeps wider/higher. Decor exists only for thinking (thought
  bubbles, upper-right) and speaking (side sound-wave arcs).

### 2.3 Build & distribution

- SwiftPM executable (`Package.swift`, macOS 13, no `.xcodeproj`); Info.plist embedded in
  the bare binary via `-sectcreate` linker flags; `script/build_and_run.sh` stages a
  `.app` by hand (writes its own Info.plist with hardcoded version `0.1.0`/`1`), signs
  with a **self-signed identity** (`FermixPet Dev`, created on demand — exists only for
  stable TCC mic grants across rebuilds), installs to `~/Applications`.
- **Zero Apple machinery in CI**: every workflow runs on `ubuntu-24.04`; the fermix CLI is
  Burrito-cross-compiled and cosign-signed on Linux. `releases.json`, `install.sh`, the
  sign loop, and the release upload glob all assume flat `fermix_<os>_<arch>` binaries.
  The Homebrew tap carries a binary **formula** only (no casks). Apple notary machinery
  exists only in the separate compux repo (pattern to copy, nothing reusable in-repo).
- README/M9.1 explicitly defer Developer ID + notarization; shared builds need the
  `xattr -dr com.apple.quarantine` workaround. On macOS Sequoia 15+ the Control-click-Open
  bypass is gone — non-notarized installs are now a support ticket each, which is the
  strongest argument for Part C.

## 3. Goals / Non-goals

**Goals**

1. Ship the audited Part A improvement set (current assets, no deps) — order + verify in §4.
2. Decide the animated-asset format (decision: Rive, §5) and specify the exact artist
   deliverable so the commission drops into the runtime cleanly (§5.4).
3. Specify the Rive runtime integration that **replaces** the PNG pipeline (§6).
4. Specify the Developer ID → notarized DMG → Homebrew cask pipeline and its CI job (§7).

**Non-goals**

- No always-listening/voice changes (M9.2 owns that surface).
- No Sparkle auto-update in v1 of Part C — the cask + DMG re-download is the update
  channel; Sparkle is a documented later step (§7.6).
- No Mac App Store distribution (sandbox would break the `$FERMIX_HOME/realtime.sock`
  client model).
- No `fermix voice install-companion` CLI verbs yet (M9.1 Stage 7 optional items) — the
  cask covers guided install; revisit after the first cask release.
- No runtime fallback between Rive and PNG pipelines (rule #12): the spike (§6.2) decides
  **once**; the shipped app has exactly one mascot path.

## 4. Part A — Improvements with current assets (adopt-now set)

Verdict from the audit: **yes, worth doing.** The set below is ordered for implementation;
each lands as its own small commit with the stated verify step. Everything is pure
math-over-`t` in the existing TimelineView idiom — no timers, no RNG, no new state beyond
two `@State` vars for reactions and one `@Published` Bool for occlusion.

If only one item ships, ship **A1** — highest alive-signal per line in the entire audit.

| # | Change | LOC | Files |
|---|---|---|---|
| A1 | Real blink (idle face = blink frame) | ~20–30 | MascotMotion, PetView |
| A2 | Per-layer secondary motion rig | ~60–80 | MascotMotion, PetView |
| A3 | Restore authored ring registration | ~6 | PetView |
| A4 | Hoist shared `pet_ball` out of the crossfade | ~8 | PetView |
| A5 | Decor gets a job: audio-reactive arcs, floating bubbles | ~25–35 | MascotMotion, PetView |
| A6 | Pause timeline on occlusion/offline + adaptive fps | ~30–35 | PetView, CompanionState, FermixPetApp |
| A7 | Drop `@Published` from `audioLevel` (+ smoothing) | ~3–5 | CompanionState |
| A8 | One-shot eased reactions on mode transitions | ~55–75 | MascotMotion, PetView |
| A9 | Compensating offset for the mis-baked speaking face | ~6–10 | PetView |

**A1 — Blink.** Deterministic pure function `MascotMotion.isBlinking(at t:)` (time-bucket
hash → ~120ms window every ~4–5s, jittered); when `expression == .listening || .thinking`
and blinking, the face layer renders `pet_idle_face` instead. Hard swap, no transition —
that *is* what a blink looks like; the value-scoped crossfade animation won't intercept it
because `expression` doesn't change. Exclude `.speaking` (misregistered face, A9) and
`.idle` (eyes already closed). Verify: watch listening state ≥30s; blink lands cleanly,
no capsule jump.

**A2 — Per-layer rig.** Thread `t`/`mode`/`audioLevel` into `MascotImage` as plain lets;
move breath off the global transform onto the body+face group as split-axis scale
(`y: 1 + 0.55·breath` — squash asymmetry); ring gets slow counter-phase tilt/lift (use
`bobPeriod(mode)`, not a hardcoded 3.1s, so counter-phase holds in speaking/thinking);
ball gets phase-lagged bob; face gets small drift/parallax (incommensurate long periods,
e.g. 13s/17s primes, folded in for idle anti-looping). Constants live as static funcs in
`MascotMotion` next to the existing ones — **no parameter structs**. Marginal render cost
≈ 0: the compositingGroup+shadow already re-renders per frame today. Verify: 60s
side-by-side vs `main`; layers visibly counter-move; Instruments SwiftUI body counts flat.

**A3 — Ring registration.** Reorder `MascotImage.layered`: body+face first, then ring
**on top at 1.0×** (drop `.scaleEffect(1.20)`), then decor, then ball. The ring's baked
occlusion only reads correctly in front. Changes proportions (orbit vs halo) — build and
eyeball before keeping; check the speaking decor arcs (same equator band) still read.

**A4 — Ball hoist.** Move the `ball` builder from `MascotImage` (inside every expression's
crossfade copy) to `MascotCrossfade`, placed **after** the `ForEach` in the ZStack so it
stays topmost (earlier-in-source = lower z) — stops the shared asset fading and
scale-popping on every expression change. Do **not** generalize into a per-layer
crossfade engine.

**A5 — Decor + pulse redistribution.** Speaking: drive arc opacity/scale from RMS
(`opacity 0.35 + 0.65·level`, `scale 1 + 0.10·level`), add a small face-local y-bounce,
shrink the global pulse coefficient 0.06 → ~0.02. Thinking: slow float loop for the
bubbles; either the sawtooth rise with `sin(π·p)` opacity envelope (seam-safe) or a plain
sine float — implementer's pick. Never pulse the outer shadow with audioLevel (per-frame
blur re-raster). Verify: speak a long reply; arcs breathe with speech; whole-body throb
visibly reduced.

**A6 — Occlusion pause + adaptive cadence.** `TimelineView(.animation(minimumInterval:,
paused:))` (macOS 12+, fine on the 13 floor): paused when `!windowVisible || mode ==
.offline`; interval 1/30 for speaking, 1/20 for listening/muted/toolUse/error, 1/12 for
idle/thinking — and 1/30 whenever an A8 reaction is active (`age < 0.9s`), else the
damped impulse strobes at 5 frames/cycle on the very transitions it exists to sell.
`windowVisible` = new `@Published` Bool on
`CompanionState`, fed by an `NSWindow.didChangeOcclusionStateNotification` observer added
in `WindowConfigurator.makeNSView`'s existing async block. This is the real energy lever
for an always-on companion (offline/hidden is the dominant duty cycle). Verify:
`powermetrics --samplers tasks -n 10` in three postures (offline parked, idle visible,
window on another Space) — near-zero CPU in postures 1 and 3.

**A7 — audioLevel sampling.** `audioLevel` is only ever read inside the timeline closure
(pull-sampled per tick); the `@Published` push invalidates PetView/ControlDock at PCM-chunk
rate during speech for nothing. Make it a plain `private(set) var` (writes stay on main),
optionally one-line exponential smoothing (`0.65·old + 0.35·new`) so the 30fps sampling
reads as a swell. Verify: Instruments SwiftUI template — view-body counts during speech
drop to timeline-only.

**A8 — One-shot reactions.** Two `@State` vars (`reactionKind`, `reactionStart`) set in
`.onChange(of: state.mode)`; damped impulse `d = exp(−4.5·age)·sin(14·age)` evaluated
lazily from the existing clock, zero after 0.9s. Transition map is the entire budget —
an explicit switch of 3–4 cases: offline→idle hop, →error shake, →speaking squash-stretch
(rides A2's split-axis scale), →toolUse tilt. **No reaction enums-with-tables, no event
system.** macOS 13 caveat: two-param `onChange(of:initial:_:)` is macOS 14+; on 13 get
the previous mode with a capture-list default — `.onChange(of: state.mode)
{ [old = state.mode] new in … }` — zero stored state, keeping §4's state budget intact.
This closes M9.3's designed-but-unshipped §4.6. Do last. Verify: trigger each transition
live (connect, force an error, start a reply, invoke a tool).

**A9 — Speaking-face compensation.** `.offset` ≈ `(−12·s, +24·s)` with `s = 108/1024`
for `.speaking` only, one constant with a bbox-citing comment. Tune the exact pixels
visually on a thinking→speaking transition (bbox includes glow).

### 4.1 Audited but deferred (do not ship in this pass)

- **Mode-transition transform lerp** (fixes the `animation(value:)`/TimelineView snap):
  correct diagnosis, but medium-risk; as sketched it also kills the 0.7s glow-color ease
  (the outer `.animation` must stay for color, or color eased separately). A8 masks the
  worst transitions; adopt only if the snap still shows afterwards.
- **Waking glance during idle** (listening-face swap + tilt every ~30s): charming,
  reuses A1's machinery verbatim; add only if idle still reads loopy in daily use.
- **Shadow/blur caching**: the "move shadow inside the transforms" fix is **negated by
  A2** (per-layer motion changes the compositing group's content every frame, so the
  cache never holds). The real future fix is a different design — a static pre-blurred
  glow image behind the mascot instead of a live `.shadow` filter. Bounded meanwhile by A6.
- **Pre-downsample PNGs at preload** (~63 MB decoded → ~few MB): pure memory hygiene,
  invisible; fiddly NSBitmapImageRep code. Land whenever someone is next in
  `PetAssetCache` — or skip entirely if Part B ships (deletes the PNGs).

Ceiling statement: after A1–A9, these assets are done. Gaze tracking, real mouth sync,
per-bubble motion need authored animated assets — that's Part B, not more Swift.

## 5. Part B — Animated asset format decision

### 5.1 Requirements

The pet is not a looping movie; it's a **state machine with a continuous input**:

- 8 states (idle/listening/thinking/speaking/toolUse/error/offline/muted) with **blended,
  interruptible transitions** (a state change mid-loop must cross-blend, never snap or
  wait for loop end).
- A **continuous 0–1 parameter** (`audioLevel`, speech RMS) driving mouth/energy every
  frame while speaking.
- Transparency in a borderless floating NSWindow; low idle cost (always-on, runs for
  days); SwiftPM-compatible dependency; macOS-real (not iOS-only) runtime; commissionable
  from working artists; sane licensing.

### 5.2 Comparison (researched 2026-07-02, sources in §10)

| Format | State machine | Continuous input | macOS/SwiftUI | Dep weight | License | Killer flaw |
|---|---|---|---|---|---|---|
| **Rive** (`.riv` + rive-ios) | Native, editor-authored, blend transitions | Native (number input, 1D blend) | AppKit+SwiftUI, macOS 13.1+ (14+ for fps capping) | ~5.4 MB framework (arm64) | Runtime MIT; artist needs $9/mo Cadet to export | macOS is second-tier: open drawable-leak + black-bg bugs (§5.3) |
| Lottie (lottie-ios) | **None** — app is the state machine; transitions are cuts or N² authored segments | Keypath ValueProvider hack, fragile | Yes (4.3+) | small | Apache-2.0 | No blending, no real input driving — fails both core requirements |
| Sprite/APNG/WebP flipbooks | None | None | trivial | zero | none | The status quo with more frames; 10–40 MB raster |
| HEVC-alpha video loops | None (file swap + crossfade) | None | AVPlayerLayer only (SwiftUI players paint black) | zero | none | Zero interactivity; always-on decode; 15–60 MB |
| Spine | Runtime track mixing (code-authored graph) | Yes, code-driven | young on macOS | moderate | **Requires paid Spine editor license for runtime use** | License friction + state graph lives in Swift, not the artist's tool |
| Live2D Cubism | Parameter rig (great deformation) | Excellent | No SwiftPM, OpenGL-era SDK | heavy | Revenue-triggered publication license | Integration cliff + license timebomb |

**Decision: Rive**, conditionally (conditions below). It is the only format whose native
model *is* the requirement — the artist authors the state machine, transitions blend and
interrupt correctly by construction, and `audioLevel` maps to a 1D blend inside the
speaking state. The Swift side shrinks to ~30 lines of input-setting. Runner-up is Lottie
only if artist availability ever trumps interaction quality — it turns transitions into
cuts and audio-driving into a keypath hack, i.e. it gives up exactly what the pet exists
to do. If Rive fails its spike, the fallback is the **shipped Part A procedural pass**,
not Lottie.

### 5.3 Adversarial review findings (must-handle conditions)

A skeptic pass tried to overturn the recommendation and returned **confirmed-with-caveats**.
The caveats are binding conditions:

1. **Bump the deployment floor to macOS 14.** Rive's frame-rate capping uses
   `CAMetalDisplayLink` (macOS 14+); on 13.x it runs deprecated `CVDisplayLink` at native
   refresh — uncappable constant 120 Hz on ProMotion for an app whose every state is a
   looping animation (auto-pause never engages). Rive's own floor is 13.1 anyway
   (current pet floor is 13.0; this is the moment to move to 14).
2. **Integration spike before commissioning the artist** (§6.2): two open macOS bugs sit
   exactly on our constraints — rive-ios **#413** (Metal drawable/IOSurface accumulation
   on always-on macOS, ~2.8 GB after ~15 h; mitigation: periodic view recreation) and
   **#451** (black background on macOS 6.20.6; workaround: force the MTKView layer
   `isOpaque = false` once in a superview). Both must be proven handled in *our* window
   before any money goes to art.
3. **Budget the SwiftPM plumbing:** RiveRuntime's macOS slice is a **dynamic framework**
   (~5.4 MB arm64; ~105 MB xcframework at dependency-resolution time). With no Xcode
   "Embed & Sign", `build_and_run.sh`/`package_release.sh` must gain: copy into
   `Contents/Frameworks`, add an rpath on the executable
   (`@executable_path/../Frameworks`), sign the framework inside-out before the app.
   (No consumer tools-version bump: `.macOS(.v14)` is available in swift-tools 5.9;
   a dependency's own manifest version doesn't force ours.)
4. **Pin the runtime version** — macOS regressions have shipped in point releases;
   upgrade deliberately, re-running the soak test, never blindly.
5. **Contractually require artist source access** (`.rev`/editor share) — Rive source
   lives in Rive's cloud; the Oct 2025 pricing change (exports moved behind $9/mo Cadet)
   is precedent. Downside is capped: MIT runtime + "exports keep working forever" means
   worst case is a frozen-but-functional asset.

### 5.4 Artist commission spec (hand over verbatim)

Deliverables: `fermix_pet.riv` (runtime v6.x-compatible export), **source access**
(.rev/share link — contractual), one-page state-machine cheat-sheet screenshot.

- **Artboard:** one, named `PetArtboard`, 360×336 (2× of the 180×168pt window; vector, so
  this only sets proportions), fully transparent background, ~8% inner padding so
  squash/pulse never clips. Layout fit `contain`, centered.
- **State machine:** exactly one, named `PetStateMachine`, set as default. Inputs
  (names are load-bearing — the app binds exactly):
  - `state` (number): 0=idle 1=listening 2=thinking 3=speaking 4=toolUse 5=error
    6=offline 7=muted
  - `audioLevel` (number 0.0–1.0, smoothed speech RMS, updated tens of times per second
    while speaking)
  - No triggers in this commission. Every runtime event today *is* a state change, so
    one-shot personality lives in the **transition animations** (below). We add trigger
    inputs only when a concrete non-state-change event exists to fire them — commissioning
    them now would be a deliverable nothing can invoke.
- **Transitions:** Any-State (or fully connected) into each state on `state == N`,
  200–300 ms **with blending, no exit time** — a state change must interrupt immediately.
  Entrances carry the one-shot character: entering `listening` = a small perk-up/hop
  beat, entering `error` = a startle, entering `speaking` = a squash-stretch anticipation,
  entering `toolUse` = a busy tilt. These entrance beats replace hand-coded reactions
  (M9.3 §4.6 / Part A A8) in the Rive era.
- **States (seamless loops):** idle (calm breath 2–4s, blink baked in), listening
  (perked 1–2s), thinking (ponder 2–3s), speaking (**1D blend on `audioLevel`** from
  rest-mouth 0.0 to fully energized 1.0 — the single most important deliverable),
  toolUse (tinkering 1.5–3s), error (distressed, readable at a glance), offline
  (dormant 3–5s, minimal motion — this state runs for hours at a low frame-rate cap,
  so it must read correctly at ~10 fps), muted (present-but-quiet).
- **Constraints:** vector-first (embedded raster ≤512px only if essential), total ≤1 MB,
  no audio/fonts/Rive-Listeners (all input comes from the app), every loop seam-free,
  on-model silhouette across states so blends never tear. Character must read at 180pt.
- **Acceptance test (run before sign-off):** load via
  `RiveViewModel(fileName:"fermix_pet", stateMachineName:"PetStateMachine")`; step
  `state` 0–7 in random order (blended, never snapped); sweep `audioLevel` 0→1→0 in
  speaking (smooth continuous response); check the entrance beats for listening/error/
  speaking/toolUse read as one-shots; play the offline loop at a 10 fps cap; verify
  transparency over a desktop screenshot.

The mascot's visual identity (cosmic-jellyfish shell, navy light-drawn face capsule,
beaded orbit ring, head pearl — §2.2) is the style reference the artist re-creates as a
rigged vector character; hand over the existing PNGs as the model sheet.

## 6. Part B — Runtime integration design

### 6.1 Architecture

One new file replaces four:

- **New `PetRiveView.swift`:** wraps `RiveViewModel(fileName:stateMachineName:)`.
  - **State drive:** one pure `Mode → Double` function maps `CompanionState.Mode` to the
    `state` input, preserving today's `callActive` nuance (in-call idle → listening, as
    `PetExpression.resolve` does now); set from `.onChange(of: state.mode)`. One-shot
    reaction flourishes are authored into the Rive transition entrances (§5.4) — A8's
    hand-coded reaction code does not carry over and is deleted with the rest.
  - **audioLevel drive (push, not pull):** the PNG pipeline pull-samples `audioLevel`
    from a TimelineView tick — which is deleted here. Instead the value is *pushed*: the
    existing `onOutputLevel` callback path (already main-thread, A7's smoothing kept as a
    plain var) additionally calls `setInput("audioLevel", value)` while speaking; Rive's
    own advance loop consumes the latest value each frame. RMS chunks arrive well within
    the input-set rate Rive handles; no timer, no timeline.
  - **Energy:** A6's `windowVisible` Bool + occlusion observer carry over as-is, but
    their *application* is rewritten against Rive's API surface (the TimelineView they
    fed is deleted): `.paused()` when `windowVisible == false` — occlusion is the only
    hard pause; `.frameRate()` caps per mode (30 speaking, ~20 active states, 10–12
    idle/thinking/**offline**). Offline-but-visible plays the commissioned dormant loop
    at the low cap rather than freezing it — pausing it would mean paying an artist for
    a loop the design never renders.
  - **Bug shields:** the #451 `isOpaque = false` workaround, and the #413 mitigation
    (recreate the Rive view on call end + every 24 h of continuous run — whichever the
    spike proves necessary; delete the mitigation once a fixed runtime version lands,
    with the soak test as proof).
- **Deleted when Rive ships (rule #12 — the old flow is dead the moment the new one
  ships):** `MascotMotion.swift`, `PetAssetCache.swift`, `PetExpression.swift`,
  `MascotCrossfade`/`MascotImage`/`AnimatedMascot` in `PetView.swift`, and all 15 PNGs
  (−3.5 MB repo / −63 MB decoded; net app-size change ≈ +5.4 MB framework − assets).
  `PetView` keeps the dock, context menu, hover, glow, and tap surfaces.
- **Changed (small):** `CompanionState` drops `petExpression`
  (`CompanionState.swift:119-121` — it returns the deleted `PetExpression` type); modes,
  socket protocol, and audio are untouched.
- **Unchanged:** `RealtimeSocketClient`, `AudioController`, window configuration.

`Package.swift`: add `rive-app/rive-ios` (pinned exact version), platforms →
`.macOS(.v14)` (no tools-version bump needed). `build_and_run.sh` gains the framework
embed + rpath + inside-out codesign steps (dev path signs the framework with the
self-signed identity too).

### 6.2 Go/no-go spike (before commissioning art)

1–2 days, using any sample `.riv` (Rive community files suffice):

1. `swift build` integration: framework resolves, embeds, app launches from the staged
   bundle. → *Verify: app runs from `~/Applications`, not just `swift run`.*
2. Transparency in **our** borderless floating window; apply #451 workaround if needed.
   → *Verify: screenshot over desktop, no black box.*
3. State-machine driving from `CompanionState` events end-to-end with a live daemon call.
   → *Verify: mode changes blend during a real voice turn.*
4. **24–48 h always-on soak** (idle + a few calls) watching IOSurface/drawable counts
   (`footprint`/Instruments) for #413, with the view-recreation mitigation implemented
   and toggleable. → *Verify: memory flat within noise over the soak window.*
5. Energy: `powermetrics` idle draw vs the Part A PNG baseline at matched fps caps.
   → *Verify: within ~2× of PNG idle, or pause/cap strategy adjusted until it is.*

**No-go:** if the soak fails and the mitigation is unacceptable, stay on the Part A
procedural pet (already the shipped baseline) and re-evaluate on a later rive-ios; do not
switch to Lottie (fails §5.1 requirements).

## 7. Part C — Developer ID, notarization, installable distribution

### 7.1 One-time prerequisites (owner, after enrollment)

1. Apple Developer Program, individual ($99/yr). Account Holder role creates certs.
2. **Developer ID Application** certificate — the only cert needed (signs .app, DMG, zip).
   Skip Developer ID *Installer* (that's for `.pkg` only).
3. Export cert+key as password-protected `.p12`; back it up offline like the cosign key —
   losing it is near-unrecoverable (limited issuance; new cert chain perturbs TCC/trust).
4. App Store Connect **API key** for notarytool (Users and Access → Integrations; `.p8`
   downloads once; note Key ID + Issuer ID).
5. No provisioning profile — Developer ID distribution with our entitlements uses none.

### 7.2 Entitlements + Info.plist

New `Sources/FermixPet/FermixPet.entitlements`:

- `com.apple.security.device.audio-input` = true — **required**: hardened runtime denies
  mic outright without it regardless of `NSMicrophoneUsageDescription`. This is the #1
  "mic worked before signing, dead after" failure for SwiftPM apps (no Xcode capabilities
  UI to remember it for you).
- Nothing else. `network.client` is an App Sandbox entitlement — we're not sandboxed;
  hardened runtime doesn't restrict the unix-socket client. No hardened-runtime exception
  entitlements speculatively. Assert `get-task-allow` absent in release (debug-signed
  leftovers are a canonical notary rejection).

Info.plist: keep existing keys; **stamp real versions** — `CFBundleShortVersionString`
from the release tag, `CFBundleVersion` monotonic (e.g. `GITHUB_RUN_NUMBER`) instead of
the hardcoded `0.1.0`/`1`. There are currently **three** plist truth sources and two
already diverge (`Sources/FermixPet/Info.plist` for `-sectcreate` vs the
`build_and_run.sh` heredoc: `CFBundleIconFile` differs; the heredoc adds
`CFBundleExecutable`/`LSMinimumSystemVersion`/`NSPrincipalClass`). Consolidate: one
template plist consumed by both `build_and_run.sh` and `package_release.sh` with stamped
fields; the `-sectcreate` embedded copy stays for bare-binary dev runs only (the bundle
plist wins in a bundle). Enforcement, not assertion: §7.3 step 6 gains an identity-key
diff (bundle id, mic usage string, executable name) between the embedded and bundle
plists so drift fails the release instead of confusing TCC.

### 7.3 Packaging pipeline (new `script/package_release.sh`)

`build_and_run.sh` keeps the self-signed **dev** path unchanged; release packaging is a
separate script — two configurations (dev vs release), one code path each (rule #12).

1. `swift build -c release`; stage the bundle exactly as today.
2. *(Added in Stage 3, when the first framework is embedded — no speculative framework
   branch ships in Stage 1.)* Sign embedded frameworks (Rive, later Sparkle) inside-out
   first — `codesign --force --timestamp --options runtime --sign "Developer ID
   Application: …"` per framework; **never `--deep` for signing** (verification only).
3. Sign the app:
   `codesign --force --timestamp --options runtime --entitlements FermixPet.entitlements
   --identifier io.tezra.FermixPet --sign "Developer ID Application: <Name> (<TEAMID>)"
   FermixPet.app`
4. Notarize the app: `ditto -c -k --keepParent` → zip →
   `xcrun notarytool submit --wait --key "$ASC_API_KEY_PATH" --key-id "$ASC_KEY_ID"
   --issuer "$ASC_ISSUER_ID"`; then `xcrun stapler staple FermixPet.app`. Credentials are
   key-file flags from env — **one interface for local runs and CI** (a
   `store-credentials` keychain profile wouldn't exist on a fresh runner; two credential
   paths for one script is exactly the rule-#12 shape). Error 65 (ticket CDN propagation):
   bounded retry, ≤5 attempts at 30s intervals, then fail loud.
5. Build the DMG (drag-to-Applications layout; `create-dmg` or plain
   `hdiutil create -format UDZO`); `codesign --timestamp --sign "Developer ID …"` the DMG;
   notarize the DMG (fast — contents already ticketed); staple the DMG.
   Two-pass so the copied-out app carries its own staple for fully-offline first launch.
6. Verify gate: `codesign --verify --deep --strict`, `codesign -d --entitlements -`
   (audio-input present, get-task-allow absent), embedded-vs-bundle plist identity-key
   diff (§7.2), `spctl -a -t exec -vv` → "Notarized Developer ID", `xcrun stapler
   validate` on both artifacts.

**DMG over pkg/zip:** single small app, no privileged install steps; pkg needs a second
cert; casks consume DMGs natively; canonical Mac UX. Zip revisited if/when Sparkle lands
(its preferred format).

### 7.4 CI (new `.github/workflows/release-pet.yml`)

Separate workflow, **`pet-v*.*.*` tags**, `macos-14` runner — deliberately not part of
release.yml: the CLI release is a single ubuntu job whose sign loop, `releases.json`
schema, upload glob, and install.sh all assume flat `fermix_*` binaries, and the pet's
cadence is independent of mix.exs versioning. A separate tag + release keeps every one of
those consumers untouched.

- Secrets: `MACOS_CERT_P12_BASE64`, `MACOS_CERT_P12_PASSWORD`, `ASC_API_KEY_P8`,
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, ephemeral `KEYCHAIN_PASSWORD`. (Check tezra-io org
  settings first — compux's notary secrets may already exist org-level and be reusable.)
- Steps: checkout → import cert into a temp keychain (`apple-actions/import-codesign-certs`
  or the manual `security create-keychain` / `import` / `set-key-partition-list
  -S apple-tool:,apple:` recipe — the partition-list step is what stops codesign hanging
  headless) → write `.p8` to a temp file → `package_release.sh` with versions stamped
  from the tag → upload `FermixPet-<ver>.dmg` + `.sha256` to the `pet-v<ver>` GitHub
  Release → cosign sign-blob the checksum (orthogonal to Apple signing; keeps the
  supply-chain story uniform with the CLI) → `always()` cleanup: delete keychain + `.p8`.
- Runner needs outbound network (secure-timestamp server + notary service).
- **Release checklist item CI can't cover:** one manual browser-download of the DMG per
  release — inter-job artifacts carry no `com.apple.quarantine`, so Gatekeeper is never
  exercised in CI.

### 7.5 Homebrew cask + README

`Casks/fermixpet.rb` in the existing tap (`tezra-io/homebrew-tap`): `version`/`sha256`/
`url` (GitHub release DMG), `app "FermixPet.app"`, `depends_on macos: ">= :sonoma"` once
Part B bumps the floor (`:ventura` until then), `zap trash:
["~/Library/Caches/io.tezra.FermixPet"]`. Homebrew quarantines on install by default, so
the app **must** be notarized+stapled or first launch blocks. Bump: extend the existing
tap-push step pattern (HOMEBREW_TAP_TOKEN, sed version+sha) in release-pet.yml — we own
the tap, no bump-cask-pr indirection.

README/M9.1 cleanup in the same change: delete the `xattr -dr com.apple.quarantine`
guidance and "no prebuilt download yet"; install path becomes
`brew install --cask tezra-io/tap/fermixpet` or the DMG. Update the `self_knowledge`
skill (Execution Contract) — today it only describes the pet as a `realtime.sock`
client (`SKILL.md:87`); add how it is installed/updated once the cask exists.

### 7.6 Updates: deferred, deliberately

No Sparkle in v1. The tap + DMG already form the update channel
(`brew upgrade --cask fermixpet`), and embedding Sparkle in a bare SwiftPM bundle is
all-manual exactly where we're least experienced yet (copy framework, rpath, re-sign XPC
helpers with `--preserve-metadata=entitlements`, EdDSA keypair as a new unlosable secret,
appcast generation, strictly-incrementing CFBundleVersion). When install base justifies
it, Sparkle 2 slots into the same CI (generate_appcast over release DMGs, appcast on
GitHub Pages); adopting late costs users one manual download of the first
Sparkle-enabled build. Prereq already handled: monotonic CFBundleVersion from §7.2.

### 7.7 TCC migration (one-time user-visible effect)

TCC keys the mic grant to bundle ID + designated requirement. Switching self-signed →
Developer ID changes the DR, so existing dev users should **expect one fresh mic prompt**;
the known failure mode is a **silent deny** instead of a prompt (TCC confusion when one
bundle ID has been seen under mixed ad-hoc/self-signed/Developer ID signatures) — remedy:
`tccutil reset Microphone io.tezra.FermixPet`, then relaunch. Document both in README.
After the switch the Team-ID-anchored DR is stable across all future updates, so users
are not re-prompted on upgrades. (The self-signed dev identity already gives
rebuild-stable grants on one machine; the Developer ID extends that stability to every
user and every release without each machine minting a local cert.) Bundle ID and signing
identity are now frozen forever — changing either resets all TCC state.

## 8. Build order

**Stage 0 (now, no gates):** A1–A9 in §4 order, each with its verify step. Update the
M9.3 doc status (P0 shipped / P2 superseded by this doc).
**Stage 1 (gate: Developer ID enrolled):** §7.1 prereqs → entitlements + version stamping
→ `package_release.sh` → local end-to-end (sign, notarize, staple, DMG, `spctl` green,
fresh-VM install test) → `release-pet.yml` → first `pet-v0.2.0` release → cask → README +
self_knowledge sweep.
**Stage 2 (gate: Stage 1 shipped):** Rive spike (§6.2). Go/no-go recorded in this doc.
**Stage 3 (gate: spike green):** commission art (§5.4 spec + PNG model sheet) →
`PetRiveView` + deletions (§6.1) → add the framework embed + inside-out signing steps to
`package_release.sh` (§7.3 step 2 — deliberately deferred to here; Rive is the first
embedded framework) → acceptance test → soak on a release-signed build → ship as
`pet-v0.3.0` → flip the cask's `depends_on macos:` to `:sonoma` in the same bump (manual
edit — the sed bump only touches version+sha) → delete PNGs, update
self_knowledge/README/CHANGELOG.

Each stage is independently shippable; Stage 0 has no dependency on the Developer ID at
all and should not wait for it.

## 9. Risks

| Risk | Mitigation |
|---|---|
| rive-ios macOS drawable leak (#413) kills always-on | Spike soak test gates the commission; view-recreation mitigation; pinned runtime |
| rive-ios black background on macOS (#451) | Known one-line `isOpaque` workaround, verified in spike step 2 |
| Rive pricing/lock-in shifts again | MIT runtime + exports-work-forever caps downside; contractual `.rev` source access |
| Mic dead after first notarized build | Entitlements file is a checklist gate (§7.3 step 6 asserts it before submit) |
| Developer ID key loss | Offline `.p12` backup alongside the cosign key |
| Notary rejection on first attempt | §7.3 verify gate catches hardened-runtime/timestamp/get-task-allow locally first |
| TCC silent-deny after identity switch | Documented `tccutil reset` + one-prompt expectation in README |
| A3 ring reorder reads wrong at 1.0× | Build-and-eyeball gate; it's a 6-line revert |

## 10. Sources (load-bearing)

Rive: github.com/rive-app/rive-ios (MIT, macOS/AppKit/SwiftUI, v6.21.0 2026-06-30);
rive.app/docs/runtimes/apple/apple (macOS 13.1+, `.frameRate()`/`.paused()`);
rive.app/pricing + rive.app/blog/rive-s-new-9-mo-plan (Cadet $9/mo export gate, no
runtime fee); issues #413 (macOS drawable accumulation), #451 (macOS black background),
#349 (CVDisplayLink vs CAMetalDisplayLink / macOS 14 fps capping).
Lottie: lottie-ios discussions#2189 + releases 4.3.x (SwiftUI/macOS);
airbnb.gitbook.io/lottie dynamic-properties (ValueProvider keypaths).
Spine: esotericsoftware.com/spine-runtimes-license (paid editor license required).
Live2D: live2d.com/en/sdk/license (revenue-triggered publication license).
Apple: developer.apple.com "Notarizing macOS software before distribution",
"Customizing the notarization workflow", "Resolving common notarization issues",
"Hardened Runtime" + `com.apple.security.device.audio-input`, TN3127 (designated
requirements/TCC stability), forums thread 701514 (Quinn: inside-out signing, no --deep,
no provisioning profile for Developer ID), thread 701581 (packaging), news saqachfa
(Sequoia removes Control-click bypass).
Sparkle: sparkle-project.org/documentation (EdDSA, appcast, XPC re-signing).
Homebrew: docs.brew.sh/Cask-Cookbook. CI: GitHub docs "Installing an Apple certificate
on macOS runners", Apple-Actions/import-codesign-certs.
