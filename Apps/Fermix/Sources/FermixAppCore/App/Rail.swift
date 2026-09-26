import AppKit
import SwiftUI

/// The rail's geometry at each of the reader's sidebar sizes (redlines §5.7).
///
/// The rail is a column of symbol buttons rather than a sidebar `List`,
/// because a list draws its selection across the whole row and cannot leave
/// space between rows on macOS: the selections of neighbouring rows touched,
/// and every way of adding air made the selection a tall bar again (owner,
/// 2026-09-25, of the Codex rail: "I feel codex has a more space ... follow the
/// best design"). The square is the system's own sidebar row at the reader's
/// sidebar icon size (small 24, medium 32, large 40 on macOS 26), and the gap
/// is a quarter of it, the proportion the Codex rail keeps (a 28 point square
/// seven points apart).
enum RailMetrics {
    static func square(_ size: SidebarRowSize) -> Double {
        switch size {
        case .small: return 24
        case .medium: return 32
        case .large: return 40
        @unknown default: return 32
        }
    }

    static func gap(_ size: SidebarRowSize) -> Double {
        square(size) / 4
    }

    /// The symbol's point size: fifteen in a 32 point square, which draws the
    /// glyphs at the height the system sidebar drew them.
    static func symbol(_ size: SidebarRowSize) -> Double {
        (square(size) * 15 / 32).rounded()
    }

    static func cornerRadius(_ size: SidebarRowSize) -> Double {
        square(size) / 4
    }

    /// What the first square keeps clear of the band above it.
    static let topInset: Double = 8
}

/// The rail: the four surfaces, then Settings pinned to the foot.
///
/// Each destination is a button, so VoiceOver reads its name and whether it
/// is the one showing, full keyboard access reaches every one in order, and a
/// pointer gets the name as its help tag. Choosing one hands its identifier to
/// `select`, the same one path the list's selection took.
///
/// What the list gave for free is kept by hand: with a destination focused,
/// the up and down arrows move the focus and the choice together through the
/// five in order, as arrow keys walked the list's rows (redlines §5.7).
struct RailColumn: View {
    let items: [SidebarItem]
    let selected: String?
    let select: (String) -> Void

    @Environment(\.sidebarRowSize) private var rowSize
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: RailMetrics.gap(rowSize)) {
            ForEach(items) { item in
                RailButton(title: item.title, systemImage: item.systemImage, selected: item.id == selected) {
                    select(item.id)
                }
                .focused($focused, equals: item.id)
            }

            Spacer(minLength: 0)

            RailButton(
                title: ProductStrings[.sidebarSettings],
                systemImage: "gearshape",
                selected: selected == SidebarItem.settingsIdentifier
            ) {
                select(SidebarItem.settingsIdentifier)
            }
            .focused($focused, equals: SidebarItem.settingsIdentifier)
        }
        .padding(.top, RailMetrics.topInset)
        // As far off the bottom edge as the first square is off the band.
        .padding(.bottom, WindowMetrics.railBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onMoveCommand(perform: move)
    }

    /// The five destinations in keyboard order: the four, then Settings.
    private var order: [String] {
        items.map(\.id) + [SidebarItem.settingsIdentifier]
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let focused, let index = order.firstIndex(of: focused) else { return }

        let next: Int
        switch direction {
        case .up: next = index - 1
        case .down: next = index + 1
        default: return
        }
        guard order.indices.contains(next) else { return }

        self.focused = order[next]
        select(order[next])
    }
}

/// One rail destination: its symbol in a square, filled while it is showing.
///
/// The selection is the system's own unemphasized selection colour, the one a
/// sidebar row showed, and the symbol takes its filled form, as the Codex rail
/// does, so the destination that is showing reads at a glance.
private struct RailButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.sidebarRowSize) private var rowSize
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .symbolVariant(selected ? .fill : .none)
                .font(.system(size: RailMetrics.symbol(rowSize)))
                .foregroundStyle(.primary)
                .frame(width: RailMetrics.square(rowSize), height: RailMetrics.square(rowSize))
                .background(fill, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RailMetrics.cornerRadius(rowSize), style: .continuous)
    }

    private var fill: Color {
        if selected { return Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
        if hovering { return Color(nsColor: .quinaryLabel) }

        return .clear
    }
}
