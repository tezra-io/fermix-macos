import SwiftUI

/// The one primary action on a surface.
///
/// It is a view rather than a style because §9 requires the primary action to be
/// the default button, and a `ButtonStyle` cannot carry a keyboard shortcut. One
/// component means Return activates the primary action on every surface by
/// construction, instead of on the ones somebody remembered.
public struct PrimaryAction: View {
    private let title: String
    private let size: ControlSize
    private let action: () -> Void

    @State private var isHovering = false

    public init(_ title: String, size: ControlSize, action: @escaping () -> Void) {
        precondition(!title.isEmpty, "a primary action needs a title")

        self.title = title
        self.size = size
        self.action = action
    }

    /// The focus ring is the system's, here as everywhere else (redlines §9).
    /// The product suppresses it nowhere: a ring the app draws itself is one
    /// more thing that has to track every macOS change to focus, and a person
    /// who has turned the system ring up gets the app's instead.
    public var body: some View {
        Button(title, action: action)
            .buttonStyle(PrimaryButtonStyle(size, isHovering: isHovering))
            .keyboardShortcut(.defaultAction)
            .onHover { isHovering = $0 }
    }
}

/// The primary button's drawing: accent fill, white label, and the only shadow
/// a control carries. Private to this file — `PrimaryAction` is the component,
/// which is also why hover arrives as a parameter: a `ButtonStyle` cannot
/// observe the pointer.
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
        let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
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
        let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)

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
                .foregroundStyle(isHovering ? Palette.linkHover.color : Palette.accent.color)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityIdentifier(DesignComponent.linkButton.accessibilityIdentifier)
    }
}
