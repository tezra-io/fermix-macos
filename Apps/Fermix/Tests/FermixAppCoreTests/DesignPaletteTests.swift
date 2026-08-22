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
            ("base100", Palette.base100, "#fcfcfc", "#020202"),
            ("base200", Palette.base200, "#f5f5f5", "#060606"),
            ("base300", Palette.base300, "#e4e4e4", "#1b1b1b"),
            ("ink", Palette.ink, "#161616", "#f2f2f2"),
            ("secondary", Palette.secondary, "#555555", "#9e9e9e"),
            ("faint", Palette.faint, "#808080", "#717171"),
            ("accent", Palette.accent, "#2b5cff", "#2b5cff"),
            ("accentPressed", Palette.accentPressed, "#1e46d6", "#1e46d6"),
            ("success", Palette.success, "#618374", "#8bae9e"),
            ("warning", Palette.warning, "#9c815d", "#ceb38d"),
            ("error", Palette.error, "#a05c57", "#ca827c"),
            ("successText", Palette.successText, "#3d5d4f", "#adc4b9"),
            ("pillPass", Palette.pillPass, "#4b6c5d", "#8bae9e"),
            ("pillWarn", Palette.pillWarn, "#866d49", "#ceb38d")
        ]

        for (name, token, light, dark) in expected {
            #expect(token.resolved(for: .light).hexString == light, "\(name) light")
            #expect(token.resolved(for: .dark).hexString == dark, "\(name) dark")
        }
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
            ("cardFill", Palette.cardFill, .rgba(255, 255, 255, 0.60), .rgba(255, 255, 255, 0.045)),
            ("chipFill", Palette.chipFill, .rgba(255, 255, 255, 0.70), .rgba(255, 255, 255, 0.06)),
            ("monoDisc", Palette.monoDisc, .rgba(0, 0, 0, 0.06), .rgba(255, 255, 255, 0.10)),
            ("buttonFill", Palette.buttonFill, .rgba(255, 255, 255, 0.85), .rgba(255, 255, 255, 0.08)),
            ("buttonBorder", Palette.buttonBorder, .rgba(0, 0, 0, 0.12), .rgba(255, 255, 255, 0.16)),
            ("navActive", Palette.navActive, .rgba(43, 92, 255, 0.10), .rgba(43, 92, 255, 0.16)),
            ("sheen", Palette.sheen, .rgba(43, 92, 255, 0.05), .rgba(255, 255, 255, 0.05)),
            ("dotDone", Palette.dotDone, .rgba(43, 92, 255, 0.40), .rgba(43, 92, 255, 0.45)),
            ("successPillFill", Palette.successPillFill, .rgba(40, 160, 110, 0.07), .rgba(120, 220, 180, 0.08)),
            ("successPillBorder", Palette.successPillBorder, .rgba(40, 160, 110, 0.22), .rgba(120, 220, 180, 0.20)),
            ("successGlow", Palette.successGlow, .rgba(40, 160, 110, 0.15), .rgba(120, 220, 180, 0.18)),
            ("warnPillFill", Palette.warnPillFill, .rgba(200, 150, 50, 0.06), .rgba(235, 200, 120, 0.07)),
            ("warnIconFill", Palette.warnIconFill, .rgba(200, 150, 50, 0.12), .rgba(235, 200, 120, 0.12)),
            ("warnPillBorder", Palette.warnPillBorder, .rgba(200, 150, 50, 0.22), .rgba(235, 200, 120, 0.20)),
            ("errorDiscFill", Palette.errorDiscFill, .rgba(200, 80, 60, 0.06), .rgba(230, 130, 110, 0.08)),
            ("errorDiscBorder", Palette.errorDiscBorder, .rgba(200, 80, 60, 0.20), .rgba(230, 130, 110, 0.22))
        ]

        for (name, token, light, dark) in expected {
            #expect(token.light == light, "\(name) light")
            #expect(token.dark == dark, "\(name) dark")
        }
    }

    @Test("the three hairline weights match the redline table")
    func hairlines() {
        #expect(Palette.hairline(.standard).light == .rgba(0, 0, 0, 0.08))
        #expect(Palette.hairline(.standard).dark == .rgba(255, 255, 255, 0.10))
        #expect(Palette.hairline(.faint).light == .rgba(0, 0, 0, 0.05))
        #expect(Palette.hairline(.faint).dark == .rgba(255, 255, 255, 0.06))
        #expect(Palette.hairline(.strong).light == .rgba(0, 0, 0, 0.16))
        #expect(Palette.hairline(.strong).dark == .rgba(255, 255, 255, 0.20))
    }

    /// Increase Contrast raises every hairline to 25% and leaves fills alone.
    @Test("increase contrast raises every hairline to 25% and touches no fill")
    func increaseContrastRaisesHairlinesOnly() {
        for weight in HairlineWeight.allCases {
            let raised = Palette.hairline(weight, increaseContrast: true)

            #expect(raised.light == .rgba(0, 0, 0, 0.25), "\(weight) light")
            #expect(raised.dark == .rgba(255, 255, 255, 0.25), "\(weight) dark")
        }

        #expect(Palette.cardFill.light.alpha == 0.60)
        #expect(Palette.chipFill.light.alpha == 0.70)
    }

    @Test("the backdrop gradient matches the redline")
    func backdropGradient() {
        #expect(Backdrop.gradientAngleDegrees == 160)
        #expect(Backdrop.gradient.start.resolved(for: .light).hexString == "#f1f4f6")
        #expect(Backdrop.gradient.end.resolved(for: .light).hexString == "#fcfcfc")
        #expect(Backdrop.gradient.start.resolved(for: .dark).hexString == "#070709")
        #expect(Backdrop.gradient.end.resolved(for: .dark).hexString == "#020202")
    }

    @Test("welcome carries both drifting blobs and every other surface is static")
    func backdropBlobs() {
        let welcome = Backdrop.blobs(.welcome)

        #expect(welcome.count == 2)
        #expect(welcome[0].diameter == 560)
        #expect(welcome[0].blurRadius == 70)
        #expect(welcome[0].color.light.alpha == 0.12)
        #expect(welcome[0].color.dark.alpha == 0.20)
        #expect(welcome[1].diameter == 640)
        #expect(welcome[1].blurRadius == 80)
        #expect(welcome[1].color.light.alpha == 0.07)
        #expect(welcome[1].color.dark.alpha == 0.12)
        #expect(Backdrop.drifts(.welcome))

        #expect(Backdrop.blobs(.window).count == 1)
        #expect(Backdrop.blobs(.window)[0].color.light.alpha == 0.10)
        #expect(Backdrop.blobs(.bootFailed)[0].color.light.alpha == 0.09)
        #expect(Backdrop.blobs(.menuBar)[0].diameter == 480)

        for surface in BackdropSurface.allCases where surface != .welcome {
            #expect(!Backdrop.drifts(surface), "\(surface) must be static")
        }
    }

    /// The artboards write blob offsets as CSS insets from an anchored corner,
    /// where a negative value pushes the blob *outside* that corner. SwiftUI's
    /// offset is signed the other way round on the trailing and bottom edges, so
    /// the inset has to be resolved rather than passed through: blob B is
    /// `right: -160px; bottom: -200px`, which must bleed down and to the right.
    @Test("every blob bleeds past its anchored corner rather than inward")
    func blobsBleedOutward() {
        let welcome = Backdrop.blobs(.welcome)

        #expect(welcome[0].anchor == .topLeading)
        #expect(welcome[0].offset == CGSize(width: -140, height: -160))
        #expect(welcome[0].resolvedOffset == CGSize(width: -140, height: -160))

        #expect(welcome[1].anchor == .bottomTrailing)
        #expect(welcome[1].offset == CGSize(width: -160, height: -200))
        #expect(welcome[1].resolvedOffset == CGSize(width: 160, height: 200))

        // Written as an invariant over every surface: a blob added later either
        // bleeds outward too, or fails here.
        for surface in BackdropSurface.allCases {
            for blob in Backdrop.blobs(surface) {
                let outward = blob.anchor == .topLeading
                    ? blob.resolvedOffset.width <= 0 && blob.resolvedOffset.height <= 0
                    : blob.resolvedOffset.width >= 0 && blob.resolvedOffset.height >= 0

                #expect(outward, "\(surface) blob at \(blob.anchor) drifts inward")
            }
        }
    }

    /// Every blob is the one blue. A second accent on a surface is a design
    /// defect the redline names explicitly.
    @Test("every backdrop blob is the accent blue")
    func blobsAreAccentOnly() {
        for surface in BackdropSurface.allCases {
            for blob in Backdrop.blobs(surface) {
                let light = blob.color.light

                #expect(light.hexString == "#2b5cff" || light.hexString == "#5a82ff", "\(surface)")
            }
        }
    }
}
