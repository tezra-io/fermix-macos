import SwiftUI

/// One transcript item, drawn by what it is.
struct ChatItemView: View {
    let item: ChatItem
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let answer: (String, Bool) -> Void

    var body: some View {
        switch item {
        case .row(let row) where ChatSpeaker.isUser(row.role):
            ChatUserRow(text: ChatText.marking(marked, in: ChatText.plain(row.text)), sending: false)
        case .row(let row):
            ChatReplyRow(text: ChatText.marking(marked, in: ChatText.reply(row.text, home: NSHomeDirectory())), speaker: row.role)
        case .turn(let turn):
            ChatTurnRow(turn: turn)
        case .approval(let approval, let answering):
            ChatApprovalCard(approval: approval, answering: answering, answer: answer)
        case .pending(_, let text):
            ChatUserRow(text: ChatText.plain(text), sending: true)
        case .error(let sentence):
            ChatErrorRow(sentence: sentence)
        }
    }
}

/// What the owner wrote: on the trailing side, in a soft fill on the ground,
/// as they typed it. While the daemon has not accepted it, it says so under it.
private struct ChatUserRow: View {
    let text: AttributedString
    let sending: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            Text(text)
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)
                .padding(ChatMetrics.userChipPadding)
                .background(
                    RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
                        .fill(Palette.chipFill.color)
                )
                .opacity(sending ? ChatMetrics.sendingStrength : 1)

            if sending {
                Text(ProductStrings[.chatSending])
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.faint.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, ChatMetrics.userRowLeadingRoom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatSpeaker.name(role: ChatSpeaker.user))
        .accessibilityValue(sending ? ProductStrings.commaPair(String(text.characters), ProductStrings[.chatSending]) : String(text.characters))
    }
}

/// What Fermix wrote: on the leading side, straight on the ground, with no fill
/// of its own. A delivery, a row with no turn, is drawn the same way.
private struct ChatReplyRow: View {
    let text: AttributedString
    let speaker: String?

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.body))
            .foregroundStyle(Palette.ink.color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ChatSpeaker.name(role: speaker))
            .accessibilityValue(String(text.characters))
    }
}

/// The turn answering now: its text so far, and under it one quiet line for
/// whichever of thinking or the latest tool call applies (`ChatTurnStatus`).
private struct ChatTurnRow: View {
    let turn: CompanionTurn

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !turn.text.isEmpty {
                Text(ChatText.reply(turn.text, home: NSHomeDirectory()))
                    .fermixType(Typography.style(.body))
                    .foregroundStyle(Palette.ink.color)
            }

            switch ChatTurnStatus(turn) {
            case .thinking:
                ChatQuietLine(text: ProductStrings[.chatThinking], showsMark: true)
            case .tool(let tool):
                ChatQuietLine(text: ChatToolLine.sentence(tool), showsMark: tool.phase == .start)
            case .quiet:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One quiet line under a turn's draft: the activity mark while it is
/// running, beside the sentence that says what.
private struct ChatQuietLine: View {
    let text: String
    let showsMark: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if showsMark {
                ActivityMark().accessibilityHidden(true)
            }

            Text(text)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.faint.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// An approval the agent is waiting on: the daemon's own words and its two
/// answers. The token is never drawn; each answer sends the route the daemon
/// named for it. Once one is on its way both wait for the daemon to resolve
/// the card, so it is never answered twice.
private struct ChatApprovalCard: View {
    let approval: CompanionApproval
    let answering: Bool
    let answer: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(approval.text)
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.ink.color)

            if let detail = approval.detail {
                Text(detail)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .textSelection(.enabled)
            }

            HStack(spacing: Spacing.xs) {
                Button(ProductStrings[.chatApprove]) { answer(approval.approvalId, true) }
                Button(ProductStrings[.chatDeny]) { answer(approval.approvalId, false) }
            }
            .buttonStyle(SecondaryButtonStyle(.row))
            .disabled(answering)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.chipFill.color))
        .overlay(shape.strokeBorder(Palette.hairline(.standard).color, lineWidth: Stroke.hairline))
        .accessibilityElement(children: .contain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
    }
}

/// The latest failure, as one line in the sentence it arrived in.
private struct ChatErrorRow: View {
    let sentence: String

    var body: some View {
        Label(sentence, systemImage: "exclamationmark.circle")
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
