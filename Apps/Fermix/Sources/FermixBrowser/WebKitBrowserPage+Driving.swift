import FermixAppCore
import Foundation

/// The page as the engine reads and drives it (plan §4.2), on the page script
/// and the trusted input `WebKitPageActions` delivers.
extension WebKitBrowserPage: BrowserPageDriving {
    func snapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        try await WebKitPageSnapshot(script: pageScript(), webView: webView).take(request)
    }

    func snapshotAfterNavigation(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        try await pageActions().lookAfterNavigation(request)
    }

    func act(_ action: BrowserPageAction, observing look: BrowserSnapshotRequest?) async throws -> BrowserActOutcome {
        try await pageActions().perform(action, observing: look)
    }

    /// The page's act kinds, its looks and its sign-in handlers, on one
    /// script. The actions live for one call, so holding the page is no cycle.
    func pageActions() throws -> WebKitPageActions {
        WebKitPageActions(
            webView: webView,
            script: try pageScript(),
            expectUpload: { [weak self] path in self?.pendingUploadPath = path },
            waitForLoad: { budget in try await self.waitForLoad(within: budget) },
            waitForCommit: { budget in try await self.waitForCommit(within: budget) },
            navigations: { self.navigationsStarted }
        )
    }

    /// Waits for the navigation `webView.isLoading` reports in flight to
    /// finish, for at most `budget`, and answers whether it did: a page that
    /// is not loading answers true at once, and one still loading when the
    /// budget runs out answers false, never an error. A
    /// navigation that fails throws its reason.
    func waitForLoad(within budget: Duration) async throws -> Bool {
        guard webView.isLoading else { return true }

        let waiter = ReadyWaiter()
        readyWaiters.append(waiter)
        return try await park(waiter, within: budget)
    }

    /// Waits for the navigation the last `load` started to commit, for at
    /// most `budget`, and answers whether it is over: true once it has
    /// committed, or ended without failing and without a commit, at once if
    /// it already has; false when the budget runs out first, never an error.
    /// A navigation that failed throws its reason.
    func waitForCommit(within budget: Duration) async throws -> Bool {
        endIfDropped()
        if case .over(let outcome) = requested { return try outcome.map { _ in true }.get() }

        let waiter = ReadyWaiter()
        commitWaiters.append(waiter)
        return try await park(waiter, within: budget)
    }

    /// `waiter`, already in its list, until the delegate answers it or
    /// `budget` runs out.
    private func park(_ waiter: ReadyWaiter, within budget: Duration) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            waiter.timer = Task { @MainActor in
                try? await Task.sleep(for: budget)
                self.giveUp(waiter)
            }
        }
    }

    /// A waiter whose budget ran out leaves its list before it answers, so a
    /// navigation that never commits or finishes keeps none of them.
    private func giveUp(_ waiter: ReadyWaiter) {
        readyWaiters.removeAll { $0 === waiter }
        commitWaiters.removeAll { $0 === waiter }
        waiter.finish(.success(false))
    }

    private func pageScript() throws -> WebKitPageScript {
        try pageScriptResult.get()
    }
}
