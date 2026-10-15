import Foundation
import SwiftUI
import Testing

@testable import FermixAppCore

/// A reply is blocks in reading order: words, read as inline markdown with
/// their links, and fenced code blocks, kept exactly as written with the
/// language their fence names. Copy takes a block's exact text through the
/// one pasteboard writer, which a test replaces.
@Suite("Reply blocks")
struct ReplyBlocksTests {
    private static let home = "/Users/me"

    /// Each block as one short line: its words, or its language and code.
    private static func described(_ text: String) -> [String] {
        ReplyText(markdown: text, home: home).blocks.map { block in
            switch block {
            case .prose(let words): return "prose " + String(words.characters)
            case .code(let code): return "code \(code.language ?? "-") " + code.text
            }
        }
    }

    @Test("words, a code block with its language, and words again, the blank lines between set aside")
    func proseCodeProse() {
        let text = "Run it:\n\n```python\nprint(\"hi\")\n\nx = 1\n```\n\nThen check."

        #expect(Self.described(text) == ["prose Run it:", "code python print(\"hi\")\n\nx = 1", "prose Then check."])
    }

    /// A reply still being written draws its open block as a block, which
    /// then only grows as its lines arrive.
    @Test("a fence never closed runs to the end, as in a reply still being written")
    func unclosedFence() {
        #expect(Self.described("Here:\n```swift\nlet a = 1\nlet b") == ["prose Here:", "code swift let a = 1\nlet b"])
        #expect(Self.described("Here:\n```") == ["prose Here:", "code - "])
        #expect(Self.described("Here:\n``") == ["prose Here:\n``"])
    }

    @Test("a tilde fence is a fence, and a fence closes only on as many of its own mark")
    func tildesAndLengths() {
        #expect(Self.described("~~~\n```\nx\n```\n~~~") == ["code - ```\nx\n```"])
        #expect(Self.described("````md\n```\ninner\n```\n````\nafter") == ["code md ```\ninner\n```", "prose after"])
        #expect(Self.described("```\na\n~~~\nb\n``` \nc") == ["code - a\n~~~\nb", "prose c"])
    }

    /// Only a line that starts with a fence opens one; a backtick fence's
    /// info string has no backtick in it, so inline code stays words.
    @Test("a fence inside a sentence, or with a backtick after it, is words")
    func fenceInsideText() {
        let text = "Use ``` to open a block.\n```a``` is inline.\nThe end ```"

        #expect(ReplyFences.runs(text) == [.prose(text.split(separator: "\n", omittingEmptySubsequences: false))])
    }

    @Test("an empty block is a block with no lines, and words that are only blank lines are no block")
    func emptyBlock() {
        #expect(Self.described("```\n```") == ["code - "])
        #expect(Self.described("```\n```\n\n\n```sh\nls\n```") == ["code - ", "code sh ls"])
    }

    @Test("lines that end with a carriage return and a line feed read as lines")
    func crlf() {
        #expect(Self.described("Here:\r\n```py\r\nx = 1\r\ny = 2\r\n```\r\nDone") == ["prose Here:", "code py x = 1\ny = 2", "prose Done"])
    }

    /// A fence inside a list item is indented, and its lines lose as much.
    @Test("an indented fence opens a block whose lines lose its indent")
    func indentedFence() {
        let text = "1. Run:\n   ```sh\n   ls -la\n     two in\n  short\n   ```\n2. Done"

        #expect(Self.described(text) == ["prose 1. Run:", "code sh ls -la\n  two in\nshort", "prose 2. Done"])
    }

    @Test("code is kept as written: no markdown read, no links, its spaces and tabs as they are")
    func verbatim() {
        let code = "**not bold** [x](https://a.com/x) `y` ~/notes.md  \n\tindented\t"
        let reply = ReplyText(markdown: "```js title=a\n\(code)\n```", home: Self.home)

        #expect(reply.blocks == [.code(ReplyCode(language: "js", text: code))])
        #expect(reply.links.isEmpty)
    }

    @Test("a heading is still drawn as its text in bold, beside a code block")
    func headingsUnchanged() throws {
        let blocks = ChatText.reply("## Steps\n```\nls\n```", home: Self.home)
        let heading = try #require(blocks.first?.prose)

        #expect(String(heading.characters) == "Steps")
        #expect(heading.runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(blocks.last?.code == ReplyCode(language: nil, text: "ls"))
    }

    @Test("a person's words are one block as typed, fences and all")
    func plainIsOneBlock() {
        let text = "```\nls\n```"

        #expect(ReplyText(plain: text, home: Self.home).blocks.map { $0.prose.map { String($0.characters) } } == [text])
    }

    /// A code span sits on a faint fill, which marks it without making
    /// its line taller than the words round it.
    @Test("an inline code span is drawn on a faint fill, and the words round it on none")
    func inlineCodeChip() throws {
        let words = try #require(ChatText.reply("Run `ls -la` now.", home: Self.home).first?.prose)
        let code = try #require(words.runs.first { $0.inlinePresentationIntent == .code })

        #expect(String(words[code.range].characters) == "ls -la")
        #expect(code.backgroundColor == Palette.codeSpanFill.color)
        #expect(words.runs.filter { $0.backgroundColor != nil }.count == 1)
    }

    @Test("a code block is drawn in ink, its comments faint and its keywords, strings and numbers in their tones")
    func codeColours() {
        let drawn = ChatText.code(ReplyCode(language: "python", text: "def f():  # note\n    return \"a\", 42"), marking: [])
        func colour(of word: String) -> Color? {
            drawn.runs.first { String(drawn[$0.range].characters) == word }?.foregroundColor
        }

        #expect(String(drawn.characters) == "def f():  # note\n    return \"a\", 42")
        #expect(colour(of: "def") == Palette.codeKeyword.color)
        #expect(colour(of: "# note") == Palette.faint.color)
        #expect(colour(of: "\"a\"") == Palette.codeString.color)
        #expect(colour(of: "42") == Palette.codeNumber.color)
        #expect(drawn.runs.contains { String(drawn[$0.range].characters) == " f():  " && $0.foregroundColor == nil })
    }

    @Test("a search's matches are marked inside a code block too")
    func codeMarking() {
        let drawn = ChatText.code(ReplyCode(language: nil, text: "echo Report\nreport"), marking: ["report"])
        let marked = drawn.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }

        #expect(marked.map { String(drawn[$0.range].characters) } == ["Report", "report"])
    }

    /// A voice note's transcript is one text: a code block in it reads as
    /// code on lines of its own.
    @Test("the blocks as one text keep their order, code as code")
    func oneText() {
        let text = ChatText.oneText(ChatText.reply("See:\n```\nls\n```\nDone", home: Self.home))
        let code = text.runs.filter { $0.inlinePresentationIntent == .code }

        #expect(String(text.characters) == "See:\nls\nDone")
        #expect(code.map { String(text[$0.range].characters) } == ["ls"])
    }

    @Test("Copy writes the block's exact text through the seam, and says so to VoiceOver")
    func copy() {
        let written = ValueBox<[String]>()
        written.set([])
        let announcer = RecordingAnnouncer()
        let code = ReplyCode(language: "sh", text: "ls -la  \n\techo \"done\"\n")

        ChatCodeCopy(write: { written.set((written.value ?? []) + [$0]) }, announcer: announcer)(code)

        #expect(written.value == ["ls -la  \n\techo \"done\"\n"])
        #expect(announcer.sentences == [ProductStrings[.chatCodeCopied]])
    }
}
