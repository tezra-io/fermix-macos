import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents

/// Reducer steps written as the chat's own, so a case reads as the sequence of
/// events it replays.
extension CompanionChat {
    @discardableResult
    fileprivate mutating func receive(_ event: CompanionServerEvent) -> [CompanionClientEvent] {
        CompanionReducer.receive(event, into: &self)
    }

    @discardableResult
    fileprivate mutating func negotiated() -> [CompanionClientEvent] {
        CompanionReducer.negotiated(&self)
    }

    /// A cold start whose newest page held `seqs`, with older rows below them
    /// when `older` says so.
    fileprivate static func holding(_ seqs: ClosedRange<Int>, older: Bool = false) -> CompanionChat {
        var chat = CompanionChat()
        chat.negotiated()
        chat.receive(E.backward(Array(seqs), head: seqs.upperBound, older: older ? seqs.lowerBound : nil))
        return chat
    }

    fileprivate var seqs: [Int] { rows.map(\.serverSeq) }
}

/// The chat's state machine: the contract's client cursor rule, the outbox,
/// turns, approvals, search and the read frontier, with no socket and no clock.
@Suite("Companion reducer")
struct CompanionReducerTests {
    // MARK: - The catch-up read

    /// `after_seq: 0` reads the oldest page. A client that holds nothing wants
    /// the newest, which only `before_seq` reaches.
    @Test("a cold start asks for the newest page")
    func coldStartPullsTheNewestPage() {
        var chat = CompanionChat()

        #expect(chat.negotiated() == [newestPagePull])
        #expect(chat.historyPull == .before(seq: Int.max))
    }

    @Test("the newest page becomes the held window and its newest row the cursor")
    func newestPageSeedsTheWindow() {
        var chat = CompanionChat()
        chat.negotiated()

        let replies = chat.receive(E.backward([118, 119, 120], head: 120, older: 118))

        #expect(replies.isEmpty)
        #expect(chat.seqs == [118, 119, 120])
        #expect(chat.cursor == 120)
        #expect(chat.historyHeadSeq == 120)
        #expect(chat.hasOlder)
        #expect(chat.historyPull == nil)
    }

    @Test("an empty timeline starts at zero and takes its first row live")
    func emptyTimelineColdStart() {
        var chat = CompanionChat()
        chat.negotiated()

        #expect(chat.receive(E.backward([], head: 0)).isEmpty)
        #expect(chat.rows.isEmpty)
        #expect(chat.cursor == 0)
        #expect(chat.historyHeadSeq == 0)
        #expect(!chat.hasOlder)

        #expect(chat.receive(E.row(1)).isEmpty)
        #expect(chat.seqs == [1])
        #expect(chat.cursor == 1)
    }

    @Test("a client holding rows reads on from its cursor, then resends its outbox in order")
    func warmReconnectReadsOnThenResends() {
        var chat = CompanionChat.holding(10...12)
        _ = CompanionReducer.send("Hello", clientMsgId: "mac-1", into: &chat)
        _ = CompanionReducer.send("And again", clientMsgId: "mac-2", into: &chat)
        CompanionReducer.disconnected(&chat)

        #expect(
            chat.negotiated() == [
                historyPull(.after(seq: 12)),
                .msg(clientMsgId: "mac-1", profileId: "main", text: "Hello"),
                .msg(clientMsgId: "mac-2", profileId: "main", text: "And again")
            ]
        )
    }

    // MARK: - The cursor rule

    @Test("a live row at the next seq is shown and moves the cursor")
    func nextRowIsShown() {
        var chat = CompanionChat.holding(8...10)

        #expect(chat.receive(E.row(11, clientMsgId: "mac-1")).isEmpty)
        #expect(chat.seqs == [8, 9, 10, 11])
        #expect(chat.cursor == 11)
        #expect(chat.rows.last?.clientMsgId == "mac-1")
        #expect(chat.rows.last?.role == "user")
    }

    @Test("a live row at or below the cursor is dropped")
    func rowAtOrBelowTheCursorIsDropped() {
        var chat = CompanionChat.holding(8...10)
        let before = chat

        #expect(chat.receive(E.row(10)).isEmpty)
        #expect(chat.receive(E.row(4)).isEmpty)
        #expect(chat == before)
    }

    @Test("a gap is pulled from the cursor once, and nothing past it is shown until the page lands")
    func gapPullsOnce() {
        var chat = CompanionChat.holding(8...10)

        #expect(chat.receive(E.row(13)) == [historyPull(.after(seq: 10))])
        #expect(chat.receive(E.row(14)).isEmpty)
        #expect(chat.receive(.textDone(turnId: "turn-1", serverSeq: 15, text: "Done.")).isEmpty)
        #expect(chat.seqs == [8, 9, 10])
        #expect(chat.cursor == 10)

        #expect(chat.receive(E.forward([11, 12, 13, 14, 15], head: 15, next: 15)).isEmpty)
        #expect(chat.seqs == Array(8...15))
        #expect(chat.cursor == 15)
        #expect(chat.historyPull == nil)
    }

    /// A live row that arrives ahead of the page is for a row the page already
    /// read, so the two carry it twice and it is held once.
    @Test("a live row and a page carrying the same row hold it once")
    func liveRowAndPageOverlap() {
        var chat = CompanionChat.holding(8...10)
        chat.receive(E.row(12))
        chat.receive(E.row(11))

        #expect(chat.cursor == 11)
        #expect(chat.receive(E.forward([11, 12], head: 12, next: 12)).isEmpty)
        #expect(chat.seqs == [8, 9, 10, 11, 12])
        #expect(chat.cursor == 12)
    }

    @Test("a page ahead of a live row makes the late row a duplicate")
    func pageAheadOfALiveRow() {
        var chat = CompanionChat.holding(8...10)
        chat.receive(E.row(12))
        chat.receive(E.forward([11, 12, 13], head: 13, next: 13))

        #expect(chat.receive(E.row(13)).isEmpty)
        #expect(chat.receive(E.row(11)).isEmpty)
        #expect(chat.seqs == Array(8...13))
        #expect(chat.cursor == 13)
    }

    @Test("merging the same page twice changes nothing")
    func pageMergeIsIdempotent() {
        var chat = CompanionChat.holding(8...10)
        chat.receive(E.row(12))
        chat.receive(E.forward([11, 12], head: 12, next: 12))
        let once = chat

        chat.receive(E.forward([11, 12], head: 12, next: 12))

        #expect(chat == once)
    }

    @Test("a page that stops below the head reads on from where it stopped")
    func pageBelowTheHeadReadsOn() {
        var chat = CompanionChat.holding(8...10)
        chat.receive(E.row(12))

        #expect(chat.receive(E.forward([11, 12], head: 15, next: 12)) == [historyPull(.after(seq: 12))])
        #expect(chat.receive(E.forward([13, 14, 15], head: 15, next: 15)).isEmpty)
        #expect(chat.cursor == 15)
        #expect(chat.historyHeadSeq == 15)
    }

    /// A page carries the exported row, which names its role and time where
    /// the reply's own `text_done` did not.
    @Test("a page's row replaces the reply held from its text_done")
    func pageRowReplacesTheReplyRow() {
        var chat = CompanionChat.holding(8...10)
        chat.receive(.textDone(turnId: "turn-1", serverSeq: 11, text: "row 11"))
        #expect(chat.rows.last?.role == nil)

        chat.receive(E.row(13))
        chat.receive(E.forward([11, 12, 13], head: 13, next: 13))

        #expect(chat.rows.first { $0.serverSeq == 11 }?.role == "assistant")
        #expect(chat.rows.first { $0.serverSeq == 11 }?.turnId == nil)
    }

    // MARK: - Older rows

    @Test("older rows are pulled below the oldest held row, once, and only while some exist")
    func pullOlder() {
        var chat = CompanionChat.holding(8...10, older: true)

        #expect(CompanionReducer.pullOlder(&chat) == [historyPull(.before(seq: 8))])
        #expect(CompanionReducer.pullOlder(&chat).isEmpty)

        #expect(chat.receive(E.backward([5, 6, 7], head: 10)).isEmpty)
        #expect(chat.seqs == Array(5...10))
        #expect(chat.cursor == 10)
        #expect(!chat.hasOlder)
        #expect(CompanionReducer.pullOlder(&chat).isEmpty)
    }

    /// A gap row that arrives while a backward pull is out is not pulled then,
    /// and the backward page's head is what brings it.
    @Test("a backward page reads on from the cursor when the head has moved past it")
    func backwardPageReadsOnAfterAGap() {
        var chat = CompanionChat.holding(8...10, older: true)
        _ = CompanionReducer.pullOlder(&chat)

        #expect(chat.receive(E.row(12)).isEmpty)
        #expect(chat.receive(E.backward([5, 6, 7], head: 12, older: 5)) == [historyPull(.after(seq: 10))])
        #expect(chat.hasOlder)
    }

    // MARK: - Turns

    @Test("deltas accumulate exactly as sent and text_done replaces the draft with its row")
    func deltasThenTextDone() {
        var chat = CompanionChat.holding(1...12)
        let tool = CompanionToolEvent(turnId: "turn-mac-1", tool: "web_search", phase: .start, detail: nil)

        chat.receive(.turnStarted(profileId: "main", turnId: "turn-mac-1", inReplyTo: "mac-1"))
        chat.receive(.textDelta(turnId: "turn-mac-1", text: "You have "))
        chat.receive(.toolEvent(tool))
        chat.receive(.textDelta(turnId: "turn-mac-1", text: " one meeting"))

        #expect(chat.turn == CompanionTurn(turnId: "turn-mac-1", inReplyTo: "mac-1", text: "You have  one meeting", tool: tool))

        #expect(chat.receive(.textDone(turnId: "turn-mac-1", serverSeq: 13, text: "You have one meeting, at 10.")).isEmpty)
        #expect(chat.turn == nil)
        #expect(
            chat.rows.last
                == CompanionRow(reply: "turn-mac-1", serverSeq: 13, text: "You have one meeting, at 10.", inReplyTo: "mac-1")
        )
        #expect(chat.cursor == 13)
    }

    @Test("a turn joined midway starts from its first delta, with no request known")
    func turnJoinedMidway() {
        var chat = CompanionChat.holding(1...12)

        chat.receive(.textDelta(turnId: "turn-phone-4", text: "The text so far"))

        #expect(chat.turn == CompanionTurn(turnId: "turn-phone-4", inReplyTo: nil, text: "The text so far", tool: nil))
    }

    @Test("a turn error ends the turn and says why, in the contract's words or the daemon's")
    func turnErrors() {
        var chat = CompanionChat.holding(1...12)
        chat.receive(.turnStarted(profileId: "main", turnId: "turn-mac-3", inReplyTo: "mac-3"))
        chat.receive(.textDelta(turnId: "turn-mac-3", text: "Partial"))

        chat.receive(.turnError(turnId: "turn-mac-3", code: "cancelled", message: "cancelled"))
        #expect(chat.turn == nil)
        #expect(chat.lastError == ProductStrings[.companionErrorReplyStopped])
        #expect(chat.seqs == Array(1...12))

        chat.receive(.turnError(turnId: "turn-mac-4", code: "interrupted", message: "interrupted"))
        #expect(chat.lastError == ProductStrings[.companionErrorReplyInterrupted])

        chat.receive(.turnError(turnId: "turn-mac-5", code: "provider_error", message: "The provider is busy"))
        #expect(chat.lastError == "The reply did not finish: The provider is busy")
    }

    // MARK: - The outbox

    @Test("a message enters the outbox and is answered with its line")
    func sendEntersTheOutbox() {
        var chat = CompanionChat.holding(1...12)

        let replies = CompanionReducer.send("What is on my calendar today?", clientMsgId: "mac-1", into: &chat)

        #expect(replies == [.msg(clientMsgId: "mac-1", profileId: "main", text: "What is on my calendar today?")])
        #expect(chat.pending == [CompanionOutboxEntry(clientMsgId: "mac-1", request: .message(text: "What is on my calendar today?"))])
    }

    @Test("accepted clears the request whether or not it was a duplicate")
    func acceptedClearsTheOutbox() {
        var chat = CompanionChat.holding(1...12)
        _ = CompanionReducer.send("First", clientMsgId: "mac-1", into: &chat)
        _ = CompanionReducer.send("Second", clientMsgId: "mac-2", into: &chat)

        chat.receive(E.accepted("mac-1", duplicate: false))
        #expect(chat.pending.map(\.clientMsgId) == ["mac-2"])

        chat.receive(E.accepted("mac-2", duplicate: true, serverSeq: 14))
        #expect(chat.pending.isEmpty)
    }

    @Test("a blank message is not a message")
    func blankIsNotAMessage() {
        var chat = CompanionChat.holding(1...12)

        #expect(CompanionReducer.send(" \n\t", clientMsgId: "mac-1", into: &chat).isEmpty)
        #expect(chat.pending.isEmpty)
    }

    /// The daemon closes the connection over a line past its cap, and the
    /// outbox would send it again after every reconnect.
    @Test("a message past the line cap is refused before it enters the outbox")
    func messagePastTheCapIsRefused() {
        var chat = CompanionChat.holding(1...12)
        let text = String(repeating: "a", count: CompanionProtocol.maximumClientLineBytes)

        #expect(CompanionReducer.send(text, clientMsgId: "mac-1", into: &chat).isEmpty)
        #expect(chat.pending.isEmpty)
        #expect(chat.lastError == ProductStrings[.companionErrorMessageTooLong])

        _ = CompanionReducer.send("Shorter", clientMsgId: "mac-2", into: &chat)
        #expect(chat.lastError == nil)
    }

    @Test("a refusal naming a request takes it out of the outbox and says so")
    func refusalNamingARequest() {
        var chat = CompanionChat.holding(1...12)
        _ = CompanionReducer.send("Hello", clientMsgId: "mac-2", into: &chat)

        chat.receive(E.refusal("client_message_conflict", clientMsgId: "mac-2"))

        #expect(chat.pending.isEmpty)
        #expect(chat.lastError == "The daemon reported: client_message_conflict")
    }

    @Test("cancelling a request not yet accepted keeps it from ever being resent")
    func cancelLeavesTheOutbox() {
        var chat = CompanionChat.holding(1...12)
        _ = CompanionReducer.send("Hello", clientMsgId: "mac-3", into: &chat)

        #expect(CompanionReducer.cancel("mac-3", into: &chat) == [.cancel(profileId: "main", clientMsgId: "mac-3")])
        #expect(chat.pending.isEmpty)
        CompanionReducer.disconnected(&chat)
        #expect(chat.negotiated() == [historyPull(.after(seq: 12))])
    }

    // MARK: - Approvals

    @Test("an approval is held until it resolves, and each answer is its route sent as a command")
    func approvals() {
        var chat = CompanionChat.holding(1...12)
        chat.receive(E.approval("sandbox-1"))
        #expect(chat.approvals.map(\.approvalId) == ["sandbox-1"])

        let approve = CompanionReducer.answer("sandbox-1", approve: true, clientMsgId: "mac-2", into: &chat)
        let deny = CompanionReducer.answer("sandbox-1", approve: false, clientMsgId: "mac-3", into: &chat)

        #expect(approve == [.command(clientMsgId: "mac-2", profileId: "main", name: "confirm", args: "opaque-token")])
        #expect(deny == [.command(clientMsgId: "mac-3", profileId: "main", name: "deny", args: "opaque-token")])
        #expect(chat.pending.map(\.clientMsgId) == ["mac-2", "mac-3"])
        #expect(CompanionReducer.answer("sandbox-9", approve: true, clientMsgId: "mac-4", into: &chat).isEmpty)

        chat.receive(.approvalResolved(approvalId: "sandbox-1", outcome: .approved))
        #expect(chat.approvals.isEmpty)
    }

    @Test("an approval sent again is held once")
    func approvalHeldOnce() {
        var chat = CompanionChat.holding(1...12)

        chat.receive(E.approval("sandbox-1"))
        chat.receive(E.approval("sandbox-2"))
        chat.receive(E.approval("sandbox-1"))

        #expect(chat.approvals.map(\.approvalId) == ["sandbox-1", "sandbox-2"])
    }

    @Test("a route is a slash command named up to its first space")
    func commandRoutes() {
        let confirm = CompanionCommandRoute("/confirm opaque-token")
        let deny = CompanionCommandRoute("/deny")
        let ask = CompanionCommandRoute("/ask two words")

        #expect(confirm?.name == "confirm")
        #expect(confirm?.args == "opaque-token")
        #expect(deny?.name == "deny")
        #expect(deny?.args == nil)
        #expect(ask?.name == "ask")
        #expect(ask?.args == "two words")
        #expect(CompanionCommandRoute("confirm opaque-token") == nil)
        #expect(CompanionCommandRoute("/") == nil)
    }

    // MARK: - Search

    @Test("results are shown for the query asked, and a stale answer is not")
    func searchResults() {
        var chat = CompanionChat.holding(1...120)

        #expect(
            CompanionReducer.search("dentist", into: &chat)
                == [.historySearch(profileId: "main", query: "dentist", limit: CompanionProtocol.searchLimit, beforeSeq: nil)]
        )
        #expect(chat.search == CompanionSearch(query: "dentist", hits: nil, nextBeforeSeq: nil))

        chat.receive(E.results("dent", seqs: [70]))
        #expect(chat.search?.hits == nil)

        chat.receive(E.results("dentist", seqs: [88], older: 88))
        #expect(chat.search == CompanionSearch(query: "dentist", hits: [E.hit(88)], nextBeforeSeq: 88))

        CompanionReducer.clearSearch(&chat)
        chat.receive(E.results("dentist", seqs: [88]))
        #expect(chat.search == nil)
    }

    @Test("older hits are asked once from next_before_seq and extend the hits shown")
    func olderHits() {
        var chat = CompanionChat.holding(1...120)

        #expect(CompanionReducer.searchOlder(&chat).isEmpty, "no search is on screen")
        _ = CompanionReducer.search("dentist", into: &chat)
        #expect(CompanionReducer.searchOlder(&chat).isEmpty, "the first page is not answered yet")

        chat.receive(E.results("dentist", seqs: [100, 88], older: 88))
        #expect(
            CompanionReducer.searchOlder(&chat)
                == [.historySearch(profileId: "main", query: "dentist", limit: CompanionProtocol.searchLimit, beforeSeq: 88)]
        )
        #expect(chat.search?.olderHitsAsked == 88)
        #expect(CompanionReducer.searchOlder(&chat).isEmpty, "older hits are already asked for")

        chat.receive(E.results("dentist", seqs: [40]))
        #expect(chat.search == CompanionSearch(query: "dentist", hits: [E.hit(100), E.hit(88), E.hit(40)], nextBeforeSeq: nil))
        #expect(CompanionReducer.searchOlder(&chat).isEmpty, "the daemon said no older hits exist")
    }

    @Test("a dropped connection forgets the older hits it asked for")
    func disconnectForgetsOlderHits() {
        var chat = CompanionChat.holding(1...120)
        _ = CompanionReducer.search("dentist", into: &chat)
        chat.receive(E.results("dentist", seqs: [88], older: 88))
        _ = CompanionReducer.searchOlder(&chat)

        CompanionReducer.disconnected(&chat)

        #expect(chat.search == CompanionSearch(query: "dentist", hits: [E.hit(88)], nextBeforeSeq: 88))
        #expect(CompanionReducer.searchOlder(&chat).count == 1)
    }

    @Test("a query the daemon would refuse is not sent")
    func refusedQueries() {
        var chat = CompanionChat.holding(1...12)
        let longest = String(repeating: "é", count: CompanionProtocol.maximumSearchQueryLength)

        #expect(CompanionReducer.search("", into: &chat).isEmpty)
        #expect(CompanionReducer.search(longest + "e", into: &chat).isEmpty)
        #expect(chat.search == nil)
        #expect(CompanionReducer.search(longest, into: &chat).count == 1)
    }

    // MARK: - The read frontier

    @Test("the read frontier is sent once per newest row, and never behind the daemon's")
    func readFrontier() {
        var chat = CompanionChat.holding(1...12)

        #expect(CompanionReducer.newestRowSeen(&chat) == [.readState(profileId: "main", readUpToSeq: 12)])
        #expect(CompanionReducer.newestRowSeen(&chat).isEmpty)

        chat.receive(E.row(13))
        #expect(CompanionReducer.newestRowSeen(&chat) == [.readState(profileId: "main", readUpToSeq: 13)])

        chat.receive(E.row(14))
        chat.receive(.readState(profileId: "main", readUpToSeq: 14))
        #expect(CompanionReducer.newestRowSeen(&chat).isEmpty)
    }

    @Test("an empty timeline has no row to mark read")
    func emptyTimelineMarksNothing() {
        var chat = CompanionChat()

        #expect(CompanionReducer.newestRowSeen(&chat).isEmpty)
    }

    // MARK: - A dropped connection

    @Test("a dropped connection forgets its pull, its draft and its unanswered search")
    func disconnectForgetsWhatWillNotBeAnswered() {
        var chat = CompanionChat.holding(1...12)
        chat.receive(E.row(14))
        chat.receive(.textDelta(turnId: "turn-1", text: "Partial"))
        _ = CompanionReducer.search("dentist", into: &chat)
        _ = CompanionReducer.send("Hello", clientMsgId: "mac-1", into: &chat)

        CompanionReducer.disconnected(&chat)

        #expect(chat.historyPull == nil)
        #expect(chat.turn == nil)
        #expect(chat.search == nil)
        #expect(chat.pending.map(\.clientMsgId) == ["mac-1"])
        #expect(chat.seqs == Array(1...12))
    }

    @Test("an answered search survives a dropped connection")
    func answeredSearchSurvives() {
        var chat = CompanionChat.holding(1...12)
        _ = CompanionReducer.search("dentist", into: &chat)
        chat.receive(E.results("dentist", seqs: [8]))

        CompanionReducer.disconnected(&chat)

        #expect(chat.search?.hits == [E.hit(8)])
    }
}
