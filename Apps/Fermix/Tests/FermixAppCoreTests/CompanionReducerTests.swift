import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents
private typealias M = CompanionMediaRows

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

    fileprivate func row(_ seq: Int) -> CompanionRow? {
        rows.first { $0.serverSeq == seq }
    }
}

/// The chat's state machine: the contract's client cursor rule, the queue of
/// reads, rows kept current, the outbox, turns, approvals, search and the read
/// frontier, with no socket and no clock.
@Suite("Companion reducer")
struct CompanionReducerTests {
    // MARK: - The catch-up read

    /// `after_seq: 0` reads the oldest page. A client that holds nothing wants
    /// the newest, which only `before_seq` reaches.
    @Test("a cold start asks for the newest page")
    func coldStartPullsTheNewestPage() {
        var chat = CompanionChat()

        #expect(chat.negotiated() == [newestPagePull])
        #expect(chat.historyPull == .catchUp(.before(seq: Int.max)))
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

    /// Version 2: during a voice call a typed message may be material for the
    /// call rather than a request, and the agent may leave it unanswered.
    @Test("a turn that wrote no reply ends with nothing kept and nothing said")
    func turnDoneEndsQuietly() {
        var chat = CompanionChat.holding(1...12)
        chat.receive(.turnStarted(profileId: "main", turnId: "turn-mac-5", inReplyTo: "mac-5"))
        chat.receive(.textDelta(turnId: "turn-mac-5", text: "Partial"))

        chat.receive(.turnDone(turnId: "turn-mac-5"))

        #expect(chat.turn == nil)
        #expect(chat.lastError == nil)
        #expect(chat.seqs == Array(1...12))
    }

    @Test("another turn's turn_done leaves the turn being answered alone")
    func turnDoneForAnotherTurn() {
        var chat = CompanionChat.holding(1...12)
        chat.receive(.turnStarted(profileId: "main", turnId: "turn-mac-6", inReplyTo: "mac-6"))

        chat.receive(.turnDone(turnId: "turn-mac-5"))

        #expect(chat.turn?.turnId == "turn-mac-6")
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

    // MARK: - The queue of reads

    /// A page does not say which read it answers, so one is out at a time and
    /// the rest wait their turn: the catch-up read, then paging, then rows
    /// read again (M66 §3.6).
    @Test("reads are served catch-up first, then paging, then rows read again")
    func readsAreServedInOrder() {
        var chat = CompanionChat.holding(1...10, older: true)
        #expect(chat.receive(M.voiceNote(11)) == [M.read(after: 10, limit: 1)])
        chat.receive(M.page([M.note(11)], head: 11))

        // While the catch-up read is out, the voice note is due a read and the
        // reader reaches the top: both wait.
        #expect(chat.receive(E.row(13)) == [historyPull(.after(seq: 11))])
        #expect(chat.receive(E.row(12, role: "assistant")).isEmpty)
        #expect(CompanionReducer.pullOlder(&chat).isEmpty)
        #expect(chat.olderWaiting == 1)
        #expect(chat.rowsToRead == [11, 12])

        // The catch-up page brings 12, so the row read is left with the note.
        #expect(chat.receive(E.forward([12, 13], head: 13, next: 13)) == [historyPull(.before(seq: 1))])
        #expect(chat.receive(E.backward([], head: 13)) == [M.read(after: 10, limit: 1)])
        #expect(chat.receive(M.page([M.note(11, text: "Pick up milk")], head: 13)).isEmpty)
        #expect(chat.historyPull == nil)
    }

    @Test("a page that stops below the head is read on before any read waiting")
    func catchUpGoesBeforeWaitingReads() {
        var chat = CompanionChat.holding(1...10, older: true)
        chat.receive(M.announced(11))
        _ = CompanionReducer.pullOlder(&chat)

        // Rows were written while the row read was out.
        #expect(chat.receive(M.page([M.exported(11, refs: [M.picture])], head: 14)) == [historyPull(.after(seq: 11))])
        #expect(chat.receive(E.forward([12, 13, 14], head: 14, next: 14)) == [historyPull(.before(seq: 1))])
    }

    @Test("rows asked to be read while a read is out wait as one read of just the rows they span")
    func rowsToReadWaitAsOne() {
        var chat = CompanionChat.holding(1...10)

        #expect(chat.receive(M.announced(11, role: "assistant")) == [M.read(after: 10, limit: 1)])
        #expect(chat.receive(M.announced(12, role: "assistant")).isEmpty)
        #expect(chat.receive(M.announced(13, role: "assistant")).isEmpty)

        #expect(
            chat.receive(M.page([M.exported(11, role: "assistant", refs: [M.picture])], head: 13))
                == [M.read(after: 11, limit: 2)]
        )
    }

    @Test("a page for a cursor already waiting or out is asked once")
    func pagingIsAskedOncePerCursor() {
        var chat = CompanionChat.holding(8...10, older: true)
        chat.receive(E.row(12))

        #expect(CompanionReducer.pullOlder(&chat).isEmpty)
        #expect(CompanionReducer.pullOlder(&chat).isEmpty)
        #expect(chat.receive(E.forward([11, 12], head: 12, next: 12)) == [historyPull(.before(seq: 8))])
        #expect(CompanionReducer.pullOlder(&chat).isEmpty)
        #expect(chat.olderWaiting == nil)
    }

    /// A page stops at about 60 KiB, so a long row can end a row read early.
    @Test("a row read that a page did not reach is read on from where the page stopped")
    func rowReadReadsOnPastAShortPage() {
        var chat = CompanionChat.holding(1...10, older: true)
        _ = CompanionReducer.pullOlder(&chat)
        chat.receive(M.announced(11, role: "assistant"))
        chat.receive(M.announced(12, role: "assistant"))

        #expect(chat.receive(E.backward([], head: 12)) == [M.read(after: 10, limit: 2)])
        #expect(
            chat.receive(M.page([M.exported(11, role: "assistant", refs: [M.picture])], head: 12))
                == [M.read(after: 11, limit: 1)]
        )
        #expect(chat.receive(M.page([], head: 12)).isEmpty)
        #expect(chat.rowsToRead.isEmpty)
        #expect(chat.historyPull == nil)
    }

    @Test("a row read asks from just below its lowest row for no more than one page, and nothing is no read")
    func rowReadSpansAtMostAPage() {
        #expect(CompanionRowRead([40])?.afterSeq == 39)
        #expect(CompanionRowRead([40])?.limit == 1)
        #expect(CompanionRowRead([40, 44])?.limit == 5)
        #expect(CompanionRowRead([1, 500])?.limit == CompanionProtocol.historyPageLimit)
        #expect(CompanionRowRead([]) == nil)
    }

    @Test("rows being read when the connection drops are read after the next catch-up; a page asked for is not")
    func rowReadsOutliveADroppedConnection() {
        var chat = CompanionChat.holding(1...10, older: true)
        chat.receive(M.announced(11))
        _ = CompanionReducer.pullOlder(&chat)

        CompanionReducer.disconnected(&chat)

        #expect(chat.olderWaiting == nil)
        #expect(chat.negotiated() == [historyPull(.after(seq: 11))])
        #expect(chat.receive(E.forward([], head: 11, next: 11)) == [M.read(after: 10, limit: 1)])
    }

    // MARK: - Keeping rows current, stage 1

    @Test("a media row announced is read once for its files, and a row of another kind is not")
    func mediaRowIsReadOnce() {
        var chat = CompanionChat.holding(1...10)

        #expect(chat.receive(M.announced(11, role: "assistant")) == [M.read(after: 10, limit: 1)])
        #expect(chat.row(11)?.mediaRefs == [])
        #expect(chat.receive(E.row(12)).isEmpty)

        #expect(chat.receive(M.page([M.exported(11, role: "assistant", refs: [M.picture])], head: 12)).isEmpty)
        #expect(chat.row(11)?.mediaRefs == [M.picture])
        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.receive(E.row(13, role: "assistant")).isEmpty)
    }

    /// The engine writes its reply to a voice note only once the transcript
    /// is stored or has failed, so an assistant's row is when to read the
    /// note, and the page says whether that row is the note's reply.
    @Test("an assistant row reads a waiting voice note up to itself; a user row and this Mac's own reply do not")
    func voiceNoteIsReadUpToItsReply() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.voiceNote(11))
        chat.receive(M.page([M.note(11)], head: 11))
        #expect(chat.awaitingTranscript == [11: M.request(11)])

        #expect(chat.receive(E.row(12)).isEmpty)
        #expect(chat.receive(.textDone(turnId: "turn-mac-1", serverSeq: 13, text: "Noted.")).isEmpty)
        #expect(chat.awaitingTranscript == [11: M.request(11)])

        #expect(chat.receive(E.row(14, role: "assistant")) == [M.read(after: 10, limit: 4)])
        let page = [M.note(11, text: "Pick up milk"), E.exported(12), E.exported(13), M.reply(14, to: 11, text: "Added to your list.")]
        #expect(chat.receive(M.page(page, head: 14)).isEmpty)
        #expect(chat.row(11)?.text == "Pick up milk")
        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.receive(E.row(15, role: "assistant")).isEmpty)
    }

    @Test("a delivery between a voice note and its reply costs one read, and the note waits on until its reply settles it")
    func deliveryLeavesTheNoteWaiting() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.voiceNote(11))
        chat.receive(M.page([M.note(11)], head: 11))

        #expect(chat.receive(E.row(12, role: "assistant")) == [M.read(after: 10, limit: 2)])
        #expect(chat.receive(M.page([M.note(11), E.exported(12)], head: 12)).isEmpty)
        #expect(chat.awaitingTranscript == [11: M.request(11)])

        #expect(chat.receive(E.row(13, role: "assistant")) == [M.read(after: 10, limit: 3)])
        let page = [M.note(11, text: "Pick up milk"), E.exported(12), M.reply(13, to: 11, text: "Added to your list.")]
        #expect(chat.receive(M.page(page, head: 13)).isEmpty)
        #expect(chat.row(11)?.text == "Pick up milk")
        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.receive(E.row(14, role: "assistant")).isEmpty)
    }

    @Test("a reply saying a voice note could not be transcribed settles it with no text")
    func failedTranscriptIsSettledByItsReply() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.voiceNote(11))
        chat.receive(M.page([M.note(11)], head: 11))

        #expect(chat.receive(E.row(12, role: "assistant")) == [M.read(after: 10, limit: 2)])
        let page = [M.note(11), M.reply(12, to: 11, text: "I couldn't transcribe that voice note.")]
        #expect(chat.receive(M.page(page, head: 12)).isEmpty)
        #expect(chat.row(11)?.text == "")
        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.receive(E.row(13, role: "assistant")).isEmpty)
    }

    /// A reply can reach a page ahead of its own announcement, or after a
    /// reconnect lost it, in a page that does not carry the note.
    @Test("a page bringing a voice note's reply without the note reads the note once more, and that read is final")
    func replyWithoutItsNoteReadsTheNote() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.voiceNote(11))
        chat.receive(M.page([M.note(11)], head: 11))

        #expect(chat.receive(E.row(13)) == [historyPull(.after(seq: 11))])
        let page = [M.reply(12, to: 11, text: "Added to your list."), E.exported(13)]
        #expect(chat.receive(M.page(page, head: 13)) == [M.read(after: 10, limit: 1)])
        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.receive(M.page([M.note(11, text: "Pick up milk")], head: 13)).isEmpty)
        #expect(chat.row(11)?.text == "Pick up milk")
    }

    /// A reply comes soon after its note; one that has not come a page of
    /// rows later is not waited for, so no read ever spans more than a page.
    @Test("a voice note is waited for no more once an assistant row is announced a page of rows past it")
    func waitEndsAPageOfRowsOn() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.voiceNote(11))
        chat.receive(M.page([M.note(11)], head: 11))

        #expect(chat.receive(E.row(210, role: "assistant")) == [historyPull(.after(seq: 11))])
        #expect(chat.rowsToRead == [11, 210])
        #expect(CompanionRowRead(chat.rowsToRead)?.limit == CompanionProtocol.historyPageLimit)
        #expect(chat.awaitingTranscript == [11: M.request(11)])

        chat.receive(E.row(211, role: "assistant"))
        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.rowsToRead == [11, 210])
    }

    @Test("a media row from the person that records no request is not waited for")
    func noteWithoutARequestIsNotWaitedFor() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.announced(11))
        chat.receive(M.page([M.exported(11, refs: [M.voice])], head: 11))

        #expect(chat.awaitingTranscript.isEmpty)
        #expect(chat.receive(E.row(12, role: "assistant")).isEmpty)
    }

    @Test("a voice note read at launch or by paging with no text is final as read")
    func voiceNoteFromHistoryIsNotReadAgain() {
        var chat = CompanionChat()
        chat.negotiated()
        chat.receive(
            .historyPage(
                CompanionHistoryPage(
                    profileId: E.profile,
                    messages: [E.exported(9), M.exported(10, refs: [M.voice])],
                    historyHeadSeq: 10,
                    nextAfterSeq: nil,
                    nextBeforeSeq: 9
                )
            )
        )
        _ = CompanionReducer.pullOlder(&chat)
        chat.receive(
            .historyPage(
                CompanionHistoryPage(
                    profileId: E.profile,
                    messages: [M.exported(8, refs: [M.voice])],
                    historyHeadSeq: 10,
                    nextAfterSeq: nil,
                    nextBeforeSeq: nil
                )
            )
        )

        #expect(chat.receive(E.row(11, role: "assistant")).isEmpty)
        #expect(chat.rowsToRead.isEmpty)
    }

    @Test("a media row that a page brings needs no read of its own")
    func pageBroughtRowIsNotReadAgain() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(E.row(12))

        #expect(chat.receive(M.announced(11, role: "assistant")).isEmpty)
        #expect(chat.rowsToRead == [11])
        #expect(
            chat.receive(M.page([M.exported(11, role: "assistant", refs: [M.picture]), E.exported(12)], head: 12))
                .isEmpty
        )
        #expect(chat.rowsToRead.isEmpty)
    }

    // MARK: - Replacing a row

    @Test("a row read again replaces the held one at its seq, and says its height changed")
    func replacedRowIsAChange() {
        var chat = CompanionChat.holding(1...10)
        chat.receive(M.announced(11, role: "assistant"))

        chat.receive(M.page([M.exported(11, role: "assistant", refs: [M.picture])], head: 11))

        #expect(chat.seqs == Array(1...11))
        #expect(chat.row(11)?.mediaRefs == [M.picture])
        #expect(chat.reshape?.seqs == [11])
    }

    /// A reply held from its `text_done` comes back with its role and time:
    /// nothing it draws changed.
    @Test("a row brought again with the same text, files and previews is no change of height")
    func unchangedRowIsNoChange() {
        var chat = CompanionChat.holding(8...10)
        chat.receive(.textDone(turnId: "turn-1", serverSeq: 11, text: "row 11"))
        chat.receive(E.row(13))

        chat.receive(E.forward([11, 12, 13], head: 13, next: 13))

        #expect(chat.row(11)?.role == "assistant")
        #expect(chat.reshape == nil)
    }
}
