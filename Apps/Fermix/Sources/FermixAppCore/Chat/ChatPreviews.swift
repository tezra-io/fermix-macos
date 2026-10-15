import CoreGraphics
import Foundation
import UniformTypeIdentifiers

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
    case made(ChatPreview)
    /// A picture past the ceiling, or one whose size ImageIO cannot read:
    /// the tile shows its icon.
    case iconOnly
    /// A video AVFoundation cannot play, which opens outside Fermix.
    case unplayable
    /// It failed or took too long.
    case failed
    /// It was let go before it ended: its tile left the screen, or the queue
    /// was full and it was the oldest waiting. The next appearance asks
    /// again, and it does not count as a try.
    case dropped

    /// Whether this is the tile's last answer. One that failed or was let go
    /// is asked for again the next time its tile appears, and the previews
    /// decide whether it has a try left (`ChatPreviewBudget.tries`).
    var isFinal: Bool {
        switch self {
        case .made, .iconOnly, .unplayable: return true
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

/// What a preview is kept by: the file's identity, modification date and
/// size, so an edited or replaced file is a new key and a stale result can
/// never be shown for it, and the pixel size and scale it was made at.
struct ChatPreviewKey: Hashable, Sendable {
    let identity: ChatFileIdentity
    let modified: Date
    let size: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
}

/// One preview to make: a tile's file, at its size.
struct ChatPreviewRequest: Sendable {
    let file: URL
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
        CGSize(width: key.pixelWidth, height: key.pixelHeight)
    }

    /// Where the preview is held as it is cut: a page by its head, which is
    /// where its title is, and anything else by its middle.
    var anchor: ChatPreviewCover.Anchor {
        family == .pdf || family == .document ? .top : .center
    }

    init(_ facts: ChatFileFacts, size: CGSize, scale: Double) {
        file = facts.file
        family = ChatPreviewPolicy.family(of: facts)
        self.size = size
        self.scale = scale
        key = ChatPreviewKey(
            identity: facts.identity,
            modified: facts.modified,
            size: facts.size,
            pixelWidth: Int((size.width * scale).rounded()),
            pixelHeight: Int((size.height * scale).rounded()),
            scale: scale
        )
    }
}

/// What the Mac's own frameworks draw of a file a tile names: its
/// thumbnail, a picture's size and motion, and a PDF's page count, from Quick
/// Look, ImageIO and PDF. Behind a protocol, so the budgets are provable with
/// a fake and no test opens a file, and because Quick Look's thumbnails are
/// GUI-only: the reader is `FermixViewers`'s `SystemMediaReader`, which
/// `main.swift` hands in. Whether a film plays and how long it is are
/// AVFoundation's, asked of the one owner of both (`MediaFacts`).
public protocol ChatMediaReading: Sendable {
    /// A picture's pixel count and whether it moves, from its properties
    /// alone, or nil where ImageIO cannot read them.
    func picture(at file: URL) -> ChatPictureFacts?
    /// The file's thumbnail at `size` points and `scale`, never its icon. It
    /// stops when the task asking for it is cancelled.
    func thumbnail(of file: URL, size: CGSize, scale: Double) async throws -> CGImage
    func pageCount(of file: URL) async -> Int?
}

/// Makes a tile's preview within the budgets (M66 §3.7).
///
/// At most two jobs run at once and at most 64 wait, the oldest let go past
/// that; two tiles asking for one preview share one job; a tile that leaves
/// the screen cancels its ask, and a job nobody waits on any more is
/// cancelled; a job that takes longer than ten seconds counts as failed; and
/// what is made is kept in a cache of decoded bytes. A job's work runs off the
/// main thread; its bookkeeping is on it.
@MainActor
final class ChatPreviews {
    private let reader: any ChatMediaReading
    private let facts: any MediaFacts
    private let deadlines: any DeadlineScheduling
    private var cache: ChatPreviewCache
    private var jobs: [ChatPreviewKey: Job] = [:]
    /// Jobs not started, oldest first.
    private var waiting: [ChatPreviewKey] = []
    private var running: Set<ChatPreviewKey> = []
    private var failures: [ChatPreviewKey: Int] = [:]
    private var nextWaiter = 0

    private final class Job {
        let request: ChatPreviewRequest
        var waiters: [Int: CheckedContinuation<ChatPreviewOutcome, Never>] = [:]
        var work: Task<Void, Never>?
        var deadline: DeadlineToken?

        init(_ request: ChatPreviewRequest) {
            self.request = request
        }
    }

    init(
        reader: any ChatMediaReading,
        facts: any MediaFacts,
        deadlines: any DeadlineScheduling,
        cacheBytes: Int = ChatPreviewBudget.cacheBytes
    ) {
        self.reader = reader
        self.facts = facts
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
        if let cached = cache.preview(for: request.key) { return .made(cached) }
        guard failures[request.key, default: 0] < ChatPreviewBudget.tries else { return .failed }

        let waiter = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                join(request, waiter: waiter, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.leave(request.key, waiter: waiter) }
        }
    }

    private func join(_ request: ChatPreviewRequest, waiter: Int, _ continuation: CheckedContinuation<ChatPreviewOutcome, Never>) {
        if let job = jobs[request.key] {
            job.waiters[waiter] = continuation
            return
        }

        let job = Job(request)
        job.waiters[waiter] = continuation
        jobs[request.key] = job
        waiting.append(request.key)
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
        let key = job.request.key
        running.insert(key)
        job.deadline = deadlines.schedule(after: ChatPreviewBudget.timeout) { [weak self] in
            self?.finish(job, .failed)
        }
        job.work = Task { [reader, facts, request = job.request] in
            let outcome = await Self.make(request, with: reader, facts: facts)
            self.finish(job, outcome)
        }
    }

    /// A job ended. A result for a job already let go, or already timed out,
    /// is dropped: its tile is no longer waiting for it.
    private func finish(_ job: Job, _ outcome: ChatPreviewOutcome) {
        let key = job.request.key
        guard jobs[key] === job else { return }

        jobs[key] = nil
        running.remove(key)
        job.deadline?.cancel()
        job.work?.cancel()
        switch outcome {
        case .made(let preview): cache.insert(preview, for: key)
        case .failed: failures[key, default: 0] += 1
        case .iconOnly, .unplayable, .dropped: break
        }
        for continuation in job.waiters.values {
            continuation.resume(returning: outcome)
        }
        startWaiting()
    }

    /// One job's work, off the main thread. A picture's size is read before
    /// anything decodes it; a video is asked whether it plays and how long it
    /// is, and a PDF how many pages it has, beside its thumbnail.
    nonisolated static func make(
        _ request: ChatPreviewRequest,
        with reader: any ChatMediaReading,
        facts: any MediaFacts
    ) async -> ChatPreviewOutcome {
        var detail: ChatPreviewDetail?
        switch request.family {
        case .picture:
            guard let picture = reader.picture(at: request.file), picture.pixels <= ChatPreviewBudget.pixels else { return .iconOnly }
            detail = picture.animated ? .animated : nil
        case .video:
            guard await facts.isPlayable(request.file) else { return .unplayable }
            detail = await facts.length(of: request.file).map(ChatPreviewDetail.length)
        case .pdf:
            detail = await reader.pageCount(of: request.file).map(ChatPreviewDetail.pages)
        case .document, .sound, .page, .text, .data, .other:
            break
        }

        let thumbnail: CGImage
        do {
            thumbnail = try await reader.thumbnail(of: request.file, size: request.box, scale: request.scale)
        } catch {
            return Task.isCancelled ? .dropped : .failed
        }
        guard let image = ChatPreviewCover.image(thumbnail, filling: request.pixels, anchor: request.anchor) else { return .failed }

        return .made(ChatPreview(image: image, detail: detail))
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

/// The app's own cache of decoded previews, counted in bytes, the least
/// recently used let go first.
struct ChatPreviewCache {
    let capacity: Int
    private(set) var bytes = 0
    private var entries: [ChatPreviewKey: ChatPreview] = [:]
    /// Least recently used first.
    private var order: [ChatPreviewKey] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// The preview kept for a key, which counts as its use.
    mutating func preview(for key: ChatPreviewKey) -> ChatPreview? {
        guard let preview = entries[key] else { return nil }

        order.removeAll { $0 == key }
        order.append(key)
        return preview
    }

    /// Keeps a preview, letting the least recently used go until the cache
    /// fits. One larger than the whole cache is not kept.
    mutating func insert(_ preview: ChatPreview, for key: ChatPreviewKey) {
        guard preview.bytes <= capacity else { return }

        remove(key)
        entries[key] = preview
        order.append(key)
        bytes += preview.bytes
        while bytes > capacity, let oldest = order.first {
            remove(oldest)
        }
    }

    private mutating func remove(_ key: ChatPreviewKey) {
        guard let preview = entries.removeValue(forKey: key) else { return }

        order.removeAll { $0 == key }
        bytes -= preview.bytes
    }
}
