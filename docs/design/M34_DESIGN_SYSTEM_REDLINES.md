# Fermix macOS — design redlines, extracted for Swift (M33 → M34)

Source of truth: `fermix/docs/design/MILESTONE_33_MACOS_COMPANION_APP/assets/design/`
(`DESIGN_SPEC.md` + the twelve `*.dc.html` artboards + `canvas.json`). The CSS in the
artboards is the redline; this file is that CSS resolved into values Swift can consume.

Binding contract: `fermix/docs/design/MILESTONE_34_UNIFIED_MACOS_APP_IMPLEMENTATION.md`
§§3–7. **Where an artboard and M34 disagree, M34 wins** — every such point is listed in
§7 below and marked at the screen where it applies.

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
| `sheen` (active ladder row sweep) | `rgba(43,92,255,0.05)` | `rgba(255,255,255,0.05)` |
| `dotDone` (progress dot, completed) | `rgba(43,92,255,0.40)` | `rgba(43,92,255,0.45)` |
| `successPillFill` / `border` | `rgba(40,160,110,0.07)` / `rgba(40,160,110,0.22)` | `rgba(120,220,180,0.08)` / `rgba(120,220,180,0.20)` |
| `warnPillFill` / `iconFill` / `border` | `rgba(200,150,50,0.06)` / `0.12` / `0.22` | `rgba(235,200,120,0.07)` / `0.12` / `0.20` |
| `errorDiscFill` / `border` | `rgba(200,80,60,0.06)` / `rgba(200,80,60,0.20)` | `rgba(230,130,110,0.08)` / `rgba(230,130,110,0.22)` |
| `successGlow` (Home status dot halo) | `rgba(40,160,110,0.15)` | `rgba(120,220,180,0.18)` |

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
| Headline | 17 / 22 | 600 | `.system(size: 17, weight: .semibold)` | card headers |
| StatusHeadline | 19 / — | 600 | `.system(size: 19, weight: .semibold)` | Home "Running" |
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

### 4.3 SwiftUI mapping (one path per configuration — no silent fallback chain)

```swift
// GlassSurface.swift — the only place either path is written.
@ViewBuilder
func glassBackground(_ recipe: GlassRecipe) -> some View {
    if reduceTransparency {                       // opaque, same borders/shadow
        shape.fill(Color.base200)
    } else if #available(macOS 26.0, *) {
        shape.fill(recipe.tint)                   // the fill above, as a tint
             .glassEffect(.regular, in: shape)    // inside a GlassEffectContainer
    } else {                                      // macOS 15 floor
        shape.fill(.ultraThinMaterial)
        shape.fill(recipe.tint)                   // same tint overlay
    }
}
```

- macOS 26: the window/popover root sits inside one `GlassEffectContainer`; sibling glass
  elements share it so morphing reads as one material.
- macOS 15: `.ultraThinMaterial` + the recipe fill as a tint overlay. Identical border,
  inner highlight (a 1pt top-edge overlay gradient), shadow, and radius on both paths.
- Reduce Transparency: solid `base200`, same border/highlight/shadow. Not a fallback —
  it is a third declared configuration selected by an accessibility setting.
- The embedded Setup web surface is **opaque `base100`/`base200` on purpose**;
  never glass. Cards inside any window are flat, never glass.
- Inner highlight in SwiftUI: `.overlay(shape.strokeBorder(LinearGradient(colors:
  [highlight, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.04)), lineWidth: 1))`.

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
- CTA 44 tall, padding 0/28, radius 10, primary. Caption 12 `faint` below, gap 14,
  block top margin 32, `rise-in` delay 300ms.
- No feature grid, no checkboxes, nothing else.
- Progress dots: 1 of 4 active.

### 5.2 Activate — boot masking (`Activate.dc.html`)

Titlebar carries a right-aligned chip: height 24, padding 0/10, radius 6, `chipFill` +
hairline, 13pt accent bolt glyph pulsing (`glow` 2.8s), label 11/500 `secondary`
"menu bar mirrors this state".
Content 400 tall, horizontal padding 120, centered.
- **Orb** 96×96, bottom margin 26, `breathe` 2.8s.
  - halo: `inset −22`, `radial-gradient(circle, rgba(43,92,255,0.35), transparent 65%)`, `glow` 2.8s.
  - sphere: `radial-gradient(circle at 32% 28%, orbHi, orbLo 70%)`, 1pt `orbRim`,
    `inset 0 1 8 rgba(255,255,255,0.35)`, `0 14 34 rgba(43,92,255,0.30)`.
    Light `orbHi rgba(255,255,255,0.95)`, `orbLo rgba(235,240,255,0.55)`, `orbRim rgba(0,0,0,0.06)`.
    Dark `orbHi rgba(255,255,255,0.30)`, `orbLo rgba(255,255,255,0.04)`, `orbRim rgba(255,255,255,0.25)`.
  - core: `inset 26`, `radial-gradient(#2b5cff → #1e46d6)`, `0 0 24 rgba(43,92,255,0.80)`, `glow` 2.8s.
- Headline Title 22/28 tracks the active row; bottom margin 6. Caption 13/18 `faint`
  below, bottom margin 30.
- **Ladder card**: width 380, radius 12, `cardFill` + hairline, rows 52 tall,
  padding 0/18, separator 1pt `hairlineFaint`, gap 12 between icon and label 14/500.
  - done: 22 accent disc + 12pt white check (stroke 3, round caps).
  - active: 22 arc spinner (r 9, track `hairlineStrong` 2.5, accent 90° arc, `spin` 900ms
    linear) **plus** a sheen sweep across the row: `linear-gradient(100deg, transparent 30%,
    sheen 50%, transparent 70%)`, `sheen` 2.2s ease-in-out infinite, translateX −120%→240%.
  - pending: 22 hollow ring, 2pt `hairlineStrong`, label tone `faint`.
- Rows, in order (the only provable states): `Background service registered` ·
  `Starting the Fermix daemon` · `Preparing your setup`.
  Headlines by stage: `Registering the service` · `Starting the daemon` · `Almost ready`.
- Reveal Setup the moment `/health/live` answers — never `/health/ready`. 90s → Boot failed.
- VoiceOver: each row is one element, label = row text, value = `done|in progress|waiting`;
  announce transitions with `.accessibilityAnnouncement`. Spinner and sheen are decorative.
- Progress dots: 2 of 4 active (dot 1 done).

### 5.3 Connect AI (`ConnectAI.dc.html`)

Content 400, padding `8 / 110 / 0`, centered. Title 22 + subcopy 14/20 `secondary`,
max width 430, bottom margin 28. Column width 460, row gap 12.
- Provider row: height 64, padding 0/18, radius 12, `cardFill` + hairline, gap 14.
  36 disc `monoDisc` + **provider mark** (M34: no fabricated monogram — see §7.4),
  name 15/600 + hint 12 `faint`, trailing secondary button 34 tall / 0-14 / radius 8,
  "Sign in" 13/600 + 12pt external-arrow glyph.
- API-key row: height 56, radius 12, **1pt dashed `hairlineStrong`**, no fill.
  18pt key glyph, title 14/600, hint 12 `faint`, trailing 14pt chevron.
- Skip link 13 accent, top margin 22.
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
- Skip link 13 accent, top margin 20. Progress dots: 4 of 4 active (this artboard) —
  in the shipped 5-step ladder Connect channel is step 4 and Ready is step 5.

### 5.5 Ready (`Ready.dc.html`)

Content 424, padding 0/110, centered.
- Mascot 116×116 with two bloom rings inset 10, 2pt `rgba(43,92,255,0.5)` and
  `rgba(43,92,255,0.3)`, `bloom` 900ms at 200ms / 380ms delay, `cubic-bezier(0.22,0.61,0.36,1)`,
  one-shot. Mascot `mascot-pop` 700ms. Bottom margin 10.
- "Fermix is live" TitleLarge 24/30, `rise-in` delay 150ms, bottom margin 6.
- Success pill: height 24, padding 0/11, capsule, `successPillFill` + border, 7pt success
  dot, label 12/500 `successText`; bottom margin 16; `rise-in` delay 220ms.
- CLI row: width 470, padding 14/16, radius 12, `cardFill` + hairline, gap 12.
  20 leading checkbox (radius 6) + 12pt check; title 14/600 with `fermix` in Mono 13;
  hint 12 `faint`. **M34: unchecked by default (§7.2).** `rise-in` delay 300ms.
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

### 5.7 Home (`Home.dc.html`)

Window **880×560 default, resizable**, glass §4.1, radius 14, split view.
- **Sidebar 200 fixed**, right border 1pt `hairlineFaint`.
  - Titlebar zone 52, padding 0/18 (traffic lights live here).
  - Nav list padding 8/10, row gap 2. Row: height **34**, padding 0/10, radius 8, gap 10,
    17pt stroke icon + label 13.5. Active = `navActive` fill + `#2b5cff` icon/label at 600;
    inactive = `secondary` at 500. Rows: Home · Setup · Doctor · Pet · Logs.
    The sidebar is the chat-ready shell: a future Chat row is one more entry.
  - Footer: top border `hairlineFaint`, padding 14/18, mascot 22, name+version 11.5/600,
    update state 10.5 `faint`.
- **Content** padding 22/26, section gap 16.
  - Status hero card: padding 20/22, radius 12, `cardFill` + hairline, inner gap 14.
    Row 1: 12 status dot with `inset −4` glow halo (`successGlow`), "Running" 19/600,
    uptime 13 `faint` ("for 3 days 4 hours" — humane times), spacer, then right-aligned
    chips: height 26, padding 0/11, capsule, `chipFill` + hairline, 12/500 `secondary`
    (provider chip, channel chip).
    Row 2 actions gap 10, each 36 tall, radius 9, 14pt icon + 13pt label:
    primary "Open Setup", secondary "Run Doctor", secondary "Restart daemon".
    **M34 adds** enable/disable background service and independent GUI-login and
    background-service toggles here (§7.3).
  - **M34: Runtime + Attention sections replace RECENT ACTIVITY (§7.3).** The artboard's
    card geometry is still the redline for both: card radius 12, `cardFill` + hairline;
    header 42 tall, padding 0/18, caption 12/600 tracking 0.05em `faint`, trailing accent
    link 12; rows 52 tall, padding 0/18, gap 13, 30 icon tile (radius 8, `chipFill` +
    hairline, 15pt glyph, `secondary`), title 13.5/500 + detail 12 `faint`, trailing
    meta 11.5 `faint`. Runtime rows carry authoritative facts (engine version, protocol,
    uptime, provider, channels); Attention rows carry warnings with the one next action.
    Empty state: same card, one centered caption line, no illustration.

### 5.8 Hosted setup (`SetupHosted.dc.html`)

Window 880×560, glass §4.1.
- Titlebar 52: traffic lights, centered title "Setup" 13/600 `secondary`,
  trailing 52 spacer so the title stays optically centered.
- Web surface: `margin 0 14`, `radius 10 10 0 0`, 1pt hairline, **no bottom border**,
  fill **opaque** `webBg` (light `#fcfcfc`, dark `#060606`); it is the daemon's LiveView in
  an ephemeral `WKWebView`. Inside (rendered by the web app, mirrored here as the redline):
  tab rail 172 wide, padding 14/8, rows 30 / radius 7 / 12.5pt, active = `navActive` +
  accent 600; content padding 20/22, section title 16/600, subcopy 12.5 `webFaint`,
  provider cards padding 14/16 radius 10 `webCard` + `webLine`, 34 disc, name 14/600,
  state 12, trailing Connect (primary 30 tall, radius 8) or Add key (secondary).
- Footer 34 tall, `footBg`, top border `hairlineFaint`, centered:
  12pt window glyph + "Served locally by your daemon · 127.0.0.1:4030" 11.5 `faint`
  + separator + "Open in browser ↗" accent link (mints a fresh session).
- Native chrome is glass; web content is opaque. Never log or persist the tokenized URL.

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

## 6. Motion (verbatim from `DESIGN_SPEC` §7 / `Motion.dc.html`)

| Name | Spec | SwiftUI |
|---|---|---|
| Orb breath | scale 1→1.05, glow .5→1, 2800ms easeInOut ∞ | `.easeInOut(1.4).repeatForever(autoreverses: true)` |
| Stage advance | spinner→check pop 320ms overshoot `(0.34,1.56,0.64,1)` | `.spring(response: 0.32, dampingFraction: 0.62)` |
| Window enter | y+14→0, opacity 0→1, scale .985→1, 280ms `(0.32,0.72,0,1)` | `.spring(response: 0.28, dampingFraction: 0.85)` |
| Success bloom | 2 rings scale .45→1.85 fade, 900ms, 180ms stagger, one-shot | `.easeOut(0.9)` |
| Glyph pulse | opacity .45→1, 1600ms easeInOut ∞, starting state only | timer-driven opacity |
| Step crossfade | out fade+x−16, in fade+x+16→0, 240ms ease; window never moves | `.transition(.asymmetric(...))` |

Supporting timings taken from the artboards (not in the table, still redlines):
ladder spinner `spin` 900ms linear ∞ · active-row sheen 2.2s ease-in-out ∞ ·
mascot entrance 700ms `cubic-bezier(0.34,1.4,0.64,1)` · `rise-in` 480ms
`cubic-bezier(0.32,0.72,0,1)` with 120/200/300/380ms stagger · Welcome blob drift 18s / 22s.

**Reduce Motion**: loops stop (orb and glyph hold at full glow, blobs static), entrances
become opacity-only at 150ms, blooms and crossfade slides are skipped. Every animation is
decorative — **no state is conveyed by motion alone**; the ladder row state, the menu-bar
state, and the success state each have a text or shape equivalent.

Implementation: read `@Environment(\.accessibilityReduceMotion)`; a single
`Motion.swift` returns the animation or `nil`, and every call site takes it from there —
one path, no per-view `if reduceMotion` branches scattered through the views.

## 7. Copy deck (externalized strings; sentence case, no em dashes, no exclamation
marks, no "please wait", no placeholder text, no FermixPet naming)

The daemon is "the Fermix daemon" once per screen, then "the daemon". Times are humane.
Errors read: what happened → what is untouched → the one next action.

**Welcome** — headline: wordmark only (no text headline).
Body: "Your Mac's resident AI agent. Reachable from Telegram, Slack, and your desktop,
running privately on this machine." CTA: "Set up Fermix". Caption: "Takes about two minutes".

**Activate** — headlines by stage: "Registering the service" · "Starting the daemon" ·
"Almost ready". Caption: "First start takes a little longer while Fermix unpacks."
Chip: "menu bar mirrors this state". Rows: "Background service registered" ·
"Starting the Fermix daemon" · "Preparing your setup".

**Connect AI** — title: "Connect your AI". Subcopy: "Sign in with an account you already
have. Sign-in opens in your browser, and Fermix never sees your password."
Rows: "ChatGPT" / "Uses your ChatGPT subscription via Codex"; "Claude" / "Uses your Claude
subscription". Button: "Sign in". Dashed row: "Use an API key instead" /
"OpenAI, Anthropic, xAI, OpenRouter, Ollama". Skip: "I'll do this later".

**Connect channel** — title: "Talk to Fermix anywhere". Subcopy: "Pick where you'll message
Fermix first. You can add more channels any time." Hero: "Telegram" / "Fastest to set up" /
"Connect Telegram". Alternates: "Slack" / "For your workspace"; "Discord" / "For your server".
Skip: "Do this later". Pairing area, real payload absent (M34): "Pairing opens in Setup" with
the truthful instruction line; never a mock QR and never "QR — scan from your phone" as art.

**Ready** — title: "Fermix is live". Pill: "Daemon running · responds even when this window
is closed". CLI row: "Install the `fermix` command for Terminal" /
"Links into /usr/local/bin, asks for your password once" — M34 replaces the privileged
action with a copyable Terminal command, so the hint becomes
"Copies a Terminal command you run once" and the row starts unchecked.
Buttons: "Open Fermix", "Advanced setup".

**Boot failed** — title: "Fermix couldn't start". Body: "The daemon didn't respond within
90 seconds. Your configuration hasn't been touched, and Doctor can usually tell you exactly
what happened." Card label: "LAST LOG LINES". Buttons: "Run Doctor", "View full log",
"Try again". Truthful variants required by M34 §5 (one sentence each, same shape):
approval pending · background item disabled · incompatible version · crash loop ·
bind failure · web unavailable · invalid package.

**Home** — status: "Running" + "for 3 days 4 hours"; when setup is incomplete: "Setup
required". Actions: "Open Setup", "Run Doctor", "Restart daemon", "Enable background
service" / "Disable background service", "Open at login". Sections: "RUNTIME", "ATTENTION".
Footer: "Fermix <version>" / "Up to date".

**Setup** — title: "Setup". Footer: "Served locally by your daemon · 127.0.0.1:4030" ·
"Open in browser ↗".

**Doctor** — banner: "Healthy, with one thing to look at" /
"Answers come from the running daemon, what it can actually see, not this window's
environment." / "Checked just now". Pills: "PASS", "WARN". Fix hints are imperative and
name the one command, e.g. "Run `codex login` in Terminal, then re-check".
Right rail: "NETWORK CHECKS" / "Probes provider and channel endpoints for real. Uses the
network; takes up to 30 seconds." / "Run network checks". "SUPPORT" /
"Export support bundle" / "Open log folder".

**Menu bar** — "Fermix", "Running · 3 days"; "Open Fermix", "Setup", "Run Doctor",
"Restart daemon", "Show pet", "Pause notifications", "Check for updates…" ("Up to date"),
"Quit Fermix" ("daemon keeps running"), "Enable background service" /
"Disable background service".

Copy checks (CI): reject `—`, `!`, "please wait", "FermixPet", "Lorem", "TODO",
"Coming soon", and Title Case in `Localizable.strings`.

## 8. Where M34 overrides an artboard

1. **QR placeholder → removed.** `ConnectChannel.dc.html` draws a 92×92 tile reading
   "QR — scan from your phone". M34 §7 and planned deviation 5: render a QR only from a
   real daemon-supplied pairing payload; otherwise route to truthful Setup instructions.
   Keep the tile's geometry for the real code; never ship the mock.
2. **CLI row pre-checked → unchecked.** `Ready.dc.html` shows the row checked with
   "asks for your password once". M34 §4 and planned deviation 12: unchecked by default,
   no privileged helper, a copyable Terminal command plus verification afterwards, and a
   refusal to recommend replacing a foreign file. Cask installs skip the
   hardcoded `/usr/local/bin` command entirely (brew owns the link).
3. **Recent Activity → Runtime + Attention.** `Home.dc.html` lists a mock feed
   (reminder delivered / skill updated / daily brief sent). M34 §5 and planned deviation 7:
   replace with Runtime and Attention sections derived from overview/health data;
   no activity database, no model-facing memory. The row and card geometry survive.
   Home also gains service enable/disable plus independent login toggles, and
   "Start / Stop" wording is banned in favor of "Enable / Disable background service"
   (planned deviation 6).
4. **Monogram provider marks → vendor marks or text.** `ConnectAI.dc.html` and
   `SetupHosted.dc.html` draw "G", "C", "X" letter discs. M34 §7: marks come only from
   official brand kits with recorded source, date, terms, treatment, dark-mode policy, and
   accessibility label; when a mark cannot be redistributed accurately, use the vendor text
   name with a neutral system symbol. Never fabricate a monogram.
5. **macOS floor.** `DESIGN_SPEC` §10.1 leaves 13/14 open. M34 planned deviation 15 settles
   it: macOS 15 floor, universal2, Liquid Glass on 26 with the §4.3 Material path on 15.
6. **Durable stop wording.** `DESIGN_SPEC` §10.2 leaves it open; M34 §4 settles it as
   Enable/Disable background service (registration is the durable state).
7. **Logs surface.** `DESIGN_SPEC` §10.4 leaves Logs conditional; M34 §5 ships it as
   bounded polling over daemon-owned rotated logs — the sidebar row stays.
8. **Ready gating.** M34 §5 requires a live compatible daemon and at least one configured
   provider before Ready; a channel stays optional. The artboard implies Ready is reachable
   from any path.
9. **Artboards are direction, not assets.** M34 §7: AppIcon, menu-bar template, and mascot
   frames come from the approved masters; nothing in `assets/design/` ships as a resource.

## 9. Accessibility (DESIGN_SPEC §9, as build gates)

- Both palettes hold ≥4.5:1 for text. `faint` is captions-only and must hold ≥3:1 at
  11pt/500 measured **on the real material**, not on a flat swatch.
- Status is never color-only: pills carry letters, badges carry shape, ladder rows carry
  text state, the menu-bar attention state is a badge plus panel wording.
- Full keyboard path through onboarding: every CTA, skip link, and row is focusable; the
  primary action is the default button; focus ring is the system ring, never suppressed.
- VoiceOver announces ladder-row state changes; the spinner and sheen are `.accessibilityHidden`.
- Reduce Transparency → §4.3 solid path. Increase Contrast → hairlines to 25% alpha.
- Reduce Motion → §6 rules, including pet animation.
- Snapshot coverage: light and dark for every persistent surface plus error, empty,
  loading, and recovery states (M34 §7).
