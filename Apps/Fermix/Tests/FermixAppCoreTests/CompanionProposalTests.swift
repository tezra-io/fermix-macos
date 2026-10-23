import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents

/// Proposal lines as the daemon writes them at companion version 4 (M60 §3.7).
/// The vendored goldens are version 3 until the engine's version 4 is
/// re-vendored, so these lines are built from the spec's shapes.
enum ProposalLines {
    static let summary = "A task wants to run issue_create under your mandate release-issues. It runs only if you confirm."
    static let args = "{\n  \"owner\": \"example-org\",\n  \"repo\": \"ops\",\n  \"title\": \"Lantern security advisory\"\n}"
    /// An item whose text holds a Markdown link, a bare URL and a phone number.
    static let itemText = "Lantern advisory: read [the notice](https://login.example/steal) at https://advisories.example/ln-77 or call +1 555 0142."
    /// What a confirmed call's tool answered.
    static let result = "{\n  \"number\": 4127,\n  \"url\": \"https://tracker.example/example-org/ops/4127\"\n}"

    /// A card as the engine writes it: a field that does not apply is
    /// absent, never null.
    static func cardObject(
        _ id: String = "prop_01",
        state: String = "waiting",
        created: String = "2026-10-22T14:02:30Z",
        expires: String = "2026-10-22T14:32:30Z",
        taskName: String? = "Release watch",
        watcher: String? = "release-watch",
        source: String? = "eng-blogs",
        cue: [String: Any]? = cueObject()
    ) -> [String: Any] {
        present([
            "proposal_id": id,
            "state": state,
            "mandate": "release-issues",
            "task": present(["job_id": "job_7f3a", "name": taskName]),
            "watcher": watcher,
            "source_ref": source,
            "tool": "issue_create",
            "created_at": created,
            "expires_at": expires,
            "received_at": "2026-10-22T14:02:00Z",
            "status_sentence": "Waiting for your answer; it runs only if you confirm.",
            "summary": summary,
            "outside": present(["args_text": args, "cue": cue])
        ])
    }

    static func cueObject(subject: String? = nil, occurredAt: String? = "2026-10-22T13:58:00Z") -> [String: Any] {
        present(["type": "feed.item", "subject": subject, "text": itemText, "occurred_at": occurredAt])
    }

    static func present(_ fields: [String: Any?]) -> [String: Any] {
        fields.compactMapValues { $0 }
    }

    static func eventObject(_ card: [String: Any] = cardObject()) -> [String: Any] {
        ["type": "proposal", "profile_id": "main", "proposal": card]
    }

    static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A proposal event, decoded as the session would decode it.
    static func event(_ card: [String: Any] = cardObject()) throws -> CompanionServerEvent {
        try CompanionServerEvent.decode(line(eventObject(card)))
    }

    static func proposal(_ card: [String: Any] = cardObject()) throws -> CompanionProposal {
        guard case .proposal(_, let proposal) = try event(card) else {
            throw CompanionFixtureDefect.recordHasNoType(file: "proposal", line: 0)
        }
        return proposal
    }

    static func resolved(
        _ id: String = "prop_01",
        state: CompanionProposalState = .confirmed,
        sentence: String = "Confirmed. issue_create ran.",
        resultText: String? = result
    ) -> CompanionServerEvent {
        .proposalResolved(
            CompanionProposalResolution(
                profileId: "main",
                proposalId: id,
                state: state,
                resultStatus: resultText == nil ? nil : "ok",
                sentence: sentence,
                resultText: resultText
            )
        )
    }
}

private extension CompanionChat {
    @discardableResult
    mutating func receive(_ event: CompanionServerEvent) -> [CompanionClientEvent] {
        CompanionReducer.receive(event, into: &self)
    }

    @discardableResult
    mutating func answer(_ id: String, _ decision: CompanionProposalDecision, as clientMsgId: String = "mac-1")
        -> [CompanionClientEvent] {
        CompanionReducer.answer(proposal: id, decision, clientMsgId: clientMsgId, into: &self)
    }

    func card(_ id: String) -> CompanionProposalCard? {
        proposals.first { $0.id == id }
    }

    /// A chat that has said hello and holds the proposals the daemon sent.
    static func holding(_ cards: [[String: Any]]) throws -> CompanionChat {
        var chat = CompanionChat()
        _ = CompanionReducer.negotiated(&chat, onScreen: [])
        for card in cards {
            chat.receive(try ProposalLines.event(card))
        }
        return chat
    }
}

private let proposalAnswerKeys: Set<String> = ["type", "client_msg_id", "profile_id", "proposal_id", "decision"]

private func moment(_ value: String) throws -> Date {
    try #require(CompanionTime.date(value))
}

// MARK: - The wire

@Suite("Companion proposals: the wire")
struct CompanionProposalWireTests {
    @Test("this build speaks version 4 on the 3 to 4 window, the version that carries proposals")
    func declaresVersionFour() {
        #expect(CompanionProtocol.version == 4)
        #expect(CompanionProtocol.supportedWindow == CompanionVersionWindow(minimum: 3, maximum: 4))
    }

    @Test("a proposal decodes under the Swift names and writes back as itself")
    func proposalRoundTrips() throws {
        let object = ProposalLines.eventObject()
        let event = try CompanionServerEvent.decode(ProposalLines.line(object))
        guard case .proposal(let profileId, let proposal) = event else {
            Issue.record("the proposal did not decode as a proposal")
            return
        }

        #expect(event.wireType == "proposal")
        #expect(!event.isUnrecognized)
        #expect(profileId == "main")
        #expect(proposal.proposalId == "prop_01")
        #expect(proposal.state == .waiting)
        #expect(proposal.task == CompanionProposalTask(jobId: "job_7f3a", name: "Release watch"))
        #expect(proposal.watcher == "release-watch")
        #expect(proposal.sourceRef == "eng-blogs")
        #expect(proposal.outside.argsText == ProposalLines.args)
        #expect(proposal.outside.cue?.text == ProposalLines.itemText)
        #expect(proposal.outside.cue?.subject == nil)
        #expect(CompanionServerWire.object(event) as NSDictionary == object as NSDictionary)
    }

    @Test("a card with no task name, watcher, source or cue decodes, as one Fermix no longer keeps the item of")
    func optionalFields() throws {
        let proposal = try ProposalLines.proposal(
            ProposalLines.cardObject(taskName: nil, watcher: nil, source: nil, cue: nil)
        )

        #expect(proposal.task == CompanionProposalTask(jobId: "job_7f3a", name: nil))
        #expect(proposal.watcher == nil)
        #expect(proposal.sourceRef == nil)
        #expect(proposal.outside.cue == nil)
        #expect(proposal.statusSentence == "Waiting for your answer; it runs only if you confirm.")

        let subject = try ProposalLines.proposal(
            ProposalLines.cardObject(cue: ProposalLines.cueObject(subject: "Lantern 4.2", occurredAt: nil))
        )
        #expect(subject.outside.cue?.subject == "Lantern 4.2")
        #expect(subject.outside.cue?.occurredAt == nil)
    }

    @Test("a proposal state this build does not know keeps its own word")
    func unknownStateIsKept() throws {
        let proposal = try ProposalLines.proposal(ProposalLines.cardObject(state: "withdrawn"))

        #expect(proposal.state == .unrecognized("withdrawn"))
    }

    /// M60 §3.7 draws the optional fields as null; the engine leaves them
    /// out. Both are the same card.
    @Test("a card written with nulls decodes as the same card with those keys absent")
    func nullsAreAbsence() throws {
        var nulls = ProposalLines.cardObject(watcher: nil, source: nil, cue: nil)
        nulls["watcher"] = NSNull()
        nulls["source_ref"] = NSNull()
        nulls["outside"] = ["args_text": ProposalLines.args, "cue": NSNull()] as [String: Any]

        #expect(
            try ProposalLines.proposal(nulls)
                == ProposalLines.proposal(ProposalLines.cardObject(watcher: nil, source: nil, cue: nil))
        )
    }

    @Test("a card missing its arguments is refused by the field's path")
    func missingArgumentsAreRefused() throws {
        var card = ProposalLines.cardObject()
        card["outside"] = ["cue": ProposalLines.cueObject()]

        #expect(throws: CompanionDecodeFailure.missingField("proposal.outside.args_text")) {
            _ = try CompanionServerEvent.decode(ProposalLines.line(ProposalLines.eventObject(card)))
        }
    }

    @Test("a resolution decodes with its result and without it, and writes back as itself")
    func resolutionRoundTrips() throws {
        let full: [String: Any] = [
            "type": "proposal_resolved", "profile_id": "main", "proposal_id": "prop_01", "state": "confirmed",
            "result_status": "ok", "sentence": "Confirmed. issue_create ran.", "result_text": ProposalLines.result
        ]
        let bare: [String: Any] = [
            "type": "proposal_resolved", "profile_id": "main", "proposal_id": "prop_02", "state": "denied",
            "sentence": "Denied. issue_create will not run."
        ]

        for object in [full, bare] {
            let event = try CompanionServerEvent.decode(ProposalLines.line(object))

            #expect(event.wireType == "proposal_resolved")
            #expect(CompanionServerWire.object(event) as NSDictionary == object as NSDictionary)
        }
        #expect(
            try CompanionServerEvent.decode(ProposalLines.line(bare))
                == ProposalLines.resolved("prop_02", state: .denied, sentence: "Denied. issue_create will not run.", resultText: nil)
        )
    }

    /// M60 §5.2: the app confirms exactly the recorded call. Never arguments,
    /// never a token, never a value it edited.
    @Test("a proposal answer carries the request, the profile, the id and the word, and nothing else")
    func answerCarriesOnlyIdAndDecision() throws {
        for decision in [CompanionProposalDecision.confirm, .deny] {
            let event = CompanionClientEvent.proposalAnswer(
                clientMsgId: "mac-1", profileId: "main", proposalId: "prop_01", decision: decision
            )
            let object = try wireObject(companion: event)

            #expect(Set(object.allKeys.compactMap { $0 as? String }) == proposalAnswerKeys)
            #expect(object["type"] as? String == "proposal_answer")
            #expect(object["proposal_id"] as? String == "prop_01")
            #expect(object["decision"] as? String == decision.rawValue)
        }
    }
}

// MARK: - The chat

@Suite("Companion proposals: the chat")
struct CompanionProposalChatTests {
    @Test("a proposal is held by its id, and one sent again is held once")
    func heldOnceById() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject(), ProposalLines.cardObject("prop_02")])
        chat.receive(try ProposalLines.event())

        #expect(chat.proposals.map(\.id) == ["prop_01", "prop_02"])
        #expect(chat.proposals.allSatisfy { $0.standing == .open && $0.awaitsDecision })
    }

    @Test("an answer goes into the outbox carrying only the id and the word, and both buttons wait")
    func answerDisablesBothButtons() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject()])

        let sent = chat.answer("prop_01", .confirm)

        let line = try wireObject(companion: try #require(sent.first))

        #expect(sent == [.proposalAnswer(clientMsgId: "mac-1", profileId: "main", proposalId: "prop_01", decision: .confirm)])
        #expect(Set(line.allKeys.compactMap { $0 as? String }) == proposalAnswerKeys)
        #expect(chat.pending.map(\.request) == [.proposalAnswer(proposalId: "prop_01", decision: .confirm)])
        #expect(chat.card("prop_01")?.standing == .answered(.confirm))
        #expect(chat.card("prop_01")?.awaitsDecision == false)
    }

    @Test("a card answered once is never answered again")
    func answeredOnce() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject()])
        chat.answer("prop_01", .deny)

        #expect(chat.answer("prop_01", .confirm, as: "mac-2").isEmpty)
        #expect(chat.pending.count == 1)
        #expect(chat.card("prop_01")?.standing == .answered(.deny))
    }

    @Test("a card the daemon does not say waits, in a word it knows or one it does not, draws no button and takes no answer")
    func onlyAWaitingCardIsAnswered() throws {
        var chat = try CompanionChat.holding([
            ProposalLines.cardObject("prop_01", state: "confirmed"),
            ProposalLines.cardObject("prop_02", state: "withdrawn")
        ])

        #expect(chat.proposals.allSatisfy { !$0.awaitsDecision })
        #expect(chat.answer("prop_01", .confirm).isEmpty)
        #expect(chat.answer("prop_02", .confirm).isEmpty)
        #expect(chat.answer("prop_unknown", .confirm).isEmpty)
        #expect(chat.pending.isEmpty)
    }

    @Test("accepted takes the answer out of the outbox and leaves the card waiting for the daemon")
    func acceptedKeepsTheCardAnswered() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject()])
        chat.answer("prop_01", .confirm)

        chat.receive(E.accepted("mac-1", duplicate: false))

        #expect(chat.pending.isEmpty)
        #expect(chat.card("prop_01")?.standing == .answered(.confirm))
    }

    @Test("the daemon's resolution replaces the buttons with its sentence and what the tool answered")
    func resolutionReplacesTheButtons() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject(), ProposalLines.cardObject("prop_02")])
        chat.answer("prop_01", .confirm)

        chat.receive(ProposalLines.resolved())
        chat.receive(ProposalLines.resolved("prop_02", state: .denied, sentence: "Denied. issue_create will not run.", resultText: nil))

        #expect(chat.card("prop_01")?.standing == .resolved(sentence: "Confirmed. issue_create ran.", resultText: ProposalLines.result))
        #expect(chat.card("prop_02")?.standing == .resolved(sentence: "Denied. issue_create will not run.", resultText: nil))
        #expect(chat.proposals.allSatisfy { !$0.awaitsDecision })
    }

    @Test("a resolution for a card not held changes nothing")
    func resolutionForAnUnknownCard() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject()])

        chat.receive(ProposalLines.resolved("prop_elsewhere"))

        #expect(chat.proposals.map(\.id) == ["prop_01"])
        #expect(chat.card("prop_01")?.standing == .open)
    }

    /// M60 §4.7: a card decided elsewhere, on the phone or in a direct chat,
    /// is not answered twice, and a card the daemon sends again is never
    /// doubled.
    @Test("a handshake drops every card not resolved, keeps the resolved, and holds the daemon's resend once")
    func handshakeDropsWaitingCards() throws {
        var chat = try CompanionChat.holding([
            ProposalLines.cardObject("prop_open"),
            ProposalLines.cardObject("prop_answered"),
            ProposalLines.cardObject("prop_expired", expires: "2026-10-22T14:03:00Z"),
            ProposalLines.cardObject("prop_resolved")
        ])
        chat.answer("prop_answered", .deny)
        CompanionReducer.expire(at: try moment("2026-10-22T14:05:00Z"), in: &chat)
        chat.receive(ProposalLines.resolved("prop_resolved"))

        CompanionReducer.disconnected(&chat)
        _ = CompanionReducer.negotiated(&chat, onScreen: [])

        #expect(chat.proposals.map(\.id) == ["prop_resolved"])

        chat.receive(try ProposalLines.event(ProposalLines.cardObject("prop_open")))
        chat.receive(try ProposalLines.event(ProposalLines.cardObject("prop_open")))

        #expect(chat.proposals.map(\.id) == ["prop_resolved", "prop_open"])
        #expect(chat.card("prop_open")?.standing == .open)
    }

    @Test("a card sent again while its answer still waits in the outbox stays answered")
    func resendWithAnAnswerInTheOutbox() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject()])
        chat.answer("prop_01", .confirm)
        CompanionReducer.disconnected(&chat)

        let resent = CompanionReducer.negotiated(&chat, onScreen: [])
        chat.receive(try ProposalLines.event())

        #expect(resent.contains(.proposalAnswer(clientMsgId: "mac-1", profileId: "main", proposalId: "prop_01", decision: .confirm)))
        #expect(chat.card("prop_01")?.standing == .answered(.confirm))
        #expect(chat.answer("prop_01", .confirm, as: "mac-2").isEmpty)
    }

    @Test("a refused answer shows the daemon's sentence on its card, not as the chat's failure")
    func refusedAnswerSaysWhyOnTheCard() throws {
        var chat = try CompanionChat.holding([ProposalLines.cardObject()])
        chat.answer("prop_01", .confirm)

        chat.receive(.error(CompanionServerError(
            reason: "request_failed",
            message: "That proposal expired; nothing ran.",
            field: nil,
            event: nil,
            clientMsgId: "mac-1",
            direction: nil,
            clientVersion: nil,
            minVersion: nil,
            maxVersion: nil,
            ref: nil
        )))

        #expect(chat.pending.isEmpty)
        #expect(chat.lastError == nil)
        #expect(chat.card("prop_01")?.standing == .resolved(sentence: "That proposal expired; nothing ran.", resultText: nil))
    }

    @Test("a card expires on this Mac's clock, and only one nobody answered")
    func expiryOnItsOwnClock() throws {
        var chat = try CompanionChat.holding([
            ProposalLines.cardObject("prop_open", expires: "2026-10-22T14:32:30Z"),
            ProposalLines.cardObject("prop_answered", expires: "2026-10-22T14:32:30Z"),
            ProposalLines.cardObject("prop_later", expires: "2026-10-22T15:00:00Z")
        ])
        chat.answer("prop_answered", .confirm)

        CompanionReducer.expire(at: try moment("2026-10-22T14:32:29Z"), in: &chat)
        #expect(chat.card("prop_open")?.standing == .open)

        CompanionReducer.expire(at: try moment("2026-10-22T14:32:30Z"), in: &chat)
        #expect(chat.card("prop_open")?.standing == .expired)
        #expect(chat.card("prop_answered")?.standing == .answered(.confirm))
        #expect(chat.card("prop_later")?.standing == .open)
        #expect(chat.answer("prop_open", .confirm, as: "mac-2").isEmpty)

        chat.receive(ProposalLines.resolved("prop_open", state: .expired, sentence: "That proposal expired; nothing ran.", resultText: nil))
        #expect(chat.card("prop_open")?.standing == .resolved(sentence: "That proposal expired; nothing ran.", resultText: nil))
    }

    @Test("the next expiry is the soonest of the cards still asking")
    func nextExpiry() throws {
        var chat = try CompanionChat.holding([
            ProposalLines.cardObject("prop_late", expires: "2026-10-22T15:00:00Z"),
            ProposalLines.cardObject("prop_soon", expires: "2026-10-22T14:10:00Z"),
            ProposalLines.cardObject("prop_unreadable", expires: "soon")
        ])

        let soon = try moment("2026-10-22T14:10:00Z")
        let late = try moment("2026-10-22T15:00:00Z")

        #expect(CompanionReducer.nextExpiry(of: chat) == soon)

        chat.answer("prop_soon", .deny)
        #expect(CompanionReducer.nextExpiry(of: chat) == late)
    }

    @Test("the proposals waiting are the cards that ask, oldest first by when each was made")
    func waitingOldestFirst() throws {
        var chat = try CompanionChat.holding([
            ProposalLines.cardObject("prop_new", created: "2026-10-22T14:20:00Z"),
            ProposalLines.cardObject("prop_old", created: "2026-10-22T14:00:00Z"),
            ProposalLines.cardObject("prop_mid", created: "2026-10-22T14:10:00Z")
        ])
        chat.answer("prop_mid", .confirm)

        #expect(CompanionReducer.waiting(chat.proposals).map(\.id) == ["prop_old", "prop_new"])
    }

    @Test("each request to show a card is a new one, even for the same card")
    func revealIsANewRequestEachTime() {
        var chat = CompanionChat()

        CompanionReducer.reveal(proposal: "prop_01", in: &chat)
        let first = chat.proposalReveal
        CompanionReducer.reveal(proposal: "prop_01", in: &chat)

        #expect(first?.proposalId == "prop_01")
        #expect(chat.proposalReveal?.proposalId == "prop_01")
        #expect(chat.proposalReveal != first)
    }
}

// MARK: - The session

/// Counts what is scheduled, so a case can tell one timer kept from one
/// cancelled and set again.
@MainActor
private final class CountingDeadlines: DeadlineScheduling {
    let inner = ManualDeadlineScheduler()
    private(set) var scheduled = 0

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DeadlineToken {
        scheduled += 1
        return inner.schedule(after: seconds, work)
    }
}

@MainActor
private final class ProposalHarness {
    let socket = FakeCompanionSocket()
    let deadlines = CountingDeadlines()
    var clock: Date
    private(set) var session: CompanionSession!

    init() throws {
        clock = try moment("2026-10-22T14:02:30Z")
        var issued = 0
        session = CompanionSession(
            transport: CompanionSocketClient(lines: socket),
            socketPath: { "/tmp/fermix-test/companion.sock" },
            deadlines: deadlines,
            messageIds: {
                issued += 1
                return "mac-\(issued)"
            },
            now: { [unowned self] in self.clock }
        )
    }

    var model: CompanionModel { session.model }

    func connected() {
        session.connect()
        socket.deliver(E.hello())
    }
}

@Suite("Companion proposals: the session")
@MainActor
struct CompanionProposalSessionTests {
    @Test("a card counts down on one timer to its expiry on this Mac's clock, which takes its buttons away")
    func countsDownToExpiry() throws {
        let harness = try ProposalHarness()
        harness.connected()

        harness.socket.deliver(try ProposalLines.event())

        #expect(harness.deadlines.inner.scheduledDelays == [1_800])
        #expect(harness.model.waitingProposalIds == ["prop_01"])

        harness.clock = harness.clock.addingTimeInterval(1_800)
        harness.deadlines.inner.fireAll()

        #expect(harness.model.proposals.first?.standing == .expired)
        #expect(harness.model.waitingProposalIds.isEmpty)
        #expect(harness.deadlines.inner.liveCount == 0)
    }

    @Test("a card that arrives past its expiry arrives expired")
    func arrivesExpired() throws {
        let harness = try ProposalHarness()
        harness.connected()

        harness.socket.deliver(try ProposalLines.event(ProposalLines.cardObject(expires: "2026-10-22T14:00:00Z")))

        #expect(harness.model.proposals.first?.standing == .expired)
        #expect(harness.deadlines.inner.liveCount == 0)
    }

    @Test("a reply streaming while a card counts down sets no timer of its own")
    func streamingSetsNoTimer() throws {
        let harness = try ProposalHarness()
        harness.connected()
        harness.socket.deliver(try ProposalLines.event())
        let scheduled = harness.deadlines.scheduled

        harness.socket.deliver(.turnStarted(profileId: "main", turnId: "turn-1", inReplyTo: "mac-0"))
        for piece in ["Looking", " at", " it"] {
            harness.socket.deliver(.textDelta(turnId: "turn-1", text: piece))
        }

        #expect(harness.deadlines.scheduled == scheduled)
        #expect(harness.deadlines.inner.liveCount == 1)
    }

    @Test("a resolved card stops the countdown")
    func resolutionStopsTheCountdown() throws {
        let harness = try ProposalHarness()
        harness.connected()
        harness.socket.deliver(try ProposalLines.event())

        harness.socket.deliver(ProposalLines.resolved(state: .denied, sentence: "Denied. issue_create will not run.", resultText: nil))

        #expect(harness.deadlines.inner.liveCount == 0)
    }

    @Test("answering puts exactly the proposal answer on the wire")
    func answerOnTheWire() throws {
        let harness = try ProposalHarness()
        harness.connected()
        harness.socket.deliver(try ProposalLines.event())

        harness.session.answerProposal("prop_01", decision: .confirm)

        #expect(try harness.socket.sentObjects().last == wireObject(companion: .proposalAnswer(
            clientMsgId: "mac-1", profileId: "main", proposalId: "prop_01", decision: .confirm
        )))
        #expect(harness.model.proposals.first?.standing == .answered(.confirm))
    }

    /// A version 3 connection never carries a proposal, so this build never
    /// sits on one waiting for a card: a daemon whose window ends at 3 is
    /// told to update.
    @Test("a daemon whose window ends at version 3 is refused rather than waited on for proposals")
    func versionThreeDaemonIsRefused() throws {
        let harness = try ProposalHarness()

        harness.session.connect()
        harness.socket.deliver(E.hello(2, 3))

        #expect(harness.model.connection == .refused(ProductStrings[.companionConnectionUpdateEngine]))
        #expect(try harness.socket.sentObjects() == [wireObject(companion: .clientHello(protocolVersion: 4))])
    }

    @Test("the menu line's request to show a card is published once and taken back when served")
    func revealIsServedOnce() throws {
        let harness = try ProposalHarness()
        harness.connected()
        harness.socket.deliver(try ProposalLines.event())

        harness.session.revealProposal("prop_01")
        #expect(harness.model.proposalReveal?.proposalId == "prop_01")

        harness.session.proposalRevealServed()
        #expect(harness.model.proposalReveal == nil)
    }
}

// MARK: - The transcript

@Suite("Companion proposals: the transcript")
struct CompanionProposalTimelineTests {
    private static func row(_ seq: Int, at time: String?) -> CompanionRow {
        CompanionRow(
            serverSeq: seq,
            text: "row \(seq)",
            role: "assistant",
            timestamp: time,
            clientMsgId: nil,
            inReplyTo: nil,
            turnId: nil
        )
    }

    private static let rows = [
        row(1, at: "2026-10-22T14:00:00Z"),
        row(2, at: "2026-10-22T14:02:00Z"),
        row(3, at: "2026-10-22T14:05:00Z")
    ]

    private static func card(_ id: String, created: String) throws -> CompanionProposalCard {
        CompanionProposalCard(proposal: try ProposalLines.proposal(ProposalLines.cardObject(id, created: created)), standing: .open)
    }

    private static func ids(_ items: [ChatItem]) -> [ChatItemID] {
        items.map(\.id)
    }

    @Test("a card sits among the rows at the time it was made, with no seq of its own")
    func placedByWhenItWasMade() throws {
        let items = ChatTimeline.items(
            rows: Self.rows, turn: nil, approvals: [], pending: [], lastError: nil,
            proposals: [try Self.card("prop_01", created: "2026-10-22T14:02:30Z")]
        )

        #expect(Self.ids(items) == [.row(1), .row(2), .proposal("prop_01"), .row(3)])
    }

    @Test("a card made after every row follows them, ahead of the turn answering now")
    func newestCardBeforeTheTurn() throws {
        let turn = CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "So far", tool: nil)
        let items = ChatTimeline.items(
            rows: Self.rows + [Self.row(4, at: nil)], turn: turn, approvals: [], pending: [], lastError: nil,
            proposals: [try Self.card("prop_01", created: "2026-10-22T14:09:00Z")]
        )

        #expect(Self.ids(items) == [.row(1), .row(2), .row(3), .proposal("prop_01"), .row(4), .turn("turn-1")])
    }

    @Test("a card made before every held row comes first, and one whose time cannot be read comes after the rows")
    func edgesOfTheHeldRows() throws {
        let items = ChatTimeline.items(
            rows: Self.rows, turn: nil, approvals: [], pending: [], lastError: nil,
            proposals: [
                try Self.card("prop_early", created: "2026-10-22T13:00:00Z"),
                try Self.card("prop_unreadable", created: "earlier")
            ]
        )

        #expect(Self.ids(items) == [.proposal("prop_early"), .row(1), .row(2), .row(3), .proposal("prop_unreadable")])
    }

    @Test("a card answers no message, so it stands apart even right after the owner's own")
    func cardOpensATurn() throws {
        let mine = ChatItem.row(CompanionRow(
            serverSeq: 1, text: "Watch the eng blogs", role: "user", timestamp: nil,
            clientMsgId: "mac-1", inReplyTo: nil, turnId: nil
        ))
        let card = ChatItem.proposal(try Self.card("prop_01", created: "2026-10-22T14:02:30Z"))

        #expect(ChatTimeline.opensNewTurn(after: mine, before: card))
        #expect(ChatTimeline.opensNewTurn(after: card, before: .row(Self.row(2, at: nil))))
    }

    @Test("a proposal's answer in the outbox is never drawn as a message")
    func answerIsNotAMessage() throws {
        let answer = CompanionOutboxEntry(clientMsgId: "mac-1", request: .proposalAnswer(proposalId: "prop_01", decision: .confirm))
        let items = ChatTimeline.items(
            rows: [], turn: nil, approvals: [], pending: [answer], lastError: nil,
            proposals: [try Self.card("prop_01", created: "2026-10-22T14:02:30Z")]
        )

        #expect(Self.ids(items) == [.proposal("prop_01")])
    }
}

// MARK: - Outside text

@Suite("Outside text")
struct OutsideTextTests {
    /// M60 §9: a cue text holding a Markdown link, a bare URL and a phone
    /// number renders all three literally, with no link and no detector.
    @Test("outside text is its characters: a Markdown link, a bare URL and a phone number stay text, linked to nothing")
    func setLiterally() {
        let text = ProposalLines.itemText
        let set = OutsideText.literal(text)

        #expect(String(set.characters) == text)
        #expect(set.runs.count == 1)
        #expect(set.runs.allSatisfy { $0.link == nil })
        #expect(String(set.characters).contains("[the notice](https://login.example/steal)"))
    }

    /// The component never reaches for what would parse or link its text:
    /// no Markdown initializer, no localized key (which SwiftUI reads as
    /// Markdown), no detector, no link, no URL opener, no tap handler.
    @Test("the outside text component parses nothing and links nothing")
    func componentParsesNothing() throws {
        let source = try #require(try SourceTree.swiftFiles(matching: "Chat/OutsideTextBlock.swift").first).text
        let forbidden = [
            "AttributedString(markdown", "LocalizedStringKey", "NSDataDetector", "DataDetector", "dataDetector",
            ".link =", "Link(", "openURL", "onTapGesture", "Text(\"", "AsyncImage"
        ]

        for construct in forbidden {
            #expect(!source.contains(construct), "OutsideTextBlock uses \(construct)")
        }
    }

    @Test("outside text shows at most twelve lines until Show all")
    func capsAtTwelveLines() {
        #expect(ChatMetrics.outsideLineCap == 12)
        #expect(ProductStrings[.outsideShowAll] == "Show all")
    }

    @Test("an item's fields are labelled by Fermix and say only what the item said")
    func itemFacts() throws {
        let bare = try #require(try ProposalLines.proposal().outside.cue)
        let full = try #require(try ProposalLines.proposal(
            ProposalLines.cardObject(cue: ProposalLines.cueObject(subject: "Lantern 4.2", occurredAt: "yesterday-ish"))
        ).outside.cue)

        #expect(ChatProposalCard.facts(of: bare) == ["Type: feed.item", "Dated: 2026-10-22T13:58:00Z"])
        #expect(ChatProposalCard.facts(of: full) == ["Type: feed.item", "Subject: Lantern 4.2", "Dated: yesterday-ish"])
        #expect(OutsideText.facts(ChatProposalCard.facts(of: full)) == "Type: feed.item · Subject: Lantern 4.2 · Dated: yesterday-ish")
    }

    @Test("the card's own lines are Fermix's record and none of the outside text")
    func fermixLinesCarryNoOutsideText() throws {
        let proposal = try ProposalLines.proposal()
        let lines = [ChatProposalCard.facts(of: proposal), ChatProposalCard.itemHeader(of: proposal), proposal.summary]

        #expect(ChatProposalCard.facts(of: proposal).hasPrefix("Task: Release watch · Watcher: release-watch · Waits until "))
        #expect(ChatProposalCard.itemHeader(of: proposal).hasPrefix("From eng-blogs, received "))

        let bare = try ProposalLines.proposal(ProposalLines.cardObject(taskName: nil, watcher: nil, source: nil))
        #expect(ChatProposalCard.facts(of: bare).hasPrefix("Task: job_7f3a · Waits until "))
        #expect(ChatProposalCard.itemHeader(of: bare) == "The item it acted on")
        for line in lines {
            #expect(!line.contains("Lantern"), "\(line)")
            #expect(!line.contains("example-org"), "\(line)")
        }
    }

    /// M60 §4.8 and §9: outside text appears in no notification, menu line,
    /// title or button label. Structurally: only the card reads a proposal's
    /// outside text, beside the wire and the chat state that carry it.
    @Test("no notification, menu line or title reads a proposal's outside text: only the card does")
    func onlyTheCardReadsOutsideText() throws {
        let carriers: Set<String> = [
            "Companion/CompanionProtocol.swift",
            "Companion/CompanionChat.swift",
            "Companion/CompanionReducer.swift",
            "Companion/FixtureCompanionTransport.swift",
            "Chat/ChatProposalCard.swift"
        ]
        let readers = try SourceTree.swiftFiles(under: "", excluding: false).filter { file in
            ["argsText", "resultText", "outside.cue", "outside.argsText"].contains { file.text.contains($0) }
        }

        #expect(!readers.isEmpty, "the scan found no reader at all")
        for file in readers {
            #expect(carriers.contains { file.path.hasSuffix($0) }, "\(file.path) reads a proposal's outside text")
        }
    }

    /// M60 §5.3: only the person at this Mac answers, on the card itself. No
    /// command, menu row, URL, script or intent reaches the answer.
    @Test("only the card's own buttons answer a proposal: no automation route does")
    func noAutomationRouteAnswers() throws {
        let allowed: Set<String> = [
            "Companion/CompanionSession.swift",
            "Companion/CompanionReducer.swift",
            "Chat/ChatTranscript.swift"
        ]
        let answering = try SourceTree.swiftFiles(under: "", excluding: false).filter { file in
            file.text.contains("answerProposal") || file.text.contains("CompanionReducer.answer(proposal:")
        }

        #expect(!answering.isEmpty, "the scan found no caller at all")
        for file in answering {
            #expect(allowed.contains { file.path.hasSuffix($0) }, "\(file.path) answers a proposal")
        }
    }
}

// MARK: - The fixture daemon

/// `--fixture-start` draws every card state from the scripted daemon (M60 §6
/// Fixtures), through the real adapter, session and reducer.
@Suite("Companion proposals: the fixture daemon")
@MainActor
struct CompanionProposalFixtureTests {
    private static let launched = Date(timeIntervalSince1970: 1_792_000_000)

    private func fixtureChat() -> CompanionSession {
        var issued = 0
        return CompanionSession(
            transport: CompanionSocketClient(lines: FixtureCompanionTransport(timeline: .full, now: Self.launched)),
            socketPath: { "/fixture/companion.sock" },
            deadlines: ManualDeadlineScheduler(),
            messageIds: {
                issued += 1
                return "fixture-\(issued)"
            },
            now: { Self.launched }
        )
    }

    @Test("the full timeline holds a card in each state: resolved three ways, refused, lapsed, and one asking")
    func everyCardState() throws {
        let session = fixtureChat()
        session.connect()

        let standings = Dictionary(uniqueKeysWithValues: session.model.proposals.map { ($0.id, $0.standing) })

        guard case .resolved(_, let result)? = standings["fixture-proposal-confirmed"] else {
            Issue.record("the confirmed card is not resolved")
            return
        }
        #expect(result != nil)
        #expect(standings["fixture-proposal-denied"] == .resolved(sentence: "Denied. github_create_issue will not run.", resultText: nil))
        #expect(standings["fixture-proposal-expired"] == .resolved(sentence: "That proposal expired; nothing ran.", resultText: nil))
        #expect(standings["fixture-proposal-lapsed"] == .expired)
        #expect(standings[FixtureProposalScript.waitingId] == .open)
        #expect(session.model.waitingProposalIds == [FixtureProposalScript.waitingId])
        #expect(session.model.proposals.first { $0.id == "fixture-proposal-refused" }?.proposal.outside.cue == nil)
    }

    @Test("answering the card that asks is accepted, and the card waits for its resolution")
    func answerIsAccepted() {
        let session = fixtureChat()
        session.connect()

        session.answerProposal(FixtureProposalScript.waitingId, decision: .confirm)

        #expect(session.model.pending.isEmpty)
        #expect(session.model.proposals.first { $0.id == FixtureProposalScript.waitingId }?.standing == .answered(.confirm))
    }
}
