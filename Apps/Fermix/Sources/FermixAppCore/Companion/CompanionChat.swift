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
    /// The history message's kind, `text` or `media`, where the event that
    /// brought the row carried it.
    public let kind: String?
    /// The files the row refers to, by ref. Only a history page carries them:
    /// a live `row` and a `text_done` bring none.
    public let mediaRefs: [CompanionMediaRef]
    /// The link previews the engine stored on the row. Only a history page
    /// carries them.
    public let linkPreviews: [CompanionLinkPreview]

    public var id: Int { serverSeq }

    init(
        serverSeq: Int,
        text: String,
        role: String?,
        timestamp: String?,
        clientMsgId: String?,
        inReplyTo: String?,
        turnId: String?,
        kind: String? = nil,
        mediaRefs: [CompanionMediaRef] = [],
        linkPreviews: [CompanionLinkPreview] = []
    ) {
        self.serverSeq = serverSeq
        self.text = text
        self.role = role
        self.timestamp = timestamp
        self.clientMsgId = clientMsgId
        self.inReplyTo = inReplyTo
        self.turnId = turnId
        self.kind = kind
        self.mediaRefs = mediaRefs
        self.linkPreviews = linkPreviews
    }
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
            turnId: nil,
            kind: row.kind,
            mediaRefs: row.mediaRefs,
            linkPreviews: row.linkPreviews ?? []
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
            turnId: nil,
            kind: row.kind
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

    /// Whether two rows at one seq draw alike: the same text, files and
    /// previews (M66 §3.1). Who wrote a row and when are not what changes its
    /// height when history brings it again.
    func drawsAlike(_ other: CompanionRow) -> Bool {
        text == other.text && mediaRefs == other.mediaRefs && linkPreviews == other.linkPreviews
    }

    /// A voice note whose transcript is not stored yet: a row with an `audio`
    /// ref (M66 §3.4) and no text, as history last had it.
    var awaitsTranscript: Bool {
        text.isEmpty && mediaRefs.contains { $0.kind == "audio" }
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
    /// The `before_seq` of the older hits asked for and not yet answered. Its
    /// answer extends the hits rather than replacing them.
    public internal(set) var olderHitsAsked: Int? = nil
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

/// A history read as it was sent, which is how its page is taken. A page does
/// not say which read it answers, so one is out at a time.
enum CompanionPull: Equatable, Sendable {
    /// The rows after the cursor, or the newest page for a chat that holds
    /// none.
    case catchUp(CompanionHistoryCursor)
    /// The page before the oldest held row, which the reader scrolled to.
    case older(beforeSeq: Int)
    /// Held rows read again for what their announcement could not carry.
    case rows(CompanionRowRead)

    var event: CompanionClientEvent {
        .historyPull(profileId: CompanionProtocol.profileId, cursor: cursor, limit: limit)
    }

    var cursor: CompanionHistoryCursor {
        switch self {
        case .catchUp(let cursor): return cursor
        case .older(let beforeSeq): return .before(seq: beforeSeq)
        case .rows(let read): return .after(seq: read.afterSeq)
        }
    }

    /// A full page for the catch-up read and paging; a row read asks only for
    /// the rows it reads.
    private var limit: Int {
        switch self {
        case .catchUp, .older: return CompanionProtocol.historyPageLimit
        case .rows(let read): return read.limit
        }
    }
}

/// Held rows read again in one read: from just below the lowest, as far as the
/// highest, within one page.
struct CompanionRowRead: Equatable, Sendable {
    let seqs: Set<Int>
    let afterSeq: Int
    let limit: Int

    /// Nil when there is nothing to read.
    init?(_ seqs: Set<Int>) {
        guard let lowest = seqs.min(), let highest = seqs.max() else { return nil }

        self.seqs = seqs
        afterSeq = lowest - 1
        limit = min(highest - lowest + 1, CompanionProtocol.historyPageLimit)
    }

    /// The rows the page answering this read did not reach: a page stops at
    /// about 60 KiB, so a long row can end it before the highest. An empty
    /// page found no row from the lowest on, so there is nothing left to read.
    func unreached(by page: CompanionHistoryPage) -> Set<Int> {
        guard let reached = page.messages.last?.serverSeq else { return [] }

        return seqs.filter { $0 > reached }
    }
}

/// Rows whose height changed in place: what the transcript holds the reader's
/// place against (M66 §3.8). Each change is a new value, so two changes to the
/// same rows are two changes to an observer.
public struct CompanionReshape: Equatable, Sendable {
    /// Counts the changes.
    public let id: Int
    /// The rows that changed: rows history brought again with different
    /// content, or the row whose strip opened or folded.
    public let seqs: Set<Int>
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
    /// The one history read out. The reads asked meanwhile wait below it, one
    /// of each at most, and are served in order (M66 §3.6): the catch-up read,
    /// which is never kept waiting, then paging, then rows read again.
    var historyPull: CompanionPull?
    /// Paging waiting for the read out: the page before this seq, the oldest
    /// held row when it was asked for.
    var olderWaiting: Int?
    /// Held rows to read again, waiting for the read out. One read serves
    /// them all.
    var rowsToRead: Set<Int> = []
    /// The person's media rows announced in this session with no text, which
    /// may be voice notes waiting for their transcript (M66 §3.6, stage 1), by
    /// seq, with the request each recorded: its reply names that request in
    /// `in_reply_to`. A row leaves when history shows it is no voice note or
    /// has its text, when a page brings its reply, or when an assistant's row
    /// is announced a page of rows past it.
    var awaitingTranscript: [Int: String] = [:]
    /// The read frontier, as the daemon last reported it or this client last
    /// advanced it.
    var readUpToSeq = 0
    /// The rows whose strip shows every item, by seq (M66 §3.2). Kept here
    /// rather than in a row's view, which a lazy transcript drops off screen.
    var openStrips: Set<Int> = []
    /// The latest change to a held row's height.
    var reshape: CompanionReshape?
}
