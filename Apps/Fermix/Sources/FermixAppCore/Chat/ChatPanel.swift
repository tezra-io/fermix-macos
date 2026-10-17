import SwiftUI

/// A block of a reply on a soft panel of its own, a code block or a table:
/// its own block at the column's width, on the chip's soft fill with a
/// card's corners and no border.
///
/// Copy sits in the top trailing corner and shows while the pointer is over
/// the panel or the keyboard is on it; VoiceOver always finds it. Once
/// pressed it says Copied for a moment.
struct ChatPanel<Content: View>: View {
    /// The panel's name for VoiceOver.
    let label: String
    /// What Copy writes.
    let text: String
    let content: Content

    @State private var hovering = false

    init(label: String, copying text: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.text = text
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Palette.chipFill.color))
            .overlay(alignment: .topTrailing) {
                ChatPanelCopyButton(text: text, hovering: hovering)
                    .padding([.top, .trailing], ChatMetrics.codeCopyInset)
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChatMetrics.codeRadius, style: .continuous)
    }
}

/// What a panel draws sideways, never wrapped: past the panel's width it
/// scrolls inside it, fading at an end with more past it, as a strip does.
struct ChatPanelScroll<Content: View>: View {
    let content: Content

    /// Which ends have more past them, which fade.
    @State private var edges = ChatStripEdges(leading: false, trailing: false)

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal) {
            content
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onScrollGeometryChange(for: ChatStripEdges.self, of: { ChatStripEdges(ChatStripScroll($0)) }) { _, now in
            edges = now
        }
        .mask { ChatStripFade(edges: edges) }
    }
}

/// A panel's Copy: a quiet glyph on a fill of its own, opaque so the line
/// under it never shows through, which says Copied for a moment once pressed.
private struct ChatPanelCopyButton: View {
    let text: String
    /// Whether the pointer is over the panel.
    let hovering: Bool

    @State private var copied = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = hovering || focused || copied

        Button {
            ChatCopy.app(text)
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
        .focused($focused)
        .help(ProductStrings[.chatCodeCopy])
        .accessibilityLabel(ProductStrings[copied ? .chatCodeCopied : .chatCodeCopy])
        .opacity(shown ? 1 : 0)
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: shown)
        .task(id: copied) {
            guard copied else { return }

            try? await Task.sleep(for: ChatMetrics.codeCopiedFor)
            if !Task.isCancelled { copied = false }
        }
    }
}

/// What a panel's Copy does: puts its text on the pasteboard through the
/// app's one writer (`Clipboard`), a code block's exactly as written and a
/// table's as text with tabs, and tells VoiceOver it did.
struct ChatCopy {
    let write: (String) -> Void
    let announcer: any AccessibilityAnnouncing

    /// The pasteboard and VoiceOver, as the app copies.
    static var app: ChatCopy {
        ChatCopy(write: Clipboard.write, announcer: AppKitAccessibilityAnnouncer())
    }

    func callAsFunction(_ text: String) {
        write(text)
        announcer.announce(ProductStrings[.chatCodeCopied])
    }
}
