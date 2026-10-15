import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FermixAppCore

/// What a row's media needs that outlives the chat surface: the home a visit
/// reads as the surface appears, each row's strip kept for its content and
/// that visit, a tile's file read against the visit's home, and the app a
/// type opens in, looked up once. The disk is a temporary folder of its own.
@MainActor
@Suite("Chat media")
struct ChatMediaTests {
    private typealias F = ChatFactsFixture

    private static func media(
        home: @escaping () throws -> URL = { URL(fileURLWithPath: "/Users/me/.fermix") },
        apps: FakeDocumentApplications = FakeDocumentApplications()
    ) -> ChatMedia {
        ChatMedia(
            home: home,
            userHome: "/Users/me",
            reader: FakeMediaReader(),
            facts: FakeMediaFacts(),
            documentApplication: { apps.lookUp($0) },
            deadlines: ManualDeadlineScheduler()
        )
    }

    private static func row(_ seq: Int, _ text: String, role: String = "assistant", previews: [CompanionLinkPreview] = []) -> CompanionRow {
        CompanionRow(
            serverSeq: seq, text: text, role: role, timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil,
            linkPreviews: previews
        )
    }

    // MARK: - The visit

    /// The home is read as the surface appears, once for the visit: the
    /// surface keeps what it read, so the next visit reads it again. A home
    /// that cannot be read has nothing inside it.
    @Test("each visit reads the home once, and a home that cannot be read has nothing inside it")
    func visit() {
        let reads = CountingBox()
        let media = Self.media(home: {
            reads.increment()
            return URL(fileURLWithPath: "/Users/me/.fermix")
        })

        let visit = media.surfaceEntered()
        #expect(reads.count == 1)
        #expect(visit.home == URL(fileURLWithPath: "/Users/me/.fermix"))
        #expect(visit.paths?.contains(URL(fileURLWithPath: "/Users/me/.fermix/a.png", isDirectory: false)) == true)

        _ = media.strip(for: Self.row(1, "Wrote /Users/me/.fermix/out/notes.txt"), in: visit)
        #expect(reads.count == 1)

        _ = media.surfaceEntered()
        #expect(reads.count == 2)

        let unreadable = Self.media(home: { throw CocoaError(.fileReadCorruptFile) }).surfaceEntered()
        #expect(unreadable == ChatVisit(home: nil, paths: nil))
    }

    // MARK: - The memo

    /// History can bring a held row again with more in it, and a visit can
    /// find the home elsewhere: its strip is worked out again then.
    @Test("a row's strip is kept for its content and visit, and worked out again when either changes")
    func memo() throws {
        let media = Self.media()
        let visit = media.surfaceEntered()
        let row = Self.row(7, "Wrote /Users/me/.fermix/out/notes.txt and https://a.com/x")
        let enriched = Self.row(7, row.text, previews: [CompanionLinkPreview(url: "https://a.com/x", site: "A", title: "A page", description: nil, imageRef: nil)])

        let first = media.strip(for: row, in: visit)
        #expect(media.strip(for: row, in: visit) == first)
        #expect(first.items.map(\.id) == ["file:///Users/me/.fermix/out/notes.txt", "https://a.com/x"])

        guard case .link(let link)? = media.strip(for: enriched, in: visit).cards.last else {
            Issue.record("the address is not a card")
            return
        }
        #expect(link.preview?.title == "A page")

        #expect(media.strip(for: enriched, in: nil).items.map(\.id) == ["https://a.com/x"])
    }

    /// A person's words are read as they typed them; the row's role says
    /// whose they are.
    @Test("a person's row is read as plain text and Fermix's as markdown")
    func roleReading() {
        let media = Self.media()
        let text = "Look at `~/Desktop/a.png`"

        #expect(media.strip(for: Self.row(1, text, role: CompanionProtocol.userRole), in: nil).items.isEmpty)
        #expect(media.strip(for: Self.row(2, text), in: nil).items.map(\.id) == ["file:///Users/me/Desktop/a.png"])
    }

    // MARK: - A tile's file

    @Test("a tile's file is read off the main thread against the visit's home, and a missing one is missing")
    func lookUp() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let inside = try place.write("shot.png", in: place.home)
        let outside = try place.write("far.png", in: place.outside)
        let media = Self.media(home: { place.home })
        let visit = media.surfaceEntered()

        guard case .found(let facts) = await media.lookUp(inside, in: visit) else {
            Issue.record("the file inside the home was not found")
            return
        }
        #expect(facts.insideHome)
        #expect(facts.file == FilePlaceFixture.real(inside))

        guard case .found(let far) = await media.lookUp(outside, in: visit) else {
            Issue.record("the file outside the home was not found")
            return
        }
        #expect(!far.insideHome)

        #expect(await media.lookUp(place.home.appendingPathComponent("gone.png"), in: visit) == .missing)
    }

    // MARK: - Where a tile opens outside

    @Test("an Opens outside tile's app is looked up once per type, and Finder needs no lookup")
    func hints() async {
        let apps = FakeDocumentApplications([UTType.mpeg4Movie.identifier: "Infuse"])
        let media = Self.media(apps: apps)

        #expect(await media.hint(for: F.facts("/h/clip.mp4")) == .openIn("Infuse"))
        #expect(await media.hint(for: F.facts("/h/other.mp4", number: 2)) == .openIn("Infuse"))
        #expect(await media.hint(for: F.facts("/h/clip.mov", number: 3)) == .showInFinder)
        #expect(await media.hint(for: F.facts("/h/book.epub", number: 4)) == .showInFinder)
        #expect(apps.lookups == [.mpeg4Movie, .quickTimeMovie])
    }

    // MARK: - What the rows read

    /// The media and the player are each one object for the app's life, so
    /// two contexts are the same when they, the visit and the column are: a
    /// keystroke that redraws the surface must not redraw every row.
    @Test("two row contexts are the same when their media, player, visit and column are")
    func contextEquality() {
        let media = Self.media()
        let player = AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts())
        let visit = media.surfaceEntered()
        let context = ChatRowContext(media: media, player: player, visit: visit, columnWidth: 720)

        #expect(context == ChatRowContext(media: media, player: player, visit: visit, columnWidth: 720))
        #expect(context != ChatRowContext(media: media, player: player, visit: visit, columnWidth: 430))
        #expect(context != ChatRowContext(media: media, player: player, visit: nil, columnWidth: 720))
        #expect(context != ChatRowContext(media: Self.media(), player: player, visit: visit, columnWidth: 720))
        #expect(context != ChatRowContext(media: media, player: AppPlayer(engine: FakePlaybackEngine(), facts: FakeMediaFacts()), visit: visit, columnWidth: 720))
    }
}

/// Where a file a tile names really is, read off the disk: inside the Fermix
/// home only where it really lands inside, its identity on this Mac, and its
/// executable bit; and the home's spellings, which the strip reads a path's
/// text against before the disk is asked.
@MainActor
@Suite("Chat file facts")
struct ChatFileFactsTests {
    @Test("a file is inside the home where it really lands, so a link in the home pointing out is outside")
    func insideHome() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let inside = try place.write("shot.png", in: place.home)
        let far = try place.write("far.png", in: place.outside)
        let link = place.home.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: far)

        #expect(ChatFileFacts.read(inside, home: place.home)?.insideHome == true)
        #expect(ChatFileFacts.read(far, home: place.home)?.insideHome == false)
        #expect(ChatFileFacts.read(link, home: place.home)?.insideHome == false)
        #expect(ChatFileFacts.read(link, home: place.home)?.file == FilePlaceFixture.real(far))
        #expect(ChatFileFacts.read(inside, home: nil)?.insideHome == false)
        #expect(ChatFileFacts.read(place.home.appendingPathComponent("gone.png"), home: place.home) == nil)
    }

    /// The preview cache keys on a file's volume and number: a link reads as
    /// the file it reaches, and two files are two.
    @Test("a file's identity is its own, reached directly or through a link")
    func identity() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let one = try place.write("one.png", in: place.home)
        let two = try place.write("two.png", in: place.home)
        let link = place.home.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)

        let first = try #require(ChatFileFacts.read(one, home: place.home))
        #expect(ChatFileFacts.read(link, home: place.home)?.identity == first.identity)
        #expect(ChatFileFacts.read(two, home: place.home)?.identity != first.identity)
        #expect(first.size == 5)
    }

    @Test("a regular file's executable bit is read, and a folder is a folder")
    func executable() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let tool = try place.write("clip.mov", in: place.home, executable: true)
        let plain = try place.write("plain.mov", in: place.home)
        let folder = try place.folder("out", in: place.home)

        #expect(ChatFileFacts.read(tool, home: place.home)?.disk.entry == .file(size: 5, isExecutable: true))
        #expect(ChatFileFacts.read(plain, home: place.home)?.disk.entry == .file(size: 5, isExecutable: false))
        #expect(ChatFileFacts.read(folder, home: place.home)?.disk.entry == .folder)
    }

    /// A home reached through a link is spelled both ways: as the record
    /// writes it, and as it really lands (`/tmp` is `/private/tmp`, and the
    /// temporary folder is under `/var`, which is `/private/var`).
    @Test("the home's spellings are where it is written and where it really lands")
    func spellings() throws {
        #expect(FilePlace.spellings(of: URL(fileURLWithPath: "/tmp/fermix-chat-home", isDirectory: true))
            == ["/tmp/fermix-chat-home", "/private/tmp/fermix-chat-home"])

        let place = try FilePlaceFixture()
        defer { place.remove() }
        let home = ChatHome(place.home)
        let real = FilePlaceFixture.real(place.home)

        #expect(home.roots == FilePlace.spellings(of: place.home))
        #expect(home.roots.contains(real.path))
        #expect(home.contains(place.home.appendingPathComponent("a.png")))
        #expect(home.contains(real.appendingPathComponent("a.png")))
        #expect(!home.contains(place.outside.appendingPathComponent("a.png")))
        #expect(!home.contains(place.home))
    }
}
