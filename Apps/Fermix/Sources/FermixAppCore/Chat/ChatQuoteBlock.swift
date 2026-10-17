import SwiftUI

extension ChatMetrics {
    /// A quote's bar, and the room between it and the quote's words.
    static let quoteBarWidth: Double = 2
    static let quoteGap: Double = Spacing.s
}

/// A quote in a reply: its words in the reply's own face and ink, beside a
/// thin faint bar as tall as they are.
struct ChatQuoteBlock: View {
    /// The quote's words, drawn.
    let words: AttributedString

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: ChatMetrics.quoteGap) {
            Capsule()
                .fill(Palette.hairline(.strong, increaseContrast: contrast == .increased).color)
                .frame(width: ChatMetrics.quoteBarWidth)

            Text(words)
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProductStrings[.chatQuote])
        .accessibilityValue(String(words.characters))
    }
}
