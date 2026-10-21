import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// What a preview job made of a file's content: the picture a tile draws of
/// it, or the levels a sound's waveform is drawn from. A waveform is a preview
/// of its sound as a thumbnail is of its file, made, kept and let go by the
/// same previews, and so is a map of a reply's places (M72 §7.2).
enum ChatPreviewMade: Equatable, Sendable {
    case picture(ChatPreview)
    case levels(SoundLevels)
    case map(PlaceMapPicture)

    /// What it holds decoded, which the cache counts.
    var bytes: Int {
        switch self {
        case .picture(let preview): return preview.bytes
        case .levels(let levels): return levels.bytes
        case .map(let map): return map.bytes
        }
    }
}

/// A preview made of a file's content at its tile's pixel size, and what the
/// tile writes over it.
struct ChatPreview: Equatable, Sendable {
    /// The thumbnail, already cut to fill the tile at its pixel size and never
    /// larger: no full-size picture is kept, and the tile draws it as it is.
    let image: CGImage
    let detail: ChatPreviewDetail?

    /// What it holds decoded, which the cache counts.
    var bytes: Int { image.bytesPerRow * image.height }

    static func == (lhs: ChatPreview, rhs: ChatPreview) -> Bool {
        lhs.image === rhs.image && lhs.detail == rhs.detail
    }
}

/// What a tile writes over its preview.
enum ChatPreviewDetail: Equatable, Sendable {
    /// A PDF's page count.
    case pages(Int)
    /// A video's length, in seconds.
    case length(Double)
    /// A picture that moves, drawn still at its first frame.
    case animated
}

/// What asking for a preview came to.
enum ChatPreviewOutcome: Equatable, Sendable {
    case made(ChatPreviewMade)
    /// A picture past the ceiling, or one whose size ImageIO cannot read:
    /// the tile shows its icon.
    case iconOnly
    /// A video AVFoundation cannot play, which opens outside Fermix.
    case unplayable
    /// It failed or took too long, or the engine could not grant a
    /// phone-side file's bytes for a reason of its own.
    case failed
    /// It was let go before it ended: its tile left the screen, or the queue
    /// was full and it was the oldest waiting. The next appearance asks
    /// again, and it does not count as a try.
    case dropped
    /// The engine no longer has a phone-side file's bytes: Not available.
    case missing

    /// Whether this is the tile's last answer. One that failed or was let go
    /// is asked for again the next time its tile appears, and the previews
    /// decide whether it has a try left (`ChatPreviewBudget.tries`).
    var isFinal: Bool {
        switch self {
        case .made, .iconOnly, .unplayable, .missing: return true
        case .failed, .dropped: return false
        }
    }
}

/// A picture's size and motion, read from its properties without decoding it.
public struct ChatPictureFacts: Equatable, Sendable {
    public let pixels: Int
    public let animated: Bool

    public init(pixels: Int, animated: Bool) {
        self.pixels = pixels
        self.animated = animated
    }

    /// The facts from a picture's own header, which the file writes and so may
    /// claim anything. A size whose area overflows, or a side that is not
    /// positive, counts as past every ceiling: the tile shows its icon, and
    /// nothing traps on the multiplication.
    public init(width: Int, height: Int, animated: Bool) {
        let area = width.multipliedReportingOverflow(by: height)
        let sane = width > 0 && height > 0 && !area.overflow

        self.init(pixels: sane ? area.partialValue : .max, animated: animated)
    }
}

/// The budgets previews are made within (M66 §3.7): starting numbers, to be
/// checked by the profile.
enum ChatPreviewBudget {
    /// Jobs at once.
    static let jobs = 2
    /// Jobs waiting to start; past this the oldest is let go.
    static let waiting = 64
    /// How long one job may take before it counts as failed.
    static let timeout: TimeInterval = 10
    /// The decoded previews the app keeps, least recently used let go first.
    /// It is not a cap on the process, nor on Quick Look's own cache.
    static let cacheBytes = 32 * 1024 * 1024
    /// The largest picture a preview is made of. A larger one shows its icon.
    static let pixels = 100_000_000
    /// How many times one preview is tried: once, and once more the next time
    /// its tile appears.
    static let tries = 2
}

/// What a preview is kept by: what its content is known by, and what was
/// made of it, a picture at a pixel size and scale, a sound's levels in so
/// many stretches (M66 §3.7), or a map at a pixel size, scale and appearance
/// (M72 §7.2).
struct ChatPreviewKey: Hashable, Sendable {
    /// A file's identity, modification date and size, so an edited or
    /// replaced file is a new key and a stale result can never be shown for
    /// it; or a phone-side file's ref, which names its content and never
    /// changes, so a fresh copy of the same file is no new work; or a map's
    /// places, by their coordinates alone, which are all a map draws.
    enum Content: Hashable, Sendable {
        case file(ChatFileIdentity, modified: Date, size: Int)
        case ref(String)
        case places([CompanionPlaceLocation])
    }

    enum Form: Hashable, Sendable {
        case picture(pixelWidth: Int, pixelHeight: Int, scale: Double)
        case levels(buckets: Int)
        case map(pixelWidth: Int, pixelHeight: Int, scale: Double, appearance: PlaceMapAppearance)
    }

    let content: Content
    let form: Form

    /// A picture of `size` points at `scale`.
    init(_ content: Content, size: CGSize, scale: Double) {
        let pixels = Self.pixels(of: size, scale: scale)
        self.content = content
        form = .picture(pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height), scale: scale)
    }

    /// A sound's levels in `buckets` stretches.
    init(_ content: Content, buckets: Int) {
        self.content = content
        form = .levels(buckets: buckets)
    }

    /// A map of `places` at `size` points and `scale`, in one appearance.
    init(places: [CompanionPlaceLocation], size: CGSize, scale: Double, appearance: PlaceMapAppearance) {
        let pixels = Self.pixels(of: size, scale: scale)
        content = .places(places)
        form = .map(pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height), scale: scale, appearance: appearance)
    }

    /// A tile's own pixels: its points at the screen's scale, whole.
    static func pixels(of size: CGSize, scale: Double) -> CGSize {
        CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// What a preview is made from: a file a path names, where it really lands,
/// or a phone-side file, by its ref, whose file the engine grants only while
/// the preview is made (M66 decision 1).
enum ChatPreviewSource: Sendable {
    case file(URL)
    case ref(String)
}

/// One preview to make: a tile's file, at its size.
struct ChatPreviewRequest: Sendable {
    let source: ChatPreviewSource
    let family: ChatFileFamily
    /// The tile, in points, and the screen's scale.
    let size: CGSize
    let scale: Double
    let key: ChatPreviewKey

    /// What Quick Look is asked for: a square twice the tile's width. Its
    /// thumbnail fits inside, so this is the box that comes back large enough
    /// to fill a 3:2 tile for a page up to twice as tall as it is wide and a
    /// picture up to three times as wide as it is tall; past that, it is
    /// enlarged a little to fill.
    var box: CGSize {
        CGSize(width: size.width * 2, height: size.width * 2)
    }

    /// The tile's own pixels, which the preview is cut to.
    var pixels: CGSize {
        ChatPreviewKey.pixels(of: size, scale: scale)
    }

    /// Where the preview is held as it is cut: a page by its head, which is
    /// where its title is, and anything else by its middle.
    var anchor: ChatPreviewCover.Anchor {
        family == .pdf || family == .document ? .top : .center
    }

    /// A file's preview, read where it really lands.
    init(_ facts: ChatFileFacts, size: CGSize, scale: Double) {
        self.init(
            source: .file(facts.file),
            family: ChatPreviewPolicy.family(of: facts),
            size: size,
            scale: scale,
            content: .file(facts.identity, modified: facts.modified, size: facts.size)
        )
    }

    /// A phone-side file's preview, of the type its row names.
    init(_ ref: CompanionMediaRef, size: CGSize, scale: Double) {
        self.init(ref: ref.ref, family: ChatPreviewPolicy.family(of: ChatPreviewPolicy.type(of: ref)), size: size, scale: scale)
    }

    /// The preview of a phone-side file of `family`, by its ref alone: a
    /// stored link preview's picture has no row of its own to say more.
    init(ref: String, family: ChatFileFamily, size: CGSize, scale: Double) {
        self.init(source: .ref(ref), family: family, size: size, scale: scale, content: .ref(ref))
    }

    private init(source: ChatPreviewSource, family: ChatFileFamily, size: CGSize, scale: Double, content: ChatPreviewKey.Content) {
        self.source = source
        self.family = family
        self.size = size
        self.scale = scale
        key = ChatPreviewKey(content, size: size, scale: scale)
    }
}

/// One sound's levels to read, for its waveform (M66 §3.4): a sound file's
/// in the Fermix home, kept as a file's preview is, or a voice note's, by its
/// ref, whose file the engine grants only while they are read. Always in
/// `SoundLevels.buckets` stretches, which the waveform merges to its bars.
struct ChatLevelsRequest: Sendable {
    let source: ChatPreviewSource
    let key: ChatPreviewKey

    /// A sound file's levels, read where it really lands.
    init(_ facts: ChatFileFacts) {
        source = .file(facts.file)
        key = ChatPreviewKey(.file(facts.identity, modified: facts.modified, size: facts.size), buckets: SoundLevels.buckets)
    }

    /// A voice note's levels, by its ref.
    init(_ note: CompanionMediaRef) {
        source = .ref(note.ref)
        key = ChatPreviewKey(.ref(note.ref), buckets: SoundLevels.buckets)
    }
}

/// One map to draw (M72 §7.2): a reply's places, at its map's size and the
/// screen's scale, in the light or the dark map, over the area that fits them
/// with room for their pins.
struct ChatMapRequest: Sendable {
    let places: [CompanionPlaceLocation]
    let size: CGSize
    let scale: Double
    let appearance: PlaceMapAppearance
    let key: ChatPreviewKey

    init(places: [CompanionPlaceLocation], size: CGSize, scale: Double, appearance: PlaceMapAppearance) {
        self.places = places
        self.size = size
        self.scale = scale
        self.appearance = appearance
        key = ChatPreviewKey(places: places, size: size, scale: scale, appearance: appearance)
    }

    var area: PlaceMapArea {
        PlaceMapArea.fitting(places, in: size, padding: ChatMetrics.placeMapPadding)
    }

    /// The map's own pixels, which the picture is cut to.
    var pixels: CGSize {
        ChatPreviewKey.pixels(of: size, scale: scale)
    }
}

/// What the Mac's own frameworks draw of a file a tile names: its
/// thumbnail, a picture's size and motion, and a PDF's page count, from Quick
/// Look, ImageIO and PDF; and, as the `PlaceMaps`, a map of a reply's places
/// and a place opened in Maps, from MapKit. Behind a protocol, so the budgets
/// are provable with a fake and no test opens a file, and because Quick
/// Look's thumbnails and MapKit's maps are GUI-only: the reader is
/// `FermixViewers`'s `SystemMediaReader`, which `main.swift` hands in.
/// Whether a film plays and how long it is are AVFoundation's, asked of the
/// one owner of both (`MediaFacts`).
public protocol ChatMediaReading: PlaceMaps {
    /// A picture's pixel count and whether it moves, from its properties
    /// alone, or nil where ImageIO cannot read them.
    func picture(at file: URL) -> ChatPictureFacts?
    /// The file's thumbnail at `size` points and `scale`, never its icon. It
    /// stops when the task asking for it is cancelled.
    func thumbnail(of file: URL, size: CGSize, scale: Double) async throws -> CGImage
    func pageCount(of file: URL) async -> Int?
}

/// Makes a tile's preview, a sound's levels for its waveform, and a map of a
/// reply's places, within the budgets (M66 §3.7): each is a preview of what
/// it shows, and shares every rule below.
///
/// At most two jobs run at once and at most 64 wait, the oldest let go past
/// that; two tiles asking for one preview share one job; a tile that leaves
/// the screen cancels its ask, and a job nobody waits on any more is
/// cancelled; a job that takes longer than ten seconds counts as failed; and
/// what is made is kept in a cache of decoded bytes. A job's work runs off the
/// main thread; its bookkeeping is on it.
///
/// A phone-side file's job holds the file the engine grants for its ref from
/// the moment it starts until it ends, whatever it comes to, and at no other
/// time (M66 decision 1): never while it waits, never for a preview already
/// kept, and never for a tile that left the screen, whose job is let go. Its
/// preview then lives in the cache, so a history scrolled through holds
/// nothing once its previews are made.
@MainActor
final class ChatPreviews {
    private let reader: any ChatMediaReading
    private let facts: any MediaFacts
    private let levels: any SoundLevelReading
    private let grants: any MediaGranting
    private let deadlines: any DeadlineScheduling
    private var cache: ChatPreviewCache
    private var jobs: [ChatPreviewKey: Job] = [:]
    /// Jobs not started, oldest first.
    private var waiting: [ChatPreviewKey] = []
    private var running: Set<ChatPreviewKey> = []
    private var failures: [ChatPreviewKey: Int] = [:]
    private var nextWaiter = 0

    /// What one job makes: a tile's picture, a sound's levels or a map.
    private enum Ask: Sendable {
        case picture(ChatPreviewRequest)
        case levels(ChatLevelsRequest)
        case map(ChatMapRequest)

        var key: ChatPreviewKey {
            switch self {
            case .picture(let request): return request.key
            case .levels(let request): return request.key
            case .map(let request): return request.key
            }
        }
    }

    private final class Job {
        let ask: Ask
        var waiters: [Int: CheckedContinuation<ChatPreviewOutcome, Never>] = [:]
        var work: Task<Void, Never>?
        var deadline: DeadlineToken?

        init(_ ask: Ask) {
            self.ask = ask
        }
    }

    init(
        reader: any ChatMediaReading,
        facts: any MediaFacts,
        levels: any SoundLevelReading,
        grants: any MediaGranting,
        deadlines: any DeadlineScheduling,
        cacheBytes: Int = ChatPreviewBudget.cacheBytes
    ) {
        self.reader = reader
        self.facts = facts
        self.levels = levels
        self.grants = grants
        self.deadlines = deadlines
        cache = ChatPreviewCache(capacity: cacheBytes)
    }

    /// Jobs running and waiting, for the budgets' proof.
    var runningCount: Int { running.count }
    var waitingCount: Int { waiting.count }
    var cachedBytes: Int { cache.bytes }

    /// The preview a tile asks for: from the cache, or made by a job it
    /// shares with any other tile asking for the same. A preview that has
    /// failed its tries is not asked for again. Cancelling the asking task
    /// leaves the job, and it answers `.dropped`.
    func preview(_ request: ChatPreviewRequest) async -> ChatPreviewOutcome {
        await ask(.picture(request))
    }

    /// A sound's levels, which its waveform asks for while it is on screen,
    /// as a tile asks for its preview, and under the same rules.
    func levels(_ request: ChatLevelsRequest) async -> ChatPreviewOutcome {
        await ask(.levels(request))
    }

    /// A map of a reply's places, which its block asks for while it is on
    /// screen, and under the same rules.
    func map(_ request: ChatMapRequest) async -> ChatPreviewOutcome {
        await ask(.map(request))
    }

    private func ask(_ ask: Ask) async -> ChatPreviewOutcome {
        let key = ask.key
        if let cached = cache.made(for: key) { return .made(cached) }
        guard failures[key, default: 0] < ChatPreviewBudget.tries else { return .failed }

        let waiter = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                join(ask, waiter: waiter, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.leave(key, waiter: waiter) }
        }
    }

    private func join(_ ask: Ask, waiter: Int, _ continuation: CheckedContinuation<ChatPreviewOutcome, Never>) {
        if let job = jobs[ask.key] {
            job.waiters[waiter] = continuation
            return
        }

        let job = Job(ask)
        job.waiters[waiter] = continuation
        jobs[ask.key] = job
        waiting.append(ask.key)
        if waiting.count > ChatPreviewBudget.waiting, let oldest = waiting.first {
            drop(oldest)
        }
        startWaiting()
    }

    /// A tile stopped asking. A job nobody waits on any more stops too.
    private func leave(_ key: ChatPreviewKey, waiter: Int) {
        guard let job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else { return }

        continuation.resume(returning: .dropped)
        if job.waiters.isEmpty { drop(key) }
    }

    /// Lets a job go before it ends, whether it waits or runs, answering
    /// whoever still waits on it.
    private func drop(_ key: ChatPreviewKey) {
        guard let job = jobs.removeValue(forKey: key) else { return }

        waiting.removeAll { $0 == key }
        running.remove(key)
        job.deadline?.cancel()
        job.work?.cancel()
        for continuation in job.waiters.values {
            continuation.resume(returning: .dropped)
        }
        startWaiting()
    }

    private func startWaiting() {
        while running.count < ChatPreviewBudget.jobs, !waiting.isEmpty {
            let key = waiting.removeFirst()
            guard let job = jobs[key] else { continue }

            start(job)
        }
    }

    private func start(_ job: Job) {
        running.insert(job.ask.key)
        job.work = Task { [ask = job.ask] in
            let outcome = await self.work(ask) { self.timeOut(job) }
            self.finish(job, outcome)
        }
    }

    /// The time a preview has (§3.3) runs from when its bytes are in hand: a
    /// file's at once, a phone-side file's once the engine has granted it. A
    /// grant that waits out a reconnect is no failure of the preview, and
    /// uses none of its tries.
    private func timeOut(_ job: Job) {
        guard jobs[job.ask.key] === job else { return }

        job.deadline = deadlines.schedule(after: ChatPreviewBudget.timeout) { [weak self] in
            self?.finish(job, .failed)
        }
    }

    /// One job's work: a file's preview or levels on its file (`onFile`),
    /// and a map at once, drawn from its places alone. `inHand` starts the
    /// job's clock.
    private func work(_ ask: Ask, inHand: () -> Void) async -> ChatPreviewOutcome {
        switch ask {
        case .picture(let request):
            return await onFile(request.source, inHand: inHand) { file in
                await Self.make(request, from: file, with: reader, facts: facts)
            }
        case .levels(let request):
            return await onFile(request.source, inHand: inHand) { file in
                await Self.levels(request, from: file, with: levels)
            }
        case .map(let request):
            inHand()
            return await Self.map(request, with: reader)
        }
    }

    /// Work on a file: at once, and on a phone-side file's once the engine
    /// has granted it, the grant let go as the work ends, however it ends. A
    /// job let go while it waited for the grant is dropped.
    private func onFile(
        _ source: ChatPreviewSource,
        inHand: () -> Void,
        make: (URL) async -> ChatPreviewOutcome
    ) async -> ChatPreviewOutcome {
        switch source {
        case .file(let file):
            inHand()
            return await make(file)
        case .ref(let ref):
            let grant = await grants.hold(ref)
            defer { grants.release(ref) }

            switch grant {
            case .granted(let granted):
                inHand()
                return await make(granted.url)
            case .missing: return .missing
            case .failed: return Task.isCancelled ? .dropped : .failed
            }
        }
    }

    /// A job ended. A result for a job already let go, or already timed out,
    /// is dropped: its tile is no longer waiting for it.
    private func finish(_ job: Job, _ outcome: ChatPreviewOutcome) {
        let key = job.ask.key
        guard jobs[key] === job else { return }

        jobs[key] = nil
        running.remove(key)
        job.deadline?.cancel()
        job.work?.cancel()
        switch outcome {
        case .made(let made): cache.insert(made, for: key)
        case .failed: failures[key, default: 0] += 1
        case .iconOnly, .unplayable, .dropped, .missing: break
        }
        for continuation in job.waiters.values {
            continuation.resume(returning: outcome)
        }
        startWaiting()
    }

    /// A preview of `file`, off the main thread. A picture's size is read
    /// before anything decodes it; a video is asked whether it plays and how
    /// long it is, and a PDF how many pages it has, beside its thumbnail.
    nonisolated static func make(
        _ request: ChatPreviewRequest,
        from file: URL,
        with reader: any ChatMediaReading,
        facts: any MediaFacts
    ) async -> ChatPreviewOutcome {
        var detail: ChatPreviewDetail?
        switch request.family {
        case .picture:
            guard let picture = reader.picture(at: file), picture.pixels <= ChatPreviewBudget.pixels else { return .iconOnly }
            detail = picture.animated ? .animated : nil
        case .video:
            guard await facts.isPlayable(file) else { return .unplayable }
            detail = await facts.length(of: file).map(ChatPreviewDetail.length)
        case .pdf:
            detail = await reader.pageCount(of: file).map(ChatPreviewDetail.pages)
        case .document, .sound, .page, .text, .data, .other:
            break
        }

        let thumbnail: CGImage
        do {
            thumbnail = try await reader.thumbnail(of: file, size: request.box, scale: request.scale)
        } catch {
            return Task.isCancelled ? .dropped : .failed
        }
        guard let image = ChatPreviewCover.image(thumbnail, filling: request.pixels, anchor: request.anchor) else { return .failed }

        return .made(.picture(ChatPreview(image: image, detail: detail)))
    }

    /// A map of a reply's places, off the main thread, cut to its pixels as
    /// a thumbnail is. The area keeps the map's proportion, so the cut only
    /// scales it, and every place stays where the area's projection puts it.
    nonisolated static func map(_ request: ChatMapRequest, with maps: any PlaceMaps) async -> ChatPreviewOutcome {
        let drawn: CGImage
        do {
            drawn = try await maps.map(of: request.area, size: request.size, appearance: request.appearance)
        } catch {
            return Task.isCancelled ? .dropped : .failed
        }
        guard let image = ChatPreviewCover.image(drawn, filling: request.pixels, anchor: .center) else { return .failed }

        return .made(.map(PlaceMapPicture(image: image)))
    }

    /// A sound's levels, read off the main thread. One AVFoundation cannot
    /// decode failed, and leaves its waveform's resting bars.
    nonisolated static func levels(
        _ request: ChatLevelsRequest,
        from file: URL,
        with reader: any SoundLevelReading
    ) async -> ChatPreviewOutcome {
        guard case .levels(let buckets) = request.key.form,
              let levels = await reader.levels(of: file, buckets: buckets)
        else { return Task.isCancelled ? .dropped : .failed }

        return .made(.levels(levels))
    }
}

/// A thumbnail cut to fill its tile edge to edge: scaled until it covers the
/// tile, what spills over cut away, and drawn once at the tile's pixels, so
/// the cache holds only what is shown.
enum ChatPreviewCover {
    enum Anchor: Sendable {
        /// The head stays: a page's title, a document's first lines.
        case top
        case center
    }

    /// Where a source is drawn, in the target's own coordinates (the origin
    /// at the bottom left, as Core Graphics has it), to cover the target: by
    /// the larger of the two scales, centred across, and held at the top or
    /// the middle.
    static func rect(of source: CGSize, covering target: CGSize, anchor: Anchor) -> CGRect {
        let scale = max(target.width / source.width, target.height / source.height)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        let bottom = anchor == .top ? target.height - drawn.height : (target.height - drawn.height) / 2

        return CGRect(origin: CGPoint(x: (target.width - drawn.width) / 2, y: bottom), size: drawn)
    }

    /// The source cut to fill `pixels`, or nil where no bitmap of that size
    /// can be made.
    static func image(_ source: CGImage, filling pixels: CGSize, anchor: Anchor) -> CGImage? {
        guard pixels.width >= 1, pixels.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(pixels.width),
                  height: Int(pixels.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let size = CGSize(width: source.width, height: source.height)
        context.interpolationQuality = .high
        context.draw(source, in: rect(of: size, covering: pixels, anchor: anchor))
        return context.makeImage()
    }
}

/// The app's own cache of decoded previews, pictures and levels alike,
/// counted in bytes, the least recently used let go first.
struct ChatPreviewCache {
    let capacity: Int
    private(set) var bytes = 0
    private var entries: [ChatPreviewKey: ChatPreviewMade] = [:]
    /// Least recently used first.
    private var order: [ChatPreviewKey] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// The preview kept for a key, which counts as its use.
    mutating func made(for key: ChatPreviewKey) -> ChatPreviewMade? {
        guard let made = entries[key] else { return nil }

        order.removeAll { $0 == key }
        order.append(key)
        return made
    }

    /// Keeps a preview, letting the least recently used go until the cache
    /// fits. One larger than the whole cache is not kept.
    mutating func insert(_ made: ChatPreviewMade, for key: ChatPreviewKey) {
        guard made.bytes <= capacity else { return }

        remove(key)
        entries[key] = made
        order.append(key)
        bytes += made.bytes
        while bytes > capacity, let oldest = order.first {
            remove(oldest)
        }
    }

    private mutating func remove(_ key: ChatPreviewKey) {
        guard let made = entries.removeValue(forKey: key) else { return }

        order.removeAll { $0 == key }
        bytes -= made.bytes
    }
}
