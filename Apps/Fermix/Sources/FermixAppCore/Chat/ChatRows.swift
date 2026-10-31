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
    /// The one place the whole chat shows on a reply's map (M72 §14.1).
    let places: ChatPlaceSelection
    /// The check every link a reply's words draw opens through.
    let linkGuard: ChatLinkGuard
    /// The Fermix home as this visit to Chat read it, nil until the surface
    /// has read it.
    let visit: ChatVisit?
    /// The reading column's width, which a strip fits its tiles to.
    let columnWidth: Double
    /// The Lists panel beside the chat, and through it the owner's lists a
    /// reply's card draws (M85 §08).
    let lists: ChecklistPanelModel

    /// The media, the player, the opener and the lists are each one object
    /// for the app's life, and the places shown and the link check one for
    /// the surface's, so two
    /// contexts are the same when they, the visit and the column are: a
    /// keystroke that redraws the surface must not redraw every row.
    static func == (lhs: ChatRowContext, rhs: ChatRowContext) -> Bool {
        lhs.media === rhs.media && lhs.player === rhs.player && lhs.links === rhs.links
            && lhs.places === rhs.places && lhs.linkGuard === rhs.linkGuard
            && lhs.visit == rhs.visit && lhs.columnWidth == rhs.columnWidth && lhs.lists === rhs.lists
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
    /// Whether the row's lists card is the newest of each list it draws,
    /// and so live (M85 §08).
    let listsLive: Bool
    let answer: (String, Bool) -> Void
    /// A proposal card's two buttons, and nothing else, answer through this.
    let decide: (String, CompanionProposalDecision) -> Void

    var body: some View {
        switch item {
        case .row(let row):
            ChatRow(row: row, marked: marked, listsLive: listsLive)
                .equatable()
        case .turn(let turn):
            ChatTurnRow(turn: turn)
        case .approval(let approval, let answering):
            ChatApprovalCard(approval: approval, answering: answering, answer: answer)
        case .proposal(let card):
            ChatProposalCard(card: card, decide: decide)
        case .pending(_, let text):
            ChatUserRow(text: ChatText.plain(text), sending: true)
        case .error(let sentence):
            ChatErrorRow(sentence: sentence)
        }
    }
}

/// A finished row, on its side: its words, or its voice note with its words
/// as the transcript; under them the records its reply was drawn with, a map
/// and cards for the places it recommends (M72 §8.1) and the lists its turn
/// read or changed (M85 §08); then the sound files it
/// names in the Fermix home;
/// the note and each sound playable where it is (M66 §3.4); and then its
/// strip (§3.1). Its words are the strip's text, without the lines that only
/// name what the strip and the players show. A row with no other words, a
/// picture Fermix sent to the phone or a reply that only lists what it made,
/// draws its strip alone. A turn still being written is no row yet, so
/// nothing here looks at the disk while a reply streams. Under a reply with
/// words, what can be done with it (`ChatMessageActions`); beside a person's
/// own message, the same on its leading side.
///
/// It draws again only when what it draws changes: the row, compared whole
/// so a field the row gains is never missed, and the words a search marks in
/// it. What it reads from the surface comes through the environment, which
/// draws it again when that changes.
struct ChatRow: View, Equatable {
    let row: CompanionRow
    let marked: [String]
    /// Whether its lists card is live; an older one folds to one line.
    let listsLive: Bool

    @Environment(\.chatRows) private var rows

    static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.row == rhs.row && lhs.marked == rhs.marked && lhs.listsLive == rhs.listsLive
    }

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
                    ChatUserRow(text: words(strip), sending: false, copying: row.text)
                } else if let reply = strip.reply {
                    ChatReplyRow(blocks: reply.blocks, marked: marked, titles: ChatLinkTitles(row.linkPreviews), speaker: row.role)
                }
            }

            ChatRecords(blocks: row.blocks, reply: row.serverSeq, listsLive: listsLive)

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
        .modifier(ChatReplyActionsRow(row: row))
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
/// as they typed it. While the daemon has not accepted it, it says so under
/// it; once it has, Copy waits beside it, in the room on its leading side,
/// and shows while the pointer is over it.
private struct ChatUserRow: View {
    let text: AttributedString
    let sending: Bool
    /// What Copy writes, nil while the message is still being sent.
    var copying: String?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            HStack(alignment: .bottom, spacing: Spacing.xxs) {
                if let copying {
                    ChatCopyAction(text: copying, shown: hovering)
                }

                chip
            }

            if sending {
                Text(ProductStrings[.chatSending])
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.faint.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, ChatMetrics.userRowLeadingRoom - (copying == nil ? 0 : ChatMetrics.actionSize + Spacing.xxs))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var chip: some View {
        Text(text)
            .fermixType(ChatMetrics.readingType)
            .foregroundStyle(Palette.ink.color)
            .textSelection(.enabled)
            .padding(ChatMetrics.userChipPadding)
            .background(
                RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
                    .fill(Palette.chipFill.color)
            )
            .opacity(sending ? ChatMetrics.sendingStrength : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ChatSpeaker.name(role: ChatSpeaker.user))
            .accessibilityValue(sending ? ProductStrings.commaPair(String(text.characters), ProductStrings[.chatSending]) : String(text.characters))
    }
}

/// What Fermix wrote: on the leading side, its words straight on the ground
/// with no fill of its own, as one text a reader selects across
/// (`ChatReplyText`). A delivery, a row with no turn, and the turn still
/// being written are drawn the same way.
private struct ChatReplyRow: View {
    /// The blocks as they read.
    let blocks: [ReplyBlock]
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    /// The titles of the pages its links go to, where the engine read them.
    let titles: ChatLinkTitles
    let speaker: String?

    var body: some View {
        ChatReplyText(blocks: blocks, marked: marked, titles: titles, speaker: speaker)
            .equatable()
    }
}

/// The turn answering now: over its text, what it is doing and has done
/// (`ChatTurnActivity`), and its text so far. Its text is read as it
/// arrives (`ReplyDraft`), so each piece reads only the block still being
/// written. How long it has worked is counted from when this Mac saw it
/// start, and stops when it starts writing.
private struct ChatTurnRow: View {
    let turn: CompanionTurn

    @Environment(\.chatRows) private var rows
    @State private var draft = ReplyDraft()
    @State private var started = Date.now
    @State private var wrote: Date?

    var body: some View {
        let progress = ChatTurnProgress(turn)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            if progress.shows {
                ChatTurnActivity(progress: progress, started: started, wrote: wrote)
            }

            if let rows, !turn.text.isEmpty {
                ChatReplyRow(
                    blocks: draft.blocks(turn.text, home: rows.media.userHome),
                    marked: [],
                    titles: .none,
                    speaker: CompanionProtocol.assistantRole
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: progress.working, initial: true) { _, working in
            wrote = working ? nil : .now
        }
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
