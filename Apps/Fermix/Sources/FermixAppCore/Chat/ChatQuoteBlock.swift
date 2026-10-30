import SwiftUI

extension ChatMetrics {
    /// A quote's bar, and the room between it and the quote's words.
    static let quoteBarWidth: Double = 2
    static let quoteGap: Double = Spacing.s
}

/// A quote in a reply: its words drawn as a reply's paragraphs are
/// (`ChatProse`), beside a thin faint bar as tall as they are.
struct ChatQuoteBlock: View {
    /// The quote's words as they were parsed.
    let words: AttributedString
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let titles: ChatLinkTitles
    let speaker: String?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: ChatMetrics.quoteGap) {
            Capsule()
                .fill(Palette.hairline(.strong, increaseContrast: contrast == .increased).color)
                .frame(width: ChatMetrics.quoteBarWidth)

            ChatProse(paragraphs: [words], marked: marked, titles: titles, speaker: speaker)
                .equatable()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProductStrings[.chatQuote])
        .accessibilityValue(String(words.characters))
    }
}
