import FermixAppCore
import Foundation
import WebKit

/// One download on WebKit's `WKDownload` (plan §4.4).
///
/// It decides nothing: where the file goes is asked of `events`, which the
/// pane sets as the download is handed over, and what WebKit reports is
/// passed on. Nothing is passed on after a cancel or a refused destination.
///
/// WebKit writes the file at the destination as it arrives, and leaves what
/// it wrote there when a download fails or is cancelled; its network process
/// sets the quarantine attribute on every file it writes.
@MainActor
final class WebKitBrowserDownload: NSObject, BrowserDownload {
    weak var events: (any BrowserDownloadEvents)?

    private let download: WKDownload

    init(_ download: WKDownload) {
        self.download = download
        super.init()

        // Set before this call returns: a download with no delegate when
        // WebKit asks where its file goes is cancelled.
        download.delegate = self
    }

    /// WebKit answers a cancel with what it could resume from, which nothing
    /// here keeps, and reports no failure after it. The download is held
    /// until that answer, so the answer has somewhere to arrive.
    func cancel(_ stopped: @escaping @MainActor () -> Void) {
        events = nil
        download.cancel { [self] _ in
            withExtendedLifetime(self) { stopped() }
        }
    }
}

extension WebKitBrowserDownload: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        guard let events else {
            completionHandler(nil)
            return
        }

        events.download(self, needsDestinationFor: suggestedFilename) { [weak self] destination in
            if destination == nil { self?.events = nil }
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        events?.downloadFinished(self)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        events?.download(self, failed: error.localizedDescription)
    }
}
