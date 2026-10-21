import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@testable import FermixAppCore

/// The Mac's frameworks as a tile's previews meet them, played by hand: what
/// ImageIO and PDF say of each file is set up front, and each thumbnail
/// either comes at once or waits until the case finishes or fails it. A map
/// comes at once as the case's picture, or fails where the case gave none. No file is read,
/// and neither Quick Look nor MapKit is asked. A place opened by its
/// identifier is recorded, and found or not as the case says, and Maps never
/// opens; a live map is one that shows a place or not as the case says, and
/// draws nothing. What AVFoundation says is `FakeMediaFacts`'s.
final class FakeMediaReader: ChatMediaReading, @unchecked Sendable {
    /// How a thumbnail comes.
    enum Thumbnails {
        /// At once, this picture.
        case immediate(CGImage)
        /// When the case says, through `finish` or `fail`.
        case held
    }

    private let thumbnails: Thumbnails
    private let pictures: [URL: ChatPictureFacts]
    private let pages: [URL: Int]
    /// Whether a cancelled thumbnail stops; false plays a renderer that
    /// finishes its work whatever it is told.
    private let stopsWhenCancelled: Bool
    private let mapPicture: CGImage?
    /// Whether Maps finds a place by its identifier, for its card and for
    /// Maps alike.
    private let findsPlaces: Bool

    private let lock = NSLock()
    private var waiting: [(id: UUID, file: URL, continuation: CheckedContinuation<CGImage, Error>)] = []
    private var cancelledEarly: Set<UUID> = []
    private var asked: [URL] = []
    private var cancelled = 0
    private var mapped: [MapAsk] = []
    private var placed: [String] = []

    /// One map asked for.
    struct MapAsk: Equatable {
        let area: PlaceMapArea
        let size: CGSize
        let appearance: PlaceMapAppearance
    }

    init(
        thumbnails: Thumbnails = .held,
        pictures: [URL: ChatPictureFacts] = [:],
        pages: [URL: Int] = [:],
        stopsWhenCancelled: Bool = true,
        map: CGImage? = nil,
        findsPlaces: Bool = true
    ) {
        self.thumbnails = thumbnails
        self.pictures = pictures
        self.pages = pages
        self.stopsWhenCancelled = stopsWhenCancelled
        mapPicture = map
        self.findsPlaces = findsPlaces
    }

    /// Every file a thumbnail was asked of, in order.
    var thumbnailsAsked: [URL] { lock.withLock { asked } }
    /// Thumbnails stopped by their task's cancellation.
    var thumbnailsCancelled: Int { lock.withLock { cancelled } }

    func picture(at file: URL) -> ChatPictureFacts? {
        pictures[file]
    }

    func thumbnail(of file: URL, size: CGSize, scale: Double) async throws -> CGImage {
        lock.withLock { asked.append(file) }
        if case .immediate(let image) = thumbnails { return image }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = lock.withLock {
                    guard !cancelledEarly.contains(id) else { return true }

                    waiting.append((id, file, continuation))
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            guard stopsWhenCancelled else { return }

            resume(id) { $0.resume(throwing: CancellationError()) }
        }
    }

    /// The first held thumbnail of `file`, made.
    func finish(_ file: URL, with image: CGImage) {
        resumeFirst(of: file) { $0.resume(returning: image) }
    }

    /// The first held thumbnail of `file`, failed.
    func fail(_ file: URL) {
        resumeFirst(of: file) { $0.resume(throwing: CocoaError(.fileReadCorruptFile)) }
    }

    func pageCount(of file: URL) async -> Int? {
        pages[file]
    }

    /// Every map asked for, in order.
    var mapsAsked: [MapAsk] { lock.withLock { mapped } }

    func map(of area: PlaceMapArea, size: CGSize, appearance: PlaceMapAppearance) async throws -> CGImage {
        lock.withLock { mapped.append(MapAsk(area: area, size: size, appearance: appearance)) }
        guard let mapPicture else { throw CocoaError(.fileReadUnknown) }

        return mapPicture
    }

    @MainActor
    func liveMap(
        of area: PlaceMapArea,
        size: CGSize,
        appearance: PlaceMapAppearance,
        pins: [PlaceMapPin],
        clicked: @escaping @MainActor (Int?) -> Void
    ) -> any PlaceLiveMap {
        FakeLiveMap(findsPlaces: findsPlaces)
    }

    /// Every identifier a place was opened by, in order.
    var placesOpened: [String] { lock.withLock { placed } }

    @MainActor
    func openPlace(_ identifier: String, failed: @escaping @MainActor () -> Void) {
        lock.withLock { placed.append(identifier) }
        if !findsPlaces { failed() }
    }

    private func resume(_ id: UUID, with answer: (CheckedContinuation<CGImage, Error>) -> Void) {
        let found: CheckedContinuation<CGImage, Error>? = lock.withLock {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else {
                cancelledEarly.insert(id)
                return nil
            }
            cancelled += 1
            return waiting.remove(at: index).continuation
        }
        found.map(answer)
    }

    private func resumeFirst(of file: URL, with answer: (CheckedContinuation<CGImage, Error>) -> Void) {
        let found: CheckedContinuation<CGImage, Error>? = lock.withLock {
            guard let index = waiting.firstIndex(where: { $0.file == file }) else { return nil }

            return waiting.remove(at: index).continuation
        }
        found.map(answer)
    }
}

/// AVFoundation's reading of a sound's levels, played by hand: each read
/// either comes at once with what the case set up, or waits until the case
/// finishes it, and one whose task is cancelled stops. No file is read.
final class FakeSoundLevels: SoundLevelReading, @unchecked Sendable {
    /// How a read comes.
    enum Reads {
        /// At once, these levels, or none where nil.
        case immediate(SoundLevels?)
        /// When the case says, through `finish`.
        case held
    }

    private let reads: Reads
    private let lock = NSLock()
    private var waiting: [(id: UUID, file: URL, continuation: CheckedContinuation<SoundLevels?, Never>)] = []
    private var cancelledEarly: Set<UUID> = []
    private var asked: [URL] = []
    private var buckets: [Int] = []
    private var cancelled = 0

    init(_ reads: Reads = .held) {
        self.reads = reads
    }

    /// Every file levels were asked of, in order.
    var levelsAsked: [URL] { lock.withLock { asked } }
    /// The stretches each read was asked for, in order.
    var bucketsAsked: [Int] { lock.withLock { buckets } }
    /// Reads stopped by their task's cancellation.
    var levelsCancelled: Int { lock.withLock { cancelled } }

    func levels(of file: URL, buckets count: Int) async -> SoundLevels? {
        lock.withLock {
            asked.append(file)
            buckets.append(count)
        }
        if case .immediate(let levels) = reads { return levels }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let early = lock.withLock {
                    guard !cancelledEarly.contains(id) else { return true }

                    waiting.append((id, file, continuation))
                    return false
                }
                if early { continuation.resume(returning: nil) }
            }
        } onCancel: {
            let found: CheckedContinuation<SoundLevels?, Never>? = lock.withLock {
                guard let index = waiting.firstIndex(where: { $0.id == id }) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                cancelled += 1
                return waiting.remove(at: index).continuation
            }
            found?.resume(returning: nil)
        }
    }

    /// The first held read of `file`, answered: these levels, or none.
    func finish(_ file: URL, with levels: SoundLevels?) {
        let found: CheckedContinuation<SoundLevels?, Never>? = lock.withLock {
            guard let index = waiting.firstIndex(where: { $0.file == file }) else { return nil }

            return waiting.remove(at: index).continuation
        }
        found?.resume(returning: levels)
    }
}

/// A picture of a known size, made in memory: what a thumbnail or a preview
/// holds, for a case that never reads a file.
func fixturePicture(width: Int = 4, height: Int = 4) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        preconditionFailure("a bitmap context makes a picture")
    }

    return image
}

/// Launch Services' answer to which app opens a document of a type, set up
/// front, with every type it was asked recorded.
final class FakeDocumentApplications: @unchecked Sendable {
    private let apps: [String: String]
    private let lock = NSLock()
    private var asked: [UTType] = []

    /// `apps` names the app for a type, by the type's identifier.
    init(_ apps: [String: String] = [:]) {
        self.apps = apps
    }

    /// Every type an app was looked up for.
    var lookups: [UTType] { lock.withLock { asked } }

    func lookUp(_ type: UTType) -> WorkspaceApplication? {
        lock.withLock { asked.append(type) }

        return apps[type.identifier].map { WorkspaceApplication(url: URL(fileURLWithPath: "/Applications/\($0).app", isDirectory: true), name: $0) }
    }
}

/// The facts a tile would read of a file, made up rather than read.
enum ChatFactsFixture {
    static func facts(
        _ path: String,
        type: UTType? = nil,
        number: UInt64 = 1,
        insideHome: Bool = true,
        isDirectory: Bool = false,
        isExecutable: Bool = false,
        size: Int = 100
    ) -> ChatFileFacts {
        ChatFileFacts(
            file: URL(fileURLWithPath: path),
            disk: FileFacts(
                type: type ?? ChatPreviewPolicy.type(ofPath: path) ?? .data,
                entry: isDirectory ? .folder : .file(size: size, isExecutable: isExecutable)
            ),
            identity: ChatFileIdentity(volume: 1, number: number),
            modified: Date(timeIntervalSince1970: 1_000),
            insideHome: insideHome
        )
    }
}

/// A live map that draws nothing: it shows a place at once where Maps finds
/// places, and fails where it does not.
@MainActor
final class FakeLiveMap: PlaceLiveMap {
    private let findsPlaces: Bool

    init(findsPlaces: Bool) {
        self.findsPlaces = findsPlaces
    }

    let view = NSView()

    func show(_ number: Int, identifier: String) async throws {
        guard findsPlaces else { throw CocoaError(.fileReadUnknown) }
    }

    func putAway() async {}
}
