import SwiftUI

/// Which hairline a surface is drawing.
public enum HairlineWeight: String, CaseIterable, Sendable {
    /// Card and window borders.
    case standard
    /// Row separators.
    case faint
    /// Pending dots and dashed rows.
    case strong
}

/// The semantic palette, verbatim from `M34_DESIGN_SYSTEM_REDLINES.md` §§1.1–1.2.
///
/// Every neutral is chroma 0 and every status colour is deliberately
/// low-chroma; `#2b5cff` is the only accent in the product, and §2 of the
/// design spec is explicit that a surface showing two blues that are not
/// selection plus primary action has a defect.
public enum Palette {
    // MARK: - Neutrals

    /// Window and content ground.
    public static let base100 = ThemedColor(lightHex: "#fcfcfc", darkHex: "#020202")
    /// Recessed ground, the web surface, and the Reduce-Transparency fill.
    public static let base200 = ThemedColor(lightHex: "#f5f5f5", darkHex: "#060606")
    /// Pressed and hover fills.
    public static let base300 = ThemedColor(lightHex: "#e4e4e4", darkHex: "#1b1b1b")
    /// Primary text.
    public static let ink = ThemedColor(lightHex: "#161616", darkHex: "#f2f2f2")
    /// Body and secondary text.
    public static let secondary = ThemedColor(lightHex: "#555555", darkHex: "#9e9e9e")
    /// Captions, timestamps, and hints. Never load-bearing text.
    public static let faint = ThemedColor(lightHex: "#808080", darkHex: "#717171")

    // MARK: - The one blue

    public static let accent = ThemedColor(uniform: SRGBColor(hex: "#2b5cff"))
    public static let accentPressed = ThemedColor(uniform: SRGBColor(hex: "#1e46d6"))

    /// §1.1 gives this token a dark value only.
    public static let linkHoverDark = SRGBColor(hex: "#6b8dff")

    /// Link hover. On light there is no separate token, so the accent's
    /// pressed colour is used, which is what the table's empty light cell means.
    public static let linkHover = ThemedColor(light: accentPressed.light, dark: linkHoverDark)

    // MARK: - Status

    public static let success = ThemedColor(lightHex: "#618374", darkHex: "#8bae9e")
    public static let warning = ThemedColor(lightHex: "#9c815d", darkHex: "#ceb38d")
    public static let error = ThemedColor(lightHex: "#a05c57", darkHex: "#ca827c")
    /// Text inside a success pill, darker than the dot beside it.
    public static let successText = ThemedColor(lightHex: "#3d5d4f", darkHex: "#adc4b9")
    /// Doctor PASS letter-pill, text only.
    public static let pillPass = ThemedColor(lightHex: "#4b6c5d", darkHex: "#8bae9e")
    /// Doctor WARN letter-pill, text only.
    public static let pillWarn = ThemedColor(lightHex: "#866d49", darkHex: "#ceb38d")

    // MARK: - Alpha tokens

    /// A flat card inside glass.
    public static let cardFill = ThemedColor(
        light: .rgba(255, 255, 255, 0.60),
        dark: .rgba(255, 255, 255, 0.045)
    )
    public static let chipFill = ThemedColor(
        light: .rgba(255, 255, 255, 0.70),
        dark: .rgba(255, 255, 255, 0.06)
    )
    /// The neutral avatar disc behind a provider or channel mark.
    public static let monoDisc = ThemedColor(
        light: .rgba(0, 0, 0, 0.06),
        dark: .rgba(255, 255, 255, 0.10)
    )
    public static let buttonFill = ThemedColor(
        light: .rgba(255, 255, 255, 0.85),
        dark: .rgba(255, 255, 255, 0.08)
    )
    public static let buttonBorder = ThemedColor(
        light: .rgba(0, 0, 0, 0.12),
        dark: .rgba(255, 255, 255, 0.16)
    )
    /// The selected sidebar row's fill.
    public static let navActive = ThemedColor(
        light: .rgba(43, 92, 255, 0.10),
        dark: .rgba(43, 92, 255, 0.16)
    )
    /// The sweep across an active ladder row.
    public static let sheen = ThemedColor(
        light: .rgba(43, 92, 255, 0.05),
        dark: .rgba(255, 255, 255, 0.05)
    )
    /// A completed progress dot.
    public static let dotDone = ThemedColor(
        light: .rgba(43, 92, 255, 0.40),
        dark: .rgba(43, 92, 255, 0.45)
    )

    public static let successPillFill = ThemedColor(
        light: .rgba(40, 160, 110, 0.07),
        dark: .rgba(120, 220, 180, 0.08)
    )
    public static let successPillBorder = ThemedColor(
        light: .rgba(40, 160, 110, 0.22),
        dark: .rgba(120, 220, 180, 0.20)
    )
    /// The soft halo behind Home's running dot.
    public static let successGlow = ThemedColor(
        light: .rgba(40, 160, 110, 0.15),
        dark: .rgba(120, 220, 180, 0.18)
    )

    public static let warnPillFill = ThemedColor(
        light: .rgba(200, 150, 50, 0.06),
        dark: .rgba(235, 200, 120, 0.07)
    )
    public static let warnIconFill = ThemedColor(
        light: .rgba(200, 150, 50, 0.12),
        dark: .rgba(235, 200, 120, 0.12)
    )
    public static let warnPillBorder = ThemedColor(
        light: .rgba(200, 150, 50, 0.22),
        dark: .rgba(235, 200, 120, 0.20)
    )

    public static let errorDiscFill = ThemedColor(
        light: .rgba(200, 80, 60, 0.06),
        dark: .rgba(230, 130, 110, 0.08)
    )
    public static let errorDiscBorder = ThemedColor(
        light: .rgba(200, 80, 60, 0.20),
        dark: .rgba(230, 130, 110, 0.22)
    )

    /// The accent at low alpha, behind the Telegram hero's own mark.
    public static let accentWash = ThemedColor(uniform: .rgba(43, 92, 255, 0.12))
    /// The one accent-tinted shadow in the product: the Telegram hero card.
    public static let heroGlow = ThemedColor(uniform: .rgba(43, 92, 255, 0.18))

    // MARK: - The activation orb (§5.2)

    public static let orbHalo = ThemedColor(uniform: .rgba(43, 92, 255, 0.35))
    public static let orbHighlight = ThemedColor(
        light: .rgba(255, 255, 255, 0.95),
        dark: .rgba(255, 255, 255, 0.30)
    )
    public static let orbLow = ThemedColor(
        light: .rgba(235, 240, 255, 0.55),
        dark: .rgba(255, 255, 255, 0.04)
    )
    public static let orbRim = ThemedColor(
        light: .rgba(0, 0, 0, 0.06),
        dark: .rgba(255, 255, 255, 0.25)
    )
    public static let orbShadow = ThemedColor(uniform: .rgba(43, 92, 255, 0.30))
    public static let orbCoreGlow = ThemedColor(uniform: .rgba(43, 92, 255, 0.80))

    /// The embedded Setup web surface (§5.8). It is deliberately opaque rather
    /// than glass: crisp content inside glass chrome is the design statement,
    /// and a translucent web view would put the desktop behind the daemon's own
    /// page.
    public static let webBackground = ThemedColor(lightHex: "#fcfcfc", darkHex: "#060606")

    // MARK: - Hairlines

    /// The three hairline weights, and the one place Increase Contrast changes
    /// a colour: §1.2 raises every hairline to 25% alpha and leaves fills alone.
    public static func hairline(_ weight: HairlineWeight, increaseContrast: Bool = false) -> ThemedColor {
        guard !increaseContrast else {
            return ThemedColor(light: .rgba(0, 0, 0, 0.25), dark: .rgba(255, 255, 255, 0.25))
        }

        switch weight {
        case .standard:
            return ThemedColor(light: .rgba(0, 0, 0, 0.08), dark: .rgba(255, 255, 255, 0.10))
        case .faint:
            return ThemedColor(light: .rgba(0, 0, 0, 0.05), dark: .rgba(255, 255, 255, 0.06))
        case .strong:
            return ThemedColor(light: .rgba(0, 0, 0, 0.16), dark: .rgba(255, 255, 255, 0.20))
        }
    }
}
