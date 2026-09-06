import CoreGraphics
import Foundation
import Testing

@testable import FermixAppCore

/// The type ramp and the spacing/shape scale, restated from
/// `M34_DESIGN_SYSTEM_REDLINES.md` §§2–3.
@Suite("Design type and metrics")
struct DesignTypeAndMetricsTests {
    @Test("the type ramp matches the redline table")
    func typeRamp() {
        let expected: [(TypeRole, Double, Double?, Int, Bool)] = [
            (.display, 28, 34, 600, false),
            (.titleLarge, 24, 30, 600, false),
            (.title, 22, 28, 600, false),
            (.statusHeadline, 19, nil, 600, false),
            (.headline, 17, 22, 600, false),
            (.body, 15, 20, 400, false),
            (.bodyCompact, 14, 20, 400, false),
            (.callout, 13, 18, 500, false),
            (.calloutSmall, 12, 17, 400, false),
            (.caption, 11, 14, 500, false),
            (.mono, 13, nil, 400, true),
            (.monoLog, 11.5, 16, 400, true)
        ]

        for (role, size, leading, weight, monospaced) in expected {
            let style = Typography.style(role)

            #expect(style.size == size, "\(role) size")
            #expect(style.leading == leading, "\(role) leading")
            #expect(style.weight.numeric == weight, "\(role) weight")
            #expect(style.monospaced == monospaced, "\(role) monospaced")
        }
    }

    @Test("every role in the ramp is covered by the table")
    func everyRoleHasAStyle() {
        for role in TypeRole.allCases {
            #expect(Typography.style(role).size > 0, "\(role)")
        }
    }

    /// `lineSpacing` is the artboard leading minus the point size, which is
    /// what SwiftUI's `.lineSpacing` actually adds.
    @Test("line spacing is leading minus size")
    func lineSpacing() {
        #expect(Typography.style(.display).lineSpacing == 6)
        #expect(Typography.style(.body).lineSpacing == 5)
        #expect(Typography.style(.statusHeadline).lineSpacing == 0)
    }

    /// One rule, not a per-label constant: uppercase section labels take +4%
    /// tracking at whatever size they are set in.
    @Test("uppercase tracking is four percent of the point size")
    func uppercaseTracking() {
        #expect(Typography.uppercaseTrackingRatio == 0.04)
        #expect(Typography.style(.caption).uppercased().tracking == 0.44)
        #expect(Typography.style(.calloutSmall).uppercased().tracking == 0.48)
        #expect(Typography.style(.caption).tracking == 0)
        #expect(Typography.sectionLabel.tracking == 0.44)
        #expect(Typography.sectionLabel.weight == .semibold)
    }

    @Test("a weight override keeps every other value")
    func weightOverride() {
        let heavier = Typography.style(.bodyCompact).weight(.semibold)

        #expect(heavier.size == 14)
        #expect(heavier.leading == 20)
        #expect(heavier.weight == .semibold)
    }

    /// Every rung responds to `Accessibility ▸ Display ▸ Text size`.
    ///
    /// A fixed point size ignores it, and the whole ramp was fixed points under
    /// a comment claiming the text still grew (redlines §2). The rung keeps the
    /// redline's own size as its base and scales from it against a system text
    /// style, so the table above stays diffable *and* the type responds.
    ///
    /// The gate is written over the ramp rather than over a list of rungs: a
    /// role added later either declares its text style or fails here.
    @Test("every rung of the ramp scales against a system text style")
    func everyRungScales() throws {
        for role in TypeRole.allCases {
            let style = Typography.style(role)

            // `.body` is a real answer, so it cannot stand for "nobody chose":
            // the assertion is that the ratio is honoured, which is what a rung
            // with no style would fail on.
            #expect(style.ratio(at: style.size * 1.5) == 1.5, "\(role)")
            #expect(style.font(at: style.size * 1.5) != style.font, "\(role) draws one size whatever the step")
        }

        // Larger rungs scale against larger styles, so the ramp keeps its own
        // order at every step rather than collapsing at the top.
        #expect(Typography.style(.display).relativeTo == .largeTitle)
        #expect(Typography.style(.body).relativeTo == .body)
        #expect(Typography.style(.caption).relativeTo == .caption)

        // The one place a point size becomes a font is the scaled modifier, so
        // no view can reach past it for a fixed one.
        let ramp = try #require(try SourceTree.swiftFiles(matching: "Design/Tokens/Typography.swift").first)
        #expect(ramp.text.contains("@ScaledMetric"), "the ramp draws at a size nothing scales")
    }

    /// The whole product draws with the system font, and no font ships.
    ///
    /// The ramp resolves through `TypeStyle.font`, which is `.system` and
    /// nothing else, so this is the half a value assertion cannot see: a view
    /// that reached past the ramp for a face of its own, or a face bundled as a
    /// resource. Both are how a "we use the system font" claim stops being
    /// true without any table changing.
    @Test("no surface loads a font of its own, and none is bundled")
    func everyFaceIsTheSystemFace() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let forbidden = ["Font.custom(", ".custom(", "NSFont(name:", "CTFontCreateWithName"]

        for file in files {
            for needle in forbidden {
                #expect(!file.text.contains(needle), "\(file.path) reaches for \(needle)")
            }
        }

        // Nothing under Resources may be a font file: a bundled face would be
        // loadable by name even with no call site above.
        let resources = SourceTree.root.appendingPathComponent("Resources", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(atPath: resources.path))
        var faces: [String] = []
        for case let name as String in enumerator {
            let suffix = (name as NSString).pathExtension.lowercased()
            if ["ttf", "otf", "ttc", "woff", "woff2"].contains(suffix) { faces.append(name) }
        }

        #expect(faces.isEmpty, "\(faces)")
    }

    /// A settings row is one grouped-form row however many lines it draws, so
    /// the form's own insets stop at its edge. These are the gaps inside it
    /// (owner directive of 2026-09-03: "some of the items are stuck together
    /// without proper spacing").
    @Test("a settings row's own rhythm is on the spacing scale")
    func settingsRowRhythm() {
        #expect(SettingsRowMetrics.captionGap == Spacing.xxs)
        #expect(SettingsRowMetrics.entryGap == Spacing.xs)
        #expect(SettingsRowMetrics.stackGap == Spacing.s)
        #expect(SettingsRowMetrics.captionGap < SettingsRowMetrics.entryGap)
        #expect(SettingsRowMetrics.entryGap < SettingsRowMetrics.stackGap)

        for value in [SettingsRowMetrics.captionGap, SettingsRowMetrics.entryGap, SettingsRowMetrics.stackGap] {
            #expect(Spacing.scale.contains(value), "\(value) is off the scale")
        }
    }

    /// The assistant measures one text column, so the eight screens cannot each
    /// pick a width and read as eight layouts.
    @Test("the assistant has one subcopy width and one mascot size")
    func onboardingGrid() {
        #expect(OnboardingMetrics.contentWidth == 460)
        #expect(OnboardingMetrics.nextStepsWidth == 470)
        #expect(OnboardingMetrics.mascotSize == 96)
        #expect(OnboardingMetrics.horizontalPadding == 100)
    }

    @Test("the spacing scale is exactly the seven published steps")
    func spacingScale() {
        #expect(Spacing.scale == [4, 8, 12, 16, 24, 32, 48])
    }

    @Test("radii match the redline")
    func radii() {
        #expect(Radius.controlCompact == 8)
        #expect(Radius.control == 10)
        #expect(Radius.card == 12)
        #expect(Radius.window == 14)
        #expect(Radius.iconTile == 8)
        #expect(Radius.iconTileSmall == 6)
    }

    /// The menu-row metrics went with the popover: an `NSMenu` row is the
    /// system's geometry, not the app's.
    @Test("hit targets meet the published minimums")
    func hitTargets() {
        #expect(HitTarget.button == 36)
        #expect(HitTarget.onboardingCTA == 44)
    }

    @Test("strokes match the redline, and only the hero border is heavier")
    func strokes() {
        #expect(Stroke.hairline == 1)
        #expect(Stroke.heroBorder == 1.5)
        #expect(Stroke.icon == 1.8)
    }

    @Test("window geometry matches the redline")
    func windowGeometry() {
        #expect(WindowMetrics.onboardingSize.width == 800)
        #expect(WindowMetrics.onboardingSize.height == 520)
        #expect(WindowMetrics.mainDefaultSize.width == 1040)
        #expect(WindowMetrics.mainDefaultSize.height == 640)
        #expect(WindowMetrics.progressDotZoneHeight == 44)
        #expect(WindowMetrics.ladderMaxWidth == OnboardingMetrics.contentWidth)
        // One leading edge: a single content padding, not a tolerated range.
        #expect(WindowMetrics.contentPadding == 24)
        #expect(OnboardingMetrics.horizontalPadding == 100)
    }

    /// M34 §3.1: the sidebar column is a range the system lays out, not a fixed
    /// width the app draws.
    @Test("the sidebar column is 180 minimum, 200 ideal, 260 maximum")
    func sidebarColumn() {
        #expect(WindowMetrics.sidebarMinWidth == 180)
        #expect(WindowMetrics.sidebarIdealWidth == 200)
        #expect(WindowMetrics.sidebarMaxWidth == 260)
        #expect(WindowMetrics.sidebarMinWidth < WindowMetrics.sidebarIdealWidth)
        #expect(WindowMetrics.sidebarIdealWidth < WindowMetrics.sidebarMaxWidth)
    }

    /// One floor, not the pair a separate settings window allowed: decision D3
    /// puts settings inside this window, so the 220 pt pane column plus a
    /// readable content column has to fit at every size the user can reach.
    @Test("the window floor is 760 by 520, whatever the sidebar is doing")
    func windowFloor() {
        #expect(WindowMetrics.mainMinimumSize == CGSize(width: 760, height: 520))
        // The floor has to clear the settings pane column plus a content column
        // narrower than its own 640 pt ceiling.
        #expect(WindowMetrics.mainMinimumSize.width > WindowMetrics.settingsSidebarWidth + 400)
        #expect(WindowMetrics.mainMinimumSize.width > WindowMetrics.sidebarMaxWidth)
        #expect(WindowMetrics.mainDefaultSize.width > WindowMetrics.mainMinimumSize.width)
        #expect(WindowMetrics.mainDefaultSize.height > WindowMetrics.mainMinimumSize.height)
    }

    /// A mark drawn on the app's own tile takes most of it, and the neutral
    /// symbol a vendor without a retrievable mark falls to is drawn larger
    /// still, because a symbol comes out of a font with its own padding.
    ///
    /// At the previous 0.56 the 20-point settings tile gave a mark an 11-point
    /// box, so Mistral's logotype — which its own file centres in a square with
    /// a third of the height empty — drew at about 7 points beside 20-point
    /// marks that bleed; and the neutral symbol at 0.42 was an 8-point chip on
    /// three of the seven provider rows, which read as a smudge.
    @MainActor
    @Test("a mark and its neutral symbol are drawn at the recorded fractions")
    func markInsets() {
        #expect(VendorMarkView.inset == 0.72)
        #expect(VendorMarkView.symbolInset == 0.55)
        // The symbol is the larger fraction: a glyph fills its box and a symbol
        // does not.
        #expect(VendorMarkView.symbolInset * 20 >= 11, "the neutral symbol is legible at the settings size")
        #expect(VendorMarkView.inset < 1, "an inset mark does not reach the tile's edge")
    }
}
