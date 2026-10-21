import Foundation
import Testing

@testable import FermixAppCore

/// A turn's draft reads only what is still being written, and still reads,
/// at every point, exactly as the whole draft does at once: the rule OpenUI's
/// streaming parser states, held here over replies that use every block, fed
/// a scalar at a time, so a piece may end inside a line ending or a cluster.
@Suite("Reply draft")
struct ReplyDraftTests {
    private static let home = "/Users/me"

    static let replies: [String] = [
        "## Plan\nHere is what I found in ~/work/notes.md and at https://example.com/a.\n\n"
            + "A second paragraph with **bold**, `code` and [a link](https://example.org).\n\n\nThird, after two blank lines.\n",
        "Steps:\n1. Install the tools\n   - brew install x\n   - brew install y\n2. Run it\n\n   It takes a minute.\n\n"
            + "3. Check the output\n\nThen:\n- [ ] write tests\n- [x] ship\n  * nested one\n    + deeper\n      - deepest\n\nDone.",
        "| Name | Price | Notes |\n|:-----|------:|:-----:|\n| **Tea** | $3 | hot \\| iced |\n| [Cake](https://cake.example) | $5 |\n"
            + "| Pie | $4 | a | extra |\nAfter the table.\n\na | b\n--- | ---\n1 | 2\n",
        "> Quoted line one\n> # Quoted heading\n>\n> more\nNot quoted.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n"
            + "> after code\n\n~~~\nopen fence that never closes\n\n- not a list",
        "Para one\r\n\r\n- a\r\n- b\r\n\r\nPara two\r\n\r\n| x | y |\r\n|---|---|\r\n| 1 | 2 |\r\n",
        "\n\n\tIndented with a tab\n\n- café ☕️\n\t- tabbed nested\n\n1) one\n2) two\n\n👩‍👩‍👧 family\n\n> 引用\n",
        "The record was set in\n2024. Since then it has held.\n\nIntro\n2. two\n- \nmore\n\nSteps:\n1. one\n2. two\n\n1999. A list\n",
    ]

    @Test("fed a scalar at a time, a draft reads at every point as the whole of it does", arguments: replies.indices)
    func everyPrefix(_ which: Int) {
        let draft = ReplyDraft()
        var text = ""
        for scalar in Self.replies[which].unicodeScalars {
            text.unicodeScalars.append(scalar)

            #expect(draft.blocks(text, home: Self.home) == ReplyText(markdown: text, home: Self.home).blocks, "\(text.debugDescription)")
        }
    }

    /// A piece of a draft may carry several lines, so a cut is found inside
    /// it rather than at its start.
    @Test("fed in pieces of every size, a draft reads as the whole of it does", arguments: [2, 5, 13, 64])
    func pieces(_ size: Int) {
        for reply in Self.replies {
            let draft = ReplyDraft()
            let scalars = Array(reply.unicodeScalars)
            for end in stride(from: size, through: scalars.count + size - 1, by: size) {
                var text = ""
                text.unicodeScalars.append(contentsOf: scalars.prefix(end))

                #expect(draft.blocks(text, home: Self.home) == ReplyText(markdown: text, home: Self.home).blocks, "\(text.debugDescription)")
            }
        }
    }

    /// What the draft keeps is the words up to its last cut, so each piece
    /// reads only the block still being written.
    @Test("a draft keeps every finished paragraph and reads only the one still being written")
    func keeps() {
        let draft = ReplyDraft()

        _ = draft.blocks("One.\n\nTwo.\n\nThr", home: Self.home)
        #expect(draft.keptText == "One.\n\nTwo.\n\n")

        _ = draft.blocks("One.\n\nTwo.\n\nThree.\n- a\n\n- b", home: Self.home)
        #expect(draft.keptText == "One.\n\nTwo.\n\n")

        _ = draft.blocks("One.\n\nTwo.\n\nThree.\n- a\n\n- b\n\nAfter.\n\n", home: Self.home)
        #expect(draft.keptText == "One.\n\nTwo.\n\nThree.\n- a\n\n- b\n\nAfter.\n\n")
    }

    @Test("a draft that does not carry on the one kept, or reads home elsewhere, is read again from its start")
    func readAgain() {
        let draft = ReplyDraft()
        _ = draft.blocks("A ~/a.md\n\nB\n\nC", home: Self.home)

        #expect(draft.blocks("X\n\nY", home: Self.home) == ReplyText(markdown: "X\n\nY", home: Self.home).blocks)
        #expect(draft.blocks("X\n\nY ~/b.md", home: "/Users/you") == ReplyText(markdown: "X\n\nY ~/b.md", home: "/Users/you").blocks)
    }
}
