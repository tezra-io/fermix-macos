import Foundation

extension BrowserTab {
    /// `page.snapshot`: the page read the way the engine's renderer expects
    /// it. The host client is the only caller.
    ///
    /// A navigation already in flight is waited for first, within the settle
    /// budget: a snapshot taken the instant a load starts reads whatever was
    /// there before. A load still in flight once the budget is spent is read
    /// as it stands, and the snapshot's `readyState` says so.
    public func snapshot(mode: BrowserSnapshotMode, maxChars: Int, depth: Int) async throws -> BrowserPageSnapshot {
        let driver = try drivenPage()
        _ = try await driver.waitForLoad(within: BrowserPageSettle.settleBudget)
        return try await driver.snapshot(BrowserSnapshotRequest(mode: mode, maxChars: maxChars, depth: depth))
    }

    /// The look after `tab.open` or `tab.navigate`, once its navigation
    /// commits, within the navigation timeout, and then within the navigation
    /// budget. The host client is the only caller.
    public func snapshotAfterNavigation(mode: BrowserSnapshotMode, maxChars: Int, depth: Int) async throws -> BrowserPageSnapshot {
        try await drivenPage().snapshotAfterNavigation(BrowserSnapshotRequest(mode: mode, maxChars: maxChars, depth: depth))
    }

    /// One of the engine's act kinds, carried out on the page, then looked at
    /// when `look` names a snapshot, and answered at once when it is nil.
    public func act(_ action: BrowserPageAction, observing look: BrowserSnapshotRequest?) async throws -> BrowserActOutcome {
        try await drivenPage().act(action, observing: look)
    }

    private func drivenPage() throws -> any BrowserPageDriving {
        guard let driver else { throw BrowserPageDriveError.notDrivable }

        return driver
    }
}
