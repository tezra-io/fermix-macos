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
decision" on 13/14 is settled — 13/14 are dropped). Liquid Glass on macOS 26 and later, one
explicit Material path on 15. The app is built against the macOS 26 SDK, so everything it
writes is a macOS 26 API that the macOS 27 runtime draws with its own refinements; an API
that exists only in the macOS 27 SDK waits for that SDK on the release runners (§8
decision 26).

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
Background switches sit directly under that button. `accent` stays scheme independent. It
carried a white label while it filled the primary action, and lightening it is what would
have broken that (white on `#2b5cff` is 5.13:1; white on `accentHover` `#4a73ff`, the only
lighter accent in the ramp, is 4.04:1, under §9's floor). It carries no label at all now
that §4.4 has made the primary action monochrome: what it fills is selection, switches, the
focus ring and the progress dots, which the system draws identically in both appearances.
The one blue that does split by appearance is `accentText` (§4.4), and it splits because
text is read against whatever it lands on rather than against a label of its own.

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

### 1.3 Ambient ground (the one window's own ground)

**The window paints one static ground behind everything it shows** (owner directive of
2026-09-20: "make the app more modern feel with its liquid glass", with reference captures
whose common trait is glass over a coloured field). It is the artboards' backdrop brought
back for one reason: glass needs something behind it. The system draws the sidebar, the
toolbar and every form section as translucent material, and over a flat grey window that
material has nothing to refract, so the app read as one grey sheet however much glass was
in it. The theme does not change: the ground is the neutral ramp washed with the one blue.

| Token (`AmbientRecipe`) | Light | Dark | Role |
|---|---|---|---|
| `groundStart` | `#eef2fb` | `#0d1020` | the wash at the leading top corner |
| `groundEnd` | `#fafbfd` | `#08080c` | the wash at the trailing bottom corner |
| `glowLeading` | `rgba(43,92,255,0.10)` | `rgba(43,92,255,0.28)` | glow centred at unit point (0.08, 0), behind the navigation glass |
| `glowTrailing` | `rgba(43,92,255,0.06)` | `rgba(90,130,255,0.14)` | glow centred at unit point (1, 1.05), behind content |
| `calmGlowLeading` | `rgba(43,92,255,0.04)` | `rgba(43,92,255,0.10)` | the same glow, calm intensity |
| `calmGlowTrailing` | `rgba(43,92,255,0.02)` | `rgba(90,130,255,0.05)` | the same glow, calm intensity |

- **Two intensities, one ground** (2026-09-20). The wash, the hues and the two centres are
  the same in both; only the glow alphas differ, at about a third. `AmbientIntensity` names
  them and the window chooses, because which surface is showing is the window's fact and not
  the recipe's. **`expressive`** is the ground as first published, for the moments the
  product is being itself: the Setup Assistant, recovery, and Pet. Those are single screens
  with a headline and one action, passed through or watched rather than worked in, and the
  glow is what makes them more than a form. **`calm`** is for the surfaces a person reads and
  works in: Home, Doctor, Logs, the update surface, and every pane of the settings
  presentation, whatever route it is showing over. **A chat surface, when the window grows
  one, takes the calm ground**, for the same reason a settings pane does: it is a column of
  text a person stays in.
- The defect the second intensity answers is a moving ratio rather than a failed one (owner,
  2026-09-20: on Settings over the gradient "some text doesnt feel that visible wherever it
  falls"). A pane of thirteen rows crosses the whole wash, so the expressive ground reads the
  same caption at 6.22:1 at the top of the window and 7.54:1 at the bottom, and the eye reads
  that gradient across a page of text as the text fading rather than as the ground shading.
  The calm ground moves it 7.57 to 8.34 instead. Lowering alpha rather than changing hue,
  because a person crosses between the two inside one window and a hue step there is the
  two-window-colours defect §5.8 already closed once.
- Each glow is a radial gradient that falls off to clear, reaching 0.62 and 0.60 of the
  window's longer side. **Never a blurred shape, and nothing moves**: a blur is a filter the
  compositor re-runs and a drift is a timer, and the ground has to cost one draw per resize
  and nothing per frame. The artboards' `drift-a` and `drift-b` stay retired, on Welcome too.
- **One painter.** `AmbientGround` is built once, as the background of the primary window's
  root, behind the split view rather than inside its detail column, so the sidebar's
  material and the toolbar's sit over the same wash the surfaces do. Home, Settings and the
  assistant are presentations of that one window, so a person never crosses from one window
  colour to another, which is the rule §5.8 set when the assistant stopped painting `base100`.
- **A surface shows the ground by giving up its own.** A grouped `Form` and a `List` fill
  their scroll area with an opaque system colour; `showsAmbientGround()` hides that fill and
  nothing else, so the section cards, their separators and their row material stay the
  system's. The assistant's form chrome hid its forms' ground already and keeps doing so.
- **Reduce Transparency and Increase Contrast draw no ground at all**, so the window shows
  the system's own colour exactly as it did before the ground existed.
- **The alphas are the largest that keep §9's floors at each glow's own centre**, which is
  the ground's worst point in both appearances: section headers and footers are drawn
  straight on the ground, so `ink` and `secondary` hold 4.5:1 and `faint` holds 3:1 there.
  `DesignMaterialsTests` computes the ratios from the tokens rather than trusting this line,
  **over both intensities**, reading each one's pair of glows off `AmbientIntensity` itself
  so the pair that is measured is the pair that is drawn. On the expressive ground
  `secondary` measures 6.22 dark and 5.75 light, `faint` 3.24 dark and 3.09 light; the calm
  ground is kinder at every one of those points.
- The artboard values this replaces (a 160 degree neutral gradient, two blurred blobs at
  560 and 640 points, drifting on Welcome) are superseded and ship nowhere.
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
- Radii: fields and hover fills **8–10** · cards **12** · windows/popovers **14** · menu rows **7** ·
  small icon tiles **6–8** · **buttons**, pills and dots **capsule/circle** (§4.4).
- Window content padding 22–26. Onboarding horizontal padding 90–120 (per screen below).
- Titlebar zone 52 tall, 20 horizontal. Progress-dot zone 44 tall.
- Hit targets: menu rows ≥28 (32 designed) · buttons ≥36 · onboarding CTAs 44 · a form
  row's own action 26, the height the system gives its row controls (§4.4).
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
- **Scope, and this is the M34 change: glass is the navigation layer only, and on macOS 26 all of it is system provided.** The inset floating sidebar, the toolbar's glass groups, sheets, pickers and toggles come from the system. The app writes no `glassEffect` in the content layer, no glass container, no custom background behind a bar, and no background extension effect. Scroll edge effects are automatic. **What the app supplies is the ground under that glass** (§1.3): the system's material is only as good as what is behind it, and the ambient ground is the one thing behind all of it.
- **The app draws no container of its own** in the primary window, in either of its presentations: a box exists only where the system draws one, which is a form section, a sheet, or the sidebar. There are therefore no cards to make flat or glass, and the recipes in §4.1 and §4.2 apply to nothing the app draws. The settings presentation (§5.8) inherits the rule unchanged, which is the whole of what the retired Settings window contributed to this section.
- No current content surface writes that glass recipe. Settings error bars use `.bar` material on both systems, or solid `base200` under Reduce Transparency; the availability split changes placement only (§5.8). Pending restarts use the Settings toolbar and draw no bar. Decision 1 is taken (§8.1), so `GlassSurface`, `BackdropView` and the two window recipes are deleted rather than kept for the assistant, and the view-background form of the recipe goes with them. The popover recipe in §4.2 is retired with the menu bar popover. `ContainerRuleTests` bans the deleted primitives by name, so none of them can come back without the gate saying so.
- Inner highlight in SwiftUI: `.overlay(shape.strokeBorder(LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.04)), lineWidth: 1))`.
- **Availability is an inventory, and the gate is membership rather than a count.** Six sites are written, each with its declared macOS 15 form: the clear titlebar over the window's ambient ground (a titled window keeps its titlebar fill on the floor, which has no scroll edge effect to keep a bar legible over content), and the five of the M34 design: the toolbar spacer (separate toolbar item groups), the window resize anchor (instant resize), the safe area bar (a safe area inset with the bar material), the prominent glass button style (bordered prominent), and shared background visibility for status text (plain text with no background modifier). The inventory is those six: decision 1 deleted `GlassSurface`, so the two sites inside it are gone with it, and the glass refresh of 2026-09-20 added the titlebar. The structural gate asserts that every availability site in the tree is on this list, never that the list has a particular length.
- **The prominent glass button style left that inventory with the blue fill** (2026-09-20, §4.4): the primary action is the product's own monochrome capsule, and no system style draws one, so `glassProminent` and `borderedProminent` are gone from the tree and banned by name. The site did not disappear, it moved: **shared background visibility now covers two controls**, the status sentence, which sits on no glass at all, and the prominent action, which draws its own capsule and had the toolbar's shared glass showing as a second, larger ring around it. On the floor both are the same toolbar item with the modifier left off, and the gate counts each branch rather than merely finding the modifier, because a branch that dropped its item would lose the control on macOS 15 and nowhere else.

### 4.4 Buttons

**Every button is a capsule** (2026-09-20). The system draws its toolbar buttons as
capsules, and the artboards' radius 10 and radius 9 rectangles beside them read as controls
from another app. One declaration, `ButtonRecipe.shape`, shapes the two styles the app
draws, and the window root sets `.buttonBorderShape(.capsule)` beside the accent so every
bordered button the system draws is the same shape. A geometry carries no radius.

**The primary action is monochrome** (2026-09-20). Fill `ink` (near-black `#16161a` on
light, near-white `#f4f5f7` on dark), label the inverse, height 44 (onboarding, label
15/600) or 36 (in-window, label 13/600). Hover `#2c2c33` / `#ffffff`, pressed `#000000` /
`#d5d8de`. Shadow `0 6 18 rgba(0,0,0,0.28)`, pressed `0 3 10`, plus the inner highlight
`inset 0 1 0 rgba(255,255,255,0.25)`.

It was `#2b5cff` with a white label and a blue glow under it (owner, 2026-09-20: the blue on
`Continue setup` and on the failure page's buttons "doesnt match with the theme"). Nothing
about the button changed; what changed is what it sits on. The ground is a wash of `#2b5cff`
(§1.3) and the switches, the selection and the progress dots over it are `#2b5cff`, so a
filled `#2b5cff` capsule on top of both had nothing left to stand against: the three-blue
surface §1.1 calls a defect arrived by adding the ground rather than by adding a control.
Monochrome is the application icon's own white-on-black, so the one button that says "do
this" wears what the product wears wherever else it signs itself, and it reads better on the
ground than the blue did: the label holds 16.5:1 on dark and 18:1 on light, where white on
`#2b5cff` held 5.13:1. **The shadow goes neutral with the fill**, because a blue glow under
a white capsule is the accent coming back by another door.

**The blue keeps everything it already carried**: list and sidebar selection, switches,
pickers, the focus ring, the progress dots and `navActive`. Those are fills the system draws
identically in both appearances, which is why `accent` stays scheme independent. What left
is one fill the app drew itself.

**`accentText` is the accent used as text** (light `#2b5cff`, dark `#7f9dff`), and it is the
one token in the ramp that splits by appearance. A fill carries its own ratio against its own
label; coloured text is read against whatever it lands on, and `#2b5cff` is 3.47:1 on a dark
card, under §9's 4.5:1 floor for text. The dark value is the same blue lifted until it
reads: 6.95:1 on `cardFill` and 5.58:1 at the dark ground's brightest point. On light it is
the accent unchanged, 5.15:1 on the white card, because lightening a blue on a light ground
is what loses it. `LinkButton` is its one consumer and `linkHover` is untouched; a gate
computes both floors from the tokens.

**The toolbar's prominent action is that same primary action at the row size** (§5.7), not
a style the system draws. Two things follow and are written into the component. It waives
Return (`isDefault: false`), because a toolbar action stands beside whatever the surface is
asking rather than confirming it, and a surface's own primary action keeps the key. And on
macOS 26 the toolbar's shared background is hidden behind it (§4.3), because a capsule that
draws its own background inside one that draws another is two rings.

Secondary: `buttonFill` + 1pt `buttonBorder`, ink label, weight 500, no shadow.

**A form row's action is the secondary style at the row size**: height 26, padding 0/12,
label 13/500, ink on the neutral capsule. The root tint reaches a system bordered button as
its label colour, so every row action was the product blue on a dark translucent card,
3.47:1 against §9's 4.5:1 floor, and one more blue on a surface whose blue is meant to be
the one action in the toolbar (§1.1). It is stated once per form, `rowActions()`, rather
than on each button, so a row added later takes it without asking. Switches, pickers and
the disclosure control are not buttons and are untouched; a button that states a style of
its own, and a menu that does, keeps it.

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

Primary window **1040×640 default, resizable**; minimum **760×520**, one minimum rather than the pair the previous revision carried, because the settings presentation (§5.8) runs inside this window and its 240pt pane column plus a readable content column has to fit at every reachable size; frame autosaved. The window is a `NavigationSplitView` with a unified toolbar and an inline title: **no window glass, no drawn titlebar zone, and one ambient ground behind everything (§1.3)** (the artboard's 52pt titlebar was a mock of chrome the window now gets from the system). Sizing is expressed in AppKit terms, because the app hosts SwiftUI inside `NSHostingView` and has no SwiftUI `Scene`: `window.minSize`, the style-mask flags, and `window.isRestorable`.
- **Sidebar: the rail** (owner directive of 2026-09-20, from a reference capture: "I like the left pane with its pitch black color and the premium icons instead of the icon + name. Plus the logo at the top left. One thing I dont like is the left icons on the center which isnt necessary"). One fixed **96pt** column, painted `WindowFrameRecipe.fill` `#000000` with `ink` `#ffffff` **in both appearances**, because it is the application icon's own ground; the column resolves in the dark appearance whatever the window's is, since a light selection and light symbols on black are the one pairing that cannot be read. **96 rather than the first cut's 76** (owner, 2026-09-20: the traffic lights "feel cutoff because of the reduced left pane width"). Measured on the running window the cluster spans x 19 to x 78, so at 76 the green light straddled the rail's trailing edge and was drawn half on black and half on the ground, which is exactly what a cut-off light looks like. Clearing the lights is therefore not the rule; **carrying them is**: at 96 the whole cluster sits on the black with 19pt of it leading and 18pt trailing, so the lights read as centred in the column they are on, and the gate asserts that margin rather than a bare minimum width. The rows are **the published four, as symbols alone, top aligned and never centred: Home · Doctor · Logs · Pet**, and nothing stands above them. For one afternoon the mascot mark headed the column and stood in for the Pet row; the owner withdrew both the same day ("the previous icon was fine. The fermix mascot on the left pane isnt needed. And it should be below the logs"), so Pet is its own `pawprint` again, last of the four. **What the owner had asked for was on the Pet surface, not in the rail** ("I was telling about replacing the blue actual mascot in the pet page with monochrome"): the Pet preview draws the one-ink mascot, `PetMark`, at 108pt in `ink`, near-white on the dark ground and near-black on the light one, in place of the painted artwork. It is the fourth image of the menu bar's own generator (`FermixMarkPet`, far above the size where the eye floor binds, so its eyes are the master's own), so the mascot in the window and the mark in the menu bar are one drawing. The painted mascot stays where it moves, in the floating companion, and on Ready, which is now the only surface that draws `MascotArtwork`; §5.5's rule that Ready and Pet share one still treatment is withdrawn for Pet by this directive. **It is still the split view's own `List` with a selection**, restyled rather than replaced, which is the whole difference from the drawn rail the artboards proposed and this document refused twice: arrow keys, full keyboard access and VoiceOver reach it exactly as before, each symbol row is still a `Label` whose name VoiceOver reads and the pointer gets as its help tag. **The rail stops at the rail**: a black border run on around the content as an inset rounded panel was built and withdrawn the same day (owner: "Lets remove the border, it doesnt fit well with the color of ours"), and a gate keeps the window view from insetting, clipping or stroking its content into a panel again. In the settings presentation the pane column wears the same black, with its labels, because thirteen panes in four sections cannot be symbols. **The Setup row is gone** (M34 §5: setup is a task, not a destination); engine identity moves into Home's Runtime section and update state into the attention row and the update surface. **Pinned under the rows, in the footer position, is one more system row: Settings (gear)**, always present whatever the daemon reports, keyboard reachable in the same order as the rows above it, and carrying ⌘, as its shortcut. **It is the last row of the sidebar's own `List`**, held on the bottom edge by one empty, unselectable spacer row whose height is measured off the column rather than written down (2026-09-04). Drawn as a second one-row `List` in a bottom safe-area inset it was pinned and unreachable: two lists are two selection contexts, so arrow keys from Pet stopped at Pet, against the sentence above. **The column it is measured against is the full one** (2026-09-20): the list's own size excludes the titlebar's safe area while its rows are laid out in the column's full-height coordinates, so measuring the size alone left the gear 59pt short of the bottom edge, which is exactly the inset the proxy had already taken off. Adding the top inset back puts the two measurements in one coordinate space, and `WindowMetrics.railBottomInset` **12pt** is then what the gear keeps clear, leaving it 19pt off the bottom: the same margin the traffic lights have at the top, so the rail is inset equally at both ends. That measurement makes the list exactly as tall as the window, which is what drew a scroll bar down the rail for the last point of it (owner, 2026-09-20: "I saw a scroll bar on the left pane"), so **the rail hides its scroll indicators**, by the same modifier the settings pane column beside it already takes under §5.8's scroll rule. Five fixed rows never scroll in a way a person can use. It is the app's one visible way into setup, added on the owner's directive of 2026-09-03 after he opened the app and found none, and it is a row rather than a toolbar button because it is the slot he named for the dropdown the tab list may become once the window gains a chat surface. It is **not** the artboard's sidebar footer returning: that footer drew a wordmark, a version and engine identity inside a box the app painted, it stays deleted, and the footer position now holds this one system row and nothing else. The sidebar stays the chat-ready shell: a future Chat row is one more entry.
  - **The body's two leading corners are rounded to the window's own radius** (owner, 2026-09-20: "should we make the left pane or the body rounded edge like the macOS window?"), `WindowMetrics.bodyCornerRadius` **20pt**, measured off this window rather than taken from `Radius.window`, whose 14 is the artboards' number for a drawn panel. The rail already ends in rounded corners because the window clips it; where the body met the rail it did not, so the two columns read as one sheet with a black stripe painted down it rather than as a body sitting inside a frame. **This is not the withdrawn border**, and the difference is the mechanism: it is more of the rail's own black, laid over the detail column's top and bottom leading corners as a square with a quarter disc taken out of it. No inset, no clip, no stroke, no colour of its own, and it takes no clicks. A clip would cost the surface a point of content on every edge and need a ground behind what it cut away, which is the panel that was removed.
- **Collapse**: View > Show/Hide Sidebar (⌃⌘S). The leading toolbar toggle is removed, because on a rail this narrow it lands on the traffic lights, and there is no drag, because the rail is one width. With the toggle gone a surface that has no toolbar of its own, which is Pet, dropped the window to the short titlebar, so every app surface carries one empty zero sized toolbar item to size the titlebar by. The system's was three ways: the leading toolbar toggle, View > Show/Hide Sidebar (⌃⌘S), and drag. Width-driven collapse below **840pt** and restore above **900pt**: the same offsets from the window minimum the previous revision chose, +80 and +140, carried onto the new 760pt minimum, where the old 720/780 pair could never fire at all. The band between them is 60pt, unchanged. An explicit hide is persisted and never overridden by width. Never hidden on first launch. No hover reveal, no overlay. Entering the settings presentation hides the sidebar as a presentation rather than as a preference, and leaving it restores the visibility the user chose.
- **Content** is one `Form(.grouped)`; the artboard's hero card and section cards are not drawn. The owner's calmer-status refinement places **Status** in the first native `LabeledContent` row of Background, with the current state in normal secondary text and the accessibility `updatesFrequently` trait. There is no separate display headline, status dot or halo. **While a lifecycle transaction the app itself started is running** (a restart, or enabling or disabling the background service) the row says so, with the small activity mark beside the sentence, instead of flipping to "Fermix isn't running" for the seconds the daemon is away, which read as a failure (owner report of 2026-09-20: "when user clicks on restart and theres no currently indicator saying whats happening"). That a transaction this app started is in flight is the app's own fact, which is the only reason the app may say it; everything else in the row is still the daemon's. Uptime appears once, in Runtime. Sections, in order:
  - **Background**: the Status row followed by three independent switches: run in the background, open at login, and show in menu bar. The first two control registration; the third controls visibility. Lifecycle actions retain Enable / Disable wording.
  - **Attention**: one row per daemon-reported gap, each with exactly one trailing action, and one centered line when there are none. Sources are readiness failures, which carry a gating flag, a copy key and a pane deep link, the restart reasons, and the five standing coexistence descriptors M34 §5 publishes as one list: legacy service unit, restricted keychain items, engine PATH baseline, restart pending, and settings changed outside Fermix. Row wording comes from the app catalogue keyed by the **copy key** alone, never from the pane and never from a command line sentence: five channel failures and the voice companion collapse onto two panes, so a pane key cannot tell Telegram from Slack. The pane is the deep link and nothing else. The copy key is a closed set the daemon publishes, so the catalogue's coverage gate is written over that set, with the provider family enumerated at test time, rather than over a count of components.
  - **Runtime**: labelled rows for engine, management protocol, uptime, provider, channels, skills and tools, the last two as counts only.
- **Toolbar**: leading system sidebar toggle plus the inline title; trailing at most one tinted primary action while its condition holds (continue setup, or finish updating), then at most one secondary group, never more than three groups. Status text never sits on glass. **The window states a running lifecycle transaction there, on every surface**: "Restarting Fermix" with the small activity mark, in the `.status` placement, the same drawing Doctor's "Running checks" uses. It is one window-level modifier because the window is the only view that spans every surface, and it is silent in the assistant, whose ladder already draws the restart row. **Progress sits at the point of action and everything else stays readable**: a full-window blur with a spinner was considered and refused, because it blocks a window whose contents are still true, hides the context the person was in, and costs a compositing filter for the whole duration.
  - **That prominent action is the product's own primary action** at the row size (§4.4), and no longer a style the system draws. It was the system's prominent style carrying the root tint, `.tint(Palette.accent)`: prominent glass on macOS 26 and `borderedProminent` on the 15 floor. Untinted it took the macOS accent instead, measured off the shipped captures at `rgb(5,124,254)` on dark and `rgb(0,112,237)` on light against the product's `#2b5cff`, so Home's `Continue setup` was the one primary action in the app that was not the product's blue, and the tint fixed that. What the tint could not fix is that the product's blue was wrong there too once the ground arrived under it (owner, 2026-09-20: the blue on `Continue setup` and on the failure page's buttons "doesnt match with the theme"), so §4.4 took the blue off the primary action altogether and this button is that action, monochrome, drawn by the app. `glassProminent` and `borderedProminent` are gone from the tree and banned by name, because either would put the macOS accent back. It waives Return, since a toolbar action stands beside what the surface is asking rather than confirming it, and on macOS 26 the toolbar's shared glass is hidden behind it, since it draws its own capsule (§4.3). §1.1's two-blue rule is unchanged and is now easier to keep: the only blue left on the surface is selection and switches.
  - The accent stays scheme independent. **No dark-appearance variant is added**, because lightening it is what would break the label: white on `#2b5cff` is 5.13:1, and white on `accentHover` (`#4a73ff`), the only lighter accent the ramp has, is 4.04:1, under §9's 4.5:1 floor.
- **Runtime rows carry a vendor mark where the fact is about a vendor.** Only the provider row is, and the daemon publishes the provider's key there, so nothing is parsed out of the sentence beside it. The mark is 20pt (`SettingsRowMetrics.markSize`), which is the size every grouped-form row draws one at.
- **Home, Doctor, Pet and the update surface take §5.8's scroll rule** (2026-09-20): indicators are never drawn and the edges take the system's fade. Home drew the one scrollbar left in the window.
- Doctor and Logs live in the same window with the same rules: Doctor is a banner plus one grouped list with its actions in the toolbar and **no right rail**, each failed row carrying the daemon's remediation sentence and one action; Logs runs edge to edge with search, level, pause and export in the toolbar. Pet keeps its preview and call controls in a grouped form, restyled off the deleted card and titlebar primitives.

### 5.8 Native setup: the assistant and settings inside the primary window (supersedes `SetupHosted.dc.html`)

There is no hosted surface and no web view. The artboard is retired: its tab rail, its opaque web ground, its 52pt drawn titlebar and its loopback footer describe a surface the app no longer has. What is retired is that artboard and the hosted pane inside the app, never the browser setup: the daemon goes on serving its Setup LiveView for every Homebrew formula install, on macOS exactly as on Linux, and this document does not draw it.

**Setup Assistant** (a presentation of the primary window, on the owner directive of 2026-09-05). Setup and recovery retain their existing screens and model; they no longer create an auxiliary window. Entering the assistant hides the app sidebar and grows a smaller window to at least 800×520 without shrinking it on exit. Home, setup, recovery, and settings keep the same `NSWindow`.
- **Chrome** uses the primary window and its system toolbar, with no drawn backdrop or glass card. The stage caption stays in the bottom bar. A toolbar chevron returns to Home; Starting uses the existing cancellation path, and Applying keeps the user on its active transaction. The bottom Back action still goes to the previous setup step.
- The single-window decision preserves the setup flow. The native progress refinement in
  §5.2 changes Starting and Applying presentation only; Welcome and Ready branding remains.
- **The assistant paints no ground of its own** (2026-09-04). It shows the primary window's
one ambient ground (§1.3), which is what every other presentation of that window shows;
painting `base100` here gave one application two window colours and made the assistant read
as a different app the moment a person moved between it and the primary window. The
assistant has no split view to make its toolbar clear, so its toolbar hides its own
background; left in place it drew an opaque band across the one presentation that is all
ground.
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
- **No inline scrollbars** (owner: "try to avoid the inline scrollbar"). The form scrolls only when its content is taller than the window, scroll indicators are never shown, the top and bottom edges carry the automatic scroll edge effect of §4.3, and a short pane does not scroll at all. **No nested scroll view inside a pane**: a long list either groups and collapses in place, or opens a sheet that owns its list. The plugin list is the Integrations pane's own single scroll, kept short by its pills and its search; the model picker and the installed-apps picker are sheets, and inside a provider's own sheet the model list is a page of that sheet rather than a second one. The rule is the window's and not one pane's, so **the pane column carries it too**: thirteen panes in four sections are taller than the 640pt default, so that column scrolls, and it hides its indicators and fades its edges by the same two modifiers the form uses. Every scroll container the settings presentation owns is on this rule, which is how it is gated.
- **One Settings-level Restart… toolbar action** appears when saved settings require a restart or a restart will finish an engine update. It belongs to the Settings presentation, so changing panes neither adds another reminder nor repeats a banner above the form. Its tooltip and accessibility hint carry the reason details; activating it uses the existing restart command and opens the existing confirmation sheet. The sheet retains every daemon reason, conversation impact, refusal and restart choice (§7). The action is disabled when that command is unavailable, and it is withdrawn, not dimmed, while a lifecycle transaction the app started is running: the window's status sentence stands in its place, so nothing offers a second restart over the first. No restart happens merely because the reminder appears, and no dismissal preference or second pending-state store is added.
- **Error banners retain the top safe-area slot**, carrying `.bar` material on both systems and solid `base200` under Reduce Transparency. `safeAreaBar` on macOS 26 and `safeAreaInset` on the floor change placement only. An external change or unreadable file takes priority over the pending-restart action; an engine that this app cannot update states the problem with no restart action.
- **External-change banner**, one line and one action, is shown while the settings file has changed outside Fermix. The refusal itself lives in the daemon's shared write tails, so the browser door shows the same banner, and the reload re-records the daemon's baseline so the write after it succeeds. A file the daemon cannot read or parse is a different state: it shows no reload action, because the reload would re-run the read that failed, and routes to Recovery with the parser's own sentence and a reveal action.
- **Row kinds** rendered by one descriptor form: toggle to `Toggle`; choice to `Picker`; text to `TextField` with a prompt and **a rounded bezel filling the value column the form
already laid out**, because a grouped form strips a field's chrome and the value then
reads as one more fact in a page of facts (`Your name  Sujeeth` said nothing about being
editable). No width of its own: a fixed measure squeezed the label beside it, and a
ceiling let each field shrink to its own value; number to a `Stepper` showing its value, or a `Slider` when the daemon's own bounds and step suit one; secret to a secret row that is edited in place, reading stored with replace and remove, or drawing the field itself where nothing is stored; list to a list editor. A row the daemon marks read-only renders as `LabeledContent`. Row label, footer, options and bounds are the daemon's; the app supplies no field inventory.
  - **A row's own vertical rhythm is `SettingsRowMetrics`, not the form's.** A descriptor row is one grouped-form row however many lines it draws, so the form's row insets stop at its edge and never reach inside it. Three gaps, all on §3's scale: `captionGap` 4 between a control and the caption that explains it, `entryGap` 8 between the entries of a stacked editor, `stackGap` 12 between the peer blocks of one (its label, its entries, the field that adds one). The list editor took the caption gap for all three, which ran its label into its entries and put two 24pt `Remove` buttons a point apart; that is what the owner saw on Sandbox ("some of the items are stuck together without proper spacing"), and it is fixed in the shared row rather than in that pane, so every descriptor pane takes it.
  - **A row that is about one vendor draws that vendor's mark** at `SettingsRowMetrics.markSize` (20pt), before its label: providers, channels, and the sign-in clients section. That measure is the row's whole leading accessory column, so a row that leads with a system symbol instead — Ready's next-step rows — takes the same 20 and lines up with them. 20 rather than the plugin page's 28, because a grouped-form row is a line of text and an accessory taller than its cap height sets the row's height instead of sitting inside it. **A mark on transparency is inset to 0.72 of the tile and the neutral symbol to 0.55**, both raised on 2026-09-04: at 0.56 the 20pt tile gave a mark an 11pt box, so Mistral's logotype — which its own file centres in a square with a third of the height empty — drew at about 7pt beside 20pt marks that bleed, and the neutral symbol at 0.42 was an 8pt chip on three of the seven provider rows, which read as a smudge rather than a symbol. The vendor's own whitespace is kept; a file is never cropped, because no record here permits editing a mark. **A mark whose file carries its own ground bleeds and is never inset**: Telegram's roundel, inset, drew an 11pt blue disc inside a 20pt grey one.
  - **A fact row draws no mark.** Home's Runtime section is seven labelled facts in one flush column, and a leading tile on the single row that names a vendor indented that label alone against the other six; for the provider the owner actually runs there is no retrievable mark either, so what the row carried was a neutral placeholder chip beside a raw wire key. A mark belongs on a row that is *about* a vendor, which is the three lists above and the assistant's Connect your AI discs.
  - **A section header that is about one vendor draws that vendor's mark**, at the same `SettingsRowMetrics.markSize` the rows take, because this document names no separate measure for a section. Meetings is the case: its **Google Meet** and **Zoom** sections are each about one platform, so each header carries that platform's mark before its name, while **Shared settings** is about both and carries none. It sits on the header rather than on the first row of each section because neither first row is about a vendor: Google Meet's is the shared job row that starts the sign-in and Zoom's is a descriptor row the daemon publishes, so a mark prepended to either would land on every other pane that draws the same shared row. The mark is decorative there exactly as it is on a row: the header speaks the platform's name, which is the accessibility label the record carries for that key, so nothing is spoken twice.
  - **A meeting platform is its own kind in the provenance record**, `meeting_platform`, keyed `google_meet` and `zoom`. `meetings` is one native driver with one Fermix mark under the Features pill; the two platforms underneath it are two vendors, and folding them into the feature roster would put three different things behind one key. Their keys are the app's own, like the feature keys, so `ROSTER.json` pins no upstream list for them; their marks are the vendors' own, so the refresh re-downloads them rather than re-vendoring them from fermix. Google Meet ships the product icon Google itself serves, taken as the vendor's raster for the reason the Google sign-in client already records: AppKit loads Google's SVG and omits its blur filter. Zoom ships the square application icon Zoom serves for its own site (its touch icon), the current mark since Zoom's rebrand; the media kit's downloadable file is a horizontal wordmark that draws as a thin band in a square tile, and the retired camera glyph is not Zoom's mark any more, so neither is used.
  - **A channel row's title is the daemon's**, from `settings.sections` (`channels.whatsapp` → `WhatsApp`), not the wire identifier with its first letter raised, which produced `Whatsapp` beside WhatsApp's own mark. A channel the daemon named with no section published shows the identifier as the daemon wrote it, which is visibly a key rather than a spelling the app invented.
- **Integrations is a page in the Codex shape**, not a stack of groups (owner directive of 2026-09-03, with the Codex Plugins page supplied as the reference): a header carrying the pane title and a one-line subtitle; a row of kind pills carrying live counts, the selected one filled, with the search field at that row's trailing edge; then a flat list whose row is a 28pt rounded icon tile holding the plugin's own logo, the name at 13.5/500, a second line beneath it at 12 `secondary`, and a trailing `Toggle`. **That second line is one rule with two branches**: an installed row draws the daemon's own `status_sentence`, because where it stands is the whole question about something already on this Mac; a row that is not installed draws the manifest summary, because what it does is the only question there is about it yet. Drawing the summary wherever there was one is what hid the state the owner reported: an installed, switched-on plugin signed in to nothing said `Read schedules, find availability` under a switch reading on, and people read "on" as "working". `IntegrationRowModel.subtitle` is the one owner of that rule. Pills: Installed · Available · MCPs · Features. A row opens its detail, and **says so**: a trailing `chevron.forward` and a hover fill, because a click that opened a sheet with no pointer change, no highlight and no chevron was advertised by nothing at all. Sign-in clients are a section at the foot of the list, never a group, and they keep logos of their own. No box around the list, no collapsible sections, generous vertical rhythm, both appearances. **The toolbar's inline title is removed on this pane alone**: the page header carries the title, and the window title two lines above it said the same word twice. The window keeps its title — it is what the Window menu names this window by — and only its drawing in the toolbar is dropped.
  - **No rules between rows** (owner directive of 2026-09-03: "remove any extra horizontal separation. keep it clean"). A plain `List` draws a separator under every row, and these rows are already an icon tile over two lines of text, which read as a ruled ledger. The rhythm is the row's own vertical padding. The rule is the list's, so the sign-in clients section inside it takes it too.
  - **The tile holds a real logo, vendored with provenance.** The logos come from fermix's own checked-in plugin catalog, which publishes one per entry, decoded out of it and recorded in `VendorMarks/PROVENANCE.json` beside the catalog entry and version they came from. The three native driver features take Fermix's own marks from the engine's setup surface, and so does `computer_use_sidecar`, the one catalog entry that publishes no logo. A name in neither roster draws the neutral symbol; no monogram is ever invented for it.
  - **The plugin roster is the union of two upstream sets, and reading one of them is not enough.** `priv/plugins/index.json` is the static catalog a machine installs *from*; `priv/plugins/catalog.json` names the three plugins the engine ships *inside* itself — `google_calendar`, `gmail`, `google_drive` — which `Registry.list` unions into every `plugins.list` answer, so they are installed on a machine that added nothing. Written against the first list alone, the roster left every one of them drawing the puzzle-piece tile under the default Installed pill: the icon the owner asked to replace, on the only rows he was guaranteed to see. Both sets are pinned in `ROSTER.json` and the drift check compares the roster against their union; the Swift gate derives its case set from the daemon's own `plugins.list` answer rather than from a list kept by hand.
  - **A mark's file is named for the format its bytes are.** `whatsapp-color.png` shipped WebP bytes under a PNG name: the sha256 matched, `NSImage` decoded it, and the record's claim about the file was simply false. The offline gate and the Swift suite both check the magic bytes against the extension now, because a digest pins *which* bytes ship and never *what* they are.
  - The **search field** is a capsule on `base200` with a leading magnifier glyph, 200pt wide, and it reads the name and the one-line description under every pill including Features: one search rule, so the control cannot mean one thing under one pill and something else under another.
  - The row's **toggle is one gesture**. Flicking it on for a plugin that is not installed raises the consent sheet, installs, and then enables the plugin the operator asked for; a refusal keeps the sheet up carrying the daemon's own sentence. Stopping at the install would leave the switch snapping back off over something newly installed that nobody enabled.
  - **A switch-on ends by putting the next step in front of the person.** Once the enable has landed the row is re-read from the daemon's answer, and where its `primary_action` is `sign_in`, `add_token`, `set_up_client` or `choose_workspace` the row's own detail opens, which is where the daemon's verb button already lives. Nothing else is started: a browser this app raised by itself would be a sign-in nobody asked for. Every other published id is either something the daemon does without the operator (`check`) or something the switch just did (`install`, `enable`), and a sheet over one of those is a sheet to dismiss. A refused enable keeps the refusal path it already had.
  - The **detail** addresses its plugin by name and reads the catalogue live, as does the workspace page it turns to: every verb on it re-reads that catalogue, and the daemon republishes a workspace discovery on the plugin row rather than on the job, so a captured row would leave both describing the state they opened on. The detail draws a button only for a verb it can carry out — `Add token` is not one, because the credential slot above it is the single door to that slot.
- **Sheets**: form presentation sizing, 460 wide for credential sheets and 520×480 for pickers and the plugin detail, one default button, Escape cancels, cancel always present. **One popup is fine, and a popup never raises a second one** (owner directive of 2026-09-20: "I dont mind having a one level popup", after a report that typing an API key was three windows deep: a pane raised a provider's or a plugin's detail, the detail raised a sheet for the key or for its sign-in client, and that raised a third). What a sheet owns beyond itself is a page it turns to, with `chevron.backward` at its top and Escape returning to the sheet's first page before it closes the sheet, or a row edited in place: **a secret is typed in the row that owns it**, the model list is a page of the provider's sheet, and the plugin detail's workspace choice, sign-in client and token slot are pages of the detail, with the sign-in wait drawn in place under the verb that started it. A sheet keeps one size across its pages. `ContainerRuleTests` scans every sheet declaration in the tree for a presentation of its own, so the depth cannot come back one modifier at a time. Secure fields exist in **exactly one source file** and are rendered from there by the descriptor form and by the credential sheets: the confinement is the gate, and a `secret` row inside a pane's own form is that one row, not a second implementation. No uninstall sheet ships in the first release, so that route lands on Doctor with one named sentence and a reveal action.

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
`ActivityMark` owns the one Reduce Motion indicator substitution, a small native `ProgressView` or the static dotted circle, and the checklist, the toolbar's status sentence and Home's Status row all draw it; the floating pet
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
"Import Claude Code sign-in" when detected, otherwise "Add setup token"; "Add key…" for a
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
"Try again". The three Login Items causes, approval pending, background item disabled and
registration failed, lead instead with "Open Login Items settings", then "Try again" and
"View full log": their sentence names a switch in System Settings, and Doctor would ask a
daemon that never started. One sentence each, same shape, for all thirteen causes: approval pending ·
background item disabled · incompatible version · crash loop · bind failure ·
web unavailable · invalid package · not in Applications · legacy install present ·
foreign daemon running · older daemon running · duplicate copy present · activation
timed out. The coexistence sentences are fixed by M34 §4, for example: "A Fermix daemon
from an older version is using this home, so nothing was changed. In Terminal run brew
upgrade fermix, then fermix restart, then fermix migrate-to-app." A system-scope service
gets its own sentence and its own action, "sudo fermix service uninstall --system".

**Home** — first Background row label: "Status", value: "Running"; while a lifecycle transaction runs, its sentence ("Restarting Fermix", "Enabling the background service", "Disabling the background service"), and VoiceOver hears the end of one ("Fermix restarted", "Background service enabled", "Background service disabled"); when a gating readiness
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
"Search settings". Secret row: "Stored" with "Replace…" and "Remove"; where nothing is stored the row is the field itself, prompt "Paste the value", with "Store" beside it and Return doing the same. "Replace…" swaps the value column for that field and a "Cancel". There is no "Add…": a button whose only job was to raise a sheet went with the sheet.
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
plain write every other switch makes. **The two platform sections carry their platforms'
marks** (§5.8): Google Meet's and Zoom's own, before the section name, with "Shared settings"
carrying none. That adds no string, because the header speaks the section title the deck
already carries, which is also the accessibility label `PROVENANCE.json` records for the key.
**There is no standalone Install row and no string for one**: the engine's install is
idempotent and fast when the notetaker and its browser are already there, so a second door
would be a second thing to explain and an install link nobody asked for, which is what the
owner saw. The Google sign-in row stays, with its
existing notice.

**Providers** (the pane and a provider's own sheet, 2026-09-20). **A row leads with the
provider's real way in.** The owner's report: "add key in every provider doesnt sit well
since some like spacexai and anthropic and codex are signin and that should be the primary
signin methind." The row's verb used to read the selected auth mode before it looked for a
sign-in door, so "Add key…" led on providers whose way in is a sign-in. The order is now: a
provider that needs no credential, or already works, draws no verb; a provider with a
sign-in door leads with it whatever auth mode is selected ("Import Claude Code sign-in" or
"Import Codex sign-in" where the daemon detects one, then "Add setup token" for Anthropic,
then "Sign in"); only a provider with no sign-in door leads with "Add key…", which opens the
one "Add an API key" sheet. "Details…" opens the provider's own sheet, which is one popup
and raises nothing (§5.8).
**In that sheet the sign-in and the API key are not peers** (owner: "The problem with the
api keys and sigin at the same level causes user to scroll"). The sign-in doors lead, as
"Sign in with browser", "Import Claude Code sign-in", "Import Codex sign-in" and the
"Setup token" row with its caption "Use a setup token to connect your Claude account."; the
API key sits behind one collapsed disclosure, "Use an API key instead", which carries the
daemon's auth mode row and the key's own secret row. A provider whose only way in is a key
draws that secret row directly, focused. Then the provider's own descriptor rows, then
"Sign out" and "Use as primary" beside "Done". Every provider's sheet fits the default
window without scrolling, which a test measures.
**Anthropic keeps all three doors whatever is selected or connected** (owner: "for claude,
the sigin option shoudl still be there, inaddiion to import token and also the api"): the
adopted Claude Code sign-in, the setup token and the API key. Where the daemon detects no
Claude Code sign-in the door stays, disabled, over "No Claude Code sign-in was found on
this Mac. Sign in to Claude Code first to use it here." The pane row keeps leading with a
door that works when clicked, so there it is offered only when detected. **There is no
browser sign-in for Anthropic to offer**: `auth.start` refuses it, and a button the daemon
refuses on every click is the defect §7 Connect your AI already records.

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
**text**, then a "What this can do" row of buttons, which wraps onto a second line rather
than truncating its words (the widest real row is a rejected client's five verbs), then the
settings, the sign-in client and the workspace rows the family needs. **The detail raises
nothing** (§5.8): "Choose…" and "Set up the sign-in client" turn the sheet to a page of its
own, whose back control is the chevron alone with the accessibility label "Back to" and the
plugin's name, and a sign-in the detail started is waited on in place under that row, with
"Cancel", "Open the browser again" and, once it has failed, the daemon's sentence and
"Try again". Where a sign-in leads and the daemon also publishes a token id, the token is
the secondary door and its slot is a page; where the token leads, the rule below stands.
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

**Menu bar** — the status item is a menu, not a panel. While a lifecycle transaction runs the state line is its sentence, "Restarting Fermix", "Enabling the background service" or "Disabling the background service", the longest at 32 characters and inside the 34 gate. Otherwise the first row is a disabled state line:
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

26. **The glass refresh and one-level flows of 2026-09-20**, from the owner's report that
    typing an API key was three windows and more than three clicks deep, and the request to
    "make the app more modern feel with its liquid glass" without changing the theme and
    without bloat. Each item is written where it belongs above; this is the index.
    - **One ambient ground behind the one window** (§1.3), static, drawn once, and absent
      under Reduce Transparency and Increase Contrast. Every form and list shows it by giving
      up its own fill; the containers stay the system's and the app still writes no glass.
    - **The titlebar is clear over that ground on macOS 26 and later** (§4.3), the sixth
      availability site. AppKit's titlebar fill drew an opaque band across the assistant and
      the Integrations header, which a SwiftUI toolbar modifier does not reach.
    - **Every button is a capsule, and a form row's action is a neutral one** (§4.4). The
      blue-on-dark row labels measured 3.47:1 against §9's 4.5:1.
    - **Integrations' search capsule, selected pill and hover fill are `chipFill`**, an alpha
      token, where they were `base200`: an opaque capsule on a wash reads as a hole in it.
    - **One popup, never two** (§5.8), with the secret typed in its own row, and a
      provider leading with its real way in (§7 Providers).
    - **macOS 27**: the app builds against the macOS 26 SDK, locally and on the release
      runners, so nothing here is a macOS 27 API; macOS 27 draws all of it natively. An API
      that exists only in the macOS 27 SDK joins the availability inventory once that SDK is
      on the runners.
    - **Not taken**: an icon rail, drawn window chrome, hand-drawn cards or switches, a
      `glassEffect` in the content layer, a Home hero (decision 25 stands), and any motion in
      the ground.

27. **The rail of 2026-09-20**, the same day as decision 26, from the owner's fourth reference
    capture. Written at §5.7; this is the index and what is left open.
    - **The app sidebar is a black rail of symbols**, the system's list restyled, never a
      drawn column. The mascot mark that headed it for an afternoon is withdrawn (decision 29). Settings' pane column wears the same black.
    - **No border around the content.** Tried, captured, withdrawn by the owner the same day.
    - **Open, the owner's call:** the width rule still hides the rail under 840pt and returns
      it above 900pt, unchanged. It was written for a 200pt sidebar that a narrow window
      could not hold; the rail fits at the 760pt floor at either width it has had, so the
      rule now buys nothing and costs the only visible navigation. Retiring it removes
      `widthChanged`, `systemCollapsed` and `collapsedByWidth` from the reducer and its
      tests, which is why it is a decision and not a side effect of this change.
    - The rail's own measurements moved the same evening, under decision 29: 96pt, and the
      mark left the rail for the Pet surface.

28. **Saying what is happening** (2026-09-20), from the owner's report that a restart showed
    nothing between the sheet closing and the daemon answering again. Written at §5.7, §5.8
    and §7; this is the index.
    - **One fact, one writer.** `AppModel.transactionInFlight` names the lifecycle transaction
      the app itself started, set when it is actually taken and cleared in the same `defer`
      on completion, refusal and failure. "Restart when idle" claims nothing while it waits.
    - **Every surface reads that one fact**: the window's toolbar sentence, Home's Status
      row, the Settings Restart… action that steps aside, and the status item's state line.
      The end is announced to VoiceOver; the start is not, because the assistant's ladder
      already says it.
    - **No blur overlay.** Progress at the point of action, the rest of the window readable.
    - **Open:** settings writes made in those seconds still earn "Fermix isn't running"
      rather than waiting, because `SettingsModel` has no path to the fact and every
      `writesBlocked` guard speaks the external-change sentence; and the menu bar glyph can
      show the attention mark while the state line says "Restarting Fermix".

29. **The rail and the ground, settled** (2026-09-20, the evening of decisions 26 to 28),
    from the owner running the built app rather than reading a document. Seven reports, six
    of them about the same thing: the ground and the rail were right, and everything drawn
    *over* them had been tuned before they existed. Each item is written where it belongs
    above; this is the index.
    - **The primary action is monochrome** (§4.4, §5.7), fill `ink` and the label inverted,
      with a neutral shadow. The blue on `Continue setup` and on the failure page's buttons
      "doesnt match with the theme": once the ground is a wash of `#2b5cff` and the switches
      over it are `#2b5cff`, a `#2b5cff` capsule is the third blue on the surface. The blue
      keeps selection, switches, the focus ring and the progress dots.
    - **The toolbar's prominent action is that same action** (§4.4, §5.7), so
      `glassProminent` and `borderedProminent` leave the tree and the availability inventory
      (§4.3); shared background visibility covers the action as well as the status sentence.
      The action waives Return, which belongs to whatever the surface is asking.
    - **`accentText`** (§4.4), light `#2b5cff` and dark `#7f9dff`: the accent used as text is
      a different requirement from the accent used as a fill, and `#2b5cff` is 3.47:1 on a
      dark card.
    - **Two ground intensities** (§1.3). Text-heavy surfaces sit on nearly one value; the
      glow is for moments. Home, Doctor, Logs, the update surface and all of Settings take
      the calm one, the assistant, recovery and Pet the expressive one, and a future chat
      surface takes the calm one.
    - **The rail is 96pt** (§5.7), because the traffic lights "feel cutoff because of the
      reduced left pane width": measured, the cluster spans x 19 to x 78, so 76 cut the
      green light in half and 96 centres the cluster on the black.
    - **The mark is not in the rail, and the Pet surface draws it** (§5.7). An afternoon's
      reading of "remove the pet icon from left bar and use the monochrome in the pet page" put
      the mark in the rail as the Pet row; the owner corrected it the same evening. The rail is
      the four published symbols, Pet last, and the monochrome mascot replaces the painted one
      on the Pet surface. The toolbar's prominent action is the in-window size, 36pt, the
      toolbar's own control height: at the row size the owner saw it as smaller at once.
    - **The gear is on the bottom edge and the rail hides its scroll indicators** (§5.7).
      The spacer was measured against a height the titlebar's safe area had already been
      taken out of, which left the gear 59pt short; correcting it made the list exactly as
      tall as the window, which is where the scroll bar came from.
    - **The body's two leading corners are rounded** to the window's own measured 20pt
      (§5.7), painted in the rail's black rather than clipped, so the withdrawn border stays
      withdrawn.
    - **Not taken:** a rounded or inset rail, a border of any kind around the content, a
      colour change between the two grounds, and an accent-tinted shadow under the
      monochrome button.
    - **Open:** `accentText` on light is the accent unchanged, and the accent has no margin
      on the light ground. On the wash it measures 4.59:1 at the leading end and 4.97:1 at
      the trailing one, but inside the expressive leading glow it falls to 4.02:1, under
      §9's floor, and 4.36:1 on the calm one. The assistant draws two links on that ground
      (`Use existing home` on Welcome, `Change provider` on Connect your AI), both well
      clear of that corner, so nothing ships under the floor today. It is unresolved rather
      than fixed: the gate computes the dark ground and both cards, where the lifted value
      earns its margin, and the light side needs either a darker light value than `#2b5cff`
      or a rule that a link never lands inside a glow. This was true before the token
      existed, because `LinkButton` drew `accent` on light and still does.

## 9. Accessibility (DESIGN_SPEC §9, as build gates)

- Both palettes hold ≥4.5:1 for text. `faint` is captions-only and must hold ≥3:1 at
  11pt/500 measured **on the real material**, not on a flat swatch.
- Status is never color-only: pills carry letters, badges carry shape, ladder rows carry
  text state, the menu-bar attention state is a badge plus panel wording.
- Full keyboard path through onboarding: every CTA and row is focusable; the
  primary action is the default button; focus ring is the system ring, never suppressed.
- VoiceOver announces checklist-row state changes; decorative markers are
  `.accessibilityHidden` because the row supplies its label and state.
- Reduce Transparency → §4.3 solid path. Increase Contrast → hairlines to 25% alpha. Both
  → no ambient ground (§1.3): the window shows the system's flat colour.
- The ambient ground keeps the text floors at its own brightest points, computed from the
  tokens by `DesignMaterialsTests` rather than asserted here.
- Reduce Motion → §6 rules, including pet animation.
- Snapshot coverage: light and dark for every persistent surface plus error, empty,
  loading, and recovery states (M34 §7).
