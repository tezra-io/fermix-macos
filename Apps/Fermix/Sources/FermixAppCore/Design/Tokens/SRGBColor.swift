import AppKit
import SwiftUI

/// One sRGB colour, stored as the exact channel values the M33 redlines publish.
///
/// The redline tables are written in hex and in `rgba()`, so the tokens are
/// declared the same way and a reviewer can diff a declaration against the
/// table without doing arithmetic. Neutrals are authored in oklch upstream and
/// published here already converted; `#2b5cff` is authored as hex and is never
/// round-tripped.
public struct SRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        precondition((0...1).contains(red), "red out of range: \(red)")
        precondition((0...1).contains(green), "green out of range: \(green)")
        precondition((0...1).contains(blue), "blue out of range: \(blue)")
        precondition((0...1).contains(alpha), "alpha out of range: \(alpha)")

        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#rrggbb`, the form §1.1 publishes. A malformed literal is a source
    /// defect, so it traps rather than resolving to some other colour.
    public init(hex: String, alpha: Double = 1) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        precondition(digits.count == 6, "hex must be six digits: \(hex)")
        guard let value = UInt32(digits, radix: 16) else {
            preconditionFailure("hex is not hexadecimal: \(hex)")
        }

        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            alpha: alpha
        )
    }

    /// `rgba(r, g, b, a)` with 0-255 channels, the form §1.2 publishes. The
    /// alpha tokens are used verbatim and never converted to hex.
    public static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double) -> SRGBColor {
        precondition((0...255).contains(red), "red out of range: \(red)")
        precondition((0...255).contains(green), "green out of range: \(green)")
        precondition((0...255).contains(blue), "blue out of range: \(blue)")

        return SRGBColor(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: alpha
        )
    }

    /// The channels as `#rrggbb`, so a token can be compared against the
    /// redline table it came from. Alpha is deliberately not encoded.
    public var hexString: String {
        let channels = [red, green, blue].map { UInt8((($0 * 255).rounded())) }

        return "#" + channels.map { String(format: "%02x", $0) }.joined()
    }

    public func withAlpha(_ alpha: Double) -> SRGBColor {
        SRGBColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var color: Color {
        Color(nsColor: nsColor)
    }
}
