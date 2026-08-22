import SwiftUI

/// One row of the main window's sidebar.
///
/// Selection is a fill plus an accent label plus the `.isSelected` trait, so a
/// screen reader and a colour-blind reader both get it.
public struct SidebarRow: View {
    private let item: SidebarItem
    private let isSelected: Bool
    private let action: () -> Void

    public init(item: SidebarItem, isSelected: Bool, action: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(foreground)
                    .frame(width: 17)

                Text(item.title)
                    .fermixType(Typography.style(.callout).weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(foreground)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
                    .fill(isSelected ? Palette.navActive.color : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(DesignComponent.sidebarRow.accessibilityIdentifier)
    }

    private var foreground: Color {
        isSelected ? Palette.accent.color : Palette.secondary.color
    }
}

/// One row of the menu-bar panel: a label, an optional trailing hint, and a
/// keyboard shortcut where the design gives one.
public struct MenuRow: View {
    private let title: String
    private let hint: String?
    private let shortcut: KeyEquivalent?
    private let action: () -> Void

    @State private var isHighlighted = false

    public init(
        title: String,
        hint: String? = nil,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) {
        precondition(!title.isEmpty, "a menu row needs a title")

        self.title = title
        self.hint = hint
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .fermixType(Typography.style(.callout))
                    .foregroundStyle(isHighlighted ? Color.white : Palette.ink.color)

                Spacer(minLength: Spacing.s)

                if let hint {
                    Text(hint)
                        .fermixType(Typography.style(.caption))
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.75) : Palette.faint.color)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: HitTarget.menuRow)
            .background(
                RoundedRectangle(cornerRadius: Radius.menuRow, style: .continuous)
                    .fill(isHighlighted ? Palette.accent.color : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.menuRow, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(OptionalShortcut(shortcut: shortcut))
        .onHover { isHighlighted = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(hint ?? "")
        .accessibilityIdentifier(DesignComponent.menuRow.accessibilityIdentifier)
    }
}

/// `keyboardShortcut` has no optional form, and building the row twice to get
/// one would duplicate the row.
private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyEquivalent?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            content
        }
    }
}
