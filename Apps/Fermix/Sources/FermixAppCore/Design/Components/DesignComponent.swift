import Foundation

/// Every component in the design system.
///
/// The inventory exists so accessibility can be gated as one invariant over
/// the whole library instead of component by component: a component added
/// later either joins this enum or has no identifier to render with.
public enum DesignComponent: String, CaseIterable, Sendable {
    case glassChrome
    case card
    case sidebarRow
    case statusRow
    case statusPill
    case letterPill
    case chip
    case primaryButton
    case secondaryButton
    case linkButton
    case menuRow
    case progressLadder
    case progressDots
    case emptyState
    case errorPanel
    case menuBarGlyph

    /// The accessibility identifier the view renders with. Stable, namespaced,
    /// and unique, so a UI test can name a component without matching copy.
    public var accessibilityIdentifier: String {
        "fermix.\(rawValue)"
    }

    /// Whether the user acts on this component.
    ///
    /// An interactive component is built on a `Button`, which is what puts it
    /// in the keyboard focus order and draws the system focus ring; §9 forbids
    /// suppressing that ring. Static and decorative components stay out of the
    /// focus order and carry a label rather than an action.
    public var isInteractive: Bool {
        switch self {
        case .sidebarRow, .primaryButton, .secondaryButton, .linkButton, .menuRow:
            return true
        case .glassChrome, .card, .statusRow, .statusPill, .letterPill, .chip,
             .progressLadder, .progressDots, .emptyState, .errorPanel, .menuBarGlyph:
            return false
        }
    }
}
