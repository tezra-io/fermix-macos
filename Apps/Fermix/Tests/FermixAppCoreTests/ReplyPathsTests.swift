import Foundation
import SwiftUI
import Testing

@testable import FermixAppCore

/// A local path a reply names is a link to its file, read off the text alone:
/// a markdown link to a path, a code span that is one, and a bare path in
/// plain text. The home is passed in, so `~` never reads this Mac's own, and
/// nothing asks the disk whether a file is there.
@Suite("Reply paths")
struct ReplyPathsTests {
    private static let home = "/Users/me"

    private static func reply(_ text: String) -> AttributedString {
        ChatText.reply(text, home: home)
    }

    /// Each linked stretch of a reply, by its text, as the address it opens.
    private static func links(_ reply: AttributedString) -> [String: String] {
        var links: [String: String] = [:]
        for (link, range) in reply.runs[\.link] {
            guard let link else { continue }
            links[String(reply[range].characters)] = link.absoluteString
        }
        return links
    }

    private static func barePaths(_ text: String) -> [String] {
        ReplyPaths.barePaths(in: text).map { String(text[$0]) }
    }

    private static func linksAreTextBlue(_ reply: AttributedString) -> Bool {
        reply.runs.filter { $0.link != nil }.allSatisfy { $0.foregroundColor == Palette.accentText.color }
    }

    /// The colour the linked stretch with this text is drawn in.
    private static func colour(of text: String, in reply: AttributedString) -> Color? {
        reply.runs.first { $0.link != nil && String(reply[$0.range].characters) == text }?.foregroundColor
    }

    /// The underline of the linked stretch with this text, nil for none.
    private static func underline(of text: String, in reply: AttributedString) -> Text.LineStyle? {
        reply.runs.first { $0.link != nil && String(reply[$0.range].characters) == text }?.underlineStyle
    }

    /// A path's underline: thin, solid, in the fainter grey under its ink.
    private static let pathUnderline = Text.LineStyle(pattern: .solid, color: Palette.faint.color)

    // MARK: - Markdown links

    /// SwiftUI's parser keeps a path destination as a URL with no scheme,
    /// which nothing can open; it becomes the file's own address, decoded
    /// once so a space the parser encoded is not encoded twice.
    @Test("a markdown link to a local path opens its file, and one to an address stays as it is")
    func markdownLinks() {
        let reply = Self.reply(
            "[the report](~/.fermix/workspace/report.md), [the deck](/Users/me/deck.pdf), "
                + "[the summary](</Users/me/My Reports/q3.pdf>), [the site](https://example.com/a/b), "
                + "[mail](mailto:me@example.com), [notes](notes/a.md) and [the copy](//example.com/a/b)"
        )

        #expect(Self.links(reply) == [
            "the report": "file:///Users/me/.fermix/workspace/report.md",
            "the deck": "file:///Users/me/deck.pdf",
            "the summary": "file:///Users/me/My%20Reports/q3.pdf",
            "the site": "https://example.com/a/b",
            "mail": "mailto:me@example.com",
            "notes": "notes/a.md",
            "the copy": "//example.com/a/b",
        ])
        #expect(Self.linksAreTextBlue(reply))
    }

    // MARK: - Code spans

    @Test("a code span that is a path from end to end is a link and stays code")
    func codeSpans() throws {
        let reply = Self.reply("Saved the screenshot to `~/.fermix/browser/artifacts/shot.png`.")

        #expect(Self.links(reply) == ["~/.fermix/browser/artifacts/shot.png": "file:///Users/me/.fermix/browser/artifacts/shot.png"])
        let linked = try #require(reply.runs.first { $0.link != nil })
        #expect(linked.inlinePresentationIntent == .code)
        #expect(Self.colour(of: "~/.fermix/browser/artifacts/shot.png", in: reply) == Palette.ink.color)
        #expect(Self.underline(of: "~/.fermix/browser/artifacts/shot.png", in: reply) == Self.pathUnderline)
    }

    /// Spaces are allowed inside a code span, which marks where the path
    /// ends, and are percent-encoded in the address.
    @Test("a code span path keeps its spaces, encoded in the address")
    func codeSpanWithSpaces() {
        let reply = Self.reply("It is in `~/My Reports/q3 summary.pdf` now.")

        #expect(Self.links(reply) == ["~/My Reports/q3 summary.pdf": "file:///Users/me/My%20Reports/q3%20summary.pdf"])
    }

    @Test("a code span that only holds a path, or names one component under the root, is no link")
    func codeSpansThatAreNotPaths() {
        let reply = Self.reply("Run `cp /Users/me/a.png /tmp/b.png`, then `/status`, `/model gpt` and `~/`.")

        #expect(Self.links(reply).isEmpty)
    }

    // MARK: - Bare paths

    @Test("a bare path starts a word or follows an opening mark, and leaves the punctuation around it")
    func barePaths() {
        #expect(Self.barePaths("I wrote the report to /Users/me/.fermix/workspace/report.pdf.") == ["/Users/me/.fermix/workspace/report.pdf"])
        #expect(Self.barePaths("/tmp/shots/a.png is ready") == ["/tmp/shots/a.png"])
        #expect(Self.barePaths("(see ~/Desktop/shot.png), \"/var/log/x.log\" or '/a/b'") == ["~/Desktop/shot.png", "/var/log/x.log", "/a/b"])
        #expect(Self.barePaths("Done: /a/b/c? Also /a/b/d!") == ["/a/b/c", "/a/b/d"])
        #expect(Self.barePaths("Stray /a/b/c` and nested /a/b/e)].") == ["/a/b/c", "/a/b/e"])
        #expect(Self.barePaths("A folder: /Users/me/") == ["/Users/me/"])
        #expect(Self.barePaths("Saved to ~/notes.md.") == ["~/notes.md"])
    }

    /// A reference to a line says where to look in the file, not which file:
    /// the text stays as written and the address is the file's alone.
    @Test("a line reference after a bare path or a code span path is left out of the address")
    func lineReferences() {
        let reply = Self.reply("See /Users/me/app.swift:42 and /Users/me/b.swift:42:7, then `~/work/c.ex:12`.")

        #expect(Self.links(reply) == [
            "/Users/me/app.swift:42": "file:///Users/me/app.swift",
            "/Users/me/b.swift:42:7": "file:///Users/me/b.swift",
            "~/work/c.ex:12": "file:///Users/me/work/c.ex",
        ])
        #expect(ReplyPaths.withoutLineReference("/a/b.txt:12:3:4") == "/a/b.txt:12")
        #expect(ReplyPaths.withoutLineReference("/a/b.txt:x") == "/a/b.txt:x")
        #expect(ReplyPaths.withoutLineReference("/a/b.txt:") == "/a/b.txt:")
        #expect(Self.barePaths("/approve:42 and /a:7").isEmpty, "a root and one name is a command, a line after it or not")
    }

    @Test("curly quotes and angle brackets stand around a bare path as straight quotes and parentheses do")
    func curlyQuotesAndAngleBrackets() {
        #expect(Self.barePaths("\u{201C}/Users/me/a.png\u{201D}, \u{2018}~/b/c.md\u{2019} and </a/b/c>.") == ["/Users/me/a.png", "~/b/c.md", "/a/b/c"])
    }

    /// An agent writes a path with a space in it in code, which marks where
    /// it ends; unquoted, the path links only up to the space.
    @Test("an unquoted bare path with a space in it links up to the space")
    func barePathWithASpace() {
        #expect(Self.barePaths("Saved to /Users/me/My Reports/q3.pdf") == ["/Users/me/My"])
    }

    @Test("an address, a slash command, a fraction and the bare roots are no bare path")
    func notBarePaths() {
        #expect(Self.barePaths("https://example.com/a/b and file:///a/b/c").isEmpty)
        #expect(Self.barePaths("//example.com/a/b").isEmpty)
        #expect(Self.barePaths("/approve, or /model gpt").isEmpty)
        #expect(Self.barePaths("and/or 1/2 x/a/b").isEmpty)
        #expect(Self.barePaths("~/ and / and ~notes.md").isEmpty)
    }

    /// The address SwiftUI already made a link keeps it, a path inside a link
    /// is part of that link, and a bare path beside them is a link of its own.
    @Test("a bare path in a reply is a link, never inside an address or another link")
    func barePathsInAReply() {
        let reply = Self.reply("Open https://example.com/a/b or [see /a/b/c here](https://example.com), then /Users/me/a.png.")

        #expect(Self.links(reply) == [
            "https://example.com/a/b": "https://example.com/a/b",
            "see /a/b/c here": "https://example.com",
            "/Users/me/a.png": "file:///Users/me/a.png",
        ])
        #expect(Self.colour(of: "https://example.com/a/b", in: reply) == Palette.accentText.color)
        #expect(Self.colour(of: "see /a/b/c here", in: reply) == Palette.accentText.color)
        #expect(Self.colour(of: "/Users/me/a.png", in: reply) == Palette.ink.color)
        #expect(Self.underline(of: "/Users/me/a.png", in: reply) == Self.pathUnderline)
        #expect(Self.underline(of: "https://example.com/a/b", in: reply) == nil)
        #expect(Self.underline(of: "see /a/b/c here", in: reply) == nil)
    }

    /// The text before the path is not all ASCII either, so the path's place
    /// in the drawn text is found by character, not by byte.
    @Test("a path with a name in another script is percent-encoded and reads back as written")
    func nonASCIIName() throws {
        let reply = Self.reply("Café menu saved to /Users/me/Документы/café.pdf")
        let url = try #require(reply.runs.compactMap(\.link).first)
        let encoded = url.absoluteString.unicodeScalars.allSatisfy { $0.isASCII }

        #expect(Array(Self.links(reply).keys) == ["/Users/me/Документы/café.pdf"])
        #expect(url.isFileURL)
        #expect(encoded)
        #expect(url.path(percentEncoded: false) == "/Users/me/Документы/café.pdf")
    }

    // MARK: - Drawing

    /// A folder every Mac has, named without its trailing slash: asked, the
    /// disk would add one. The address comes from the text alone.
    @Test("the address is built from the path alone, its own trailing slash saying folder")
    func addressFromTheTextAlone() {
        #expect(ReplyPaths.fileURL("/System/Library", home: Self.home).absoluteString == "file:///System/Library")
        #expect(ReplyPaths.fileURL("/System/Library/", home: Self.home).absoluteString == "file:///System/Library/")
        #expect(ReplyPaths.fileURL("~/a/b", home: Self.home).absoluteString == "file:///Users/me/a/b")
    }

    @Test("a search still marks its matches in a reply with a path, and the path stays a link")
    func searchMarksAReplyWithAPath() {
        let marked = ChatText.marking(["report"], in: Self.reply("Saved to `~/work/report.pdf`, and the report is ready."))
        let emphasised = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }

        #expect(emphasised.map { String(marked[$0.range].characters) } == ["report", "report"])
        #expect(Self.links(marked) == ["~/work/report.pdf": "file:///Users/me/work/report.pdf"])
    }

    /// A fenced block's lines become code spans, so a line is a link only
    /// when the whole of it is a path.
    @Test("in a fenced block, a line is a link only when its whole text is a path")
    func fencedBlock() {
        let reply = Self.reply("Here:\n```\n/Users/me/shots/a.png\ncp /Users/me/a.png /tmp/b.png\n~/notes\n```\nDone")
        let code = reply.runs.filter { $0.inlinePresentationIntent == .code }

        #expect(code.map { String(reply[$0.range].characters) } == ["/Users/me/shots/a.png", "cp /Users/me/a.png /tmp/b.png", "~/notes"])
        #expect(Self.links(reply) == [
            "/Users/me/shots/a.png": "file:///Users/me/shots/a.png",
            "~/notes": "file:///Users/me/notes",
        ])
    }

    @Test("a heading's path is a link, drawn in bold")
    func headingPath() throws {
        let reply = Self.reply("## Saved /Users/me/out/report.pdf")
        let linked = try #require(reply.runs.first { $0.link != nil })

        #expect(Self.links(reply) == ["/Users/me/out/report.pdf": "file:///Users/me/out/report.pdf"])
        #expect(linked.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test("the person's own message stays as they typed it, with no links")
    func ownMessageStaysPlain() {
        let own = ChatText.plain("Look in /Users/me/shots/a.png and `~/work/report.pdf`")

        #expect(own.runs.allSatisfy { $0.link == nil })
    }
}
