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

/// How much room a control has: an onboarding call to action, an in-window
/// button, or the action at the trailing edge of a form row.
public enum ControlSize: String, CaseIterable, Sendable {
    case onboarding
    case inWindow
    /// A grouped-form row is a line of text, so its action is the height of a
    /// system row control rather than the 36 points a free-standing button
    /// takes: taller, and the button sets the row's height instead of sitting
    /// inside it.
    case row
}

/// One button's geometry. The shape is not here: every button is the one
/// capsule `ButtonRecipe.shape` names, whatever its size.
public struct ButtonGeometry: Equatable, Sendable {
    public let height: Double
    public let horizontalPadding: Double
    public let labelStyle: TypeStyle
}

/// The primary and secondary button recipes (§4.4).
///
/// The primary button is the only control inside a window that carries a
/// shadow; depth 0 is the rule for everything else.
public enum ButtonRecipe {
    /// Every button the app draws is a capsule, which is the shape the system
    /// gives its own toolbar buttons and, through the window root's border
    /// shape, every bordered button beside them. Radius 10 and 9 were the
    /// artboards' rounded rectangles, and beside system capsules they read as
    /// controls from another app.
    public static let shape = Capsule(style: .continuous)

    public static let primaryFill = Palette.ink
    /// The pointer-over fill. Pressed wins over hover, because the pointer is
    /// necessarily over the button while it is down.
    public static let primaryHoverFill = ThemedColor(lightHex: "#2c2c33", darkHex: "#ffffff")
    public static let primaryPressedFill = ThemedColor(lightHex: "#000000", darkHex: "#d5d8de")
    public static let primaryLabel = ThemedColor(lightHex: "#ffffff", darkHex: "#16161a")
    public static let primaryInnerHighlight = SRGBColor.rgba(255, 255, 255, 0.25)

    public static let primaryShadow = GlassShadow(
        cssBlur: 18,
        yOffset: 6,
        color: ThemedColor(uniform: .rgba(0, 0, 0, 0.28))
    )
    public static let primaryPressedShadow = GlassShadow(
        cssBlur: 10,
        yOffset: 3,
        color: ThemedColor(uniform: .rgba(0, 0, 0, 0.28))
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
                horizontalPadding: 28,
                labelStyle: Typography.style(.body).weight(.semibold)
            )
        case .inWindow:
            return ButtonGeometry(
                height: HitTarget.button,
                horizontalPadding: 14,
                labelStyle: Typography.style(.callout).weight(.semibold)
            )
        case .row:
            return ButtonGeometry(
                height: HitTarget.rowAction,
                horizontalPadding: 12,
                labelStyle: Typography.style(.callout).weight(.semibold)
            )
        }
    }

    public static func secondary(_ size: ControlSize) -> ButtonGeometry {
        switch size {
        case .onboarding:
            return ButtonGeometry(
                height: HitTarget.onboardingCTA,
                horizontalPadding: 22,
                labelStyle: Typography.style(.body).weight(.medium)
            )
        case .inWindow:
            return ButtonGeometry(
                height: HitTarget.button,
                horizontalPadding: 14,
                labelStyle: Typography.style(.callout).weight(.medium)
            )
        case .row:
            return ButtonGeometry(
                height: HitTarget.rowAction,
                horizontalPadding: 12,
                labelStyle: Typography.style(.callout).weight(.medium)
            )
        }
    }
}
