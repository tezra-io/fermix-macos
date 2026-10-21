import Foundation
import SwiftUI
import Testing

@testable import FermixAppCore

/// A web address a reply writes out is a link drawn as a path is, and the
/// strip lists every address the reply links to, in reading order. Only an
/// address written with its scheme counts, never one in code, and the marks
/// that close a sentence are not part of it.
@Suite("Reply links")
struct ReplyLinksTests {
    /// A reply as drawn, its blocks as one text.
    private static func reply(_ text: String) -> AttributedString {
        ChatText.oneText(ChatText.drawn(ReplyText(markdown: text, home: "/Users/me")))
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

    private static func addresses(_ text: String) -> [String] {
        ReplyText(markdown: text, home: "/Users/me").addresses.map(\.absoluteString)
    }

    private static func run(of text: String, in reply: AttributedString) -> AttributedString.Runs.Run? {
        reply.runs.first { $0.link != nil && String(reply[$0.range].characters) == text }
    }

    @Test("a bare address is a link in ink with the path's underline, listed in reading order")
    func bareAddresses() throws {
        let reply = Self.reply("Read https://example.com/a/b, then HTTP://Example.org/x.")

        #expect(Self.links(reply) == [
            "https://example.com/a/b": "https://example.com/a/b",
            "HTTP://Example.org/x": "HTTP://Example.org/x",
        ])
        let run = try #require(Self.run(of: "https://example.com/a/b", in: reply))
        #expect(run.foregroundColor == Palette.ink.color)
        #expect(run.underlineStyle == Text.LineStyle(pattern: .solid, color: Palette.faint.color))
        #expect(Self.addresses("Read https://example.com/a/b, then HTTP://Example.org/x.") == [
            "https://example.com/a/b", "HTTP://Example.org/x",
        ])
    }

    /// A markdown link with words of its own is the reply's: it keeps its
    /// blue, and the address inside its words is part of it, not a second
    /// link. Its destination is an address the reply links to all the same.
    @Test("a markdown link keeps its words and its blue, and its destination is listed")
    func markdownLinks() throws {
        let text = "See [the report](https://example.com/r) and [see https://a.com/x here](https://b.com/y)."
        let reply = Self.reply(text)

        #expect(Self.links(reply) == [
            "the report": "https://example.com/r",
            "see https://a.com/x here": "https://b.com/y",
        ])
        #expect(Self.run(of: "the report", in: reply)?.foregroundColor == Palette.accentText.color)
        #expect(Self.addresses(text) == ["https://example.com/r", "https://b.com/y"])
    }

    @Test("an address in code is left as the code it is")
    func addressesInCode() {
        let text = "Run `curl https://example.com/api` or `https://example.com/whole`, then\n```\nhttps://example.com/fenced\n```"
        let reply = Self.reply(text)

        #expect(Self.links(reply).isEmpty)
        #expect(Self.addresses(text).isEmpty)
    }

    /// The parser's own links end differently from one macOS to the next; the
    /// detector's end where the address does, whatever closes the sentence.
    @Test("the punctuation, quotes and brackets after an address are not part of it")
    func trailingPunctuation() {
        let text = "(https://example.com/a?q=1#frag), https://example.com/x? and https://example.com/y! "
            + "{https://example.com/r} \u{201C}https://example.com/t\u{201D} <https://example.com/u> "
            + "https://en.wikipedia.org/wiki/Foo_(bar). https://example.com/z;"

        #expect(Self.addresses(text) == [
            "https://example.com/a?q=1#frag", "https://example.com/x", "https://example.com/y",
            "https://example.com/r", "https://example.com/t", "https://example.com/u",
            "https://en.wikipedia.org/wiki/Foo_(bar)", "https://example.com/z",
        ])
        #expect(ReplyLinks.trimmed("https://a.com/b).") == "https://a.com/b")
        #expect(ReplyLinks.trimmed("https://a.com/(b)") == "https://a.com/(b)")
    }

    /// A host or a file's name with no scheme is a word: `notes.md` is a file
    /// that happens to read like an address in Moldova.
    @Test("only an address written with its scheme is one")
    func schemeWritten() {
        let text = "Try www.example.com, example.com/path, notes.md, me@example.com or ftp://example.com/a."
        let reply = Self.reply(text)

        #expect(Self.addresses(text).isEmpty)
        #expect(!Self.links(reply).keys.contains("www.example.com"))
        #expect(!Self.links(reply).keys.contains("notes.md"))
    }

    @Test("paths and addresses in one reply are each their own link")
    func pathsBesideAddresses() {
        let reply = Self.reply("Saved ~/shots/a.png from https://example.com/a.png")

        #expect(Self.links(reply) == [
            "~/shots/a.png": "file:///Users/me/shots/a.png",
            "https://example.com/a.png": "https://example.com/a.png",
        ])
        #expect(ReplyText(markdown: "Saved ~/shots/a.png from https://example.com/a.png", home: "/Users/me").files.map(\.absoluteString) == ["file:///Users/me/shots/a.png"])
    }
}
