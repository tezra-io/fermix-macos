import SwiftUI

extension ChatMetrics {
    /// Outside text shows at most this many lines until Show all expands it
    /// in place (M60 §4.8).
    static let outsideLineCap = 12
    /// The room round outside text inside its inset.
    static let outsideInset: Double = Spacing.xs
    /// The inset's corners: a step inside the card's own.
    static let outsideRadius: Double = Radius.control
}

/// How a block of outside text is set: a call's arguments and what a tool
/// answered in the code face, an item's words in the reply's body face.
enum OutsideTextFace: Equatable {
    case code
    case item

    var style: TypeStyle {
        switch self {
        case .code: return ChatMetrics.codeType
        case .item: return Typography.style(.body)
        }
    }
}

/// Outside text as this app sets it: the characters exactly as written, one
/// plain run with no attribute on it. Nothing in it is parsed as markup,
/// turned into a link, or read for addresses, numbers or dates, so a link
/// written in it reads as the characters that spell it and nothing in it can
/// be clicked (M60 §5.1).
enum OutsideText {
    static func literal(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    /// An item's labelled fields on one line, joined as every status line
    /// joins two facts.
    static func facts(_ facts: [String]) -> String? {
        guard let first = facts.first else { return nil }

        return facts.dropFirst().reduce(first) { ProductStrings.middot($0, $1) }
    }
}

/// The one component that draws outside text (M60 §4.8): what a model or a
/// stranger wrote, under a header in Fermix's voice naming where it came
/// from, set plain in a quiet inset.
///
/// The text is selectable, so an owner can copy an issue title, and nothing
/// else: no link, no detector, no preview, no picture. Past twelve lines it is
/// cut with Show all, which expands it in place. VoiceOver reads it whole,
/// header first, whatever is shown: the owner decides on it.
///
/// It is used inside a proposal's card and nowhere else; no title, menu line,
/// notification or button label ever carries its text.
struct OutsideTextBlock: View {
    /// Fermix's words: where the text came from.
    let header: String
    /// The item's own fields, each labelled by Fermix, the values outside text.
    let facts: [String]
    let text: String
    let face: OutsideTextFace

    @State private var expanded = false
    /// The text's height as shown, and as it would be uncut: the difference
    /// is what Show all brings.
    @State private var shownHeight: Double = 0
    @State private var fullHeight: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(header)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.secondary.color)

                inset
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(header)
            .accessibilityValue(spoken)

            if !expanded, fullHeight > shownHeight + 1 {
                Button(ProductStrings[.outsideShowAll]) { expanded = true }
                    .buttonStyle(.link)
                    .fermixType(Typography.style(.caption))
                    // VoiceOver already reads the whole text.
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inset: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let line = OutsideText.facts(facts) {
                Text(OutsideText.literal(line))
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.secondary.color)
                    .textSelection(.enabled)
            }

            Text(OutsideText.literal(text))
                .fermixType(face.style)
                .foregroundStyle(Palette.ink.color)
                .lineLimit(expanded ? nil : ChatMetrics.outsideLineCap)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) { uncut }
        }
        .padding(ChatMetrics.outsideInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ChatMetrics.outsideRadius, style: .continuous)
                .fill(Palette.chipFill.color)
        )
    }

    /// The text at its whole height for the width it is shown at, never
    /// drawn: what tells the block whether its cap cut anything.
    private var uncut: some View {
        Text(OutsideText.literal(text))
            .fermixType(face.style)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { fullHeight = $0 }
    }

    /// What VoiceOver reads after the header: the fields, then the text,
    /// whole.
    private var spoken: String {
        [OutsideText.facts(facts), text].compactMap { $0 }.joined(separator: "\n")
    }
}
