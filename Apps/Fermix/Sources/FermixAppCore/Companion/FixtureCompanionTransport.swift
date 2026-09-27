#if DEBUG
import Foundation

/// Which timeline a fixture launch's chat holds.
enum FixtureCompanionTimeline: Equatable {
    /// Nothing written yet: the chat surface's empty state.
    case empty
    /// A dozen rows of both sides with older ones behind them, a reply being
    /// written with a tool running, and an approval waiting.
    case full
}

/// The companion socket, replaced by a scripted daemon.
///
/// Only the socket is replaced. Every line still crosses `CompanionSocketClient`
/// and every event the session's reducer, so the chat surface is rendered over
/// the events the contract publishes rather than over a model somebody filled
/// in by hand. What the daemon would decide is scripted, and no more: it
/// answers the handshake with this build's window, pages and searches its own
/// rows, takes a message into a row and a short reply, resolves an approval's
/// answer, and stops a turn that is cancelled.
///
/// Callbacks go out on whatever thread asked, which is the main one; the
/// composition wraps this in the same main-actor delivery the real socket
/// takes.
///
/// DEBUG only, by construction: a release build has no scripted daemon.
final class FixtureCompanionTransport: LineSocketTransport, @unchecked Sendable {
    var onMessage: ((CompanionServerEvent) -> Void)?
    var onFailure: ((LineSocketFailure<CompanionDecodeFailure>) -> Void)?

    /// The most rows one page carries, below the contract's page so the
    /// newest one has older rows behind it for the reader to reach.
    static let historyPage = 12
    /// The most hits one answer carries, below the contract's page so the
    /// fixture can show the action that asks for older ones.
    static let searchPage = 4
    /// How long the scripted reply to a message takes to arrive.
    static let replyDelay: TimeInterval = 1.5

    private var rows: [CompanionTimelineRow]
    private let opening: [CompanionServerEvent]
    private var repliesWritten = 0

    init(timeline: FixtureCompanionTimeline) {
        switch timeline {
        case .empty:
            rows = []
            opening = []
        case .full:
            rows = FixtureCompanionScript.rows
            opening = FixtureCompanionScript.opening
        }
    }

    func connect(path: String, completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void) {
        completion(.success(()))
    }

    func send(_ line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String
        else {
            preconditionFailure("the fixture daemon was sent a line that is not an event")
        }

        answer(type, event)
    }

    func sendDroppable(_ line: Data) {
        send(line)
    }

    func sendDroppable(producing line: @escaping @Sendable () -> Data) {
        send(line())
    }

    func close() {}

    // MARK: - The script

    private func answer(_ type: String, _ event: [String: Any]) {
        switch type {
        case "client_hello":
            emit(.serverHello(minVersion: CompanionProtocol.supportedWindow.minimum, maxVersion: CompanionProtocol.supportedWindow.maximum))
        case "history_pull":
            emit(.historyPage(page(event)))
            if (event["before_seq"] as? Int) == CompanionReducer.newestPageBound { opening.forEach(emit) }
        case "history_search":
            emit(.searchResults(results(event)))
        case "msg":
            take(message: event)
        case "command":
            resolve(command: event)
        case "cancel":
            stop(event)
        case "read_state":
            emit(.readState(profileId: CompanionProtocol.profileId, readUpToSeq: event["read_up_to_seq"] as? Int ?? 0))
        default:
            preconditionFailure("the fixture daemon has no answer for \(type)")
        }
    }

    private var head: Int { rows.last?.serverSeq ?? 0 }

    /// A page, as the contract cuts one: the newest rows below a cursor, or the
    /// oldest above one, oldest first either way.
    private func page(_ event: [String: Any]) -> CompanionHistoryPage {
        let limit = min(event["limit"] as? Int ?? Self.historyPage, Self.historyPage)

        if let before = event["before_seq"] as? Int {
            let below = rows.filter { $0.serverSeq < before }
            let messages = Array(below.suffix(limit))
            let older = below.count > messages.count ? messages.first?.serverSeq : nil
            return CompanionHistoryPage(
                profileId: CompanionProtocol.profileId,
                messages: messages,
                historyHeadSeq: head,
                nextAfterSeq: nil,
                nextBeforeSeq: older
            )
        }

        let after = event["after_seq"] as? Int ?? 0
        let messages = Array(rows.filter { $0.serverSeq > after }.prefix(limit))
        return CompanionHistoryPage(
            profileId: CompanionProtocol.profileId,
            messages: messages,
            historyHeadSeq: head,
            nextAfterSeq: messages.last?.serverSeq ?? after,
            nextBeforeSeq: nil
        )
    }

    /// Hits newest first, each excerpt the whole row with every match marked.
    private func results(_ event: [String: Any]) -> CompanionSearchResults {
        let query = event["query"] as? String ?? ""
        let before = event["before_seq"] as? Int ?? Int.max
        let matching = rows.reversed().filter { $0.serverSeq < before && $0.content.localizedCaseInsensitiveContains(query) }
        let hits = matching.prefix(Self.searchPage).map { Self.hit($0, query: query) }

        return CompanionSearchResults(
            profileId: CompanionProtocol.profileId,
            query: query,
            hits: Array(hits),
            nextBeforeSeq: matching.count > hits.count ? hits.last?.serverSeq : nil
        )
    }

    private static func hit(_ row: CompanionTimelineRow, query: String) -> CompanionSearchHit {
        let text = row.content
        var ranges: [CompanionMatchRange] = []
        var searchStart = text.startIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            ranges.append(
                CompanionMatchRange(
                    start: text.unicodeScalars.distance(from: text.startIndex, to: found.lowerBound),
                    length: text[found].unicodeScalars.count
                )
            )
            searchStart = found.upperBound
        }

        return CompanionSearchHit(
            serverSeq: row.serverSeq,
            role: row.role,
            timestamp: row.timestamp,
            excerpt: text,
            ranges: ranges
        )
    }

    /// A message becomes the owner's row at once and a short reply after a
    /// moment, so the turn is seen being written.
    private func take(message event: [String: Any]) {
        let clientMsgId = event["client_msg_id"] as? String ?? ""
        let text = event["text"] as? String ?? ""
        emit(.accepted(CompanionAccepted(clientMsgId: clientMsgId, duplicate: false, serverSeq: nil)))

        let row = append(role: "user", content: text, clientMsgId: clientMsgId, inReplyTo: nil)
        emit(.row(CompanionAnnouncedRow(
            profileId: CompanionProtocol.profileId,
            serverSeq: row.serverSeq,
            role: row.role,
            text: row.content,
            timestamp: row.timestamp,
            clientMsgId: clientMsgId
        )))

        repliesWritten += 1
        let turnId = "fixture-turn-\(repliesWritten)"
        emit(.turnStarted(profileId: CompanionProtocol.profileId, turnId: turnId, inReplyTo: clientMsgId))
        emit(.textDelta(turnId: turnId, text: FixtureCompanionScript.replyOpening))

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyDelay) { [weak self] in
            self?.finish(turnId, replyingTo: clientMsgId)
        }
    }

    private func finish(_ turnId: String, replyingTo clientMsgId: String) {
        let reply = append(role: "assistant", content: FixtureCompanionScript.reply, clientMsgId: nil, inReplyTo: clientMsgId)
        emit(.textDone(turnId: turnId, serverSeq: reply.serverSeq, text: reply.content))
    }

    private func resolve(command event: [String: Any]) {
        let clientMsgId = event["client_msg_id"] as? String ?? ""
        emit(.accepted(CompanionAccepted(clientMsgId: clientMsgId, duplicate: false, serverSeq: nil)))
        emit(.approvalResolved(
            approvalId: FixtureCompanionScript.approvalId,
            outcome: event["name"] as? String == "confirm" ? .approved : .denied
        ))
    }

    /// The contract's own answer to a cancel: the turn ends as cancelled.
    private func stop(_ event: [String: Any]) {
        let clientMsgId = event["client_msg_id"] as? String ?? ""
        let turnId = clientMsgId == FixtureCompanionScript.askedLast
            ? FixtureCompanionScript.openingTurn
            : "fixture-turn-\(repliesWritten)"
        emit(.turnError(turnId: turnId, code: "cancelled", message: "cancelled"))
    }

    private func append(role: String, content: String, clientMsgId: String?, inReplyTo: String?) -> CompanionTimelineRow {
        let row = FixtureCompanionScript.row(head + 1, role, content, clientMsgId: clientMsgId, inReplyTo: inReplyTo)
        rows.append(row)
        return row
    }

    private func emit(_ event: CompanionServerEvent) {
        onMessage?(event)
    }
}

/// What the full timeline holds: eight older rows behind a newest page of
/// twelve, and what is happening now.
enum FixtureCompanionScript {
    static let askedLast = "fixture-msg-20"
    static let openingTurn = "fixture-turn-opening"
    static let approvalId = "fixture-approval-1"
    static let replyOpening = "Working on it. "
    static let reply = "This is the fixture companion. It answers every message the same way, a moment later."

    /// Twenty rows, oldest first: 1 to 8 are behind the newest page, which
    /// asks for them when the reader reaches the top.
    static let rows: [CompanionTimelineRow] = [
        row(1, "user", "Good morning. Anything I should know before the day starts?", clientMsgId: "fixture-msg-1"),
        row(2, "assistant", "Two meetings, a parcel arriving before noon, and rain from about four.", inReplyTo: "fixture-msg-1"),
        row(3, "user", "Remind me to take an umbrella at three.", clientMsgId: "fixture-msg-3"),
        row(4, "assistant", "Done. I will remind you at 15:00.", inReplyTo: "fixture-msg-3"),
        row(5, "assistant", "Reminder: take an umbrella, rain is due from about four."),
        row(6, "user", "Thanks. What did Priya say about the launch date?", clientMsgId: "fixture-msg-6"),
        row(7, "assistant", "She moved it to the **14th** so the release notes can be reviewed first.", inReplyTo: "fixture-msg-6"),
        row(8, "user", "Good. Add the review to my calendar for the 12th.", clientMsgId: "fixture-msg-8"),
        row(9, "user", "What is on my calendar tomorrow?", clientMsgId: "fixture-msg-9"),
        row(10, "assistant", "Two things: the design review at **10:00** and lunch with Sam at 12:30. The review has a prep doc attached.", inReplyTo: "fixture-msg-9"),
        row(11, "user", "Move lunch to one and let Sam know.", clientMsgId: "fixture-msg-11"),
        row(12, "assistant", "Done. Lunch is at 13:00 now, and I sent Sam a note on Telegram.", inReplyTo: "fixture-msg-11"),
        row(13, "assistant", "Your design review starts in 15 minutes. The prep doc is in *Shared/Design*."),
        row(14, "user", "Summarise the prep doc in three points.", clientMsgId: "fixture-msg-14"),
        row(
            15,
            "assistant",
            "1. The window gains a Chat row, first in the rail.\n2. The composer docks at the bottom once the conversation starts.\n3. Search runs in the engine, so months of history stay fast.",
            inReplyTo: "fixture-msg-14"
        ),
        row(16, "user", "Book the dentist for Friday morning if there is a slot.", clientMsgId: "fixture-msg-16"),
        row(17, "assistant", "Friday has a slot at 9:30 with Dr Patel. Shall I book it?", inReplyTo: "fixture-msg-16"),
        row(18, "user", "Yes, book it.", clientMsgId: "fixture-msg-18"),
        row(19, "assistant", "Booked for Friday at 9:30. It is on your calendar with the address and a reminder the evening before.", inReplyTo: "fixture-msg-18"),
        row(20, "user", "Will it rain on Saturday? I want to plan the hike.", clientMsgId: askedLast),
    ]

    /// Live after the newest page: the reply to the last message, with the
    /// forecast lookup running, and an approval the agent is waiting on.
    static let opening: [CompanionServerEvent] = [
        .turnStarted(profileId: CompanionProtocol.profileId, turnId: openingTurn, inReplyTo: askedLast),
        .textDelta(turnId: openingTurn, text: "Let me check the forecast for Saturday around the trailhead."),
        .toolEvent(CompanionToolEvent(turnId: openingTurn, tool: "web_search", phase: .start, detail: nil)),
        .approval(
            CompanionApproval(
                approvalId: approvalId,
                kind: "sandbox",
                text: "Allow reading ~/Documents/Hikes to find the trail you saved?",
                detail: "Fermix asks before it reads outside its own folders.",
                token: "fixture-token",
                ttlSeconds: 300,
                approveCommand: "/confirm fixture-token",
                denyCommand: "/deny fixture-token"
            )
        ),
    ]

    static func row(
        _ seq: Int,
        _ role: String,
        _ content: String,
        clientMsgId: String? = nil,
        inReplyTo: String? = nil
    ) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: role,
            content: content,
            kind: "text",
            timestamp: String(format: "2026-09-25T09:%02d:00Z", seq % 60),
            mediaRefs: [],
            clientMsgId: clientMsgId,
            inReplyTo: inReplyTo,
            metadata: nil
        )
    }
}
#endif
