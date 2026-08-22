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

/// The tick inside a completed ladder row's disc. Stroked, round caps, on the
/// same 24-point grid.
public struct FermixCheckShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }

        var path = Path()
        path.move(to: point(5, 13))
        path.addLine(to: point(10, 18))
        path.addLine(to: point(19, 7))

        return path
    }
}

/// The 90-degree arc of the ladder's active spinner.
public struct FermixArcShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        return path
    }
}

/// The shipped menu-bar template image.
///
/// The status item and every preview of it draw the same approved monochrome
/// master, which macOS tints for the current menu-bar appearance because the
/// file is named `…Template`. `FermixBoltShape` is not an alternative to this:
/// the shape is for in-window chrome drawn at an arbitrary size in the accent,
/// which a tinted 16-point raster cannot be.
///
/// A missing master is a packaging defect, not a runtime condition, so it
/// traps rather than returning nil for a caller to quietly draw around.
public enum MenuBarGlyphImage {
    public static let resourceName = "FermixBoltTemplate"

    public static func template() -> NSImage {
        guard let image = Bundle.module.image(forResource: resourceName) else {
            preconditionFailure("Missing \(resourceName) in the application resource bundle")
        }

        image.isTemplate = true
        image.size = NSSize(width: MenuBarGlyphMetrics.glyphSize, height: MenuBarGlyphMetrics.glyphSize)

        return image
    }
}
