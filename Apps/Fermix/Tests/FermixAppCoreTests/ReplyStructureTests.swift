import Foundation
import SwiftUI
import Testing

@testable import FermixAppCore

/// The words between a reply's code blocks are read as the blocks they are
/// written as, by GitHub's rules kept to the set the phone draws: paragraphs,
/// lists with their nesting and numbers, tables with their alignment and
/// cells, and quotes. A heading stays a bold line of its paragraph.
@Suite("Reply structure")
struct ReplyStructureTests {
    private static let home = "/Users/me"

    /// A block as one short line: its kind and its words, a list's items a
    /// bar apart, each two spaces in for each depth, and a table's columns'
    /// alignments then its rows, cells a comma apart and rows a slash.
    static func described(_ block: ReplyBlock) -> String {
        switch block {
        case .prose(let words): return "prose " + String(words.characters)
        case .quote(let words): return "quote " + String(words.characters)
        case .code(let code): return "code \(code.language ?? "-") " + code.text
        case .list(let list): return "list " + list.items.map(described).joined(separator: " | ")
        case .table(let table): return "table " + described(table)
        }
    }

    private static func described(_ item: ReplyListItem) -> String {
        let mark: String
        switch item.marker {
        case .bullet: mark = "•"
        case .number(let number): mark = "\(number)."
        case .task(let done): mark = done ? "[x]" : "[ ]"
        }
        return String(repeating: "  ", count: item.depth) + mark + " " + String(item.words.characters)
    }

    private static func described(_ table: ReplyTable) -> String {
        let alignments = table.alignments.map { alignment -> String in
            switch alignment {
            case .leading: return "l"
            case .center: return "c"
            case .trailing: return "r"
            }
        }
        let rows = ([table.header] + table.rows).map { $0.map { String($0.characters) }.joined(separator: ",") }
        return alignments.joined() + " " + rows.joined(separator: " / ")
    }

    private static func described(_ text: String) -> [String] {
        ReplyText(markdown: text, home: home).blocks.map(described)
    }

    // MARK: - Paragraphs

    /// A paragraph ends at a blank line; the blank lines themselves are the
    /// room between blocks, however many there are.
    @Test("paragraphs are split at blank lines, and blank lines are no block")
    func paragraphs() {
        #expect(Self.described("a\nb\n\nc\n\n\n  \nd\n") == ["prose a\nb", "prose c", "prose d"])
        #expect(Self.described("\n\n  \n").isEmpty)
    }

    @Test("a heading is a bold line of its paragraph, as it was")
    func headingInParagraph() throws {
        let blocks = ReplyText(markdown: "## Plan\nFirst this.\n\n### Then\n- a", home: Self.home).blocks
        let plan = try #require(blocks.first?.prose)

        #expect(blocks.map(Self.described) == ["prose Plan\nFirst this.", "prose Then", "list • a"])
        #expect(plan.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    // MARK: - Lists

    @Test("a list item opens with a dash, a star or a plus, and the three make one list")
    func bullets() {
        #expect(Self.described("- a\n* b\n+ c") == ["list • a | • b | • c"])
        #expect(Self.described("-\ttabbed") == ["list • tabbed"])
    }

    /// The number a list shows is CommonMark's: its first item's as written
    /// and one more for each item after it, so a reply that numbers every
    /// item 1 still counts, and a list a code block cut in two goes on.
    @Test("a numbered list counts from its first number, with a point or a bracket")
    func numbers() {
        #expect(Self.described("1. a\n1. b\n1) c") == ["list 1. a | 2. b | 3. c"])
        #expect(Self.described("3. a\n7. b") == ["list 3. a | 4. b"])
        #expect(Self.described("1. a\n```\nx\n```\n2. b") == ["list 1. a", "code - x", "list 2. b"])
    }

    @Test("an item indented past the one before it is nested, at most two deep, and numbers count by depth")
    func nesting() {
        #expect(Self.described("- a\n  - b\n    - c\n      - d\n- e") == ["list • a |   • b |     • c |     • d | • e"])
        #expect(Self.described("1. a\n   - b\n   - c\n2. d") == ["list 1. a |   • b |   • c | 2. d"])
        #expect(Self.described("1. a\n   1. b\n   2. c\n2. d\n   1. e") == ["list 1. a |   1. b |   2. c | 2. d |   1. e"])
        #expect(Self.described("- a\n    - b\n  - c") == ["list • a |   • b |   • c"])
        #expect(Self.described("  - a\n- b") == ["list • a | • b"])
    }

    /// A line indented under an item carries it on, a blank line before it
    /// kept, and the next item may follow blank lines; a line that is not
    /// indented ends the list, blank lines before it or not.
    @Test("an indented line carries on its item, and an unindented one ends the list")
    func continuation() {
        #expect(Self.described("- a\n  more\n- b") == ["list • a\nmore | • b"])
        #expect(Self.described("1. a\n\n2. b\n\n   detail\n\nAfter") == ["list 1. a | 2. b\n\ndetail", "prose After"])
        #expect(Self.described("- a\nAfter") == ["list • a", "prose After"])
        #expect(Self.described("Steps:\n1. a") == ["prose Steps:", "list 1. a"])
    }

    @Test("a bullet whose words open with a box and a space is a task, done once ticked")
    func tasks() {
        #expect(Self.described("- [ ] buy\n- [x] sell\n* [X] hold\n- [ ]no\n1. [ ] numbered") == [
            "list [ ] buy | [x] sell | [x] hold | • [ ]no | 1. [ ] numbered",
        ])
    }

    /// CommonMark's rule for a list straight after a paragraph's line, so a
    /// wrapped sentence whose next line opens with a year is not a list.
    @Test("after a paragraph's line an item opens a list only with words after its mark, and numbered only from 1")
    func interruptions() {
        #expect(Self.described("The record was set in\n2024. Since then it has held.") == ["prose The record was set in\n2024. Since then it has held."])
        #expect(Self.described("Intro\n2. two\n3) three") == ["prose Intro\n2. two\n3) three"])
        #expect(Self.described("Intro\n1) one\n2. two") == ["prose Intro", "list 1. one | 2. two"])
        #expect(Self.described("Intro\n- a") == ["prose Intro", "list • a"])
        #expect(ReplyText(markdown: "Intro\n- \nmore", home: Self.home).blocks.map { $0.prose != nil } == [true])
        #expect(Self.described("Intro\n\n2024. A list after a blank line") == ["prose Intro", "list 2024. A list after a blank line"])
    }

    @Test("a mark with no space after it, emphasis and a decimal are words")
    func notItems() {
        let text = "-a\n**bold** start\n*em* text\n3.14 is pi\n1.5x faster\n#tag\n---\n1234567890. too long"

        #expect(Self.described(text) == ["prose " + text.replacingOccurrences(of: "**bold**", with: "bold").replacingOccurrences(of: "*em*", with: "em")])
    }

    // MARK: - Tables

    @Test("a table is a header over a delimiter row, its rows under it, each column aligned as it says")
    func table() {
        let text = "| Name | Price | Note | Size |\n|:-----|------:|:-:|---|\n| Tea | 3 | hot | s |\n| Cake | 5 | sweet | m |"

        #expect(Self.described(text) == ["table lrcl Name,Price,Note,Size / Tea,3,hot,s / Cake,5,sweet,m"])
        #expect(Self.described("a | b\n--- | ---\n1 | 2") == ["table ll a,b / 1,2"])
        #expect(Self.described("| one |\n|-|\n| 1 |") == ["table l one / 1"])
    }

    @Test("a row has the header's cells, short rows filled and long ones cut, and a cell's escaped bar is a bar")
    func cells() {
        let text = "| a \\| b | c |\n|---|---|\n| `x \\| y` | z | extra |\n| only |\n|  |  |"

        #expect(Self.described(text) == ["table ll a | b,c / x | y,z / only, / ,"])
    }

    @Test("a cell's words are inline markdown with their links")
    func cellMarkdown() throws {
        let reply = ReplyText(markdown: "| Place | Site |\n|---|---|\n| **Cafe** | [menu](https://cafe.example/menu) |", home: Self.home)
        guard case .table(let table) = reply.blocks.first else {
            Issue.record("no table")
            return
        }
        let place = try #require(table.rows.first?.first)

        #expect(String(place.characters) == "Cafe")
        #expect(place.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(reply.addresses.map(\.absoluteString) == ["https://cafe.example/menu"])
    }

    @Test("a table ends at a blank line or a line without a bar, and opens inside a paragraph")
    func tableEnds() {
        #expect(Self.described("Here:\n| a |\n|---|\n| 1 |\nAfter") == ["prose Here:", "table l a / 1", "prose After"])
        #expect(Self.described("| a |\n|---|\n\n| 1 |") == ["table l a", "prose | 1 |"])
    }

    @Test("a line with a bar is no table without a delimiter row of as many cells with a bar in it")
    func notTables() {
        #expect(Self.described("a | b\n---") == ["prose a | b\n---"])
        #expect(Self.described("a | b\n|---|") == ["prose a | b\n|---|"])
        #expect(Self.described("a | b\n| --- | x |") == ["prose a | b\n| --- | x |"])
        #expect(Self.described("| a | b |") == ["prose | a | b |"])
    }

    // MARK: - Quotes

    @Test("a quote is its lines that open with a mark, an empty one a break, and ends at the first that does not")
    func quotes() {
        #expect(Self.described("> a\n>b\n>\n> c\nAfter") == ["quote a\nb\n\nc", "prose After"])
        #expect(Self.described("   > three in\n    > four in") == ["quote three in", "prose     > four in"])
        #expect(Self.described("Said:\n> so") == ["prose Said:", "quote so"])
    }

    // MARK: - Reading

    @Test("the links of every block are read, in reading order")
    func linksInEveryBlock() {
        let text = "See https://a.example/1\n- in ~/work/list.md\n> quoted https://b.example/2\n\n| x |\n|---|\n| https://c.example/3 |"
        let reply = ReplyText(markdown: text, home: Self.home)

        #expect(reply.links.map(\.absoluteString) == [
            "https://a.example/1", "file:///Users/me/work/list.md", "https://b.example/2", "https://c.example/3",
        ])
    }

    /// The words can be cut after a blank line that ends a paragraph, a table
    /// or a quote, never inside a code block, after a list the next item may
    /// carry on, or at the last line, which may still be written.
    @Test("the words can be cut after a blank line that nothing before it can carry on over")
    func cuts() {
        func cut(_ text: String) -> String? {
            ReplyText.reading(text, home: Self.home).cut.map { String(text[..<$0.index]) }
        }

        #expect(cut("a\n\nb") == "a\n\n")
        #expect(cut("a\n\nb\n\nc") == "a\n\nb\n\n")
        #expect(cut("a\n") == nil)
        #expect(cut("- a\n\nb") == nil)
        #expect(cut("- a\n\nb\n\nc") == "- a\n\nb\n\n")
        #expect(cut("| a |\n|---|\n| 1 |\n\nx") == "| a |\n|---|\n| 1 |\n\n")
        #expect(cut("> a\n\nx") == "> a\n\n")
        #expect(cut("```\na\n\nb") == nil)
        #expect(cut("```\na\n```\n\nb") == "```\na\n```\n\n")
        #expect(ReplyText.reading("a\n\nb\n\nc", home: Self.home).cut?.blocks == 2)
    }

    // MARK: - Drawing

    @Test("a list's, a table's and a quote's words are drawn and marked as a paragraph's are")
    func drawn() throws {
        let blocks = ChatText.drawn(ReplyText(markdown: "- see [the notes](https://a.example)\n\n> a report\n\n| report |\n|---|\n| x |", home: Self.home))
        guard case .list(let list) = blocks[0], case .quote(let quote) = ChatText.drawn(blocks[1], marking: ["report"]),
              case .table(let table) = ChatText.drawn(blocks[2], marking: ["report"])
        else {
            Issue.record("the blocks are not a list, a quote and a table")
            return
        }
        let link = try #require(list.items.first?.words.runs.first { $0.link != nil })

        #expect(link.foregroundColor == Palette.accentText.color)
        #expect(quote.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(table.header.first?.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test("as one text, paragraphs are a blank line apart, a list's items follow their marks and a table's cells are a tab apart")
    func oneText() {
        let text = ChatText.oneText(ChatText.drawn(ReplyText(markdown: "One\n\nTwo\n- a\n  1. b\n\n| x | y |\n|---|---|\n| 1 | 2 |", home: Self.home)))

        #expect(String(text.characters) == "One\n\nTwo\n• a\n1. b\nx\ty\n1\t2")
    }

    @Test("Copy takes a table as text with tabs, a line for the header and one for each row")
    func tableText() {
        let reply = ReplyText(markdown: "| a | **b** |\n|---|---|\n| 1 | [two](https://two.example) |", home: Self.home)
        guard case .table(let table) = reply.blocks.first else {
            Issue.record("no table")
            return
        }

        #expect(table.text == "a\tb\n1\ttwo")
    }
}
