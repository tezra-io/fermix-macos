import Combine
import Foundation

/// The one owner of the browser pane (plan §4.3 to §4.5, §4.10): which tabs
/// exist and whose each is, which one shows, whether the pane is open, where
/// each page is on screen, and everything a page asks of the person.
///
/// The pane draws `model` and asks this for everything it wants done. The
/// engine is built on the first tab, over the website profile the record
/// keeps, so a person who never opens the pane never has one written.
///
/// Closing the pane hides it and keeps its tabs: a link opened later lands
/// beside them, as a link opened in a browser lands in the window already
/// there. Closing the last tab closes the pane.
///
/// The host's side of the daemon's `browser_host` wire runs through here too:
/// a task's tabs, their release, the availability the host reports and its
/// part of a quit, each decided by `BrowserHostReducer` and carried out here.
@MainActor
public final class BrowserCoordinator {
    /// How long a quit waits for the daemon's answer to `host_stopping`.
    public static let quitBound: TimeInterval = 2

    public let model: BrowserModel

    private let makeEngine: BrowserEngineMaking
    private let profile: WebsiteProfileRecord
    private let workspace: any WorkspaceLinkOpening
    private let session: any SessionAvailabilityReporting
    /// The quit's bound. A run-loop timer in the product, because main-actor
    /// work can starve while AppKit holds a termination.
    private let deadlines: any DeadlineScheduling
    /// The window's half of opening and closing the pane: the room beside the
    /// body, which `WindowCoordinator.setBrowserPane(open:)` owns.
    private let paneShown: (Bool) -> Void
    /// The primary window's own present path (`WindowCoordinator.show(.main)`):
    /// idempotent, and what a visible task's `tab.open` uses to come to the
    /// front even where the app launched hidden (plan §4.0's `--background`).
    private let presentPrimaryWindow: () -> Void
    private var engine: (any BrowserEngine)?
    /// The daemon's end of the attached connection, where there is one.
    private var link: (any BrowserHostLink)?
    private var availabilityChanges: AnyCancellable?
    private var quitDone: (@MainActor () -> Void)?
    private var quitBoundToken: DeadlineToken?

    /// The pane's page area, while SwiftUI has one built.
    private weak var paneStage: (any BrowserPageStage)?
    /// Whether the primary window is on screen: open, and not covered,
    /// minimised or on another Space.
    private var windowVisible = false
    /// Whether the system's file chooser is up for a page's upload field: the
    /// pane's one popup while it is, as a page's dialog is.
    private var choosingFiles = false
    /// Where each tab's page is now.
    private var placed: [BrowserTab.ID: BrowserPagePlace] = [:]

    public init(
        makeEngine: @escaping BrowserEngineMaking,
        profile: WebsiteProfileRecord,
        workspace: any WorkspaceLinkOpening,
        session: any SessionAvailabilityReporting,
        deadlines: any DeadlineScheduling,
        paneShown: @escaping (Bool) -> Void,
        presentPrimaryWindow: @escaping () -> Void
    ) {
        self.model = BrowserModel()
        self.makeEngine = makeEngine
        self.profile = profile
        self.workspace = workspace
        self.session = session
        self.deadlines = deadlines
        self.paneShown = paneShown
        self.presentPrimaryWindow = presentPrimaryWindow
        availabilityChanges = session.changes.sink { [weak self] availability in
            self?.availabilityChanged(availability)
        }
    }

    // MARK: - Opening

    /// A link, in a new tab of the shared profile, in front.
    public func open(_ url: URL) {
        guard let tab = makePersonTab(.shared) else { return }

        add(tab)
        tab.load(url)
    }

    /// A blank tab, with the caret in the address field.
    public func newTab(profile: BrowserProfile) {
        guard let tab = makePersonTab(profile) else { return }

        add(tab)
        focusAddress()
    }

    public func focusAddress() {
        model.addressFocusRequests += 1
    }

    /// What the person typed in the address field, in the tab in front, or in
    /// a new tab where none is.
    public func load(address: String) {
        guard let url = BrowserAddress.url(from: address) else {
            model.notice = ProductStrings[.browserNoticeNotAnAddress]
            return
        }
        guard let tab = model.selectedTab else {
            open(url)
            return
        }

        model.notice = nil
        tab.load(url)
    }

    // MARK: - Tabs and the pane

    public func select(_ tab: BrowserTab) {
        model.notice = nil
        model.selectedTabID = tab.id
        placePages()
    }

    /// The person closes a tab. Their own closes; a task's is not theirs to
    /// close, and the gesture cancels the task instead, whose release then
    /// takes the tab.
    public func close(_ tab: BrowserTab) {
        switch model.host.personClose(tab.id) {
        case .close: remove([tab.id])
        case .cancelTask(let task): cancel(task)
        }
    }

    /// The person cancels the task a tab belongs to. Sent once, however often
    /// it is asked for, and the tab stays until the task's release.
    public func cancel(_ task: BrowserTaskID) {
        guard model.host.cancel(task) else { return }

        link?.cancelTask(task)
    }

    /// Opens the pane, on an empty page where it holds no tab: "Show browser",
    /// so the person can watch or browse without waiting for a link.
    public func showPane() {
        guard !model.isOpen else { return }

        model.isOpen = true
        paneShown(true)
        placePages()
    }

    /// Hides the pane and keeps its tabs. A dialog waiting over the pane is
    /// answered as dismissed, because nobody can see it to answer it.
    public func closePane() {
        guard model.isOpen else { return }

        answer(.dismissed)
        model.notice = nil
        model.isOpen = false
        paneShown(false)
        placePages()
    }

    /// The page in front, in the person's own browser.
    public func openInSystemBrowser() {
        guard let url = model.selectedTab?.url else { return }

        openOutside(url)
    }

    /// The person's answer to the dialog over the pane.
    public func answer(_ answer: BrowserDialogAnswer) {
        guard let request = model.dialog else { return }

        model.dialog = nil
        request.answer(answer)
    }

    // MARK: - Where the pages are

    /// The pane built its page area. Pages that stood in one it replaced are
    /// placed again.
    public func paneStageAppeared(_ stage: any BrowserPageStage) {
        forgetPanePlacements(releasingFrom: paneStage)
        paneStage = stage
        placePages()
    }

    /// The pane's page area is gone. Its pages go where the rules say now.
    public func paneStageGone(_ stage: any BrowserPageStage) {
        guard paneStage === stage else { return }

        paneStage = nil
        forgetPanePlacements(releasingFrom: stage)
        placePages()
    }

    /// The primary window's occlusion moved, as the window host reports it.
    public func windowVisibilityChanged(_ visible: Bool) {
        guard visible != windowVisible else { return }

        windowVisible = visible
        placePages()
    }

    // MARK: - The host

    /// The wire client attached. The first availability report goes at once.
    /// `caps` is nil for the `browser_host` wire client, which learns them
    /// from the first `tab.open` (`establishTabCaps`) rather than a build
    /// constant.
    public func hostAttached(_ link: any BrowserHostLink, caps: BrowserTabCaps?) -> BrowserHostConnection? {
        guard let connection = model.host.attach(caps: caps) else { return nil }

        self.link = link
        link.reportAvailability(model.host.availability)
        return connection
    }

    /// `tab.open`'s own caps, adopted for the connection's life the first
    /// time they arrive. False where a later `tab.open` names different
    /// ones, which the wire client answers as a refusal rather than a quiet
    /// change of policy mid-connection.
    public func establishTabCaps(_ caps: BrowserTabCaps) -> Bool {
        model.host.establishCaps(caps)
    }

    /// The connection is gone: every task's tabs are released, and a quit
    /// waiting on its answer completes.
    public func hostDetached(_ connection: BrowserHostConnection) {
        guard model.host.connection == connection else { return }

        link = nil
        let detach = model.host.detach(connection)
        remove(detach.released)
        if detach.endsQuit { finishQuit() }
    }

    /// `tab.open`: a tab of the shared profile, the task's, loading `url`. A
    /// task that is not visible never opens the pane: it comes to the front
    /// only of a pane with nothing in front. A visible task is what "launch
    /// the browser" means, so it opens the pane, the "Show browser" path, and
    /// brings the primary window up too, in case the app launched hidden.
    public func openTaskTab(_ url: URL, for task: BrowserTaskID, visible: Bool = false) -> Result<BrowserTab.ID, BrowserTabRefusal> {
        let engine: any BrowserEngine
        do {
            engine = try builtEngine()
        } catch {
            return .failure(.websiteDataUnreadable)
        }

        let tab = engine.makeTab(profile: .shared)
        if case .refused(let refusal) = model.host.openTaskTab(tab.id, for: task) { return .failure(refusal) }

        tab.delegate = self
        insert(tab, after: nil)
        if model.selectedTabID == nil {
            select(tab)
        } else {
            placePages()
        }
        tab.load(url)
        if visible {
            showPane()
            presentPrimaryWindow()
        }
        return .success(tab.id)
    }

    /// `task.release`: exactly the task's tabs, once.
    public func releaseTask(_ task: BrowserTaskID) {
        remove(model.host.release(task))
    }

    /// `tab.close`: one of the host's own tabs, closed directly. Unlike
    /// `close(_:)`, which is the person's gesture on their own tab and
    /// cancels a task's rather than closing it, the daemon closes one of its
    /// own tabs outright. The wire client checks first that the tab is not
    /// the person's; this is what carries out the close once it has.
    public func closeTaskTab(_ tab: BrowserTab.ID) {
        remove([tab])
    }

    /// The engine's idle period has passed. The registry decides now whether
    /// the host holds no tab of anyone's, so a period that began idle and saw a
    /// tab open since lets nothing go.
    public func releaseIdle() {
        guard model.host.releaseIdle() else { return }

        engine?.releaseIdle()
    }

    // MARK: - Mechanics

    /// A tab the person asked for, registered as theirs.
    private func makePersonTab(_ profile: BrowserProfile) -> BrowserTab? {
        guard let engine = resolvedEngine() else { return nil }

        let tab = engine.makeTab(profile: profile)
        tab.delegate = self
        model.host.openPersonTab(tab.id)

        return tab
    }

    /// The engine, for something the person asked for. A profile that cannot
    /// be read opens the pane on the sentence that says so, rather than a link
    /// that silently went nowhere.
    private func resolvedEngine() -> (any BrowserEngine)? {
        do {
            return try builtEngine()
        } catch {
            model.notice = ProductStrings[.browserNoticeProfileUnavailable]
            showPane()
            return nil
        }
    }

    /// The engine, built over the website profile on first use.
    private func builtEngine() throws -> any BrowserEngine {
        if let engine { return engine }

        let built = makeEngine(try profile.identifier())
        engine = built
        return built
    }

    /// A tab beside its opener, or at the end, in front, with the pane open.
    private func add(_ tab: BrowserTab, after opener: BrowserTab? = nil) {
        insert(tab, after: opener)
        select(tab)
        showPane()
    }

    private func insert(_ tab: BrowserTab, after opener: BrowserTab?) {
        let index = opener.flatMap { opener in model.tabs.firstIndex { $0.id == opener.id } }
        model.tabs.insert(tab, at: index.map { $0 + 1 } ?? model.tabs.count)
    }

    /// Takes tabs out together, as one close or one task's release, so no page
    /// is placed while a tab that is going is still listed. The tab in front
    /// goes to its nearest neighbour that stays, and the last tab takes the
    /// pane with it.
    private func remove(_ going: Set<BrowserTab.ID>) {
        let tabs = model.tabs
        let front = tabs.firstIndex { $0.id == model.selectedTabID }
        for tab in tabs where going.contains(tab.id) {
            retire(tab)
        }
        model.tabs.removeAll { going.contains($0.id) }
        guard let last = model.tabs.last else {
            model.selectedTabID = nil
            closePane()
            return
        }
        guard let front, going.contains(tabs[front].id) else { return }

        select(tabs[(front + 1)...].first { !going.contains($0.id) } ?? last)
    }

    /// A tab that is going answers any dialog its page is waiting on, and its
    /// page answers anything it asks from now on by itself.
    private func retire(_ tab: BrowserTab) {
        if model.dialog?.tabID == tab.id { answer(.dismissed) }
        tab.delegate = nil
        tab.stop()
        unplace(tab)
    }

    private func openOutside(_ url: URL) {
        guard !workspace.open(url) else { return }

        model.notice = ProductStrings[.browserNoticeNoApp]
    }

    /// Only the page in front, in an open pane, may ask the person anything,
    /// and only while nothing else is asking, so a popup never stacks.
    private func mayAsk(from tab: BrowserTab) -> Bool {
        model.isOpen && model.selectedTabID == tab.id && model.dialog == nil && !choosingFiles
    }

    private func availabilityChanged(_ availability: BrowserAvailability) {
        guard let report = model.host.availabilityChanged(availability) else { return }

        link?.reportAvailability(report)
    }

    private func quitHoldEnded() {
        guard model.host.endQuitHold() else { return }

        finishQuit()
    }

    private func finishQuit() {
        quitBoundToken?.cancel()
        quitBoundToken = nil
        link = nil
        let done = quitDone
        quitDone = nil
        done?()
    }

    // MARK: - Placement

    private var paneVisibility: BrowserPaneVisibility {
        guard model.isOpen, paneStage != nil else { return .hidden }

        return windowVisible ? .onScreen : .covered
    }

    /// Puts every page where `BrowserPagePlace` says, moving only the ones
    /// whose place changed.
    private func placePages() {
        let pane = paneVisibility
        for tab in model.tabs {
            let place = BrowserPagePlace.of(owner: owner(of: tab), inFront: tab.id == model.selectedTabID, pane: pane)
            move(tab, to: place)
        }
    }

    private func move(_ tab: BrowserTab, to place: BrowserPagePlace) {
        let from = placed[tab.id] ?? .nowhere
        guard from != place else { return }

        stage(for: from)?.release(tab.view)
        stage(for: place)?.hold(tab.view)
        placed[tab.id] = place
    }

    private func unplace(_ tab: BrowserTab) {
        move(tab, to: .nowhere)
        placed[tab.id] = nil
    }

    /// The pages that stood in a page area that is going, or already gone.
    private func forgetPanePlacements(releasingFrom stage: (any BrowserPageStage)?) {
        for tab in model.tabs where placed[tab.id] == .pane {
            stage?.release(tab.view)
            placed[tab.id] = .nowhere
        }
    }

    private func stage(for place: BrowserPagePlace) -> (any BrowserPageStage)? {
        switch place {
        case .pane: return paneStage
        case .hostWindow: return engine?.hostWindow
        case .nowhere: return nil
        }
    }

    /// Every tab in the pane has a record, from the step that made it.
    private func owner(of tab: BrowserTab) -> BrowserTabOwner {
        guard let owner = model.host.owner(of: tab.id) else {
            preconditionFailure("a tab in the pane has no owner on record")
        }

        return owner
    }
}

extension BrowserCoordinator: BrowserHostQuitting {
    /// Reports the app terminating while it still may, then releases every
    /// task tab and, attached, sends `host_stopping` and holds the quit until
    /// the answer or the bound, whichever comes first (BROWSER-7).
    public func stopHost(done: @escaping @MainActor () -> Void) {
        session.applicationTerminating()

        switch model.host.stop() {
        case .complete(let released):
            remove(released)
            done()
        case .hold(let released):
            remove(released)
            quitDone = done
            quitBoundToken = deadlines.schedule(after: Self.quitBound) { [weak self] in
                self?.quitHoldEnded()
            }
            link?.sendHostStopping { [weak self] in
                self?.quitHoldEnded()
            }
        }
    }
}

extension BrowserCoordinator: BrowserTabDelegate {
    /// A page's own window. The person's lands beside its opener and comes to
    /// the front, which is where a sign-in window has to be to be answered. A
    /// task's lands beside its opener too and counts under the task's caps,
    /// where it is refused at a cap, which the page sees as a blocked popup.
    public func newTabRequested(_ tab: BrowserTab, from opener: BrowserTab) -> Bool {
        switch model.host.openPopup(tab.id, from: opener.id) {
        case .refused:
            return false
        case .admitted(.person):
            tab.delegate = self
            add(tab, after: opener)
        case .admitted(.task):
            tab.delegate = self
            insert(tab, after: opener)
            placePages()
        }

        return true
    }

    /// A page closed its own window. A task's closed tab is told to the
    /// daemon, which never otherwise hears of it.
    public func closeRequested(by tab: BrowserTab) {
        if let task = model.host.pageClosed(tab.id)?.task {
            link?.tabClosed(tab.id, task: task)
        }

        remove([tab.id])
    }

    /// A page's upload field. The person's own tab gets the system's file
    /// chooser, on the same terms as a page's dialog. A task's tab gets none:
    /// a task uploads only through `page.upload`, which is confined to the
    /// engine's workspace.
    public func filesRequested(
        _ request: BrowserFileRequest,
        in tab: BrowserTab,
        answer: @escaping @MainActor ([URL]?) -> Void
    ) {
        guard model.host.owner(of: tab.id) == .person, mayAsk(from: tab), let engine else {
            answer(nil)
            return
        }

        choosingFiles = true
        engine.chooseFiles(request, for: tab.view) { [weak self] files in
            self?.choosingFiles = false
            answer(files)
        }
    }

    public func externalSchemeMet(_ url: URL) {
        openOutside(url)
    }

    /// Shown where the page may ask (`mayAsk`); every other dialog is
    /// dismissed at once.
    public func dialogPresented(
        _ dialog: BrowserDialog,
        in tab: BrowserTab,
        answer: @escaping @MainActor (BrowserDialogAnswer) -> Void
    ) {
        guard mayAsk(from: tab) else {
            answer(.dismissed)
            return
        }

        model.dialog = BrowserDialogRequest(dialog: dialog, tabID: tab.id, answer: answer)
    }

    public func downloadStarted(_ url: URL) {
        model.notice = ProductStrings[.browserNoticeDownloadRefused]
    }

    /// The system's sentence, for the tab in front only: a tab behind it has
    /// nothing on screen for the sentence to be about.
    public func loadFailed(_ reason: String, in tab: BrowserTab) {
        guard model.selectedTabID == tab.id else { return }

        model.notice = reason
    }
}

/// The wire client's seam onto this coordinator (`BrowserHostClient.swift`),
/// which the methods above already answer exactly.
extension BrowserCoordinator: BrowserHostCoordinating {}
