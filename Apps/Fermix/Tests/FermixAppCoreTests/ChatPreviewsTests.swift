import CoreGraphics
import Foundation
import Testing

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

    /// A made preview as its picture's size and its detail: every preview is
    /// cut to its tile's pixels, 400 by 266 for these 200-by-133 tiles at
    /// twice the scale.
    private struct Made: Equatable {
        let width: Int
        let height: Int
        let detail: ChatPreviewDetail?
    }

    private static func made(_ outcome: ChatPreviewOutcome) -> Made? {
        guard case .made(.picture(let preview)) = outcome else { return nil }

        return Made(width: preview.image.width, height: preview.image.height, detail: preview.detail)
    }

    /// One job's work on the file a request names, where it names one.
    private static func make(_ request: ChatPreviewRequest, with reader: FakeMediaReader, facts: FakeMediaFacts) async -> ChatPreviewOutcome {
        guard case .file(let file) = request.source else { return .failed }

        return await ChatPreviews.make(request, from: file, with: reader, facts: facts)
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

    /// A tile asks again, on its next appearance, only where its last answer
    /// was not final: a failure or a job let go.
    @Test("a made preview, an icon and an unplayable film are final; a failure and a drop are not")
    func finalAnswers() {
        #expect(ChatPreviewOutcome.made(.picture(ChatPreview(image: fixturePicture(), detail: nil))).isFinal)
        #expect(ChatPreviewOutcome.made(.levels(SoundLevels(values: [0.5], seconds: 1))).isFinal)
        #expect(ChatPreviewOutcome.iconOnly.isFinal)
        #expect(ChatPreviewOutcome.unplayable.isFinal)
        #expect(!ChatPreviewOutcome.failed.isFinal)
        #expect(!ChatPreviewOutcome.dropped.isFinal)
    }

    // MARK: - Jobs

    @Test("at most two jobs run at once, and the next starts as one ends")
    func jobLimit() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...3))
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: FakeMediaGrants(), deadlines: ManualDeadlineScheduler())

        let first = Task { await previews.preview(Self.request(1)) }
        let second = Task { await previews.preview(Self.request(2)) }
        let third = Task { await previews.preview(Self.request(3)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 2 && previews.waitingCount == 1 }
        #expect(previews.runningCount == 2)
        // The two run at once, so either may ask first.
        #expect(Set(reader.thumbnailsAsked) == [Self.file(1), Self.file(2)])

        let image = fixturePicture()
        reader.finish(Self.file(1), with: image)
        #expect(Self.made(await first.value) == Made(width: 400, height: 266, detail: nil))
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
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: FakeMediaGrants(), deadlines: ManualDeadlineScheduler())

        let first = Task { await previews.preview(Self.request(1)) }
        let second = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 1 }
        for _ in 0..<100 { await Task.yield() }
        #expect(reader.thumbnailsAsked.count == 1)

        reader.finish(Self.file(1), with: fixturePicture())
        let made = await first.value
        #expect(Self.made(made) == Made(width: 400, height: 266, detail: nil))
        #expect(await second.value == made)

        #expect(await previews.preview(Self.request(1)) == made)
        #expect(reader.thumbnailsAsked.count == 1)
    }

    /// A tile that leaves the screen stops asking; a job one tile still waits
    /// on goes on for it, and one nobody waits on is stopped.
    @Test("a tile leaving the screen cancels its ask, and a job nobody waits on stops")
    func cancelledOffScreen() async throws {
        let reader = FakeMediaReader(pictures: Self.pictures(1...1))
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: FakeMediaGrants(), deadlines: ManualDeadlineScheduler())

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
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: FakeMediaGrants(), deadlines: ManualDeadlineScheduler())

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
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: FakeMediaGrants(), deadlines: ManualDeadlineScheduler())

        let ask = Task { await previews.preview(Self.request(1)) }
        try await Self.waitUntil { reader.thumbnailsAsked.count == 1 }
        ask.cancel()
        #expect(await ask.value == .dropped)

        reader.finish(Self.file(1), with: fixturePicture())
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
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: FakeMediaGrants(), deadlines: deadlines)

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
            thumbnails: .immediate(fixturePicture()),
            pictures: [large: ChatPictureFacts(pixels: 100_000_001, animated: false)]
        )

        #expect(await Self.make(Self.request(1, path: "/h/large.png"), with: reader, facts: FakeMediaFacts()) == .iconOnly)
        #expect(await Self.make(Self.request(2, path: "/h/unreadable.png"), with: reader, facts: FakeMediaFacts()) == .iconOnly)
        #expect(reader.thumbnailsAsked.isEmpty)
    }

    @Test("a moving picture is drawn still with its mark, a PDF with its pages, a video with its length")
    func details() async {
        let image = fixturePicture()
        let reader = FakeMediaReader(
            thumbnails: .immediate(image),
            pictures: [URL(fileURLWithPath: "/h/wave.gif"): ChatPictureFacts(pixels: 100, animated: true)],
            pages: [URL(fileURLWithPath: "/h/report.pdf"): 12]
        )
        let clip = URL(fileURLWithPath: "/h/clip.mp4")
        let facts = FakeMediaFacts(playable: [clip], lengths: [clip: 42])

        #expect(Self.made(await Self.make(Self.request(1, path: "/h/wave.gif"), with: reader, facts: facts)) == Made(width: 400, height: 266, detail: .animated))
        #expect(Self.made(await Self.make(Self.request(2, path: "/h/report.pdf"), with: reader, facts: facts)) == Made(width: 400, height: 266, detail: .pages(12)))
        #expect(Self.made(await Self.make(Self.request(3, path: clip.path), with: reader, facts: facts)) == Made(width: 400, height: 266, detail: .length(42)))
        #expect(Self.made(await Self.make(Self.request(4, path: "/h/q3.docx"), with: reader, facts: facts)) == Made(width: 400, height: 266, detail: nil))
    }

    // MARK: - Filling the tile

    /// Quick Look's thumbnail fits inside what it is asked for, so it is
    /// asked for a square twice the tile's width: large enough to fill the
    /// tile for a page twice as tall as wide or a picture three times as wide
    /// as tall.
    @Test("Quick Look is asked for a square twice the tile's width, and a page is held by its head")
    func askedForEnough() {
        #expect(Self.request(1).box == CGSize(width: 400, height: 400))
        #expect(Self.request(1).pixels == CGSize(width: 400, height: 266))
        #expect(Self.request(1, path: "/h/report.pdf").anchor == .top)
        #expect(Self.request(2, path: "/h/q3.docx").anchor == .top)
        #expect(Self.request(3, path: "/h/shot.png").anchor == .center)
        #expect(Self.request(4, path: "/h/clip.mp4").anchor == .center)
    }

    /// Core Graphics puts the origin at the bottom left: a page held by its
    /// head is drawn so its top meets the tile's top, and what spills over
    /// falls off the bottom.
    @Test("a preview covers its tile, cut at the sides or the foot, never letterboxed")
    func cover() {
        let tile = CGSize(width: 400, height: 267)

        let page = ChatPreviewCover.rect(of: CGSize(width: 100, height: 200), covering: tile, anchor: .top)
        #expect(page == CGRect(x: 0, y: -533, width: 400, height: 800))

        let shot = ChatPreviewCover.rect(of: CGSize(width: 100, height: 200), covering: tile, anchor: .center)
        #expect(shot == CGRect(x: 0, y: -266.5, width: 400, height: 800))

        let wide = ChatPreviewCover.rect(of: CGSize(width: 300, height: 100), covering: tile, anchor: .center)
        #expect(wide.minX < 0)
        #expect(wide.height == 267)
        #expect(abs(wide.midX - 200) < 0.001)

        let cut = ChatPreviewCover.image(fixturePicture(width: 3, height: 9), filling: tile, anchor: .top)
        #expect(cut?.width == 400)
        #expect(cut?.height == 267)
    }

    @Test("a video AVFoundation cannot play opens outside, and no frame is made of it")
    func unplayableVideo() async {
        let clip = URL(fileURLWithPath: "/h/clip.mp4")
        let reader = FakeMediaReader(thumbnails: .immediate(fixturePicture()))

        #expect(await Self.make(Self.request(1, path: clip.path), with: reader, facts: FakeMediaFacts()) == .unplayable)
        #expect(reader.thumbnailsAsked.isEmpty)
    }

    /// The key holds the file's identity, date and size and the pixel size,
    /// so an edited file, or one tile drawn larger, is a different preview.
    @Test("a preview is keyed by the file's identity, date and size and by its pixels")
    func keys() {
        let facts = F.facts("/h/shot.png", number: 9, size: 100)
        let key = ChatPreviewRequest(facts, size: Self.size, scale: 2).key

        #expect(key.form == .picture(pixelWidth: 400, pixelHeight: 266, scale: 2))
        #expect(key != ChatPreviewRequest(F.facts("/h/shot.png", number: 9, size: 101), size: Self.size, scale: 2).key)
        #expect(key != ChatPreviewRequest(facts, size: Self.size, scale: 1).key)
        #expect(key == ChatPreviewRequest(F.facts("/h/renamed.png", number: 9, size: 100), size: Self.size, scale: 2).key)
    }

    // MARK: - Phone-side files (M66 decision 1)

    private static let picture = FakeMediaGrants.ref("b")

    private static func refRequest(_ ref: String, mime: String = "image/png", kind: String = "image") -> ChatPreviewRequest {
        let media = CompanionMediaRef(ref: ref, kind: kind, mime: mime, sizeBytes: 10, sha256: nil, filename: nil, caption: nil)
        return ChatPreviewRequest(media, size: size, scale: 2)
    }

    /// The previews over a fake renderer and fake grants, every ref granted
    /// as a PNG unless the case says otherwise, and every granted picture
    /// small.
    private static func refRig(_ refs: [String], thumbnails: FakeMediaReader.Thumbnails = .held)
        -> (previews: ChatPreviews, reader: FakeMediaReader, grants: FakeMediaGrants, deadlines: ManualDeadlineScheduler) {
        let grants = FakeMediaGrants()
        var pictures: [URL: ChatPictureFacts] = [:]
        for ref in refs {
            let answer = FakeMediaGrants.granted(ref, "png")
            grants.answers[ref] = answer
            if case .granted(let grant) = answer { pictures[grant.url] = ChatPictureFacts(pixels: 400 * 300, animated: false) }
        }
        let reader = FakeMediaReader(thumbnails: thumbnails, pictures: pictures)
        let deadlines = ManualDeadlineScheduler()
        let previews = ChatPreviews(reader: reader, facts: FakeMediaFacts(), levels: FakeSoundLevels(), grants: grants, deadlines: deadlines)
        return (previews, reader, grants, deadlines)
    }

    private static func grantedFile(_ ref: String) -> URL {
        URL(fileURLWithPath: "/fermix/companion/media/\(ref).png")
    }

    @Test("a phone-side file is held from its job's start to its end, and its preview is made from the granted file")
    func refHeldWhileMade() async throws {
        let rig = Self.refRig([Self.picture])

        let ask = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 1 }
        #expect(rig.grants.counts == [Self.picture: 1])
        #expect(rig.reader.thumbnailsAsked == [Self.grantedFile(Self.picture)])

        rig.reader.finish(Self.grantedFile(Self.picture), with: fixturePicture())
        #expect(Self.made(await ask.value) == Made(width: 400, height: 266, detail: nil))
        #expect(rig.grants.log == ["hold " + Self.picture, "release " + Self.picture])
        #expect(rig.grants.held == 0)
    }

    /// Nothing is fetched ahead: a job waiting for one of the two places
    /// holds nothing, and one let go before it starts never holds at all.
    @Test("a waiting job holds nothing, and one let go before it starts is never held")
    func refNeverHeldAhead() async throws {
        let refs = ["1", "2", "3"].map { FakeMediaGrants.ref(Character($0)) }
        let rig = Self.refRig(refs)

        let first = Task { await rig.previews.preview(Self.refRequest(refs[0])) }
        let second = Task { await rig.previews.preview(Self.refRequest(refs[1])) }
        let third = Task { await rig.previews.preview(Self.refRequest(refs[2])) }
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 2 && rig.previews.waitingCount == 1 }
        #expect(rig.grants.holds == 2)
        #expect(rig.grants.counts[refs[2]] == nil, "a waiting job held its file")

        third.cancel()
        #expect(await third.value == .dropped)
        rig.reader.finish(Self.grantedFile(refs[0]), with: fixturePicture())
        rig.reader.finish(Self.grantedFile(refs[1]), with: fixturePicture())
        _ = await (first.value, second.value)

        #expect(rig.grants.holds == 2, "a job let go before it started was held")
        #expect(rig.grants.held == 0)
    }

    /// A ref names its content, so the preview made of one copy serves the
    /// next, whatever path the engine grants it at then.
    @Test("a ref's preview is kept by the ref, so asking again needs no grant")
    func refCacheHit() async throws {
        let rig = Self.refRig([Self.picture], thumbnails: .immediate(fixturePicture()))

        let made = await rig.previews.preview(Self.refRequest(Self.picture))
        rig.grants.answers[Self.picture] = FakeMediaGrants.granted(Self.picture, "png", in: URL(fileURLWithPath: "/elsewhere", isDirectory: true))

        #expect(await rig.previews.preview(Self.refRequest(Self.picture)) == made)
        #expect(rig.grants.holds == 1)
        #expect(rig.reader.thumbnailsAsked.count == 1)
    }

    @Test("a ref's key is the ref with the tile's pixels and scale, never a file's")
    func refKeys() {
        let key = Self.refRequest(Self.picture).key

        #expect(key.content == .ref(Self.picture))
        #expect(key.form == .picture(pixelWidth: 400, pixelHeight: 266, scale: 2))
        #expect(key == Self.refRequest(Self.picture, mime: "image/jpeg").key)
        #expect(key != Self.refRequest(FakeMediaGrants.ref("c")).key)
        #expect(key != ChatPreviewRequest(ref: Self.picture, family: .picture, size: CGSize(width: 28, height: 28), scale: 2).key)
        #expect(key != ChatPreviewRequest(ref: Self.picture, family: .picture, size: Self.size, scale: 1).key)
        #expect(key != Self.request(1).key)
    }

    /// The engine no longer has the bytes: Not available, for good, and
    /// nothing is drawn.
    @Test("a ref whose bytes are gone is Not available, final, and let go")
    func refMissing() async {
        let rig = Self.refRig([])
        rig.grants.answers[Self.picture] = .missing

        let outcome = await rig.previews.preview(Self.refRequest(Self.picture))

        #expect(outcome == .missing)
        #expect(outcome.isFinal)
        #expect(ChatPreviewPolicy.state(of: outcome) == .notAvailable)
        #expect(rig.reader.thumbnailsAsked.isEmpty)
        #expect(rig.grants.held == 0)
    }

    /// The engine could not make the file: Preview unavailable, tried once
    /// more the next time the tile appears, and then not again.
    @Test("a ref the engine could not grant is Preview unavailable, tried once more, then not again")
    func refFailedGrant() async {
        let rig = Self.refRig([])
        rig.grants.answers[Self.picture] = .failed

        let first = await rig.previews.preview(Self.refRequest(Self.picture))
        #expect(first == .failed)
        #expect(ChatPreviewPolicy.state(of: first) == .previewUnavailable)

        #expect(await rig.previews.preview(Self.refRequest(Self.picture)) == .failed)
        #expect(await rig.previews.preview(Self.refRequest(Self.picture)) == .failed)
        #expect(rig.grants.holds == 2)
        #expect(rig.grants.held == 0)
    }

    @Test("a preview that fails on the granted file lets the grant go")
    func refThumbnailFails() async throws {
        let rig = Self.refRig([Self.picture])

        let ask = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 1 }
        rig.reader.fail(Self.grantedFile(Self.picture))

        #expect(await ask.value == .failed)
        #expect(rig.grants.held == 0)
    }

    /// A tile that leaves the screen while its job waits for the engine's
    /// answer stops waiting; the use is still let go.
    @Test("a tile leaving the screen while its file is being granted lets the grant go")
    func refCancelledWhileGranting() async throws {
        let rig = Self.refRig([])

        let ask = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.grants.waitingCount == 1 }
        #expect(rig.grants.held == 1)

        ask.cancel()
        #expect(await ask.value == .dropped)
        try await Self.waitUntil { rig.grants.held == 0 }
        #expect(rig.grants.log == ["hold " + Self.picture, "release " + Self.picture])
        #expect(rig.reader.thumbnailsAsked.isEmpty)
    }

    @Test("a tile leaving the screen while its preview is made lets the grant go")
    func refCancelledWhileMaking() async throws {
        let rig = Self.refRig([Self.picture])

        let ask = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 1 }
        ask.cancel()

        #expect(await ask.value == .dropped)
        try await Self.waitUntil { rig.grants.held == 0 }
        #expect(rig.reader.thumbnailsCancelled == 1)
    }

    @Test("a job past ten seconds lets its grant go")
    func refTimedOut() async throws {
        let rig = Self.refRig([Self.picture])

        let ask = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 1 }
        rig.deadlines.fireAll()

        #expect(await ask.value == .failed)
        try await Self.waitUntil { rig.grants.held == 0 }
    }

    /// A reconnect can take longer than a preview's ten seconds: a grant the
    /// engine has not answered yet starts no clock, so the wait costs the
    /// tile none of its tries, and the clock starts once the file is in hand.
    @Test("a job waiting for its grant has no clock running, and the grant starts it")
    func refWaitStartsNoClock() async throws {
        let rig = Self.refRig([Self.picture])
        rig.grants.answers[Self.picture] = nil

        let ask = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.grants.waitingCount == 1 }
        rig.deadlines.fireAll()
        #expect(rig.previews.runningCount == 1)

        let granted = FakeMediaGrants.granted(Self.picture, "png")
        rig.grants.answers[Self.picture] = granted
        rig.grants.answer(Self.picture, granted)
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 1 }
        rig.deadlines.fireAll()
        #expect(await ask.value == .failed)

        // The wait used none of the tries: the one timeout did, so the tile
        // is asked for once more.
        let again = Task { await rig.previews.preview(Self.refRequest(Self.picture)) }
        try await Self.waitUntil { rig.reader.thumbnailsAsked.count == 2 }
        rig.deadlines.fireAll()
        #expect(await again.value == .failed)
        try await Self.waitUntil { rig.grants.held == 0 }
    }

    /// A long history scrolled through: tiles appear and leave, some before
    /// their job starts, some while it waits for the engine, some while the
    /// preview is made, and the rest see their preview made. Once it settles,
    /// nothing is held, and every hold had its one release.
    @Test("a long history scrolled through holds nothing once its previews are made")
    func longHistoryHoldsNothing() async throws {
        let refs = (1...40).map { String(format: "%064x", $0) }
        let unanswered = refs.suffix(10)
        let rig = Self.refRig(refs)
        for ref in unanswered { rig.grants.answers[ref] = nil }

        let asks = refs.map { ref in Task { await rig.previews.preview(Self.refRequest(ref)) } }
        try await Self.waitUntil { rig.previews.runningCount == 2 }
        for (index, ask) in asks.enumerated() where index.isMultiple(of: 3) { ask.cancel() }

        for _ in 0..<1_000 where rig.previews.runningCount + rig.previews.waitingCount > 0 {
            for ref in unanswered { rig.grants.answer(ref, .missing) }
            for ref in refs { rig.reader.finish(Self.grantedFile(ref), with: fixturePicture()) }
            await Task.yield()
        }
        for ask in asks { _ = await ask.value }

        try await Self.waitUntil { rig.grants.held == 0 }
        #expect(rig.grants.holds > 0)
        #expect(rig.grants.log.filter { $0.hasPrefix("release ") }.count == rig.grants.holds)
    }

    // MARK: - A sound's levels (M66 §3.4)

    private static let note = FakeMediaGrants.ref("a")
    private static let heard = SoundLevels(values: [0, 0.5, 1], seconds: 6.69)

    private static func noteRequest(_ ref: String) -> ChatLevelsRequest {
        ChatLevelsRequest(CompanionMediaRef(ref: ref, kind: "audio", mime: "audio/ogg", sizeBytes: 10, sha256: nil, filename: nil, caption: nil))
    }

    private static func noteFile(_ ref: String) -> URL {
        URL(fileURLWithPath: "/fermix/companion/media/\(ref).ogg")
    }

    /// The previews over a fake levels reader and fake grants, every note
    /// granted as an Ogg file.
    private static func noteRig(_ refs: [String], reads: FakeSoundLevels.Reads = .held)
        -> (previews: ChatPreviews, levels: FakeSoundLevels, grants: FakeMediaGrants, deadlines: ManualDeadlineScheduler) {
        let grants = FakeMediaGrants()
        for ref in refs {
            grants.answers[ref] = FakeMediaGrants.granted(ref, "ogg")
        }
        let levels = FakeSoundLevels(reads)
        let deadlines = ManualDeadlineScheduler()
        let previews = ChatPreviews(reader: FakeMediaReader(), facts: FakeMediaFacts(), levels: levels, grants: grants, deadlines: deadlines)
        return (previews, levels, grants, deadlines)
    }

    @Test("a voice note's levels are read from the granted file, held from the job's start to its end")
    func noteHeldWhileRead() async throws {
        let rig = Self.noteRig([Self.note])

        let ask = Task { await rig.previews.levels(Self.noteRequest(Self.note)) }
        try await Self.waitUntil { rig.levels.levelsAsked.count == 1 }
        #expect(rig.grants.counts == [Self.note: 1])
        #expect(rig.levels.levelsAsked == [Self.noteFile(Self.note)])
        #expect(rig.levels.bucketsAsked == [SoundLevels.buckets])

        rig.levels.finish(Self.noteFile(Self.note), with: Self.heard)
        #expect(await ask.value == .made(.levels(Self.heard)))
        #expect(rig.grants.log == ["hold " + Self.note, "release " + Self.note])
    }

    /// A note whose levels cannot be read keeps its resting bars: tried once
    /// more the next time it appears, and then not again.
    @Test("a voice note whose levels cannot be read fails, is tried once more, and lets its grant go each time")
    func noteReadFails() async {
        let rig = Self.noteRig([Self.note], reads: .immediate(nil))

        #expect(await rig.previews.levels(Self.noteRequest(Self.note)) == .failed)
        #expect(await rig.previews.levels(Self.noteRequest(Self.note)) == .failed)
        #expect(await rig.previews.levels(Self.noteRequest(Self.note)) == .failed)
        #expect(rig.levels.levelsAsked.count == 2)
        #expect(rig.grants.holds == 2)
        #expect(rig.grants.held == 0)
    }

    @Test("a voice note leaving the screen while its levels are read stops the read and lets the grant go")
    func noteCancelledWhileRead() async throws {
        let rig = Self.noteRig([Self.note])

        let ask = Task { await rig.previews.levels(Self.noteRequest(Self.note)) }
        try await Self.waitUntil { rig.levels.levelsAsked.count == 1 }
        ask.cancel()

        #expect(await ask.value == .dropped)
        try await Self.waitUntil { rig.grants.held == 0 }
        #expect(rig.levels.levelsCancelled == 1)
        #expect(rig.grants.log == ["hold " + Self.note, "release " + Self.note])
    }

    @Test("a voice note leaving the screen while its file is being granted reads nothing and lets the grant go")
    func noteCancelledWhileGranting() async throws {
        let rig = Self.noteRig([])

        let ask = Task { await rig.previews.levels(Self.noteRequest(Self.note)) }
        try await Self.waitUntil { rig.grants.waitingCount == 1 }
        ask.cancel()

        #expect(await ask.value == .dropped)
        try await Self.waitUntil { rig.grants.held == 0 }
        #expect(rig.grants.log == ["hold " + Self.note, "release " + Self.note])
        #expect(rig.levels.levelsAsked.isEmpty)
    }

    @Test("a voice note's read past ten seconds fails, stops, and lets its grant go")
    func noteTimedOut() async throws {
        let rig = Self.noteRig([Self.note])

        let ask = Task { await rig.previews.levels(Self.noteRequest(Self.note)) }
        try await Self.waitUntil { rig.levels.levelsAsked.count == 1 }
        #expect(rig.deadlines.scheduledDelays == [10])
        rig.deadlines.fireAll()

        #expect(await ask.value == .failed)
        try await Self.waitUntil { rig.grants.held == 0 }
        #expect(rig.levels.levelsCancelled == 1)
        #expect(rig.grants.holds == 1)
    }

    /// Nothing is fetched ahead: a note waiting behind two jobs holds
    /// nothing, and one that leaves the screen before its job starts is
    /// never held or read.
    @Test("a voice note off screen before its job starts is never held or read")
    func noteNeverHeldAhead() async throws {
        let refs = ["1", "2", "3"].map { FakeMediaGrants.ref(Character($0)) }
        let rig = Self.noteRig(refs)

        let first = Task { await rig.previews.levels(Self.noteRequest(refs[0])) }
        let second = Task { await rig.previews.levels(Self.noteRequest(refs[1])) }
        let third = Task { await rig.previews.levels(Self.noteRequest(refs[2])) }
        try await Self.waitUntil { rig.levels.levelsAsked.count == 2 && rig.previews.waitingCount == 1 }
        #expect(rig.grants.counts[refs[2]] == nil, "a waiting note held its file")

        third.cancel()
        #expect(await third.value == .dropped)
        rig.levels.finish(Self.noteFile(refs[0]), with: Self.heard)
        rig.levels.finish(Self.noteFile(refs[1]), with: Self.heard)
        _ = await (first.value, second.value)

        #expect(!rig.grants.log.contains("hold " + refs[2]))
        #expect(!rig.levels.levelsAsked.contains(Self.noteFile(refs[2])))
        #expect(rig.grants.held == 0)
    }

    /// A ref names its content, so the levels read from one copy serve the
    /// next, whatever path the engine grants it at then.
    @Test("a voice note's levels are kept by its ref, so asking again needs no grant and reads nothing")
    func noteCacheHit() async {
        let rig = Self.noteRig([Self.note], reads: .immediate(Self.heard))

        #expect(await rig.previews.levels(Self.noteRequest(Self.note)) == .made(.levels(Self.heard)))
        rig.grants.answers[Self.note] = FakeMediaGrants.granted(Self.note, "ogg", in: URL(fileURLWithPath: "/elsewhere", isDirectory: true))

        #expect(await rig.previews.levels(Self.noteRequest(Self.note)) == .made(.levels(Self.heard)))
        #expect(rig.grants.holds == 1)
        #expect(rig.levels.levelsAsked.count == 1)
    }

    @Test("a voice note whose bytes are gone is Not available, final, read never and let go")
    func noteMissing() async {
        let rig = Self.noteRig([])
        rig.grants.answers[Self.note] = .missing

        let outcome = await rig.previews.levels(Self.noteRequest(Self.note))

        #expect(outcome == .missing)
        #expect(outcome.isFinal)
        #expect(rig.levels.levelsAsked.isEmpty)
        #expect(rig.grants.held == 0)
    }

    @Test("a sound file's levels are read from the file itself, with no grant, and kept")
    func soundFileLevels() async {
        let rig = Self.noteRig([], reads: .immediate(Self.heard))
        let chime = F.facts("/h/chime.m4a", number: 7)

        #expect(await rig.previews.levels(ChatLevelsRequest(chime)) == .made(.levels(Self.heard)))
        #expect(await rig.previews.levels(ChatLevelsRequest(chime)) == .made(.levels(Self.heard)))
        #expect(rig.levels.levelsAsked == [URL(fileURLWithPath: "/h/chime.m4a")])
        #expect(rig.grants.holds == 0)
    }

    /// A voice note's levels are kept by its ref and the stretches they are
    /// read in; a file's as its preview is, by its identity, date and size.
    @Test("levels are keyed by the ref or the file with the stretches, never as a picture is")
    func levelsKeys() {
        let key = Self.noteRequest(Self.note).key
        let chime = ChatLevelsRequest(F.facts("/h/chime.m4a", number: 7, size: 100)).key

        #expect(key == ChatPreviewKey(.ref(Self.note), buckets: SoundLevels.buckets))
        #expect(key.form == .levels(buckets: SoundLevels.buckets))
        #expect(key != ChatPreviewRequest(ref: Self.note, family: .sound, size: Self.size, scale: 2).key)
        #expect(key != Self.noteRequest(FakeMediaGrants.ref("c")).key)
        #expect(chime == ChatLevelsRequest(F.facts("/h/renamed.m4a", number: 7, size: 100)).key)
        #expect(chime != ChatLevelsRequest(F.facts("/h/chime.m4a", number: 7, size: 101)).key)
        #expect(chime != ChatPreviewRequest(F.facts("/h/chime.m4a", number: 7, size: 100), size: Self.size, scale: 2).key)
    }

    @Test("a sound's levels count in the cache as the floats they are")
    func levelsBytes() {
        #expect(ChatPreviewMade.levels(SoundLevels(values: Array(repeating: 0.5, count: 64), seconds: 1)).bytes == 64 * MemoryLayout<Float>.stride)
    }

    // MARK: - The cache

    @Test("the cache keeps decoded bytes under its cap, letting the least recently used go first")
    func cacheCap() throws {
        let preview = ChatPreviewMade.picture(ChatPreview(image: fixturePicture(width: 8, height: 8), detail: nil))
        var cache = ChatPreviewCache(capacity: preview.bytes * 3)
        let keys = (UInt64(1)...4).map { Self.request($0).key }

        for key in keys.prefix(3) { cache.insert(preview, for: key) }
        #expect(cache.bytes == preview.bytes * 3)
        #expect(cache.made(for: keys[0]) == preview)

        cache.insert(preview, for: keys[3])
        #expect(cache.bytes == preview.bytes * 3)
        #expect(cache.made(for: keys[1]) == nil)
        #expect(cache.made(for: keys[0]) == preview)
        #expect(cache.made(for: keys[2]) == preview)
        #expect(cache.made(for: keys[3]) == preview)

        var small = ChatPreviewCache(capacity: preview.bytes - 1)
        small.insert(preview, for: keys[0])
        #expect(small.bytes == 0)
        #expect(small.made(for: keys[0]) == nil)
    }
}

/// A picture's header is the file's own claim, so its size is never trusted
/// to multiply safely.
@Suite("Chat picture facts")
struct ChatPictureFactsTests {
    @Test("a header's size is its area, and one that overflows or is not positive is past every ceiling")
    func headerSizeNeverTraps() {
        #expect(ChatPictureFacts(width: 400, height: 300, animated: false).pixels == 120_000)
        #expect(ChatPictureFacts(width: Int.max, height: 2, animated: false).pixels == .max)
        #expect(ChatPictureFacts(width: 4_294_967_295, height: 4_294_967_295, animated: false).pixels == .max)
        #expect(ChatPictureFacts(width: 0, height: 300, animated: false).pixels == .max)
        #expect(ChatPictureFacts(width: -1, height: -1, animated: true).pixels == .max)
    }
}
