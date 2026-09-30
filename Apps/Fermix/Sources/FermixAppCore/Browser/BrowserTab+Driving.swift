import Foundation

extension BrowserTab {
    /// The page read the way the engine's renderer expects it. The host client
    /// is the only caller.
    ///
    /// Waits for a navigation already in flight to finish first: a snapshot
    /// taken the instant `tab.open` or `tab.navigate` calls `load` races the
    /// page it just asked for, and reads whatever was there before.
    public func snapshot(mode: BrowserSnapshotMode, maxChars: Int, depth: Int) async throws -> BrowserPageSnapshot {
        let driver = try drivenPage()
        try await driver.waitUntilReady()
        return try await driver.snapshot(BrowserSnapshotRequest(mode: mode, maxChars: maxChars, depth: depth))
    }

    /// One of the engine's act kinds, carried out on the page.
    public func act(_ action: BrowserPageAction, observing request: BrowserSnapshotRequest) async throws -> BrowserActOutcome {
        try await drivenPage().act(action, observing: request)
    }

    private func drivenPage() throws -> any BrowserPageDriving {
        guard let driver else { throw BrowserPageDriveError.notDrivable }

        return driver
    }
}
