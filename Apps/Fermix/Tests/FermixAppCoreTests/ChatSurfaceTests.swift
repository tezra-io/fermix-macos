import Combine
import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents

/// What the chat surface draws, as values: the transcript's order, where a
/// hit is, where the reader was, the greeting, and the words each line uses.
/// No window, no scroll view: the view reads these and nothing else decides.
@Suite("Chat surface")
struct ChatSurfaceTests {
    // MARK: - The transcript

    private static func row(_ seq: Int, role: String? = "assistant") -> CompanionRow {
        CompanionRow(serverSeq: seq, text: "row \(seq)", role: role, timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil)
    }

    private static let approval = CompanionApproval(
        approvalId: "sandbox-1",
        kind: "sandbox",
        text: "Allow reading ~/Documents?",
        detail: nil,
        token: "opaque-token",
        ttlSeconds: 60,
        approveCommand: "/confirm opaque-token",
        denyCommand: "/deny opaque-token"
    )

    @Test("rows, then the turn, its approvals, the messages not yet accepted, and the latest failure")
    func readingOrder() {
        let turn = CompanionTurn(turnId: "turn-1", inReplyTo: "mac-1", text: "So far", tool: nil)
        let items = ChatTimeline.items(
            rows: [Self.row(1, role: "user"), Self.row(2)],
            turn: turn,
            approvals: [Self.approval],
            pending: [CompanionOutboxEntry(clientMsgId: "mac-2", request: .message(text: "And then?"))],
            lastError: "The reply was stopped"
        )

        #expect(items.map(\.id) == [.row(1), .row(2), .turn("turn-1"), .approval("sandbox-1"), .pending("mac-2"), .error])
    }

    /// An approval's answer travels as a command whose args are the token, and
    /// the token is never drawn: the outbox entry marks the card as answering
    /// rather than becoming a message of its own.
    @Test("an approval's answer in the outbox is never drawn as a message, and marks the card")
    func answeringAnApproval() {
        let answer = CompanionOutboxEntry(clientMsgId: "mac-3", request: .command(name: "confirm", args: "opaque-token"))
        let items = ChatTimeline.items(rows: [], turn: nil, approvals: [Self.approval], pending: [answer], lastError: nil)

        #expect(items == [.approval(Self.approval, answering: true)])

        let unanswered = ChatTimeline.items(rows: [], turn: nil, approvals: [Self.approval], pending: [], lastError: nil)
        #expect(unanswered == [.approval(Self.approval, answering: false)])
    }

    @Test("an empty timeline with nothing pending draws nothing, which is the empty state")
    func emptyTimeline() {
        #expect(ChatTimeline.items(rows: [], turn: nil, approvals: [], pending: [], lastError: nil).isEmpty)
    }

    /// The seam between a user's own row (or a message not yet accepted) and
    /// the reply that follows it is one turn; every other seam, including two
    /// user rows in a row, opens a new one.
    @Test("a user row and the reply after it are one turn; every other seam opens a new one")
    func turnSeams() {
        let userRow = ChatItem.row(Self.row(1, role: "user"))
        let replyRow = ChatItem.row(Self.row(2, role: "assistant"))
        let turn = ChatItem.turn(CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "So far", tool: nil))
        let pending = ChatItem.pending(clientMsgId: "mac-1", text: "Hello")

        #expect(ChatTimeline.opensNewTurn(after: nil, before: userRow) == false)
        #expect(ChatTimeline.opensNewTurn(after: userRow, before: replyRow) == false)
        #expect(ChatTimeline.opensNewTurn(after: pending, before: turn) == false)
        #expect(ChatTimeline.opensNewTurn(after: replyRow, before: userRow) == true)
        #expect(ChatTimeline.opensNewTurn(after: userRow, before: userRow) == true)
        #expect(ChatTimeline.opensNewTurn(after: turn, before: .approval(Self.approval, answering: false)) == true)
    }

    // MARK: - Following the conversation

    /// A reader on the bottom edge follows a new row; one who scrolled up to
    /// read holds their place; sending follows regardless of where they were.
    @Test("at bottom follows, scrolled up holds, and sending follows regardless")
    func followRule() {
        #expect(ChatFollow.follows(atBottom: true, sent: false) == true)
        #expect(ChatFollow.follows(atBottom: false, sent: false) == false)
        #expect(ChatFollow.follows(atBottom: false, sent: true) == true)
        #expect(ChatFollow.follows(atBottom: true, sent: true) == true)
    }

    /// The strip takes its room from the transcript, whose scroll view keeps
    /// its top where it was: a reader on the bottom edge is put back there,
    /// and one reading further up keeps their place. A reader's own scroll
    /// changes no size, so it is never undone.
    @Test("the transcript keeps a reader on its bottom edge when the strip takes room")
    func transcriptKeepsTheBottomEdge() {
        func viewport(_ height: Double, width: Double = 720, atBottom: Bool) -> ChatViewport {
            ChatViewport(size: CGSize(width: width, height: height), atBottom: atBottom)
        }
        let reading = viewport(480, atBottom: true)

        // The strip arrives, or takes a line.
        #expect(ChatFollow.keepsBottom(readerAtBottom: true, before: reading, now: viewport(400, atBottom: false)))
        #expect(ChatFollow.keepsBottom(readerAtBottom: true, before: reading, now: viewport(464, atBottom: true)))
        // The column narrows beside the pane and the rows rewrap.
        #expect(ChatFollow.keepsBottom(readerAtBottom: true, before: viewport(480, atBottom: true), now: viewport(480, width: 432, atBottom: false)))
        // The pane opens over a run of sizes: past the first, the last reading
        // is already off the bottom edge, and the reader still is not.
        #expect(ChatFollow.keepsBottom(readerAtBottom: true, before: viewport(480, width: 600, atBottom: false), now: viewport(480, width: 480, atBottom: false)))
        // A reader further up keeps their place.
        #expect(!ChatFollow.keepsBottom(readerAtBottom: false, before: viewport(480, atBottom: false), now: viewport(400, atBottom: false)))
        // The reader scrolled away from the bottom edge themselves.
        #expect(!ChatFollow.keepsBottom(readerAtBottom: true, before: reading, now: viewport(480, atBottom: false)))
    }

    // MARK: - The draft

    /// The chat view is rebuilt on every rail change and when Settings opens,
    /// so the text being written lives on the session and the view starts from
    /// it. Not on the model, and not published: a keystroke redraws nothing
    /// but the field.
    @Test("the draft lives on the session, unpublished, so a rebuilt chat view finds it")
    @MainActor
    func draftOutlivesTheView() throws {
        let session = CompanionSession(
            transport: CompanionSocketClient(lines: FakeCompanionSocket()),
            socketPath: { "/tmp/fermix-test/companion.sock" },
            deadlines: ManualDeadlineScheduler()
        )
        var changes = 0
        let subscription = session.model.objectWillChange.sink { _ in changes += 1 }
        defer { subscription.cancel() }

        #expect(session.draft.isEmpty)
        session.draft = "check the lease"
        #expect(session.draft == "check the lease")
        #expect(changes == 0)

        let surface = try #require(try SourceTree.swiftFiles(matching: "Chat/ChatSurfaceView.swift").first?.text)
        #expect(surface.contains("_draft = State(initialValue: session.draft)"))
        #expect(surface.contains("session.draft = draft"))
    }

    // MARK: - Where a hit is

    @Test("a held hit is scrolled to, an older one is read towards, and one past the oldest page is not")
    func revealSteps() {
        let reveal = ChatReveal(E.hit(88))
        let held = (80...120).map { Self.row($0) }
        let later = (100...120).map { Self.row($0) }

        #expect(reveal.step(rows: held, hasOlder: true) == .scroll(.row(88)))
        #expect(reveal.step(rows: later, hasOlder: true) == .readOlder)
        #expect(reveal.step(rows: later, hasOlder: false) == .unreachable)
        #expect(reveal.step(rows: [], hasOlder: false) == .unreachable)
    }

    @Test("a hit's terms are the words its ranges mark, counted in Unicode scalars")
    func hitTerms() {
        #expect(ChatReveal(E.hit(88)).terms == ["dentist"])

        let accented = CompanionSearchHit(
            serverSeq: 3,
            role: "user",
            timestamp: "2026-09-24T09:15:00Z",
            excerpt: "…café au lait and a dentist",
            ranges: [CompanionMatchRange(start: 1, length: 4), CompanionMatchRange(start: 20, length: 7)]
        )
        #expect(ChatExcerpt.terms(of: accented) == ["café", "dentist"])

        let pastTheEnd = CompanionSearchHit(
            serverSeq: 4,
            role: "user",
            timestamp: "2026-09-24T09:15:00Z",
            excerpt: "short",
            ranges: [CompanionMatchRange(start: 3, length: 9)]
        )
        #expect(ChatExcerpt.terms(of: pastTheEnd).isEmpty)
    }

    // MARK: - Where the reader was

    @Test("a reader on the bottom edge keeps the newest item there, and one scrolled up keeps the top one")
    func readerPlace() {
        let items = (1...5).map { ChatItem.row(Self.row($0)) }

        #expect(ChatPlace(atBottom: true, visible: [.row(4), .row(5)], items: items) == .newest(.row(5)))
        #expect(ChatPlace(atBottom: false, visible: [.older, .row(2), .row(1)], items: items) == .top(.row(1)))
        #expect(ChatPlace(atBottom: false, visible: [.older], items: items) == nil)
    }

    // MARK: - The greeting

    @Test("the greeting follows the Mac's clock")
    func greetingByHour() {
        #expect(ChatGreeting.phrase(hour: 4) == .chatGreetingEvening)
        #expect(ChatGreeting.phrase(hour: 5) == .chatGreetingMorning)
        #expect(ChatGreeting.phrase(hour: 11) == .chatGreetingMorning)
        #expect(ChatGreeting.phrase(hour: 12) == .chatGreetingAfternoon)
        #expect(ChatGreeting.phrase(hour: 17) == .chatGreetingAfternoon)
        #expect(ChatGreeting.phrase(hour: 18) == .chatGreetingEvening)
        #expect(ChatGreeting.phrase(hour: 23) == .chatGreetingEvening)
    }

    @Test("the greeting takes the first name About you saved, and none when it saved none")
    func greetingName() {
        #expect(ChatGreeting.text(hour: 9, userName: "Sujeena Shrestha") == "Good morning, Sujeena")
        #expect(ChatGreeting.text(hour: 14, userName: "Sujeena") == "Good afternoon, Sujeena")
        #expect(ChatGreeting.text(hour: 20, userName: "   ") == "Good evening")
        #expect(ChatGreeting.text(hour: 20, userName: nil) == "Good evening")
    }

    /// The name is the daemon's `personalization.user_name`, read through the
    /// one settings model: the same row About you writes.
    @MainActor
    @Test("the name is the personalization row About you writes, read through the settings model")
    func greetingReadsTheSettingsRow() async throws {
        let harness = try SettingsHarness()

        #expect(ChatGreeting.userName(in: harness.model) == nil)

        await harness.model.loadSection(AboutYouAnswers.personalizationSection)

        // The contract's golden publishes the row with no name in it.
        #expect(ChatGreeting.userName(in: harness.model) == "")
        #expect(ChatGreeting.text(hour: 9, userName: ChatGreeting.userName(in: harness.model)) == "Good morning")
    }

    // MARK: - Words

    @Test("the two sides are named as the product names them, and an unknown role as the daemon wrote it")
    func speakers() {
        #expect(ChatSpeaker.name(role: "user") == ProductStrings[.voiceCaptionSpeakerUser])
        #expect(ChatSpeaker.name(role: "assistant") == ProductStrings[.voiceCaptionSpeakerAssistant])
        #expect(ChatSpeaker.name(role: nil) == ProductStrings[.voiceCaptionSpeakerAssistant])
        #expect(ChatSpeaker.name(role: "system") == "system")
        #expect(ChatSpeaker.isUser("user"))
        #expect(!ChatSpeaker.isUser(nil))
    }

    @Test("the tool line says what is running, what ran, and a phase it has no word for as the tool alone")
    func toolLine() {
        let tool = { (phase: CompanionToolPhase) in
            CompanionToolEvent(turnId: "turn-1", tool: "web_search", phase: phase, detail: nil)
        }

        #expect(ChatToolLine.sentence(tool(.start)) == "Using web_search")
        #expect(ChatToolLine.sentence(tool(.stop)) == "Used web_search")
        #expect(ChatToolLine.sentence(tool(.unrecognized("paused"))) == "web_search")
    }

    /// A turn is thinking until either a tool is named or text starts
    /// arriving; a named tool stays shown even once text follows it; and a
    /// turn with text and no tool is quiet, drawing nothing beneath it.
    @Test("a turn is thinking, then a named tool, then quiet, read off its own fields alone")
    func turnStatus() {
        let tool = CompanionToolEvent(turnId: "turn-1", tool: "web_search", phase: .start, detail: nil)

        #expect(ChatTurnStatus(CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "", tool: nil)) == .thinking)
        #expect(ChatTurnStatus(CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "", tool: tool)) == .tool(tool))
        #expect(ChatTurnStatus(CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "So far", tool: nil)) == .quiet)
        #expect(ChatTurnStatus(CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "So far", tool: tool)) == .tool(tool))
    }

    /// The engine's provider-lifecycle `tool_event` (carried today as a tool
    /// named "unknown") is never matched by name: it reads as any other named
    /// tool, because the thinking state is read off the turn having no tool at
    /// all rather than off what a tool happens to be called.
    @Test("a tool named unknown is drawn as any other named tool, never as thinking")
    func noSpecialCaseForUnknown() {
        let tool = CompanionToolEvent(turnId: "turn-1", tool: "unknown", phase: .start, detail: nil)
        let turn = CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: "", tool: tool)

        #expect(ChatTurnStatus(turn) == .tool(tool))
        #expect(ChatTurnStatus(turn) != .thinking)
    }

    /// The links are live: the surface hands them to the content link opener,
    /// which opens them in the pane or the person's own browser.
    @Test("reply markdown is inline only, and its links are live")
    func replyText() {
        let reply = ChatText.reply("See **the notes** at [the site](https://example.com).")

        #expect(String(reply.characters) == "See the notes at the site.")
        #expect(reply.runs.compactMap(\.link) == [URL(string: "https://example.com")!])
        #expect(reply.runs.filter { $0.link != nil }.allSatisfy { $0.foregroundColor == Palette.accentText.color })
        #expect(reply.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    /// A heading line is drawn as its text in bold and a fenced block as code
    /// spans, their marks gone; a `#` that is not a heading, and every other
    /// block mark, stays the text it is.
    @Test("a heading line is drawn in bold and a fenced block as code, and other block marks stay")
    func replyBlocks() {
        let reply = ChatText.reply(
            "Plan\n### What to expect\n- Heat: humid\n#hashtag\n####### seven\n## \n```text\n/tmp/a.png\n\nx `y`\n```\nDone"
        )

        #expect(String(reply.characters) == "Plan\nWhat to expect\n- Heat: humid\n#hashtag\n####### seven\n## \n/tmp/a.png\n\nx `y`\nDone")
        let bold = reply.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(reply[$0.range].characters) } == ["What to expect"])
        let code = reply.runs.filter { $0.inlinePresentationIntent == .code }
        #expect(code.map { String(reply[$0.range].characters) } == ["/tmp/a.png", "x `y`"])
    }

    @Test("marking finds every occurrence of each term, ignoring case")
    func marking() {
        let marked = ChatText.marking(["the"], in: ChatText.plain("The dentist and the hygienist"))
        let emphasised = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }

        #expect(emphasised.map { String(marked[$0.range].characters) } == ["The", "the"])
    }

    @Test("a hit's time is shown in this Mac's format, and a time the parser refuses as written")
    func hitTime() {
        #expect(ChatTime.written("2026-09-24T09:15:00Z") != "2026-09-24T09:15:00Z")
        #expect(ChatTime.written("yesterday") == "yesterday")
    }
}
