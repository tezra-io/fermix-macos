import Foundation

/// What the transcript scrolls to and remembers a place by.
enum ChatItemID: Hashable, Sendable {
    /// The marker above the oldest held row while older rows exist.
    case older
    case row(Int)
    case turn(String)
    case approval(String)
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
    /// A message the daemon has not accepted yet.
    case pending(clientMsgId: String, text: String)
    /// The latest failure, in the daemon's or the catalogue's sentence.
    case error(String)

    var id: ChatItemID {
        switch self {
        case .row(let row): return .row(row.serverSeq)
        case .turn(let turn): return .turn(turn.turnId)
        case .approval(let approval, _): return .approval(approval.approvalId)
        case .pending(let clientMsgId, _): return .pending(clientMsgId)
        case .error: return .error
        }
    }
}

/// The transcript as a list: every fact the chat model publishes, in reading
/// order, and nothing derived beyond that order.
///
/// Rows come first, oldest to newest, then the turn answering now, then the
/// approvals it raised, then what the owner has sent and the daemon has not
/// yet accepted, and last the latest failure. A command in the outbox is an
/// approval's answer rather than something the owner wrote, so it is not drawn
/// as a message: its token is never rendered.
enum ChatTimeline {
    static func items(
        rows: [CompanionRow],
        turn: CompanionTurn?,
        approvals: [CompanionApproval],
        pending: [CompanionOutboxEntry],
        lastError: String?
    ) -> [ChatItem] {
        var items = rows.map(ChatItem.row)
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
            lastError: model.lastError
        )
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
