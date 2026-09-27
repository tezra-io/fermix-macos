import FermixAppCore
import Foundation

/// The page as the engine reads and drives it (plan §4.2), on the page script
/// and the trusted input `WebKitPageActions` delivers.
extension WebKitBrowserPage: BrowserPageDriving {
    func snapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        try await WebKitPageSnapshot(script: pageScript()).take(request)
    }

    func act(_ action: BrowserPageAction, observing request: BrowserSnapshotRequest) async throws -> BrowserActOutcome {
        let actions = WebKitPageActions(webView: webView, script: try pageScript()) { [weak self] path in
            self?.pendingUploadPath = path
        }

        return try await actions.perform(action, observing: request)
    }

    private func pageScript() throws -> WebKitPageScript {
        try pageScriptResult.get()
    }
}
