import CoreGraphics
import Foundation

/// The seven-step spacing scale (`M34_DESIGN_SYSTEM_REDLINES.md` §3). Nothing
/// is off-scale except the documented odd paddings, which are load-bearing
/// artboard values and live on the component that uses them.
public enum Spacing {
    public static let xxs: Double = 4
    public static let xs: Double = 8
    public static let s: Double = 12
    public static let m: Double = 16
    public static let l: Double = 24
    public static let xl: Double = 32
    public static let xxl: Double = 48

    public static let scale: [Double] = [xxs, xs, s, m, l, xl, xxl]
}

/// Corner radii. Pills, orbs, and dots are capsules and have no entry.
public enum Radius {
    public static let controlCompact: Double = 8
    public static let control: Double = 10
    public static let card: Double = 12
    public static let window: Double = 14
    public static let popover: Double = 12
    public static let menuRow: Double = 7
    public static let iconTile: Double = 8
    public static let iconTileSmall: Double = 6
}

/// Minimum interactive heights.
public enum HitTarget {
    public static let menuRowMinimum: Double = 28
    public static let menuRow: Double = 32
    public static let button: Double = 36
    public static let onboardingCTA: Double = 44
}

/// Stroke widths. Only the Telegram hero card is heavier than a hairline.
public enum Stroke {
    public static let hairline: Double = 1
    public static let heroBorder: Double = 1.5
    /// The one icon family: stroked, 1.8pt, on a 16/20/24 grid.
    public static let icon: Double = 1.8
}

/// Window and panel geometry (`M34_DESIGN_SYSTEM_REDLINES.md` §5).
public enum WindowMetrics {
    /// Fixed, non-resizable, centred on the backdrop.
    public static let onboardingSize = CGSize(width: 800, height: 520)
    /// Default size; the main window is resizable.
    public static let mainDefaultSize = CGSize(width: 880, height: 560)
    public static let sidebarWidth: Double = 200
    public static let titlebarHeight: Double = 52
    public static let progressDotZoneHeight: Double = 44
    public static let popoverWidth: Double = 300
    public static let ladderCardWidth: Double = 380
    public static let contentPadding: ClosedRange<Double> = 22...26
}

/// The progress-dot zone at the foot of every onboarding screen.
public enum ProgressDotMetrics {
    public static let activeSize = CGSize(width: 22, height: 6)
    public static let inactiveDiameter: Double = 6
    public static let gap: Double = 8
}

/// The menu-bar status item (`M34_DESIGN_SYSTEM_REDLINES.md` §5.10).
public enum MenuBarGlyphMetrics {
    public static let glyphSize: Double = 16
    public static let badgeDiameter: Double = 7
    /// A ring in the menu-bar background colour keeps the badge legible on any
    /// wallpaper. It is a shape, not a colour cue.
    public static let badgeRingWidth: Double = 1.5
    /// `right -3, top -2`, expressed as a trailing/top offset.
    public static let badgeOffset = CGSize(width: 3, height: -2)
}
