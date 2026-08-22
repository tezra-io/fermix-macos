import AppKit
import SwiftUI

/// Which of the two first-class appearances a token is being read in.
public enum FermixColorScheme: String, CaseIterable, Sendable {
    case light
    case dark
}

/// A token with a light and a dark value.
///
/// Light and dark are both first-class in this design, so a token is a pair,
/// never a base colour with a derived variant. `color` hands SwiftUI a dynamic
/// `NSColor` so the pair resolves with the system appearance rather than with
/// a value captured when the view was built.
public struct ThemedColor: Equatable, Sendable {
    public let light: SRGBColor
    public let dark: SRGBColor

    public init(light: SRGBColor, dark: SRGBColor) {
        self.light = light
        self.dark = dark
    }

    /// A token that is the same colour in both appearances, which in this
    /// palette is only the accent and its pressed state.
    public init(uniform: SRGBColor) {
        self.init(light: uniform, dark: uniform)
    }

    public init(lightHex: String, darkHex: String, alpha: Double = 1) {
        self.init(
            light: SRGBColor(hex: lightHex, alpha: alpha),
            dark: SRGBColor(hex: darkHex, alpha: alpha)
        )
    }

    public func resolved(for scheme: FermixColorScheme) -> SRGBColor {
        switch scheme {
        case .light: return light
        case .dark: return dark
        }
    }

    public func withAlpha(_ alpha: Double) -> ThemedColor {
        ThemedColor(light: light.withAlpha(alpha), dark: dark.withAlpha(alpha))
    }

    public var nsColor: NSColor {
        let light = light
        let dark = dark

        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
        }
    }

    public var color: Color {
        Color(nsColor: nsColor)
    }
}

/// A two-stop gradient token, used by the desktop backdrop.
public struct ThemedGradient: Equatable, Sendable {
    public let start: ThemedColor
    public let end: ThemedColor

    public init(start: ThemedColor, end: ThemedColor) {
        self.start = start
        self.end = end
    }
}
