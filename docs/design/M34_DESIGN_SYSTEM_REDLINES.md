# Fermix macOS — design redlines, extracted for Swift (M33 → M34)

Source of truth: `fermix/docs/design/MILESTONE_33_MACOS_COMPANION_APP/assets/design/`
(`DESIGN_SPEC.md` + the twelve `*.dc.html` artboards + `canvas.json`). The CSS in the
artboards is the redline; this file is that CSS resolved into values Swift can consume.

Binding contract: `fermix/docs/design/MILESTONE_34_UNIFIED_MACOS_APP_IMPLEMENTATION.md`
§§3–7. **Where an artboard and M34 disagree, M34 wins** — every such point is listed in
§7 below and marked at the screen where it applies.
Later owner-authorized refinements are recorded at their affected surfaces and in §8;
those supersede the corresponding artboard treatment while preserving the product flow.

Floor: macOS 15 (M34 planned deviation 15 locks macOS 15 + universal2; M33's "open
decision" on 13/14 is settled — 13/14 are dropped). Liquid Glass on macOS 26, one
explicit Material path on 15.

---

## 1. Color tokens

All neutrals are oklch chroma 0; status colors are deliberately low-chroma (≤0.09).
Hex columns are the oklch values converted to sRGB (Oklab → linear sRGB → gamma,
clamped). `#2b5cff` is authored as hex and is kept exact — never round-trip it.

### 1.1 Semantic palette

| Token | Light oklch | Light hex | Dark oklch | Dark hex | Use |
|---|---|---|---|---|---|
| `base100` | `oklch(99% 0 0)` | `#fcfcfc` | `oklch(9% 0 0)` | `#020202` | window / content ground |
| `base200` | `oklch(97% 0 0)` | `#f5f5f5` | `oklch(12% 0 0)` | `#060606` | recessed ground, web surface, Reduce-Transparency fill |
| `base300` | `oklch(92% 0 0)` | `#e4e4e4` | `oklch(22% 0 0)` | `#1b1b1b` | pressed / hover fills |
| `ink` | `oklch(20% 0 0)` | `#161616` | `oklch(96% 0 0)` | `#f2f2f2` | primary text |
| `secondary` | `oklch(45% 0 0)` | `#555555` | `oklch(70% 0 0)` | `#9e9e9e` | body / secondary text |
| `faint` | `oklch(60% 0 0)` | `#808080` | `oklch(55% 0 0)` | `#717171` | captions, timestamps, hints |
| `accent` | `#2b5cff` | `#2b5cff` | `#2b5cff` | `#2b5cff` | the one blue |
| `accentPressed` | `#1e46d6` | `#1e46d6` | `#1e46d6` | `#1e46d6` | accent hover/pressed |
| `linkHoverDark` | — | — | `#6b8dff` | `#6b8dff` | link hover on dark only |
| `success` | `oklch(58% 0.045 165)` | `#618374` | `oklch(72% 0.045 165)` | `#8bae9e` | status dot / pill |
| `warning` | `oklch(62% 0.06 75)` | `#9c815d` | `oklch(78% 0.06 75)` | `#ceb38d` | status |
| `error` | `oklch(55% 0.09 25)` | `#a05c57` | `oklch(68% 0.09 25)` | `#ca827c` | status |
| `successText` | `oklch(45% 0.045 165)` | `#3d5d4f` | `oklch(80% 0.03 165)` | `#adc4b9` | text inside success pill |
| `pillPass` | `oklch(50% 0.045 165)` | `#4b6c5d` | `oklch(72% 0.045 165)` | `#8bae9e` | Doctor PASS letter-pill |
| `pillWarn` | `oklch(55% 0.06 75)` | `#866d49` | `oklch(78% 0.06 75)` | `#ceb38d` | Doctor WARN letter-pill |

**No token joins this table for the vendor marks.** A `markPlate` `#f6f7f9` did, for one
day, as the plate under a mark whose ink is dark and whose source publishes no light
variant (GitHub's and Notion's, as the plugin catalog ships them). It failed both ways and
is deleted: `#f6f7f9` is the light appearance's own `base100`, so on light the plate was
invisible and the black glyphs floated bare on the list ground, and on dark the two light
squares were the brightest objects on the Integrations page, beside dark tiles and a grey
disc — three tile languages in one list. A plate equal to the ground is not a plate. The
two treatments that remain are the vendor's own: **two published inks resolved by
appearance** (GitHub's kit publishes Invertocat black and white and says to use the higher
contrast option, so the app draws the vendor's choice per ground and tints nothing), and
**a mark that already carries its own light ink** (Notion's is a white page with the
wordmark cut out of it, and needs nothing under it). Which of the two plates a mark takes —
`neutral` or `bleed` — is recorded per mark in `VendorMarks/PROVENANCE.json`, never decided
in a view. The six `orb*` tokens that used to sit beside `monoDisc` are deleted with the
orb (§5.2).

**The accent is applied once, at every window's root** (`ProductTinted` in
`AppKitWindowHost`), not on the control that showed the defect. Untinted, SwiftUI's
prominent styles, switches, list selection and sheet default buttons all take the *macOS*
accent, which measured `rgb(5,124,254)` on dark and `rgb(0,112,237)` on light in the
shipped Home captures against the product's `#2b5cff` — markedly lighter on a near-black
ground, which is why the owner saw it in dark and not on white. Tinting only the toolbar's
prominent action would have swapped one two-blue surface for another: Home's three
Background switches sit directly under that button. `accent` stays scheme independent,
because lightening it is what would break the label: white on `#2b5cff` is 5.13:1 and white
on `accentHover` `#4a73ff`, the only lighter accent in the ramp, is 4.04:1 and under §9's
floor.

Artboards use `oklch(72% 0 0)` (`#a4a4a4`) for dark secondary body text where
`DESIGN_SPEC` §3 lists `oklch(70% 0 0)`. Ship the spec value `#9e9e9e` for `secondary`
and expose `#a4a4a4` only if a snapshot diff demands it (2-point delta, invisible).

### 1.2 Alpha tokens (used verbatim, never converted)

| Token | Light | Dark |
|---|---|---|
| `hairline` (card/window border) | `rgba(0,0,0,0.08)` | `rgba(255,255,255,0.10)` |
| `hairlineFaint` (row separators) | `rgba(0,0,0,0.05)` | `rgba(255,255,255,0.06)` |
| `hairlineStrong` (pending dots, dashed rows) | `rgba(0,0,0,0.16)` | `rgba(255,255,255,0.20)` |
| `cardFill` (flat card inside glass) | `rgba(255,255,255,0.60)` | `rgba(255,255,255,0.045)` |
| `chipFill` | `rgba(255,255,255,0.70)` | `rgba(255,255,255,0.06)` |
| `monoDisc` (avatar disc) | `rgba(0,0,0,0.06)` | `rgba(255,255,255,0.10)` |
| `buttonFill` (secondary) | `rgba(255,255,255,0.85)` | `rgba(255,255,255,0.08)` |
| `buttonBorder` (secondary) | `rgba(0,0,0,0.12)` | `rgba(255,255,255,0.16)` |
| `navActive` (sidebar selected) | `rgba(43,92,255,0.10)` | `rgba(43,92,255,0.16)` |
| `sheen` (retired ladder sweep; artboard reference) | `rgba(43,92,255,0.05)` | `rgba(255,255,255,0.05)` |
| `dotDone` (progress dot, completed) | `rgba(43,92,255,0.40)` | `rgba(43,92,255,0.45)` |
| `successPillFill` / `border` | `rgba(40,160,110,0.07)` / `rgba(40,160,110,0.22)` | `rgba(120,220,180,0.08)` / `rgba(120,220,180,0.20)` |
| `warnPillFill` / `iconFill` / `border` | `rgba(200,150,50,0.06)` / `0.12` / `0.22` | `rgba(235,200,120,0.07)` / `0.12` / `0.20` |
| `errorDiscFill` / `border` | `rgba(200,80,60,0.06)` / `rgba(200,80,60,0.20)` | `rgba(230,130,110,0.08)` / `rgba(230,130,110,0.22)` |
| `successGlow` (retired Home halo; artboard reference) | `rgba(40,160,110,0.15)` | `rgba(120,220,180,0.18)` |

Increase Contrast: raise every `hairline*` token to 25% alpha (`rgba(0,0,0,0.25)` /
`rgba(255,255,255,0.25)`); leave fills alone.

### 1.3 Backdrop (desktop behind windows; the onboarding stage)

- Light gradient 160°: `oklch(96.5% 0.004 250)` `#f1f4f6` → `oklch(99% 0 0)` `#fcfcfc`.
- Dark gradient 160°: `oklch(13% 0.004 260)` `#070709` → `oklch(9% 0 0)` `#020202`.
- Blob A: 560×560, `left −140, top −160`, `radial-gradient(circle, blobA 0%, transparent 62%)`, blur 70.
- Blob B: 640×640, `right −160, bottom −200`, transparent at 60%, blur 80.
- blobA/blobB alpha: light `rgba(43,92,255,0.12)` / `rgba(43,92,255,0.07)`;
  dark `rgba(43,92,255,0.20)` / `rgba(90,130,255,0.12)`.
  Home/Doctor/SetupHosted use a single blob at 0.10 (light) / 0.16 (dark);
  BootFailed uses one blob at 0.09 / 0.14; MenuBar uses 480×480 at 0.10 / 0.16.
- Blobs **drift only on Welcome**: `drift-a` 18s (translate 60,30 · scale 1.08),
  `drift-b` 22s (translate −50,−24 · scale 1.06), both ease-in-out infinite alternate-shape.
  Static everywhere else. Reduce Motion → static everywhere.
- Traffic lights (mock only; real windows use system chrome): `#ff5f57` `#febc2e` `#28c840`, 12pt.

## 2. Type ramp

SF Pro through `.system`; SF Mono through `.system(design: .monospaced)`.
Sizes are points; leading is the artboard's `line-height`.

| Role | Size / leading | Weight | SwiftUI | Use |
|---|---|---|---|---|
| Display | 28 / 34 | 600 semibold | `.system(size: 28, weight: .semibold)` + `.lineSpacing(6)` | onboarding headlines |
| Title | 22 / 28 | 600 | `.system(size: 22, weight: .semibold)` | step titles ("Connect your AI") |
| TitleLarge | 24 / 30 | 600 | `.system(size: 24, weight: .semibold)` | "Fermix is live" only |
| Headline | 17 / 22 | 600 | `.system(size: 17, weight: .semibold)` | section and sheet headings; Starting and Applying |
| StatusHeadline | 19 / — | 600 | `.system(size: 19, weight: .semibold)` | historical status treatment; Home uses a native form row |
| Body | 15 / 20 | 400 | `.system(size: 15)` | descriptions, setup copy, CTA labels |
| BodyCompact | 14 / 20–21 | 400–600 | `.system(size: 14)` | step subcopy, row titles |
| Callout | 13 / 18 | 500–600 | `.system(size: 13, weight: .medium/.semibold)` | buttons, list rows, menu items |
| CalloutSmall | 12 / 17 | 400–600 | `.system(size: 12)` | hints, chips, footer |
| Caption | 11 / 14 | 500 | `.system(size: 11, weight: .medium)` + `.tracking(0.44)` when uppercase | section labels, timestamps |
| Mono | 13 | 400 | `.system(size: 13, design: .monospaced)` | commands, tokens |
| MonoLog | 11.5 / 16 | 400 | `.system(size: 11.5, design: .monospaced)` | log lines |

Uppercase section labels: +4% tracking (11pt → `.tracking(0.44)`; the artboards use
`letter-spacing: 0.05–0.07em` on 11–12pt labels — 0.06em is the median, `.tracking(0.66)`
at 11pt is within the redline). All type must respond to Dynamic Type where AppKit allows;
never hardcode a frame height that clips at larger sizes.

## 3. Spacing, shape, hit targets

- Spacing scale: **4 · 8 · 12 · 16 · 24 · 32 · 48**. Nothing off-scale except the
  documented odd paddings below (they come from the artboards and are load-bearing).
- Radii: controls **8–10** · cards **12** · windows/popovers **14** · menu rows **7** ·
  small icon tiles **6–8** · pills/orbs/dots **capsule/circle**.
- Window content padding 22–26. Onboarding horizontal padding 90–120 (per screen below).
- Titlebar zone 52 tall, 20 horizontal. Progress-dot zone 44 tall.
- Hit targets: menu rows ≥28 (32 designed) · buttons ≥36 · onboarding CTAs 44.
- Borders are 1pt hairline; the Telegram hero card is the only 1.5pt border, in accent.
- Depth 0 inside a surface: cards are flat (fill + 1pt border, **no shadow**).
  Shadows belong to windows, popovers, the primary button, and the orb only.

## 4. Materials — the two glass recipes

### 4.1 Window / panel glass (onboarding window, Home, Doctor, SetupHosted)

| Property | Light | Dark |
|---|---|---|
| fill | `rgba(255,255,255,0.66)` | `rgba(26,26,29,0.58)` |
| blur | `blur(30) saturate(1.5)` | same |
| border | 1pt `rgba(0,0,0,0.08)` | 1pt `rgba(255,255,255,0.10)` |
| top inner highlight | `inset 0 1 0 rgba(255,255,255,0.75)` | `inset 0 1 0 rgba(255,255,255,0.12)` |
| drop shadow | `0 32 80 rgba(20,24,40,0.16)` | `0 32 80 rgba(0,0,0,0.55)` |
| radius | 14 | 14 |

### 4.2 Popover glass (menu-bar panel)

| Property | Light | Dark |
|---|---|---|
| fill | `rgba(255,255,255,0.72)` | `rgba(26,26,29,0.62)` |
| blur | `blur(30) saturate(1.5)` | same |
| border | 1pt `rgba(0,0,0,0.08)` | 1pt `rgba(255,255,255,0.10)` |
| top inner highlight | `inset 0 1 0 rgba(255,255,255,0.80)` | `inset 0 1 0 rgba(255,255,255,0.12)` |
| drop shadow | `0 22 60 rgba(20,24,40,0.20)` | `0 22 60 rgba(0,0,0,0.60)` |
| radius | 12 | 12 |

### 4.3 SwiftUI mapping (one path per configuration, no silent fallback chain)

```swift
// Historical glass recipe. Decision 1 retired GlassSurface and its last caller;
// this is not the Settings error bar, which uses .bar on both supported systems.
@ViewBuilder
func glassBackground(_ recipe: GlassRecipe) -> some View {
    if reduceTransparency {                       // opaque, same border/shadow
        shape.fill(Color.base200)
    } else if #available(macOS 26.0, *) {
        shape.fill(recipe.tint)                   // the fill above, as a tint
             .glassEffect(.regular, in: shape)
    } else {                                      // macOS 15 floor
        shape.fill(.ultraThinMaterial)
        shape.fill(recipe.tint)                   // same tint overlay
    }
}
```

- The retired recipe declared three configurations: Reduce Transparency solid, Liquid Glass on macOS 26, and Material on the macOS 15 floor, with identical border, inner highlight, shadow and radius. The accessibility setting was checked ahead of the operating system.
- **Scope, and this is the M34 change: glass is the navigation layer only, and on macOS 26 all of it is system provided.** The inset floating sidebar, the toolbar's glass groups, sheets, pickers and toggles come from the system. The app writes no `glassEffect` in the content layer, no glass container, no custom background behind a bar, and no background extension effect. Scroll edge effects are automatic.
- **The app draws no container of its own** in the primary window, in either of its presentations: a box exists only where the system draws one, which is a form section, a sheet, or the sidebar. There are therefore no cards to make flat or glass, and the recipes in §4.1 and §4.2 apply to nothing the app draws. The settings presentation (§5.8) inherits the rule unchanged, which is the whole of what the retired Settings window contributed to this section.
- No current content surface writes that glass recipe. Settings error bars use `.bar` material on both systems, or solid `base200` under Reduce Transparency; the availability split changes placement only (§5.8). Pending restarts use the Settings toolbar and draw no bar. Decision 1 is taken (§8.1), so `GlassSurface`, `BackdropView` and the two window recipes are deleted rather than kept for the assistant, and the view-background form of the recipe goes with them. The popover recipe in §4.2 is retired with the menu bar popover. `ContainerRuleTests` bans the deleted primitives by name, so none of them can come back without the gate saying so.
- Inner highlight in SwiftUI: `.overlay(shape.strokeBorder(LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.04)), lineWidth: 1))`.
- **Availability is an inventory, and the gate is membership rather than a count.** Five sites are written by the M34 design, each with its declared macOS 15 form: the toolbar spacer (separate toolbar item groups), the window resize anchor (instant resize), the safe area bar (a safe area inset with the bar material), the prominent glass button style (bordered prominent), and shared background visibility for status text (plain text with no background modifier). The inventory is those five: decision 1 deleted `GlassSurface`, so the two sites inside it are gone with it. The structural gate asserts that every availability site in the tree is on this list, never that the list has a particular length.

### 4.4 Primary button

Fill `#2b5cff`, label white 15/600, radius 10, height 44 (onboarding) or 36 (in-window,
radius 9, label 13/600). Shadow `0 6 18 rgba(43,92,255,0.35)` + inner highlight
`inset 0 1 0 rgba(255,255,255,0.25)`. Pressed → `#1e46d6`, shadow to `0 3 10`.
Secondary button: `buttonFill` + 1pt `buttonBorder`, ink label, weight 500, no shadow.

## 5. Screen anatomy

Every onboarding screen: backdrop 880×600 canvas in the artboard; the **window itself is
800×520 fixed, non-resizable, centered**, radius 14, window glass (§4.1). Titlebar 52.
Content region 400–440. Progress-dot zone 44 at the bottom: active = 22×6 accent capsule,
done = 6×6 `dotDone`, pending = 6×6 `hairlineStrong`, gap 8, centered.

### 5.1 Welcome (`Main.dc.html`)

Content 420 tall, horizontal padding 96, centered, text centered.
- Mascot 108×108, `drop-shadow(0 10 24 shadow)`, bottom margin 18, entrance `mascot-in`
  700ms `cubic-bezier(0.34,1.4,0.64,1)` (0% opacity 0 · y+18 · scale 0.92 → 60% y−4 ·
  scale 1.02 → 100% rest).
- Wordmark: inline SVG, height 30, `currentColor` letterforms + two `#2b5cff` eye-dots
  (r 4.7 at x 2 and 15 of the `i` group). Bottom margin 22. `rise-in` 480ms delay 120ms.
- Value sentence: Body 15/22 `secondary`, max width 460, `rise-in` delay 200ms.
- CTA 44 tall, padding 0/28, radius 10, primary. It lives in §5.8's bottom bar.
- **The caption under the sentence is gone** (owner directive of 2026-09-03: "Too many
  subtexts/headings throws off. doesnt look elegant"). Welcome is a wordmark, a title and
  one line, and nothing else: how long setup takes is a promise the next screen's four-row
  ladder shows rather than states. The `Use an existing Fermix home…` link stays, because
  it is an action rather than a third thing to read, and it keeps the block's `rise-in`
  delay of 300ms.
- No feature grid, no checkboxes, nothing else.
- **One title and at most one line of subcopy is the rule on every assistant screen**, and
  the one text column all eight measure against is `OnboardingMetrics.contentWidth` (460).
  A width literal on a surface is that surface picking its own measure, which is how the
  assistant came to read as eight layouts; a build gate scans the five surface files for
  one.
- Progress dots: 1 of 4 active.

### 5.2 Starting and Applying — native progress (supersedes `Activate.dc.html`)

The owner's request for calmer native status presentation applies to these two mechanical
stages. They share one compact progress column; Welcome and Ready retain their branding,
headings and artwork. The existing navigation, activation checks, cancellation, finish
gate and restart confirmation are unchanged.

- **No mascot or status chip on either mechanical stage.** Starting's interim breathing
  mascot is retired with its custom loop. The earlier orb and its dedicated palette tokens
  remain deleted. Ready and Pet keep the shared still artwork described in §5.5.
- **One column**, vertically centred, with the existing assistant horizontal padding and
  maximum `OnboardingMetrics.contentWidth` (460). Headline uses `Headline` 17/22 semibold;
  optional subcopy uses `BodyCompact` 14/20 in `secondary`, wrapping vertically. The gap
  between headline, subcopy and checklist is `Spacing.m` (16). Starting's background-item
  explanation appears when the activation plan calls for it; Applying has no subcopy.
- **Native checklist**: shared `ProgressLadder`, with a 20pt marker column
  (`SettingsRowMetrics.markSize`), `Spacing.s` (12) between marker and text, and vertical
  row padding `Spacing.xs` (8). Rows grow with their text; there is no fixed height, card,
  separator overlay, sheen or custom spinner. Text uses `BodyCompact`, in `ink` for active
  and completed rows and `secondary` for pending rows.
  - done: system `checkmark.circle.fill`, accent.
  - active: small native `ProgressView`; Reduce Motion uses static `circle.dotted`, accent.
  - pending: system `circle`, secondary.
- Row order and headlines come from the existing activation/apply state, with copy in §7.
  Applying includes a restart row only when required or already running.
- Starting retains its negotiated daemon and `/health/live` checks, never `/health/ready`,
  and the existing 90-second timeout to Boot failed.
- VoiceOver: each row is one element, label = row text, value = `done|in progress|waiting`;
  announce state transitions through the existing accessibility announcer. Markers are
  hidden from accessibility because the row already carries their meaning.
- Progress dots and bottom controls retain the current assistant step and flow (§5.8).

### 5.3 Connect AI (`ConnectAI.dc.html`)

Content 400, padding `8 / 110 / 0`, centered. Title 22 + subcopy 14/20 `secondary`,
bottom margin 24. **Subcopy and column share one width**, `OnboardingMetrics.contentWidth`
(460), which is §5.1's one-column rule: the artboard's 430 subcopy inside a 460 column was
two measures on one screen. Row gap 12.
- **The rows are grouped-form rows, and the app draws no card around them** (2026-09-04).
  The artboard's 64-point card with its own fill, hairline and radius was the third
  container grammar in three consecutive screens — cards here, a grouped form on About
  you, bare rows on Ready — which read as three designs rather than one journey. One
  `Form(.grouped)` at `OnboardingMetrics.contentWidth`, one section, the system's row and
  separator material, its own ground hidden so the section card is the only box.
- Provider row: a grouped-form row. 28 disc `monoDisc` + **provider mark** (M34: no
  fabricated monogram — see §7.4) — 28 rather than the artboard's 36, because a form row
  is a line of text and a mark taller than the row sets the row's height; name 14/600 over
  hint 12 `secondary`; trailing system button carrying the daemon's verb.
- API-key row: the same row with an 18pt key glyph on `base200` in place of the vendor
  disc, title, hint, and the trailing `Add key…` button. The dashed border is gone with
  the cards.
- **No skip link** (owner decision of 2026-09-05): connecting an AI is the one
  required decision, and a link that could only leave setup added nothing that
  Home's `Continue setup` does not already say. The 2026-09-04 version of this
  screen carried a link that left the assistant for Home; it is withdrawn.
  **The bar's continue action is on the same rule**:
  About you and Applying are reachable only once the daemon reports no gating
  provider failure, and a continue refused for one states
  `onboarding.blocked.provider` here rather than moving.
- **A sign-in the daemon refuses before it starts is stated under the rows**, in
  the daemon's own sentence, at the grouped form's footer and in the refusal
  tone the credential sheets use. The waiting sheet reports a flow that is
  running, so it never opens for a start that was refused, and the row was left
  exactly as it was: the button read as dead (owner report of 2026-09-04, on an
  engine serving `setup.state.get` and not yet `auth.start`). The sentence
  clears when the next attempt starts.
- Progress dots: 3 of 4 active.

### 5.4 Connect channel (`ConnectChannel.dc.html`)

Content 400, padding `8 / 90 / 0`. Title 22 + subcopy 14/20, max width 430, bottom margin 26.
Row of two columns, total width 620, gap 14.
- **Telegram hero** (flex-grow): padding `22 18 18`, radius 12, `cardFill`,
  **1.5pt `#2b5cff` border**, shadow `0 8 26 rgba(43,92,255,0.18)`, items centered, gap 12.
  44 disc `rgba(43,92,255,0.12)` + 22pt accent paper-plane glyph; name 15/600;
  hint 12 `faint`; **QR area 92×92, radius 8** (M34: real payload or truthful instructions —
  §7.1); full-width Connect button 36 / radius 8 / primary 13/600.
- Alternates column width 240, gap 14: Slack, Discord. Each padding 16, radius 12,
  `cardFill` + hairline, 36 `monoDisc` + 18pt glyph, name 14/600, hint 11 `faint`.
- No skip link. Progress dots: 4 of 4 active (this artboard) —
  in the shipped 5-step ladder Connect channel is step 4 and Ready is step 5.

### 5.5 Ready (`Ready.dc.html`)

Content 424, padding 0/110, centered.
- **Mascot 96×96, bottom margin 12**, through `MascotArtwork`, also used by the Pet tab.
  Welcome and Ready branding is unchanged by the mechanical-stage refinement in §5.2.
  **No disc**, here or anywhere else the still mascot is
  drawn (owner directive of 2026-09-04). The disc was added because the mascot's body is
  near-white and was thought to lose its edge on the assistant's near-white light ground; on
  the shipped artwork the body's own blue rim and shadow hold the silhouette in both
  appearances, and the plate read as a chip behind a character. The rule that put it in the
  component rather than on one screen still stands: Ready and Pet share the same still
  treatment. `MascotArtwork` composes ring behind body behind face from `PetAssetCache`,
  using the open-eye `listening` pose and its resting scale. Its 132/108 canvas leaves room
  for the ring's 1.20x orbit; it is not a ground behind the character.
- **The screen reads readiness from the daemon when it appears.** Its whole claim is the
  daemon's, and readiness used to arrive only from the activation that walked here, so every
  other way in — a route resuming at Ready (§3.4), and every fixture launch of this surface —
  drew the "not answering yet" notice against a daemon that was up, and the screen could not
  be looked at at all. Connect your AI already reads readiness on appear for the same reason.
  The fixture home for this start is `configured` — the only machine Ready renders on,
  since it refuses to draw while a gating failure stands. The bloom rings and the pop stay deleted: the success
  is carried by the pill's words. The wordmark that stood here in their place is gone too,
  because it said `Fermix` directly above a line that already says `Fermix is live`, which
  is the repeated label the 2026-09-03 directive asks the assistant to lose.
- "Fermix is live" TitleLarge 24/30, `rise-in` delay 150ms, bottom margin 6.
- Success pill: height 24, padding 0/11, capsule, `successPillFill` + border, 7pt success
  dot, label 12/500 `successText`; bottom margin 16; `rise-in` delay 220ms.
- **The `Next, if you like` section label is gone.** Each next-step row names what it opens
  and carries its own chevron, so the eyebrow was a heading over three self-describing rows.
  The provider and model line under the pill is this screen's one line of subcopy, and it
  moves from `faint` to `secondary` now that no caption tier sits beneath it.
- **Next-step rows and the CLI row are grouped-form rows** in one `Form(.grouped)` section
  at width 470 (`OnboardingMetrics.nextStepsWidth`), the same grammar §5.3 and About you
  keep (2026-09-04). Drawn bare on the window's ground, with the CLI row a hand-drawn card
  in the middle of them, they were the third container shape in three screens. Each
  next-step row carries the system `chevron.forward`, the direction-relative symbol that
  mirrors under a right-to-left layout.
- CLI row: a grouped-form row. 20 leading checkbox + title 14/600 with `fermix` in Mono
  13; hint 12 `secondary`; the copy and verify buttons trailing.
  **M34: unchecked by default (§7.2).** `rise-in` delay 300ms.
- Actions gap 14, top margin 26: primary "Open Fermix" 44/0-28/radius 10;
  secondary "Advanced setup" 44/0-22. `rise-in` delay 380ms.
- Progress dots: last active.

### 5.6 Boot failed (`BootFailed.dc.html`)

Replaces Activate on the 90s timeout. Content 440, padding `26 / 120 / 0`.
- Amber-outline disc 76, capsule, `errorDiscFill` + 1pt `errorDiscBorder`, 32pt triangle
  glyph stroked in `error` (1.8 stroke). Bottom margin 22. No red flood anywhere.
- Title 22 "Fermix couldn't start"; body 14/21 `secondary`, max width 440, bottom margin 26.
- LAST LOG LINES card: width 470, radius 12, `cardFill` + hairline. Header 40 tall,
  padding 0/16, caption 11/600 tracking 0.06em `faint`, 1pt `hairlineFaint` under it.
  Body padding 12/16, MonoLog 11.5/16 `secondary`, 3 lines, gap 5, error line in `error`.
- Actions gap 14: primary "Run Doctor" 44/0-24 with 16pt pulse glyph; secondary
  "View full log" 44/0-22; ghost link "Try again" 14 accent.
- No progress dots on this screen.

### 5.7 Home and the primary window (`Home.dc.html`, superseded where noted)

Primary window **1040×640 default, resizable**; minimum **760×520**, one minimum rather than the pair the previous revision carried, because the settings presentation (§5.8) runs inside this window and its 240pt pane column plus a readable content column has to fit at every reachable size; frame autosaved. The window is a `NavigationSplitView` with a unified toolbar and an inline title: **no window glass, no backdrop, no painted ground, and no drawn titlebar zone** (the artboard's 52pt titlebar was a mock of chrome the window now gets from the system). Sizing is expressed in AppKit terms, because the app hosts SwiftUI inside `NSHostingView` and has no SwiftUI `Scene`: `window.minSize`, the style-mask flags, and `window.isRestorable`.
- **Sidebar**, column min 180 / ideal 200 / max 260, system list styling, no drawn right border. Rows are system labels with SF Symbols: **Home · Doctor · Logs · Pet**. **The Setup row is gone** (M34 §5: setup is a task, not a destination); engine identity moves into Home's Runtime section and update state into the attention row and the update surface. **Pinned under the rows, in the footer position, is one more system row: Settings (gear)**, always present whatever the daemon reports, keyboard reachable in the same order as the rows above it, and carrying ⌘, as its shortcut. **It is the last row of the sidebar's own `List`**, held on the bottom edge by one empty, unselectable spacer row whose height is measured off the column rather than written down (2026-09-04). Drawn as a second one-row `List` in a bottom safe-area inset it was pinned and unreachable: two lists are two selection contexts, so arrow keys from Pet stopped at Pet, against the sentence above. It is the app's one visible way into setup, added on the owner's directive of 2026-09-03 after he opened the app and found none, and it is a row rather than a toolbar button because it is the slot he named for the dropdown the tab list may become once the window gains a chat surface. It is **not** the artboard's sidebar footer returning: that footer drew a wordmark, a version and engine identity inside a box the app painted, it stays deleted, and the footer position now holds this one system row and nothing else. The sidebar stays the chat-ready shell: a future Chat row is one more entry.
- **Collapse** is the system's, three ways: the leading toolbar toggle, View > Show/Hide Sidebar (⌃⌘S), and drag. Width-driven collapse below **840pt** and restore above **900pt**: the same offsets from the window minimum the previous revision chose, +80 and +140, carried onto the new 760pt minimum, where the old 720/780 pair could never fire at all. The band between them is 60pt, unchanged. An explicit hide is persisted and never overridden by width. Never hidden on first launch. No hover reveal, no overlay. Entering the settings presentation hides the sidebar as a presentation rather than as a preference, and leaving it restores the visibility the user chose.
- **Content** is one `Form(.grouped)`; the artboard's hero card and section cards are not drawn. The owner's calmer-status refinement places **Status** in the first native `LabeledContent` row of Background, with the current state in normal secondary text and the accessibility `updatesFrequently` trait. There is no separate display headline, status dot or halo. Uptime appears once, in Runtime. Sections, in order:
  - **Background**: the Status row followed by three independent switches: run in the background, open at login, and show in menu bar. The first two control registration; the third controls visibility. Lifecycle actions retain Enable / Disable wording.
  - **Attention**: one row per daemon-reported gap, each with exactly one trailing action, and one centered line when there are none. Sources are readiness failures, which carry a gating flag, a copy key and a pane deep link, the restart reasons, and the five standing coexistence descriptors M34 §5 publishes as one list: legacy service unit, restricted keychain items, engine PATH baseline, restart pending, and settings changed outside Fermix. Row wording comes from the app catalogue keyed by the **copy key** alone, never from the pane and never from a command line sentence: five channel failures and the voice companion collapse onto two panes, so a pane key cannot tell Telegram from Slack. The pane is the deep link and nothing else. The copy key is a closed set the daemon publishes, so the catalogue's coverage gate is written over that set, with the provider family enumerated at test time, rather than over a count of components.
  - **Runtime**: labelled rows for engine, management protocol, uptime, provider, channels, skills and tools, the last two as counts only.
- **Toolbar**: leading system sidebar toggle plus the inline title; trailing at most one tinted primary action while its condition holds (continue setup, or finish updating), then at most one secondary group, never more than three groups. Status text never sits on glass.
  - **That tinted action carries the product accent**, `.tint(Palette.accent)`, on both systems: prominent glass on macOS 26 and `borderedProminent` on the 15 floor choose the style and nothing else. Untinted it took the macOS accent instead, measured off the shipped captures at `rgb(5,124,254)` on dark and `rgb(0,112,237)` on light against the product's `#2b5cff`, so Home's `Continue setup` was the one primary action in the app that was not the product's blue, and on a near-black ground the system blue is markedly lighter and more saturated, which is why the owner saw it in dark and not on white. §1.1 already calls one surface showing two blues that are not selection plus primary action a defect.
  - The accent stays scheme independent. **No dark-appearance variant is added**, because lightening it is what would break the label: white on `#2b5cff` is 5.13:1, and white on `accentHover` (`#4a73ff`), the only lighter accent the ramp has, is 4.04:1, under §9's 4.5:1 floor.
- **Runtime rows carry a vendor mark where the fact is about a vendor.** Only the provider row is, and the daemon publishes the provider's key there, so nothing is parsed out of the sentence beside it. The mark is 20pt (`SettingsRowMetrics.markSize`), which is the size every grouped-form row draws one at.
- Doctor and Logs live in the same window with the same rules: Doctor is a banner plus one grouped list with its actions in the toolbar and **no right rail**, each failed row carrying the daemon's remediation sentence and one action; Logs runs edge to edge with search, level, pause and export in the toolbar. Pet keeps its preview and call controls in a grouped form, restyled off the deleted card and titlebar primitives.

### 5.8 Native setup: the assistant and settings inside the primary window (supersedes `SetupHosted.dc.html`)

There is no hosted surface and no web view. The artboard is retired: its tab rail, its opaque web ground, its 52pt drawn titlebar and its loopback footer describe a surface the app no longer has. What is retired is that artboard and the hosted pane inside the app, never the browser setup: the daemon goes on serving its Setup LiveView for every Homebrew formula install, on macOS exactly as on Linux, and this document does not draw it.

**Setup Assistant** (a presentation of the primary window, on the owner directive of 2026-09-05). Setup and recovery retain their existing screens and model; they no longer create an auxiliary window. Entering the assistant hides the app sidebar and grows a smaller window to at least 800×520 without shrinking it on exit. Home, setup, recovery, and settings keep the same `NSWindow`.
- **Chrome** uses the primary window and its system toolbar, with no drawn backdrop or glass card. The stage caption stays in the bottom bar. A toolbar chevron returns to Home; Starting uses the existing cancellation path, and Applying keeps the user on its active transaction. The bottom Back action still goes to the previous setup step.
- The single-window decision preserves the setup flow. The native progress refinement in
  §5.2 changes Starting and Applying presentation only; Welcome and Ready branding remains.
- **The assistant paints no ground of its own** (2026-09-04). It shows the system window
colour, which is what every other window in the app shows; painting `base100` here gave one
application two window colours and made the assistant read as a different app the moment a
person moved between it and the primary window.
- The 800×520 measure is a minimum growth target for the assistant, not a second fixed window. Its root fills the primary window inside the safe area; resizing and frame restoration remain owned by AppKit.
- Content region 400–440 with the published horizontal padding; **bottom bar 64pt** carrying back (plain) and exactly one default continue action; no screen carries a skip link (§5.3). Progress dots keep §5 geometry across the four decision points — Welcome, Connect your AI, About you and Ready, the retired Connect channel screen having been the fifth — and the two mechanical stages inherit the step they run inside.
- Screens: Welcome, Starting (the native checklist from §5.2, with rows from its activation plan), Connect your AI (rows from §5.3, 460 wide, the dashed API-key row becoming a sheet trigger), About you (a grouped form), Applying (the same native checklist with a conditional restart row), Ready (§5.5 with next-step rows in place of the advanced action), plus Boot failed (§5.6) and Recovery.
- The finish gate is the daemon's: negotiation inside the window plus `/health/live`, no gating readiness failure, and no pending restart. Advisory failures render as one line whose action opens Home, never as a block.
- Restart-only entry starts the restart without rewriting personalization. A refused About you save stays on About you and states the refusal, even when the earlier settings already satisfy readiness.

**Settings, a presentation of the primary window** (owner directive of 2026-09-03: "the setup/settings should launch in the same app/window"). There is no Settings window, no `WindowKind.settings`, and no second place to look.
- **Entering** hides the app sidebar (Home · Doctor · Logs · Pet) and puts the settings layout in the same window: a **240pt pane column** on the left, the pane's form on the right. Leaving restores the surface the user came from and the sidebar visibility they had.
- **The back control** is at the toolbar's leading edge: **the chevron alone** (`chevron.backward`, the direction-relative symbol the system's own back button draws and the only one that mirrors under a right-to-left layout), a system toolbar button, labelled for VoiceOver as "Back to Fermix". The word beside the chevron is gone and so is its string (owner directive of 2026-09-03: "The back button < Fermix isnt aligned properly, i think just the < arrow should be fine"). The word was the misalignment: a chevron glyph and a 13pt word have different optical centres, so the pair sat low against the inline title however the label was styled, and the system's own back control carries no word either. It keeps the system button's chrome rather than being flattened, because that is what supplies the standard leading-edge position, the standard hit target and the vertical centring. **Escape does the same** while no sheet is open. There is no second way back and no close button, because nothing is closing.
- **Pane column, fixed 240pt**: a system `List` in four titled sections (Assistant, Connections, Capabilities, System) holding thirteen panes, with **the search field at its top** (`.searchable(placement: .sidebar)`, indexing pane titles and row labels) and the sidebar toggle removed from the toolbar. Not collapsible, no drawn border, last pane restored from user defaults.
- **Content column: one `Form(.grouped)` per pane, maximum 640pt wide, centred in the width left over.** Window title equal to the pane title, which is the shows-title flag on the window descriptor, now set by the primary window alone. Section headers and footers are the system's; the app draws no card, no rail, and no divider overlay. Section headers are written in sentence case unless the owner takes the HIG side of the title-case decision (§7).
- **Window size: 1040×640 default, `window.minSize` 760×520** (§5.7 carries the same two numbers, because it is the same window). Entering settings grows a window smaller than the default up to it: animated, anchored at the window's top-left, and clamped to `NSScreen.visibleFrame` so it can never grow off-screen or under the menu bar. Leaving settings does not shrink it back. **One growth path on both systems**, an AppKit `setFrame(display:animate:)` that holds the frame's top-left (an AppKit origin is its bottom-left), because the app hosts SwiftUI inside an `NSHostingView` and has no `Scene` for `.windowResizeAnchor` to reach; there is no macOS 26 alternative, and the geometry is a pure function of three rectangles so it is provable without a window server. The two numbers are **content** sizes, the unit the window descriptor builds with, while the growth rule works in frame units, so the seam asks the window how much chrome sits on top rather than assuming the two are equal. They are equal today: every window descriptor here carries `.fullSizeContentView`, which puts a window's content rect and its frame rect on one rectangle. **The same clamp is a ceiling on every window, not only on growth**: presenting fits a window to the visible frame of the screen it opens on, before it is shown, so a frame restored from an autosave written on a larger display, or a default larger than the display it lands on, is corrected before anybody sees it and the corrected frame is what gets saved. **A window's size is its descriptor's and never its content's**: the hosting view's own sizing options are cleared, and no view restates the size its descriptor owns.
- **No inline scrollbars** (owner: "try to avoid the inline scrollbar"). The form scrolls only when its content is taller than the window, scroll indicators are never shown, the top and bottom edges carry the automatic scroll edge effect of §4.3, and a short pane does not scroll at all. **No nested scroll view inside a pane**: a long list either groups and collapses in place, or opens a sheet that owns its list. The plugin list is the Integrations pane's own single scroll, kept short by its pills and its search; the model picker and the installed-apps picker are sheets. The rule is the window's and not one pane's, so **the pane column carries it too**: thirteen panes in four sections are taller than the 640pt default, so that column scrolls, and it hides its indicators and fades its edges by the same two modifiers the form uses. Every scroll container the settings presentation owns is on this rule, which is how it is gated.
- **One Settings-level Restart… toolbar action** appears when saved settings require a restart or a restart will finish an engine update. It belongs to the Settings presentation, so changing panes neither adds another reminder nor repeats a banner above the form. Its tooltip and accessibility hint carry the reason details; activating it uses the existing restart command and opens the existing confirmation sheet. The sheet retains every daemon reason, conversation impact, refusal and restart choice (§7). The action is disabled when that command is unavailable. No restart happens merely because the reminder appears, and no dismissal preference or second pending-state store is added.
- **Error banners retain the top safe-area slot**, carrying `.bar` material on both systems and solid `base200` under Reduce Transparency. `safeAreaBar` on macOS 26 and `safeAreaInset` on the floor change placement only. An external change or unreadable file takes priority over the pending-restart action; an engine that this app cannot update states the problem with no restart action.
- **External-change banner**, one line and one action, is shown while the settings file has changed outside Fermix. The refusal itself lives in the daemon's shared write tails, so the browser door shows the same banner, and the reload re-records the daemon's baseline so the write after it succeeds. A file the daemon cannot read or parse is a different state: it shows no reload action, because the reload would re-run the read that failed, and routes to Recovery with the parser's own sentence and a reveal action.
- **Row kinds** rendered by one descriptor form: toggle to `Toggle`; choice to `Picker`; text to `TextField` with a prompt and **a rounded bezel filling the value column the form
already laid out**, because a grouped form strips a field's chrome and the value then
reads as one more fact in a page of facts (`Your name  Sujeeth` said nothing about being
editable). No width of its own: a fixed measure squeezed the label beside it, and a
ceiling let each field shrink to its own value; number to a `Stepper` showing its value, or a `Slider` when the daemon's own bounds and step suit one; secret to a secret row reading stored with replace and remove, or add; list to a list editor. A row the daemon marks read-only renders as `LabeledContent`. Row label, footer, options and bounds are the daemon's; the app supplies no field inventory.
  - **A row's own vertical rhythm is `SettingsRowMetrics`, not the form's.** A descriptor row is one grouped-form row however many lines it draws, so the form's row insets stop at its edge and never reach inside it. Three gaps, all on §3's scale: `captionGap` 4 between a control and the caption that explains it, `entryGap` 8 between the entries of a stacked editor, `stackGap` 12 between the peer blocks of one (its label, its entries, the field that adds one). The list editor took the caption gap for all three, which ran its label into its entries and put two 24pt `Remove` buttons a point apart; that is what the owner saw on Sandbox ("some of the items are stuck together without proper spacing"), and it is fixed in the shared row rather than in that pane, so every descriptor pane takes it.
  - **A row that is about one vendor draws that vendor's mark** at `SettingsRowMetrics.markSize` (20pt), before its label: providers, channels, and the sign-in clients section. That measure is the row's whole leading accessory column, so a row that leads with a system symbol instead — Ready's next-step rows — takes the same 20 and lines up with them. 20 rather than the plugin page's 28, because a grouped-form row is a line of text and an accessory taller than its cap height sets the row's height instead of sitting inside it. **A mark on transparency is inset to 0.72 of the tile and the neutral symbol to 0.55**, both raised on 2026-09-04: at 0.56 the 20pt tile gave a mark an 11pt box, so Mistral's logotype — which its own file centres in a square with a third of the height empty — drew at about 7pt beside 20pt marks that bleed, and the neutral symbol at 0.42 was an 8pt chip on three of the seven provider rows, which read as a smudge rather than a symbol. The vendor's own whitespace is kept; a file is never cropped, because no record here permits editing a mark. **A mark whose file carries its own ground bleeds and is never inset**: Telegram's roundel, inset, drew an 11pt blue disc inside a 20pt grey one.
  - **A fact row draws no mark.** Home's Runtime section is seven labelled facts in one flush column, and a leading tile on the single row that names a vendor indented that label alone against the other six; for the provider the owner actually runs there is no retrievable mark either, so what the row carried was a neutral placeholder chip beside a raw wire key. A mark belongs on a row that is *about* a vendor, which is the three lists above and the assistant's Connect your AI discs.
  - **A channel row's title is the daemon's**, from `settings.sections` (`channels.whatsapp` → `WhatsApp`), not the wire identifier with its first letter raised, which produced `Whatsapp` beside WhatsApp's own mark. A channel the daemon named with no section published shows the identifier as the daemon wrote it, which is visibly a key rather than a spelling the app invented.
- **Integrations is a page in the Codex shape**, not a stack of groups (owner directive of 2026-09-03, with the Codex Plugins page supplied as the reference): a header carrying the pane title and a one-line subtitle; a row of kind pills carrying live counts, the selected one filled, with the search field at that row's trailing edge; then a flat list whose row is a 28pt rounded icon tile holding the plugin's own logo, the name at 13.5/500, a second line beneath it at 12 `secondary`, and a trailing `Toggle`. **That second line is one rule with two branches**: an installed row draws the daemon's own `status_sentence`, because where it stands is the whole question about something already on this Mac; a row that is not installed draws the manifest summary, because what it does is the only question there is about it yet. Drawing the summary wherever there was one is what hid the state the owner reported: an installed, switched-on plugin signed in to nothing said `Read schedules, find availability` under a switch reading on, and people read "on" as "working". `IntegrationRowModel.subtitle` is the one owner of that rule. Pills: Installed · Available · MCPs · Features. A row opens its detail, and **says so**: a trailing `chevron.forward` and a hover fill, because a click that opened a sheet with no pointer change, no highlight and no chevron was advertised by nothing at all. Sign-in clients are a section at the foot of the list, never a group, and they keep logos of their own. No box around the list, no collapsible sections, generous vertical rhythm, both appearances. **The toolbar's inline title is removed on this pane alone**: the page header carries the title, and the window title two lines above it said the same word twice. The window keeps its title — it is what the Window menu names this window by — and only its drawing in the toolbar is dropped.
  - **No rules between rows** (owner directive of 2026-09-03: "remove any extra horizontal separation. keep it clean"). A plain `List` draws a separator under every row, and these rows are already an icon tile over two lines of text, which read as a ruled ledger. The rhythm is the row's own vertical padding. The rule is the list's, so the sign-in clients section inside it takes it too.
  - **The tile holds a real logo, vendored with provenance.** The logos come from fermix's own checked-in plugin catalog, which publishes one per entry, decoded out of it and recorded in `VendorMarks/PROVENANCE.json` beside the catalog entry and version they came from. The three native driver features take Fermix's own marks from the engine's setup surface, and so does `computer_use_sidecar`, the one catalog entry that publishes no logo. A name in neither roster draws the neutral symbol; no monogram is ever invented for it.
  - **The plugin roster is the union of two upstream sets, and reading one of them is not enough.** `priv/plugins/index.json` is the static catalog a machine installs *from*; `priv/plugins/catalog.json` names the three plugins the engine ships *inside* itself — `google_calendar`, `gmail`, `google_drive` — which `Registry.list` unions into every `plugins.list` answer, so they are installed on a machine that added nothing. Written against the first list alone, the roster left every one of them drawing the puzzle-piece tile under the default Installed pill: the icon the owner asked to replace, on the only rows he was guaranteed to see. Both sets are pinned in `ROSTER.json` and the drift check compares the roster against their union; the Swift gate derives its case set from the daemon's own `plugins.list` answer rather than from a list kept by hand.
  - **A mark's file is named for the format its bytes are.** `whatsapp-color.png` shipped WebP bytes under a PNG name: the sha256 matched, `NSImage` decoded it, and the record's claim about the file was simply false. The offline gate and the Swift suite both check the magic bytes against the extension now, because a digest pins *which* bytes ship and never *what* they are.
  - The **search field** is a capsule on `base200` with a leading magnifier glyph, 200pt wide, and it reads the name and the one-line description under every pill including Features: one search rule, so the control cannot mean one thing under one pill and something else under another.
  - The row's **toggle is one gesture**. Flicking it on for a plugin that is not installed raises the consent sheet, installs, and then enables the plugin the operator asked for; a refusal keeps the sheet up carrying the daemon's own sentence. Stopping at the install would leave the switch snapping back off over something newly installed that nobody enabled.
  - **A switch-on ends by putting the next step in front of the person.** Once the enable has landed the row is re-read from the daemon's answer, and where its `primary_action` is `sign_in`, `add_token`, `set_up_client` or `choose_workspace` the row's own detail opens, which is where the daemon's verb button already lives. Nothing else is started: a browser this app raised by itself would be a sign-in nobody asked for. Every other published id is either something the daemon does without the operator (`check`) or something the switch just did (`install`, `enable`), and a sheet over one of those is a sheet to dismiss. A refused enable keeps the refusal path it already had.
  - The **detail** addresses its plugin by name and reads the catalogue live, as does the workspace sheet it opens: every verb on it re-reads that catalogue, and the daemon republishes a workspace discovery on the plugin row rather than on the job, so a captured row would leave both sheets describing the state they opened on. The detail draws a button only for a verb it can carry out — `Add token` is not one, because the credential slot above it is the single door to that slot.
- **Sheets**: form presentation sizing, 460 wide for credential sheets and 520×480 for pickers, one default button, Escape cancels, cancel always present. Secure fields exist in **exactly one source file** and are rendered from there by the descriptor form and by the credential sheets: the confinement is the gate, and a `secret` row inside a pane's own form is that one row, not a second implementation. No uninstall sheet ships in the first release, so that route lands on Doctor with one named sentence and a reveal action.

### 5.9 Doctor (`Doctor.dc.html`)

Window 880×560, glass §4.1. Titlebar 52 with centered "Doctor" 13/600.
Body padding `6 / 26 / 22`, section gap 14.
- Summary banner: padding 14/18, radius 12, state-tinted fill + border
  (`warnPillFill`/`warnPillBorder` shown), 20pt state glyph, title 14.5/600,
  explainer 12 `secondary` ("Answers come from the running daemon — what it can actually
  see, not this window's environment."), trailing 11.5 `faint` "Checked just now".
- Check list (flex-grow): radius 12, `cardFill` + hairline. Rows **46** tall, padding 0/18,
  gap 12: 20 status disc (pass = `successPillFill` + 11pt check stroked `success`;
  warn = `warnIconFill` + "!" 12/700 `warning`), label 13.5/500, optional fix hint 11.5
  `secondary` under it, trailing letter-pill 11/600 tracking 0.04em in `pillPass`/`pillWarn`
  **text only — no flood fill**. Separator `hairlineFaint`.
  M34 statuses to render: passed · warning · failed · unavailable · skipped · cancelled ·
  timed out · not_applicable.
- Right rail 250 wide, gap 12:
  - NETWORK CHECKS card: padding 16, radius 12, caption 12/600 tracking 0.05em `faint`,
    body 12/17 `secondary` ("Probes provider and channel endpoints for real. Uses the
    network; takes up to 30 seconds."), button 34 tall, radius 8, secondary, 13pt globe glyph.
  - SUPPORT card: padding 16, gap 8, caption label, two accent links 12.5 —
    "Export support bundle" (M34: bounded diagnostics JSON), "Open log folder".
- Local scope: 10s whole-run deadline, no permission prompts. Network scope: explicit action only.

### 5.10 Menu bar (`MenuBar.dc.html`)

- **Glyph**: the Fermix bolt, 16pt template image, three states —
  running = solid; starting = `glow` 1.6s opacity 0.45→1 ease-in-out infinite;
  attention = solid glyph + 7pt `warning` badge at `right −3, top −2` with a 1.5pt
  ring in the menu-bar background color. Never color-only: the badge is a shape, and the
  panel header states the condition in words.
  **Superseded by §8 decision 20** — the mark, the size, the badge geometry and the
  pulse all change. The overhang this paragraph specifies is what a status button
  clips, so it is the one part that must not be rebuilt from here.
- **Panel 300 wide**, radius 12, popover glass §4.2, anchored under the status item.
  - Header: padding 13/14, gap 10, bottom border `hairlineFaint`. Mascot 28,
    "Fermix" 13.5/600, status dot 6 + "Running · 3 days" 11 `secondary`, trailing version 10.5 `faint`.
  - Items: container padding 6; each row **32** tall, padding 0/10, radius 7, label 13/500,
    trailing hint 11 `faint`. Highlighted row = accent fill, white label, hint at 75% white.
  - Groups, with 1pt `hairlineFaint` separators (margin 6/4):
    1. Open Fermix (⌘O) · Setup · Run Doctor
    2. Restart daemon · Show pet (hint "on") · Pause notifications
    3. Check for updates… (hint "Up to date") · Quit Fermix (hint "daemon keeps running")
  - **M34**: add Enable/Disable background service to group 2 — never Start/Stop
    (§7.3). Quitting the GUI sends no daemon lifecycle command; the hint says so in line.
- Menu-bar strip in the artboard is scaffolding only; the real strip is the system's.

## 6. Motion (`DESIGN_SPEC` §7 / `Motion.dc.html`, superseded where noted)

| Name | Spec | SwiftUI |
|---|---|---|
| Window enter | y+14→0, opacity 0→1, scale .985→1, 280ms `(0.32,0.72,0,1)` | `.spring(response: 0.28, dampingFraction: 0.85)` |
| Glyph pulse | opacity .45→1, 1600ms easeInOut ∞, starting state only | none — §8 decision 20 bakes .45 into a static raster |
| Step crossfade | out fade+x−16, in fade+x+16→0, 240ms ease; window never moves | `.transition(.asymmetric(...))` |
| Mascot entrance | 700ms `(0.34,1.4,0.64,1)` | `.timingCurve(0.34, 1.4, 0.64, 1, duration: 0.7)` |
| Rise in | y+14→0, opacity 0→1, 480ms `(0.32,0.72,0,1)` | `.timingCurve(0.32, 0.72, 0, 1, duration: 0.48)` |

Welcome's rise-in stagger stays 120/200/300/380ms; Ready's stays 150/220/300/380ms.
Their existing entrance motion and branding are unchanged. The deleted backdrop's blob
drift and the retired success bloom are historical artboard treatments, not current roles.

**Mechanical progress uses native indicators** (§5.2). The custom ladder spinner, row
sheen, spinner-to-check pop and Starting mascot breath are retired, including the motion
roles and implementations that became unused. The floating companion's separate animation
is unchanged; Ready and Pet keep their shared still artwork.

**Reduce Motion**: entrances become opacity-only at 150ms and crossfades lose their slide.
The shared native checklist substitutes a static dotted circle for its active spinner.
The menu-bar glyph never moves (§8 decision 20). **No state is conveyed by motion alone**;
checklist rows, the menu-bar state and readiness each have a text or shape equivalent.

Implementation: product entrance and transition animations resolve through `Motion.swift`.
The native checklist owns its one Reduce Motion indicator substitution; the floating pet
keeps its existing motion policy.

## 7. Copy deck (externalized strings; sentence case, no em dashes, no exclamation
marks, no "please wait", no placeholder text, no FermixPet naming)

The daemon is "the Fermix daemon" once per screen, then "the daemon". Times are humane.
Errors read: what happened → what is untouched → the one next action.

**Welcome** — title: "Welcome to Fermix" (wordmark above it where the mark exists).
Body: "An assistant that runs on this Mac and answers wherever you message it."
CTA: "Set up Fermix". Secondary link: "Use an existing Fermix home…" (offered only when no
migration handoff exists). **There is no caption**: §5.1 deleted the tier on the
2026-09-03 directive, and a deck that still lists its string is a string that still has to
be written, translated and reviewed for a screen that does not draw it.

**Starting** (replaces Activate) — title: "Starting Fermix". Subcopy: "macOS may mention a
new background item. That is Fermix." Rows, in order: "Registering the background service" ·
"Starting the daemon" · "Checking it answers" · "Reading what is already set up".
The subcopy and registration row follow the activation plan. Both the production plan and
the isolated development background-service plan register an agent, so both include them.
The compact headline and native indicators follow §5.2; this changes presentation, not
the checks the checklist reports.
Bottom bar leading control: **"Cancel"**, the one control this screen carries (owner report
of 2026-09-04: a ladder that was not running left "only way to get back is close the window
and relaunch"). It cancels the activation and returns to Home. Starting is the only screen
whose way out is stopping what runs on it, which is why it takes the slot About you uses for
"Back" rather than a control of its own.

**Connect your AI** — title: "Connect your AI". Subcopy: "Sign in with an account you
already have, or add an API key. Sign-in opens in your browser and Fermix never sees your
password." **A row leads with a verb the daemon will actually answer** (2026-09-05):
`auth_modes` is not that signal, because Anthropic publishes `oauth` there and `auth.start`
refuses it — its two doors are an adopted Claude Code sign-in and a setup token, so a row
that read the mode offered a "Sign in" answered "This provider has no browser sign-in." on
every click. Rows: one per provider the daemon publishes, **titled with the daemon's own
label** rather than with a name written here — "OpenAI Codex (ChatGPT)", "Anthropic",
"SpaceXAI" and the rest come from the provider descriptor, so this screen, the Providers
pane and Home's Attention rows cannot call one provider three things. Verbs: "Sign in";
"Use Claude Code sign-in" when detected, otherwise "Add setup token"; "Add key…" for a
provider whose only way in is a typed key. Sheet: "Add an API key" /
"Verify and save". Waiting: "Finish signing in in your browser". Port refusal: "Port 1455 is
in use, usually by the Codex command line tool signing in. Finish or quit that and try
again." Already connected: "Your AI is already connected" / "Fermix found a working setup in
your home folder and will keep using it." / "Continue", "Change provider". **Change
provider puts the three rows back on this screen** rather than opening the Providers pane:
the two windows are exclusive, so the pane door shut the assistant mid-journey with
nothing said about where it had gone.

**About you** (new) — title: "About you". Subcopy: "Fermix uses this to address you and to
keep time straight. Change it any time in Settings." Fields: "Your name", "Time zone" with
"Change…", "Style" (Concise / Balanced / Detailed), "Call the assistant".
**All four are `personalization` rows and go out as one write** (2026-09-05), the assistant
name under `bot_name` and the label the Personality pane already shows. There is no `agent`
section on the wire: writing one earned an `invalid_params` refusal recorded under a row no
assistant screen read, so the typed name was dropped in silence and Ready landed as if it
had been saved.
**A refused save says why, here.** The screen draws the gate that refused the advance and
the daemon's own sentence for the section it writes, in the shape Connect your AI already
uses; without them the person came back to a form that looked exactly as they left it,
having been told nothing.

**Applying** (new) — title: "Applying your setup". Rows: "Saving your setup" ·
"Restarting Fermix so your provider takes effect", **the second drawn only when the daemon
reports a restart is required, or once one is under way**. A home that needs none used to
watch that row sit pending until the screen left, which reads as a step that did not
finish rather than one that never happened; the second half of the rule matters because
the daemon stops requiring a restart the moment it takes one, and a row that is running
must not vanish under the person watching it. Applying shares Starting's compact native
progress layout (§5.2), with its existing refusal text and restart confirmation intact.

**Ready** — title: "Fermix is live". Status: "Running, answers even when this window is
closed". Provider and model line beneath it. Next-step rows, with **no section label**
above them (§5.5: each row names what it opens and carries its own chevron):
"Connect Telegram, Slack or Discord" and "Turn on the voice companion", both opening the
matching Settings pane. Advisory line when something still needs attention:
"Some things still need attention", opening Home. CLI row unchanged from M34 §4:
"Install the `fermix` command for Terminal" / "Copies a Terminal command you run once",
unchecked, and skipped entirely when Homebrew owns the link, which it does on Apple silicon
once the cask's binary stanza is in place.

**Boot failed** — title: "Fermix could not start". Body: what happened, what is untouched,
the one next action. Card label: "LAST LOG LINES". Buttons: "Run Doctor", "View full log",
"Try again". One sentence each, same shape, for all thirteen causes: approval pending ·
background item disabled · incompatible version · crash loop · bind failure ·
web unavailable · invalid package · not in Applications · legacy install present ·
foreign daemon running · older daemon running · duplicate copy present · activation
timed out. The coexistence sentences are fixed by M34 §4, for example: "A Fermix daemon
from an older version is using this home, so nothing was changed. In Terminal run brew
upgrade fermix, then fermix restart, then fermix migrate-to-app." A system-scope service
gets its own sentence and its own action, "sudo fermix service uninstall --system".

**Home** — first Background row label: "Status", value: "Running"; when a gating readiness
failure stands: "Setup required"; when the engine reconcile is pending: "Restart to finish
updating"; when nothing answers: "Fermix isn't running". **That last sentence is one
string in one place**, shared by Home's Status row, the status item's state line and the
sentence a refused read puts in front of the operator; the three surfaces once said
"Daemon not reachable", "Not running" and "The Fermix daemon isn't running" about the same
machine. Uptime uses humane times in Runtime; it is not repeated beside Status.
Sections: "Background", "Attention", "Runtime" (system form headers, sentence
case unless the owner takes the HIG side of the title-case decision, no uppercase rail
labels). Background switches: "Run in the background", "Open at login", "Show Fermix in the menu bar". Attention empty
state: "Nothing needs your attention". Example attention rows with their one action:
"Another Fermix service is installed on this account" / "Show me how to remove it";
"Restart to finish updating Fermix" / "Restart…"; "Settings changed outside Fermix" /
"Reload settings from disk". A row about one provider or one channel **names it with the
daemon's own label**, read off the same snapshot the row came from: "Connect Anthropic",
not "Connect Claude" and not "Connect Openai_codex". The catalogue owns the sentence and
the daemon owns the name inside it. Toolbar action, when it applies: "Continue setup" or
"Finish updating Fermix". No "Open Setup" anywhere: no string names Setup as a destination.

**Settings** (replaces the hosted Setup deck), a presentation of the main window rather than a
window of its own. Sidebar footer row: "Settings" (⌘,). Back control: **no word at all** —
§5.8's chevron alone, carrying the accessibility label "Back to Fermix" and no visible
string. Window title equals the current pane title, except on Integrations, which draws
that title in its own page header and removes the toolbar's.
Groups: "Assistant", "Connections", "Capabilities", "System". Thirteen panes: "Providers",
"Personality", "Memory", "Channels", "Integrations", "Voice", "Meetings", "Computer",
"Coding agents", "Search", "Images", "Sandbox", "Permissions". Search field prompt:
"Search settings". Secret row: "Stored" with "Replace…" and "Remove", or "Add…".
One Settings toolbar action: "Restart…"; its tooltip and accessibility hint carry the
daemon's reason sentences, falling back to "Restart to apply" when none are supplied.
There is no repeated pending-restart banner above each pane. Restart sheet:
"Restart Fermix now?" with the reasons, the count of conversations in progress, and, in
the order macOS puts them, "Restart when idle", "Cancel", "Restart now" — cancel beside
the default action, not stranded at the far end of the row. **Every sheet titles at the
headline rung**, not the step-title rung the assistant's decision screens use: a sheet is a panel
over a window, and at 22pt each credential sheet opened with a headline as large as the
window title behind it. Engine sheet: "Finish updating Fermix".
External change: "Settings changed outside Fermix" / "Reload settings from disk".
**A refused pane is two sentences, not one** (owner report of 2026-09-04, and §7.1 of the
working design). When the bundle ships a newer engine: "This needs the newer engine in this
copy of Fermix. Restart to finish updating." The Settings toolbar offers "Restart…" with
that explanation in its tooltip and accessibility hint; the existing "Finish updating
Fermix" sheet includes it when no daemon reasons were supplied. When the daemon already
is the engine this copy ships, so no restart can help:
"Settings needs a newer Fermix engine than this copy ships.", **with no action**, as the
banner's own line, as every pane's newer-engine notice, and as Home's Attention row body.
The restart sheet also states a refused restart where there is one, and the one refusal this
build has copy for is: "Fermix's background service isn't registered on this Mac, so a
restart would stop Fermix and nothing would start it again. Run the Setup Assistant to
register it."
Unreadable settings file: the parser's own sentence plus "Reveal settings file", and no
reload action. No control is labelled "Save", "Apply" or "Submit".
**Every refusal is the daemon's own sentence** (2026-09-05). `error.message` is fixed per
code, and two codes cover a whole family: `invalid_params` carries every settings
validation, "This provider has no browser sign-in.", "A secret cannot be empty." and the
rest, and `config_unreadable` carries the parser's own line. Both put the sentence that says
what happened in `error.details.sentence`, so a surface that renders `message` alone shows
"Request parameters are invalid." for all of them. A shape the vendored contract does not
publish is drift, not an outage: it reads "The daemon answered with something Fermix could
not read" rather than "The daemon could not be reached", and it is logged with the method
and the field it arrived under.
**A choice row whose options are only suggestions** takes a control that can express an
off-list value, because the daemon accepts one: the time zone row opens the same searchable
list of what macOS knows that About you opens, and every other suggestion row is a field
with a "Suggestions" menu beside it. A closed choice with no selection shows "Not set"
rather than an empty popup.

**Meetings** (the notetaker pane, §5.4). The pane is headed by the daemon's own
`meetings_enabled` toggle, labelled as the daemon labels it, under the app's own footer:
"Installs the notetaker and its browser on first enable, about 150 MB." The footer is the
app's because it describes a gesture this app performs; the descriptor's own footer
describes the feature. Turning the switch on runs the notetaker install and writes the
daemon's flag only once that job has completed, with the job's phase, its progress and one
"Cancel" under the switch while it runs, and the daemon's own sentence there when a run
ends badly. A refused or cancelled install leaves the switch off. Turning it off is the
plain write every other switch makes. **There is no standalone Install row and no string
for one**: the engine's install is idempotent and fast when the notetaker and its browser
are already there, so a second door would be a second thing to explain and an install link
nobody asked for, which is what the owner saw. The Google sign-in row stays, with its
existing notice.

**Integrations** (the plugins page, §5.8). Subtitle: "Plugins, MCP servers and the built-in
drivers Fermix can use." Kind pills, each rendered with its live count: "Installed",
"Available", "MCPs", "Features". Search field prompt: "Search integrations". A row carries
the daemon's own name and one-line description; its toggle takes the accessibility label
"Enabled". Section at the foot of the list: "Sign-in clients". Header action, present only
while the daemon publishes something addable: "Add". There is no "Browse directory": the
catalog has no directory to browse. No results: "Nothing matches your search."
A row's second line is where it stands once it is installed and what it does while it is
not (§5.8), so a switch that reads on can never be the only thing the row says. A switch-on
that leaves a step for the person opens that row's detail rather than settling into a
silent "on".
Detail: the daemon's status sentence, "Next step" carrying the daemon's own leading verb as
**text**, then a "What this can do" row of buttons, then the settings, the sign-in client
and the workspace rows the family needs.
**A word is not a routing key** (2026-09-05): the daemon publishes `primary_verb` and
`verbs` as its English and `primary_action` and `actions` as the closed ids naming which
method each button runs. A button routes on the id and is titled from this deck by that id;
the daemon's word is drawn as text and never as a button label. Painting it onto an
app-derived action is how the eden row drew "Choose workspace" on a control that ran
`plugins.check.start`, beside a second "Choose…" that opened the sheet. Button words, one
per published id: "Install…" (install), "Turn on" (enable), "Turn off" (disable), "Sign in"
(sign_in), "Set up the sign-in client" (set_up_client), "Choose…" (choose_workspace),
"Check again" (check), "Disconnect" (disconnect). The two credential ids — `add_token` and
`replace_token`, whose words are "Add token…" and "Replace the token" — draw **no button**:
the credential slot is the sheet's own secret row, which is the one door to it. An id this
build does not know draws no button rather than a guessed one, and a row the daemon
published no verbs for draws none at all.
Features rows carry three states, not two: "On", "Off", and "Not reported" while nothing has
been read. "Off" over an unread snapshot was a claim about a daemon nobody had asked, and it
read on screen exactly like a feature the operator had turned off.

**Logs** — the daemon writes UTC to the microsecond
(`2026-08-19T12:00:00.512431+00:00`); the row shows that instant in this Mac's own zone and
format, to the millisecond, the way Console does. Levels read as words — Error, Warning,
Notice, Info, Debug — in the row and in the level popup; the wire value is the key that
selects one and is never the label. A level this build has no word for shows the daemon's
own value, which is the only name that machine has for it. An empty surface is the
system's `ContentUnavailableView`, not a caption line: the one-line form stays what an
empty *section* inside a `Form` draws.

**Doctor** — banner: "Healthy" or "2 failed", with the explainer "Answers come from the
running daemon, what it can actually see, not this window's environment." and
"Checked just now". Letter pills for all eight statuses, text only. A failed row carries the
daemon's own remediation title and exactly one action button, for example "Open Providers",
"Open System Settings", "Restart…", "Reload settings from disk", "Open recovery", or
"Show me how to remove it" for the instructions kind that opens a sheet of commands; the app
holds no remediation wording of its own and no string here names a `mix` task, `config.toml`,
or an environment variable.
**Every kind the engine's remediation table emits resolves to a surface this app already
owns** (2026-09-05): `restart` to the one Restart sheet, `reload` to `settings.reload`,
`instructions/external_config_change.recovery` to Recovery, and
`instructions/legacy_service_unit.removal` to the sheet of commands. `job` resolves to
nothing and draws no button: the table publishes no job remediation, and a job is not
startable from a bare target. The removal sheet is built from the scope and path the daemon
reported under `coexistence.legacy_service_unit`, never from a filesystem probe and a path
composed in Swift — the daemon owns the home, and a unit under a `HOME` this app cannot see
is what the probe answered with "Fermix cannot find that service".
Toolbar: "Run network checks" labelled "Uses the network, takes up to 30 seconds", and a
menu carrying "Export support bundle" and "Reveal log folder". There is no right rail.

**Menu bar** — the status item is a menu, not a panel. First row is a disabled state line:
"Running for 8 minutes" · "Setup required" · "Restart to finish updating" ·
"Fermix isn't running". **No row carries a key equivalent**: the menu opens with Fermix in
the background and a key equivalent drawn here fires only while Fermix is frontmost, so
the shortcut column advertised a gesture that mostly did nothing, and ⌘2 beside "Run
Doctor" advertised the View menu's "Doctor" under a second name. The shortcuts stay in the
main menu, which is where they work.
Items: "Open Fermix", "Settings…", "Run Doctor", "Restart Fermix…", "Show Pet",
"Enable Background Service" / "Disable Background Service", "Check for Updates…",
"Hide Menu Bar Item", "Quit Fermix".
**No row is prose, and no row is a sentence.** The disabled hint under "Hide Menu Bar Item"
is deleted: it was 90 characters, and a menu is as wide as its widest row, which is the
owner's first point on 2026-09-04 ("theres too much discription on the top right bar of
fermix which makes the window wider"). What it said lives in Home's menu-bar switch footer,
which is where the switch it explains lives. Apple's own status menus carry no explanatory
rows. The state line stays, capped at a state word plus a humane uptime; the widest row in
the menu is now "Disable Background Service" at 26 characters, and a build gate holds every
row and every state line under 34.

**Main menu** (macOS title case, a recorded exception, kept in its own catalogue
section): Fermix ("About Fermix", "Check for Updates…", "Settings…", Services, Hide,
"Quit Fermix") · File ("Close Window", "Export Support Bundle…", "Reveal Log Folder") ·
Edit · View ("Show Sidebar" / "Hide Sidebar", "Home", "Doctor", "Logs", "Pet",
"Run Local Checks", "Run Network Checks…", "Pause Logs") · Daemon ("Restart Fermix…",
"Enable Background Service" / "Disable Background Service", "Open Setup Assistant") ·
Window · Help ("Add the fermix Command to Terminal…").

Copy checks (CI): reject `—`, `!`, "please wait", "FermixPet", "Lorem", "TODO",
"Coming soon", and Title Case in `Localizable.strings`, with the menu section as the
declared title-case exception, joined by grouped-form section headers if the owner takes
the HIG side of that decision (M34 §14 decision 4). Added by M34: no string names Setup as
a destination; no attention or Doctor string contains a `mix` task, `config.toml`, or an
environment variable name; no settings control is labelled "Save", "Apply" or "Submit";
every button carries a title or an accessibility label; every sheet has a cancel.

## 8. Where M34 overrides an artboard

1. **Assistant chrome: decision 1 is taken, and §5.8 draws the shipped surface.** The artboards
   render every onboarding screen as an 800×520 glass card with a 52pt titlebar, a mascot, a
   wordmark and progress dots over a drifting blob backdrop. The shipped window is a standard
   titled auxiliary window with hidden title text, traffic lights only, no drawn backdrop, and
   the stage caption in the bottom bar. `BackdropView`, `GlassChrome` and `GlassSurface` are
   therefore deleted rather than scoped, `ContainerRuleTests` bans them by name, and §4.3's
   availability inventory is five sites.
2. **Hosted setup → native setup.** `SetupHosted.dc.html` is retired: no web view, no tab
   rail, no opaque web ground, no loopback footer. §5.8 is the replacement anatomy.
   The browser setup itself is unchanged and out of scope here: it stays the setup
   surface for every Homebrew formula install and is not drawn by this document.
3. **Day-2 settings live in the primary window**, not in a window of their own: entering hides
   the app sidebar and shows a 220pt pane column beside the pane's form, one back control (a
   chevron plus "Fermix") and Escape return, and the window grows to at least 980×640. This
   reverses M34 §14 decision 2 and the separate window it recommended, on the owner's directive
   of 2026-09-03 ("having it launch as a separate app or window doesnt make sense and adds
   friction"), and it is why the primary window's own numbers moved in §5.7. The visible entry
   point is the pinned Settings row in the sidebar footer, which is where a bottom dropdown goes
   when the tab list becomes one; the current tabs are untouched until then.
4. **The Setup sidebar row is gone**, and the sidebar is collapsible with a persisted state.
   `Home.dc.html` lists five rows including Setup; the shipped rows are Home · Doctor · Logs ·
   Pet, because setup is a task rather than a destination (M34 §5).
5. **No container the app draws itself.** The artboards' hero card, section cards, sidebar
   rows, the drawn sidebar footer, drawn titlebars and divider overlays are not built in the
   primary window in either of its presentations; the system's grouped form, sheets and
   sidebar draw every box. The pinned Settings row §5.7 adds is a system row in the footer
   position and not that drawn footer returning. The card
   geometry survives only as a reference for spacing inside system containers, and the
   progress ladder, the error panel and the pet surface are rebuilt off those primitives in
   the same slice that deletes them.
6. **Recent Activity → Background, Attention, Runtime** in one grouped form, derived from
   overview, health and setup state, each attention row carrying exactly one action and its
   wording keyed on the daemon's copy key. No activity database, no model-facing memory.
7. **`ConnectChannel.dc.html` is not built.** A channel is optional and advisory in the
   readiness split, so it lives in the Channels pane; the Telegram hero, the alternates
   column and the pairing tile ship nowhere, and the QR override in the previous revision of
   this section is moot rather than pending.
8. **Activate → Starting, with four rows.** The fourth row, "Reading what is already set up",
   is what makes an upgrade land on Ready rather than re-asking a configured home.
9. **Two assistant screens have no artboard**: About you (required because the gating
   readiness set includes a name, a time zone and a style) and Applying (the restart a new
   provider needs). Both follow §5.8's anatomy.
10. **Doctor loses the right rail**: the network action and the two support actions move into
    the toolbar, and each failed row carries the daemon's remediation sentence with one
    action, including an instructions action that opens a sheet of commands.
11. **The menu bar popover becomes a menu.** `MenuBar.dc.html`'s 300pt panel is not built, so
    the popover recipe in §4.2 applies to nothing; the status item shows a menu whose first row
    is a disabled state line, and every toolbar action is also a main-menu command.
12. **No uninstall sheet in the first release.** A placeholder sheet would fail the copy gate,
    so `fermix://uninstall` lands on Doctor with one named sentence and a reveal action while
    the uninstall transaction is unbuilt. The verb prints a removal sequence instead, running the
    bundle's own unregister entry point first, and the cask runs that same entry point as an early
    uninstall script before the app is removed.
13. **CLI row pre-checked → unchecked.** Unchanged from the previous revision: no privileged
    helper, a copyable Terminal command with verification afterwards, and the command skipped
    entirely where Homebrew owns the link, which the cask's binary stanza arranges on Apple
    silicon while Intel reports the same row as linked by the app, once the launcher that stanza
    links is built, which is a release deliverable rather than a property the bundle already has.
14. **Monogram provider marks → vendor marks or text.** Unchanged: official brand kits with a
    recorded provenance, or the vendor text name beside a neutral system symbol. Never a
    fabricated monogram.
15. **macOS floor.** Unchanged: macOS 15 floor, universal2, Liquid Glass on 26 with the §4.3
    Material path on 15.
16. **Durable stop wording.** Unchanged: Enable / Disable background service.
17. **Logs surface.** Unchanged: bounded polling over daemon-owned rotated logs, now with its
    controls in the toolbar and the list running edge to edge.
18. **Ready gating.** M34 §5 requires a live compatible daemon, no gating readiness failure
    (one configured provider plus the three personalization values), and no pending restart
    before Ready renders. Channels and the voice companion are advisory and render as one
    line rather than blocking. The artboard implies Ready is reachable from any path.
19. **Artboards are direction, not assets.** Unchanged: AppIcon, menu-bar template and mascot
    frames come from the approved masters; nothing in `assets/design/` ships as a resource.
20. **The status item is drawn by AppKit, so §5.10's glyph is superseded in four places.**
    The item hands the system a template `NSImage` and nothing else — no hosting view, no
    subview — because a status button clips its contents, which is what cut the top off the
    badge the owner reported. Four consequences:
    - **The mark is the FermixPet mascot in one ink, not the bolt.** Interim, at the owner's
      request, until there is a Fermix logo; it is also the app icon. Both masters are
      generated from the pet artwork by `scripts/build_mascot_mark.py`.
    - **18pt, not 16.** The canonical menu bar template size, with an @2x representation.
    - **The badge is 5pt with a 1pt ring, cut INSIDE the image box** rather than 7pt with a
      1.5pt ring overhanging at `right −3, top −2`. Nothing may overhang: the button clips
      it. The badge is still a shape in the same alpha, so it tints with the mark and is
      never a colour cue, and the menu's first row still states the condition in words.
    - **No pulse.** Starting is a third raster at the redline's own 0.45 ink, static. A
      status item does not animate, and the deleted pulse held at FULL opacity under Reduce
      Motion, which made starting pixel-identical to running for the users who most needed
      the two to differ.

    The 300pt panel §5.10 goes on to specify is separately superseded by decision 11.

21. **Three control states §4.4 never specified, each found by looking at the shipped app
    rather than at an artboard.** They are recorded here because the artboards draw one
    state per control and the product has more.
    - **A disabled button is drawn at 0.4 opacity** (`ButtonRecipe.disabledOpacity`). A
      SwiftUI `ButtonStyle` is handed no disabled treatment, so both styles in §4.4 drew an
      unavailable control exactly like an available one: Pet's `Mute microphone` looked
      pressable with no call running.
    - **The Settings error banner takes the pane's measure, not the window's.** It is capped at
      `settingsContentMaxWidth` and inset by `settingsFormCardInset` (30pt, the grouped
      form's own card inset), so its first word and its button land on the same edges as
      the section cards under it. On the full window width it sat 60pt outside them on both
      sides and read as a second column laid over the first.
    - **A `Toggle` states its style wherever its label is hidden.** A toggle is a switch
      only while it is a row of a grouped form; inside another row's trailing content it
      arrives as a checkbox, which is how Channels drew a checkbox for `Telegram` and a
      switch for `Accept editor connections` in the same pane.

22. **The still mascot is the body plus its face.** §5.7's Pet surface preview drew the idle
    BODY layer alone, and that layer is modelled around an opening the face plate fills, so
    the preview was a torus with a hole where the eyes belong. The floating pet always
    composited both. One mascot, drawn the same way wherever it is still.

23. **The polish pass of 2026-09-03**, taken from the owner watching the app being captured.
    Each item is written where it belongs above; this is the index, and the reasons that do
    not fit one section.
    - **Home's tinted toolbar action takes the product accent** (§5.7). It was taking the
      macOS accent, which is a different and lighter blue on a dark ground.
    - **The settings back control is the chevron alone** (§5.8), and `settings.back` is
      deleted from the deck. The name survives only where it is still read, which is
      VoiceOver.
    - **Every list row that is about a vendor draws that vendor's mark** (§5.7, §5.8), and
      the missing official marks were fetched through the existing pipeline. What could not
      be fetched is recorded as a refusal rather than replaced: OpenAI, its Codex sign-in
      and xAI keep the text treatment because their own hosts answer 403 or 404 to every
      non-interactive request, and `PROVENANCE.json` says which host refused what.
    - **The plugin roster joins the provenance record** as two new kinds, `plugin` and
      `feature`, with the plate each mark is drawn on as a recorded field. Identity in that
      record is now `(kind, key)`, because Discord and Slack are each both a channel and a
      plugin with different art. A `VendorMarkTests` suite reads the JSON and proves the
      table the app draws from says the same thing.
    - **The assistant is one title and one line per screen** (§5.1, §5.2, §5.5), the orb was
      replaced by the mascot, and `welcome.caption` and `ready.nextSection` leave the deck.
      Decision 25 later replaces the mechanical-stage mascot with native progress.
    - **A descriptor row's internal rhythm is its own table** (§5.8), which is the Sandbox
      pane's stuck-together list editor and every pane that grows one later.
    - **The type audit found nothing to change.** Every style in the product resolves through
      `Typography.style`, which is `Font.system` and nothing else; no view reaches for
      `Font.custom`, `NSFont(name:)` or `CTFontCreateWithName`, and no font file ships in the
      bundle. A build gate now scans for all four, so the claim stays true.

24. **The polish pass of 2026-09-04**, taken from the owner running the app through the
    development loop. Each item is written where it belongs above; this is the index.
    - **The status item carries no hint rows** (§7 Menu bar), which is what was making the
      menu wide.
    - **The still mascot has no disc** (§5.5), on Ready and Pet, its current consumers.
    - **Starting carries a Cancel** (§5.2, §7 Starting), and a resume over an unresolved
      refusal lands on Boot failed rather than on a ladder with nothing running behind it.
    - **A refused pane says which of two things is true** (§7 Settings): a restart that
      finishes an update, or an engine this copy of Fermix does not ship yet, the second
      with no action at all.
    - **A refused restart is a sentence the person who asked can read** (§7 Settings), in
      the Restart sheet and on the assistant's Applying screen, not only in the log.

25. **Calmer native status and progress**, authorized by the owner after running Home,
    onboarding and Settings. The existing navigation and setup flow remain unchanged.
    - **Home status is a native grouped-form row** (§5.7), replacing the large headline,
      status dot and halo. Uptime appears once in Runtime.
    - **Starting and Applying share native progress** (§5.2): a 17pt headline, flexible
      checklist rows and a system indicator, static under Reduce Motion. Their mechanical
      mascot and custom progress effects are retired. Welcome and Ready branding remains.
    - **Pending changes have one Settings Restart… toolbar action** (§5.8), opening the
      existing reasons and confirmation sheet. Error banners, refusal details and command
      availability keep their existing meaning; changing panes does not repeat a reminder.

## 9. Accessibility (DESIGN_SPEC §9, as build gates)

- Both palettes hold ≥4.5:1 for text. `faint` is captions-only and must hold ≥3:1 at
  11pt/500 measured **on the real material**, not on a flat swatch.
- Status is never color-only: pills carry letters, badges carry shape, ladder rows carry
  text state, the menu-bar attention state is a badge plus panel wording.
- Full keyboard path through onboarding: every CTA and row is focusable; the
  primary action is the default button; focus ring is the system ring, never suppressed.
- VoiceOver announces checklist-row state changes; decorative markers are
  `.accessibilityHidden` because the row supplies its label and state.
- Reduce Transparency → §4.3 solid path. Increase Contrast → hairlines to 25% alpha.
- Reduce Motion → §6 rules, including pet animation.
- Snapshot coverage: light and dark for every persistent surface plus error, empty,
  loading, and recovery states (M34 §7).
