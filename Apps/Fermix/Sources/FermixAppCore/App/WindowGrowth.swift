import CoreGraphics
import Foundation

/// Where a window may sit and how large it may be: growing the primary window
/// when settings opens (decision D3, owner directive of 2026-09-03: "you can
/// work on resizing the initial app based on the need"), and holding every
/// window inside the screen it is on.
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
