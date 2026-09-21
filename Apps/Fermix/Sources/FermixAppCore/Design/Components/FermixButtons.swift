import SwiftUI

/// The one primary action on a surface.
///
/// It is a view rather than a style because §9 requires the primary action to be
/// the default button, and a `ButtonStyle` cannot carry a keyboard shortcut. One
/// component means Return activates the primary action on every surface by
/// construction, instead of on the ones somebody remembered.
///
/// The one place it does not is the toolbar, and that is a caller's decision
/// rather than a second component: `isDefault` defaults to taking Return, so
/// giving it up has to be asked for.
public struct PrimaryAction: View {
    private let title: String
    private let size: ControlSize
    private let isDefault: Bool
    private let action: () -> Void

    @State private var isHovering = false

    /// - Parameter isDefault: whether Return takes it. True everywhere a surface
    ///   has one action to confirm; false in the toolbar, where the action
    ///   stands beside whatever the surface is doing and Return is not its.
    public init(_ title: String, size: ControlSize, isDefault: Bool = true, action: @escaping () -> Void) {
        precondition(!title.isEmpty, "a primary action needs a title")

        self.title = title
        self.size = size
        self.isDefault = isDefault
        self.action = action
    }

    /// The focus ring is the system's, here as everywhere else (redlines §9).
    /// The product suppresses it nowhere: a ring the app draws itself is one
    /// more thing that has to track every macOS change to focus, and a person
    /// who has turned the system ring up gets the app's instead.
    public var body: some View {
        Button(title, action: action)
            .buttonStyle(PrimaryButtonStyle(size, isHovering: isHovering))
            .keyboardShortcut(isDefault ? .defaultAction : nil)
            .onHover { isHovering = $0 }
    }
}

/// The primary button's drawing: the application icon's own monochrome, an
/// inverted label, and the only shadow a control carries.
///
/// Near-white on dark and near-black on light, which is how the product signs
/// itself everywhere else it is drawn. It was the accent, and the accent on the
/// ambient ground was one blue too many: the ground is a wash of `#2b5cff`, the
/// selection and the switches are `#2b5cff`, and a filled `#2b5cff` capsule on
/// top of all of it stopped reading as the one thing to do (owner, 2026-09-20:
/// the blue on `Continue setup` and on the failure page's buttons "doesnt match
/// with the theme"). Ink against a blue-cast ground is the higher contrast of
/// the two anyway: the label holds 16.5:1 on dark and 18:1 on light, where white
/// on the accent held 5.13:1.
///
/// The shadow goes neutral with the fill. A blue glow under a white capsule
/// would be the accent coming back through the back door.
///
/// Private to this file, because `PrimaryAction` is the component. That is also
/// why hover arrives as a parameter: a `ButtonStyle` cannot observe the pointer.
private struct PrimaryButtonStyle: ButtonStyle {
    private let size: ControlSize
    private let isHovering: Bool

    /// A style is not given the disabled state; it has to read it. Without
    /// this, `.disabled(true)` stops the action and changes nothing on screen.
    @Environment(\.isEnabled) private var isEnabled

    init(_ size: ControlSize, isHovering: Bool) {
        self.size = size
        self.isHovering = isHovering
    }

    func makeBody(configuration: Configuration) -> some View {
        let geometry = ButtonRecipe.primary(size)
        let shape = ButtonRecipe.shape
        let shadow = configuration.isPressed ? ButtonRecipe.primaryPressedShadow : ButtonRecipe.primaryShadow

        return configuration.label
            .fermixType(geometry.labelStyle)
            .foregroundStyle(ButtonRecipe.primaryLabel.color)
            .padding(.horizontal, geometry.horizontalPadding)
            .frame(minHeight: geometry.height)
            .background(shape.fill(fill(pressed: configuration.isPressed).color))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [ButtonRecipe.primaryInnerHighlight.color, .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.08)
                    ),
                    lineWidth: Stroke.hairline
                )
            )
            .clipShape(shape)
            .shadow(color: shadow.color.color, radius: shadow.radius, y: shadow.yOffset)
            .opacity(isEnabled ? 1 : ButtonRecipe.disabledOpacity)
            .accessibilityIdentifier(DesignComponent.primaryButton.accessibilityIdentifier)
    }

    /// Pressed wins over hover: the pointer is necessarily over the button
    /// while it is down.
    private func fill(pressed: Bool) -> ThemedColor {
        if pressed { return ButtonRecipe.primaryPressedFill }
        if isHovering { return ButtonRecipe.primaryHoverFill }

        return ButtonRecipe.primaryFill
    }
}

/// Everything else: a neutral fill, one hairline, and no shadow.
public struct SecondaryButtonStyle: ButtonStyle {
    private let size: ControlSize

    @Environment(\.colorSchemeContrast) private var contrast
    /// See `PrimaryButtonStyle`: the disabled state reaches a style only here.
    @Environment(\.isEnabled) private var isEnabled

    public init(_ size: ControlSize) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        let geometry = ButtonRecipe.secondary(size)
        let shape = ButtonRecipe.shape

        return configuration.label
            .fermixType(geometry.labelStyle)
            .foregroundStyle(ButtonRecipe.secondaryLabel.color)
            .padding(.horizontal, geometry.horizontalPadding)
            .frame(minHeight: geometry.height)
            .background(shape.fill((configuration.isPressed ? Palette.base300 : ButtonRecipe.secondaryFill).color))
            .overlay(
                shape.strokeBorder(
                    contrast == .increased
                        ? Palette.hairline(.standard, increaseContrast: true).color
                        : ButtonRecipe.secondaryBorder.color,
                    lineWidth: Stroke.hairline
                )
            )
            .clipShape(shape)
            .opacity(isEnabled ? 1 : ButtonRecipe.disabledOpacity)
            .accessibilityIdentifier(DesignComponent.secondaryButton.accessibilityIdentifier)
    }
}

extension View {
    /// Every action a form's rows draw, stated once on the form.
    ///
    /// The window's root tint reaches a system bordered button as its label
    /// colour, so every row action was the product blue on a dark translucent
    /// card: 3.47:1 against §9's 4.5:1 floor, and one more blue on a surface
    /// whose blue is meant to be the one action in the toolbar. A row's action
    /// is the secondary style at the row's own size instead: ink on a neutral
    /// capsule, legible in both appearances.
    ///
    /// On the form rather than on each button, so a row added later takes it
    /// without asking. Switches, pickers and the disclosure control are not
    /// buttons and are untouched; a button that states a style of its own
    /// keeps it.
    func rowActions() -> some View {
        buttonStyle(SecondaryButtonStyle(.row))
    }
}

/// A bare accent link: skip actions, card header links, and the Setup footer.
public struct LinkButton: View {
    private let title: String
    private let action: () -> Void

    @State private var isHovering = false

    public init(title: String, action: @escaping () -> Void) {
        precondition(!title.isEmpty, "a link needs a title")

        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .fermixType(Typography.style(.callout))
                .foregroundStyle(isHovering ? Palette.linkHover.color : Palette.accentText.color)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityIdentifier(DesignComponent.linkButton.accessibilityIdentifier)
    }
}
