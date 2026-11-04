import SwiftUI

/// Which of the engine's commands a draft asks for, and the draft a chosen
/// command writes.
enum ChatCommandFilter {
    /// The commands a draft that is a slash and the start of one word asks
    /// for, nil for any other draft: one without a leading slash, or one past
    /// its first word, which is a command being given its arguments or words
    /// that happen to start with a slash. A name or an alias that starts with
    /// the word comes first, each in the engine's order, then one whose name,
    /// alias or description holds it.
    static func matches(_ commands: [CompanionCommand], draft: String) -> [CompanionCommand]? {
        guard draft.hasPrefix("/") else { return nil }

        let word = draft.dropFirst()
        guard !word.contains(where: \.isWhitespace) else { return nil }

        let term = word.lowercased()
        guard !term.isEmpty else { return commands }

        let leading = commands.filter { command in
            ([command.name] + command.aliases).contains { $0.lowercased().hasPrefix(term) }
        }
        let holding = commands.filter { command in
            !leading.contains(command)
                && ([command.name, command.description] + command.aliases).contains { $0.lowercased().contains(term) }
        }
        return leading + holding
    }

    /// The draft a chosen command writes: its slash and name, and the space
    /// its arguments follow.
    static func draft(for command: CompanionCommand) -> String {
        "/" + command.name + " "
    }
}

/// The engine's commands a draft asks for, over the composer: each its slash
/// and name over the engine's description of it, the chosen one marked, and
/// a click writes one into the draft. As tall as six commands, then it
/// scrolls, keeping the chosen one in view.
struct ChatCommandPalette: View {
    let commands: [CompanionCommand]
    /// The chosen command's place in the list.
    let choice: Int
    let pick: (CompanionCommand) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { place, command in
                        row(command, chosen: place == choice)
                            .id(command.id)
                    }
                }
                .padding(Spacing.xxs)
            }
            .frame(height: height)
            .onChange(of: choice) {
                guard commands.indices.contains(choice) else { return }

                reader.scrollTo(commands[choice].id)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.cardFill.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.hairline(.standard).color, lineWidth: Stroke.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProductStrings[.chatCommands])
    }

    private var height: Double {
        Double(min(commands.count, ChatMetrics.paletteVisibleRows)) * ChatMetrics.paletteRowHeight + 2 * Spacing.xxs
    }

    private func row(_ command: CompanionCommand, chosen: Bool) -> some View {
        Button {
            pick(command)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text("/" + command.name)
                    .fermixType(Typography.style(.body))
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.ink.color)
                Text(command.description)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.s)
            .frame(maxWidth: .infinity, minHeight: ChatMetrics.paletteRowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
                    .fill(chosen ? Palette.chipFill.color : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
