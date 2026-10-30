import FermixAppCore
import Foundation

/// The page as the engine reads and drives it (plan §4.2), on the page script
/// and the trusted input `WebKitPageActions` delivers.
extension WebKitBrowserPage: BrowserPageDriving {
    func snapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        try await waitUntilReady()
        return try await WebKitPageSnapshot(script: pageScript()).take(request)
    }

    func act(_ action: BrowserPageAction, observing request: BrowserSnapshotRequest) async throws -> BrowserActOutcome {
        try await pageActions().perform(action, observing: request)
    }

    /// The page's act kinds and its sign-in handlers, on one script.
    func pageActions() throws -> WebKitPageActions {
        WebKitPageActions(
            webView: webView,
            script: try pageScript(),
            expectUpload: { [weak self] path in self?.pendingUploadPath = path },
            waitUntilReady: { [weak self] in try await self?.waitUntilReady() }
        )
    }

    /// Waits for the navigation `webView.isLoading` reports in flight to
    /// finish, bounded by the same timeout every page-script call takes; a
    /// page that is not loading answers at once.
    func waitUntilReady() async throws {
        guard webView.isLoading else { return }

        let waiter = ReadyWaiter()
        readyWaiters.append(waiter)
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            waiter.timer = Task { @MainActor in
                try? await Task.sleep(for: WebKitPageScript.timeout)
                waiter.finish(.failure(BrowserPageDriveError.waitTimedOut))
            }
        }
    }

    private func pageScript() throws -> WebKitPageScript {
        try pageScriptResult.get()
    }
}
