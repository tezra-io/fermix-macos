import SwiftUI

/// The menu-bar status-item glyph in its three states.
///
/// Running is solid, starting pulses, attention carries a badge. The badge is
/// a shape with a ring in the menu-bar background colour, never a colour cue
/// on its own, and the panel header states the condition in words.
public struct MenuBarGlyphView: View {
    private let state: MenuBarGlyphState
    private let elapsed: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `elapsed` is the seconds since the pulse began. The status item redraws
    /// on a timer it owns, so the view stays a pure function of its inputs.
    public init(state: MenuBarGlyphState, elapsed: Double = 0) {
        precondition(elapsed >= 0, "elapsed time must not be negative")

        self.state = state
        self.elapsed = elapsed
    }

    public var body: some View {
        Image(nsImage: MenuBarGlyphImage.template())
            .renderingMode(.template)
            .foregroundStyle(Palette.ink.color)
            .frame(width: MenuBarGlyphMetrics.glyphSize, height: MenuBarGlyphMetrics.glyphSize)
            .opacity(opacity)
            .overlay(alignment: .topTrailing) { badge }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityLabel)
            .accessibilityIdentifier(DesignComponent.menuBarGlyph.accessibilityIdentifier)
    }

    private var opacity: Double {
        guard state.pulses else { return MenuBarGlyphPulse.maximumOpacity }

        return MenuBarGlyphPulse.opacity(atElapsed: elapsed, reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private var badge: some View {
        if state.showsBadge {
            Circle()
                .fill(Palette.warning.color)
                .frame(width: MenuBarGlyphMetrics.badgeDiameter, height: MenuBarGlyphMetrics.badgeDiameter)
                .overlay(
                    Circle().strokeBorder(Palette.base100.color, lineWidth: MenuBarGlyphMetrics.badgeRingWidth)
                )
                .offset(
                    x: MenuBarGlyphMetrics.badgeOffset.width,
                    y: MenuBarGlyphMetrics.badgeOffset.height
                )
                .accessibilityHidden(true)
        }
    }
}
