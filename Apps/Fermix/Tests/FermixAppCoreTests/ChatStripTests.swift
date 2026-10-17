import Foundation
import Testing

@testable import FermixAppCore

/// A row's strip, worked out from its content alone: which items, in which
/// order, each destination once, a stored preview paired with the address it
/// was made from by the engine's own rule, how wide its tiles are, and how a
/// sideways row moves. No disk: the home is text, as the paths are.
@Suite("Chat strip")
struct ChatStripTests {
    private static let home = ChatHome(roots: ["/Users/me/.fermix"])

    private static func strip(
        _ text: String,
        plain: Bool = false,
        refs: [CompanionMediaRef] = [],
        previews: [CompanionLinkPreview] = [],
        blocks: [CompanionBlock] = [],
        home: ChatHome? = home
    ) -> ChatStrip {
        ChatStrip(text: text, plain: plain, mediaRefs: refs, linkPreviews: previews, blocks: blocks, userHome: "/Users/me", home: home)
    }

    private static func ref(_ name: String, kind: String = "image", mime: String = "image/png") -> CompanionMediaRef {
        CompanionMediaRef(ref: String(repeating: String(name.prefix(1)), count: 64), kind: kind, mime: mime, sizeBytes: 10, sha256: nil, filename: name, caption: nil)
    }

    /// A stored preview of `url`, read for `link`, or stored before links were
    /// kept where it has none.
    private static func preview(_ url: String, link: String? = nil, title: String = "Title") -> CompanionLinkPreview {
        CompanionLinkPreview(link: link, url: url, site: "Site", title: title, description: nil, imageRef: nil)
    }

    /// Each item as one short line, so a whole strip reads as a list.
    private static func described(_ strip: ChatStrip) -> [String] {
        described(strip.items)
    }

    private static func described(_ items: [ChatStripItem]) -> [String] {
        items.map { item in
            switch item {
            case .media(let ref): return "ref \(ref.filename ?? "")"
            case .file(let file): return "file \(file.path)"
            case .link(let link): return "link \(link.address.absoluteString)" + (link.preview.map { " = \($0.url)" } ?? "")
            }
        }
    }

    // MARK: - Order and membership

    /// A phone-side picture and a page Fermix made draw their content, so
    /// they lead, refs first; then the other files' cards; then the links,
    /// where a preview that is no address's stands on its own before the
    /// addresses, and an address's own preview is drawn at the address's
    /// place.
    @Test("previews lead; then the files' cards; then loose previews and addresses, each once")
    func order() {
        let strip = Self.strip(
            "See https://b.com/x and /Users/me/.fermix/workspace/report.pdf, then https://b.com/x and ~/notes.pdf again.",
            refs: [Self.ref("photo.png"), Self.ref("log.txt", kind: "document", mime: "text/plain")],
            previews: [Self.preview("https://b.com/x"), Self.preview("https://c.com/z")]
        )

        #expect(Self.described(strip) == [
            "ref photo.png",
            "file /Users/me/.fermix/workspace/report.pdf",
            "ref log.txt",
            "file /Users/me/notes.pdf",
            "link https://c.com/z = https://c.com/z",
            "link https://b.com/x = https://b.com/x",
        ])
    }

    /// A tile's kind is read from its path, before the disk is asked, so it
    /// keeps its shape whatever the file turns out to be: a preview only for
    /// what is drawn by its content, and only inside the home.
    @Test("a preview is a path inside the home to a picture, a video, a PDF or a document; other files are cards, addresses links")
    func previewsAndCards() {
        let strip = Self.strip(
            "Made /Users/me/.fermix/w/shot.png, /Users/me/.fermix/w/clip.mov, /Users/me/.fermix/w/q3.docx and "
                + "/Users/me/.fermix/w/Notes.pages, besides /Users/me/.fermix/w/logo.svg, /Users/me/.fermix/w/page.html, "
                + "/Users/me/.fermix/w/table.csv, ~/Desktop/far.png and https://a.com/x",
            refs: [Self.ref("phone.png")]
        )

        #expect(Self.described(strip.previews) == [
            "ref phone.png",
            "file /Users/me/.fermix/w/shot.png",
            "file /Users/me/.fermix/w/clip.mov",
            "file /Users/me/.fermix/w/q3.docx",
            "file /Users/me/.fermix/w/Notes.pages",
        ])
        #expect(Self.described(strip.cards) == [
            "file /Users/me/.fermix/w/logo.svg",
            "file /Users/me/.fermix/w/page.html",
            "file /Users/me/.fermix/w/table.csv",
            "file /Users/me/Desktop/far.png",
        ])
        #expect(strip.links.map(\.address.absoluteString) == ["https://a.com/x"])
    }

    /// The engine reads code too: a preview of an address the text has in
    /// code stands as its own item, the text's address being no link, and
    /// opens the address it was read for, less the code's closing mark.
    @Test("a preview of an address in code stands on its own and opens that address")
    func previewOfCode() {
        let strip = Self.strip(
            "Fetched `https://c.com/y` for you",
            previews: [Self.preview("https://www.c.com/y", link: "https://c.com/y`")]
        )

        #expect(Self.described(strip) == ["link https://c.com/y = https://www.c.com/y"])
    }

    /// A phone-side file is drawn by the type its row names, through the same
    /// rule as a path: what draws its content is a preview tile, anywhere,
    /// since the engine grants its file inside the home, and the rest are
    /// cards. A picture Fermix sent the phone, a row with no words, is a tile
    /// like any other.
    @Test("a phone-side file is a preview or a card by the type its row names")
    func refsByType() {
        let strip = Self.strip(
            "",
            refs: [
                Self.ref("sent.png"),
                Self.ref("clip.mp4", kind: "video", mime: "video/mp4"),
                Self.ref("report.pdf", kind: "document", mime: "application/pdf"),
                Self.ref("q3.docx", kind: "document", mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
                Self.ref("logo.svg", kind: "image", mime: "image/svg+xml"),
                Self.ref("notes.txt", kind: "document", mime: "text/plain"),
                Self.ref("archive.zip", kind: "document", mime: "application/zip"),
            ],
            home: nil
        )

        #expect(Self.described(strip.previews) == ["ref sent.png", "ref clip.mp4", "ref report.pdf", "ref q3.docx"])
        #expect(Self.described(strip.cards) == ["ref logo.svg", "ref notes.txt", "ref archive.zip"])
        #expect(strip.text.isEmpty)
    }

    @Test("the voice note and a sound Fermix made are not tiles, and a sound elsewhere is")
    func voiceNoteAndSounds() {
        let note = Self.ref("voice-note.ogg", kind: "audio", mime: "audio/ogg")
        let strip = Self.strip(
            "Recorded /Users/me/.fermix/workspace/take.m4a and found /Users/me/Music/song.mp3",
            refs: [note, Self.ref("shot.png")]
        )

        #expect(strip.voiceNote == note)
        #expect(strip.sounds.map(\.path) == ["/Users/me/.fermix/workspace/take.m4a"])
        #expect(Self.described(strip) == ["ref shot.png", "file /Users/me/Music/song.mp3"])
    }

    /// A path only being talked about stays a link in the text: a command's
    /// binary, a system file, and text outside the home. Inside the home every
    /// path is something Fermix made.
    @Test("a path is a tile inside the home or when it names something worth seeing")
    func pathsWorthSeeing() {
        let strip = Self.strip(
            "Edited /etc/hosts with /usr/bin/python3, read ~/notes.txt and ~/.ssh/config, "
                + "wrote /Users/me/.fermix/workspace/notes.txt and ~/.fermix/out/, saved ~/Desktop/shot.png, "
                + "~/Movies/clip.mov, /tmp/deck.key and ~/Docs/q3.docx"
        )

        #expect(Self.described(strip) == [
            "file /Users/me/.fermix/workspace/notes.txt",
            "file /Users/me/.fermix/out",
            "file /Users/me/Desktop/shot.png",
            "file /Users/me/Movies/clip.mov",
            "file /tmp/deck.key",
            "file /Users/me/Docs/q3.docx",
        ])
    }

    @Test("with no home read, only what is worth seeing anywhere is a tile")
    func noHome() {
        let strip = Self.strip("Wrote /Users/me/.fermix/workspace/notes.txt and /Users/me/.fermix/a.png", home: nil)

        #expect(Self.described(strip) == ["file /Users/me/.fermix/a.png"])
        #expect(strip.sounds.isEmpty)
    }

    @Test("a row with nothing to show has an empty strip")
    func emptyStrip() {
        let strip = Self.strip("Done. The answer is 42.")

        #expect(strip.items.isEmpty)
        #expect(strip.voiceNote == nil)
        #expect(strip.sounds.isEmpty)
    }

    // MARK: - Destinations

    /// A site may serve each its own page: only the scheme and the host are
    /// read without regard to case.
    @Test("two fragments, a trailing slash and two queries stay distinct; case in the scheme and host does not")
    func destinations() {
        let strip = Self.strip(
            "https://a.com/doc#one https://a.com/doc#two https://a.com/report https://a.com/report/ "
                + "https://a.com/q?x=1 https://a.com/q?x=2 HTTPS://A.COM/report https://a.com/Report"
        )

        #expect(Self.described(strip) == [
            "link https://a.com/doc#one", "link https://a.com/doc#two",
            "link https://a.com/report", "link https://a.com/report/",
            "link https://a.com/q?x=1", "link https://a.com/q?x=2",
            "link https://a.com/Report",
        ])
        #expect(ChatDestination(URL(string: "HTTPS://A.COM/report")!) == ChatDestination(URL(string: "https://a.com/report")!))
    }

    // MARK: - Stored previews

    /// The engine stores a preview under the address it reached and keeps
    /// the link it read it for, so a preview pairs with that link whatever
    /// the redirect did, in the text's order, and a click opens the address
    /// the text wrote.
    @Test("a preview stored under a redirected address pairs with the link it was read for")
    func redirectedPreviews() {
        let strip = Self.strip(
            "Old http://a.com/x and short https://t.co/abc",
            previews: [
                Self.preview("https://www.example.com/article", link: "https://t.co/abc"),
                Self.preview("https://a.com/x", link: "http://a.com/x"),
            ]
        )

        #expect(Self.described(strip) == [
            "link http://a.com/x = https://a.com/x",
            "link https://t.co/abc = https://www.example.com/article",
        ])
    }

    @Test("a host gaining www pairs by its link too, and the click keeps the address as written")
    func hostGainingWWW() throws {
        let strip = Self.strip(
            "Read https://example.com/news.",
            previews: [Self.preview("https://www.example.com/news", link: "https://example.com/news")]
        )
        let item = try #require(strip.items.first)

        #expect(strip.items.count == 1)
        guard case .link(let link) = item else {
            Issue.record("the address is not a link")
            return
        }
        #expect(link.address.absoluteString == "https://example.com/news")
        #expect(link.preview?.url == "https://www.example.com/news")
    }

    /// The strip's own rule, each destination once (M66 §3.1), is an item's
    /// identity: one is equal to another, and hashes with it, when the two
    /// name one destination, whatever preview either carries.
    @Test("two items naming one destination are one item")
    func itemsByDestination() {
        let address = URL(string: "https://a.com/x")!
        let bare = ChatStripItem.link(ChatStripLink(address: address, preview: nil))
        let previewed = ChatStripItem.link(ChatStripLink(address: URL(string: "HTTPS://A.com/x")!, preview: Self.preview("https://a.com/x")))

        #expect(bare == previewed)
        #expect(Set([bare, previewed]).count == 1)
        #expect(bare != .link(ChatStripLink(address: URL(string: "https://a.com/x/")!, preview: nil)))
        #expect(ChatStripItem.file(URL(fileURLWithPath: "/a/../a/b.png")) == .file(URL(fileURLWithPath: "/a/b.png")))
    }

    /// A preview stored before links were kept carries only the address it
    /// was stored under: it belongs to a link only when the two are the
    /// same destination, and otherwise stands on its own.
    @Test("a preview with no link pairs only with an address of its own destination")
    func previewWithoutLink() {
        let equal = Self.strip("https://a.com/x and https://b.com/y", previews: [Self.preview("https://B.com/y")])
        #expect(Self.described(equal) == ["link https://a.com/x", "link https://b.com/y = https://B.com/y"])

        let unequal = Self.strip("https://a.com/x and https://b.com/y", previews: [Self.preview("https://www.b.com/y")])
        #expect(Self.described(unequal) == [
            "link https://www.b.com/y = https://www.b.com/y",
            "link https://a.com/x",
            "link https://b.com/y",
        ])
    }

    /// The engine reads a markdown link's target to its first closing
    /// bracket, a page's own among them; the text's link keeps it, and the
    /// two are still one address.
    @Test("a link the engine read short of its own bracket pairs with the text's link")
    func engineReadsShort() {
        let strip = Self.strip(
            "Read [Foo](https://w.org/Foo_(bar)).",
            previews: [Self.preview("https://w.org/Foo_(bar)", link: "https://w.org/Foo_(bar")]
        )

        #expect(Self.described(strip) == ["link https://w.org/Foo_(bar) = https://w.org/Foo_(bar)"])
    }

    /// Every reader of a reply's words composes its marks from one set.
    @Test("every closing mark comes from one set")
    func marks() {
        #expect(ReplyMarks.closing == ReplyMarks.punctuation.union(ReplyMarks.closingQuotes).union([")", "]", "}"]))
    }

    // MARK: - The fit

    /// As wide as lets up to three of a row show whole, between 120 and 200
    /// points; a row with more scrolls, so no room is held back for a control.
    @Test("720 points: tiles of 200 by 133, however many the row has")
    func fitWide() {
        #expect(ChatStripFit.itemWidth(count: 1, width: 720) == 200)
        #expect(ChatStripFit.itemWidth(count: 3, width: 720) == 200)
        #expect(ChatStripFit.itemWidth(count: 6, width: 720) == 200)
        #expect(ChatStripFit.tileSize(width: 200).height.rounded() == 133)
    }

    @Test("430 points: three whole tiles of 138, or two of 200 where the row has two")
    func fitMiddle() {
        #expect(ChatStripFit.itemWidth(count: 3, width: 430) == 138)
        #expect(ChatStripFit.itemWidth(count: 6, width: 430) == 138)
        #expect(ChatStripFit.itemWidth(count: 2, width: 430) == 200)
    }

    @Test("300 points: two whole tiles of 146, or one of 200")
    func fitNarrow() {
        #expect(ChatStripFit.itemWidth(count: 2, width: 300) == 146)
        #expect(ChatStripFit.itemWidth(count: 6, width: 300) == 146)
        #expect(ChatStripFit.itemWidth(count: 1, width: 300) == 200)
    }

    @Test("a column too narrow for one whole tile still shows one, at the narrowest width")
    func fitTooNarrow() {
        #expect(ChatStripFit.itemWidth(count: 4, width: 100) == 120)
    }

    /// A row that fits sits on its side; one wider than its room scrolls.
    @Test("a row's width is its items and the gaps between them")
    func rowWidth() {
        #expect(ChatStripFit.rowWidth(count: 3, itemWidth: 200) == 616)
        #expect(ChatStripFit.rowWidth(count: 1, itemWidth: 200) == 200)
        #expect(ChatStripFit.rowWidth(count: 0, itemWidth: 200) == 0)
    }

    @Test("the reading column is the column's width, or the body less its gutters")
    func column() {
        #expect(ChatMetrics.column(inBody: 1200) == 720)
        #expect(ChatMetrics.column(inBody: 478) == 430)
        #expect(ChatMetrics.column(inBody: 20) == 0)
    }

    // MARK: - Moving along a row

    @Test("the arrow keys move one item along, held at the first and the last")
    func navigation() {
        #expect(ChatStripNavigation.index(from: 2, by: 1, count: 6) == 3)
        #expect(ChatStripNavigation.index(from: 2, by: -1, count: 6) == 1)
        #expect(ChatStripNavigation.index(from: 5, by: 1, count: 6) == 5)
        #expect(ChatStripNavigation.index(from: 0, by: -1, count: 6) == 0)
        #expect(ChatStripNavigation.index(from: 0, by: 1, count: 1) == 0)
    }

    /// An end has more past it while the row is not resting there, a point of
    /// slack aside.
    @Test("an end fades and offers its arrow only while there is more past it")
    func edges() {
        let start = ChatStripEdges(ChatStripScroll(offset: 0, content: 1024, container: 430))
        #expect(start == ChatStripEdges(leading: false, trailing: true))

        let middle = ChatStripEdges(ChatStripScroll(offset: 300, content: 1024, container: 430))
        #expect(middle == ChatStripEdges(leading: true, trailing: true))

        let end = ChatStripEdges(ChatStripScroll(offset: 593.5, content: 1024, container: 430))
        #expect(end == ChatStripEdges(leading: true, trailing: false))
    }

    /// The left and right arrow keys, while the row itself has focus, move it
    /// by one item and the gap after it.
    @Test("an arrow key moves a focused row by one item, and never past either end")
    func stepping() {
        let scroll = ChatStripScroll(offset: 300, content: 1024, container: 430)

        #expect(ChatStripEdges.step(from: scroll, item: 138, forward: true) == 446)
        #expect(ChatStripEdges.step(from: scroll, item: 138, forward: false) == 154)
        #expect(ChatStripEdges.step(from: ChatStripScroll(offset: 100, content: 1024, container: 430), item: 138, forward: false) == 0)
        #expect(ChatStripEdges.step(from: ChatStripScroll(offset: 500, content: 1024, container: 430), item: 138, forward: true) == 594)
        #expect(ChatStripEdges.step(from: ChatStripScroll(offset: 0, content: 300, container: 430), item: 138, forward: true) == 0)
    }

    @Test("an arrow moves the row on by what it shows, and never past either end")
    func paging() {
        let scroll = ChatStripScroll(offset: 300, content: 1024, container: 430)

        #expect(ChatStripEdges.page(from: scroll, forward: true) == 594)
        #expect(ChatStripEdges.page(from: scroll, forward: false) == 0)
        #expect(ChatStripEdges.page(from: ChatStripScroll(offset: 0, content: 1024, container: 430), forward: true) == 430)
        #expect(ChatStripEdges.page(from: ChatStripScroll(offset: 0, content: 300, container: 430), forward: true) == 0)
    }

    // MARK: - The text

    /// A reply that only lists what it made says nothing the strip does not:
    /// its text goes, and the row draws its strip alone.
    @Test("a reply that is only a list of what it made draws no text")
    func onlyAList() {
        let strip = Self.strip(
            "- /Users/me/.fermix/w/shot.png\n* `~/.fermix/w/report.pdf`\n• [clip.mov](/Users/me/.fermix/w/clip.mov)\n"
                + "1. https://a.com/x\n2) <https://b.com/y>\n  [https://c.com/z](https://c.com/z)."
        )

        #expect(strip.items.count == 6)
        #expect(strip.text.isEmpty)
    }

    /// Only a line that names one thing the strip shows, and nothing more,
    /// goes. A link inside a sentence, a markdown link with words of its own
    /// and a path with no tile all stay, and the gap the list left closes.
    @Test("prose stays, and a line that only names a tile goes, its gap closing")
    func mixedProse() {
        let text = """
            I saved the screenshot to /Users/me/.fermix/w/shot.png as asked.

            Files:
            - /Users/me/.fermix/w/shot.png
            - /etc/hosts
            - [the report](/Users/me/.fermix/w/report.pdf)

            - https://a.com/x

            See [the docs](https://a.com/docs) too.
            """
        let strip = Self.strip(text)

        #expect(strip.text == """
            I saved the screenshot to /Users/me/.fermix/w/shot.png as asked.

            Files:
            - /etc/hosts
            - [the report](/Users/me/.fermix/w/report.pdf)

            See [the docs](https://a.com/docs) too.
            """)
    }

    @Test("a line in a fenced block is never touched")
    func fencedCode() {
        let text = "Run this:\n```\n/Users/me/.fermix/w/shot.png\nhttps://a.com/x\n```\n/Users/me/.fermix/w/shot.png"
        let strip = Self.strip(text)

        #expect(strip.text == "Run this:\n```\n/Users/me/.fermix/w/shot.png\nhttps://a.com/x\n```")
    }

    /// Code is kept as written and links nothing, so a path or an address
    /// only a code block names is no tile, and a line in any code block
    /// stays put even when the same path, named on its own line outside it,
    /// is a tile: a tilde fence, an indented one in a list item and one
    /// still open among them.
    @Test("a path or an address only a code block names is no tile, and a line in a code block always stays")
    func pathInCodeStays() {
        let path = "/Users/me/.fermix/w/shot.png"
        let onlyInCode = "Saved:\n```bash\nopen \(path)\n\(path)\nhttps://a.com/x\n```"
        #expect(Self.strip(onlyInCode).items.isEmpty)
        #expect(Self.strip(onlyInCode).text == onlyInCode)

        let blocks = [
            "~~~\n\(path)\n~~~",
            "1. Open it:\n   ```\n   \(path)\n   ```",
            "````\n```\n\(path)\n````",
            "```\r\n\(path)\r\n```",
        ]
        for block in blocks {
            let strip = Self.strip(block + "\n" + path)
            #expect(Self.described(strip) == ["file \(path)"], "\(block)")
            #expect(strip.text == block.replacingOccurrences(of: "\r\n", with: "\n"), "\(block)")
        }

        let open = Self.strip(path + "\n```\n" + path)
        #expect(open.text == "```\n" + path)
    }

    /// The person's own message follows the same rule: the picture they
    /// named is under it, so the line that only names it goes.
    @Test("a person's own message loses the line that only names its picture")
    func ownMessage() {
        let text = "Can you look at this?\n~/Desktop/shot.png"

        #expect(Self.strip(text, plain: true).text == "Can you look at this?")
        #expect(Self.strip("What is in ~/Desktop/shot.png?", plain: true).text == "What is in ~/Desktop/shot.png?")
    }

    /// A person's words are drawn as they typed them, so they are read so:
    /// no markdown, so a path in backticks or behind a link's words is the
    /// text it is, and only what is written out is a path or an address.
    @Test("a person's words are read as plain text, as they are drawn")
    func plainScan() {
        let text = "See [the shot](~/Desktop/a.png), `~/Desktop/b.png`, ~/Desktop/c.png and [x](https://a.com/y)"

        #expect(Self.described(Self.strip(text, plain: true)) == ["file /Users/me/Desktop/c.png", "link https://a.com/y"])
        #expect(Self.described(Self.strip(text)) == [
            "file /Users/me/Desktop/a.png", "file /Users/me/Desktop/b.png", "file /Users/me/Desktop/c.png", "link https://a.com/y",
        ])
        #expect(Self.strip(text, plain: true).reply == nil)
    }

    /// Fermix's words are read once: the row draws the same reading the
    /// strip took its links from, less the lines it dropped.
    @Test("Fermix's row draws the strip's own reading of its words")
    func oneReading() {
        let whole = Self.strip("Saved ~/Desktop/a.png for you.")
        #expect(whole.reply == ReplyText(markdown: "Saved ~/Desktop/a.png for you.", home: "/Users/me"))

        let listed = Self.strip("Done:\n- ~/Desktop/a.png")
        #expect(listed.text == "Done:")
        #expect(listed.reply == ReplyText(markdown: "Done:", home: "/Users/me"))
    }

    @Test("a text that loses no line is kept exactly, and a sound Fermix made counts as shown")
    func untouched() {
        let text = "  Indented\n\n\nTwo gaps, and /usr/bin/python3\n"
        #expect(Self.strip(text).text == text)

        let sound = Self.strip("Recorded it:\n\n/Users/me/.fermix/w/take.m4a")
        #expect(sound.text == "Recorded it:")
        #expect(sound.sounds.count == 1)
    }
}
