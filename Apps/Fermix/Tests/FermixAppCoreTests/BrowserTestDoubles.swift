import AppKit
import Foundation

@testable import FermixAppCore

/// A page with no web engine behind it: it records what it was asked, and the
/// test speaks for it through `events`.
@MainActor
final class FakeBrowserPage: BrowserPage {
    weak var events: (any BrowserPageEvents)?
    private(set) var loaded: [URL] = []
    private(set) var actions: [String] = []

    /// Built on first use, so a test that never shows the page never makes a
    /// view.
    lazy var view = NSView()

    func load(_ url: URL) { loaded.append(url) }
    func back() { actions.append("back") }
    func forward() { actions.append("forward") }
    func reload() { actions.append("reload") }
    func stop() { actions.append("stop") }
    func find(_ text: String) { actions.append("find \(text)") }
    func zoom(_ zoom: BrowserZoom) { actions.append("zoom \(zoom)") }
}

/// An engine over fake pages, keeping every page it made.
@MainActor
final class FakeBrowserEngine: BrowserEngine {
    private(set) var pages: [FakeBrowserPage] = []
    private(set) var profiles: [BrowserProfile] = []

    func makeTab(profile: BrowserProfile) -> BrowserTab {
        let page = FakeBrowserPage()
        pages.append(page)
        profiles.append(profile)

        return BrowserTab(profile: profile, page: page)
    }
}

/// A delegate that records what a tab asked of it.
@MainActor
final class RecordingTabDelegate: BrowserTabDelegate {
    var acceptsTabs = true
    private(set) var openedTabs: [BrowserTab] = []
    private(set) var closeRequests: [BrowserTab] = []
    private(set) var externals: [URL] = []
    private(set) var dialogs: [BrowserDialog] = []
    private(set) var downloads: [URL] = []
    private(set) var failures: [String] = []
    var answer: BrowserDialogAnswer = .confirmed

    func newTabRequested(_ tab: BrowserTab, from opener: BrowserTab) -> Bool {
        openedTabs.append(tab)
        return acceptsTabs
    }

    func closeRequested(by tab: BrowserTab) { closeRequests.append(tab) }

    func externalSchemeMet(_ url: URL) { externals.append(url) }

    func dialogPresented(
        _ dialog: BrowserDialog,
        in tab: BrowserTab,
        answer: @escaping @MainActor (BrowserDialogAnswer) -> Void
    ) {
        dialogs.append(dialog)
        answer(self.answer)
    }

    func downloadStarted(_ url: URL) { downloads.append(url) }

    func loadFailed(_ reason: String, in tab: BrowserTab) { failures.append(reason) }
}

/// The Mac's own opener for content links, recorded rather than opened.
@MainActor
final class RecordingWorkspaceOpener: WorkspaceLinkOpening {
    var succeeds = true
    private(set) var opened: [URL] = []

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return succeeds
    }
}

/// What a coordinator told the window and which profiles it built engines
/// over, in order.
@MainActor
final class BrowserRecord {
    var paneShown: [Bool] = []
    var enginesBuilt: [UUID] = []
}

/// A coordinator over fake pages and a throwaway support folder.
@MainActor
struct BrowserHarness {
    let engine = FakeBrowserEngine()
    let workspace = RecordingWorkspaceOpener()
    let record = BrowserRecord()
    let location: BootstrapLocation
    let coordinator: BrowserCoordinator

    init() {
        location = BrowserProfileLocation().location
        coordinator = BrowserCoordinator(
            makeEngine: { [engine, record] profile in
                record.enginesBuilt.append(profile)
                return engine
            },
            profile: WebsiteProfileRecord(location: location),
            workspace: workspace,
            paneShown: { [record] in record.paneShown.append($0) }
        )
    }

    var model: BrowserModel { coordinator.model }

    /// The fake page behind a tab, by the order the engine made it.
    func page(_ index: Int) -> FakeBrowserPage { engine.pages[index] }
}

/// A throwaway support folder, the one the website profile record lives in.
struct BrowserProfileLocation {
    let location: BootstrapLocation

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-browser-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        location = BootstrapLocation(homeDirectory: root)
    }
}
