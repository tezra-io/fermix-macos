import SwiftUI

/// A drop shadow, carrying both the artboard's CSS blur and the SwiftUI radius
/// it converts to. CSS blur is twice SwiftUI's radius; keeping both means a
/// reviewer can check the value against either document.
///
/// The two window recipes that used to live beside this went with the
/// assistant's glass card (owner decision 1): no window draws a container of
/// its own, so the primary button's own shadow is the only one left.
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
    /// The pointer-over fill. Pressed wins over hover, because the pointer is
    /// necessarily over the button while it is down.
    public static let primaryHoverFill = Palette.accentHover
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

    /// What an unavailable button is drawn at. A `ButtonStyle` is handed no
    /// disabled treatment, so without this both styles below draw a control
    /// that cannot be pressed exactly like one that can: Pet's `Mute
    /// microphone` looked live with no call running.
    public static let disabledOpacity: Double = 0.4

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
