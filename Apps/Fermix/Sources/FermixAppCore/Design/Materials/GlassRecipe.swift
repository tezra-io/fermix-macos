import SwiftUI

/// A drop shadow, carrying both the artboard's CSS blur and the SwiftUI radius
/// it converts to. CSS blur is twice SwiftUI's radius; keeping both means a
/// reviewer can check the value against either document.
public struct GlassShadow: Equatable, Sendable {
    public let cssBlur: Double
    public let yOffset: Double
    public let color: ThemedColor

    public init(cssBlur: Double, yOffset: Double, color: ThemedColor) {
        precondition(cssBlur > 0, "shadow blur must be positive")

        self.cssBlur = cssBlur
        self.yOffset = yOffset
        self.color = color
    }

    public var radius: Double { cssBlur / 2 }
}

/// The two glass recipes (`M34_DESIGN_SYSTEM_REDLINES.md` §4).
///
/// Glass is the window, never the content: cards inside a window are flat, and
/// the embedded Setup web surface is opaque on purpose.
public enum GlassRecipe: String, CaseIterable, Sendable {
    /// The onboarding window, Home, Doctor, and hosted Setup.
    case window
    /// The menu-bar panel.
    case popover

    public var cornerRadius: Double {
        switch self {
        case .window: return Radius.window
        case .popover: return Radius.popover
        }
    }

    /// The fill the artboards publish. On macOS 26 it rides as a tint over the
    /// system material; on macOS 15 it is the tint overlay above
    /// `.ultraThinMaterial`.
    public var tint: ThemedColor {
        switch self {
        case .window:
            return ThemedColor(light: .rgba(255, 255, 255, 0.66), dark: .rgba(26, 26, 29, 0.58))
        case .popover:
            return ThemedColor(light: .rgba(255, 255, 255, 0.72), dark: .rgba(26, 26, 29, 0.62))
        }
    }

    public var border: ThemedColor {
        Palette.hairline(.standard)
    }

    /// The one-point top edge highlight that makes glass read as a lit surface.
    public var innerHighlight: ThemedColor {
        switch self {
        case .window:
            return ThemedColor(light: .rgba(255, 255, 255, 0.75), dark: .rgba(255, 255, 255, 0.12))
        case .popover:
            return ThemedColor(light: .rgba(255, 255, 255, 0.80), dark: .rgba(255, 255, 255, 0.12))
        }
    }

    public var shadow: GlassShadow {
        switch self {
        case .window:
            return GlassShadow(
                cssBlur: 80,
                yOffset: 32,
                color: ThemedColor(light: .rgba(20, 24, 40, 0.16), dark: .rgba(0, 0, 0, 0.55))
            )
        case .popover:
            return GlassShadow(
                cssBlur: 60,
                yOffset: 22,
                color: ThemedColor(light: .rgba(20, 24, 40, 0.20), dark: .rgba(0, 0, 0, 0.60))
            )
        }
    }

    /// Recorded from the artboards. The OS material owns the actual blur on
    /// both supported paths; these are the numbers the design was drawn at.
    public var cssBlurRadius: Double { 30 }
    public var saturation: Double { 1.5 }
}

/// How much room a control has: an onboarding call to action or an in-window
/// button.
public enum ControlSize: String, CaseIterable, Sendable {
    case onboarding
    case inWindow
}

/// One button's geometry.
public struct ButtonGeometry: Equatable, Sendable {
    public let height: Double
    public let cornerRadius: Double
    public let horizontalPadding: Double
    public let labelStyle: TypeStyle
}

/// The primary and secondary button recipes (§4.4).
///
/// The primary button is the only control inside a window that carries a
/// shadow; depth 0 is the rule for everything else.
public enum ButtonRecipe {
    public static let primaryFill = Palette.accent
    public static let primaryPressedFill = Palette.accentPressed
    public static let primaryLabel = ThemedColor(uniform: SRGBColor(hex: "#ffffff"))
    public static let primaryInnerHighlight = SRGBColor.rgba(255, 255, 255, 0.25)

    public static let primaryShadow = GlassShadow(
        cssBlur: 18,
        yOffset: 6,
        color: ThemedColor(uniform: .rgba(43, 92, 255, 0.35))
    )
    public static let primaryPressedShadow = GlassShadow(
        cssBlur: 10,
        yOffset: 3,
        color: ThemedColor(uniform: .rgba(43, 92, 255, 0.35))
    )

    public static let secondaryFill = Palette.buttonFill
    public static let secondaryBorder = Palette.buttonBorder
    public static let secondaryLabel = Palette.ink

    public static func primary(_ size: ControlSize) -> ButtonGeometry {
        switch size {
        case .onboarding:
            return ButtonGeometry(
                height: HitTarget.onboardingCTA,
                cornerRadius: Radius.control,
                horizontalPadding: 28,
                labelStyle: Typography.style(.body).weight(.semibold)
            )
        case .inWindow:
            return ButtonGeometry(
                height: HitTarget.button,
                cornerRadius: 9,
                horizontalPadding: 14,
                labelStyle: Typography.style(.callout).weight(.semibold)
            )
        }
    }

    public static func secondary(_ size: ControlSize) -> ButtonGeometry {
        switch size {
        case .onboarding:
            return ButtonGeometry(
                height: HitTarget.onboardingCTA,
                cornerRadius: Radius.control,
                horizontalPadding: 22,
                labelStyle: Typography.style(.body).weight(.medium)
            )
        case .inWindow:
            return ButtonGeometry(
                height: HitTarget.button,
                cornerRadius: 9,
                horizontalPadding: 14,
                labelStyle: Typography.style(.callout).weight(.medium)
            )
        }
    }
}
