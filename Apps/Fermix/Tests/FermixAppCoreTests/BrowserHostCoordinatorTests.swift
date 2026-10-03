import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The browser coordinator as the host: a task's tabs, where each page is on
/// screen, the reports the host sends, and its part of a quit. The corner
/// window and the pane's page area are fakes that record which pages they
/// hold, so every reparenting decision is read without a window.
@Suite("Browser host coordinator")
@MainActor
struct BrowserHostCoordinatorTests {
    nonisolated static let page = URL(string: "https://example.com")!
    nonisolated static let task = BrowserTaskID("task-1")
    nonisolated static let other = BrowserTaskID("task-2")
    nonisolated static let caps = BrowserTabCaps(perTask: 2, global: 3)
    nonisolated static let downloads = URL(fileURLWithPath: "/fermix/browser/downloads/task-1", isDirectory: true)

    /// A harness whose host is attached, and the daemon's end of it.
    static func attached(
        _ harness: BrowserHarness,
        caps: BrowserTabCaps = caps
    ) throws -> (link: FakeHostLink, connection: BrowserHostConnection) {
        let link = FakeHostLink()
        let connection = try #require(harness.coordinator.hostAttached(link, caps: caps))

        return (link, connection)
    }

    static func openTaskTab(
        _ harness: BrowserHarness,
        for task: BrowserTaskID = task
    ) throws -> BrowserTab {
        let id = try harness.coordinator.openTaskTab(page, for: task, downloadDirectory: downloads).get()

        return try #require(harness.model.tabs.first { $0.id == id })
    }

    /// The pane open, its page area built, in a window on screen.
    static func showPaneOnScreen(_ harness: BrowserHarness) {
        harness.coordinator.showPane()
        harness.coordinator.paneStageAppeared(harness.pane)
        harness.coordinator.windowVisibilityChanged(true)
    }

    // MARK: - A task's tabs

    @Test("a task's tab runs in the host window, loads its page and never opens the pane")
    func taskTabRunsInTheHostWindow() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)

        let tab = try Self.openTaskTab(harness)

        #expect(harness.hostWindow.holds(tab.view))
        #expect(harness.page(0).loaded == [Self.page])
        #expect(!harness.model.isOpen)
        #expect(harness.record.paneShown.isEmpty, "a task brought the window's pane forward")
        #expect(harness.model.host.owner(of: tab.id) == .task(Self.task))
    }

    @Test("a task's tab comes to the front of a pane with nothing in front, and behind the person's tab otherwise")
    func taskTabFrontOnlyOfAnEmptyPane() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)

        let first = try Self.openTaskTab(harness)
        #expect(harness.model.selectedTabID == first.id)

        harness.coordinator.open(Self.page)
        let person = try #require(harness.model.selectedTab)
        _ = try Self.openTaskTab(harness, for: Self.other)
        #expect(harness.model.selectedTabID == person.id)
    }

    @Test("a task's tab past a cap is refused, and nothing is added")
    func taskTabPastTheCap() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness, caps: BrowserTabCaps(perTask: 1, global: 1))
        _ = try Self.openTaskTab(harness)

        let refused = harness.coordinator.openTaskTab(Self.page, for: Self.task, downloadDirectory: Self.downloads)

        #expect(refused == .failure(.taskCap))
        #expect(harness.model.tabs.count == 1)
        #expect(harness.page(1).loaded.isEmpty, "a refused tab loaded its page")
    }

    @Test("a detached host takes no task tab")
    func detachedHostRefuses() {
        let harness = BrowserHarness()

        #expect(harness.coordinator.openTaskTab(Self.page, for: Self.task, downloadDirectory: Self.downloads) == .failure(.notAttached))
        #expect(harness.model.tabs.isEmpty)
    }

    @Test("an unavailable session refuses a task's tab")
    func unavailableRefuses() throws {
        let harness = BrowserHarness(availability: .unavailable(.screenLocked))
        _ = try Self.attached(harness)

        #expect(harness.coordinator.openTaskTab(Self.page, for: Self.task, downloadDirectory: Self.downloads) == .failure(.unavailable(.screenLocked)))
    }

    // MARK: - Visibility while driven

    @Test("a task's page is always in a window, and the person's only in front of an open pane")
    func placementRule() {
        let task = BrowserTabOwner.task(Self.task)
        let expected: [(BrowserTabOwner, Bool, BrowserPaneVisibility, BrowserPagePlace)] = [
            (task, true, .onScreen, .pane),
            (task, false, .onScreen, .hostWindow),
            (task, true, .covered, .hostWindow),
            (task, false, .covered, .hostWindow),
            (task, true, .hidden, .hostWindow),
            (task, false, .hidden, .hostWindow),
            (.person, true, .onScreen, .pane),
            (.person, false, .onScreen, .nowhere),
            (.person, true, .covered, .pane),
            (.person, false, .covered, .nowhere),
            (.person, true, .hidden, .nowhere),
            (.person, false, .hidden, .nowhere)
        ]

        for (owner, inFront, pane, place) in expected {
            #expect(BrowserPagePlace.of(owner: owner, inFront: inFront, pane: pane) == place, "\(owner) \(inFront) \(pane)")
        }
    }

    @Test("a task's page moves into a pane on screen by reparenting, and is never loaded again")
    func taskPageMovesIntoThePane() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        let tab = try Self.openTaskTab(harness)

        Self.showPaneOnScreen(harness)

        #expect(harness.pane.holds(tab.view))
        #expect(!harness.hostWindow.holds(tab.view))
        #expect(harness.page(0).loaded == [Self.page], "the move reloaded the page")
        #expect(!harness.page(0).actions.contains("reload"))
    }

    @Test("a covered, minimised or far-away window sends the task's page back to the host window")
    func coveredWindowSendsTheTaskPageAway() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        let tab = try Self.openTaskTab(harness)
        Self.showPaneOnScreen(harness)

        harness.coordinator.windowVisibilityChanged(false)
        #expect(harness.hostWindow.holds(tab.view))
        #expect(!harness.pane.holds(tab.view))

        harness.coordinator.windowVisibilityChanged(true)
        #expect(harness.pane.holds(tab.view))
        #expect(!harness.hostWindow.holds(tab.view))
    }

    @Test("the person's page stays in a covered pane, as it always did")
    func personPageStaysInACoveredPane() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.page)
        harness.coordinator.paneStageAppeared(harness.pane)
        harness.coordinator.windowVisibilityChanged(true)
        let tab = try #require(harness.model.selectedTab)

        harness.coordinator.windowVisibilityChanged(false)

        #expect(harness.pane.holds(tab.view))
        #expect(!harness.hostWindow.holds(tab.view))
    }

    @Test("hiding the pane sends the task's page to the host window and the person's out of every window")
    func hidingThePane() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        let task = try Self.openTaskTab(harness)
        Self.showPaneOnScreen(harness)
        harness.coordinator.open(Self.page)
        let person = try #require(harness.model.selectedTab)
        #expect(harness.pane.holds(person.view))

        harness.coordinator.closePane()

        #expect(harness.hostWindow.holds(task.view))
        #expect(!harness.pane.holds(person.view))
        #expect(!harness.hostWindow.holds(person.view), "the person's page ran in the host window")
    }

    @Test("a task's tab behind another runs in the host window while the pane shows")
    func taskTabBehindAnother() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        let task = try Self.openTaskTab(harness)
        Self.showPaneOnScreen(harness)

        harness.coordinator.open(Self.page)

        #expect(harness.hostWindow.holds(task.view))
        #expect(harness.pane.held.count == 1, "the pane holds one page")

        harness.coordinator.select(task)
        #expect(harness.pane.holds(task.view))
        #expect(harness.pane.held.count == 1)
    }

    @Test("a page area built again takes the page in front, and the one it replaced is let go")
    func paneStageReplaced() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        let tab = try Self.openTaskTab(harness)
        Self.showPaneOnScreen(harness)
        let rebuilt = FakePageStage()

        harness.coordinator.paneStageAppeared(rebuilt)
        harness.coordinator.paneStageGone(harness.pane)

        #expect(rebuilt.holds(tab.view))

        harness.coordinator.paneStageGone(rebuilt)
        #expect(harness.hostWindow.holds(tab.view), "a task's page lost its window with the pane's area")
        #expect(!rebuilt.holds(tab.view))
    }

    // MARK: - Ownership in the pane

    @Test("the person's close of a task's tab cancels the task, once, and the tab stays")
    func closingATaskTabCancels() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)
        let tab = try Self.openTaskTab(harness)

        harness.coordinator.close(tab)
        harness.coordinator.close(tab)

        #expect(link.cancelled == [Self.task])
        #expect(harness.model.tabs.map(\.id) == [tab.id])
        #expect(harness.model.host.pendingRelease == [Self.task])
    }

    @Test("the task's release takes its tabs, the person's stay, and the pane with no tab left hides")
    func releaseTakesTheTasksTabs() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        let task = try Self.openTaskTab(harness)
        Self.showPaneOnScreen(harness)

        harness.coordinator.releaseTask(Self.task)

        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.pane.holds(task.view))
        #expect(!harness.hostWindow.holds(task.view))
        #expect(!harness.model.isOpen, "the pane with no tab stayed open")
        #expect(harness.page(0).actions.contains("stop"))
    }

    @Test("a release of the tab in front and its popup brings the nearest tab that stays to the front")
    func releaseInFront() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        harness.coordinator.open(Self.page)
        let task = try Self.openTaskTab(harness)
        harness.coordinator.select(task)
        _ = harness.page(1).events?.pageOpened(FakeBrowserPage())
        harness.coordinator.open(Self.page)
        let after = try #require(harness.model.tabs.last)
        harness.coordinator.select(task)

        harness.coordinator.releaseTask(Self.task)

        #expect(harness.model.tabs.count == 2)
        #expect(harness.model.selectedTabID == after.id)
    }

    @Test("losing the daemon releases every task's tabs and keeps the person's")
    func detachReleasesTaskTabs() throws {
        let harness = BrowserHarness()
        let (_, connection) = try Self.attached(harness)
        _ = try Self.openTaskTab(harness)
        _ = try Self.openTaskTab(harness, for: Self.other)
        harness.coordinator.open(Self.page)
        let person = try #require(harness.model.selectedTab)

        harness.coordinator.hostDetached(connection)

        #expect(harness.model.tabs.map(\.id) == [person.id])
    }

    @Test("a popup from a task's tab is the task's, stays out of the pane, and is blocked at the cap")
    func taskPopups() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness, caps: BrowserTabCaps(perTask: 2, global: 2))
        let tab = try Self.openTaskTab(harness)

        let opened = harness.page(0).events?.pageOpened(FakeBrowserPage())
        let popup = try #require(harness.model.tabs.last)
        let blocked = harness.page(0).events?.pageOpened(FakeBrowserPage())

        #expect(opened == true)
        #expect(harness.model.host.owner(of: popup.id) == .task(Self.task))
        #expect(harness.hostWindow.holds(popup.view))
        #expect(!harness.model.isOpen)
        #expect(blocked == false, "a popup past the task's cap was let through")

        harness.coordinator.releaseTask(Self.task)
        #expect(!harness.model.tabs.contains { $0.id == tab.id || $0.id == popup.id })
    }

    @Test("a task's page that closes its own window tells the daemon")
    func taskPageClosesItself() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)
        let tab = try Self.openTaskTab(harness)

        harness.page(0).events?.pageAskedToClose()

        #expect(link.closedTabs == [tab.id])
        #expect(harness.model.tabs.isEmpty)
    }

    // MARK: - The pane on its own

    @Test("Show browser opens the pane with no tab in it")
    func showBrowserOpensAnEmptyPane() {
        let harness = BrowserHarness()

        harness.coordinator.showPane()

        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.isEmpty)
        #expect(harness.record.paneShown == [true])
        #expect(harness.record.enginesBuilt.isEmpty, "an empty pane built the engine")
    }

    // MARK: - Reports

    @Test("the host reports availability at attach and on every change")
    func availabilityReports() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)

        harness.session.set(.unavailable(.displayAsleep))
        harness.session.set(.available)

        #expect(link.reports == [.available, .unavailable(.displayAsleep), .available])
    }

    @Test("the idle release reaches the engine only with no tab of anyone's")
    func idleRelease() throws {
        let harness = BrowserHarness()
        _ = try Self.attached(harness)
        _ = try Self.openTaskTab(harness)

        harness.coordinator.releaseIdle()
        #expect(harness.engine.idleReleases == 0)

        harness.coordinator.releaseTask(Self.task)
        harness.coordinator.releaseIdle()
        #expect(harness.engine.idleReleases == 1)
    }

    // MARK: - Quit

    @Test("a quit with no daemon attached completes at once and holds nothing")
    func quitWithoutADaemon() {
        let harness = BrowserHarness()
        var done = 0

        harness.coordinator.stopHost { done += 1 }

        #expect(done == 1)
        #expect(harness.deadlines.liveCount == 0)
    }

    @Test("an attached quit reports terminating, releases every task tab, sends host_stopping and holds")
    func quitHolds() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)
        _ = try Self.openTaskTab(harness)
        var done = 0

        harness.coordinator.stopHost { done += 1 }

        #expect(done == 0, "the quit went ahead without the daemon's answer")
        #expect(harness.model.tabs.isEmpty)
        #expect(link.events == ["availability", "availability", "host_stopping"])
        #expect(link.reports.last == .unavailable(.appTerminating))
        #expect(harness.deadlines.scheduledDelays == [BrowserCoordinator.quitBound])
        #expect(BrowserCoordinator.quitBound == 2)
    }

    @Test("the daemon's answer ends the hold and calls off the bound")
    func answerEndsTheHold() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)
        var done = 0
        harness.coordinator.stopHost { done += 1 }

        link.answerStopping()
        harness.deadlines.fireAll()

        #expect(done == 1)
        #expect(harness.deadlines.liveCount == 0)
    }

    /// BROWSER-7: the answer is lost with the connection, and the bound is
    /// what lets the app quit.
    @Test("the bound ends the hold when the answer never comes, and a late answer does nothing")
    func boundEndsTheHold() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)
        var done = 0
        harness.coordinator.stopHost { done += 1 }

        harness.deadlines.fireAll()
        link.answerStopping()

        #expect(done == 1)
    }

    @Test("losing the daemon while the quit holds completes it")
    func detachEndsTheHold() throws {
        let harness = BrowserHarness()
        let (_, connection) = try Self.attached(harness)
        var done = 0
        harness.coordinator.stopHost { done += 1 }

        harness.coordinator.hostDetached(connection)
        harness.deadlines.fireAll()

        #expect(done == 1)
    }

    @Test("nothing is reported after host_stopping")
    func noReportAfterStopping() throws {
        let harness = BrowserHarness()
        let (link, _) = try Self.attached(harness)
        harness.coordinator.stopHost {}

        harness.session.set(.available)

        #expect(link.events.last == "host_stopping")
    }
}
