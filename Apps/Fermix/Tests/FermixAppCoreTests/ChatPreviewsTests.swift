import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FermixAppCore

/// The previews' budgets, through a fake renderer: two jobs at once, 64
/// waiting with the oldest let go, one job shared by every tile asking for
/// the same preview, a tile leaving the screen cancelling its ask, ten
/// seconds before a job counts as failed, one retry, results for a job let
/// go dropped, and a cache counted in decoded bytes. No disk, no network.
@MainActor
@Suite("Chat previews")
struct ChatPreviewsTests {
    private typealias F = ChatFactsFixture

    private static let size = CGSize(width: 200, height: 133)

    private static func request(_ number: UInt64, path: String? = nil) -> ChatPreviewRequest {
        ChatPreviewRequest(F.facts(path ?? "/h/shot\(number).png", number: number), size: size, scale: 2)
    }

    private static func file(_ number: UInt64) -> URL {
        URL(fileURLWithPath: "/h/shot\(number).png")
    }

    /// Every picture the requests name, as ImageIO would read it: small.
    private static func pictures(_ numbers: ClosedRange<UInt64>) -> [URL: ChatPictureFacts] {
        Dictionary(uniqueKeysWithValues: numbers.map { (file($0), ChatPictureFacts(pixels: 400 * 300, animated: false)) })
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }

        try #require(condition(), "the previews did not reach the expected point")
    }

    @Test("the budgets are the section's starting numbers")
    func budgets() {
        #expect(ChatPreviewBudget.jobs == 2)
        #expect(ChatPreviewBudget.waiting == 64)
        #expect(ChatPreviewBudget.timeout == 10)
        #expect(ChatPreviewBudget.cacheBytes == 32 * 1024 * 1024)
        #expect(ChatPreviewBudget.pixels == 100_000_000)
        #expect(ChatPreviewBudget.tries == 2)
    }

    // MARK: - Jobs

    @Test("at most two jobs run at once, and the next starts as one ends")
    func jobLimit() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...3))
        let previews = ChatPreviews(reader: reader, deadlines: ManualDeadlineScheduler())

        let first = Task { await previews.preview(Self.request(1)) }
        let second = Task { await previews.preview(Self.request(2)) }
        let third = Task { await previews.preview(Self.request(3)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 2 && previews.waitingCount == 1 }
        #expect(previews.runningCount == 2)
        #expect(reader.thumbnailsAsked == [Self.file(1), Self.file(2)])

        let image = FakeMediaReader.image()
        reader.finish(Self.file(1), with: image)
        #expect(await first.value == .made(ChatPreview(image: image, detail: nil)))
        try await Self.waitUntil { reader.thumbnailsAsked.count == 3 }
        #expect(previews.waitingCount == 0)

        reader.finish(Self.file(2), with: image)
        reader.finish(Self.file(3), with: image)
        _ = await (second.value, third.value)
        #expect(previews.runningCount == 0)
    }

    @Test("two tiles asking for one preview share one job, and a kept preview needs none")
    func sharedJobs() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...1))
        let previews = ChatPreviews(reader: reader, deadlines: ManualDeadlineScheduler())

        let first = Task { await previews.preview(Self.request(1)) }
        let second = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 1 }
        for _ in 0..<100 { await Task.yield() }
        #expect(reader.thumbnailsAsked.count == 1)

        let image = FakeMediaReader.image()
        reader.finish(Self.file(1), with: image)
        let made = ChatPreviewOutcome.made(ChatPreview(image: image, detail: nil))
        #expect(await first.value == made)
        #expect(await second.value == made)

        #expect(await previews.preview(Self.request(1)) == made)
        #expect(reader.thumbnailsAsked.count == 1)
    }

    /// A tile that leaves the screen stops asking; a job one tile still waits
    /// on goes on for it, and one nobody waits on is stopped.
    @Test("a tile leaving the screen cancels its ask, and a job nobody waits on stops")
    func cancelledOffScreen() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...1))
        let previews = ChatPreviews(reader: reader, deadlines: ManualDeadlineScheduler())

        let leaving = Task { await previews.preview(Self.request(1)) }
        let staying = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 1 }

        leaving.cancel()
        #expect(await leaving.value == .dropped)
        #expect(previews.runningCount == 1)
        #expect(reader.thumbnailsCancelled == 0)

        staying.cancel()
        #expect(await staying.value == .dropped)
        try await Self.waitUntil { reader.thumbnailsCancelled == 1 }
        #expect(previews.runningCount == 0)
    }

    @Test("past 64 waiting, the oldest waiting is let go")
    func waitingCap() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...67))
        let previews = ChatPreviews(reader: reader, deadlines: ManualDeadlineScheduler())

        var asks: [Task<ChatPreviewOutcome, Never>] = []
        for number in UInt64(1)...66 {
            let request = Self.request(number)
            asks.append(Task { await previews.preview(request) })
            try await Self.waitUntil { previews.runningCount + previews.waitingCount == Int(number) }
        }
        #expect(previews.waitingCount == 64)

        let newest = Self.request(67)
        asks.append(Task { await previews.preview(newest) })
        #expect(await asks[2].value == .dropped)
        #expect(previews.waitingCount == 64)
        #expect(previews.runningCount == 2)

        for ask in asks { ask.cancel() }
    }

    /// A renderer that finishes whatever it is told: the result comes back
    /// for a job already let go, and nobody is waiting for it.
    @Test("a result for a job let go is dropped, never kept")
    func staleResults() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...1), stopsWhenCancelled: false)
        let previews = ChatPreviews(reader: reader, deadlines: ManualDeadlineScheduler())

        let ask = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 1 }
        ask.cancel()
        #expect(await ask.value == .dropped)

        reader.finish(Self.file(1), with: FakeMediaReader.image())
        for _ in 0..<100 { await Task.yield() }
        #expect(previews.cachedBytes == 0)
        #expect(previews.runningCount == 0)
    }

    /// No tile waits for ever: ten seconds is a failure. The next appearance
    /// tries once more, and after that the tile is left Preview unavailable
    /// without asking again.
    @Test("a job past ten seconds fails, is tried once more, and then not again")
    func timeoutAndRetry() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...1))
        let deadlines = ManualDeadlineScheduler()
        let previews = ChatPreviews(reader: reader, deadlines: deadlines)

        let first = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 1 }
        #expect(deadlines.scheduledDelays == [10])
        deadlines.fireAll()
        #expect(await first.value == .failed)
        try await Self.waitUntil { reader.thumbnailsCancelled == 1 }

        let second = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 2 }
        reader.fail(Self.file(1))
        #expect(await second.value == .failed)

        #expect(await previews.preview(Self.request(1)) == .failed)
        #expect(reader.thumbnailsAsked.count == 2)
        #expect(previews.runningCount == 0)
    }

    // MARK: - One job's work

    @Test("a picture past 100 megapixels, or one whose size cannot be read, shows its icon and decodes nothing")
    func pixelCeiling() async {
        let large = URL(fileURLWithPath: "/h/large.png")
        let reader = FakeMediaReader(
            thumbnails: .immediate(FakeMediaReader.image()),
            pictures: [large: ChatPictureFacts(pixels: 100_000_001, animated: false)]
        )

        #expect(await ChatPreviews.make(Self.request(1, path: "/h/large.png"), with: reader) == .iconOnly)
        #expect(await ChatPreviews.make(Self.request(2, path: "/h/unreadable.png"), with: reader) == .iconOnly)
        #expect(reader.thumbnailsAsked.isEmpty)
    }

    @Test("a moving picture is drawn still with its mark, a PDF with its pages, a video with its length")
    func details() async {
        let image = FakeMediaReader.image()
        let reader = FakeMediaReader(
            thumbnails: .immediate(image),
            pictures: [URL(fileURLWithPath: "/h/wave.gif"): ChatPictureFacts(pixels: 100, animated: true)],
            pages: [URL(fileURLWithPath: "/h/report.pdf"): 12],
            lengths: [URL(fileURLWithPath: "/h/clip.mp4"): 42]
        )

        #expect(await ChatPreviews.make(Self.request(1, path: "/h/wave.gif"), with: reader) == .made(ChatPreview(image: image, detail: .animated)))
        #expect(await ChatPreviews.make(Self.request(2, path: "/h/report.pdf"), with: reader) == .made(ChatPreview(image: image, detail: .pages(12))))
        #expect(await ChatPreviews.make(Self.request(3, path: "/h/clip.mp4"), with: reader) == .made(ChatPreview(image: image, detail: .length(42))))
        #expect(await ChatPreviews.make(Self.request(4, path: "/h/q3.docx"), with: reader) == .made(ChatPreview(image: image, detail: nil)))
    }

    @Test("a video AVFoundation cannot play opens outside, and no frame is made of it")
    func unplayableVideo() async {
        let clip = URL(fileURLWithPath: "/h/clip.mp4")
        let reader = FakeMediaReader(thumbnails: .immediate(FakeMediaReader.image()), unplayable: [clip])

        #expect(await ChatPreviews.make(Self.request(1, path: clip.path), with: reader) == .unplayable)
        #expect(reader.thumbnailsAsked.isEmpty)
    }

    /// The key holds the file's identity, date and size and the pixel size,
    /// so an edited file, or one tile drawn larger, is a different preview.
    @Test("a preview is keyed by the file's identity, date and size and by its pixels")
    func keys() {
        let facts = F.facts("/h/shot.png", number: 9, size: 100)
        let key = ChatPreviewRequest(facts, size: Self.size, scale: 2).key

        #expect(key.pixelWidth == 400)
        #expect(key.pixelHeight == 266)
        #expect(key != ChatPreviewRequest(F.facts("/h/shot.png", number: 9, size: 101), size: Self.size, scale: 2).key)
        #expect(key != ChatPreviewRequest(facts, size: Self.size, scale: 1).key)
        #expect(key == ChatPreviewRequest(F.facts("/h/renamed.png", number: 9, size: 100), size: Self.size, scale: 2).key)
    }

    // MARK: - The cache

    @Test("the cache keeps decoded bytes under its cap, letting the least recently used go first")
    func cacheCap() throws {
        let preview = ChatPreview(image: FakeMediaReader.image(width: 8, height: 8), detail: nil)
        var cache = ChatPreviewCache(capacity: preview.bytes * 3)
        let keys = (UInt64(1)...4).map { Self.request($0).key }

        for key in keys.prefix(3) { cache.insert(preview, for: key) }
        #expect(cache.bytes == preview.bytes * 3)
        #expect(cache.preview(for: keys[0]) == preview)

        cache.insert(preview, for: keys[3])
        #expect(cache.bytes == preview.bytes * 3)
        #expect(cache.preview(for: keys[1]) == nil)
        #expect(cache.preview(for: keys[0]) == preview)
        #expect(cache.preview(for: keys[2]) == preview)
        #expect(cache.preview(for: keys[3]) == preview)

        var small = ChatPreviewCache(capacity: preview.bytes - 1)
        small.insert(preview, for: keys[0])
        #expect(small.bytes == 0)
        #expect(small.preview(for: keys[0]) == nil)
    }

    // MARK: - Where a tile opens outside

    @Test("an Opens outside tile's app is looked up once per type, and Finder needs no lookup")
    func hints() async {
        let reader = FakeMediaReader(apps: [UTType.mpeg4Movie.identifier: "Infuse"])
        let media = ChatMedia(home: { URL(fileURLWithPath: "/h") }, player: AppPlayer(engine: FakePlaybackEngine()), reader: reader, deadlines: ManualDeadlineScheduler())

        #expect(await media.hint(for: F.facts("/h/clip.mp4")) == .openIn("Infuse"))
        #expect(await media.hint(for: F.facts("/h/other.mp4", number: 2)) == .openIn("Infuse"))
        #expect(await media.hint(for: F.facts("/h/clip.mov", number: 3)) == .showInFinder)
        #expect(await media.hint(for: F.facts("/h/book.epub", number: 4)) == .showInFinder)
        #expect(reader.appLookups == [.mpeg4Movie, .quickTimeMovie])
    }
}
