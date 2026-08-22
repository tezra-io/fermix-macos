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
        #expect(Radius.popover == 12)
        #expect(Radius.menuRow == 7)
        #expect(Radius.iconTile == 8)
        #expect(Radius.iconTileSmall == 6)
    }

    @Test("hit targets meet the published minimums")
    func hitTargets() {
        #expect(HitTarget.menuRow == 32)
        #expect(HitTarget.menuRow >= HitTarget.menuRowMinimum)
        #expect(HitTarget.menuRowMinimum == 28)
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
        #expect(WindowMetrics.mainDefaultSize.width == 880)
        #expect(WindowMetrics.mainDefaultSize.height == 560)
        #expect(WindowMetrics.sidebarWidth == 200)
        #expect(WindowMetrics.titlebarHeight == 52)
        #expect(WindowMetrics.progressDotZoneHeight == 44)
        #expect(WindowMetrics.popoverWidth == 300)
        #expect(WindowMetrics.ladderCardWidth == 380)
        #expect(WindowMetrics.contentPadding == 22...26)
    }
}
