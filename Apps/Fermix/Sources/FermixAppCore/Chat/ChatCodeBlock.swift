import SwiftUI

extension ChatMetrics {
    /// A code block's code: the monospaced face a step under the reply's
    /// body, with room between its lines.
    static let codeType = TypeStyle(size: 13, leading: 20, weight: .regular, monospaced: true, relativeTo: .callout)
    /// A code block's corners: a card's.
    static let codeRadius: Double = Radius.card
    /// The room round a block's code inside its fill.
    static let codeInset: Double = Spacing.s
    /// The header's line and Copy's height: the system's small control
    /// height.
    static let codeHeaderHeight: Double = 20
    /// Where Copy sits in from the block's top and trailing edges, on the
    /// header's line.
    static let codeCopyInset: Double = Spacing.xs
    /// Between a reply's words and a code block, either side.
    static let codeBlockGap: Double = Spacing.s
    /// How long Copy says Copied.
    static let codeCopiedFor: Duration = .milliseconds(1500)
}

/// A fenced code block in a reply: its own block at the column's width, on
/// the chip's soft fill with a card's corners and no border. A slim header
/// names its language as written, where its fence named one; under it the
/// code, monospaced, selectable and never wrapped, a long line scrolling
/// sideways inside the block and fading at an end with more past it, as a
/// strip does. The whole block always shows, so its height is its lines' and
/// changes only as a reply still being written adds to them (M66 §3.8).
///
/// Copy sits in the top trailing corner, on the header's line, and shows
/// while the pointer is over the block or the keyboard is on it; VoiceOver
/// always finds it. Once pressed it says Copied for a moment. Where there is
/// no header it stands over the end of the first line, on a fill of its own.
struct ChatCodeBlock: View {
    let code: ReplyCode
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]

    @State private var hovering = false
    @State private var copied = false
    /// Which ends of the code have more past them, which fade.
    @State private var edges = ChatStripEdges(leading: false, trailing: false)
    @FocusState private var copyFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let language = code.language {
                header(language)
            }

            ScrollView(.horizontal) {
                ChatCodeText(code: code, marked: marked)
                    .equatable()
                    .padding(.horizontal, ChatMetrics.codeInset)
                    .padding(.top, code.language == nil ? ChatMetrics.codeInset : 0)
                    .padding(.bottom, ChatMetrics.codeInset)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: ChatStripEdges.self, of: { ChatStripEdges(ChatStripScroll($0)) }) { _, now in
                edges = now
            }
            .mask { ChatStripFade(edges: edges) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.chipFill.color))
        .overlay(alignment: .topTrailing) {
            copyButton
                .padding([.top, .trailing], ChatMetrics.codeCopyInset)
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .task(id: copied) {
            guard copied else { return }

            try? await Task.sleep(for: ChatMetrics.codeCopiedFor)
            if !Task.isCancelled { copied = false }
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

    private var copyButton: some View {
        let shown = hovering || copyFocused || copied

        return Button {
            ChatCodeCopy.app(code)
            copied = true
        } label: {
            Group {
                if copied {
                    Label(ProductStrings[.chatCodeCopied], systemImage: "checkmark")
                } else {
                    Image(systemName: "doc.on.doc")
                }
            }
            .fermixType(Typography.style(.caption))
            .foregroundStyle(Palette.secondary.color)
            .padding(.horizontal, Spacing.xs)
            .frame(minWidth: ChatMetrics.codeHeaderHeight, minHeight: ChatMetrics.codeHeaderHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.iconTileSmall, style: .continuous)
                    .fill(Palette.codeCopyFill.color)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($copyFocused)
        .help(ProductStrings[.chatCodeCopy])
        .accessibilityLabel(ProductStrings[copied ? .chatCodeCopied : .chatCodeCopy])
        .opacity(shown ? 1 : 0)
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: shown)
    }

    /// The block's name for VoiceOver: code, and its language where it has one.
    private var label: String {
        let kind = ProductStrings[.chatCode]
        return code.language.map { ProductStrings.commaPair(kind, $0) } ?? kind
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChatMetrics.codeRadius, style: .continuous)
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

/// What a code block's Copy does: puts the block's exact text on the
/// pasteboard through the app's one writer (`Clipboard`), and tells VoiceOver
/// it did.
struct ChatCodeCopy {
    let write: (String) -> Void
    let announcer: any AccessibilityAnnouncing

    /// The pasteboard and VoiceOver, as the app copies.
    static var app: ChatCodeCopy {
        ChatCodeCopy(write: Clipboard.write, announcer: AppKitAccessibilityAnnouncer())
    }

    func callAsFunction(_ code: ReplyCode) {
        write(code.text)
        announcer.announce(ProductStrings[.chatCodeCopied])
    }
}
