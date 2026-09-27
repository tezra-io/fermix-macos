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

    @Test("reply markdown is inline only, and its links are left as text")
    func replyText() {
        let reply = ChatText.reply("See **the notes** at [the site](https://example.com).")

        #expect(String(reply.characters) == "See the notes at the site.")
        #expect(reply.runs.allSatisfy { $0.link == nil })
        #expect(reply.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
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
