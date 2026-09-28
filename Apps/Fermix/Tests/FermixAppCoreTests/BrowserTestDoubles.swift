import AppKit
import Combine
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

/// A page with a web engine behind it, standing in for `WebKitBrowserPage` in
/// tests of `BrowserTab`'s host actions: it records what it was asked and
/// answers what the test sets up.
@MainActor
final class FakeDrivablePage: BrowserPage, BrowserPageDriving {
    weak var events: (any BrowserPageEvents)?
    lazy var view = NSView()

    private(set) var snapshotRequests: [BrowserSnapshotRequest] = []
    private(set) var actions: [BrowserPageAction] = []
    var snapshotResult: Result<BrowserPageSnapshot, any Error> = .success(.empty)
    var actResult: Result<BrowserActOutcome, any Error> = .success(.init(effect: .unchanged, input: .trusted, url: ""))

    func load(_ url: URL) {}
    func back() {}
    func forward() {}
    func reload() {}
    func stop() {}
    func find(_ text: String) {}
    func zoom(_ zoom: BrowserZoom) {}

    func snapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        snapshotRequests.append(request)
        return try snapshotResult.get()
    }

    func act(_ action: BrowserPageAction, observing request: BrowserSnapshotRequest) async throws -> BrowserActOutcome {
        actions.append(action)
        snapshotRequests.append(request)
        return try actResult.get()
    }
}

extension BrowserPageSnapshot {
    static let empty = BrowserPageSnapshot(
        title: "",
        url: "",
        nodes: [BrowserPageNode(id: 0, role: "RootWebArea")],
        elements: 0,
        crossOriginFrames: 0,
        closedShadowRoots: false,
        evaluateMilliseconds: 0
    )
}

/// An engine over fake pages, keeping every page it made.
@MainActor
final class FakeBrowserEngine: BrowserEngine {
    private(set) var pages: [FakeBrowserPage] = []
    private(set) var profiles: [BrowserProfile] = []
    private(set) var idleReleases = 0
    let stage = FakePageStage()

    var hostWindow: any BrowserPageStage { stage }

    func makeTab(profile: BrowserProfile) -> BrowserTab {
        let page = FakeBrowserPage()
        pages.append(page)
        profiles.append(profile)

        return BrowserTab(profile: profile, page: page)
    }

    func releaseIdle() { idleReleases += 1 }
}

/// A place a page can be, without a window: it records which pages it holds.
@MainActor
final class FakePageStage: BrowserPageStage {
    private(set) var held: [NSView] = []
    /// Every hold and release, in order, as "hold" or "release".
    private(set) var moves: [String] = []

    func hold(_ page: NSView) {
        moves.append("hold")
        guard !holds(page) else { return }

        held.append(page)
    }

    func release(_ page: NSView) {
        moves.append("release")
        held.removeAll { $0 === page }
    }

    func holds(_ page: NSView) -> Bool {
        held.contains { $0 === page }
    }
}

/// The session's availability as a test states it.
@MainActor
final class FakeSessionAvailability: SessionAvailabilityReporting {
    private let subject: CurrentValueSubject<BrowserAvailability, Never>
    private(set) var terminatingCalls = 0

    init(_ availability: BrowserAvailability = .available) {
        subject = CurrentValueSubject(availability)
    }

    var availability: BrowserAvailability { subject.value }
    var changes: AnyPublisher<BrowserAvailability, Never> { subject.eraseToAnyPublisher() }

    func set(_ availability: BrowserAvailability) {
        subject.send(availability)
    }

    func applicationTerminating() {
        terminatingCalls += 1
        subject.send(.unavailable(.appTerminating))
    }
}

/// The daemon's end of the host wire, recorded: what the host told it, and
/// the answer to `host_stopping` held for the test to give.
@MainActor
final class FakeHostLink: BrowserHostLink {
    private(set) var reports: [BrowserAvailability] = []
    private(set) var cancelled: [BrowserTaskID] = []
    private(set) var closedTabs: [UUID] = []
    private(set) var stoppingSent = 0
    /// Every event in the order the host sent it.
    private(set) var events: [String] = []
    private var answer: (@MainActor () -> Void)?

    func reportAvailability(_ availability: BrowserAvailability) {
        reports.append(availability)
        events.append("availability")
    }

    func tabClosed(_ tab: UUID, task: BrowserTaskID) {
        closedTabs.append(tab)
        events.append("tab.closed")
    }

    func cancelTask(_ task: BrowserTaskID) {
        cancelled.append(task)
        events.append("cancel")
    }

    func sendHostStopping(answered: @escaping @MainActor () -> Void) {
        stoppingSent += 1
        events.append("host_stopping")
        answer = answered
    }

    /// The daemon's answer to `host_stopping` arrives.
    func answerStopping() {
        answer?()
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

/// The link preference with no host state behind it: the suite never reads or
/// writes the operator's real defaults.
@MainActor
final class InMemoryLinkPreferenceStore: LinkPreferenceStoring {
    var linkDestination = UserDefaultsLinkPreferenceStore.defaultDestination
}

/// What a coordinator told the window and which profiles it built engines
/// over, in order.
@MainActor
final class BrowserRecord {
    var paneShown: [Bool] = []
    var enginesBuilt: [UUID] = []
    /// How many times the primary window's present path was asked for.
    var primaryWindowPresented = 0
}

/// A coordinator over fake pages and a throwaway support folder.
@MainActor
struct BrowserHarness {
    let engine = FakeBrowserEngine()
    let workspace = RecordingWorkspaceOpener()
    let record = BrowserRecord()
    let session: FakeSessionAvailability
    /// The quit's bound, fired by hand.
    let deadlines = ManualDeadlineScheduler()
    /// The pane's page area, as SwiftUI would build it.
    let pane = FakePageStage()
    let location: BootstrapLocation
    let coordinator: BrowserCoordinator

    init(availability: BrowserAvailability = .available) {
        location = BrowserProfileLocation().location
        session = FakeSessionAvailability(availability)
        coordinator = BrowserCoordinator(
            makeEngine: { [engine, record] profile in
                record.enginesBuilt.append(profile)
                return engine
            },
            profile: WebsiteProfileRecord(location: location),
            workspace: workspace,
            session: session,
            deadlines: deadlines,
            paneShown: { [record] in record.paneShown.append($0) },
            presentPrimaryWindow: { [record] in record.primaryWindowPresented += 1 }
        )
    }

    var model: BrowserModel { coordinator.model }

    /// The fake page behind a tab, by the order the engine made it.
    func page(_ index: Int) -> FakeBrowserPage { engine.pages[index] }

    /// The corner window's fake.
    var hostWindow: FakePageStage { engine.stage }
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
