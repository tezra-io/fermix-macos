import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@testable import FermixAppCore

/// A page with no web engine behind it: it records what it was asked, and the
/// test speaks for it through `events`.
@MainActor
final class FakeBrowserPage: BrowserPage {
    weak var events: (any BrowserPageEvents)?
    private(set) var loaded: [URL] = []
    private(set) var files: [FileLoad] = []
    private(set) var actions: [String] = []

    /// Built on first use, so a test that never shows the page never makes a
    /// view.
    lazy var view = NSView()

    func load(_ url: URL) { loaded.append(url) }
    func loadFile(_ url: URL, as kind: BrowserFileKind, readAccess: URL) {
        files.append(FileLoad(url: url, kind: kind, readAccess: readAccess))
    }
    func back() { actions.append("back") }
    func forward() { actions.append("forward") }
    func reload() { actions.append("reload") }
    func stop() { actions.append("stop") }
    func find(_ text: String) { actions.append("find \(text)") }
    func zoom(_ zoom: BrowserZoom) { actions.append("zoom \(zoom)") }
}

/// A file a page was asked to show, as what, and what it may read: the file
/// itself unless a test says otherwise.
struct FileLoad: Equatable {
    let url: URL
    let kind: BrowserFileKind
    let readAccess: URL

    init(url: URL, kind: BrowserFileKind, readAccess: URL? = nil) {
        self.url = url
        self.kind = kind
        self.readAccess = readAccess ?? url
    }
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

    /// The test's own gate on `waitUntilReady()`: nil answers at once, set
    /// answers once the test releases it, and `readyFailure` is thrown then
    /// instead of returning, as a failed navigation would.
    var readyGate: AsyncGate?
    var readyFailure: (any Error)?
    private(set) var readyWaits = 0

    func load(_ url: URL) {}
    func loadFile(_ url: URL, as kind: BrowserFileKind, readAccess: URL) {}
    func back() {}
    func forward() {}
    func reload() {}
    func stop() {}
    func find(_ text: String) {}
    func zoom(_ zoom: BrowserZoom) {}

    func waitUntilReady() async throws {
        readyWaits += 1
        guard let readyGate else { return }

        await readyGate.wait()
        if let readyFailure { throw readyFailure }
    }

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

    /// Every file chooser raised, with the page it was raised over; the open
    /// one waits for the test's `answerFiles`.
    private(set) var fileRequests: [BrowserFileRequest] = []
    private(set) var filePages: [NSView] = []
    private var fileAnswer: (@MainActor ([URL]?) -> Void)?

    func chooseFiles(_ request: BrowserFileRequest, for page: NSView, answer: @escaping @MainActor ([URL]?) -> Void) {
        fileRequests.append(request)
        filePages.append(page)
        fileAnswer = answer
    }

    /// The person answers the open chooser.
    func answerFiles(_ files: [URL]?) {
        let answer = fileAnswer
        fileAnswer = nil
        answer?(files)
    }

    /// Every save panel raised, by the file name it offered, with the page it
    /// was raised over; the open one waits for the test's `answerSave`.
    private(set) var saveRequests: [String] = []
    private(set) var savePages: [NSView] = []
    private var saveAnswer: (@MainActor (URL?) -> Void)?

    func chooseSaveDestination(_ filename: String, for page: NSView, answer: @escaping @MainActor (URL?) -> Void) {
        saveRequests.append(filename)
        savePages.append(page)
        saveAnswer = answer
    }

    /// The person answers the open save panel: a place, or nil for Cancel.
    func answerSave(_ destination: URL?) {
        let answer = saveAnswer
        saveAnswer = nil
        answer?(destination)
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

    /// A task's download the host refused, as the daemon was told of it.
    struct Refusal: Equatable {
        let download: UUID
        let tab: UUID
        let filename: String
        let reason: String
    }

    private(set) var refusals: [Refusal] = []

    func downloadRefused(_ download: UUID, tab: UUID, filename: String, reason: String) {
        refusals.append(Refusal(download: download, tab: tab, filename: filename, reason: reason))
        events.append("download.refused")
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
    private(set) var handOffs: [URL] = []
    private(set) var dialogs: [BrowserDialog] = []
    private(set) var downloads: [any BrowserDownload] = []
    private(set) var failures: [String] = []
    var answer: BrowserDialogAnswer = .confirmed

    func newTabRequested(_ tab: BrowserTab, from opener: BrowserTab) -> Bool {
        openedTabs.append(tab)
        return acceptsTabs
    }

    func closeRequested(by tab: BrowserTab) { closeRequests.append(tab) }

    private(set) var fileRequests: [BrowserFileRequest] = []
    var files: [URL]?

    func filesRequested(
        _ request: BrowserFileRequest,
        in tab: BrowserTab,
        answer: @escaping @MainActor ([URL]?) -> Void
    ) {
        fileRequests.append(request)
        answer(files)
    }

    func externalSchemeMet(_ url: URL, in tab: BrowserTab) { externals.append(url) }

    func handOffRequested(_ url: URL, from tab: BrowserTab) { handOffs.append(url) }

    func dialogPresented(
        _ dialog: BrowserDialog,
        in tab: BrowserTab,
        answer: @escaping @MainActor (BrowserDialogAnswer) -> Void
    ) {
        dialogs.append(dialog)
        answer(self.answer)
    }

    func downloadStarted(_ download: any BrowserDownload, in tab: BrowserTab) { downloads.append(download) }

    func loadFailed(_ reason: String, in tab: BrowserTab) { failures.append(reason) }
}

/// A download with no web engine behind it, standing in for
/// `WebKitBrowserDownload`: the test speaks for WebKit through its verbs, and
/// `write(_:)` puts bytes where the pane said the file goes, as WebKit writes
/// a file as it arrives.
@MainActor
final class FakeDownload: BrowserDownload {
    weak var events: (any BrowserDownloadEvents)?
    let suggestedFilename: String
    /// What the pane answered for the file's place, once it has.
    private(set) var destination: URL?
    private(set) var answered = false
    private(set) var cancels = 0
    /// The cancel's answer, held until the test says the engine stopped.
    private var stopped: (@MainActor () -> Void)?

    init(suggestedFilename: String = "report.pdf") {
        self.suggestedFilename = suggestedFilename
    }

    func cancel(_ stopped: @escaping @MainActor () -> Void) {
        events = nil
        cancels += 1
        self.stopped = stopped
    }

    /// WebKit asks where the file goes; the pane may answer later. A refused
    /// place cancels the download, so nothing is reported after it.
    func askForDestination() {
        events?.download(self, needsDestinationFor: suggestedFilename) { [weak self] destination in
            self?.answered = true
            self?.destination = destination
            if destination == nil { self?.events = nil }
        }
    }

    /// Bytes arrive at the destination.
    func write(_ text: String) throws {
        guard let destination else { throw CocoaError(.fileNoSuchFile) }

        try Data(text.utf8).write(to: destination)
    }

    func finish() {
        events?.downloadFinished(self)
    }

    func fail(_ reason: String) {
        events?.download(self, failed: reason)
    }

    /// The engine has stopped writing after a cancel.
    func engineStopped() {
        let stopped = self.stopped
        self.stopped = nil
        stopped?()
    }
}

/// The Mac's own opener for content links, recorded rather than opened.
@MainActor
final class RecordingWorkspaceOpener: WorkspaceLinkOpening {
    static let preview = WorkspaceApplication(url: URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true), name: "Preview")
    static let mail = WorkspaceApplication(url: URL(fileURLWithPath: "/System/Applications/Mail.app", isDirectory: true), name: "Mail")

    var succeeds = true
    /// The app this Mac would open any link in, or nil for none.
    var linkApp: WorkspaceApplication? = RecordingWorkspaceOpener.mail
    /// The app this Mac would open any document in, or nil for none.
    var documentApp: WorkspaceApplication? = RecordingWorkspaceOpener.preview
    /// The system's sentence the named app answers a file with, or nil where
    /// it takes it.
    var appFailure: String?
    /// The apps that open web pages on this Mac.
    var webBrowsers: [URL] = []
    private(set) var opened: [URL] = []
    /// Every type an app was asked for, in order.
    private(set) var typesAsked: [UTType] = []
    /// Every file handed to a named app, in order.
    private(set) var openedWith: [AppOpen] = []
    /// Every file shown in Finder, in order.
    private(set) var revealed: [URL] = []

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return succeeds
    }

    func application(toOpen url: URL) -> WorkspaceApplication? { linkApp }

    func application(toOpen type: UTType) -> WorkspaceApplication? {
        typesAsked.append(type)
        return documentApp
    }

    func opensWebPages(_ app: WorkspaceApplication) -> Bool { webBrowsers.contains(app.url) }

    func open(_ file: URL, withApplicationAt app: URL, failed: @escaping @MainActor (String) -> Void) {
        openedWith.append(AppOpen(file: file, app: app))
        if let appFailure { failed(appFailure) }
    }

    func reveal(_ url: URL) { revealed.append(url) }
}

/// A file handed to a named app.
struct AppOpen: Equatable {
    let file: URL
    let app: URL
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

    /// `home` is the Fermix home a file opens silently under; nil is a home
    /// that cannot be resolved, which has nothing inside it.
    init(availability: BrowserAvailability = .available, home: URL? = nil) {
        location = BrowserProfileLocation().location
        session = FakeSessionAvailability(availability)
        coordinator = BrowserCoordinator(
            makeEngine: { [engine, record] profile in
                record.enginesBuilt.append(profile)
                return engine
            },
            profile: WebsiteProfileRecord(location: location),
            workspace: workspace,
            home: {
                guard let home else { throw CocoaError(.fileNoSuchFile) }
                return home
            },
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
