import Foundation
import Testing

@testable import FermixAppCore

/// The button geometry of `M34_DESIGN_SYSTEM_REDLINES.md` §4.4 and the ambient
/// ground of §1.3.
///
/// The two window glass recipes and the three configurations that rendered them
/// left with the assistant's glass card (owner decision 1): no window draws a
/// container of its own, so the recipes applied to nothing. The ground under
/// the system's glass is what came back.
@Suite("Design materials")
struct DesignMaterialsTests {
    /// The primary button is the one control that carries a shadow inside a
    /// window; secondary carries none. Every size is the one capsule, so a
    /// geometry carries no radius to drift.
    ///
    /// The fill is the application icon's own monochrome, not the accent (owner,
    /// 2026-09-20: the blue on `Continue setup` and on the failure page's
    /// buttons "doesnt match with the theme"). The ambient ground is a wash of
    /// `#2b5cff` and the selection and switches over it are `#2b5cff`, so a
    /// filled `#2b5cff` capsule on top of both had nothing left to stand out
    /// against. The shadow goes neutral with it: a blue glow under a white
    /// capsule is the accent coming back by another door, which is what the gate
    /// below is for.
    @Test("the button recipes match the redline")
    func buttonRecipes() {
        #expect(ButtonRecipe.primary(.onboarding).height == 44)
        #expect(ButtonRecipe.primary(.onboarding).labelStyle.size == 15)
        #expect(ButtonRecipe.primary(.onboarding).labelStyle.weight == .semibold)
        #expect(ButtonRecipe.primary(.inWindow).height == 36)
        #expect(ButtonRecipe.primary(.inWindow).labelStyle.size == 13)

        #expect(ButtonRecipe.primaryFill == Palette.ink)
        #expect(ButtonRecipe.primaryLabel == ThemedColor(lightHex: "#ffffff", darkHex: "#16161a"))
        #expect(ButtonRecipe.primaryHoverFill == ThemedColor(lightHex: "#2c2c33", darkHex: "#ffffff"))
        #expect(ButtonRecipe.primaryPressedFill == ThemedColor(lightHex: "#000000", darkHex: "#d5d8de"))
        #expect(ButtonRecipe.primaryShadow.cssBlur == 18)
        #expect(ButtonRecipe.primaryShadow.yOffset == 6)
        #expect(ButtonRecipe.primaryPressedShadow.cssBlur == 10)
        #expect(ButtonRecipe.primaryPressedShadow.yOffset == 3)
        #expect(ButtonRecipe.primaryInnerHighlight == .rgba(255, 255, 255, 0.25))

        // Neither the fills nor the shadows carry any blue from the ramp.
        for shadow in [ButtonRecipe.primaryShadow, ButtonRecipe.primaryPressedShadow] {
            #expect(shadow.color == ThemedColor(uniform: .rgba(0, 0, 0, 0.28)))
        }
        let fills = [
            ("fill", ButtonRecipe.primaryFill),
            ("hover", ButtonRecipe.primaryHoverFill),
            ("pressed", ButtonRecipe.primaryPressedFill)
        ]
        for (name, fill) in fills {
            for accent in [Palette.accent, Palette.accentHover, Palette.accentPressed] {
                #expect(fill.light != accent.light, "the primary \(name) is an accent on light")
                #expect(fill.dark != accent.dark, "the primary \(name) is an accent on dark")
            }
        }

        #expect(ButtonRecipe.secondary(.inWindow).height == 36)
        #expect(ButtonRecipe.secondary(.inWindow).labelStyle.weight == .medium)
        #expect(ButtonRecipe.secondaryFill == Palette.buttonFill)
        #expect(ButtonRecipe.secondaryBorder == Palette.buttonBorder)
    }

    /// The primary action's label is read against the button's own fill, and it
    /// has three of them. §9's floor is for text, and a button's label is text,
    /// so hover and pressed have to hold it too: the pressed fill on dark is the
    /// lightest of the three and the one a floor would fail at first.
    ///
    /// Computed rather than asserted, so a fill retuned later either still
    /// clears the floor or fails here. Today the worst of the six is the dark
    /// pressed fill at 12.6:1, where white on the retired accent fill was 5.13:1.
    @Test("the primary label holds its floor on every fill the button draws")
    func primaryLabelHoldsItsFloor() {
        let fills = [
            ("fill", ButtonRecipe.primaryFill),
            ("hover", ButtonRecipe.primaryHoverFill),
            ("pressed", ButtonRecipe.primaryPressedFill)
        ]

        for scheme in FermixColorScheme.allCases {
            for (name, fill) in fills {
                let ratio = Contrast.ratio(
                    ButtonRecipe.primaryLabel.resolved(for: scheme),
                    fill.resolved(for: scheme)
                )

                #expect(ratio >= 4.5, "the label is \(ratio):1 on the \(scheme) \(name) fill")
            }
        }
    }

    /// A row's action is the height of the system's own row controls. At the
    /// free-standing 36 the button sets the row's height, and a form of rows
    /// with actions stops lining up with a form of rows with switches.
    @Test("a row action is a row control's height at every size that names one")
    func rowActionGeometry() {
        #expect(HitTarget.rowAction == 26)
        #expect(ButtonRecipe.secondary(.row).height == HitTarget.rowAction)
        #expect(ButtonRecipe.primary(.row).height == HitTarget.rowAction)
        #expect(ButtonRecipe.secondary(.row).labelStyle.size == 13)
        #expect(ButtonRecipe.secondary(.row).labelStyle.weight == .medium)

        for size in ControlSize.allCases {
            #expect(ButtonRecipe.secondary(size).height <= ButtonRecipe.secondary(.onboarding).height)
            #expect(ButtonRecipe.primary(size).height == ButtonRecipe.secondary(size).height, "\(size)")
        }
    }

    /// The wash and the two centres are one ground; the alphas are the two
    /// intensities of it (§1.3). Same hues and same centres in both, because a
    /// person crosses between them inside one window.
    @Test("the ambient ground matches the redline")
    func ambientRecipe() {
        #expect(AmbientRecipe.groundStart == ThemedColor(lightHex: "#eef2fb", darkHex: "#0d1020"))
        #expect(AmbientRecipe.groundEnd == ThemedColor(lightHex: "#fafbfd", darkHex: "#08080c"))
        #expect(AmbientRecipe.glowLeading.light == .rgba(43, 92, 255, 0.10))
        #expect(AmbientRecipe.glowLeading.dark == .rgba(43, 92, 255, 0.28))
        #expect(AmbientRecipe.glowTrailing.light == .rgba(43, 92, 255, 0.06))
        #expect(AmbientRecipe.glowTrailing.dark == .rgba(90, 130, 255, 0.14))
        #expect(AmbientRecipe.calmGlowLeading.light == .rgba(43, 92, 255, 0.04))
        #expect(AmbientRecipe.calmGlowLeading.dark == .rgba(43, 92, 255, 0.10))
        #expect(AmbientRecipe.calmGlowTrailing.light == .rgba(43, 92, 255, 0.02))
        #expect(AmbientRecipe.calmGlowTrailing.dark == .rgba(90, 130, 255, 0.05))
        #expect(AmbientRecipe.glowLeadingReach == 0.62)
        #expect(AmbientRecipe.glowTrailingReach == 0.60)

        // The two intensities are two alphas of one ground, so nothing but the
        // alpha may differ: a hue step between them is a second window colour.
        for intensity in AmbientIntensity.allCases {
            for (glow, published) in [
                (intensity.leadingGlow, AmbientRecipe.glowLeading),
                (intensity.trailingGlow, AmbientRecipe.glowTrailing)
            ] {
                #expect(glow.light.hexString == published.light.hexString, "\(intensity) light hue")
                #expect(glow.dark.hexString == published.dark.hexString, "\(intensity) dark hue")
            }
        }
        #expect(AmbientIntensity.calm.leadingGlow.dark.alpha < AmbientIntensity.expressive.leadingGlow.dark.alpha)
        #expect(AmbientIntensity.calm.trailingGlow.dark.alpha < AmbientIntensity.expressive.trailingGlow.dark.alpha)
    }

    /// The darker end of the wash meets the rail's black in both appearances
    /// (owner, 2026-09-24: on dark the blue beside the pitch-black rail "doesnt
    /// feel smooth"). Light runs as published because its blue-washed start is
    /// the darker end; dark runs mirrored because its near-black end is.
    @Test("the darker end of the wash meets the rail in both appearances")
    func ambientGroundDarkensTowardTheRail() {
        for scheme in FermixColorScheme.allCases {
            let (railEnd, farEnd) = AmbientRecipe.isMirrored(in: scheme)
                ? (AmbientRecipe.groundEnd, AmbientRecipe.groundStart)
                : (AmbientRecipe.groundStart, AmbientRecipe.groundEnd)

            #expect(
                Contrast.luminance(railEnd.resolved(for: scheme)) < Contrast.luminance(farEnd.resolved(for: scheme)),
                "the \(scheme) wash is lighter at the rail than away from it"
            )
        }
    }

    /// §9's floors, computed at the ground's two worst points rather than
    /// trusted: each glow's own centre, at full strength, over the end of the
    /// wash it sits on. Section headers and footers are drawn straight on the
    /// ground, so the three text neutrals have to hold there in both
    /// appearances. A glow turned up later either still clears these or fails
    /// here, which is the whole reason the alphas are tokens.
    ///
    /// Run over both intensities, because both are grounds the app ships. The
    /// glows are read off `AmbientIntensity` itself, which is where the view
    /// reads them, so the pair that is measured is the pair that is drawn.
    ///
    /// The calm ground is strictly kinder at every point, which is the property
    /// the owner actually asked for: the same caption moves 7.57 to 8.34 on dark
    /// where the expressive ground moves it 6.22 to 7.54, so a page of rows sits
    /// on nearly one value instead of visibly fading across the window.
    @Test("the text neutrals hold their floors on both grounds' brightest points")
    func ambientGroundKeepsTheTextFloors() {
        let floors: [(String, ThemedColor, Double)] = [
            ("ink", Palette.ink, 4.5),
            ("secondary", Palette.secondary, 4.5),
            ("faint", Palette.faint, 3.0)
        ]

        for intensity in AmbientIntensity.allCases {
            let points: [(String, ThemedColor, ThemedColor)] = [
                ("leading", intensity.leadingGlow, AmbientRecipe.groundStart),
                ("trailing", intensity.trailingGlow, AmbientRecipe.groundEnd)
            ]

            for scheme in FermixColorScheme.allCases {
                for (corner, glow, wash) in points {
                    let ground = Contrast.composite(glow.resolved(for: scheme), over: wash.resolved(for: scheme))

                    for (name, token, floor) in floors {
                        let ratio = Contrast.ratio(token.resolved(for: scheme), ground)

                        #expect(ratio >= floor, "\(name) is \(ratio):1 on the \(scheme) \(intensity) \(corner) glow")
                    }
                }
            }
        }
    }

    /// The accent used as text has to clear §9's floor where it is actually
    /// drawn, which the accent used as a fill never had to (§1.1, §4.4).
    ///
    /// Two places: a card, which is where a link inside a form or an error panel
    /// lands, and the dark ground's brightest point, which is where a link on
    /// the assistant lands. `#2b5cff` is 3.47:1 on the dark card, so the dark
    /// value is the lifted one and this is what says it was lifted far enough.
    @Test("the accent as text holds its floor on a card and on the dark ground")
    func accentTextHoldsItsFloor() {
        for scheme in FermixColorScheme.allCases {
            let ratio = Contrast.ratio(
                Palette.accentText.resolved(for: scheme),
                Palette.cardFill.resolved(for: scheme)
            )

            #expect(ratio >= 4.5, "the accent text is \(ratio):1 on the \(scheme) card")
        }

        // The retired treatment, kept as the measurement that forced the token.
        #expect(Contrast.ratio(Palette.accent.dark, Palette.cardFill.dark) < 4.5)

        let brightest = Contrast.composite(
            AmbientIntensity.expressive.leadingGlow.resolved(for: .dark),
            over: AmbientRecipe.groundStart.resolved(for: .dark)
        )
        let onGround = Contrast.ratio(Palette.accentText.dark, brightest)

        #expect(onGround >= 4.5, "the accent text is \(onGround):1 at the dark ground's brightest point")
    }
}

/// WCAG 2.1 relative luminance over sRGB, which is what §9's floors are
/// written in.
enum Contrast {
    static func ratio(_ first: SRGBColor, _ second: SRGBColor) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))

        return (lighter + 0.05) / (darker + 0.05)
    }

    /// An alpha token laid over an opaque ground, as the compositor resolves it.
    static func composite(_ top: SRGBColor, over ground: SRGBColor) -> SRGBColor {
        SRGBColor(
            red: top.red * top.alpha + ground.red * (1 - top.alpha),
            green: top.green * top.alpha + ground.green * (1 - top.alpha),
            blue: top.blue * top.alpha + ground.blue * (1 - top.alpha)
        )
    }

    static func luminance(_ color: SRGBColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
