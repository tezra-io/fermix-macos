import CoreGraphics
import Foundation

/// The surfaces that sit on the desktop backdrop.
///
/// The gradient is shared; the blob count, size, and alpha differ per surface,
/// and only Welcome's blobs move.
public enum BackdropSurface: String, CaseIterable, Sendable {
    /// The first onboarding screen, the only surface with drifting blobs.
    case welcome
    /// Every other onboarding screen.
    case onboarding
    /// Home, Doctor, and hosted Setup.
    case window
    /// The recovery screen, deliberately quieter.
    case bootFailed
    /// Behind the menu-bar panel.
    case menuBar
}

/// One enormous blurred radial blob of the accent blue.
public struct BackdropBlob: Equatable, Sendable {
    public enum Anchor: String, Equatable, Sendable {
        case topLeading
        case bottomTrailing
    }

    public let diameter: Double
    public let anchor: Anchor
    /// The artboard's CSS inset from the anchored corner, verbatim. A negative
    /// value pushes the blob *outside* that corner: blob B is
    /// `right: -160px; bottom: -200px`, which bleeds down and to the right.
    public let offset: CGSize
    public let blurRadius: Double
    /// The radial stop at which the blob reaches full transparency.
    public let transparentStop: Double
    public let color: ThemedColor

    public init(
        diameter: Double,
        anchor: Anchor,
        offset: CGSize,
        blurRadius: Double,
        transparentStop: Double,
        color: ThemedColor
    ) {
        precondition(diameter > 0, "blob diameter must be positive")
        precondition(blurRadius > 0, "blob blur must be positive")
        precondition((0...1).contains(transparentStop), "transparent stop out of range")

        self.diameter = diameter
        self.anchor = anchor
        self.offset = offset
        self.blurRadius = blurRadius
        self.transparentStop = transparentStop
        self.color = color
    }

    /// The inset in SwiftUI's own sign convention.
    ///
    /// CSS measures `right` and `bottom` inward from the trailing and bottom
    /// edges, while SwiftUI's `offset` measures rightward and downward from
    /// wherever the alignment put the view. The two agree at the top-left
    /// corner and disagree at every other one, so the inset is resolved here
    /// rather than passed through: passing it through drew blob B as a disc
    /// floating inside the frame instead of a bloom bleeding off it.
    public var resolvedOffset: CGSize {
        switch anchor {
        case .topLeading:
            return offset
        case .bottomTrailing:
            return CGSize(width: -offset.width, height: -offset.height)
        }
    }
}

/// The desktop backdrop: a 160-degree near-neutral gradient plus one or two
/// blue blobs (`M34_DESIGN_SYSTEM_REDLINES.md` §1.3).
public enum Backdrop {
    public static let gradientAngleDegrees: Double = 160

    public static let gradient = ThemedGradient(
        start: ThemedColor(lightHex: "#f1f4f6", darkHex: "#070709"),
        end: ThemedColor(lightHex: "#fcfcfc", darkHex: "#020202")
    )

    /// Blobs drift only on Welcome. Everywhere else they are static, and
    /// Reduce Motion makes them static there too (`Motion` owns that).
    public static func drifts(_ surface: BackdropSurface) -> Bool {
        surface == .welcome
    }

    public static func blobs(_ surface: BackdropSurface) -> [BackdropBlob] {
        switch surface {
        case .welcome, .onboarding:
            return [
                primary(lightAlpha: 0.12, darkAlpha: 0.20),
                secondary(lightAlpha: 0.07, darkAlpha: 0.12)
            ]
        case .window:
            return [primary(lightAlpha: 0.10, darkAlpha: 0.16)]
        case .bootFailed:
            return [primary(lightAlpha: 0.09, darkAlpha: 0.14)]
        case .menuBar:
            return [primary(diameter: 480, lightAlpha: 0.10, darkAlpha: 0.16)]
        }
    }

    private static func primary(diameter: Double = 560, lightAlpha: Double, darkAlpha: Double) -> BackdropBlob {
        BackdropBlob(
            diameter: diameter,
            anchor: .topLeading,
            offset: CGSize(width: -140, height: -160),
            blurRadius: 70,
            transparentStop: 0.62,
            color: ThemedColor(
                light: .rgba(43, 92, 255, lightAlpha),
                dark: .rgba(43, 92, 255, darkAlpha)
            )
        )
    }

    private static func secondary(lightAlpha: Double, darkAlpha: Double) -> BackdropBlob {
        BackdropBlob(
            diameter: 640,
            anchor: .bottomTrailing,
            offset: CGSize(width: -160, height: -200),
            blurRadius: 80,
            transparentStop: 0.60,
            color: ThemedColor(
                light: .rgba(43, 92, 255, lightAlpha),
                dark: .rgba(90, 130, 255, darkAlpha)
            )
        )
    }
}
