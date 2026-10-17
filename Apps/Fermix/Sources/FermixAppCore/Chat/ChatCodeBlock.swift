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
/// slim header names its language as written, where its fence named one;
/// under it the code, monospaced, selectable and never wrapped, a long line
/// scrolling sideways inside the block (`ChatPanelScroll`). The whole block
/// always shows, so its height is its lines' and changes only as a reply
/// still being written adds to them (M66 §3.8). Copy sits on the header's
/// line, and where there is no header it stands over the end of the first
/// line, on a fill of its own.
struct ChatCodeBlock: View {
    let code: ReplyCode
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]

    var body: some View {
        ChatPanel(label: label, copying: code.text) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if let language = code.language {
                    header(language)
                }

                ChatPanelScroll {
                    ChatCodeText(code: code, marked: marked)
                        .equatable()
                        .padding(.horizontal, ChatMetrics.codeInset)
                        .padding(.top, code.language == nil ? ChatMetrics.codeInset : 0)
                        .padding(.bottom, ChatMetrics.codeInset)
                }
            }
        }
    }

    /// The language as written, small and quiet; VoiceOver hears it in the
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

    /// The block's name for VoiceOver: code, and its language where it has one.
    private var label: String {
        let kind = ProductStrings[.chatCode]
        return code.language.map { ProductStrings.commaPair(kind, $0) } ?? kind
    }
}

/// A code block's lines, coloured (`ChatText.code`), selectable and never
/// wrapped. Its own view, compared by what it draws, so the pointer coming
/// and going over the block redraws its header and never colours the code
/// again.
private struct ChatCodeText: View, Equatable {
    let code: ReplyCode
    let marked: [String]

    var body: some View {
        Text(ChatText.code(code, marking: marked))
            .fermixType(ChatMetrics.codeType)
            .foregroundStyle(Palette.ink.color)
            .textSelection(.enabled)
            .fixedSize()
    }
}
