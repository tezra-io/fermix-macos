import SwiftUI

extension ChatMetrics {
    /// A code block's code: the monospaced face a step under the reply's
    /// body, with room between its lines.
    static let codeType = TypeStyle(size: 13, leading: 20, weight: .regular, monospaced: true, relativeTo: .callout)
    /// A code block's corners, and every panel's (`ChatPanel`): a card's.
    static let codeRadius: Double = Radius.card
    /// The room round a block's code inside its fill, and round a table's
    /// cells inside theirs.
    static let codeInset: Double = Spacing.s
    /// The header's line and Copy's height: the system's small control
    /// height.
    static let codeHeaderHeight: Double = 20
    /// Where a panel's Copy sits in from its top and trailing edges, on a
    /// code block's header's line.
    static let codeCopyInset: Double = Spacing.xs
    /// Between a reply's words and a code block, either side, and between
    /// any two of its blocks but paragraphs.
    static let codeBlockGap: Double = Spacing.s
    /// How long Copy says Copied.
    static let codeCopiedFor: Duration = .milliseconds(1500)
}

/// A fenced code block in a reply, on its own soft panel (`ChatPanel`). A
/// slim header names its language, where its fence named one: by the
/// language's own name where the tag is one `CodeLanguage` knows (`py` is
/// Python), and as written where it is not. Under it the code, monospaced
/// and selectable, a long line wrapping at the panel's edge so a one-liner
/// shows whole. The whole block always shows, so its height is its lines'
/// at the panel's width and changes only as a reply still being written
/// adds to them (M66 §3.8). Copy sits on the header's line, and where there
/// is no header it stands over the end of the first line, on a fill of its
/// own.
struct ChatCodeBlock: View {
    let code: ReplyCode
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]

    var body: some View {
        ChatPanel(label: Self.label(of: code), copying: code.text) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if let language = code.language {
                    header(CodeLanguage.name(of: language))
                }

                ChatCodeText(code: code, marked: marked)
                    .equatable()
                    .padding(.horizontal, ChatMetrics.codeInset)
                    .padding(.top, code.language == nil ? ChatMetrics.codeInset : 0)
                    .padding(.bottom, ChatMetrics.codeInset)
            }
        }
    }

    /// The language's name, small and quiet; VoiceOver hears it in the
    /// block's own name instead.
    private func header(_ language: String) -> some View {
        Text(language)
            .fermixType(Typography.style(.caption))
            .foregroundStyle(Palette.secondary.color)
            .lineLimit(1)
            .frame(height: ChatMetrics.codeHeaderHeight)
            .padding(.horizontal, ChatMetrics.codeInset)
            .padding(.top, ChatMetrics.codeCopyInset)
            .accessibilityHidden(true)
    }

    /// The block's name for VoiceOver: code, and its language by the name
    /// its header shows, where it has one.
    static func label(of code: ReplyCode) -> String {
        let kind = ProductStrings[.chatCode]
        return code.language.map { ProductStrings.commaPair(kind, CodeLanguage.name(of: $0)) } ?? kind
    }
}

/// A code block's lines, coloured (`ChatText.code`), selectable, and wrapped
/// at the panel's width: as wide as the panel gives it and as tall as its
/// lines wrap to there. Its own view, compared by what it draws, so the
/// pointer coming and going over the block redraws its header and never
/// colours the code again.
private struct ChatCodeText: View, Equatable {
    let code: ReplyCode
    let marked: [String]

    var body: some View {
        Text(ChatText.code(code, marking: marked))
            .fermixType(ChatMetrics.codeType)
            .foregroundStyle(Palette.ink.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
