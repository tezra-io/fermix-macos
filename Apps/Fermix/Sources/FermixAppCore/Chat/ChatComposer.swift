import AppKit
import SwiftUI

/// The composer: a capsule field that grows to a few lines, and one capsule
/// action at its trailing edge.
///
/// Return sends and Shift-Return starts a new line. The action is Send, the
/// surface's primary action and so its default button, until a turn is
/// running; then it is Cancel, which is never the default, so a Return typed
/// while a reply is coming cannot cancel it. Blank text is never sent: the
/// action is unavailable and Return does nothing.
///
/// Not connected, the whole composer is unavailable and the connection's own
/// sentence stands over it. A request made then would wait in the outbox, but
/// the owner could not see it go.
struct ChatComposer: View {
    @Binding var draft: String
    let connection: CompanionConnection
    let turn: CompanionTurn?
    let send: () -> Void
    let cancel: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let sentence = connection.sentence {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(alignment: .lastTextBaseline, spacing: Spacing.xs) {
                field
                action
            }
            .padding(ChatMetrics.composerInset)
            .background(shape.fill(Palette.chipFill.color))
            .overlay(shape.strokeBorder(Palette.hairline(.standard).color, lineWidth: Stroke.hairline))
            .disabled(connection != .connected)
        }
        .onAppear { focused = true }
        .onChange(of: connection) { _, now in
            guard now == .connected else { return }

            focused = true
        }
    }

    private var field: some View {
        TextField(ProductStrings[.chatComposerPrompt], text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(ChatMetrics.composerLines)
            .fermixType(Typography.style(.body))
            .focused($focused)
            .onKeyPress(.return, phases: .down, action: returnPressed)
    }

    /// Send and Cancel stand in one place and one is shown. Both stay in the
    /// layout, so the one that appears while the composer is still moving to
    /// the bottom edge moves with it instead of landing there first. The one
    /// not shown is unavailable, so Return never reaches a hidden Send.
    private var action: some View {
        ZStack {
            PrimaryAction(ProductStrings[.chatSend], size: .row, action: send)
                .disabled(turn != nil || isBlank)
                .shown(turn == nil)

            Button(ProductStrings[.chatCancel]) {
                guard let request = turn?.inReplyTo else { return }

                cancel(request)
            }
            .buttonStyle(SecondaryButtonStyle(.row))
            // A turn joined midway names no request, and a cancel names one.
            .disabled(turn?.inReplyTo == nil)
            .shown(turn != nil)
        }
    }

    /// Shift-Return is a line break where the caret is, which is what the
    /// field editor inserts for Option-Return; left to itself it would end
    /// editing. Return alone sends. The send button's own Return reaches it
    /// first while it can send, so this answers the Return it leaves: a blank
    /// draft, or a turn running.
    private func returnPressed(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.shift) else {
            if turn == nil, !isBlank { send() }
            return .handled
        }

        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
        return .handled
    }

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A capsule while the field is one line, the in-window control height,
    /// and the same corners once it grows.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HitTarget.button / 2, style: .continuous)
    }
}

private extension View {
    /// Drawn and reachable, or neither while keeping its place in the layout.
    func shown(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
