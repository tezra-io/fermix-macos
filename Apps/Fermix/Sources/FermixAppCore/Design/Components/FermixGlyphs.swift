import SwiftUI

/// The Fermix bolt, as a shape.
///
/// The path is the artboards' own, on their 24-point grid, scaled to whatever
/// square it is drawn in. The shipped menu-bar icon is the approved template
/// raster, not this: the shape exists for in-window chrome (the Activate chip,
/// the Doctor banner) where the glyph is drawn at an arbitrary size in
/// `currentColor`.
public struct FermixBoltShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(
            x: rect.midX - 12 * unit,
            y: rect.midY - 12 * unit
        )

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }

        var path = Path()
        path.move(to: point(13, 2))
        path.addLine(to: point(4.5, 13.5))
        path.addLine(to: point(11, 13.5))
        path.addLine(to: point(10, 22))
        path.addLine(to: point(19.5, 9.5))
        path.addLine(to: point(13, 9.5))
        path.closeSubpath()

        return path
    }
}

/// The shipped menu-bar template images, one per state.
///
/// Each is the interim Fermix mark — the FermixPet mascot in one ink —
/// rasterized from a single master by `scripts/build_menu_bar_template.py`, and
/// each carries alpha only, so macOS tints it for the current menu-bar
/// appearance and sizes it the way it sizes every other status item.
///
/// The state is IN the image because an `NSStatusItem` draws an image: a view
/// layered over the status button is what clipped the old badge, and it is what
/// kept the system from owning the item's sizing, hover and glass.
/// `FermixBoltShape` is not an alternative to these: the shape is for in-window
/// chrome drawn at an arbitrary size in the accent, which a tinted 18-point
/// raster cannot be.
///
/// A missing raster is a packaging defect, not a runtime condition, so it traps
/// rather than returning nil for a caller to quietly draw around.
public enum MenuBarGlyphImage {
    /// The raster a state draws. The names are the build script's own, so a
    /// state whose raster was never generated fails at the bundle read rather
    /// than falling back to a neighbouring state's shape.
    public static func resourceName(for state: MenuBarGlyphState) -> String {
        switch state {
        case .running: return "FermixMarkTemplate"
        case .starting: return "FermixMarkStartingTemplate"
        case .attention: return "FermixMarkAttentionTemplate"
        }
    }

    /// The template for one state, loaded once.
    ///
    /// The status item is redrawn on every model change, and an `NSImage`
    /// rebuilt from the bundle each time is a file read on the main thread for
    /// no gain.
    @MainActor
    public static func template(for state: MenuBarGlyphState) -> NSImage {
        if let loaded = cache[state] { return loaded }

        let name = resourceName(for: state)
        guard let image = AppResources.bundle.image(forResource: name) else {
            preconditionFailure("Missing \(name) in the application resource bundle")
        }

        image.isTemplate = true
        image.size = NSSize(width: MenuBarGlyphMetrics.imageSize, height: MenuBarGlyphMetrics.imageSize)
        cache[state] = image

        return image
    }

    @MainActor
    private static var cache: [MenuBarGlyphState: NSImage] = [:]
}
