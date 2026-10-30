import Foundation
import Testing

@testable import FermixAppCore

/// A finished row, and each part of a reply, is drawn again only when what
/// it draws changes. SwiftUI asks a view marked equatable whether it changed
/// before drawing it again, so a publish that changes one row leaves every
/// other row, and every part of a turn but the one being written, as drawn,
/// its words never coloured again.
@Suite("Reply rows")
struct ChatReplyRowTests {
    private static func row(
        _ text: String = "Saved it.",
        role: String? = CompanionProtocol.assistantRole,
        previews: [CompanionLinkPreview] = []
    ) -> CompanionRow {
        CompanionRow(serverSeq: 7, text: text, role: role, timestamp: "t", clientMsgId: nil, inReplyTo: nil, turnId: nil, linkPreviews: previews)
    }

    /// The row is compared whole, so a field a row gains is never missed.
    @Test("a finished row is drawn again only when the row or the words a search marks in it change")
    func rowEquality() {
        let row = ChatRow(row: Self.row(), marked: [])
        let preview = CompanionLinkPreview(link: nil, url: "https://a.example", site: "A", title: "A", description: nil, imageRef: nil)

        #expect(row == ChatRow(row: Self.row(), marked: []))
        #expect(row != ChatRow(row: Self.row("Saved it again."), marked: []))
        #expect(row != ChatRow(row: Self.row(previews: [preview]), marked: []))
        #expect(row != ChatRow(row: Self.row(role: CompanionProtocol.userRole), marked: []))
        #expect(row != ChatRow(row: Self.row(), marked: ["saved"]))
    }

    /// Paragraphs a blank line apart are one text, so a reader selects
    /// across them; any other block ends the run.
    @Test("a run of paragraphs is one part, and every other block is a part of its own")
    func parts() {
        let blocks = ReplyText(markdown: "One.\n\nTwo.\n\n- three\n\nFour.\n\n```\nfive\n```\nSix.", home: "/Users/me").blocks
        let parts = ChatReplyPart.parts(of: blocks).map { part -> String in
            switch part {
            case .paragraphs(let run): return run.map { String($0.characters) }.joined(separator: "+")
            case .block(let block): return ReplyStructureTests.described(block)
            }
        }

        #expect(parts == ["One.+Two.", "list • three", "Four.", "code - five", "Six."])
    }

    @Test("a part is drawn again only when its words, the words a search marks in it or its links' titles change")
    func partEquality() {
        let parts = ChatReplyPart.parts(of: ReplyText(markdown: "One.\n\nTwo.\n- three", home: "/Users/me").blocks)
        let part = ChatReplyPartView(part: parts[0], marked: [], titles: .none, speaker: nil)
        let again = ChatReplyPart.parts(of: ReplyText(markdown: "One.\n\nTwo.", home: "/Users/me").blocks)
        let titled = ChatLinkTitles([CompanionLinkPreview(link: "https://a.example", url: "https://a.example", site: "A", title: "A", description: nil, imageRef: nil)])

        #expect(part == ChatReplyPartView(part: again[0], marked: [], titles: .none, speaker: nil))
        #expect(part != ChatReplyPartView(part: parts[1], marked: [], titles: .none, speaker: nil))
        #expect(part != ChatReplyPartView(part: parts[0], marked: ["one"], titles: .none, speaker: nil))
        #expect(part != ChatReplyPartView(part: parts[0], marked: [], titles: titled, speaker: nil))
    }

    @Test("the transcript draws each finished row, each part of a reply and each run of its words through its equality")
    func drawnThroughEquality() throws {
        let rows = try #require(SourceTree.swiftFiles(matching: "Chat/ChatRows.swift").first?.text)
        let prose = try #require(SourceTree.swiftFiles(matching: "Chat/ChatProse.swift").first?.text)

        #expect(rows.contains("ChatRow(row: row, marked: marked)\n                .equatable()"))
        #expect(rows.contains("ChatReplyPartView(part: part, marked: marked, titles: titles, speaker: speaker)\n                    .equatable()"))
        #expect(rows.contains("ChatProse(paragraphs: paragraphs, marked: marked, titles: titles, speaker: speaker)\n            .equatable()"))
        #expect(prose.contains("static func == (lhs: ChatProse, rhs: ChatProse) -> Bool"))
    }
}
