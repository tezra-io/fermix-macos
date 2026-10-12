import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A preview made of a file's content at its tile's pixel size, and what the
/// tile writes over it.
struct ChatPreview: Equatable, Sendable {
    /// The thumbnail, decoded at the tile's pixel size and never larger: no
    /// full-size picture is kept.
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
    /// The tile's picture area, in points, and the screen's scale.
    let size: CGSize
    let scale: Double
    let key: ChatPreviewKey

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

/// What the Mac's own frameworks say of a file a tile names: ImageIO, Quick
/// Look, PDF, AVFoundation and Launch Services. Behind a protocol, so the
/// budgets are provable with a fake and no test opens a file, and because
/// Quick Look's thumbnails are GUI-only: the reader is `FermixViewers`'s
/// `SystemMediaReader`, which `main.swift` hands in.
public protocol ChatMediaReading: Sendable {
    /// A picture's pixel count and whether it moves, from its properties
    /// alone, or nil where ImageIO cannot read them.
    func picture(at file: URL) -> ChatPictureFacts?
    /// The file's thumbnail at `size` points and `scale`, never its icon. It
    /// stops when the task asking for it is cancelled.
    func thumbnail(of file: URL, size: CGSize, scale: Double) async throws -> CGImage
    func pageCount(of file: URL) async -> Int?
    /// A video's length, in seconds.
    func length(of file: URL) async -> Double?
    func isPlayable(_ file: URL) async -> Bool
    /// The app a document of `type` opens in, by the name Finder shows, or
    /// nil where none does or the one that would opens web pages, to which
    /// the pane hands no file.
    func application(toOpen type: UTType) -> String?
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

    init(reader: any ChatMediaReading, deadlines: any DeadlineScheduling, cacheBytes: Int = ChatPreviewBudget.cacheBytes) {
        self.reader = reader
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
        job.work = Task { [reader, request = job.request] in
            let outcome = await Self.make(request, with: reader)
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
    nonisolated static func make(_ request: ChatPreviewRequest, with reader: any ChatMediaReading) async -> ChatPreviewOutcome {
        var detail: ChatPreviewDetail?
        switch request.family {
        case .picture:
            guard let picture = reader.picture(at: request.file), picture.pixels <= ChatPreviewBudget.pixels else { return .iconOnly }
            detail = picture.animated ? .animated : nil
        case .video:
            guard await reader.isPlayable(request.file) else { return .unplayable }
            detail = await reader.length(of: request.file).map(ChatPreviewDetail.length)
        case .pdf:
            detail = await reader.pageCount(of: request.file).map(ChatPreviewDetail.pages)
        case .document, .sound, .page, .text, .data, .other:
            break
        }

        do {
            let image = try await reader.thumbnail(of: request.file, size: request.size, scale: request.scale)
            return .made(ChatPreview(image: image, detail: detail))
        } catch {
            return Task.isCancelled ? .dropped : .failed
        }
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

extension ChatFileFacts {
    /// The facts of the file a link names, read where it really lands, or nil
    /// where nothing is there now. It reads the disk, so it is called off the
    /// main thread.
    static func read(_ link: URL, home: URL?) -> ChatFileFacts? {
        guard let real = FilePlace.resolved(link.path) else { return nil }

        let file = URL(fileURLWithPath: real)
        let keys: Set<URLResourceKey> = [
            .contentTypeKey, .isDirectoryKey, .isRegularFileKey, .isExecutableKey, .fileSizeKey, .contentModificationDateKey
        ]
        var status = stat()
        guard let values = try? file.resourceValues(forKeys: keys),
              let type = values.contentType,
              let modified = values.contentModificationDate,
              stat(real, &status) == 0
        else { return nil }

        return ChatFileFacts(
            file: file,
            type: type,
            isDirectory: values.isDirectory == true,
            isExecutable: values.isRegularFile == true && values.isExecutable == true,
            identity: ChatFileIdentity(volume: UInt64(UInt32(bitPattern: status.st_dev)), number: status.st_ino),
            modified: modified,
            size: values.fileSize ?? 0,
            insideHome: home.map { FilePlace.path(real, liesUnder: $0) } ?? false
        )
    }
}

/// Everything a row's media needs that outlives the chat surface, built once
/// by the composition: the Fermix home, each row's strip, the previews and
/// the apps that open a type.
///
/// The home is read from the bootstrap record the first time a row asks for
/// it in a visit to Chat, and read again on the next visit, as the browser
/// reads it at each open: a row drawn before it was read would have to be
/// drawn again once it was. A home that cannot be read has nothing inside it.
@MainActor
final class ChatMedia {
    let previews: ChatPreviews
    /// The app's one player, which a sound in the chat plays through (M66 §3.4).
    let player: AppPlayer
    private let readHome: () throws -> URL
    private let reader: any ChatMediaReading
    private var visit: Visit?
    private var strips: [Int: (source: StripSource, strip: ChatStrip)] = [:]
    private var hints: [String: ChatTileHint] = [:]

    /// The home as one visit read it.
    private struct Visit {
        let home: URL?
        let paths: ChatHome?
    }

    /// What a row's strip is worked out from, so it is worked out again only
    /// when that changes: history may bring the same row with more in it.
    private struct StripSource: Equatable {
        let text: String
        let mediaRefs: [CompanionMediaRef]
        let linkPreviews: [CompanionLinkPreview]
        let home: ChatHome?
    }

    /// `home` reads the Fermix home from the bootstrap record, as the
    /// browser's does; `reader` is what the Mac's own frameworks say of a
    /// file, which the executable hands in; `deadlines` times the previews
    /// out.
    init(
        home: @escaping () throws -> URL,
        player: AppPlayer,
        reader: any ChatMediaReading,
        deadlines: any DeadlineScheduling
    ) {
        readHome = home
        self.player = player
        self.reader = reader
        previews = ChatPreviews(reader: reader, deadlines: deadlines)
    }

    /// The row's strip, worked out once for its content.
    func strip(for row: CompanionRow) -> ChatStrip {
        let source = StripSource(text: row.text, mediaRefs: row.mediaRefs, linkPreviews: row.linkPreviews, home: currentVisit().paths)
        if let kept = strips[row.serverSeq], kept.source == source { return kept.strip }

        let strip = ChatStrip(
            text: row.text,
            mediaRefs: row.mediaRefs,
            linkPreviews: row.linkPreviews,
            userHome: NSHomeDirectory(),
            home: source.home
        )
        strips[row.serverSeq] = (source, strip)
        return strip
    }

    /// What a tile's file is, read off the main thread.
    func lookUp(_ file: URL) async -> ChatFileLookup {
        let home = currentVisit().home
        let facts = await Task.detached(priority: .utility) { ChatFileFacts.read(file, home: home) }.value

        return facts.map(ChatFileLookup.found) ?? .missing
    }

    /// Where an Opens outside tile goes, its app found off the main thread
    /// the first time a tile of its type asks, and kept by type.
    func hint(for facts: ChatFileFacts) async -> ChatTileHint {
        guard ChatPreviewPolicy.handsToApp(facts) else { return .showInFinder }
        if let known = hints[facts.type.identifier] { return known }

        let reader = reader
        let type = facts.type
        let hint = await Task.detached(priority: .utility) { reader.application(toOpen: type).map(ChatTileHint.openIn) ?? .showInFinder }.value
        hints[type.identifier] = hint
        return hint
    }

    /// The chat surface went: the next visit reads the home again.
    func surfaceLeft() {
        visit = nil
    }

    /// The home as this visit read it, reading it the first time.
    private func currentVisit() -> Visit {
        if let visit { return visit }

        let home = try? readHome()
        let read = Visit(home: home, paths: home.map(ChatHome.init))
        visit = read
        return read
    }
}
