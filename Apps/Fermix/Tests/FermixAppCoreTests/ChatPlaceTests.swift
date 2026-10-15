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
    /// 11, read it for its file, and took rows 12 to 20 after it.
    private static func chatWithAVoiceNoteAbove() -> CompanionChat {
        var chat = CompanionChat()
        _ = CompanionReducer.negotiated(&chat)
        _ = CompanionReducer.receive(E.backward(Array(1...10), head: 10), into: &chat)
        _ = CompanionReducer.receive(M.announced(11, request: M.request(11)), into: &chat)
        _ = CompanionReducer.receive(M.page([M.exported(11, refs: [M.voice], request: M.request(11))], head: 11), into: &chat)
        for seq in 12...20 {
            _ = CompanionReducer.receive(E.row(seq), into: &chat)
        }
        return chat
    }

    /// The read the reply at 21 asks for: the note, now with its transcript,
    /// up to the reply, which says what its announcement said.
    private static let transcribed = [M.exported(11, text: "Pick up milk", refs: [M.voice], request: M.request(11))]
        + (12...20).map(E.exported)
        + [M.reply(21, to: 11, text: "row 21")]

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

        _ = CompanionReducer.receive(E.row(21, role: "assistant"), into: &chat)
        _ = CompanionReducer.receive(M.page(Self.transcribed, head: 21), into: &chat)

        #expect(chat.reshape != published)
        #expect(chat.reshape?.seqs == [11])
        #expect(before == .top(.row(12)))
        #expect(ChatPlace(atBottom: false, visible: reading, items: Self.items(of: chat)) == before)
    }

    @Test("a reader on the bottom edge follows the newest row through a change of height")
    func bottomEdgeFollowsThroughAChange() {
        var chat = Self.chatWithAVoiceNoteAbove()

        _ = CompanionReducer.receive(E.row(21, role: "assistant"), into: &chat)
        _ = CompanionReducer.receive(M.page(Self.transcribed, head: 21), into: &chat)

        #expect(chat.reshape?.seqs == [11])
        #expect(ChatPlace(atBottom: true, visible: [.row(20), .row(21)], items: Self.items(of: chat)) == .newest(.row(21)))
    }
}
