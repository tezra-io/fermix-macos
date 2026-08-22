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

    public init(_ title: String, size: ControlSize, action: @escaping () -> Void) {
        precondition(!title.isEmpty, "a primary action needs a title")

        self.title = title
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(PrimaryButtonStyle(size))
            .keyboardShortcut(.defaultAction)
    }
}

/// The primary button's drawing: accent fill, white label, and the only shadow
/// a control carries. Private to this file — `PrimaryAction` is the component.
private struct PrimaryButtonStyle: ButtonStyle {
    private let size: ControlSize

    init(_ size: ControlSize) {
        self.size = size
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
            .background(
                shape.fill(
                    (configuration.isPressed ? ButtonRecipe.primaryPressedFill : ButtonRecipe.primaryFill).color
                )
            )
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
            .accessibilityIdentifier(DesignComponent.primaryButton.accessibilityIdentifier)
    }
}

/// Everything else: a neutral fill, one hairline, and no shadow.
public struct SecondaryButtonStyle: ButtonStyle {
    private let size: ControlSize

    @Environment(\.colorSchemeContrast) private var contrast

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
