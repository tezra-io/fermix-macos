import Foundation
import Testing

@testable import FermixAppCore

/// The host's reducer, held to the `browser_host` spec's rules
/// (`tla/specs/browser_host/README.md`). The app is the spec's unpinned
/// mirror: the model checker cannot read this repository, so each rule the
/// spec holds of the app is a test here, under the rule's own name.
@Suite("Browser host reducer")
struct BrowserHostReducerTests {
    static let first = BrowserTaskID("task-1")
    static let second = BrowserTaskID("task-2")
    static let roomy = BrowserTabCaps(perTask: 3, global: 6)

    /// A host attached with the given caps, and the connection it attached on.
    static func attached(
        _ caps: BrowserTabCaps = roomy
    ) throws -> (host: HostUnderTest, connection: BrowserHostConnection) {
        let host = HostUnderTest(.available)
        let connection = try #require(host.attach(caps: caps))

        return (host, connection)
    }

    /// Opens a task tab and requires that it was taken.
    static func open(_ task: BrowserTaskID, in host: HostUnderTest) throws -> UUID {
        let tab = UUID()
        try #require(host.openTaskTab(tab, for: task) == .admitted(.task(task)))

        return tab
    }

    // MARK: - TabsReleasedExactlyOnce

    @Test("TabsReleasedExactlyOnce: a release closes the task's tabs, and a second finds nothing")
    func tabsReleasedExactlyOnce() throws {
        let (host, _) = try Self.attached()
        let one = try Self.open(Self.first, in: host)
        let two = try Self.open(Self.first, in: host)

        #expect(host.release(Self.first) == [one, two])
        #expect(host.release(Self.first).isEmpty, "a second release closed a tab again")
        #expect(host.owner(of: one) == nil)
        #expect(host.owner(of: two) == nil)
    }

    /// BROWSER-2's path: the connection drops and the host releases every task
    /// tab, then the person quits and the host releases again from what it kept.
    @Test("TabsReleasedExactlyOnce: losing the daemon, then quitting, releases each tab once")
    func detachThenQuitReleasesOnce() throws {
        let (host, connection) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)

        #expect(host.detach(connection).released == [tab])
        #expect(host.stop() == .complete(released: []))
    }

    /// The same shape with no drop: the daemon's `task.release`, then the
    /// host's own release at `host_stopping`.
    @Test("TabsReleasedExactlyOnce: a task's release, then quitting, releases each tab once")
    func releaseThenQuitReleasesOnce() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)

        #expect(host.release(Self.first) == [tab])
        #expect(host.stop() == .hold(released: []))
        #expect(host.release(Self.first).isEmpty, "the daemon's release after host_stopping found a tab")
    }

    @Test("TabsReleasedExactlyOnce: a release closes exactly its task's tabs")
    func releaseIsExactlyTheTasks() throws {
        let (host, _) = try Self.attached()
        let mine = try Self.open(Self.first, in: host)
        let theirs = try Self.open(Self.second, in: host)

        #expect(host.release(Self.first) == [mine])
        #expect(host.owner(of: theirs) == .task(Self.second))
    }

    // MARK: - PersonTabsNeverReleasedByTasks

    /// BROWSER-3's first path: the person's tab opens a popup, which with no
    /// owner to inherit joined the task pool and went with the next release.
    @Test("PersonTabsNeverReleasedByTasks: no release, drop or quit closes the person's tabs or their popups")
    func personTabsNeverReleasedByTasks() throws {
        let (host, connection) = try Self.attached()
        let person = UUID()
        let popup = UUID()
        host.openPersonTab(person)
        #expect(host.openPopup(popup, from: person) == .admitted(.person))
        let task = try Self.open(Self.first, in: host)

        #expect(host.release(Self.first) == [task])
        #expect(host.detach(connection).released.isEmpty)
        #expect(host.stop() == .complete(released: []))
        #expect(host.owner(of: person) == .person)
        #expect(host.owner(of: popup) == .person)
    }

    // MARK: - NoTaskTabClosedByPerson

    /// Witness 14: the person is refused the close of a task's tab, cancels
    /// the task instead, and the task's release takes the tab.
    @Test("NoTaskTabClosedByPerson: closing a task's tab is a cancel of the task, and the tab stays")
    func noTaskTabClosedByPerson() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)

        #expect(host.personClose(tab) == .cancelTask(Self.first))
        #expect(host.owner(of: tab) == .task(Self.first))

        #expect(host.cancel(Self.first), "the first cancel is sent")
        #expect(!host.cancel(Self.first), "a second click sends nothing more")
        #expect(host.pendingRelease == [Self.first])

        #expect(host.release(Self.first) == [tab])
        #expect(host.pendingRelease.isEmpty)
    }

    @Test("the person's own tab closes, and its record goes")
    func personClosesTheirOwnTab() {
        let host = HostUnderTest(.available)
        let tab = UUID()
        host.openPersonTab(tab)

        #expect(host.personClose(tab) == .close)
        #expect(host.owner(of: tab) == nil)
    }

    @Test("a task with no tab here has nothing to cancel from a tab")
    func cancellingATaskWithNoTab() throws {
        let (host, _) = try Self.attached()

        #expect(!host.cancel(Self.first))
        #expect(host.pendingRelease.isEmpty)
    }

    // MARK: - CapsHold

    @Test("CapsHold: a task's tab past its own cap is refused, not queued")
    func taskCapHolds() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 1, global: 1))
        _ = try Self.open(Self.first, in: host)

        #expect(host.openTaskTab(UUID(), for: Self.first) == .refused(.taskCap))
        #expect(host.openTaskTab(UUID(), for: Self.second) == .refused(.globalCap))
        #expect(host.taskTabCount == 1)
    }

    @Test("CapsHold: the global cap counts every task's tabs")
    func globalCapHolds() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 2, global: 3))
        _ = try Self.open(Self.first, in: host)
        _ = try Self.open(Self.first, in: host)
        _ = try Self.open(Self.second, in: host)

        #expect(host.openTaskTab(UUID(), for: Self.second) == .refused(.globalCap))
        #expect(host.taskTabCount == 3)
    }

    @Test("CapsHold: the caps count task tabs only, so the person's tabs never block a task")
    func personTabsDoNotCount() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 1, global: 1))
        host.openPersonTab(UUID())
        host.openPersonTab(UUID())

        _ = try Self.open(Self.first, in: host)
        #expect(host.taskTabCount == 1)
    }

    @Test("a release gives the task its room back")
    func releaseFreesTheCap() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 1, global: 1))
        _ = try Self.open(Self.first, in: host)
        _ = host.release(Self.first)

        _ = try Self.open(Self.second, in: host)
    }

    // MARK: - Popups

    @Test("a popup from a task's tab is the task's, and so is a popup of that popup")
    func popupInheritsTheTask() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)
        let popup = UUID()
        let nested = UUID()

        #expect(host.openPopup(popup, from: tab) == .admitted(.task(Self.first)))
        #expect(host.openPopup(nested, from: popup) == .admitted(.task(Self.first)))
        #expect(host.release(Self.first) == [tab, popup, nested])
    }

    /// Check 12's path: a page in a task's one tab opens a popup past the
    /// task's cap of one. The popup is blocked, which is `window.open`
    /// answering null.
    @Test("CapsHold: a popup past its task's cap is blocked")
    func popupAtTheCapIsBlocked() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 1, global: 2))
        let tab = try Self.open(Self.first, in: host)

        #expect(host.openPopup(UUID(), from: tab) == .refused(.taskCap))
        #expect(host.taskTabCount == 1)
    }

    /// Witness 13: a popup takes a slot under its task's cap, so the task's
    /// own next `tab.open` is refused.
    @Test("a popup counts under its task's cap")
    func popupTakesASlot() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 2, global: 4))
        let tab = try Self.open(Self.first, in: host)
        _ = host.openPopup(UUID(), from: tab)

        #expect(host.openTaskTab(UUID(), for: Self.first) == .refused(.taskCap))
    }

    @Test("a popup from the person's tab is never capped")
    func personPopupsAreNotCapped() throws {
        let (host, _) = try Self.attached(BrowserTabCaps(perTask: 1, global: 1))
        _ = try Self.open(Self.first, in: host)
        let person = UUID()
        host.openPersonTab(person)

        #expect(host.openPopup(UUID(), from: person) == .admitted(.person))
    }

    @Test("a popup whose opener has gone is refused")
    func popupFromAGoneOpener() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)
        _ = host.release(Self.first)

        #expect(host.openPopup(UUID(), from: tab) == .refused(.notTheTasksTab))
    }

    @Test("a popup's opener is kept, for tab.list to carry, and dropped with its own record")
    func popupOpenerIsKeptAndDropped() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)
        let popup = UUID()
        _ = host.openPopup(popup, from: tab)

        #expect(host.opener(of: popup) == tab)
        #expect(host.opener(of: tab) == nil, "a tab nothing opened has no opener")

        _ = host.release(Self.first)
        #expect(host.opener(of: popup) == nil, "the opener goes with the popup's own record")
    }

    @Test("a person's own popup keeps its opener too")
    func personsPopupKeepsItsOpener() {
        let host = HostUnderTest(.available)
        let person = UUID()
        let popup = UUID()
        host.openPersonTab(person)
        _ = host.openPopup(popup, from: person)

        #expect(host.opener(of: popup) == person)
    }

    // MARK: - Caps from the wire

    @Test("tab.open's own caps are what govern the task, once established")
    func establishedCapsGovernTheTask() throws {
        let host = HostUnderTest(.available)
        _ = host.attach(caps: nil)

        #expect(host.establishCaps(BrowserTabCaps(perTask: 1, global: 1)))
        _ = try Self.open(Self.first, in: host)

        #expect(host.openTaskTab(UUID(), for: Self.first) == .refused(.taskCap))
    }

    @Test("the same caps a second tab.open names are accepted again")
    func repeatingTheSameCapsIsAccepted() {
        let host = HostUnderTest(.available)
        _ = host.attach(caps: nil)

        #expect(host.establishCaps(BrowserTabCaps(perTask: 2, global: 4)))
        #expect(host.establishCaps(BrowserTabCaps(perTask: 2, global: 4)))
    }

    @Test("a later tab.open naming different caps is refused, not adopted")
    func differentCapsAreRefused() {
        let host = HostUnderTest(.available)
        _ = host.attach(caps: nil)

        #expect(host.establishCaps(BrowserTabCaps(perTask: 2, global: 4)))
        #expect(!host.establishCaps(BrowserTabCaps(perTask: 3, global: 4)))
        #expect(host.caps == BrowserTabCaps(perTask: 2, global: 4), "the first caps still stand")
    }

    @Test("caps cannot be established before a host attaches")
    func capsNeedAConnection() {
        let host = HostUnderTest(.available)

        #expect(!host.establishCaps(BrowserTabCaps(perTask: 1, global: 1)))
    }

    // MARK: - IdleReleaseSparesTaskTabs

    /// BROWSER-3's second path: a task waits between two steps with nothing in
    /// flight and the person has no tab. A host that could not see the owner
    /// counted itself idle and let the task's tab go.
    @Test("IdleReleaseSparesTaskTabs: the idle release never takes a task's tab")
    func idleReleaseSparesTaskTabs() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)

        #expect(!host.releaseIdle())
        #expect(host.owner(of: tab) == .task(Self.first))
        #expect(host.viewsHeld)
    }

    /// The check reads the registry in the step that releases: a timer armed
    /// when the host went idle finds the tab opened since.
    @Test("IdleReleaseSparesTaskTabs: a timer armed while idle re-reads the registry when it fires")
    func idleTimerRereadsTheRegistry() throws {
        let (host, _) = try Self.attached()
        _ = try Self.open(Self.first, in: host)
        _ = host.release(Self.first)
        // Idle now; the timer is armed here and fires after the next open.
        _ = try Self.open(Self.second, in: host)

        #expect(!host.releaseIdle())
    }

    @Test("with no tab of anyone's the web views go, once")
    func idleReleaseWithNoTabs() throws {
        let (host, _) = try Self.attached()
        _ = try Self.open(Self.first, in: host)
        _ = host.release(Self.first)

        #expect(host.releaseIdle())
        #expect(!host.viewsHeld)
        #expect(!host.releaseIdle(), "nothing is left to release")
    }

    @Test("the person's tab keeps the web views")
    func personTabKeepsTheViews() {
        let host = HostUnderTest(.available)
        host.openPersonTab(UUID())

        #expect(!host.releaseIdle())
    }

    // MARK: - QuitNeverAbandons

    @Test("QuitNeverAbandons: an attached host releases its task tabs and holds the quit")
    func quitHoldsWhileAttached() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)
        let person = UUID()
        host.openPersonTab(person)

        #expect(host.stop() == .hold(released: [tab]))
        #expect(host.quit == .holding)
        #expect(host.owner(of: person) == .person, "the person's tabs go with the process, not the release")
    }

    /// BROWSER-7: the connection drops while the quit holds, and the daemon
    /// answers into a closed socket. The bound ends the hold.
    @Test("QuitNeverAbandons: the bound ends the hold when the answer never comes")
    func boundEndsTheHold() throws {
        let (host, _) = try Self.attached()
        _ = host.stop()

        #expect(host.endQuitHold(), "the bound ended it")
        #expect(host.quit == .ended)
        #expect(!host.endQuitHold(), "the late answer finds it ended")
        #expect(host.connection == nil)
    }

    @Test("QuitNeverAbandons: losing the daemon while the quit holds ends it, the bound at zero")
    func detachEndsTheHold() throws {
        let (host, connection) = try Self.attached()
        _ = try Self.open(Self.first, in: host)
        _ = host.stop()

        let detach = host.detach(connection)
        #expect(detach.endsQuit)
        #expect(detach.released.isEmpty, "the tabs went at host_stopping")
        #expect(host.quit == .ended)
        #expect(!host.endQuitHold())
    }

    @Test("QuitNeverAbandons: a host with no daemon completes the quit at once")
    func quitWithoutADaemon() {
        let host = HostUnderTest(.available)

        #expect(host.stop() == .complete(released: []))
        #expect(host.quit == .ended)
    }

    @Test("a stopping host takes no task tab and attaches no more")
    func stoppingIsFinal() throws {
        let (host, connection) = try Self.attached()
        _ = host.stop()

        #expect(host.openTaskTab(UUID(), for: Self.first) == .refused(.stopping))
        _ = host.detach(connection)
        #expect(host.attach(caps: Self.roomy) == nil)
    }

    // MARK: - Availability

    @Test("an attached host reports each change, and nothing that did not move")
    func availabilityIsReportedOnChange() throws {
        let (host, _) = try Self.attached()

        #expect(host.availabilityChanged(.unavailable(.screenLocked)) == .unavailable(.screenLocked))
        #expect(host.availabilityChanged(.unavailable(.screenLocked)) == nil)
        #expect(host.availabilityChanged(.available) == .available)
    }

    /// BROWSER-5: the screen unlocks after `host_stopping`, and a report behind
    /// it would route a new task to a quitting app.
    @Test("no availability is reported after host_stopping")
    func noReportAfterStopping() throws {
        let host = HostUnderTest(.unavailable(.screenLocked))
        _ = host.attach(caps: Self.roomy)
        _ = host.stop()

        #expect(host.availabilityChanged(.available) == nil)
    }

    @Test("a detached host reports nothing and remembers the change")
    func detachedHostRemembers() {
        let host = HostUnderTest(.available)

        #expect(host.availabilityChanged(.unavailable(.displayAsleep)) == nil)
        #expect(host.availability == .unavailable(.displayAsleep))
    }

    @Test("an unavailable host refuses a task's tab and its requests")
    func unavailableRefuses() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)
        _ = host.availabilityChanged(.unavailable(.screenLocked))

        #expect(host.openTaskTab(UUID(), for: Self.first) == .refused(.unavailable(.screenLocked)))
        #expect(host.requestRefusal(for: Self.first, on: tab) == .unavailable(.screenLocked))
    }

    // MARK: - The connection

    /// BROWSER-4: tabs die with their connection, and a new connection starts
    /// with none, so no request of an old task lands on it.
    @Test("a task's requests are refused on a tab the connection no longer holds")
    func requestsBindToTheConnection() throws {
        let (host, connection) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)

        #expect(host.requestRefusal(for: Self.first, on: tab) == nil)
        _ = host.detach(connection)
        let again = try #require(host.attach(caps: Self.roomy))

        #expect(again != connection, "a connection is never numbered twice")
        #expect(host.requestRefusal(for: Self.first, on: tab) == .notTheTasksTab)
        #expect(host.requestRefusal(for: Self.second, on: UUID()) == .notTheTasksTab)
    }

    @Test("a detach of a connection already gone releases nothing")
    func staleDetach() throws {
        let (host, old) = try Self.attached()
        _ = host.detach(old)
        _ = host.attach(caps: Self.roomy)
        let tab = try Self.open(Self.first, in: host)

        #expect(host.detach(old).released.isEmpty)
        #expect(host.owner(of: tab) == .task(Self.first))
    }

    @Test("a detached host takes no task tab")
    func detachedRefuses() {
        let host = HostUnderTest(.available)

        #expect(host.openTaskTab(UUID(), for: Self.first) == .refused(.notAttached))
    }

    @Test("a page closing its own window drops its record and names its owner")
    func pageClosedDropsTheRecord() throws {
        let (host, _) = try Self.attached()
        let tab = try Self.open(Self.first, in: host)

        #expect(host.pageClosed(tab) == .task(Self.first))
        #expect(host.pageClosed(tab) == nil)
        #expect(host.release(Self.first).isEmpty)
    }
}

/// The reducer in a box, so a transition can sit inside an expectation: the
/// testing macros capture their operands, and a value's mutating call cannot
/// be captured. Every method is the reducer's own, forwarded.
@dynamicMemberLookup
final class HostUnderTest {
    private(set) var state: BrowserHostReducer

    init(_ availability: BrowserAvailability) {
        state = BrowserHostReducer(availability: availability)
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<BrowserHostReducer, Value>) -> Value {
        state[keyPath: keyPath]
    }

    func owner(of tab: UUID) -> BrowserTabOwner? { state.owner(of: tab) }
    func requestRefusal(for task: BrowserTaskID, on tab: UUID) -> BrowserTabRefusal? {
        state.requestRefusal(for: task, on: tab)
    }

    func attach(caps: BrowserTabCaps? = nil) -> BrowserHostConnection? { state.attach(caps: caps) }
    func establishCaps(_ caps: BrowserTabCaps) -> Bool { state.establishCaps(caps) }
    func opener(of tab: UUID) -> UUID? { state.opener(of: tab) }
    func detach(_ gone: BrowserHostConnection) -> BrowserHostDetach { state.detach(gone) }
    func availabilityChanged(_ now: BrowserAvailability) -> BrowserAvailability? { state.availabilityChanged(now) }
    func openTaskTab(_ tab: UUID, for task: BrowserTaskID) -> BrowserTabAdmission { state.openTaskTab(tab, for: task) }
    func openPopup(_ tab: UUID, from opener: UUID) -> BrowserTabAdmission { state.openPopup(tab, from: opener) }
    func openPersonTab(_ tab: UUID) { state.openPersonTab(tab) }
    func personClose(_ tab: UUID) -> BrowserPersonClose { state.personClose(tab) }
    func cancel(_ task: BrowserTaskID) -> Bool { state.cancel(task) }
    func release(_ task: BrowserTaskID) -> Set<UUID> { state.release(task) }
    func pageClosed(_ tab: UUID) -> BrowserTabOwner? { state.pageClosed(tab) }
    func releaseIdle() -> Bool { state.releaseIdle() }
    func stop() -> BrowserHostStop { state.stop() }
    func endQuitHold() -> Bool { state.endQuitHold() }
}
