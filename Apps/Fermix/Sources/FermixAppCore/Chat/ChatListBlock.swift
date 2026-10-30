import SwiftUI

extension ChatMetrics {
    /// Between two items of a list, nested or not.
    static let listItemGap: Double = Spacing.xxs
    /// Between an item's mark and its words.
    static let listMarkGap: Double = Spacing.xs
    /// How far each depth of a nested list sits in from the one above it.
    static let listIndent: Double = Spacing.l
}

/// A list in a reply: each item's words drawn as a reply's paragraphs are
/// (`ChatProse`), hung beside a faint mark, so an item's later lines start
/// under its words rather than under its mark. A bullet is a dot, a hollow one once nested; a
/// number is the one CommonMark gives the item; and a task is a box, ticked
/// once done. Nothing else changes size or weight. Every mark takes the
/// width of the list's widest, so the words of its items start on one edge,
/// and a nested item sits a step in from the one it is nested in.
struct ChatListBlock: View {
    /// The list, its words as they were parsed.
    let list: ReplyList
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let titles: ChatLinkTitles
    let speaker: String?

    var body: some View {
        let widest = list.items.map(Self.label).max { $0.count < $1.count } ?? ""

        VStack(alignment: .leading, spacing: ChatMetrics.listItemGap) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: ChatMetrics.listMarkGap) {
                    ChatListMark(item: item, widest: widest)

                    ChatProse(paragraphs: [item.words], marked: marked, titles: titles, speaker: speaker)
                        .equatable()
                }
                .padding(.leading, Double(item.depth) * ChatMetrics.listIndent)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An item's mark as text: its number, or the dot at its depth, which a
    /// task's box stands in for where it is drawn.
    static func label(_ item: ReplyListItem) -> String {
        switch item.marker {
        case .number(let number): return String(format: ProductStrings[.chatListNumberFormat], number)
        case .bullet, .task: return ProductStrings[item.depth == 0 ? .chatListBullet : .chatListBulletNested]
        }
    }
}

/// An item's mark, faint, at the trailing edge of a column the width of the
/// list's widest mark, its digits all one width. A bullet is the system's
/// round dot: the reading face draws its own square.
private struct ChatListMark: View {
    let item: ReplyListItem
    let widest: String

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(widest)
                .hidden()
                .accessibilityHidden(true)

            mark
        }
        .monospacedDigit()
        .fermixType(ChatMetrics.readingType)
        .foregroundStyle(Palette.faint.color)
        .environment(\.typeFace, item.marker.isNumber ? .reading : .system)
    }

    @ViewBuilder
    private var mark: some View {
        switch item.marker {
        case .task(let done):
            Image(systemName: done ? "checkmark.square" : "square")
                .accessibilityLabel(ProductStrings[done ? .chatTaskDone : .chatTaskOpen])
        case .bullet, .number:
            Text(ChatListBlock.label(item))
        }
    }
}
