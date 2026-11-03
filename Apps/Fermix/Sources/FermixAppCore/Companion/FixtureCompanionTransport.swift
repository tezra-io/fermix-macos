#if DEBUG
import CryptoKit
import Foundation

/// Which timeline a fixture launch's chat holds.
enum FixtureCompanionTimeline: Equatable {
    /// Nothing written yet: the chat surface's empty state.
    case empty
    /// A dozen rows of both sides with older ones behind them, a reply being
    /// written with a tool running, an approval waiting, and a cue proposal's
    /// card in each of its states (M60 §4.7).
    case full
    /// Replies drawn for what they hold (M72): places with their map and
    /// cards, lists, a table, a quote, links and code, then a scheduled
    /// job's message and a cue's under the labels naming where each came
    /// from, all on one page, and nothing happening now.
    case replies
    /// The owner's lists (M85): an older reply's card folded to one line, a
    /// card of three lists, and the newest reply's card of one list, over
    /// four lists in two folders and none, with nothing happening now.
    case lists
}

/// The companion socket, replaced by a scripted daemon.
///
/// Only the socket is replaced. Every line still crosses `CompanionSocketClient`
/// and every event the session's reducer, so the chat surface is rendered over
/// the events the contract publishes rather than over a model somebody filled
/// in by hand. What the daemon would decide is scripted, and no more: it
/// answers the handshake with this build's window, pages and searches its own
/// rows, takes a message into a row and a short reply, resolves an approval's
/// answer, resolves a proposal's answer a moment later, stops a turn that is
/// cancelled, and grants only the link pictures of the replies timeline, from
/// sample photos every Mac has; every other `media_fetch` is answered
/// `media_missing`. It keeps the lists timeline's lists (`FixtureChecklists`),
/// none on any other: it answers their pulls, takes every edit and pushes
/// each list it changed a tenth of a second later, as the engine does. Its
/// hello names a few slash commands and an inbox under the temporary folder:
/// it holds each file handed over a moment later, and a message naming them
/// carries their refs, granted from its own copies, so a sent strip draws.
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
    /// The replies timeline is looked at whole: its one page carries every
    /// row it holds, so none is behind it.
    static let repliesPage = FixtureRepliesScript.rows.count
    /// The most hits one answer carries, below the contract's page so the
    /// fixture can show the action that asks for older ones.
    static let searchPage = 4
    /// How long the scripted reply to a message takes to arrive.
    static let replyDelay: TimeInterval = 1.5

    private var rows: [CompanionTimelineRow]
    private let opening: [CompanionServerEvent]
    /// The most rows one of this timeline's pages carries.
    private let pageLimit: Int
    private var repliesWritten = 0
    private let lists: FixtureChecklists
    /// The lists this connection pulled, and those pulled with their
    /// removed rows, as the engine holds them.
    private var held: [String] = []
    private var heldWithRemoved: Set<String> = []
    /// How long the engine's window holds a change before it pushes it.
    static let listWindow: TimeInterval = 0.1
    /// How long a handed-over file takes to be held.
    static let attachDelay: TimeInterval = 0.4
    /// The largest file the fixture takes, the engine's own default.
    static let attachMaxBytes = 20 * 1_024 * 1_024
    /// The inbox the hello names, and where it keeps the files it holds.
    private let inbox = FileManager.default.temporaryDirectory.appending(path: "FermixFixtureInbox", directoryHint: .isDirectory)
    /// The files held, by the attach id that handed each over.
    private var attached: [String: CompanionMediaRef] = [:]
    /// Each held file's copy, by its ref.
    private var attachedFiles: [String: String] = [:]
    /// A few of the engine's commands, as its hello lists them.
    static let commands = [
        CompanionCommand(name: "new", aliases: ["reset"], description: "Start a fresh conversation; the current one is archived."),
        CompanionCommand(name: "compact", aliases: [], description: "Summarize the conversation so far to free up context."),
        CompanionCommand(name: "background", aliases: ["bg"], description: "Run a task in the background and report back when it is done."),
        CompanionCommand(name: "tasks", aliases: [], description: "List the background tasks and their state."),
        CompanionCommand(name: "skills", aliases: [], description: "Review, approve, or deny skill-curation proposals; unpark or restore skills."),
        CompanionCommand(name: "stop", aliases: [], description: "Stop the reply being written."),
    ]

    /// `now` is when the launch began: a waiting proposal's expiry is counted
    /// from it, so the card still asks when the chat is looked at.
    init(timeline: FixtureCompanionTimeline, now: Date = Date()) {
        switch timeline {
        case .empty:
            rows = []
            opening = []
            pageLimit = Self.historyPage
        case .full:
            rows = FixtureCompanionScript.rows
            opening = FixtureCompanionScript.opening + FixtureProposalScript.opening(now: now)
            pageLimit = Self.historyPage
        case .replies:
            rows = FixtureRepliesScript.rows
            opening = []
            pageLimit = Self.repliesPage
        case .lists:
            rows = FixtureChecklistScript.rows
            opening = []
            pageLimit = Self.historyPage
        }
        lists = FixtureChecklists(timeline == .lists ? FixtureChecklistScript.seeds : [])
        try? FileManager.default.createDirectory(at: inbox.appending(path: "held"), withIntermediateDirectories: true)
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
            emit(.serverHello(
                minVersion: CompanionProtocol.supportedWindow.minimum,
                maxVersion: CompanionProtocol.supportedWindow.maximum,
                commands: Self.commands,
                attachments: CompanionAttachmentInbox(dir: inbox.path, maxBytes: Self.attachMaxBytes)
            ))
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
        case "media_fetch":
            let ref = event["ref"] as? String ?? ""
            emit(attachedGrant(ref: ref) ?? Self.grant(ref: ref))
        case "attach_file":
            hold(file: event)
        case "media_release":
            break
        case "proposal_answer":
            decide(proposal: event)
        case "checklists_pull":
            emit(.checklists(profileId: CompanionProtocol.profileId, lists: lists.index))
        case "checklist_pull":
            pull(list: event)
        case "checklist_edit":
            edit(list: event)
        default:
            preconditionFailure("the fixture daemon has no answer for \(type)")
        }
    }

    /// A link picture's sample photo, as the engine grants a file it holds;
    /// any other ref, or a photo this Mac does not have, is missing.
    private static func grant(ref: String) -> CompanionServerEvent {
        guard let path = FixtureRepliesScript.pictures[ref], let bytes = FileManager.default.contents(atPath: path) else {
            return .mediaMissing(ref: ref)
        }

        return .mediaPath(CompanionMediaPath(
            ref: ref,
            path: path,
            kind: "image",
            mime: "image/heic",
            sizeBytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        ))
    }

    private var head: Int { rows.last?.serverSeq ?? 0 }

    /// A page, as the contract cuts one: the newest rows below a cursor, or the
    /// oldest above one, oldest first either way.
    private func page(_ event: [String: Any]) -> CompanionHistoryPage {
        let limit = min(event["limit"] as? Int ?? pageLimit, pageLimit)

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

        let refs = (event["attach_ids"] as? [String] ?? []).compactMap { attached[$0] }
        let row = append(role: "user", content: text, clientMsgId: clientMsgId, inReplyTo: nil, mediaRefs: refs)
        emit(.row(CompanionAnnouncedRow(
            profileId: CompanionProtocol.profileId,
            serverSeq: row.serverSeq,
            role: row.role,
            text: row.content,
            timestamp: row.timestamp,
            clientMsgId: clientMsgId,
            kind: refs.isEmpty ? "text" : "media",
            metadata: nil,
            mediaRefs: refs,
            linkPreviews: nil,
            blocks: nil
        )))

        repliesWritten += 1
        let turnId = "fixture-turn-\(repliesWritten)"
        emit(.turnStarted(profileId: CompanionProtocol.profileId, turnId: turnId, inReplyTo: clientMsgId))
        emit(.textDelta(turnId: turnId, text: FixtureCompanionScript.replyOpening))

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyDelay) { [weak self] in
            self?.finish(turnId, replyingTo: clientMsgId)
        }
    }

    /// Holds a handed-over file a moment later, as the engine does: kept
    /// under its digest, out of the inbox.
    private func hold(file event: [String: Any]) {
        let attachId = event["attach_id"] as? String ?? ""
        let sha256 = event["sha256"] as? String ?? ""
        let name = event["name"] as? String
        let handed = inbox.appending(path: attachId)
        let kept = inbox.appending(path: "held").appending(path: sha256 + "." + ((name as NSString?)?.pathExtension ?? "bin"))
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.moveItem(at: handed, to: kept)
        attached[attachId] = CompanionMediaRef(
            ref: sha256,
            kind: event["kind"] as? String ?? "file",
            mime: event["mime"] as? String ?? "application/octet-stream",
            sizeBytes: event["size_bytes"] as? Int ?? 0,
            sha256: sha256,
            filename: name,
            caption: nil
        )
        attachedFiles[sha256] = kept.path
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachDelay) { [weak self] in
            self?.emit(.attachStatus(attachId: attachId, status: .present))
        }
    }

    /// A held file's copy, granted as the engine grants one.
    private func attachedGrant(ref: String) -> CompanionServerEvent? {
        guard let path = attachedFiles[ref], let held = attached.values.first(where: { $0.ref == ref }) else { return nil }

        return .mediaPath(CompanionMediaPath(
            ref: ref,
            path: path,
            kind: held.kind,
            mime: held.mime,
            sizeBytes: held.sizeBytes,
            sha256: ref
        ))
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

    /// A proposal's answer is accepted at once and resolved a moment later,
    /// so a confirm is seen running before the tool's answer arrives.
    private func decide(proposal event: [String: Any]) {
        let clientMsgId = event["client_msg_id"] as? String ?? ""
        let proposalId = event["proposal_id"] as? String ?? ""
        let confirmed = event["decision"] as? String == CompanionProposalDecision.confirm.rawValue
        emit(.accepted(CompanionAccepted(clientMsgId: clientMsgId, duplicate: false, serverSeq: nil)))

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyDelay) { [weak self] in
            self?.emit(confirmed ? FixtureProposalScript.confirmed(proposalId) : FixtureProposalScript.denied(proposalId))
        }
    }

    /// A pull of one list: the list, held from then on, or the engine's
    /// refusal for one it has no list for.
    private func pull(list event: [String: Any]) {
        let listId = event["list_id"] as? String ?? ""
        let removed = event["removed"] as? Bool == true
        guard let list = lists.list(listId, removed: removed) else {
            emit(.error(Self.refusal(FixtureChecklists.missingList, clientMsgId: nil)))
            return
        }

        held.removeAll { $0 == listId }
        held.append(listId)
        if removed { heldWithRemoved.insert(listId) } else { heldWithRemoved.remove(listId) }
        emit(.checklist(profileId: CompanionProtocol.profileId, list: list))
    }

    /// An edit is accepted once applied, and each list it changed that this
    /// connection holds is pushed when the window ends, with what it made,
    /// then the index. A create's list is held from then on.
    private func edit(list event: [String: Any]) {
        let clientMsgId = event["client_msg_id"] as? String ?? ""
        guard let op = (event["op"] as? [String: Any]).flatMap(CompanionChecklistOp.init(fixtureLine:)) else {
            preconditionFailure("the fixture daemon was sent an op it does not know")
        }

        switch lists.apply(op, to: event["list_id"] as? String) {
        case .failure(let refusal):
            emit(.error(Self.refusal(refusal.sentence, clientMsgId: clientMsgId)))
        case .success(let change):
            if case .create = op, let made = change.made { held.append(made) }
            emit(.accepted(CompanionAccepted(clientMsgId: clientMsgId, duplicate: false, serverSeq: nil)))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.listWindow) { [weak self] in
                self?.push(change.changed, made: change.made.map { [clientMsgId: $0] } ?? [:])
            }
        }
    }

    private func push(_ changed: [String], made: [String: String]) {
        for listId in held where changed.contains(listId) {
            guard let list = lists.list(listId, removed: heldWithRemoved.contains(listId)) else { continue }

            emit(.checklist(profileId: CompanionProtocol.profileId, list: list, made: made))
        }
        emit(.checklists(profileId: CompanionProtocol.profileId, lists: lists.index))
    }

    private static func refusal(_ sentence: String, clientMsgId: String?) -> CompanionServerError {
        CompanionServerError(
            reason: "request_failed",
            message: sentence,
            field: nil,
            event: nil,
            clientMsgId: clientMsgId,
            direction: nil,
            clientVersion: nil,
            minVersion: nil,
            maxVersion: nil,
            ref: nil
        )
    }

    /// The contract's own answer to a cancel: the turn ends as cancelled.
    private func stop(_ event: [String: Any]) {
        let clientMsgId = event["client_msg_id"] as? String ?? ""
        let turnId = clientMsgId == FixtureCompanionScript.askedLast
            ? FixtureCompanionScript.openingTurn
            : "fixture-turn-\(repliesWritten)"
        emit(.turnError(turnId: turnId, code: "cancelled", message: "cancelled"))
    }

    private func append(
        role: String,
        content: String,
        clientMsgId: String?,
        inReplyTo: String?,
        mediaRefs: [CompanionMediaRef] = []
    ) -> CompanionTimelineRow {
        let row = FixtureCompanionScript.row(head + 1, role, content, clientMsgId: clientMsgId, inReplyTo: inReplyTo, mediaRefs: mediaRefs)
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
        row(
            17,
            "assistant",
            "Friday has a slot at 9:30 with Dr Patel, at the practice on [example.com](https://example.com/). Shall I book it?",
            inReplyTo: "fixture-msg-16"
        ),
        row(18, "user", "Yes, book it.", clientMsgId: "fixture-msg-18"),
        row(19, "assistant", "Booked for Friday at 9:30. It is on your calendar with the address and a reminder the evening before.", inReplyTo: "fixture-msg-18"),
        row(20, "user", "Will it rain on Saturday? I want to plan the hike.", clientMsgId: askedLast),
    ]

    /// Live after the newest page: the reply to the last message, with a
    /// summary of its reasoning, the forecast lookup running in the engine's
    /// words, and an approval the agent is waiting on.
    static let opening: [CompanionServerEvent] = [
        .turnStarted(profileId: CompanionProtocol.profileId, turnId: openingTurn, inReplyTo: askedLast),
        .reasoning(
            turnId: openingTurn,
            text: "**Finding the trailhead's forecast**\n\nThe hike is on Saturday, so I need the hourly forecast near the trailhead rather than the city's."
        ),
        .textDelta(turnId: openingTurn, text: "Let me check the forecast for Saturday around the trailhead."),
        .toolEvent(CompanionToolEvent(turnId: openingTurn, tool: "web_search", phase: .start, detail: nil, activity: "Searching the web")),
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
        inReplyTo: String? = nil,
        linkPreviews: [CompanionLinkPreview]? = nil,
        blocks: [CompanionBlock]? = nil,
        mediaRefs: [CompanionMediaRef] = [],
        origin: CompanionRowOrigin? = nil
    ) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: role,
            content: content,
            kind: mediaRefs.isEmpty ? "text" : "media",
            timestamp: String(format: "2026-09-25T09:%02d:00Z", seq % 60),
            mediaRefs: mediaRefs,
            clientMsgId: clientMsgId,
            inReplyTo: inReplyTo,
            metadata: origin.map { ["origin": .object(["kind": .string($0.kind.rawValue), "name": .string($0.name)])] },
            linkPreviews: linkPreviews,
            blocks: blocks.map(CompanionBlocks.init)
        )
    }
}

/// The cue proposals the full timeline holds (M60 §4.7): one card in each
/// state, placed among the newest page's rows by when each was made. One was
/// confirmed and ran, with what the tool answered; one was denied, from a
/// task no watcher woke; one the daemon expired; one the daemon refused, its
/// item no longer kept; one this Mac's clock expired with no answer; and the
/// last still asks, its item long enough to be cut at twelve lines and
/// holding a Markdown link, an address and a phone number, all drawn as the
/// text they are. Answering it is accepted at once and resolved a moment
/// later.
enum FixtureProposalScript {
    static let waitingId = "fixture-proposal-waiting"
    static let tool = "github_create_issue"
    /// How long the waiting card asks, from the launch.
    static let asksFor: TimeInterval = 30 * 60

    static func opening(now: Date) -> [CompanionServerEvent] {
        let asking = now.addingTimeInterval(asksFor)
        let passed = now.addingTimeInterval(-60)

        return [
            card("fixture-proposal-confirmed", made: 12, until: passed),
            confirmed("fixture-proposal-confirmed"),
            card("fixture-proposal-denied", made: 14, until: passed, watcher: nil),
            denied("fixture-proposal-denied"),
            card("fixture-proposal-expired", made: 15, until: passed),
            resolved("fixture-proposal-expired", .expired, "That proposal expired; nothing ran."),
            card("fixture-proposal-refused", made: 16, until: passed, cue: nil),
            resolved("fixture-proposal-refused", .refused, "That proposal was refused; nothing ran. The mandate is switched off."),
            card("fixture-proposal-lapsed", made: 18, until: passed),
            card(waitingId, made: 19, until: asking, cue: longItem)
        ]
    }

    static func confirmed(_ proposalId: String) -> CompanionServerEvent {
        resolved(proposalId, .confirmed, "Confirmed. \(tool) ran.", result: issueCreated, status: "ok")
    }

    static func denied(_ proposalId: String) -> CompanionServerEvent {
        resolved(proposalId, .denied, "Denied. \(tool) will not run.")
    }

    private static func resolved(
        _ proposalId: String,
        _ state: CompanionProposalState,
        _ sentence: String,
        result: String? = nil,
        status: String? = nil
    ) -> CompanionServerEvent {
        .proposalResolved(CompanionProposalResolution(
            profileId: CompanionProtocol.profileId,
            proposalId: proposalId,
            state: state,
            resultStatus: status,
            sentence: sentence,
            resultText: result
        ))
    }

    /// A card made at 09:`minute`:30 on the full timeline's day, its item
    /// received half a minute before.
    private static func card(
        _ proposalId: String,
        made minute: Int,
        until expiresAt: Date,
        watcher: String? = "release-watch",
        cue: CompanionProposalCue? = shortItem
    ) -> CompanionServerEvent {
        .proposal(profileId: CompanionProtocol.profileId, proposal: CompanionProposal(
            proposalId: proposalId,
            state: .waiting,
            ask: .call(mandate: "release-issues", tool: tool),
            task: CompanionProposalTask(jobId: "fixture-job-release-watch", name: "Release watch"),
            watcher: watcher,
            sourceRef: "eng-blogs",
            createdAt: String(format: "2026-09-25T09:%02d:30Z", minute),
            expiresAt: expiresAt.formatted(.iso8601),
            receivedAt: String(format: "2026-09-25T09:%02d:00Z", minute),
            decidedAt: nil,
            decidedFrom: nil,
            resultStatus: nil,
            statusSentence: "Waiting for your answer; it runs only if you confirm.",
            summary: "A task wants to run \(tool) under your mandate release-issues. It runs only if you confirm.",
            outside: CompanionProposalOutside(argsText: arguments, args: nil, reason: nil, cue: cue)
        ))
    }

    private static let arguments = """
        {
          "owner": "example-org",
          "repo": "ops",
          "title": "Lantern 4.2 security advisory"
        }
        """

    private static let issueCreated = """
        {
          "number": 4127,
          "url": "https://tracker.example/example-org/ops/issues/4127"
        }
        """

    private static let shortItem = CompanionProposalCue(
        type: "feed.item",
        subject: nil,
        text: "Lantern 4.2 security advisory: upgrade before Friday.",
        occurredAt: "2026-09-25T08:58:00Z"
    )

    private static let longItem = CompanionProposalCue(
        type: "feed.item",
        subject: "Lantern 4.2",
        text: """
            Lantern 4.2 security advisory

            A flaw in the session store lets a crafted cookie read another visitor's session.
            Every release from 4.0 to 4.2.1 is affected. Read [the full notice](https://login.example/notice) before you upgrade.

            What to do:
            1. Upgrade to 4.2.2, published at https://lantern.example/releases/4.2.2
            2. Rotate the session signing key.
            3. Clear the session table.

            Questions go to the security desk on +1 555 0142, weekdays from nine.
            The maintainers thank the two people who reported it.
            A second advisory for the 3.x line follows next week.
            """,
        occurredAt: "2026-09-25T08:58:00Z"
    )
}

/// What the replies timeline holds (M72): seven questions, each answered in
/// the shape its answer takes. Places in SoHo with the engine's block of
/// them, one place with every field and the others each missing one, the
/// last with a long name; then a list and steps, a table, and a quote, which
/// are the reply's own markdown; then places Apple Maps found around a named
/// town (§14.1), each with Apple's own identifier and page and its kind, and
/// no rating, price, hours or distance; then a reply linking pages the
/// engine previewed; code, a shell one-liner too long for one line of the
/// reply and a short Python function, each fence naming its language by a
/// common tag; and last, a scheduled job's message and a cue's, the cue
/// named by the watcher the management goldens list.
enum FixtureRepliesScript {
    static let rows: [CompanionTimelineRow] = [
        FixtureCompanionScript.row(1, "user", "Can you find a few quiet coffee shops in SoHo where I could work for an hour?", clientMsgId: "fixture-replies-1"),
        FixtureCompanionScript.row(2, "assistant", places, inReplyTo: "fixture-replies-1", blocks: [.places(placeRecords)]),
        FixtureCompanionScript.row(3, "user", "What should I pack for the hike on Saturday?", clientMsgId: "fixture-replies-3"),
        FixtureCompanionScript.row(4, "assistant", lists, inReplyTo: "fixture-replies-3"),
        FixtureCompanionScript.row(5, "user", "Compare the three flights to Lisbon for me.", clientMsgId: "fixture-replies-5"),
        FixtureCompanionScript.row(6, "assistant", table, inReplyTo: "fixture-replies-5"),
        FixtureCompanionScript.row(7, "user", "What did Priya say about the launch in her last email?", clientMsgId: "fixture-replies-7"),
        FixtureCompanionScript.row(8, "assistant", quote, inReplyTo: "fixture-replies-7"),
        FixtureCompanionScript.row(9, "user", "Where can I get tacos around Suwanee Town Center?", clientMsgId: "fixture-replies-9"),
        FixtureCompanionScript.row(10, "assistant", applePlaces, inReplyTo: "fixture-replies-9", blocks: [.places(applePlaceRecords)]),
        FixtureCompanionScript.row(11, "user", "Any good guides on growing sunflowers and dahlias this spring?", clientMsgId: "fixture-replies-11"),
        FixtureCompanionScript.row(12, "assistant", links, inReplyTo: "fixture-replies-11", linkPreviews: linkPreviews),
        FixtureCompanionScript.row(13, "user", "How do I find the biggest files in my Downloads folder?", clientMsgId: "fixture-replies-13"),
        FixtureCompanionScript.row(14, "assistant", code, inReplyTo: "fixture-replies-13"),
        FixtureCompanionScript.row(15, "assistant", briefing, origin: CompanionRowOrigin(kind: .job, name: "Morning briefing")),
        FixtureCompanionScript.row(16, "assistant", release, origin: CompanionRowOrigin(kind: .cue, name: "release-watch")),
    ]

    /// A one-liner wider than the reply, which wraps, and a short function,
    /// fenced as `sh` and `python`, which the blocks name Shell and Python.
    /// A scheduled job's delivery and a cue's, each with no message of the
    /// owner's before it, under the label naming where it came from.
    static let briefing = """
        **Good morning.** It is 12° and cloudy, with rain from about three.

        - Design review at **10:00**, the prep doc is in *Shared/Design*
        - Lunch with Sam at 13:00
        """

    static let release = "The release you are watching is out. Its notes list faster history search and a fix for the reminder sound."

    static let code = """
        This lists the twenty largest files under Downloads, biggest first, and saves the list to your Desktop.

        ```sh
        find ~/Downloads -type f -size +10M -exec du -h {} + 2>/dev/null | sort -rh | head -n 20 | sed "s|$HOME|~|" | tee ~/Desktop/largest-downloads.txt
        ```

        If you would rather stay in Python, this does the same and skips anything it cannot read.

        ```python
        from pathlib import Path


        def largest(folder, count=20):
            # Every file under the folder with its size, biggest first.
            sizes = []
            for path in Path(folder).expanduser().rglob("*"):
                try:
                    if path.is_file():
                        sizes.append((path.stat().st_size, path))
                except OSError:
                    continue
            return sorted(sizes, reverse=True)[:count]


        for size, path in largest("~/Downloads"):
            print(f"{size / 1_000_000:8.1f} MB  {path}")
        ```
        """

    /// Four pages the reply links, as the engine previews them: two with a
    /// picture, one whose page gave none, and the last with no preview at
    /// all, as a page the engine could not read is left.
    static let links = """
        Three good reads before you plant, and a seed list to start from.

        - [Sunflowers from seed](https://gardennotes.example/grow/sunflowers) covers sowing dates, spacing and staking.
        - [Dahlias for beginners](https://bloomandroot.example/guides/dahlias-for-beginners) explains tubers and when to lift them.
        - [A cutting garden in one bed](https://weekendplot.example/2026/03/cutting-garden-in-one-bed) fits both into a small space.
        - The [spring seed list](https://seedswap.example/lists/spring-seeds) has both in stock.

        Start the sunflowers indoors about three weeks before your last frost, which the county lists at https://extension.example/frost-dates. The swap's newsletter also links an order form as [seedswap.example/order](https://seedswap-orders.example/checkout), which is a different site, so check it before you pay.
        """

    static let linkPreviews: [CompanionLinkPreview] = [
        CompanionLinkPreview(
            link: "https://gardennotes.example/grow/sunflowers",
            url: "https://gardennotes.example/grow/sunflowers",
            site: "Garden Notes",
            title: "How to grow sunflowers from seed, from sowing to staking",
            description: "When to sow, how far apart, and how to keep tall stems standing.",
            imageRef: sunflowerPicture
        ),
        CompanionLinkPreview(
            link: "https://bloomandroot.example/guides/dahlias-for-beginners",
            url: "https://bloomandroot.example/guides/dahlias-for-beginners",
            site: "Bloom and Root",
            title: "Dahlias for beginners",
            description: "Tubers, spacing, and when to lift them before the first frost.",
            imageRef: dahliaPicture
        ),
        CompanionLinkPreview(
            link: "https://weekendplot.example/2026/03/cutting-garden-in-one-bed",
            url: "https://weekendplot.example/2026/03/cutting-garden-in-one-bed",
            site: "Weekend Plot",
            title: "A cutting garden in one bed",
            description: nil,
            imageRef: nil
        ),
    ]

    static let sunflowerPicture = "fba54ed7dccc3de7aefa463fe159b5b315a38c452f51bf526aa9ac3222ade744"
    static let dahliaPicture = "d08cccaf4c5bf5dbceb48adb1807de2698ccc1cebd82c4e7a09c90ba3d37cdb5"

    /// Each picture's file: a sample photo macOS keeps for account pictures.
    static let pictures = [
        sunflowerPicture: "/Library/User Pictures/Flowers/Sunflower.heic",
        dahliaPicture: "/Library/User Pictures/Flowers/Dahlia.heic",
    ]

    /// A short lead and one line per place, each linked by name, in the order
    /// the block holds them.
    static let places = """
        Here are four quiet places within a short walk, with seats and steady wifi.

        - [Little Wooster Espresso Bar](https://littlewooster.example/) is small but calm before noon.
        - [Mercer Roasting Room](https://mercerroasting.example/) has long tables at the back, away from the counter.
        - [Spring and Thompson](https://places.example/p/spring-and-thompson) is quiet in the afternoon, with outlets along the wall.
        - [The Reading Room at Broome Street Books and Coffee](https://broomestreetbooks.example/reading-room) asks for low voices, so it stays hushed.

        Hours and ratings change, so check before you go.
        """

    static let placeRecords: [CompanionPlace] = [
        CompanionPlace(
            name: "Little Wooster Espresso Bar",
            canonicalURL: "https://littlewooster.example/",
            sourceURL: "https://places.example/p/little-wooster-espresso-bar",
            applePlaceID: nil,
            location: CompanionPlaceLocation(latitude: 40.7239, longitude: -74.0011),
            address: "88 Wooster St, New York, NY 10012",
            rating: CompanionPlaceRating(value: 4.4, best: 5, count: 87),
            priceRange: "$$",
            categories: ["espresso_bar"],
            openingHours: nil,
            distance: CompanionPlaceDistance(value: 0.3, units: "km")
        ),
        CompanionPlace(
            name: "Mercer Roasting Room",
            canonicalURL: "https://mercerroasting.example/",
            sourceURL: "https://places.example/p/mercer-roasting-room",
            applePlaceID: nil,
            location: CompanionPlaceLocation(latitude: 40.7247, longitude: -73.9986),
            address: "112 Mercer St, New York, NY 10012",
            rating: CompanionPlaceRating(value: 4.6, best: 5, count: 321),
            priceRange: "$$",
            categories: ["coffee_shop", "bakery"],
            openingHours: CompanionPlaceHours(currentDay: "Thursday 07:00-19:00"),
            distance: CompanionPlaceDistance(value: 0.4, units: "km")
        ),
        CompanionPlace(
            name: "Spring and Thompson",
            canonicalURL: nil,
            sourceURL: "https://places.example/p/spring-and-thompson",
            applePlaceID: nil,
            location: CompanionPlaceLocation(latitude: 40.7255, longitude: -74.0023),
            address: "201 Spring St, New York, NY 10012",
            rating: nil,
            priceRange: "$",
            categories: ["cafe"],
            openingHours: CompanionPlaceHours(currentDay: "Thursday 08:00-18:00"),
            distance: CompanionPlaceDistance(value: 0.6, units: "km")
        ),
        CompanionPlace(
            name: "The Reading Room at Broome Street Books and Coffee",
            canonicalURL: "https://broomestreetbooks.example/reading-room",
            sourceURL: "https://places.example/p/broome-street-books",
            applePlaceID: nil,
            location: CompanionPlaceLocation(latitude: 40.7226, longitude: -74.0004),
            address: "421 Broome St, New York, NY 10013",
            rating: CompanionPlaceRating(value: 4.8, best: 5, count: 1204),
            priceRange: "$$",
            categories: ["book_store"],
            openingHours: CompanionPlaceHours(currentDay: "Thursday 09:00-21:00"),
            distance: CompanionPlaceDistance(value: 0.8, units: "km")
        ),
    ]

    /// Apple Maps' places, the first linked by its own website and the other
    /// two by Apple's own page for them, as the model writes whichever link
    /// the search gave it.
    static let applePlaces = """
        Three taquerias within a few minutes of Town Center.

        - [Tequila Mama Taqueria](https://tequilamama.com/) is on Town Center Avenue, facing the park, with its [menu](https://tequilamama.com/menu) online.
        - [Beto's Tacos](https://maps.apple.com/place?place-id=I47957D91CD7E2F7B) is a short drive south on Lawrenceville-Suwanee Road.
        - [A Tacoria](https://maps.apple.com/place?place-id=I89FC92F8D04D97C5) is a few minutes north-west, on Peachtree Industrial Boulevard.

        Maps has their hours and photos.
        """

    /// Real places, by the identifiers Apple Maps gave them, so a card opens
    /// each one's own card in Maps. The second's website is plain HTTP, which
    /// the engine drops, and the third gave none of its own.
    static let applePlaceRecords: [CompanionPlace] = [
        CompanionPlace(
            name: "Tequila Mama Taqueria",
            canonicalURL: "https://tequilamama.com/",
            sourceURL: "https://maps.apple.com/place?place-id=I15D3EC7F56AE8D5C",
            applePlaceID: "I15D3EC7F56AE8D5C",
            location: CompanionPlaceLocation(latitude: 34.0555026, longitude: -84.0647238),
            address: "340 Town Center Ave, Suwanee, GA 30024, United States",
            rating: nil,
            priceRange: nil,
            categories: ["restaurant"],
            openingHours: nil,
            distance: nil
        ),
        CompanionPlace(
            name: "Beto's Tacos",
            canonicalURL: nil,
            sourceURL: "https://maps.apple.com/place?place-id=I47957D91CD7E2F7B",
            applePlaceID: "I47957D91CD7E2F7B",
            location: CompanionPlaceLocation(latitude: 34.043542, longitude: -84.0541653),
            address: "3463 Lawrenceville-Suwanee Rd, Unit 110, Suwanee, GA 30024, United States",
            rating: nil,
            priceRange: nil,
            categories: ["restaurant"],
            openingHours: nil,
            distance: nil
        ),
        CompanionPlace(
            name: "A Tacoria",
            canonicalURL: nil,
            sourceURL: "https://maps.apple.com/place?place-id=I89FC92F8D04D97C5",
            applePlaceID: "I89FC92F8D04D97C5",
            location: CompanionPlaceLocation(latitude: 34.0666864, longitude: -84.0718644),
            address: "315 Peachtree Industrial Blvd, Suwanee, GA 30024, United States",
            rating: nil,
            priceRange: nil,
            categories: ["restaurant"],
            openingHours: nil,
            distance: nil
        ),
    ]

    static let lists = """
        For a day hike this time of year, pack light and in layers.

        - Water, at least two litres
        - A warm layer and a rain shell
        - Snacks that will not melt
        - A charged phone and a paper map

        Before you set off:

        1. Check the forecast for the trailhead, not the town.
        2. Tell someone your route and when you expect to be back.
        3. Start early, so you finish in daylight.
        """

    static let table = """
        Here are the three options, cheapest first.

        | Flight | Departs | Arrives | Price |
        | --- | --- | --- | --- |
        | TP 202 | 08:10 | 20:35 | $412 |
        | UA 66 | 17:55 | 06:20 next day | $468 |
        | DL 260 | 19:30 | 08:15 next day | $503 |

        The first is the only one that lands the same day.
        """

    static let quote = """
        She wrote:

        > The release notes are ready for review. If nobody objects by Wednesday, we ship on the 14th as planned.

        Nobody has objected so far.
        """
}
#endif
