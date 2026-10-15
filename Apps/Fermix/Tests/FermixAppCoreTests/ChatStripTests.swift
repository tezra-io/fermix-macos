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
        refs: [CompanionMediaRef] = [],
        previews: [CompanionLinkPreview] = [],
        home: ChatHome? = home
    ) -> ChatStrip {
        ChatStrip(text: text, mediaRefs: refs, linkPreviews: previews, userHome: "/Users/me", home: home)
    }

    private static func ref(_ name: String, kind: String = "image", mime: String = "image/png") -> CompanionMediaRef {
        CompanionMediaRef(ref: String(repeating: String(name.prefix(1)), count: 64), kind: kind, mime: mime, sizeBytes: 10, sha256: nil, filename: name, caption: nil)
    }

    private static func preview(_ url: String, title: String = "Title") -> CompanionLinkPreview {
        CompanionLinkPreview(url: url, site: "Site", title: title, description: nil, imageRef: nil)
    }

    /// Each item as one short line, so a whole strip reads as a list.
    private static func described(_ strip: ChatStrip) -> [String] {
        described(Strip(cards: strip.items))
    }

    /// Any run of items, as `described` lists a strip's.
    private struct Strip {
        let cards: [ChatStripItem]
    }

    private static func described(_ strip: Strip) -> [String] {
        strip.cards.map { item in
            switch item {
            case .media(let ref): return "ref \(ref.filename ?? "")"
            case .file(let file): return "file \(file.path)"
            case .link(let link): return "link \(link.address.absoluteString)" + (link.preview.map { " = \($0.url)" } ?? "")
            }
        }
    }

    // MARK: - Order and membership

    /// A preview that is no address's stands on its own before the paths,
    /// and an address's own preview is drawn at the address's place. A page
    /// Fermix made draws its content, so it leads, ahead of every card.
    @Test("previews lead; then refs, loose previews, paths worth seeing and addresses, each once")
    func order() {
        let strip = Self.strip(
            "See https://b.com/x and /Users/me/.fermix/workspace/report.pdf, then https://b.com/x and ~/notes.pdf again.",
            refs: [Self.ref("photo.png")],
            previews: [Self.preview("https://b.com/x"), Self.preview("https://c.com/z")]
        )

        #expect(Self.described(strip) == [
            "file /Users/me/.fermix/workspace/report.pdf",
            "ref photo.png",
            "link https://c.com/z = https://c.com/z",
            "file /Users/me/notes.pdf",
            "link https://b.com/x = https://b.com/x",
        ])
    }

    /// A tile's kind is read from its path, before the disk is asked, so it
    /// keeps its shape whatever the file turns out to be: a preview only for
    /// what is drawn by its content, and only inside the home.
    @Test("a preview is a path inside the home to a picture, a video, a PDF or a document; the rest are cards")
    func previewsAndCards() {
        let strip = Self.strip(
            "Made /Users/me/.fermix/w/shot.png, /Users/me/.fermix/w/clip.mov, /Users/me/.fermix/w/q3.docx and "
                + "/Users/me/.fermix/w/Notes.pages, besides /Users/me/.fermix/w/logo.svg, /Users/me/.fermix/w/page.html, "
                + "/Users/me/.fermix/w/table.csv, ~/Desktop/far.png and https://a.com/x",
            refs: [Self.ref("phone.png")]
        )

        #expect(strip.previews.map(\.lastPathComponent) == ["shot.png", "clip.mov", "q3.docx", "Notes.pages"])
        #expect(Self.described(Strip(cards: strip.cards)) == [
            "ref phone.png",
            "file /Users/me/.fermix/w/logo.svg",
            "file /Users/me/.fermix/w/page.html",
            "file /Users/me/.fermix/w/table.csv",
            "file /Users/me/Desktop/far.png",
            "link https://a.com/x",
        ])
    }

    /// The engine reads code too: a preview of an address the text has in
    /// code pairs with it, and stands as its own item, the text's address
    /// being no link.
    @Test("a preview of an address in code stands on its own and opens that address")
    func previewOfCode() {
        let strip = Self.strip("Fetched `https://c.com/y` for you", previews: [Self.preview("https://www.c.com/y")])

        #expect(Self.described(strip) == ["link https://c.com/y = https://www.c.com/y"])
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

    /// The engine stores a preview under the address it reached, so with as
    /// many previews as addresses it read, they pair by order whatever the
    /// redirect did, and a click opens the address the text wrote.
    @Test("a preview stored under a redirected address pairs with the written one by order")
    func redirectedPreviews() {
        let strip = Self.strip(
            "Old http://a.com/x and short https://t.co/abc",
            previews: [Self.preview("https://a.com/x"), Self.preview("https://www.example.com/article")]
        )

        #expect(Self.described(strip) == [
            "link http://a.com/x = https://a.com/x",
            "link https://t.co/abc = https://www.example.com/article",
        ])
    }

    @Test("a host gaining www pairs by order too, and the click keeps the address as written")
    func hostGainingWWW() throws {
        let strip = Self.strip("Read https://example.com/news.", previews: [Self.preview("https://www.example.com/news")])
        let item = try #require(strip.items.first)

        #expect(strip.items.count == 1)
        #expect(item == .link(ChatStripLink(address: URL(string: "https://example.com/news")!, preview: Self.preview("https://www.example.com/news"))))
    }

    /// One page failed, so the counts differ: a preview belongs to an
    /// address only when the two are the same destination.
    @Test("with fewer previews than addresses, only an equal pair matches")
    func fewerPreviews() {
        let equal = Self.strip("https://a.com/x and https://b.com/y", previews: [Self.preview("https://B.com/y")])
        #expect(Self.described(equal) == ["link https://a.com/x", "link https://b.com/y = https://B.com/y"])

        let unequal = Self.strip("https://a.com/x and https://b.com/y", previews: [Self.preview("https://www.b.com/y")])
        #expect(Self.described(unequal) == [
            "link https://www.b.com/y = https://www.b.com/y",
            "link https://a.com/x",
            "link https://b.com/y",
        ])
    }

    /// The engine strips every closing bracket, a page's own among them;
    /// the text's link keeps it, and the two are still one address.
    @Test("an address the engine read short of its own bracket pairs with the text's link")
    func engineReadsShort() {
        let strip = Self.strip("Read https://w.org/Foo_(bar).", previews: [Self.preview("https://w.org/Foo_(bar")])

        #expect(Self.described(strip) == ["link https://w.org/Foo_(bar) = https://w.org/Foo_(bar"])
    }

    /// The engine reads the raw text: code and markdown included, the first
    /// two different addresses, each less a run of closing marks.
    @Test("the engine's addresses are the first two different ones in the raw text, closing marks stripped")
    func engineAddresses() {
        #expect(ChatStrip.engineAddresses(in: "See https://a.com/x, [b](HTTPS://b.com/y)) and https://a.com/x again, https://c.com") == [
            "https://a.com/x", "HTTPS://b.com/y",
        ])
        // The engine keeps a code span's closing backtick, which pairing sets aside.
        #expect(ChatStrip.engineAddresses(in: "Run `https://a.com/x`.") == ["https://a.com/x`"])
        #expect(ChatStrip.engineAddresses(in: "https://w.org/Foo_(bar)!?") == ["https://w.org/Foo_(bar"])
        #expect(ChatStrip.engineAddresses(in: "no address here").isEmpty)
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

    /// The person's own message follows the same rule: the picture they
    /// named is under it, so the line that only names it goes.
    @Test("a person's own message loses the line that only names its picture")
    func ownMessage() {
        let text = "Can you look at this?\n~/Desktop/shot.png"

        #expect(Self.strip(text).text == "Can you look at this?")
        #expect(Self.strip("What is in ~/Desktop/shot.png?").text == "What is in ~/Desktop/shot.png?")
    }

    @Test("a text that loses no line is kept exactly, and a sound Fermix made counts as shown")
    func untouched() {
        let text = "  Indented\n\n\nTwo gaps, and /usr/bin/python3\n"
        #expect(Self.strip(text).text == text)

        let sound = Self.strip("Recorded it:\n\n/Users/me/.fermix/w/take.m4a")
        #expect(sound.text == "Recorded it:")
        #expect(sound.sounds.count == 1)
    }

    // MARK: - Kept per content

    /// History can bring a held row again with more in it: its strip is
    /// worked out again then, and only then.
    @MainActor
    @Test("a row's strip is worked out once for its content, and again when the content changes")
    func keptPerContent() {
        let media = ChatMedia(home: { URL(fileURLWithPath: "/Users/me/.fermix") }, player: AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts()), reader: FakeMediaReader(), documentApplication: { _ in nil }, deadlines: ManualDeadlineScheduler())
        let row = CompanionRow(serverSeq: 7, text: "See https://a.com/x", role: "assistant", timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil)
        let enriched = CompanionRow(
            serverSeq: 7, text: "See https://a.com/x", role: "assistant", timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil,
            linkPreviews: [Self.preview("https://a.com/x", title: "A page")]
        )

        let first = media.strip(for: row)
        #expect(media.strip(for: row) == first)
        #expect(first.items == [.link(ChatStripLink(address: URL(string: "https://a.com/x")!, preview: nil))])

        let second = media.strip(for: enriched)
        #expect(second.items == [.link(ChatStripLink(address: URL(string: "https://a.com/x")!, preview: Self.preview("https://a.com/x", title: "A page")))])
    }

    /// The home is read from the bootstrap record once a visit, as the
    /// browser reads it once an open, and a home that cannot be read has
    /// nothing inside it.
    @MainActor
    @Test("the Fermix home is read once a visit to Chat, and again on the next")
    func homeReadOnceAVisit() {
        let reads = CountingBox()
        let media = ChatMedia(
            home: {
                reads.increment()
                return URL(fileURLWithPath: "/Users/me/.fermix")
            },
            player: AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts()),
            reader: FakeMediaReader(),
            documentApplication: { _ in nil },
            deadlines: ManualDeadlineScheduler()
        )
        let row = { (seq: Int) in
            CompanionRow(serverSeq: seq, text: "Wrote /Users/me/.fermix/out/notes.txt", role: "assistant", timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil)
        }

        #expect(media.strip(for: row(1)).items == [.file(URL(fileURLWithPath: "/Users/me/.fermix/out/notes.txt", isDirectory: false))])
        _ = media.strip(for: row(2))
        #expect(reads.count == 1)

        media.surfaceLeft()
        _ = media.strip(for: row(3))
        #expect(reads.count == 2)

        let unreadable = ChatMedia(home: { throw CocoaError(.fileReadCorruptFile) }, player: AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts()), reader: FakeMediaReader(), documentApplication: { _ in nil }, deadlines: ManualDeadlineScheduler())
        #expect(unreadable.strip(for: row(4)).items.isEmpty)
    }

    /// The media is one object for the app's life, so two contexts are the
    /// same when it and the column are: a keystroke that redraws the surface
    /// must not redraw every row.
    @MainActor
    @Test("two strip contexts are the same when their media and column width are")
    func contextEquality() {
        let media = ChatMedia(home: { URL(fileURLWithPath: "/h") }, player: AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts()), reader: FakeMediaReader(), documentApplication: { _ in nil }, deadlines: ManualDeadlineScheduler())
        let other = ChatMedia(home: { URL(fileURLWithPath: "/h") }, player: AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts()), reader: FakeMediaReader(), documentApplication: { _ in nil }, deadlines: ManualDeadlineScheduler())
        let context = ChatStripContext(media: media, columnWidth: 720)

        #expect(context == ChatStripContext(media: media, columnWidth: 720))
        #expect(context != ChatStripContext(media: media, columnWidth: 430))
        #expect(context != ChatStripContext(media: other, columnWidth: 720))
    }
}
