import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@testable import FermixAppCore

/// The Mac's frameworks as a tile's previews meet them, played by hand: what
/// ImageIO, PDF and AVFoundation say of each file is set up front, and each
/// thumbnail either comes at once or waits until the case finishes or fails
/// it. No file is read and Quick Look is never asked.
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
    private let lengths: [URL: Double]
    private let unplayable: Set<URL>
    private let apps: [String: String]
    /// Whether a cancelled thumbnail stops; false plays a renderer that
    /// finishes its work whatever it is told.
    private let stopsWhenCancelled: Bool

    private let lock = NSLock()
    private var waiting: [(id: UUID, file: URL, continuation: CheckedContinuation<CGImage, Error>)] = []
    private var cancelledEarly: Set<UUID> = []
    private var asked: [URL] = []
    private var cancelled = 0
    private var lookups: [UTType] = []

    init(
        thumbnails: Thumbnails = .held,
        pictures: [URL: ChatPictureFacts] = [:],
        pages: [URL: Int] = [:],
        lengths: [URL: Double] = [:],
        unplayable: Set<URL> = [],
        apps: [String: String] = [:],
        stopsWhenCancelled: Bool = true
    ) {
        self.thumbnails = thumbnails
        self.pictures = pictures
        self.pages = pages
        self.lengths = lengths
        self.unplayable = unplayable
        self.apps = apps
        self.stopsWhenCancelled = stopsWhenCancelled
    }

    /// Every file a thumbnail was asked of, in order.
    var thumbnailsAsked: [URL] { lock.withLock { asked } }
    /// Thumbnails stopped by their task's cancellation.
    var thumbnailsCancelled: Int { lock.withLock { cancelled } }
    /// Every type an app was looked up for.
    var appLookups: [UTType] { lock.withLock { lookups } }

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

    func length(of file: URL) async -> Double? {
        lengths[file]
    }

    func isPlayable(_ file: URL) async -> Bool {
        !unplayable.contains(file)
    }

    func application(toOpen type: UTType) -> String? {
        lock.withLock { lookups.append(type) }
        return apps[type.identifier]
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

    /// A picture of a known size, made in memory.
    static func image(width: Int = 4, height: Int = 4) -> CGImage {
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
            type: type ?? ChatPreviewPolicy.type(ofPath: path) ?? .data,
            isDirectory: isDirectory,
            isExecutable: isExecutable,
            identity: ChatFileIdentity(volume: 1, number: number),
            modified: Date(timeIntervalSince1970: 1_000),
            size: size,
            insideHome: insideHome
        )
    }
}
