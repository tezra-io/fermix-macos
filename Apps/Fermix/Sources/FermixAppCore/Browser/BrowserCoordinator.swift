import Foundation

/// The one owner of the browser pane (plan §4.3 to §4.5): which tabs exist,
/// which one shows, whether the pane is open, and everything a page asks of
/// the person.
///
/// The pane draws `model` and asks this for everything it wants done. The
/// engine is built on the first tab, over the website profile the record
/// keeps, so a person who never opens the pane never has one written.
///
/// Closing the pane hides it and keeps its tabs: a link opened later lands
/// beside them, as a link opened in a browser lands in the window already
/// there. Closing the last tab closes the pane.
@MainActor
public final class BrowserCoordinator {
    public let model: BrowserModel

    private let makeEngine: BrowserEngineMaking
    private let profile: WebsiteProfileRecord
    private let workspace: any WorkspaceLinkOpening
    /// The window's half of opening and closing the pane: the room beside the
    /// body, which `WindowCoordinator.setBrowserPane(open:)` owns.
    private let paneShown: (Bool) -> Void
    private var engine: (any BrowserEngine)?

    public init(
        makeEngine: @escaping BrowserEngineMaking,
        profile: WebsiteProfileRecord,
        workspace: any WorkspaceLinkOpening,
        paneShown: @escaping (Bool) -> Void
    ) {
        self.model = BrowserModel()
        self.makeEngine = makeEngine
        self.profile = profile
        self.workspace = workspace
        self.paneShown = paneShown
    }

    // MARK: - Opening

    /// A link, in a new tab of the shared profile, in front.
    public func open(_ url: URL) {
        guard let tab = makeTab(.shared) else { return }

        add(tab)
        tab.load(url)
    }

    /// A blank tab, with the caret in the address field.
    public func newTab(profile: BrowserProfile) {
        guard let tab = makeTab(profile) else { return }

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
    }

    /// Closes a tab, answering any dialog its page is waiting on. The tab in
    /// front goes to its neighbour, and the last tab takes the pane with it.
    public func close(_ tab: BrowserTab) {
        guard let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        if model.dialog?.tabID == tab.id { answer(.dismissed) }
        // A page that is going answers anything it asks from now on by itself.
        tab.delegate = nil
        tab.stop()
        model.tabs.remove(at: index)
        guard !model.tabs.isEmpty else {
            model.selectedTabID = nil
            closePane()
            return
        }
        guard model.selectedTabID == tab.id else { return }

        select(model.tabs[min(index, model.tabs.count - 1)])
    }

    /// Hides the pane and keeps its tabs. A dialog waiting over the pane is
    /// answered as dismissed, because nobody can see it to answer it.
    public func closePane() {
        guard model.isOpen else { return }

        answer(.dismissed)
        model.notice = nil
        model.isOpen = false
        paneShown(false)
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

    // MARK: - Mechanics

    private func makeTab(_ profile: BrowserProfile) -> BrowserTab? {
        guard let engine = resolvedEngine() else { return nil }

        let tab = engine.makeTab(profile: profile)
        tab.delegate = self

        return tab
    }

    /// The engine, built over the website profile on first use. A profile that
    /// cannot be read opens the pane on the sentence that says so, rather than
    /// a link that silently went nowhere.
    private func resolvedEngine() -> (any BrowserEngine)? {
        if let engine { return engine }

        do {
            let built = makeEngine(try profile.identifier())
            engine = built
            return built
        } catch {
            model.notice = ProductStrings[.browserNoticeProfileUnavailable]
            showPane()
            return nil
        }
    }

    private func add(_ tab: BrowserTab, after opener: BrowserTab? = nil) {
        let index = opener.flatMap { opener in model.tabs.firstIndex { $0.id == opener.id } }
        model.tabs.insert(tab, at: index.map { $0 + 1 } ?? model.tabs.count)
        select(tab)
        showPane()
    }

    private func showPane() {
        guard !model.isOpen else { return }

        model.isOpen = true
        paneShown(true)
    }

    private func openOutside(_ url: URL) {
        guard !workspace.open(url) else { return }

        model.notice = ProductStrings[.browserNoticeNoApp]
    }
}

extension BrowserCoordinator: BrowserTabDelegate {
    /// A page's own window lands beside its opener and comes to the front,
    /// which is where a sign-in window has to be to be answered.
    public func newTabRequested(_ tab: BrowserTab, from opener: BrowserTab) -> Bool {
        tab.delegate = self
        add(tab, after: opener)

        return true
    }

    public func closeRequested(by tab: BrowserTab) {
        close(tab)
    }

    public func externalSchemeMet(_ url: URL) {
        openOutside(url)
    }

    /// Only the page in front, in an open pane, may ask the person anything,
    /// and only one at a time; every other dialog is dismissed at once.
    public func dialogPresented(
        _ dialog: BrowserDialog,
        in tab: BrowserTab,
        answer: @escaping @MainActor (BrowserDialogAnswer) -> Void
    ) {
        guard model.isOpen, model.selectedTabID == tab.id, model.dialog == nil else {
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
