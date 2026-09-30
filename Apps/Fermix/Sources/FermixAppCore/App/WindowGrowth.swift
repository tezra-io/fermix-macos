import CoreGraphics
import Foundation

/// Where a window may sit and how large it may be: growing the primary window
/// when settings opens (decision D3, owner directive of 2026-09-03: "you can
/// work on resizing the initial app based on the need"), widening it for the
/// browser pane and giving the width back (plan §4.3), and holding every window
/// inside the screen it is on.
///
/// The rule is a pure function of three rectangles so it is provable without a
/// window server: the frame the window has, the size settings needs, and the
/// visible screen frame that bounds the answer. `AppKitWindowHost` supplies the
/// three and animates to what this returns.
///
/// Anchored at the top-left because an AppKit frame origin is its *bottom*-left:
/// growing downward from a fixed origin would drag the titlebar down the screen
/// under the pointer, which reads as the window jumping.
public enum WindowGrowth {
    /// The frame the window should take, or nil where it is already large
    /// enough and nothing should move.
    ///
    /// - Parameters:
    ///   - frame: the window's frame now, in screen coordinates.
    ///   - wanted: the smallest size settings is legible at.
    ///   - visible: the screen's visible frame, which excludes the menu bar and
    ///     the Dock.
    public static func frame(
        growing frame: CGRect,
        toAtLeast wanted: CGSize,
        within visible: CGRect
    ) -> CGRect? {
        precondition(wanted.width > 0 && wanted.height > 0, "a growth target needs a size")
        guard visible.width > 0, visible.height > 0 else { return nil }

        let size = grown(frame.size, toAtLeast: wanted, within: visible.size)
        guard size != frame.size else { return nil }

        return CGRect(origin: origin(holdingTopLeftOf: frame, at: size, within: visible), size: size)
    }

    /// The frame the window should take to sit inside the screen it is on, or
    /// nil where it already does and nothing should move.
    ///
    /// A window's size is the app's: a descriptor, the growth above, or the
    /// operator's own drag. A frame can still arrive from outside all three,
    /// because `NSWindow` restores an autosaved frame that was written on a
    /// larger display, or by a build in which the SwiftUI content set the
    /// window's size extrema. Presenting runs this, so such a frame is
    /// corrected before it is shown and the corrected one is what gets saved.
    /// AppKit bounds a titled window's frame as well, restored or centred; a
    /// borderless one it leaves alone, so the floating pet has no ceiling but
    /// this. One rule for all three windows rather than one per style mask.
    ///
    /// - Parameters:
    ///   - frame: the window's frame now, in screen coordinates.
    ///   - visible: the screen's visible frame, which excludes the menu bar and
    ///     the Dock.
    public static func frame(fitting frame: CGRect, within visible: CGRect) -> CGRect? {
        guard visible.width > 0, visible.height > 0 else { return nil }

        let size = bounded(frame.size, within: visible.size)
        let fitted = CGRect(
            origin: origin(holdingTopLeftOf: frame, at: size, within: visible),
            size: size
        )

        return fitted == frame ? nil : fitted
    }

    /// The size to grow to: never smaller than the window already is, never
    /// larger than the screen can show. A window wider than the target keeps
    /// its width, because growth is one-way.
    private static func grown(
        _ size: CGSize,
        toAtLeast wanted: CGSize,
        within screen: CGSize
    ) -> CGSize {
        bounded(
            CGSize(width: max(size.width, wanted.width), height: max(size.height, wanted.height)),
            within: screen
        )
    }

    /// The one ceiling, in both directions: a window is never larger than the
    /// screen can show it.
    private static func bounded(_ size: CGSize, within screen: CGSize) -> CGSize {
        CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
    }

    // MARK: - A pane beside the content

    /// Where a window stands, which only AppKit can say.
    public struct Placement: Equatable, Sendable {
        /// The window's frame, in screen coordinates.
        public let frame: CGRect
        /// The visible frame of the screen it is on, which excludes the menu
        /// bar and the Dock.
        public let visible: CGRect
        /// Full screen or zoomed: the window's size is the screen's, and a pane
        /// takes its width from the content instead.
        public let fillsScreen: Bool

        public init(frame: CGRect, visible: CGRect, fillsScreen: Bool) {
            self.frame = frame
            self.visible = visible
            self.fillsScreen = fillsScreen
        }
    }

    /// What opening a pane did to the window, kept until the pane closes.
    public struct PaneWidening: Equatable, Sendable {
        /// The frame the window had before the pane opened.
        public let before: CGRect
        /// The frame the app gave it for the pane.
        public let widened: CGRect
    }

    /// A window's answer to a pane opening or closing.
    public struct PaneLayout: Equatable, Sendable {
        /// Where the window goes, or nil where it stays.
        public let frame: CGRect?
        /// The smallest the person may make the window now.
        public let minimumSize: CGSize
        /// What to remember until the pane closes, or nil where nothing moved.
        public let widening: PaneWidening?
    }

    /// Opening a pane beside the content (plan §4.3).
    ///
    /// The window widens to the right by the pane's width, from where it was,
    /// so the content keeps its width and the pane is added beside it. A right
    /// edge that would pass the screen's shifts the window left; a window that
    /// would be wider than the screen is held to the screen's width, and the
    /// pane takes the difference from the content. The minimum rises by the
    /// pane, so the content keeps its own floor beside it. A window that fills
    /// the screen, full screen or zoomed, is not moved at all.
    public static func opening(pane width: Double, at placement: Placement, minimum: CGSize) -> PaneLayout {
        precondition(width > 0, "a pane has a width")

        let raised = paneMinimum(pane: width, base: minimum, within: placement.visible)
        guard !placement.fillsScreen else { return PaneLayout(frame: nil, minimumSize: raised, widening: nil) }

        let widened = frame(widening: placement.frame, by: width, within: placement.visible)
        guard widened != placement.frame else { return PaneLayout(frame: nil, minimumSize: raised, widening: nil) }

        return PaneLayout(
            frame: widened,
            minimumSize: raised,
            widening: PaneWidening(before: placement.frame, widened: widened)
        )
    }

    /// Closing the pane (plan §4.3).
    ///
    /// The window goes back to the frame it had before only while it is still
    /// the frame the app gave it: a window the person has moved or resized since
    /// is theirs, and stays where they put it. Either way the minimum comes back
    /// down, and a window that fills the screen is not moved.
    public static func closing(at placement: Placement, widening: PaneWidening?, minimum: CGSize) -> PaneLayout {
        guard !placement.fillsScreen, let widening, isSameFrame(placement.frame, widening.widened) else {
            return PaneLayout(frame: nil, minimumSize: minimum, widening: nil)
        }

        return PaneLayout(frame: widening.before, minimumSize: minimum, widening: nil)
    }

    /// The window's floor while a pane is open: its own floor plus the pane,
    /// never wider than the screen can show.
    public static func paneMinimum(pane width: Double, base minimum: CGSize, within visible: CGRect) -> CGSize {
        CGSize(width: min(minimum.width + width, visible.width), height: minimum.height)
    }

    /// The frame widened to the right, shifted left where its right edge would
    /// pass the screen's, and held to the screen's width.
    private static func frame(widening frame: CGRect, by width: Double, within visible: CGRect) -> CGRect {
        let wide = min(frame.width + width, visible.width)
        let x = min(frame.minX, visible.maxX - wide)

        return CGRect(x: max(x, visible.minX), y: frame.minY, width: wide, height: frame.height)
    }

    /// AppKit settles an animated frame on its own backing grid, so a frame the
    /// app set may read back a fraction of a point away from the one it asked
    /// for. Anything under a point is the same frame; a person's own move or
    /// resize is never that small.
    private static func isSameFrame(_ one: CGRect, _ other: CGRect) -> Bool {
        abs(one.minX - other.minX) < 1 && abs(one.minY - other.minY) < 1
            && abs(one.width - other.width) < 1 && abs(one.height - other.height) < 1
    }

    /// The origin that keeps the window's top-left where it was, pushed back
    /// inside the visible frame where growth would have taken it off-screen.
    private static func origin(
        holdingTopLeftOf frame: CGRect,
        at size: CGSize,
        within visible: CGRect
    ) -> CGPoint {
        let top = frame.maxY
        let unclamped = CGPoint(x: frame.minX, y: top - size.height)

        return CGPoint(
            x: min(max(unclamped.x, visible.minX), visible.maxX - size.width),
            y: min(max(unclamped.y, visible.minY), visible.maxY - size.height)
        )
    }
}
