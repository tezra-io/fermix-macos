import SwiftUI

extension ChatMetrics {
    /// A message's action: the system's regular control height, square, its
    /// glyph a small caption's size.
    static let actionSize: Double = HitTarget.rowAction
    static let actionGlyph: Double = 12
    /// Between a reply and the actions under it.
    static let actionsTopGap: Double = Spacing.xxs
    /// The actions' height under a reply, which the seam to the next turn
    /// takes its room from (`ChatTimeline.turnPadding`).
    static let actionsHeight: Double = actionSize + actionsTopGap
}

/// What a person can do with a finished message: copy its words, as they
/// were written, markdown and all, as a code block's Copy writes its code.
///
/// Under a reply with words its actions stand on the reply's leading side,
/// with when it was written beside them, and show while the pointer is over
/// the reply or the keyboard is on them; their room is kept whether they
/// show or not, so nothing moves. Beside a person's own message, Copy waits
/// in the room on its leading side (`ChatUserRow`).
enum ChatMessageActions {
    /// Whether a row carries a reply's actions under it: Fermix's, with words.
    static func carried(by row: CompanionRow) -> Bool {
        !ChatSpeaker.isUser(row.role) && !row.text.isEmpty
    }
}

/// A reply with its actions under it, shown while the pointer is over any of
/// it. A row that carries none is drawn as it is.
struct ChatReplyActionsRow: ViewModifier {
    let row: CompanionRow

    @State private var hovering = false

    func body(content: Content) -> some View {
        if ChatMessageActions.carried(by: row) {
            VStack(alignment: .leading, spacing: ChatMetrics.actionsTopGap) {
                content

                HStack(spacing: Spacing.xxs) {
                    ChatCopyAction(text: row.text, shown: hovering)

                    if let time = row.timestamp {
                        Text(ChatTime.said(time))
                            .fermixType(Typography.style(.caption))
                            .foregroundStyle(Palette.faint.color)
                            .opacity(hovering ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: ChatMetrics.actionSize)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        } else {
            content
        }
    }
}

/// Copy, as a quiet glyph that says Copied for a moment once pressed. It
/// shows while the pointer is over its message, the keyboard is on it, or it
/// has just copied; VoiceOver always finds it.
struct ChatCopyAction: View {
    /// What it writes.
    let text: String
    /// Whether the pointer is over its message.
    let shown: Bool

    @State private var copied = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = shown || focused || copied

        Button {
            ChatCopy.app(text)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: ChatMetrics.actionGlyph))
                .frame(width: ChatMetrics.actionSize, height: ChatMetrics.actionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChatActionButtonStyle())
        .focused($focused)
        .help(ProductStrings[.chatMessageCopy])
        .accessibilityLabel(ProductStrings[copied ? .chatCodeCopied : .chatMessageCopy])
        .opacity(visible ? 1 : 0)
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: visible)
        .task(id: copied) {
            guard copied else { return }

            try? await Task.sleep(for: ChatMetrics.codeCopiedFor)
            if !Task.isCancelled { copied = false }
        }
    }
}

/// A message's action: its glyph in the secondary tone, in the ink on a
/// soft fill under the pointer, and fainter while pressed.
private struct ChatActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatActionFace(configuration: configuration)
    }
}

private struct ChatActionFace: View {
    let configuration: ButtonStyleConfiguration

    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Palette.ink.color : Palette.secondary.color)
            .background(
                RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
                    .fill(hovering ? Palette.chipFill.color : .clear)
            )
            .opacity(configuration.isPressed ? ChatMetrics.tilePressedStrength : 1)
            .onHover { hovering = $0 }
    }
}
