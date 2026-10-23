import Foundation

/// What the transcript scrolls to and remembers a place by.
enum ChatItemID: Hashable, Sendable {
    /// The marker above the oldest held row while older rows exist.
    case older
    case row(Int)
    case turn(String)
    case approval(String)
    case proposal(String)
    case pending(String)
    case error
}

/// One thing the transcript draws, in the order it draws them.
enum ChatItem: Equatable, Identifiable {
    /// A row of the held timeline: a message, a reply, or a delivery.
    case row(CompanionRow)
    /// The turn answering now: its draft and its latest tool call.
    case turn(CompanionTurn)
    /// An approval waiting on the owner. `answering` while its answer is in
    /// the outbox, so it is not answered twice.
    case approval(CompanionApproval, answering: Bool)
    /// A cue proposal's card (M60 §4.7): no timeline row and no seq, placed
    /// in the conversation at the time it was made.
    case proposal(CompanionProposalCard)
    /// A message the daemon has not accepted yet.
    case pending(clientMsgId: String, text: String)
    /// The latest failure, in the daemon's or the catalogue's sentence.
    case error(String)

    var id: ChatItemID {
        switch self {
        case .row(let row): return .row(row.serverSeq)
        case .turn(let turn): return .turn(turn.turnId)
        case .approval(let approval, _): return .approval(approval.approvalId)
        case .proposal(let card): return .proposal(card.id)
        case .pending(let clientMsgId, _): return .pending(clientMsgId)
        case .error: return .error
        }
    }

    /// A message this client sent and the daemon has not yet accepted: the
    /// signal, in `ChatTranscript`, that the reader just sent it themselves.
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    /// Whether the owner, not the daemon, wrote this item: their own row, or
    /// a message not yet accepted. Everything else is what a turn answers
    /// with.
    fileprivate var isUserAuthored: Bool {
        switch self {
        case .row(let row): return ChatSpeaker.isUser(row.role)
        case .pending: return true
        case .turn, .approval, .proposal, .error: return false
        }
    }
}

/// The transcript as a list: every fact the chat model publishes, in reading
/// order, and nothing derived beyond that order.
///
/// Rows come first, oldest to newest, with each proposal's card among them at
/// the time it was made, then the turn answering now, then the approvals it
/// raised, then what the owner has sent and the daemon has not yet accepted,
/// and last the latest failure. A command or a proposal's answer in the outbox
/// is an answer rather than something the owner wrote, so it is not drawn as a
/// message: an approval's token is never rendered.
enum ChatTimeline {
    static func items(
        rows: [CompanionRow],
        turn: CompanionTurn?,
        approvals: [CompanionApproval],
        pending: [CompanionOutboxEntry],
        lastError: String?,
        proposals: [CompanionProposalCard] = []
    ) -> [ChatItem] {
        var items = placed(rows, proposals)
        if let turn { items.append(.turn(turn)) }
        items += approvals.map { .approval($0, answering: isAnswering($0, in: pending)) }
        items += pending.compactMap(message)
        if let lastError { items.append(.error(lastError)) }

        return items
    }

    @MainActor
    static func items(of model: CompanionModel) -> [ChatItem] {
        items(
            rows: model.rows,
            turn: model.turn,
            approvals: model.approvals,
            pending: model.pending,
            lastError: model.lastError,
            proposals: model.proposals
        )
    }

    /// The rows, each card after the newest row written at or before the
    /// card was made (M60 §4.7). A row with no time of its own, a reply held
    /// from its turn, places nothing; a card made before every held row goes
    /// first, and one whose time this build cannot read goes after the rows.
    /// The walk starts at the newest row, where a card nearly always lands, so
    /// a redraw reads the times of a few rows rather than of every one.
    private static func placed(_ rows: [CompanionRow], _ cards: [CompanionProposalCard]) -> [ChatItem] {
        guard !cards.isEmpty else { return rows.map(ChatItem.row) }

        let slotted = Dictionary(grouping: cards) { slot(of: $0, among: rows) }
        var items: [ChatItem] = []
        for (index, row) in rows.enumerated() {
            items += (slotted[index] ?? []).map(ChatItem.proposal)
            items.append(.row(row))
        }
        items += (slotted[rows.count] ?? []).map(ChatItem.proposal)

        return items
    }

    /// How many held rows come before a card.
    private static func slot(of card: CompanionProposalCard, among rows: [CompanionRow]) -> Int {
        guard let made = card.createdAt else { return rows.count }

        for index in rows.indices.reversed() {
            guard let written = CompanionTime.date(rows[index].timestamp) else { continue }
            if written <= made { return index + 1 }
        }

        return 0
    }

    /// Whether the seam between two adjacent items opens a new turn: every
    /// seam does, except the one between a user's own row (or a message not
    /// yet accepted) and the reply that follows it, which is one turn. A
    /// proposal's card answers no message, so it always stands apart.
    static func opensNewTurn(after previous: ChatItem?, before current: ChatItem) -> Bool {
        guard let previous else { return false }
        if case .proposal = current { return true }

        return !(previous.isUserAuthored && !current.isUserAuthored)
    }

    private static func message(_ entry: CompanionOutboxEntry) -> ChatItem? {
        guard case .message(let text) = entry.request else { return nil }

        return .pending(clientMsgId: entry.clientMsgId, text: text)
    }

    /// Whether one of the approval's two routes is waiting in the outbox.
    private static func isAnswering(_ approval: CompanionApproval, in pending: [CompanionOutboxEntry]) -> Bool {
        let routes = [approval.approveCommand, approval.denyCommand]
            .compactMap(CompanionCommandRoute.init)
            .map { CompanionRequest.command(name: $0.name, args: $0.args) }

        return pending.contains { routes.contains($0.request) }
    }
}

/// Where a search hit's row is, relative to what the transcript holds.
///
/// A row older than the oldest held one is reached by reading back page by
/// page, the way scrolling to the top reads: every page the transcript holds
/// joins the one below it, so the rows between the hit and the reader are
/// never skipped.
struct ChatReveal: Equatable {
    let serverSeq: Int
    /// The words the daemon matched, as the hit's excerpt spells them.
    let terms: [String]

    enum Step: Equatable {
        /// The row is held: scroll to it.
        case scroll(ChatItemID)
        /// The row is older than the oldest held one and older rows exist.
        case readOlder
        /// Nothing the transcript can read holds the row.
        case unreachable
    }

    init(_ hit: CompanionSearchHit) {
        serverSeq = hit.serverSeq
        terms = ChatExcerpt.terms(of: hit)
    }

    func step(rows: [CompanionRow], hasOlder: Bool) -> Step {
        if rows.contains(where: { $0.serverSeq == serverSeq }) { return .scroll(.row(serverSeq)) }
        guard let oldest = rows.first?.serverSeq, serverSeq < oldest, hasOlder else { return .unreachable }

        return .readOlder
    }
}
