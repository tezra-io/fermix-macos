import SwiftUI

/// What every row of the transcript reads from the chat surface, which sets
/// it once in the environment: the transcript builds each row with nothing
/// of its own to hand it (M66).
struct ChatRowContext: Equatable, Sendable {
    /// What a row's media needs that outlives the surface.
    let media: ChatMedia
    /// The app's one player, which a sound in a row plays on (M66 §3.4).
    let player: AppPlayer
    /// The one content link opener, which a phone-side file's tile opens
    /// through, as a link opens through `openURL` (M66 §3.5).
    let links: ContentLinkOpener
    /// The Fermix home as this visit to Chat read it, nil until the surface
    /// has read it.
    let visit: ChatVisit?
    /// The reading column's width, which a strip fits its tiles to.
    let columnWidth: Double

    /// The media, the player and the opener are each one object for the
    /// app's life, so two contexts are the same when they, the visit and the
    /// column are: a keystroke that redraws the surface must not redraw every
    /// row.
    static func == (lhs: ChatRowContext, rhs: ChatRowContext) -> Bool {
        lhs.media === rhs.media && lhs.player === rhs.player && lhs.links === rhs.links
            && lhs.visit == rhs.visit && lhs.columnWidth == rhs.columnWidth
    }
}

extension EnvironmentValues {
    /// What the chat surface hands its rows. Absent where no chat surface
    /// hosts a row, which is to say in tests, and a finished row or a turn
    /// then draws nothing.
    var chatRows: ChatRowContext? {
        get { self[ChatRowContextKey.self] }
        set { self[ChatRowContextKey.self] = newValue }
    }
}

private struct ChatRowContextKey: EnvironmentKey {
    static let defaultValue: ChatRowContext? = nil
}

/// One transcript item, drawn by what it is.
struct ChatItemView: View {
    let item: ChatItem
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let answer: (String, Bool) -> Void

    var body: some View {
        switch item {
        case .row(let row):
            ChatRow(row: row, marked: marked)
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

/// A finished row, on its side: its words, or its voice note with its words
/// as the transcript; under them the sound files it names in the Fermix home;
/// the note and each sound playable where it is (M66 §3.4); and then its
/// strip (§3.1). Its words are the strip's text, without the lines that only
/// name what the strip and the players show. A row with no other words, a
/// picture Fermix sent to the phone or a reply that only lists what it made,
/// draws its strip alone. A turn still being written is no row yet, so
/// nothing here looks at the disk while a reply streams.
private struct ChatRow: View {
    let row: CompanionRow
    let marked: [String]

    @Environment(\.chatRows) private var rows

    var body: some View {
        if let rows {
            drawn(rows.media.strip(for: row, in: rows.visit), in: rows)
        }
    }

    private func drawn(_ strip: ChatStrip, in rows: ChatRowContext) -> some View {
        let user = ChatSpeaker.isUser(row.role)

        return VStack(alignment: user ? .trailing : .leading, spacing: ChatMetrics.stripTopGap) {
            if let note = strip.voiceNote {
                ChatVoiceNote(note: note, transcript: words(strip), speaker: row.role, player: rows.player)
            } else if !strip.text.isEmpty {
                if user {
                    ChatUserRow(text: words(strip), sending: false)
                } else if let reply = strip.reply {
                    ChatReplyRow(blocks: ChatText.drawn(reply), marked: marked, speaker: row.role)
                }
            }

            ForEach(strip.sounds, id: \.self) { sound in
                ChatSoundRow(url: sound, name: sound.lastPathComponent, player: rows.player)
            }

            if !strip.items.isEmpty {
                ChatStripView(
                    strip: strip,
                    trailing: user,
                    width: rows.columnWidth - (user ? ChatMetrics.userRowLeadingRoom : 0)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }

    /// The words as one text, as the strip read them: Fermix's drawn with
    /// their links and code, a person's as they typed them, and either marked
    /// where a search sent the reader.
    private func words(_ strip: ChatStrip) -> AttributedString {
        let text = strip.reply.map { ChatText.oneText(ChatText.drawn($0)) } ?? ChatText.plain(strip.text)
        return ChatText.marking(marked, in: text)
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

/// What Fermix wrote: on the leading side, its words straight on the ground
/// with no fill of its own, and each code block in its own between them
/// (`ChatCodeBlock`). A delivery, a row with no turn, and the turn still being
/// written are drawn the same way.
private struct ChatReplyRow: View {
    let blocks: [ReplyBlock]
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let speaker: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.codeBlockGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let words):
                    prose(ChatText.marking(marked, in: words))
                case .code(let code):
                    ChatCodeBlock(code: code, marked: marked)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ text: AttributedString) -> some View {
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

    @Environment(\.chatRows) private var rows

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let rows, !turn.text.isEmpty {
                ChatReplyRow(
                    blocks: ChatText.reply(turn.text, home: rows.media.userHome),
                    marked: [],
                    speaker: CompanionProtocol.assistantRole
                )
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
