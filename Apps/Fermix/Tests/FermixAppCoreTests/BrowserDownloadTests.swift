import Foundation
import Testing

@testable import FermixAppCore

/// A downloaded file's name, made one name a Mac volume takes (plan §8.1
/// item 2).
@Suite("Browser download name")
struct BrowserDownloadNameTests {
    @Test("a plain name is kept")
    func plainNameKept() {
        #expect(BrowserDownloadName.sanitized("report.pdf") == "report.pdf")
    }

    @Test("a name is one name in its directory: no separator, not hidden, never empty")
    func nameIsOneName() {
        #expect(BrowserDownloadName.sanitized("../../etc/passwd") == "_.._etc_passwd")
        #expect(BrowserDownloadName.sanitized("a:b\nc.txt") == "a_b_c.txt")
        #expect(BrowserDownloadName.sanitized(".profile") == "profile")
        #expect(BrowserDownloadName.sanitized("  report.pdf  ") == "report.pdf")
        for nothing in ["", "  ", ".", ".."] {
            #expect(BrowserDownloadName.sanitized(nothing) == ProductStrings[.browserDownloadUntitled])
        }
    }

    @Test("a long name is cut to a volume's limit, its extension kept")
    func longNameFits() {
        let ascii = BrowserDownloadName.sanitized(String(repeating: "a", count: 300) + ".pdf")
        let accented = BrowserDownloadName.sanitized(String(repeating: "é", count: 200) + ".zip")

        #expect(ascii.utf8.count == BrowserDownloadName.maximumBytes)
        #expect(ascii.hasSuffix(".pdf"))
        #expect(accented.utf8.count <= BrowserDownloadName.maximumBytes)
        #expect(accented.hasSuffix(".zip"))
        #expect(accented.dropLast(4).allSatisfy { $0 == "é" }, "a character was cut in half")
    }
}

/// The pane's downloads through the real coordinator, over fake pages,
/// downloads and system panels, writing only into throwaway directories: a
/// task's refused at once with nothing written, the person's saved where
/// they choose, and the one rule that lets the pane ask the person anything.
@Suite("Browser downloads")
@MainActor
struct BrowserDownloadsTests {
    nonisolated static let page = URL(string: "https://example.com/")!
    nonisolated static let task = BrowserTaskID("task-1")
    static let refusal = ProductStrings[.browserHostReasonTaskDownloadRefused]

    /// A host attached, with one task tab open.
    static func taskSetup() throws -> (harness: BrowserHarness, link: FakeHostLink, tab: BrowserTab) {
        let harness = BrowserHarness()
        let (link, _) = try BrowserHostCoordinatorTests.attached(harness)
        let tab = try BrowserHostCoordinatorTests.openTaskTab(harness)

        return (harness, link, tab)
    }

    /// The person's tab in front of an open pane on screen, and a folder to
    /// save into in place of their Downloads folder.
    static func personSetup() throws -> (harness: BrowserHarness, tab: BrowserTab, folder: URL) {
        let harness = BrowserHarness()
        harness.coordinator.open(page)
        harness.coordinator.paneStageAppeared(harness.pane)
        harness.coordinator.windowVisibilityChanged(true)
        let tab = try #require(harness.model.selectedTab)

        return (harness, tab, try throwaway("Downloads"))
    }

    static func throwaway(_ path: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-browser-download-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory
    }

    /// A download a page began, asked at once where its file goes, as WebKit
    /// asks.
    static func begin(_ given: FakeDownload? = nil, on page: FakeBrowserPage) -> FakeDownload {
        let download = given ?? FakeDownload()
        page.events?.pageStartedDownload(download)
        download.askForDestination()

        return download
    }

    static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    static func bytes(_ file: URL) throws -> Data {
        try Data(contentsOf: file)
    }

    /// An extended attribute, as WebKit's quarantine is one.
    static func mark(_ file: URL, _ attribute: String) {
        _ = setxattr(file.path, attribute, "1", 1, 0, 0)
    }

    static func isMarked(_ file: URL, _ attribute: String) -> Bool {
        getxattr(file.path, attribute, nil, 0, 0, 0) >= 0
    }

    /// The person's choice of place, answered, and the file WebKit was given
    /// in its stead.
    static func choose(_ place: URL, for download: FakeDownload, in harness: BrowserHarness) throws -> URL {
        harness.engine.answerSave(place)

        return try #require(download.destination)
    }

    /// A file the person agreed to replace, with an attribute of its own.
    static func oldFile(in folder: URL) throws -> (place: URL, contents: Data) {
        let place = folder.appendingPathComponent("report.pdf", isDirectory: false)
        let contents = Data("the person's own file".utf8)
        try contents.write(to: place)
        mark(place, "com.example.old")

        return (place, contents)
    }

    static let alert = BrowserDialog(kind: .alert, message: "Hello", origin: "example.com")
    static let files = BrowserFileRequest(allowsMultipleSelection: false, allowsDirectories: false)

    // MARK: - A task's download

    @Test("a task's download is refused: the daemon hears it begin and fail, and nothing is written")
    func taskDownloadRefused() throws {
        let (harness, link, tab) = try Self.taskSetup()

        let download = Self.begin(on: harness.page(0))

        #expect(download.answered && download.destination == nil, "a task's download was given a place to write")
        #expect(link.refusals.map(\.tab) == [tab.id])
        #expect(link.refusals.map(\.filename) == ["report.pdf"])
        #expect(link.refusals.map(\.reason) == [Self.refusal])
        #expect(link.events.last == "download.refused")
        #expect(harness.engine.saveRequests.isEmpty, "a task's download asked the person")
        #expect(harness.model.notice == nil)
    }

    /// Ownership, not placement: the task's tab is in front of a pane on
    /// screen, exactly where the person's would be asked.
    @Test("a task's download in front of an open pane asks the person nothing")
    func taskDownloadInFrontAsksNothing() throws {
        let (harness, link, tab) = try Self.taskSetup()
        BrowserHostCoordinatorTests.showPaneOnScreen(harness)
        #expect(harness.model.selectedTabID == tab.id)

        let download = Self.begin(on: harness.page(0))

        #expect(download.destination == nil)
        #expect(link.refusals.count == 1)
        #expect(harness.engine.saveRequests.isEmpty)
    }

    @Test("a download from a task's popup is refused the same way, under the popup's tab")
    func taskPopupDownloadRefused() throws {
        let (harness, link, tab) = try Self.taskSetup()
        let popup = FakeBrowserPage()
        #expect(harness.page(0).events?.pageOpened(popup) == true)
        let popupTab = try #require(harness.model.tabs.first { $0.id != tab.id })

        let download = Self.begin(on: popup)

        #expect(download.destination == nil)
        #expect(link.refusals.map(\.tab) == [popupTab.id])
        #expect(harness.engine.saveRequests.isEmpty)
    }

    @Test("a refused download is named as the page suggested it, made one safe name")
    func refusedNameIsSafe() throws {
        let (harness, link, _) = try Self.taskSetup()

        _ = Self.begin(FakeDownload(suggestedFilename: "../x/report.pdf"), on: harness.page(0))
        _ = Self.begin(FakeDownload(suggestedFilename: ""), on: harness.page(0))

        #expect(link.refusals.map(\.filename) == ["_x_report.pdf", ProductStrings[.browserDownloadUntitled]])
        #expect(Set(link.refusals.map(\.download)).count == 2, "two downloads shared one id")
    }

    @Test("a task's download the daemon was not yet told of stops with the app, without a word")
    func pendingTaskDownloadStopsAtQuit() throws {
        let (harness, link, _) = try Self.taskSetup()
        let download = FakeDownload()
        harness.page(0).events?.pageStartedDownload(download)

        harness.coordinator.stopHost {}

        #expect(download.cancels == 1)
        #expect(link.refusals.isEmpty)
    }

    // MARK: - The person's download

    @Test("the person's download asks where to save it, over its own page, and nothing crosses the wire")
    func personDownloadAsks() throws {
        let (harness, _, _) = try Self.personSetup()
        let link = FakeHostLink()
        _ = harness.coordinator.hostAttached(link, caps: BrowserTabCaps(perTask: 3, global: 6))

        let download = Self.begin(FakeDownload(suggestedFilename: ".hidden/report.pdf"), on: harness.page(0))

        #expect(harness.engine.saveRequests == ["hidden_report.pdf"])
        #expect(harness.engine.savePages.first === harness.page(0).view)
        #expect(!download.answered, "the download went on before the person answered")
        #expect(link.refusals.isEmpty)
    }

    @Test("a private tab's download is saved where the person chooses too")
    func privateTabDownloadAsks() throws {
        let (harness, _, _) = try Self.personSetup()
        harness.coordinator.newTab(profile: .private)

        _ = Self.begin(on: harness.page(1))

        #expect(harness.engine.saveRequests == ["report.pdf"])
    }

    @Test("cancelling the save panel cancels the download, with nothing said")
    func savePanelCancelled() throws {
        let (harness, _, _) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))

        harness.engine.answerSave(nil)

        #expect(download.answered)
        #expect(download.destination == nil)
        #expect(harness.model.notice == nil)

        _ = Self.begin(on: harness.page(0))
        #expect(harness.engine.saveRequests.count == 2, "a cancelled panel kept the next one from asking")
    }

    @Test("a new place the person chose says the file is on its way, then that it is saved, and is made only then")
    func personDownloadSaved() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))
        let place = folder.appendingPathComponent("report.pdf", isDirectory: false)

        let staged = try Self.choose(place, for: download, in: harness)

        #expect(staged != place, "WebKit was given the person's place to write")
        #expect(staged.lastPathComponent == "report.pdf")
        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadingFormat], "report.pdf"))

        try download.write("whole")
        #expect(!Self.exists(place), "the place was made before the download finished")
        download.finish()

        #expect(try Self.bytes(place) == Data("whole".utf8))
        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadSavedFormat], "report.pdf"))
        #expect(!Self.exists(staged.deletingLastPathComponent()), "the staging directory was left behind")
    }

    /// The old file is touched only by the move that replaces it, and the new
    /// file keeps its own attributes (WebKit's quarantine is one) and takes
    /// none of the old one's.
    @Test("a finished download replaces the file the person agreed to replace, in one step, with its own attributes")
    func finishedDownloadReplaces() throws {
        let (harness, _, folder) = try Self.personSetup()
        let old = try Self.oldFile(in: folder)
        let download = Self.begin(on: harness.page(0))

        let staged = try Self.choose(old.place, for: download, in: harness)
        try download.write("the new file")
        Self.mark(staged, "com.example.new")
        #expect(try Self.bytes(old.place) == old.contents, "the old file went before the download finished")

        download.finish()

        #expect(try Self.bytes(old.place) == Data("the new file".utf8))
        #expect(Self.isMarked(old.place, "com.example.new"))
        #expect(!Self.isMarked(old.place, "com.example.old"), "the new file took the old one's attributes")
        #expect(!Self.exists(staged.deletingLastPathComponent()))
        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadSavedFormat], "report.pdf"))
    }

    /// WebKit reports its own cancel as a failure too.
    @Test(
        "a download that fails or is cancelled leaves the person's file byte for byte, and nothing of its own",
        arguments: ["The network connection was lost.", "cancelled"]
    )
    func failedDownloadKeepsTheOldFile(_ reason: String) throws {
        let (harness, _, folder) = try Self.personSetup()
        let old = try Self.oldFile(in: folder)
        let download = Self.begin(on: harness.page(0))
        let staged = try Self.choose(old.place, for: download, in: harness)
        try download.write("half")

        download.fail(reason)

        #expect(try Self.bytes(old.place) == old.contents)
        #expect(Self.isMarked(old.place, "com.example.old"))
        #expect(!Self.exists(staged.deletingLastPathComponent()))
        #expect(
            harness.model.notice
                == String(format: ProductStrings[.browserNoticeDownloadFailedFormat], "report.pdf", reason)
        )
    }

    @Test("a failed download to a new place makes nothing there")
    func failedDownloadMakesNothing() throws {
        let (harness, _, folder) = try Self.personSetup()
        let place = folder.appendingPathComponent("report.pdf", isDirectory: false)
        let download = Self.begin(on: harness.page(0))
        let staged = try Self.choose(place, for: download, in: harness)
        try download.write("half")

        download.fail("The network connection was lost.")

        #expect(!Self.exists(place))
        #expect(!Self.exists(staged.deletingLastPathComponent()))
    }

    /// A folder that refuses the move stands in for any move that fails.
    @Test("a move into place that fails says why and keeps the person's file")
    func failedMoveKeepsTheOldFile() throws {
        let (harness, _, folder) = try Self.personSetup()
        let old = try Self.oldFile(in: folder)
        let download = Self.begin(on: harness.page(0))
        let staged = try Self.choose(old.place, for: download, in: harness)
        try download.write("the new file")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        download.finish()

        let failed = String(format: ProductStrings[.browserNoticeDownloadFailedFormat], "report.pdf", "")
        let notice = try #require(harness.model.notice)
        #expect(notice.hasPrefix(failed) && notice.count > failed.count, "the failure did not carry the system's reason: \(notice)")
        #expect(try Self.bytes(old.place) == old.contents)
        #expect(!Self.exists(staged.deletingLastPathComponent()))
    }

    @Test("a place the system cannot stage a download for cancels it and says why")
    func unstageablePlaceCancels() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))

        harness.engine.answerSave(folder.appendingPathComponent("gone/report.pdf", isDirectory: false))

        #expect(download.answered && download.destination == nil)
        #expect(harness.model.notice?.hasPrefix(String(format: ProductStrings[.browserNoticeDownloadFailedFormat], "report.pdf", "")) == true)
    }

    @Test("only the tab in front of an open pane may ask: any other download is cancelled at once")
    func onlyTheFrontTabAsks() throws {
        let (harness, _, _) = try Self.personSetup()
        harness.coordinator.newTab(profile: .shared)

        let behind = Self.begin(on: harness.page(0))
        #expect(behind.answered && behind.destination == nil)

        harness.coordinator.closePane()
        let hidden = Self.begin(on: harness.page(1))
        #expect(hidden.answered && hidden.destination == nil)
        #expect(harness.engine.saveRequests.isEmpty)
    }

    @Test("the person's download goes on when its tab is closed, as a browser's does")
    func personDownloadOutlivesItsTab() throws {
        let (harness, tab, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))
        let place = folder.appendingPathComponent("report.pdf", isDirectory: false)
        harness.engine.answerSave(place)

        harness.coordinator.close(tab)
        try download.write("whole")
        download.finish()

        #expect(download.cancels == 0)
        #expect(try Self.bytes(place) == Data("whole".utf8))
        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadSavedFormat], "report.pdf"))
    }

    @Test("a quit stops the person's download, keeps their file, and removes what the download wrote")
    func quitStopsThePersonsDownload() throws {
        let (harness, _, folder) = try Self.personSetup()
        let old = try Self.oldFile(in: folder)
        let download = Self.begin(on: harness.page(0))
        let staged = try Self.choose(old.place, for: download, in: harness)
        try download.write("half")

        harness.coordinator.stopHost {}
        #expect(download.cancels == 1)
        #expect(!Self.exists(staged.deletingLastPathComponent()), "the staging directory waited for the engine")

        // The engine was still making the file when it was told to stop.
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try download.write("late")
        download.engineStopped()
        #expect(!Self.exists(staged.deletingLastPathComponent()))
        #expect(try Self.bytes(old.place) == old.contents)
        #expect(Self.isMarked(old.place, "com.example.old"))
    }

    @Test("a quit while the save panel is up cancels the download the panel then answers")
    func quitWhileThePanelIsUp() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))

        harness.coordinator.stopHost {}
        harness.engine.answerSave(folder.appendingPathComponent("report.pdf", isDirectory: false))

        #expect(download.cancels == 1)
        #expect(download.answered && download.destination == nil)
    }

    // MARK: - One popup at a time

    @Test("one save panel at a time: a second download while one is up is cancelled")
    func oneSavePanelAtATime() throws {
        let (harness, _, _) = try Self.personSetup()
        let first = Self.begin(on: harness.page(0))

        let second = Self.begin(on: harness.page(0))

        #expect(harness.engine.saveRequests.count == 1)
        #expect(!first.answered)
        #expect(second.answered && second.destination == nil)
    }

    @Test("a download while a page's dialog is up is cancelled without a panel")
    func downloadUnderADialogIsCancelled() throws {
        let (harness, _, _) = try Self.personSetup()
        harness.page(0).events?.pagePresented(Self.alert) { _ in }
        #expect(harness.model.dialog != nil)

        let download = Self.begin(on: harness.page(0))

        #expect(download.answered && download.destination == nil)
        #expect(harness.engine.saveRequests.isEmpty)
        #expect(harness.model.dialog?.dialog == Self.alert, "the download took the dialog's place")
    }

    @Test("a download while the file chooser is up is cancelled without a panel")
    func downloadUnderTheChooserIsCancelled() throws {
        let (harness, _, _) = try Self.personSetup()
        harness.page(0).events?.pageRequestedFiles(Self.files) { _ in }
        #expect(harness.engine.fileRequests.count == 1)

        let download = Self.begin(on: harness.page(0))

        #expect(download.answered && download.destination == nil)
        #expect(harness.engine.saveRequests.isEmpty)
    }

    @Test("a page's dialog while the save panel is up is dismissed")
    func dialogOverTheSavePanelIsDismissed() throws {
        let (harness, _, _) = try Self.personSetup()
        _ = Self.begin(on: harness.page(0))
        var answers: [BrowserDialogAnswer] = []

        harness.page(0).events?.pagePresented(Self.alert) { answers.append($0) }

        #expect(answers == [.dismissed])
        #expect(harness.model.dialog == nil)
    }

    @Test("the file chooser while the save panel is up gives the page no file")
    func chooserOverTheSavePanelGivesNoFile() throws {
        let (harness, _, _) = try Self.personSetup()
        _ = Self.begin(on: harness.page(0))
        var answers: [[URL]?] = []

        harness.page(0).events?.pageRequestedFiles(Self.files) { answers.append($0) }

        #expect(answers == [nil])
        #expect(harness.engine.fileRequests.isEmpty)
    }

    @Test("the question before another app opens is dismissed while the save panel is up, and the app stays shut")
    func otherAppQuestionOverTheSavePanelIsDismissed() throws {
        let (harness, _, _) = try Self.personSetup()
        _ = Self.begin(on: harness.page(0))

        harness.page(0).events?.pageMetExternalScheme(URL(string: "mailto:hello@fermix.ai")!)

        #expect(harness.model.dialog == nil)
        #expect(harness.workspace.opened.isEmpty)
    }

    @Test("once the save panel is answered the pane may ask again")
    func answeredPanelFreesThePane() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))

        harness.engine.answerSave(folder.appendingPathComponent("report.pdf", isDirectory: false))
        harness.page(0).events?.pagePresented(Self.alert) { _ in }

        #expect(harness.model.dialog?.dialog == Self.alert)
        download.fail("done")
    }
}

/// A task's refused download on the host wire itself, through the client and
/// the real coordinator: the contract's own two events, in its order.
@Suite("Browser download wire")
@MainActor
struct BrowserDownloadWireTests {
    private typealias Transport = FakeLineSocketTransport<BrowserHostInbound, BrowserHostDecodeFailure>

    private static func attached(_ harness: BrowserHarness) -> (client: BrowserHostClient, transport: Transport) {
        let transport = Transport()
        let client = BrowserHostClient(
            lines: transport,
            socketPath: { "/tmp/fermix-test/browser_host.sock" },
            profileID: { "profile-1" },
            workspaceRoot: { URL(fileURLWithPath: "/tmp/fermix-test/workspace", isDirectory: true) },
            browserRoot: { URL(fileURLWithPath: "/tmp/fermix-test/browser", isDirectory: true) },
            hostVersion: "0.2.0",
            coordinator: harness.coordinator,
            deadlines: ManualDeadlineScheduler()
        )
        client.connect()
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))

        return (client, transport)
    }

    /// The answer to request `id`, once the client has sent it.
    private static func answer(_ id: Int, on transport: Transport) async throws -> NSDictionary {
        for _ in 0..<2000 {
            if try transport.sentObjects().contains(where: { $0["id"] as? Int == id }) { break }
            await Task.yield()
        }

        return try #require(transport.sentObjects().first { $0["id"] as? Int == id })
    }

    /// A fixture line with this build's ids in place of the fixture's own.
    private static func golden(_ index: Int, downloadID: UUID, tabID: UUID) throws -> NSDictionary {
        var object = try BrowserHostFixtures.load(.events)[index].object
        object["download_id"] = downloadID.uuidString
        object["tab_id"] = tabID.uuidString

        return NSDictionary(dictionary: object)
    }

    @Test("a refused download is the contract's download.began, then a failed download.finished")
    func refusalIsTheContractsTwoEvents() throws {
        let harness = BrowserHarness()
        let (client, transport) = Self.attached(harness)
        let download = UUID()
        let tab = UUID()
        let before = transport.sent.count

        client.downloadRefused(download, tab: tab, filename: "report.pdf", reason: "the server closed the connection")

        let sent = try Array(transport.sentObjects().dropFirst(before))
        try #require(sent.count == 2)
        #expect(try sent[0] == Self.golden(8, downloadID: download, tabID: tab))
        #expect(try sent[1] == Self.golden(11, downloadID: download, tabID: tab))
    }

    @Test("a task's download in the pane reaches the daemon as a refusal, with no path and nothing written")
    func taskDownloadOnTheWire() async throws {
        let harness = BrowserHarness()
        let (_, transport) = Self.attached(harness)
        let downloads = try BrowserDownloadsTests.throwaway("browser/downloads/0bqP3d")
        transport.deliver(.request(.tabOpen(id: 7, BrowserHostTabOpenRequest(
            taskId: "task-1", url: "https://example.com/", observe: false, downloadDir: downloads.path,
            taskTabCap: 10, tabCap: 60, snapshot: nil, visible: nil
        ))))
        let opened = try await Self.answer(7, on: transport)
        let tabID = try #require((opened["result"] as? [String: Any])?["tab_id"] as? String)

        let download = BrowserDownloadsTests.begin(on: harness.page(0))

        let lines = try transport.sentObjects().filter { ($0["type"] as? String)?.hasPrefix("download.") == true }
        try #require(lines.count == 2)
        #expect(lines[0]["type"] as? String == "download.began")
        #expect(lines[0]["tab_id"] as? String == tabID)
        #expect(lines[0]["filename"] as? String == "report.pdf")
        #expect(lines[1] == NSDictionary(dictionary: [
            "type": "download.finished",
            "download_id": try #require(lines[0]["download_id"] as? String),
            "tab_id": tabID,
            "state": "failed",
            "reason": ProductStrings[.browserHostReasonTaskDownloadRefused]
        ]))
        #expect(download.destination == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    }
}
