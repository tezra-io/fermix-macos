import Foundation
import Testing

@testable import FermixAppCore

/// The tab's host actions (plan §4.2): forwarding to a page with a web engine
/// behind it, and refusing one with none.
@Suite("Browser tab driving")
@MainActor
struct BrowserTabDrivingTests {
    @Test("a page with no web engine behind it refuses a snapshot")
    func fixturePageHasNoDriver() async throws {
        let tab = BrowserTab(profile: .shared, page: FakeBrowserPage())

        #expect(tab.driver == nil)
        await #expect(throws: BrowserPageDriveError.notDrivable) {
            _ = try await tab.snapshot(mode: .interactive, maxChars: 4000, depth: 5)
        }
    }

    @Test("a page with no web engine behind it refuses an act")
    func fixturePageRefusesAnAct() async throws {
        let tab = BrowserTab(profile: .shared, page: FakeBrowserPage())

        await #expect(throws: BrowserPageDriveError.notDrivable) {
            _ = try await tab.act(.click(ref: 1), observing: BrowserSnapshotRequest(mode: .interactive, maxChars: 4000, depth: 5))
        }
    }

    @Test("a snapshot forwards the request to the driven page and back")
    func snapshotForwards() async throws {
        let page = FakeDrivablePage()
        let expected = BrowserPageSnapshot(
            title: "Example", url: "https://example.com", nodes: [BrowserPageNode(id: 0, role: "RootWebArea")],
            elements: 3, crossOriginFrames: 0, closedShadowRoots: false, evaluateMilliseconds: 4
        )
        page.snapshotResult = .success(expected)
        let tab = BrowserTab(profile: .shared, page: page)

        let snapshot = try await tab.snapshot(mode: .full, maxChars: 8000, depth: 3)

        #expect(snapshot == expected)
        #expect(page.snapshotRequests == [BrowserSnapshotRequest(mode: .full, maxChars: 8000, depth: 3)])
    }

    @Test("an act forwards the action and the observing request to the driven page")
    func actForwards() async throws {
        let page = FakeDrivablePage()
        let expected = BrowserActOutcome(effect: .unchanged, input: .trusted, url: "https://example.com", value: "hi")
        page.actResult = .success(expected)
        let tab = BrowserTab(profile: .shared, page: page)
        let request = BrowserSnapshotRequest(mode: .interactive, maxChars: 4000, depth: 5)

        let outcome = try await tab.act(.fill(ref: 3, text: "hi"), observing: request)

        #expect(outcome == expected)
        #expect(page.actions == [.fill(ref: 3, text: "hi")])
        #expect(page.snapshotRequests == [request])
    }

    @Test("a driven page's own refusal reaches the caller")
    func drivenPageRefusalReachesTheCaller() async throws {
        let page = FakeDrivablePage()
        page.actResult = .failure(BrowserPageDriveError.staleRef(9))
        let tab = BrowserTab(profile: .shared, page: page)

        await #expect(throws: BrowserPageDriveError.staleRef(9)) {
            _ = try await tab.act(.click(ref: 9), observing: BrowserSnapshotRequest(mode: .interactive, maxChars: 4000, depth: 5))
        }
    }

    // MARK: - Waiting for the page to be ready

    @Test("a page already loaded snapshots at once")
    func snapshotWhenAlreadyReady() async throws {
        let page = FakeDrivablePage()
        page.snapshotResult = .success(.empty)
        let tab = BrowserTab(profile: .shared, page: page)

        _ = try await tab.snapshot(mode: .interactive, maxChars: 4000, depth: 5)

        #expect(page.readyWaits == 1, "the wait ran and answered at once")
        #expect(page.snapshotRequests.count == 1)
    }

    @Test("a page still loading defers the snapshot until it finishes")
    func snapshotWaitsForALoadInFlightToFinish() async throws {
        let page = FakeDrivablePage()
        page.readyGate = AsyncGate()
        page.snapshotResult = .success(.empty)
        let tab = BrowserTab(profile: .shared, page: page)

        let snapshot = Task { try await tab.snapshot(mode: .interactive, maxChars: 4000, depth: 5) }
        await Task.yield()
        #expect(page.snapshotRequests.isEmpty, "the snapshot has not been asked for yet")

        page.readyGate?.release()
        _ = try await snapshot.value

        #expect(page.snapshotRequests.count == 1)
    }

    @Test("a load that fails answers the error, and no snapshot is taken")
    func snapshotThrowsWhenTheLoadItWasWaitingOnFails() async throws {
        let page = FakeDrivablePage()
        page.readyGate = AsyncGate()
        page.readyFailure = BrowserPageDriveError.navigationFailed("a server with the specified hostname could not be found")
        let tab = BrowserTab(profile: .shared, page: page)

        let snapshot = Task { try await tab.snapshot(mode: .interactive, maxChars: 4000, depth: 5) }
        await Task.yield()
        page.readyGate?.release()

        await #expect(throws: BrowserPageDriveError.navigationFailed("a server with the specified hostname could not be found")) {
            _ = try await snapshot.value
        }
        #expect(page.snapshotRequests.isEmpty, "a page that never loaded is never read")
    }
}
