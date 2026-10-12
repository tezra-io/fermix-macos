import AVFoundation
import AppKit
import FermixAppCore
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The chat's production reader (M66 §3.7): the Mac's own frameworks,
/// nothing bundled.
///
/// The only module that imports QuickLookThumbnailing. `FermixAppCore`
/// declares `ChatMediaReading` and imports it nowhere, because both
/// executables link that library and `FermixAgent` makes no preview; only the
/// `Fermix` executable links this target, and `main.swift` hands the reader
/// in.
public struct SystemMediaReader: ChatMediaReading {
    public init() {}

    public func picture(at file: URL) -> ChatPictureFacts? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        return ChatPictureFacts(width: width, height: height, animated: CGImageSourceGetCount(source) > 1)
    }

    public func thumbnail(of file: URL, size: CGSize, scale: Double) async throws -> CGImage {
        let request = PendingThumbnail(file: file, size: size, scale: scale)
        return try await withTaskCancellationHandler {
            try await request.generate()
        } onCancel: {
            request.cancel()
        }
    }

    public func pageCount(of file: URL) async -> Int? {
        CGPDFDocument(file as CFURL)?.numberOfPages
    }

    public func length(of file: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: file).load(.duration), duration.isNumeric else { return nil }

        return duration.seconds
    }

    public func isPlayable(_ file: URL) async -> Bool {
        (try? await AVURLAsset(url: file).load(.isPlayable)) == true
    }

    /// Asked of Launch Services directly rather than through the pane's
    /// opener, whose answers are the main thread's: this runs off it.
    public func application(toOpen type: UTType) -> String? {
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(toOpen: type), let page = URL(string: "https://example.com/") else { return nil }

        let browsers = workspace.urlsForApplications(toOpen: page).map(\.standardizedFileURL)
        guard !browsers.contains(app.standardizedFileURL) else { return nil }

        return FileManager.default.displayName(atPath: app.path)
    }
}

/// One Quick Look request, which its cancellation reaches from whichever
/// thread the asking task is cancelled on: the generator takes a cancel from
/// any thread, which its request's type does not declare.
private final class PendingThumbnail: @unchecked Sendable {
    private let request: QLThumbnailGenerator.Request

    init(file: URL, size: CGSize, scale: Double) {
        request = QLThumbnailGenerator.Request(fileAt: file, size: size, scale: scale, representationTypes: .thumbnail)
    }

    func generate() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                guard let image = representation?.cgImage else {
                    continuation.resume(throwing: error ?? QLThumbnailError(.generationFailed))
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    func cancel() {
        QLThumbnailGenerator.shared.cancel(request)
    }
}
