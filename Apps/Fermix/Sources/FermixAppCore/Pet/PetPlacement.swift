import CoreGraphics

/// Where the floating pet hatches: beside the primary window's bottom-right
/// corner, so it appears next to the app rather than centred on the screen,
/// which on a wide display is far from it (owner, 2026-09-28: "is it possible
/// to hatch it close to app").
///
/// Outside the window, because the pet takes the click across its whole frame
/// (it is dragged from anywhere) and the window's bottom-right is where the
/// chat composer sends. On the window's left when the right has no room, and
/// over the window's own corner only when neither side has. With no primary
/// window on screen it hatches in the bottom-right corner of the screen.
///
/// All frames are AppKit screen coordinates, origin at the bottom left.
public enum PetPlacement {
    public static func frame(size: CGSize, beside primary: CGRect?, within visible: CGRect) -> CGRect {
        guard let primary else {
            return CGRect(origin: CGPoint(x: visible.maxX - size.width, y: visible.minY), size: size)
        }

        let bottom = min(max(primary.minY, visible.minY), visible.maxY - size.height)
        let right = CGRect(origin: CGPoint(x: primary.maxX, y: bottom), size: size)
        let left = CGRect(origin: CGPoint(x: primary.minX - size.width, y: bottom), size: size)

        if visible.contains(right) { return right }
        if visible.contains(left) { return left }

        let corner = min(primary.maxX, visible.maxX) - size.width
        return CGRect(origin: CGPoint(x: corner, y: bottom), size: size)
    }
}
