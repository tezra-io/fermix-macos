import AppKit
import Foundation
import SwiftUI
import Testing

@testable import FermixAppCore

/// A reply as one text (`ChatReplyDocument`): every block in it in reading
/// order, so a selection runs from its first word to its last; tables and
/// code blocks held in text blocks; copied as a person would paste it; and
/// set again only where it changed.
@MainActor
@Suite("Reply document")
struct ChatReplyDocumentTests {
    private static let style = ChatProseStyle(size: ChatMetrics.readingType.size)

    private static func drawn(_ markdown: String) -> NSAttributedString {
        ChatProseTests.drawn(markdown)
    }

    private static func paragraphStyle(at words: String, in text: NSAttributedString) throws -> NSParagraphStyle {
        let at = try ChatProseTests.range(of: words, in: text).location
        return try #require(text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
    }

    private static let mixed = """
        ## What I found

        Yes, it **runs code**.

        1. Clone the repository.
        2. Install `uv`.

        | Agent | Runs code |
        | --- | :-: |
        | Instinct | Yes |

        > Pauses between turns.

        ```python
        print("hi")
        ```

        Done.
        """

    @Test("every block of a reply is in one text, in reading order")
    func oneText() {
        let text = Self.drawn(Self.mixed)

        #expect(text.string == "What I found\nYes, it runs code.\n1.\tClone the repository.\n2.\tInstall uv.\nAgent\nRuns code\nInstinct\nYes\nPauses between turns.\nprint(\"hi\")\nDone.")
    }

    @Test("a heading is semibold and larger than the words, with more room above it than under it")
    func heading() throws {
        let text = Self.drawn("Intro.\n\n## What I found\n\nWords.")
        let heading = try #require(text.attribute(.font, at: try ChatProseTests.range(of: "What", in: text).location, effectiveRange: nil) as? NSFont)
        let words = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        #expect(heading.pointSize > words.pointSize)
        #expect(Double(try Self.paragraphStyle(at: "What I found", in: text).paragraphSpacingBefore) == ChatMetrics.headingGap)
        #expect(Double(try Self.paragraphStyle(at: "Words.", in: text).paragraphSpacingBefore) == ChatMetrics.underHeadingGap)
    }

    @Test("a list item hangs its later lines under its words, past its mark")
    func listItem() throws {
        let text = Self.drawn("- one\n  more of one\n- two")
        let first = try Self.paragraphStyle(at: "one", in: text)
        let later = try Self.paragraphStyle(at: "more of one", in: text)

        #expect(first.firstLineHeadIndent < first.headIndent)
        #expect(first.tabStops.first?.location == first.headIndent)
        #expect(later.firstLineHeadIndent == first.headIndent)
    }

    @Test("a table's cells and a code block's lines are held in text blocks, and a paragraph is not")
    func blocks() throws {
        let text = Self.drawn(Self.mixed)
        let cell = try Self.paragraphStyle(at: "Instinct", in: text)
        let code = try Self.paragraphStyle(at: "print", in: text)
        let quote = try Self.paragraphStyle(at: "Pauses", in: text)

        #expect(cell.textBlocks.first is NSTextTableBlock)
        #expect((cell.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns == 2)
        #expect(code.textBlocks.first is ChatCodeTextBlock)
        #expect(quote.textBlocks.first is NSTextTableBlock)
        #expect(try Self.paragraphStyle(at: "Done.", in: text).textBlocks.isEmpty)
        #expect(try Self.paragraphStyle(at: "Yes, it", in: text).textBlocks.isEmpty)
    }

    /// Every line of a code block is in one block, so its fill is one.
    @Test("every line of a code block is in the same block")
    func codeLines() throws {
        let text = Self.drawn("```\na\nb\n```")
        let first = try Self.paragraphStyle(at: "a", in: text)
        let second = try Self.paragraphStyle(at: "b", in: text)

        #expect(first.textBlocks.first === second.textBlocks.first)
    }

    @Test("copied, a table's cells are a tab apart and its rows a line apart, and a task's box is its markdown")
    func plainText() {
        let table = Self.drawn("| a | b |\n|---|---|\n| 1 | 2 |")
        let tasks = Self.drawn("- [x] done\n- [ ] open")

        #expect(ChatReplyPlainText.text(of: table, in: NSRange(location: 0, length: table.length)) == "a\tb\n1\t2")
        #expect(ChatReplyPlainText.text(of: tasks, in: NSRange(location: 0, length: tasks.length)) == "[x]\tdone\n[ ]\topen")
    }

    @Test("copied, a link's caution mark is nothing")
    func cautionCopied() {
        let text = Self.drawn("Pay at [seedswap.example/order](https://seedswap-orders.example/checkout) today.")

        #expect(ChatReplyPlainText.text(of: text, in: NSRange(location: 0, length: text.length)) == "Pay at seedswap.example/order today.")
    }

    /// A turn being written changes only its last block, so every block
    /// before it keeps the piece it was set as.
    @Test("a block that did not change keeps its piece, and the block after it is set again")
    func keptPieces() {
        let composer = ChatReplyComposer()
        let first = composer.document(ReplyText(markdown: "One.\n\nTwo", home: "/Users/me").blocks, marked: [], titles: .none, style: Self.style)
        let second = composer.document(ReplyText(markdown: "One.\n\nTwo and three", home: "/Users/me").blocks, marked: [], titles: .none, style: Self.style)

        #expect(first.pieces[0] === second.pieces[0])
        #expect(first.pieces[1] !== second.pieces[1])
    }

    @Test("each code block is named with what its Copy writes")
    func codes() {
        let blocks = ReplyText(markdown: "```sh\nls -la\n```\n\nThen:\n\n```\npwd\n```", home: "/Users/me").blocks
        let document = ChatReplyComposer().document(blocks, marked: [], titles: .none, style: Self.style)

        #expect(document.codes.map(\.text) == ["ls -la", "pwd"])
    }
}

/// The text view a reply is drawn in: a selection is copied as a person
/// would paste it, and each code block's Copy sits over its block's corner.
@MainActor
@Suite("Reply text view")
struct ChatReplyTextViewTests {
    private static func view(_ markdown: String, width: CGFloat = 600) -> ChatReplyTextView {
        let style = ChatProseStyle(size: ChatMetrics.readingType.size)
        let view = ChatReplyTextView()
        view.show(ChatReplyComposer().document(ReplyText(markdown: markdown, home: "/Users/me").blocks, marked: [], titles: .none, style: style))
        let size = view.size(fitting: width)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("a selection across a reply is copied with a table's cells a tab apart")
    func copiesSelection() throws {
        let view = Self.view("Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        view.selectAll(nil)

        // As Copy writes it: every type the text view can write.
        #expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        #expect(board.string(forType: .string) == "Intro.\na\tb\n1\t2\nAfter.")
    }

    @Test("a reply changed only in its last block keeps the words before it")
    func showsOnlyWhatChanged() throws {
        let style = ChatProseStyle(size: ChatMetrics.readingType.size)
        let composer = ChatReplyComposer()
        let view = ChatReplyTextView()
        view.show(composer.document(ReplyText(markdown: "One.\n\nTwo", home: "/").blocks, marked: [], titles: .none, style: style))
        view.show(composer.document(ReplyText(markdown: "One.\n\nTwo and three.\n\nFour.", home: "/").blocks, marked: [], titles: .none, style: style))

        #expect(view.textStorage?.string == "One.\nTwo and three.\nFour.")
        view.show(composer.document(ReplyText(markdown: "One.", home: "/").blocks, marked: [], titles: .none, style: style))
        #expect(view.textStorage?.string == "One.")
    }

    @Test("each code block's Copy sits on its header's line at its trailing corner")
    func copyOverCorner() throws {
        let view = Self.view("Run this:\n\n```sh\nls -la\n```\n\nThen this:\n\n```\npwd\n```")
        let copies = view.subviews.filter { $0 is NSHostingView<ChatCodeCopyButton> }

        #expect(copies.count == 2)
        for copy in copies {
            #expect(!copy.isHidden)
            #expect(abs(copy.frame.maxX - (view.bounds.width - ChatMetrics.codeCopyInset)) < 0.5)
            #expect(abs(Double(copy.frame.width) - ChatMetrics.actionSize) < 0.5, "\(copy.frame)")
        }
        #expect(copies[0].frame.minY < copies[1].frame.minY)
    }
}
