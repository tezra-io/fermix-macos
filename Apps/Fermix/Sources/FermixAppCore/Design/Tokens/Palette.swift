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

/// The semantic palette, from `M34_DESIGN_SYSTEM_REDLINES.md` §§1.1–1.2 with
/// the palette v2 amendment.
///
/// `#2b5cff` is the only accent in the product, and §2 of the design spec is
/// explicit that a surface showing two blues that are not selection plus
/// primary action has a defect. Palette v2 amends the "chroma 0 neutrals"
/// doctrine in exactly one place: GROUND fills may carry a barely-cool cast
/// (blue-family, at most 3% chroma — the `#101014` family), because that cast
/// is what separates premium dark from flat black. TEXT neutrals stay
/// near-neutral.
public enum Palette {
    // MARK: - Neutrals

    /// Window and content ground. Opaque: the detail pane sits on this, not on
    /// glass.
    public static let base100 = ThemedColor(lightHex: "#f6f7f9", darkHex: "#101014")
    /// Recessed ground and the Reduce-Transparency fill.
    public static let base200 = ThemedColor(lightHex: "#eef0f3", darkHex: "#0b0b0e")
    /// Pressed and hover fills.
    public static let base300 = ThemedColor(lightHex: "#e3e5e9", darkHex: "#1e1e24")
    /// Primary text.
    public static let ink = ThemedColor(lightHex: "#16161a", darkHex: "#f4f5f7")
    /// Body and secondary text.
    public static let secondary = ThemedColor(lightHex: "#52565e", darkHex: "#a6abb4")
    /// Captions, timestamps, and hints. Never load-bearing text.
    public static let faint = ThemedColor(lightHex: "#7d8087", darkHex: "#75787f")

    // MARK: - The one blue

    public static let accent = ThemedColor(uniform: SRGBColor(hex: "#2b5cff"))
    public static let accentPressed = ThemedColor(uniform: SRGBColor(hex: "#1e46d6"))
    /// The primary button's hover fill.
    public static let accentHover = ThemedColor(uniform: SRGBColor(hex: "#4a73ff"))
    /// The keyboard focus ring: a 3-point outer stroke of the accent at 45%.
    public static let focusRing = ThemedColor(uniform: .rgba(43, 92, 255, 0.45))

    /// §1.1 gives this token a dark value only.
    public static let linkHoverDark = SRGBColor(hex: "#6b8dff")

    /// Link hover. On light there is no separate token, so the accent's
    /// pressed colour is used, which is what the table's empty light cell means.
    public static let linkHover = ThemedColor(light: accentPressed.light, dark: linkHoverDark)

    // MARK: - Status

    public static let success = ThemedColor(lightHex: "#1f7a4d", darkHex: "#4cc38a")
    public static let warning = ThemedColor(lightHex: "#9a6b1f", darkHex: "#e0b35c")
    public static let error = ThemedColor(lightHex: "#b3423a", darkHex: "#e5766c")
    /// Text inside a success pill, darker than the dot beside it.
    public static let successText = ThemedColor(lightHex: "#176641", darkHex: "#7fd6ac")
    /// The pass tone's text colour (`StatusTone.pass`).
    public static let pillPass = ThemedColor(lightHex: "#1f7a4d", darkHex: "#4cc38a")
    /// The warn tone's text colour (`StatusTone.warn`).
    public static let pillWarn = ThemedColor(lightHex: "#9a6b1f", darkHex: "#e0b35c")

    // MARK: - Alpha tokens

    /// A flat card. Opaque on purpose: an alpha card over an opaque ground has
    /// no elevation, which is why the 4.5% white card read as nothing.
    public static let cardFill = ThemedColor(lightHex: "#ffffff", darkHex: "#17171c")
    public static let chipFill = ThemedColor(
        light: .rgba(0, 0, 0, 0.04),
        dark: .rgba(255, 255, 255, 0.07)
    )
    /// The neutral avatar disc behind a provider or channel mark.
    public static let monoDisc = ThemedColor(
        light: .rgba(0, 0, 0, 0.06),
        dark: .rgba(255, 255, 255, 0.10)
    )
    public static let buttonFill = ThemedColor(
        light: .rgba(255, 255, 255, 1.0),
        dark: .rgba(255, 255, 255, 0.09)
    )
    public static let buttonBorder = ThemedColor(
        light: .rgba(0, 0, 0, 0.14),
        dark: .rgba(255, 255, 255, 0.18)
    )
    /// The selected sidebar row's fill.
    public static let navActive = ThemedColor(
        light: .rgba(43, 92, 255, 0.12),
        dark: .rgba(43, 92, 255, 0.20)
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
        light: .rgba(31, 122, 77, 0.08),
        dark: .rgba(76, 195, 138, 0.10)
    )
    public static let successPillBorder = ThemedColor(
        light: .rgba(31, 122, 77, 0.25),
        dark: .rgba(76, 195, 138, 0.28)
    )
    /// The soft halo behind Home's running dot.
    public static let successGlow = ThemedColor(
        light: .rgba(31, 122, 77, 0.16),
        dark: .rgba(76, 195, 138, 0.20)
    )

    public static let warnPillFill = ThemedColor(
        light: .rgba(154, 107, 31, 0.08),
        dark: .rgba(224, 179, 92, 0.10)
    )
    public static let warnIconFill = ThemedColor(
        light: .rgba(154, 107, 31, 0.14),
        dark: .rgba(224, 179, 92, 0.14)
    )
    public static let warnPillBorder = ThemedColor(
        light: .rgba(154, 107, 31, 0.25),
        dark: .rgba(224, 179, 92, 0.26)
    )

    public static let errorDiscFill = ThemedColor(
        light: .rgba(179, 66, 58, 0.08),
        dark: .rgba(229, 118, 108, 0.10)
    )
    public static let errorDiscBorder = ThemedColor(
        light: .rgba(179, 66, 58, 0.25),
        dark: .rgba(229, 118, 108, 0.28)
    )

    /// The accent at low alpha, behind the Telegram hero's own mark.
    public static let accentWash = ThemedColor(uniform: .rgba(43, 92, 255, 0.12))
    /// The one accent-tinted shadow in the product: the Telegram hero card.
    public static let heroGlow = ThemedColor(uniform: .rgba(43, 92, 255, 0.18))

    // The six activation-orb tokens of §5.2 are gone with the orb itself. The
    // Starting screen draws the mascot in its place (owner directive of
    // 2026-09-03: the orb "feels like slop"), and the mascot is authored
    // artwork, so it needs no colour from this table.

    // MARK: - Hairlines

    /// The three hairline weights, and the one place Increase Contrast changes
    /// a colour: §1.2 raises every hairline to 25% alpha and leaves fills alone.
    public static func hairline(_ weight: HairlineWeight, increaseContrast: Bool = false) -> ThemedColor {
        guard !increaseContrast else {
            return ThemedColor(light: .rgba(0, 0, 0, 0.25), dark: .rgba(255, 255, 255, 0.25))
        }

        switch weight {
        case .standard:
            return ThemedColor(light: .rgba(0, 0, 0, 0.10), dark: .rgba(255, 255, 255, 0.14))
        case .faint:
            return ThemedColor(light: .rgba(0, 0, 0, 0.06), dark: .rgba(255, 255, 255, 0.09))
        case .strong:
            return ThemedColor(light: .rgba(0, 0, 0, 0.16), dark: .rgba(255, 255, 255, 0.24))
        }
    }
}
