import Foundation
import Testing

@testable import FermixAppCore

/// A downloaded file's name, made safe to write and unique in its directory
/// (plan §8.1 item 2).
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

    @Test("a taken name is numbered before its extension, as the Finder numbers a copy")
    func takenNamesAreNumbered() {
        let taken: Set = ["report.pdf", "report 2.pdf"]

        #expect(BrowserDownloadName.unique("report.pdf") { _ in false } == "report.pdf")
        #expect(BrowserDownloadName.unique("report.pdf") { taken.contains($0) } == "report 3.pdf")
        #expect(BrowserDownloadName.unique("notes") { $0 == "notes" } == "notes 2")
    }

    @Test("a numbered name still fits a volume's limit")
    func numberedNameFits() {
        let long = String(repeating: "a", count: 300) + ".pdf"
        let first = BrowserDownloadName.sanitized(long)

        let numbered = BrowserDownloadName.unique(long) { $0 == first }

        #expect(numbered.utf8.count == BrowserDownloadName.maximumBytes)
        #expect(numbered.hasSuffix(" 2.pdf"))
    }
}

/// How often a task's download reports progress on the wire.
@Suite("Browser download progress gate")
struct BrowserDownloadProgressGateTests {
    /// Which of `reports` the gate lets through, in order.
    static func admitted(_ reports: [(received: Int, total: Int?)]) -> [Int] {
        var gate = BrowserDownloadProgressGate()

        return reports.filter { gate.admits(received: $0.received, total: $0.total) }.map(\.received)
    }

    @Test("a stated size reports once per hundredth of it, the first report always")
    func statedSize() {
        let reports: [(received: Int, total: Int?)] = [(10, 10_000), (109, 10_000), (110, 10_000), (10_000, 10_000)]

        #expect(Self.admitted(reports) == [10, 110, 10_000])
    }

    @Test("an unstated size reports once per mebibyte")
    func unstatedSize() {
        let reports: [(received: Int, total: Int?)] = [(1, nil), (1_048_576, nil), (1_048_577, nil)]

        #expect(Self.admitted(reports) == [1, 1_048_577])
    }
}

/// The pane's downloads through the real coordinator, over fake pages and
/// downloads, writing only into throwaway directories: where each file goes
/// by whose tab began it, what the daemon hears, what the person is asked and
/// told, and what is left when a download does not finish.
@Suite("Browser downloads")
@MainActor
struct BrowserDownloadsTests {
    nonisolated static let page = URL(string: "https://example.com/")!
    nonisolated static let task = BrowserTaskID("task-1")

    /// A host attached, with one task tab open on a download directory made
    /// as the engine makes it before `tab.open`.
    struct TaskSetup {
        let harness: BrowserHarness
        let link: FakeHostLink
        let connection: BrowserHostConnection
        let tab: BrowserTab
        let directory: URL
    }

    static func taskSetup() throws -> TaskSetup {
        let harness = BrowserHarness()
        let link = FakeHostLink()
        let connection = try #require(harness.coordinator.hostAttached(link, caps: BrowserTabCaps(perTask: 3, global: 6)))
        let directory = try throwaway("browser/downloads/task-1")
        let id = try harness.coordinator.openTaskTab(page, for: task, downloadDirectory: directory).get()
        let tab = try #require(harness.model.tabs.first { $0.id == id })

        return TaskSetup(harness: harness, link: link, connection: connection, tab: tab, directory: directory)
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

    /// The id the daemon heard a download begin under, and the tab and file it
    /// named.
    static func began(_ link: FakeHostLink, at index: Int = 0) throws -> (id: UUID, tab: UUID, filename: String) {
        guard link.downloads.indices.contains(index), case .began(let id, let tab, let filename) = link.downloads[index] else {
            Issue.record("no download.began at \(index): \(link.downloads)")
            throw CocoaError(.featureUnsupported)
        }

        return (id, tab, filename)
    }

    static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    // MARK: - A task's download

    @Test("a task's file goes into its download directory, and the daemon hears it begin")
    func taskFileGoesIntoItsDirectory() throws {
        let setup = try Self.taskSetup()

        let download = Self.begin(on: setup.harness.page(0))

        #expect(download.destination == setup.directory.appendingPathComponent("report.pdf", isDirectory: false))
        let began = try Self.began(setup.link)
        #expect(began.tab == setup.tab.id)
        #expect(began.filename == "report.pdf")
        #expect(setup.harness.pane.savePanels.isEmpty, "a task's download asked the person")
        #expect(setup.harness.model.notice == nil)
    }

    @Test("a task's file never writes over one already there, or one still arriving")
    func taskFileNeverOverwrites() throws {
        let setup = try Self.taskSetup()
        let existing = setup.directory.appendingPathComponent("report.pdf", isDirectory: false)
        try Data("kept".utf8).write(to: existing)

        let second = Self.begin(on: setup.harness.page(0))
        let third = Self.begin(on: setup.harness.page(0))

        #expect(second.destination?.lastPathComponent == "report 2.pdf")
        #expect(third.destination?.lastPathComponent == "report 3.pdf", "two downloads were given one name")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "kept")
        #expect(try Self.began(setup.link, at: 1).filename == "report 3.pdf")
    }

    @Test("a completed task download reports its path inside its directory, and its size")
    func completedTaskDownload() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        try download.write("12345")

        download.finish()

        let began = try Self.began(setup.link)
        let path = setup.directory.appendingPathComponent("report.pdf", isDirectory: false).path
        #expect(setup.link.downloads.last == .finished(began.id, tab: setup.tab.id, outcome: .completed(path: path, bytes: 5)))
        #expect(path.hasPrefix(setup.directory.path + "/"), "the engine accepts a path only inside its directory")
        #expect(Self.exists(URL(fileURLWithPath: path)))
    }

    @Test("a task's progress goes on the wire, no more often than the gate lets it")
    func taskProgress() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        let id = try Self.began(setup.link).id

        download.progress(100, of: 10_000)
        download.progress(150, of: 10_000)
        download.progress(250, of: 10_000)
        download.progress(10_000, of: 10_000)

        #expect(Array(setup.link.downloads.dropFirst()) == [
            .progressed(id, received: 100, total: 10_000),
            .progressed(id, received: 250, total: 10_000),
            .progressed(id, received: 10_000, total: 10_000)
        ])
    }

    @Test("a failed task download leaves nothing behind and says why")
    func failedTaskDownload() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        let partial = try #require(download.destination)
        try download.write("half")

        download.fail("The network connection was lost.")

        let id = try Self.began(setup.link).id
        #expect(setup.link.downloads.last == .finished(id, tab: setup.tab.id, outcome: .failed(reason: "The network connection was lost.")))
        #expect(!Self.exists(partial))
    }

    @Test("a download from a task's popup goes into the task's directory, under the popup's tab")
    func popupDownloadGoesIntoTheTasksDirectory() throws {
        let setup = try Self.taskSetup()
        let popup = FakeBrowserPage()
        #expect(setup.harness.page(0).events?.pageOpened(popup) == true)
        let popupTab = try #require(setup.harness.model.tabs.first { $0.id != setup.tab.id })

        let download = Self.begin(on: popup)

        #expect(download.destination?.deletingLastPathComponent().path == setup.directory.path)
        #expect(try Self.began(setup.link).tab == popupTab.id)
    }

    // MARK: - A task's download that does not finish

    @Test("a release cancels a task's download with its terminal event, and nothing it wrote is left")
    func releaseCancels() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        let partial = try #require(download.destination)
        try download.write("half")
        let id = try Self.began(setup.link).id

        setup.harness.coordinator.releaseTask(Self.task)

        let reason = ProductStrings[.browserHostReasonDownloadTabClosed]
        #expect(setup.link.downloads.last == .finished(id, tab: setup.tab.id, outcome: .cancelled(reason: reason)))
        #expect(download.cancels == 1)
        #expect(!Self.exists(partial), "the partial file waited for the engine")

        // The engine was still making the file when it was told to stop.
        try download.write("late")
        download.engineStopped()
        #expect(!Self.exists(partial))
    }

    @Test("tab.close cancels the closed tab's download")
    func tabCloseCancels() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        let id = try Self.began(setup.link).id

        setup.harness.coordinator.closeTaskTab(setup.tab.id)

        let reason = ProductStrings[.browserHostReasonDownloadTabClosed]
        #expect(setup.link.downloads.last == .finished(id, tab: setup.tab.id, outcome: .cancelled(reason: reason)))
        #expect(download.cancels == 1)
    }

    /// The daemon forgets a tab at `tab.closed`, and drops a download's end
    /// that arrives after it.
    @Test("a page closing its own window ends its download before the daemon hears the tab closed")
    func pageCloseCancelsBeforeTabClosed() throws {
        let setup = try Self.taskSetup()
        let popup = FakeBrowserPage()
        _ = setup.harness.page(0).events?.pageOpened(popup)
        let download = Self.begin(on: popup)

        popup.events?.pageAskedToClose()

        #expect(download.cancels == 1)
        #expect(Array(setup.link.events.suffix(2)) == ["download.finished", "tab.closed"])
    }

    @Test("the person's cancel of a task ends its download with the release that follows")
    func personCancelEndsWithTheRelease() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))

        setup.harness.coordinator.close(setup.tab)
        #expect(setup.link.cancelled == [Self.task])
        #expect(download.cancels == 0, "the tab stays until the task's release")

        setup.harness.coordinator.releaseTask(Self.task)
        #expect(download.cancels == 1)
        #expect(setup.link.events.last == "download.finished")
    }

    @Test("losing the daemon cancels a task's download, with nobody left to tell")
    func detachCancelsSilently() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        let partial = try #require(download.destination)
        try download.write("half")
        let heard = setup.link.downloads.count

        setup.harness.coordinator.hostDetached(setup.connection)

        #expect(download.cancels == 1)
        #expect(setup.link.downloads.count == heard, "an event went to a connection that is gone")
        #expect(!Self.exists(partial))
    }

    @Test("a quit ends a task's download before host_stopping")
    func quitCancelsBeforeHostStopping() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        let id = try Self.began(setup.link).id

        setup.harness.coordinator.stopHost {}

        let reason = ProductStrings[.browserHostReasonAppTerminating]
        #expect(setup.link.downloads.last == .finished(id, tab: setup.tab.id, outcome: .cancelled(reason: reason)))
        #expect(Array(setup.link.events.suffix(2)) == ["download.finished", "host_stopping"])
        #expect(download.cancels == 1)
    }

    @Test("a download the daemon never heard begin ends without a word")
    func unannouncedDownloadEndsSilently() throws {
        let setup = try Self.taskSetup()
        let download = FakeDownload()
        setup.harness.page(0).events?.pageStartedDownload(download)

        setup.harness.coordinator.releaseTask(Self.task)

        #expect(download.cancels == 1)
        #expect(setup.link.downloads.isEmpty)
    }

    @Test("an ended download reports nothing more")
    func endedDownloadIsQuiet() throws {
        let setup = try Self.taskSetup()
        let download = Self.begin(on: setup.harness.page(0))
        try download.write("whole")
        download.finish()
        let heard = setup.link.downloads.count

        download.fail("late")
        download.finish()
        setup.harness.coordinator.releaseTask(Self.task)

        #expect(setup.link.downloads.count == heard)
        #expect(download.cancels == 0)
    }

    // MARK: - The person's download

    @Test("the person's download asks where to save it, and nothing crosses the wire")
    func personDownloadAsks() throws {
        let (harness, _, _) = try Self.personSetup()
        let link = FakeHostLink()
        _ = harness.coordinator.hostAttached(link, caps: BrowserTabCaps(perTask: 3, global: 6))

        let download = Self.begin(FakeDownload(suggestedFilename: ".hidden/report.pdf"), on: harness.page(0))

        #expect(harness.pane.savePanels == ["hidden_report.pdf"])
        #expect(!download.answered, "the download went on before the person answered")
        #expect(link.downloads.isEmpty)
    }

    @Test("cancelling the save panel cancels the download, with nothing said")
    func savePanelCancelled() throws {
        let (harness, _, _) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))

        harness.pane.answerSavePanel(nil)

        #expect(download.answered)
        #expect(download.destination == nil)
        #expect(harness.model.notice == nil)

        _ = Self.begin(on: harness.page(0))
        #expect(harness.pane.savePanels.count == 2, "a cancelled panel kept the next one from asking")
    }

    @Test("a place the person chose says the file is on its way, then that it is saved")
    func personDownloadSaved() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))
        let chosen = folder.appendingPathComponent("report.pdf", isDirectory: false)

        harness.pane.answerSavePanel(chosen)

        #expect(download.destination == chosen)
        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadingFormat], "report.pdf"))

        try download.write("whole")
        download.finish()

        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadSavedFormat], "report.pdf"))
        #expect(Self.exists(chosen))
    }

    @Test("a person's download that fails leaves nothing behind and says why")
    func personDownloadFailed() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))
        let chosen = folder.appendingPathComponent("report.pdf", isDirectory: false)
        harness.pane.answerSavePanel(chosen)
        try download.write("half")

        download.fail("The network connection was lost.")

        #expect(!Self.exists(chosen))
        #expect(
            harness.model.notice
                == String(format: ProductStrings[.browserNoticeDownloadFailedFormat], "report.pdf", "The network connection was lost.")
        )
    }

    /// WebKit refuses to write over a file, so the one the person agreed to
    /// replace in the panel goes first.
    @Test("a file the person agreed to replace is cleared for the download")
    func replacedFileIsCleared() throws {
        let (harness, _, folder) = try Self.personSetup()
        let chosen = folder.appendingPathComponent("report.pdf", isDirectory: false)
        try Data("old".utf8).write(to: chosen)
        let download = Self.begin(on: harness.page(0))

        harness.pane.answerSavePanel(chosen)

        #expect(download.destination == chosen)
        #expect(!Self.exists(chosen))
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
        #expect(harness.pane.savePanels.isEmpty)
    }

    @Test("one save panel at a time: a second download while one is up is cancelled")
    func oneSavePanelAtATime() throws {
        let (harness, _, _) = try Self.personSetup()
        let first = Self.begin(on: harness.page(0))

        let second = Self.begin(on: harness.page(0))

        #expect(harness.pane.savePanels.count == 1)
        #expect(!first.answered)
        #expect(second.answered && second.destination == nil)
    }

    @Test("the person's download goes on when its tab is closed, as a browser's does")
    func personDownloadOutlivesItsTab() throws {
        let (harness, tab, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))
        harness.pane.answerSavePanel(folder.appendingPathComponent("report.pdf", isDirectory: false))

        harness.coordinator.close(tab)
        try download.write("whole")
        download.finish()

        #expect(download.cancels == 0)
        #expect(harness.model.notice == String(format: ProductStrings[.browserNoticeDownloadSavedFormat], "report.pdf"))
    }

    @Test("a quit stops the person's download and removes what it wrote")
    func quitStopsThePersonsDownload() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))
        let chosen = folder.appendingPathComponent("report.pdf", isDirectory: false)
        harness.pane.answerSavePanel(chosen)
        try download.write("half")

        harness.coordinator.stopHost {}

        #expect(download.cancels == 1)
        #expect(!Self.exists(chosen))
    }

    @Test("a quit while the panel is up cancels the download the panel then answers")
    func quitWhileThePanelIsUp() throws {
        let (harness, _, folder) = try Self.personSetup()
        let download = Self.begin(on: harness.page(0))

        harness.coordinator.stopHost {}
        harness.pane.answerSavePanel(folder.appendingPathComponent("report.pdf", isDirectory: false))

        #expect(download.cancels == 1)
        #expect(download.answered && download.destination == nil)
    }
}

/// A task's download on the host wire itself, through the client and the
/// real coordinator: the contract's own shapes, the `download_dir` check,
/// and the order of a download's end against a release's answer.
@Suite("Browser download wire")
@MainActor
struct BrowserDownloadWireTests {
    private typealias Transport = FakeLineSocketTransport<BrowserHostInbound, BrowserHostDecodeFailure>

    /// A client attached over the real coordinator, with the engine's browser
    /// directory made in a throwaway home.
    private struct Wire {
        let harness: BrowserHarness
        let client: BrowserHostClient
        let transport: Transport
        let browserRoot: URL
    }

    private static func attached() throws -> Wire {
        let harness = BrowserHarness()
        let transport = Transport()
        let browserRoot = try BrowserDownloadsTests.throwaway("browser")
        let client = BrowserHostClient(
            lines: transport,
            socketPath: { "/tmp/fermix-test/browser_host.sock" },
            profileID: { "profile-1" },
            workspaceRoot: { browserRoot.deletingLastPathComponent().appendingPathComponent("workspace", isDirectory: true) },
            browserRoot: { browserRoot },
            hostVersion: "0.2.0",
            coordinator: harness.coordinator,
            deadlines: ManualDeadlineScheduler()
        )
        client.connect()
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))

        return Wire(harness: harness, client: client, transport: transport, browserRoot: browserRoot)
    }

    private static func tabOpen(id: Int, downloadDir: String) -> BrowserHostRequest {
        .tabOpen(id: id, BrowserHostTabOpenRequest(
            taskId: "task-1", url: "https://example.com/", observe: false, downloadDir: downloadDir,
            taskTabCap: 10, tabCap: 60, snapshot: nil, visible: nil
        ))
    }

    /// The answer to request `id`, once the client has sent it.
    private static func answer(_ id: Int, on transport: Transport) async throws -> NSDictionary {
        for _ in 0..<2000 {
            if try transport.sentObjects().contains(where: { $0["id"] as? Int == id }) { break }
            await Task.yield()
        }

        return try #require(transport.sentObjects().first { $0["id"] as? Int == id })
    }

    private static func lines(_ type: String, on transport: Transport) throws -> [NSDictionary] {
        try transport.sentObjects().filter { $0["type"] as? String == type }
    }

    /// A fixture line with this build's ids in place of the fixture's own.
    private static func golden(_ index: Int, downloadID: UUID, tabID: UUID) throws -> NSDictionary {
        var object = try BrowserHostFixtures.load(.events)[index].object
        object["download_id"] = downloadID.uuidString
        if object["tab_id"] != nil { object["tab_id"] = tabID.uuidString }

        return NSDictionary(dictionary: object)
    }

    @Test("each download event the link sends is the contract's own shape")
    func linkSendsTheContractsShapes() throws {
        let wire = try Self.attached()
        let download = UUID()
        let tab = UUID()
        let path = "/Users/person/.fermix/workspace/browser/downloads/0bqP3d/report.pdf"
        let before = wire.transport.sent.count

        wire.client.downloadBegan(download, tab: tab, filename: "report.pdf")
        wire.client.downloadProgressed(download, receivedBytes: 65_536, totalBytes: 91_022)
        wire.client.downloadFinished(download, tab: tab, outcome: .completed(path: path, bytes: 91_022))
        wire.client.downloadFinished(download, tab: tab, outcome: .failed(reason: "the server closed the connection"))
        wire.client.downloadFinished(download, tab: tab, outcome: .cancelled(reason: "its tab closed"))

        let sent = try Array(wire.transport.sentObjects().dropFirst(before))
        try #require(sent.count == 5)
        #expect(try sent[0] == Self.golden(8, downloadID: download, tabID: tab))
        #expect(try sent[1] == Self.golden(9, downloadID: download, tabID: tab))
        #expect(try sent[2] == Self.golden(10, downloadID: download, tabID: tab))
        #expect(try sent[3] == Self.golden(11, downloadID: download, tabID: tab))
        #expect(sent[4] == NSDictionary(dictionary: [
            "type": "download.finished",
            "download_id": download.uuidString,
            "tab_id": tab.uuidString,
            "state": "cancelled",
            "reason": "its tab closed"
        ]))
    }

    /// The daemon refuses an empty or overlong reason and closes the
    /// connection over it.
    @Test("a download's reason is never empty and never past the contract's cap")
    func reasonIsBounded() throws {
        let empty = try wireObject(BrowserHostEvent.downloadFinished(
            downloadId: "d1", tabId: "t1", state: .failed, path: nil, bytes: nil, reason: ""
        ).line())
        let long = try wireObject(BrowserHostEvent.downloadFinished(
            downloadId: "d1", tabId: "t1", state: .failed, path: nil, bytes: nil,
            reason: String(repeating: "x", count: 600)
        ).line())

        #expect(empty["reason"] == nil)
        #expect((long["reason"] as? String)?.count == BrowserHostProtocol.maximumMessageChars)
    }

    @Test("a tab.open whose download_dir is outside the engine's browser directory is refused")
    func downloadDirOutsideIsRefused() async throws {
        let wire = try Self.attached()

        wire.transport.deliver(.request(Self.tabOpen(id: 7, downloadDir: "/tmp/elsewhere/downloads")))

        let response = try await Self.answer(7, on: wire.transport)
        #expect(response["ok"] as? Bool == false)
        #expect((response["error"] as? [String: Any])?["reason"] as? String == "invalid_request")
        #expect(wire.harness.model.tabs.isEmpty)
        #expect(wire.harness.model.host.downloadDirectories.isEmpty)
    }

    @Test("a task's download crosses the wire from tab.open to a completed download.finished")
    func taskDownloadEndToEnd() async throws {
        let wire = try Self.attached()
        let downloadDir = wire.browserRoot.appendingPathComponent("downloads/0bqP3d", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        wire.transport.deliver(.request(Self.tabOpen(id: 7, downloadDir: downloadDir.path)))
        let opened = try await Self.answer(7, on: wire.transport)
        let tabID = try #require((opened["result"] as? [String: Any])?["tab_id"] as? String)

        let download = BrowserDownloadsTests.begin(on: wire.harness.page(0))
        try download.write("12345")
        download.finish()

        let began = try #require(try Self.lines("download.began", on: wire.transport).first)
        let finished = try #require(try Self.lines("download.finished", on: wire.transport).first)
        #expect(began["tab_id"] as? String == tabID)
        #expect(began["filename"] as? String == "report.pdf")
        #expect(finished["download_id"] as? String == began["download_id"] as? String)
        #expect(finished["state"] as? String == "completed")
        #expect(finished["bytes"] as? Int == 5)
        let path = try #require(finished["path"] as? String)
        // The engine's own check, on the string it sent.
        #expect(path.hasPrefix(downloadDir.path + "/"))
        #expect(path == downloadDir.path + "/report.pdf")
    }

    @Test("a release mid-download sends the download's end before the release's answer")
    func releaseSendsTheEndFirst() async throws {
        let wire = try Self.attached()
        let downloadDir = wire.browserRoot.appendingPathComponent("downloads/0bqP3d", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        wire.transport.deliver(.request(Self.tabOpen(id: 7, downloadDir: downloadDir.path)))
        _ = try await Self.answer(7, on: wire.transport)
        _ = BrowserDownloadsTests.begin(on: wire.harness.page(0))

        wire.transport.deliver(.request(.taskRelease(id: 8, taskId: "task-1")))

        let sent = try wire.transport.sentObjects()
        let finished = try #require(sent.firstIndex { $0["type"] as? String == "download.finished" })
        let released = try #require(sent.firstIndex { $0["id"] as? Int == 8 })
        #expect(finished < released)
        #expect(sent[finished]["state"] as? String == "cancelled")
        #expect(sent[finished]["reason"] as? String == ProductStrings[.browserHostReasonDownloadTabClosed])
    }
}
