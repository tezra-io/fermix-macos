import Foundation

/// A task the engine runs on the pane's tabs, by the id the host wire names it
/// with.
public struct BrowserTaskID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "a task is named")

        self.rawValue = rawValue
    }
}

/// Who a tab belongs to (spec `browser_host`, BROWSER-3): the person who opened
/// it in the pane, or the task that opened it over the wire. A popup is its
/// opener's.
public enum BrowserTabOwner: Hashable, Sendable {
    case person
    case task(BrowserTaskID)

    public var task: BrowserTaskID? {
        guard case .task(let task) = self else { return nil }

        return task
    }
}

/// The engine's live-tab caps. They count task tabs only: the person's tabs
/// never block a task, and a task never closes a tab to make room.
public struct BrowserTabCaps: Equatable, Sendable {
    public let perTask: Int
    public let global: Int

    public init(perTask: Int, global: Int) {
        precondition(perTask > 0 && global >= perTask, "a task may hold a tab, and never more than all tasks")

        self.perTask = perTask
        self.global = global
    }

    /// From `tab.open`'s own `task_tab_cap`/`tab_cap`: nil for a pair the
    /// contract's own bounds do not actually rule out on the wire (zero,
    /// negative, or a task cap past the global one), which is refused rather
    /// than let crash the precondition above.
    public init?(taskTabCap: Int, tabCap: Int) {
        guard taskTabCap > 0, tabCap >= taskTabCap else { return nil }

        self.init(perTask: taskTabCap, global: tabCap)
    }
}

/// One connection to the daemon's `browser_host.sock`, numbered by the host
/// as it attaches and never reused in this process, so a task's tabs are bound
/// to the connection they were opened on (BROWSER-4).
public struct BrowserHostConnection: Hashable, Sendable {
    let number: Int
}

/// Why the pane's tabs cannot be driven now. One reason is reported, the
/// weightiest standing.
public enum BrowserUnavailableReason: String, CaseIterable, Sendable {
    case appTerminating = "app_terminating"
    case screenLocked = "screen_locked"
    case displayAsleep = "display_asleep"
}

/// What the host reports as `availability { available, reason }`.
public enum BrowserAvailability: Equatable, Sendable {
    case available
    case unavailable(BrowserUnavailableReason)
}

/// Why a task's request, or a tab a page opened, was refused rather than
/// queued.
public enum BrowserTabRefusal: Error, Equatable, Sendable {
    case notAttached
    case stopping
    case unavailable(BrowserUnavailableReason)
    case taskCap
    case globalCap
    /// A popup whose opener no longer has a record, or a request naming a tab
    /// that is not the task's.
    case notTheTasksTab
    /// The website profile could not be read, so there is no engine to build a
    /// page on. The coordinator's, before the registry is asked.
    case websiteDataUnreadable
}

/// Whether a tab was taken, and whose it is.
public enum BrowserTabAdmission: Equatable, Sendable {
    case admitted(BrowserTabOwner)
    case refused(BrowserTabRefusal)
}

/// What the person's close of a tab comes to.
public enum BrowserPersonClose: Equatable, Sendable {
    /// Their own tab: it closes and its record goes.
    case close
    /// A task's tab is never closed by the person; the task may be cancelled
    /// instead, which releases it.
    case cancelTask(BrowserTaskID)
}

/// Where a quit stands, from the host's side.
public enum BrowserQuitHold: Equatable, Sendable {
    case none
    /// `host_stopping` went out and the quit waits for its answer or its bound.
    case holding
    /// The quit may complete.
    case ended
}

/// What a quit asks of the host.
public enum BrowserHostStop: Equatable, Sendable {
    /// Attached: every task tab released, `host_stopping` to send, and the quit
    /// held until the daemon answers or the bound elapses.
    case hold(released: Set<BrowserTab.ID>)
    /// Not attached: every task tab released, and nobody to tell.
    case complete(released: Set<BrowserTab.ID>)
}

/// What losing the daemon releases.
public struct BrowserHostDetach: Equatable, Sendable {
    public let released: Set<BrowserTab.ID>
    /// A held quit ends on losing the daemon: the answer can no longer come,
    /// which is the bound at zero (BROWSER-7).
    public let endsQuit: Bool
}

/// The host's own state, as the `browser_host` spec models the app
/// (`tla/specs/browser_host`, the unpinned mirror): the ownership registry,
/// the caps, the connection the task tabs belong to, the tasks the person
/// asked to cancel, the availability last reported, whether web views are
/// held, and the quit hold. Beside the spec's state, the directory each
/// task's downloads go into.
///
/// Pure: every transition is a value in and a decision out, and the
/// coordinator carries the decision to the tabs, the wire and the window. Its
/// tests are named after the spec's rules.
public struct BrowserHostReducer: Equatable, Sendable {
    /// The connection attached now and the caps it announced. Task tabs exist
    /// only while it does.
    public private(set) var connection: BrowserHostConnection?
    public private(set) var caps: BrowserTabCaps?
    /// The registry: every live tab's owner. A record goes at the tab's first
    /// release or close, so a second finds nothing (BROWSER-2).
    public private(set) var owners: [BrowserTab.ID: BrowserTabOwner] = [:]
    /// A popup's opener, for as long as the popup lives. Absent for a tab
    /// nothing opened, which is every tab but a popup.
    public private(set) var openers: [BrowserTab.ID: BrowserTab.ID] = [:]
    /// The tasks the person asked to cancel whose release has not arrived.
    public private(set) var pendingRelease: Set<BrowserTaskID> = []
    /// Where each task's downloads go, its tabs' popups included: the
    /// `download_dir` its latest `tab.open` named. It goes with the task's
    /// last tab.
    public private(set) var downloadDirectories: [BrowserTaskID: URL] = [:]
    public private(set) var availability: BrowserAvailability
    /// Whether the host holds web views, which the idle release lets go.
    public private(set) var viewsHeld = false
    public private(set) var quit: BrowserQuitHold = .none
    private var connections = 0

    public init(availability: BrowserAvailability) {
        self.availability = availability
    }

    // MARK: - Queries

    public func owner(of tab: BrowserTab.ID) -> BrowserTabOwner? {
        owners[tab]
    }

    /// The tab that opened this one, for a popup still alive; nil for every
    /// other tab, a popup whose own record has gone included.
    public func opener(of tab: BrowserTab.ID) -> BrowserTab.ID? {
        openers[tab]
    }

    public var taskTabCount: Int {
        owners.values.filter { $0.task != nil }.count
    }

    public func tabCount(of task: BrowserTaskID) -> Int {
        owners.values.filter { $0 == .task(task) }.count
    }

    public func downloadDirectory(of task: BrowserTaskID) -> URL? {
        downloadDirectories[task]
    }

    /// Why a task's request on a tab (`page.act`, `page.snapshot` and the rest)
    /// is refused, or nil where the host carries it out.
    public func requestRefusal(for task: BrowserTaskID, on tab: BrowserTab.ID) -> BrowserTabRefusal? {
        guard quit == .none else { return .stopping }
        guard connection != nil else { return .notAttached }
        if case .unavailable(let reason) = availability { return .unavailable(reason) }
        guard owners[tab] == .task(task) else { return .notTheTasksTab }

        return nil
    }

    // MARK: - The connection

    /// A connection attached. A quitting host attaches no more: stopping is
    /// final for it (BROWSER-5). `caps` is for a caller that already knows
    /// them; the `browser_host` wire client attaches with none and lets the
    /// first `tab.open` establish them (`establishCaps`).
    public mutating func attach(caps: BrowserTabCaps? = nil) -> BrowserHostConnection? {
        guard quit == .none else { return nil }
        precondition(connection == nil, "a host attaches once per connection")

        connections += 1
        let attached = BrowserHostConnection(number: connections)
        connection = attached
        self.caps = caps

        return attached
    }

    /// `tab.open`'s own `task_tab_cap`/`tab_cap` become this connection's for
    /// its life, the first time they arrive; a later `tab.open` naming
    /// different ones is refused rather than silently adopted. False where
    /// there is nothing to establish them on, or where they changed.
    public mutating func establishCaps(_ proposed: BrowserTabCaps) -> Bool {
        guard connection != nil else { return false }
        guard let caps else {
            self.caps = proposed
            return true
        }

        return caps == proposed
    }

    /// The daemon went away: every task tab is released and the person's stay.
    /// A report of a connection already gone releases nothing.
    public mutating func detach(_ gone: BrowserHostConnection) -> BrowserHostDetach {
        guard connection == gone else { return BrowserHostDetach(released: [], endsQuit: false) }

        connection = nil
        caps = nil
        pendingRelease = []
        let released = drop { $0.task != nil }
        guard quit == .holding else { return BrowserHostDetach(released: released, endsQuit: false) }

        quit = .ended
        return BrowserHostDetach(released: released, endsQuit: true)
    }

    /// The session's availability moved. Answers the report to send: none
    /// while detached, none once stopping (BROWSER-5), none when nothing moved.
    public mutating func availabilityChanged(_ now: BrowserAvailability) -> BrowserAvailability? {
        guard now != availability else { return nil }

        availability = now
        guard connection != nil, quit == .none else { return nil }

        return now
    }

    // MARK: - Tabs

    /// `tab.open`: the task's tab, unless the host is stopping, detached or
    /// unavailable, or the tab would pass a cap. Refused, never queued. The
    /// directory it names is where the task's downloads go from now on.
    public mutating func openTaskTab(
        _ tab: BrowserTab.ID,
        for task: BrowserTaskID,
        downloadDirectory: URL
    ) -> BrowserTabAdmission {
        guard quit == .none else { return .refused(.stopping) }
        guard let caps else { return .refused(.notAttached) }
        if case .unavailable(let reason) = availability { return .refused(.unavailable(reason)) }
        if let refusal = capRefusal(for: task, caps: caps) { return .refused(refusal) }

        downloadDirectories[task] = downloadDirectory
        return register(tab, .task(task))
    }

    /// A page opened a window of its own. The popup is its opener's owner's in
    /// this same step, and counted under that task's caps, where it is blocked
    /// at a cap (BROWSER-3). A popup from the person's tab is the person's.
    /// Its opener is kept regardless of whose it is, so `tab.list` can carry
    /// it (BROWSER-8).
    public mutating func openPopup(_ tab: BrowserTab.ID, from opener: BrowserTab.ID) -> BrowserTabAdmission {
        guard let owner = owners[opener] else { return .refused(.notTheTasksTab) }
        guard let task = owner.task else { return register(tab, .person, opener: opener) }
        guard let caps else { return .refused(.notAttached) }
        if let refusal = capRefusal(for: task, caps: caps) { return .refused(refusal) }

        return register(tab, owner, opener: opener)
    }

    /// A tab the person opened is theirs.
    public mutating func openPersonTab(_ tab: BrowserTab.ID) {
        _ = register(tab, .person)
    }

    /// The person asked to close a tab. Their own closes; a task's stays, and
    /// the answer is to cancel the task (`PersonCannotCloseTaskTab`).
    public mutating func personClose(_ tab: BrowserTab.ID) -> BrowserPersonClose {
        guard let task = owners[tab]?.task else {
            owners[tab] = nil
            openers[tab] = nil
            return .close
        }

        return .cancelTask(task)
    }

    /// The person cancels a task from its tab. True the first time, which is
    /// when the cancel is sent; its tabs stay until the task's release.
    public mutating func cancel(_ task: BrowserTaskID) -> Bool {
        guard owners.values.contains(.task(task)) else { return false }

        return pendingRelease.insert(task).inserted
    }

    /// `task.release`: exactly the task's tabs, popups included, once. A second
    /// release, or one after the host already released them, finds nothing.
    public mutating func release(_ task: BrowserTaskID) -> Set<BrowserTab.ID> {
        pendingRelease.remove(task)

        return drop { $0 == .task(task) }
    }

    /// A page closed its own window. Its record goes, and its owner is
    /// answered so a task's closed tab can be told to the daemon.
    public mutating func pageClosed(_ tab: BrowserTab.ID) -> BrowserTabOwner? {
        openers[tab] = nil
        let owner = owners.removeValue(forKey: tab)
        forgetTasksWithoutTabs()

        return owner
    }

    /// The idle release. It reads the registry in the step that releases, so a
    /// timer armed when the host went idle finds any tab opened since and lets
    /// nothing go (BROWSER-3). True where the web views may go.
    public mutating func releaseIdle() -> Bool {
        guard quit == .none, viewsHeld, owners.isEmpty else { return false }

        viewsHeld = false
        return true
    }

    // MARK: - Quit

    /// The person, the Dock, a log out or a signal asked the app to quit.
    /// Every task tab is released now, and an attached host holds the quit for
    /// the daemon's answer to `host_stopping`.
    public mutating func stop() -> BrowserHostStop {
        precondition(quit == .none, "one quit is enough")

        pendingRelease = []
        let released = drop { $0.task != nil }
        guard connection != nil else {
            quit = .ended
            return .complete(released: released)
        }

        quit = .holding
        return .hold(released: released)
    }

    /// The daemon answered `host_stopping`, or the quit's bound elapsed: the
    /// first ends the hold and the second finds it ended (BROWSER-7). True
    /// where this ended it.
    public mutating func endQuitHold() -> Bool {
        guard quit == .holding else { return false }

        quit = .ended
        connection = nil
        caps = nil
        return true
    }

    // MARK: - Mechanics

    private func capRefusal(for task: BrowserTaskID, caps: BrowserTabCaps) -> BrowserTabRefusal? {
        if tabCount(of: task) >= caps.perTask { return .taskCap }
        if taskTabCount >= caps.global { return .globalCap }

        return nil
    }

    private mutating func register(_ tab: BrowserTab.ID, _ owner: BrowserTabOwner, opener: BrowserTab.ID? = nil) -> BrowserTabAdmission {
        precondition(owners[tab] == nil, "a tab is registered once")

        owners[tab] = owner
        openers[tab] = opener
        viewsHeld = true
        return .admitted(owner)
    }

    private mutating func drop(where matches: (BrowserTabOwner) -> Bool) -> Set<BrowserTab.ID> {
        let released = Set(owners.filter { matches($0.value) }.keys)
        for tab in released {
            owners[tab] = nil
            openers[tab] = nil
        }
        forgetTasksWithoutTabs()

        return released
    }

    /// A task's download directory goes with its last tab.
    private mutating func forgetTasksWithoutTabs() {
        downloadDirectories = downloadDirectories.filter { task, _ in owners.values.contains(.task(task)) }
    }
}
