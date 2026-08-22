import SwiftUI

/// A flat card: fill plus one hairline, no shadow.
///
/// Depth 0 inside a surface is the design's second commitment. Shadows belong
/// to windows, popovers, the primary button, and the orb.
public struct Card<Content: View>: View {
    private let content: Content

    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)

        return content
            .background(shape.fill(Palette.cardFill.color))
            .overlay(
                shape.strokeBorder(
                    Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                    lineWidth: Stroke.hairline
                )
            )
            .clipShape(shape)
            .accessibilityIdentifier(DesignComponent.card.accessibilityIdentifier)
    }
}

/// A card with the artboards' section header: an uppercase caption and an
/// optional trailing accent link.
public struct SectionCard<Content: View>: View {
    private let label: String
    private let linkTitle: String?
    private let linkAction: (() -> Void)?
    private let content: Content

    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        label: String,
        linkTitle: String? = nil,
        linkAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        precondition(!label.isEmpty, "a section card needs a label")
        precondition((linkTitle == nil) == (linkAction == nil), "a section link needs both a title and an action")

        self.label = label
        self.linkTitle = linkTitle
        self.linkAction = linkAction
        self.content = content()
    }

    public var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
                content
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Text(label)
                .fermixType(Typography.sectionLabelLarge)
                .foregroundStyle(Palette.faint.color)

            Spacer(minLength: Spacing.s)

            if let linkTitle, let linkAction {
                LinkButton(title: linkTitle, action: linkAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A small capsule of neutral fact: the provider and channel chips on Home,
/// and the mirror chip in Activate's titlebar.
public struct Chip: View {
    private let title: String
    private let leading: Image?

    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ title: String, leading: Image? = nil) {
        precondition(!title.isEmpty, "a chip needs a title")

        self.title = title
        self.leading = leading
    }

    public var body: some View {
        HStack(spacing: Spacing.xxs + 2) {
            if let leading {
                leading
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent.color)
                    .accessibilityHidden(true)
            }

            Text(title)
                .fermixType(Typography.style(.calloutSmall).weight(.medium))
                .foregroundStyle(Palette.secondary.color)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(Palette.chipFill.color))
        .overlay(
            Capsule().strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier(DesignComponent.chip.accessibilityIdentifier)
    }
}
