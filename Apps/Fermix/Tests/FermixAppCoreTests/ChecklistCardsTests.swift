import Foundation
import Testing

@testable import FermixAppCore

/// What a reply's lists card draws (M85 §08): only the newest card of a list
/// is live, a one-list card's four open rows with the turn's first, and a
/// card of several lists' groups, each bounded.
@Suite("Checklist cards")
struct ChecklistCardsTests {
    private static func reply(_ seq: Int, _ lists: [CompanionChecklistRef]) -> CompanionRow {
        CompanionRow(reply: "turn-\(seq)", serverSeq: seq, text: "Done.", inReplyTo: nil, blocks: lists.isEmpty ? [] : [.checklists(lists)])
    }

    private static func ref(_ listId: String, _ rows: [String] = []) -> CompanionChecklistRef {
        CompanionChecklistRef(listId: listId, title: listId, rows: rows)
    }

    private static func item(_ id: String, done: Bool = false) -> CompanionChecklistRow {
        CompanionChecklistRow(rowId: id, kind: .item, text: id, done: done)
    }

    @Test("only the newest card that draws a list is live, and a card is live only when no newer card draws any of its lists")
    func newestCardPerList() {
        let rows = [
            Self.reply(1, [Self.ref("fermix")]),
            Self.reply(2, []),
            Self.reply(3, [Self.ref("fermix"), Self.ref("groceries")]),
            Self.reply(4, [Self.ref("packing")]),
            Self.reply(5, [Self.ref("groceries"), Self.ref("portfolio")]),
            Self.reply(6, [Self.ref("packing")])
        ]

        #expect(ChecklistCards.live(in: rows) == [5, 6])
        #expect(ChecklistCards.live(in: Array(rows.prefix(4))) == [3, 4])
        #expect(ChecklistCards.live(in: Array(rows.prefix(2))) == [1])
        #expect(ChecklistCards.live(in: []) == [])
    }

    @Test("a row's lists are its checklists block's, and a row with none has none")
    func listsOfARow() {
        let place = CompanionBlock.places([CompanionBlocksTests.example])
        let both = CompanionRow(reply: "turn-1", serverSeq: 1, text: "", inReplyTo: nil, blocks: [place, .checklists([Self.ref("fermix")])])

        #expect(ChecklistCards.lists(of: both) == [Self.ref("fermix")])
        #expect(ChecklistCards.lists(of: Self.reply(2, [])) == nil)
    }

    @Test("a one-list card holds at most four open items, the ones the turn touched first, and counts the rest")
    func oneListRows() {
        let list = CompanionChecklistList(listId: "packing", title: "Packing", rev: 1, rows: [
            Self.item("passport", done: true),
            CompanionChecklistRow(rowId: "trip", kind: .section, text: "Trip", done: nil),
            Self.item("charger"),
            Self.item("boots"),
            Self.item("sunscreen"),
            Self.item("jacket"),
            Self.item("book"),
            Self.item("adapter")
        ])

        let card = ChecklistCards.oneList(list, touched: ["jacket", "sunscreen", "passport"])

        #expect(card.rows.map(\.rowId) == ["sunscreen", "jacket", "charger", "boots"], "the turn's open items first, each part in the list's order")
        #expect(card.more == 2)

        let settling = ChecklistCards.oneList(list, touched: [], settling: ["passport"])
        #expect(settling.rows.first?.rowId == "passport", "a row ticked here a moment ago keeps its place while it settles")
        #expect(settling.more == 3)

        let short = ChecklistCards.oneList(CompanionChecklistList(listId: "l", title: "L", rev: 1, rows: [Self.item("a")]), touched: [])
        #expect(short.rows.map(\.rowId) == ["a"])
        #expect(short.more == 0)
    }

    @Test("a card of several lists draws three groups of at most three touched rows, a ticked row as it stands, and names the rest")
    func groupLimits() {
        let refs = [
            Self.ref("fermix", ["a", "b", "c", "d", "gone"]),
            Self.ref("portfolio", ["p"]),
            Self.ref("groceries"),
            Self.ref("packing", ["x"]),
            Self.ref("garden", ["y"])
        ]
        let lists: [String: CompanionChecklistList] = [
            "fermix": CompanionChecklistList(listId: "fermix", title: "Fermix", rev: 1, rows: ["d", "c", "b", "a"].map { Self.item($0, done: $0 == "b") }),
            "portfolio": CompanionChecklistList(listId: "portfolio", title: "Portfolio site", rev: 1, rows: [Self.item("p")])
        ]

        let card = ChecklistCards.groups(refs) { lists[$0] }

        #expect(card.groups.map(\.ref.listId) == ["fermix", "portfolio", "groceries"])
        #expect(card.groups[0].rows.map(\.rowId) == ["a", "b", "c"], "the turn's order, at most three, a removed row skipped")
        #expect(card.groups[0].rows[1].isDone, "a row the turn ticked shows done")
        #expect(card.groups[1].rows.map(\.rowId) == ["p"])
        #expect(card.groups[2].rows.isEmpty, "a list the turn only read is its name line")
        #expect(card.moreLists == 2)

        let two = ChecklistCards.groups(Array(refs.prefix(2))) { lists[$0] }
        #expect(two.moreLists == 0)
    }
}
