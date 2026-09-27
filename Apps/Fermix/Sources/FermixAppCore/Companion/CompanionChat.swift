import Foundation

/// One row of the held timeline, from whichever event brought it: a history
/// page, a live `row`, or a turn's `text_done`.
public struct CompanionRow: Equatable, Sendable, Identifiable {
    public let serverSeq: Int
    public let text: String
    /// Who wrote the row, in the daemon's own word, and when, as the daemon
    /// wrote the time. A reply held from its turn's `text_done` has neither:
    /// that event names the turn, not the row's role or time.
    public let role: String?
    public let timestamp: String?
    /// On a user's row, the request it recorded.
    public let clientMsgId: String?
    /// On a reply, the request it answers, where this client knows it.
    public let inReplyTo: String?
    /// On a reply held from its turn's `text_done`, that turn.
    public let turnId: String?

    public var id: Int { serverSeq }
}

extension CompanionRow {
    /// A row a history page exported.
    init(_ row: CompanionTimelineRow) {
        self.init(
            serverSeq: row.serverSeq,
            text: row.content,
            role: row.role,
            timestamp: row.timestamp,
            clientMsgId: row.clientMsgId,
            inReplyTo: row.inReplyTo,
            turnId: nil
        )
    }

    /// A row announced live as it was written outside a turn's completion.
    init(_ row: CompanionAnnouncedRow) {
        self.init(
            serverSeq: row.serverSeq,
            text: row.text,
            role: row.role,
            timestamp: row.timestamp,
            clientMsgId: row.clientMsgId,
            inReplyTo: nil,
            turnId: nil
        )
    }

    /// A reply part at its row, from the turn's `text_done`.
    init(reply turnId: String, serverSeq: Int, text: String, inReplyTo: String?) {
        self.init(
            serverSeq: serverSeq,
            text: text,
            role: nil,
            timestamp: nil,
            clientMsgId: nil,
            inReplyTo: inReplyTo,
            turnId: turnId
        )
    }
}

/// The turn answering now, as its live events describe it. Deltas are
/// live-only, so this is never history: a completed turn's text arrives as a
/// row, and a failed one leaves nothing.
public struct CompanionTurn: Equatable, Sendable {
    public let turnId: String
    /// The request it answers. Absent for a turn this connection joined
    /// midway, whose text so far arrived as its first `text_delta` without a
    /// `turn_started`.
    public let inReplyTo: String?
    /// The draft: every `text_delta` appended exactly as sent.
    public internal(set) var text: String
    /// The latest tool call the turn reported, as the daemon reported it.
    public internal(set) var tool: CompanionToolEvent?
}

/// What a request asks of the agent.
public enum CompanionRequest: Equatable, Sendable {
    case message(text: String)
    /// A slash command. An approval's answer is one.
    case command(name: String, args: String?)
}

/// A request the daemon has not yet acknowledged with `accepted`. It is sent
/// again after every reconnect until it is.
public struct CompanionOutboxEntry: Equatable, Sendable, Identifiable {
    public let clientMsgId: String
    public let request: CompanionRequest

    public var id: String { clientMsgId }

    /// The event that carries the request. It is the same every time it is
    /// sent: the daemon refuses one id with different content as a conflict.
    var event: CompanionClientEvent {
        switch request {
        case .message(let text):
            return .msg(clientMsgId: clientMsgId, profileId: CompanionProtocol.profileId, text: text)
        case .command(let name, let args):
            return .command(clientMsgId: clientMsgId, profileId: CompanionProtocol.profileId, name: name, args: args)
        }
    }
}

/// A search of the timeline and what the daemon answered.
public struct CompanionSearch: Equatable, Sendable {
    public let query: String
    /// Newest first. Nil until the daemon answers this query.
    public internal(set) var hits: [CompanionSearchHit]?
    /// Where older hits start, when the daemon said older ones exist.
    public internal(set) var nextBeforeSeq: Int?
}

extension CompanionApproval: Identifiable {
    public var id: String { approvalId }
}

/// An approval's route, `/name args`, as the command that answers it: the
/// contract's `/confirm TOKEN` is `command{name: "confirm", args: "TOKEN"}`.
struct CompanionCommandRoute: Equatable {
    let name: String
    let args: String?

    /// Nil for a route that is not a slash command, which cannot be answered.
    init?(_ route: String) {
        guard route.hasPrefix("/") else { return nil }

        let parts = route.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty else { return nil }

        self.name = String(name)
        self.args = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
    }
}

/// Everything the chat holds, as one value the reducer reads and writes. The
/// model publishes it and the session is the only writer.
struct CompanionChat: Equatable, Sendable {
    /// The held window of the timeline, strictly ascending by seq.
    var rows: [CompanionRow] = []
    /// The last seq this client shows: the newest held row, or 0 before any.
    var cursor = 0
    /// The newest seq the daemon had written when it read the latest page.
    var historyHeadSeq = 0
    /// Whether a row older than the oldest held one exists, as the latest
    /// backward page said.
    var hasOlder = false
    var turn: CompanionTurn?
    /// The outbox, oldest first.
    var pending: [CompanionOutboxEntry] = []
    /// Approvals not yet resolved, in the order they arrived.
    var approvals: [CompanionApproval] = []
    var search: CompanionSearch?
    /// The latest failure, in a sentence, until the next request.
    var lastError: String?
    /// The one history pull out. The cursor rule never asks twice at once.
    var historyPull: CompanionHistoryCursor?
    /// The read frontier, as the daemon last reported it or this client last
    /// advanced it.
    var readUpToSeq = 0
}
