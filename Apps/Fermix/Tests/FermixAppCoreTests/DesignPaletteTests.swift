import CoreGraphics
import Testing

@testable import FermixAppCore

/// The M33 redline tables, restated as assertions.
///
/// Every value here is copied from
/// `docs/design/M34_DESIGN_SYSTEM_REDLINES.md` §§1.1–1.3. A token that drifts
/// from the published table fails here rather than in a screenshot diff.
@Suite("Design palette")
struct DesignPaletteTests {
    @Test("hex round-trips through the sRGB channels")
    func hexRoundTrips() {
        #expect(SRGBColor(hex: "#2b5cff").hexString == "#2b5cff")
        #expect(SRGBColor(hex: "#fcfcfc").hexString == "#fcfcfc")
        #expect(SRGBColor(hex: "#020202").hexString == "#020202")
    }

    @Test("an alpha token keeps the published channels verbatim")
    func alphaTokensAreVerbatim() {
        let token = SRGBColor.rgba(43, 92, 255, 0.4)

        #expect(token.hexString == "#2b5cff")
        #expect(token.alpha == 0.4)
    }

    @Test("the semantic palette matches the redline table")
    func semanticPalette() {
        let expected: [(String, ThemedColor, String, String)] = [
            ("base100", Palette.base100, "#f6f7f9", "#101014"),
            ("base200", Palette.base200, "#eef0f3", "#0b0b0e"),
            ("base300", Palette.base300, "#e3e5e9", "#1e1e24"),
            ("ink", Palette.ink, "#16161a", "#f4f5f7"),
            ("secondary", Palette.secondary, "#52565e", "#a6abb4"),
            ("faint", Palette.faint, "#7d8087", "#75787f"),
            ("accent", Palette.accent, "#2b5cff", "#2b5cff"),
            ("accentHover", Palette.accentHover, "#4a73ff", "#4a73ff"),
            ("accentPressed", Palette.accentPressed, "#1e46d6", "#1e46d6"),
            ("success", Palette.success, "#1f7a4d", "#4cc38a"),
            ("warning", Palette.warning, "#9a6b1f", "#e0b35c"),
            ("error", Palette.error, "#b3423a", "#e5766c"),
            ("successText", Palette.successText, "#176641", "#7fd6ac"),
            ("pillPass", Palette.pillPass, "#1f7a4d", "#4cc38a"),
            ("pillWarn", Palette.pillWarn, "#9a6b1f", "#e0b35c"),
            ("cardFill", Palette.cardFill, "#ffffff", "#17171c")
        ]

        for (name, token, light, dark) in expected {
            #expect(token.resolved(for: .light).hexString == light, "\(name) light")
            #expect(token.resolved(for: .dark).hexString == dark, "\(name) dark")
        }
    }

    /// Palette v2's one amendment to "chroma 0 neutrals": ground fills carry a
    /// barely-cool cast. The dark elevation ladder must actually step —
    /// recessed, ground, card, hover, each lighter than the last — because the
    /// steps, not shadows, are what carry elevation on an opaque ground.
    @Test("the dark elevation ladder steps recessed, ground, card, hover")
    func darkElevationLadder() {
        let ladder = [Palette.base200, Palette.base100, Palette.cardFill, Palette.base300]
            .map { $0.resolved(for: .dark) }

        for (lower, higher) in zip(ladder, ladder.dropFirst()) {
            #expect(lower.red < higher.red, "\(lower.hexString) must sit below \(higher.hexString)")
        }
    }

    /// The focus ring is the accent at 45%, drawn as a 3-point outer stroke.
    @Test("the focus ring is the accent at 45 percent in both schemes")
    func focusRing() {
        #expect(Palette.focusRing.light == .rgba(43, 92, 255, 0.45))
        #expect(Palette.focusRing.dark == .rgba(43, 92, 255, 0.45))
    }

    /// `#2b5cff` is authored as hex and never round-tripped through oklch, so
    /// the accent must be byte-identical in both schemes.
    @Test("the one blue is the same colour in both schemes")
    func accentIsSchemeIndependent() {
        #expect(Palette.accent.light == Palette.accent.dark)
        #expect(Palette.accentPressed.light == Palette.accentPressed.dark)
    }

    /// The redline gives `linkHoverDark` a dark value only; light links reuse
    /// the accent's pressed colour.
    @Test("link hover resolves to the dark-only token on dark")
    func linkHover() {
        #expect(Palette.linkHoverDark.hexString == "#6b8dff")
        #expect(Palette.linkHover.resolved(for: .dark).hexString == "#6b8dff")
        #expect(Palette.linkHover.resolved(for: .light) == Palette.accentPressed.light)
    }

    @Test("the alpha tokens match the redline table")
    func alphaPalette() {
        let expected: [(String, ThemedColor, SRGBColor, SRGBColor)] = [
            ("chipFill", Palette.chipFill, .rgba(0, 0, 0, 0.04), .rgba(255, 255, 255, 0.07)),
            ("monoDisc", Palette.monoDisc, .rgba(0, 0, 0, 0.06), .rgba(255, 255, 255, 0.10)),
            ("buttonFill", Palette.buttonFill, .rgba(255, 255, 255, 1.0), .rgba(255, 255, 255, 0.09)),
            ("buttonBorder", Palette.buttonBorder, .rgba(0, 0, 0, 0.14), .rgba(255, 255, 255, 0.18)),
            ("navActive", Palette.navActive, .rgba(43, 92, 255, 0.12), .rgba(43, 92, 255, 0.20)),
            ("sheen", Palette.sheen, .rgba(43, 92, 255, 0.05), .rgba(255, 255, 255, 0.05)),
            ("dotDone", Palette.dotDone, .rgba(43, 92, 255, 0.40), .rgba(43, 92, 255, 0.45)),
            ("successPillFill", Palette.successPillFill, .rgba(31, 122, 77, 0.08), .rgba(76, 195, 138, 0.10)),
            ("successPillBorder", Palette.successPillBorder, .rgba(31, 122, 77, 0.25), .rgba(76, 195, 138, 0.28)),
            ("successGlow", Palette.successGlow, .rgba(31, 122, 77, 0.16), .rgba(76, 195, 138, 0.20)),
            ("warnPillFill", Palette.warnPillFill, .rgba(154, 107, 31, 0.08), .rgba(224, 179, 92, 0.10)),
            ("warnIconFill", Palette.warnIconFill, .rgba(154, 107, 31, 0.14), .rgba(224, 179, 92, 0.14)),
            ("warnPillBorder", Palette.warnPillBorder, .rgba(154, 107, 31, 0.25), .rgba(224, 179, 92, 0.26)),
            ("errorDiscFill", Palette.errorDiscFill, .rgba(179, 66, 58, 0.08), .rgba(229, 118, 108, 0.10)),
            ("errorDiscBorder", Palette.errorDiscBorder, .rgba(179, 66, 58, 0.25), .rgba(229, 118, 108, 0.28)),
            ("focusRing", Palette.focusRing, .rgba(43, 92, 255, 0.45), .rgba(43, 92, 255, 0.45))
        ]

        for (name, token, light, dark) in expected {
            #expect(token.light == light, "\(name) light")
            #expect(token.dark == dark, "\(name) dark")
        }
    }

    @Test("the three hairline weights match the redline table")
    func hairlines() {
        #expect(Palette.hairline(.standard).light == .rgba(0, 0, 0, 0.10))
        #expect(Palette.hairline(.standard).dark == .rgba(255, 255, 255, 0.14))
        #expect(Palette.hairline(.faint).light == .rgba(0, 0, 0, 0.06))
        #expect(Palette.hairline(.faint).dark == .rgba(255, 255, 255, 0.09))
        #expect(Palette.hairline(.strong).light == .rgba(0, 0, 0, 0.16))
        #expect(Palette.hairline(.strong).dark == .rgba(255, 255, 255, 0.24))
    }

    /// Increase Contrast raises every hairline to 25% and leaves fills alone.
    @Test("increase contrast raises every hairline to 25% and touches no fill")
    func increaseContrastRaisesHairlinesOnly() {
        for weight in HairlineWeight.allCases {
            let raised = Palette.hairline(weight, increaseContrast: true)

            #expect(raised.light == .rgba(0, 0, 0, 0.25), "\(weight) light")
            #expect(raised.dark == .rgba(255, 255, 255, 0.25), "\(weight) dark")
        }

        #expect(Palette.cardFill.light.alpha == 1.0, "cards are opaque")
        #expect(Palette.chipFill.light.alpha == 0.04)
    }
}
