import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents
private typealias M = CompanionMediaRows

/// The reader's place as a value (M66 §3.8): the one item that a page landing
/// above them, or a held row changing height, must not move. No scroll view:
/// the transcript takes this from the items on screen before the change lands
/// and scrolls to it after.
@Suite("Chat place")
struct ChatPlaceTests {
    private static func items(_ seqs: ClosedRange<Int>) -> [ChatItem] {
        seqs.map { seq in
            .row(CompanionRow(serverSeq: seq, text: "row \(seq)", role: "assistant", timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil))
        }
    }

    private static func items(of chat: CompanionChat) -> [ChatItem] {
        ChatTimeline.items(rows: chat.rows, turn: chat.turn, approvals: chat.approvals, pending: chat.pending, lastError: chat.lastError)
    }

    /// A chat that holds rows 1 to 10, then took a voice note from the phone at
    /// 11 with its file, and took rows 12 to 20 after it.
    private static func chatWithAVoiceNoteAbove() -> CompanionChat {
        var chat = CompanionChat()
        _ = CompanionReducer.negotiated(&chat, onScreen: [])
        _ = CompanionReducer.receive(E.backward(Array(1...10), head: 10), into: &chat)
        _ = CompanionReducer.receive(M.announced(11, refs: [M.voice]), into: &chat)
        for seq in 12...20 {
            _ = CompanionReducer.receive(E.row(seq), into: &chat)
        }
        return chat
    }

    /// The engine stored the note's transcript, said so, and the read it asked
    /// for brought the note with its text.
    private static func transcribe(_ chat: inout CompanionChat) {
        _ = CompanionReducer.receive(M.updated(11), into: &chat)
        _ = CompanionReducer.receive(M.page([M.exported(11, text: "Pick up milk", refs: [M.voice])], head: 20), into: &chat)
    }

    @Test("a reader on the bottom edge is held there with the newest item, whatever it is")
    func bottomEdgeHoldsTheNewest() {
        let rows = Self.items(1...6)
        let sending = rows + [.pending(clientMsgId: "mac-1", text: "And then?")]

        #expect(ChatPlace(atBottom: true, visible: [.row(5), .row(6)], items: rows) == .newest(.row(6)))
        #expect(ChatPlace(atBottom: true, visible: [.row(6)], items: sending) == .newest(.pending("mac-1")))
    }

    @Test("a reader further up is held by the first item on screen in reading order, the older marker aside")
    func readerAboveIsHeldByTheTopItem() {
        let rows = Self.items(1...6)

        #expect(ChatPlace(atBottom: false, visible: [.row(4), .row(2), .row(3)], items: rows) == .top(.row(2)))
        #expect(ChatPlace(atBottom: false, visible: [.older, .row(1)], items: rows) == .top(.row(1)))
    }

    @Test("with nothing on screen there is no place to hold")
    func nothingOnScreen() {
        #expect(ChatPlace(atBottom: false, visible: [], items: Self.items(1...6)) == nil)
        #expect(ChatPlace(atBottom: true, visible: [], items: []) == nil)
    }

    @Test("a row read again above the reader is a change of height, and the item at the top of the view is held")
    func rowReadAgainAboveTheReader() {
        var chat = Self.chatWithAVoiceNoteAbove()
        let reading: Set<ChatItemID> = [.row(12), .row(13), .row(14)]
        let before = ChatPlace(atBottom: false, visible: reading, items: Self.items(of: chat))
        let published = chat.reshape

        Self.transcribe(&chat)

        #expect(chat.reshape != published)
        #expect(chat.reshape?.seqs == [11])
        #expect(before == .top(.row(12)))
        #expect(ChatPlace(atBottom: false, visible: reading, items: Self.items(of: chat)) == before)
    }

    @Test("a reader on the bottom edge follows the newest row through a change of height")
    func bottomEdgeFollowsThroughAChange() {
        var chat = Self.chatWithAVoiceNoteAbove()

        Self.transcribe(&chat)

        #expect(chat.reshape?.seqs == [11])
        #expect(ChatPlace(atBottom: true, visible: [.row(19), .row(20)], items: Self.items(of: chat)) == .newest(.row(20)))
    }

    /// The transcript tells the session which held rows are on screen, so a
    /// row read before a disconnect is read again as it comes into view
    /// (M66 §3.6). Scrolling changes the visible items far more often.
    @Test("the rows on screen are reported when they change, and only then")
    func rowsOnScreenAreReportedOnChange() {
        var shown = ChatRowsOnScreen()

        #expect(shown.update([.row(4), .row(5)]) == [4, 5])
        #expect(shown.update([.row(5), .row(4), .turn("turn-1")]) == nil)
        #expect(shown.update([.older, .row(1), .row(2)]) == [1, 2])
        #expect(shown.update([.pending("mac-1"), .error]) == [])
        #expect(shown.update([]) == nil)
    }
}
