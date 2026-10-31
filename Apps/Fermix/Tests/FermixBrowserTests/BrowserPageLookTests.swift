import FermixAppCore
import Foundation
import Testing

@testable import FermixBrowser

/// What a look reads on a real web view: an act the
/// engine does not look after takes no look, an act it does look after waits
/// out the page's own change and reads it once it holds still, without
/// waiting for a load the act did not start, the look after a navigation
/// waits for that navigation's own commit and reads the loaded page, the
/// fingerprint sees a change of words, a snapshot says how far its document
/// had loaded, and a wait for a load ends with the load, its interruption,
/// its failure or its budget, never with an earlier navigation's ending.
/// The looks run on their own clock: a page that never moves costs the whole
/// settle budget, and nothing here sleeps beyond the page's own timer.
@MainActor
@Suite("Browser page looks", .serialized, .timeLimit(.minutes(1)))
struct BrowserPageLookTests {
    private static let address = "https://shop.example.com/choose"
    private static let nextAddress = "https://shop.example.com/next"
    private static let look = BrowserSnapshotRequest(mode: .full, maxChars: 50_000, depth: 50)
    /// A page whose choice is written out a moment after the change, by the
    /// page's own timer, and which already shows the first choice.
    private static let delayedPage = """
        <!doctype html><html><head><title>Choose a size</title></head><body>
        <label for="size">Size</label>
        <select id="size" onchange="const chosen = this.value; setTimeout(() => { document.getElementById('out').textContent = 'You chose the ' + chosen + ' size'; }, 100)">
          <option value="small">Small</option>
          <option value="medium">Medium</option>
        </select>
        <p id="out">You chose the small size</p>
        </body></html>
        """
    /// A file page whose choice leaves for the file beside it.
    private static let leavingPage = """
        <!doctype html><html><head><title>Choose a size</title></head><body>
        <label for="size">Size</label>
        <select id="size" onchange="location.href = 'next.html'">
          <option value="small">Small</option>
          <option value="large">Large</option>
        </select>
        </body></html>
        """
    private static let nextPage = """
        <!doctype html><html><head><title>Next</title></head><body><p>The next page</p></body></html>
        """
    private static let page = """
        <!doctype html><html><head><title>Choose a size</title></head><body>
        <label for="size">Size</label>
        <select id="size" onchange="document.getElementById('out').textContent = 'You chose the ' + this.value + ' size'">
          <option value="small">Small</option>
          <option value="large">Large</option>
        </select>
        <p id="out"></p>
        </body></html>
        """

    @Test("an act the engine does not look after answers unobserved, though the page changed under it")
    func unobservedActTakesNoLook() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)
        let ref = try await harness.ref(role: "combobox")

        let outcome = try await harness.page.act(.select(ref: ref, value: "large"), observing: nil)

        #expect(outcome.effect == .unobserved, "no look was taken, so no snapshot came back")
        #expect(outcome.value == "large")
        #expect(outcome.url == Self.address)
        #expect(try await harness.pageString("document.getElementById('out').textContent") == "You chose the large size")
    }

    @Test("an act the engine looks after waits out the page's own delayed change and reads the page once it holds still")
    func delayedChangeIsReadOnceItRests() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.delayedPage, at: Self.address)
        let ref = try await harness.ref(role: "combobox")

        let outcome = try await harness.page.act(.select(ref: ref, value: "medium"), observing: Self.look)

        guard case .changed(let snapshot) = outcome.effect else {
            Issue.record("the page changed after the act, so its look reads it: \(outcome.effect)")
            return
        }
        #expect(snapshot.nodes.contains { $0.name.contains("You chose the medium size") }, "the page as its timer left it")
        #expect(outcome.value == "medium")
    }

    @Test("an act that leaves the page as it was answers unchanged once the settle budget is spent, and reads nothing")
    func sameChoiceIsUnchanged() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.delayedPage, at: Self.address)
        let ref = try await harness.ref(role: "combobox")

        let outcome = try await harness.page.act(.select(ref: ref, value: "small"), observing: Self.look)

        #expect(outcome.effect == .unchanged, "the timer wrote the words already there")
        #expect(outcome.value == "small")
    }

    @Test("an act that changes a page still loading something it did not start is read once the page rests, not when that load ends")
    func loadInFlightBeforeTheActIsNotWaitedFor() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.delayedPage, at: Self.address)
        let ref = try await harness.ref(role: "combobox")
        try await harness.hold(Self.page, at: Self.nextAddress)
        defer { harness.release(.cancel) }
        #expect(harness.webView.isLoading, "a load the act did not start is in flight")
        let waits = LoadWaits()

        let outcome = try await harness.actions(recording: waits).perform(.select(ref: ref, value: "medium"), observing: Self.look)

        #expect(waits.budgets.isEmpty, "the look never waited for the load the act did not start")
        guard case .changed(let snapshot) = outcome.effect else {
            Issue.record("the page changed after the act, so its look reads it: \(outcome.effect)")
            return
        }
        #expect(snapshot.nodes.contains { $0.name.contains("You chose the medium size") })
    }

    @Test("an act that starts a navigation waits for its load with the navigation budget, then reads the new page")
    func navigationTheActStartsIsWaitedFor() async throws {
        try await Self.withPageFile(Self.leavingPage) { file in
            let next = file.deletingLastPathComponent().appending(path: "next.html", directoryHint: .notDirectory)
            try Data(Self.nextPage.utf8).write(to: next)
            let harness = BrowserPageHarness()
            try await harness.load(file: file)
            let ref = try await harness.ref(role: "combobox")
            harness.holdNextResponse()
            defer { harness.releaseResponse(.cancel) }
            let waits = LoadWaits()
            waits.whenAsked = { harness.releaseResponse(.allow) }

            let outcome = try await harness.actions(recording: waits).perform(.select(ref: ref, value: "large"), observing: Self.look)

            #expect(waits.budgets == [BrowserPageSettle.navigationBudget], "the act's own navigation, held until the look waited for it")
            guard case .changed(let snapshot) = outcome.effect else {
                Issue.record("the act left the page, so its look reads the new one: \(outcome.effect)")
                return
            }
            #expect(snapshot.title == "Next")
        }
    }

    @Test("an act's address is the document the page shows, not a load still waiting to commit")
    func addressIsTheShownDocument() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            try await harness.load(file: file)
            let shown = try #require(harness.webView.url?.absoluteString)
            let ref = try await harness.ref(role: "combobox")
            try await harness.hold(Self.page, at: Self.nextAddress)
            defer { harness.release(.cancel) }
            #expect(harness.webView.url?.absoluteString == Self.nextAddress, "WebKit already names the load in flight")

            let outcome = try await harness.page.act(.select(ref: ref, value: "large"), observing: nil)

            #expect(outcome.url == shown)
        }
    }

    @Test("a wait whose budget runs out on a load still in flight answers not loaded, and leaves no waiter behind")
    func waitOutlivedByItsLoad() async throws {
        let harness = BrowserPageHarness()
        try await harness.hold(Self.page, at: Self.address)
        defer { harness.release(.cancel) }
        #expect(harness.webView.isLoading)

        let loaded = try await harness.page.waitForLoad(within: .milliseconds(20))

        #expect(!loaded)
        #expect(harness.page.readyWaiters.isEmpty, "the waiter left the list when its budget ran out")
    }

    @Test("a wait parked on a load in flight is released loaded once the load finishes")
    func waitReleasedByItsLoad() async throws {
        let harness = BrowserPageHarness()
        try await harness.hold(Self.page, at: Self.address)
        defer { harness.release(.cancel) }
        #expect(harness.webView.isLoading, "the wait below parks rather than answering at once")

        let letting = Task { @MainActor in harness.release(.allow) }
        let loaded = try await harness.page.waitForLoad(within: .seconds(8))
        await letting.value

        #expect(loaded)
        #expect(harness.page.readyWaiters.isEmpty)
        #expect(try await harness.pageString("document.title") == "Choose a size")
    }

    @Test("a wait parked on a load that is interrupted, as a download interrupts one, is released loaded")
    func waitReleasedByAnInterruptedLoad() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            await harness.holdResponse(file: file)
            defer { harness.releaseResponse(.allow) }
            #expect(harness.webView.isLoading, "the wait below parks rather than answering at once")

            let interrupting = Task { @MainActor in harness.releaseResponse(.cancel) }
            let loaded = try await harness.page.waitForLoad(within: .seconds(8))
            await interrupting.value

            #expect(loaded, "an interruption fails nothing, and its budget did not run out")
            #expect(harness.page.readyWaiters.isEmpty)
            #expect(!harness.webView.isLoading)
            #expect(harness.loadingAtEnd == [false], "the interruption was the last load's")
        }
    }

    @Test("a wait parked on a load that fails throws the failure")
    func waitFailedByItsLoad() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            await harness.hold(file: file.deletingLastPathComponent().appending(path: "missing.html", directoryHint: .notDirectory))
            defer { harness.release(.cancel) }
            #expect(harness.webView.isLoading, "the wait below parks rather than answering at once")

            let letting = Task { @MainActor in harness.release(.allow) }
            do {
                _ = try await harness.page.waitForLoad(within: .seconds(8))
                Issue.record("a file that is not there fails the load, and the wait on it")
            } catch {
                #expect(Self.isNavigationFailure(error), "\(error)")
            }
            await letting.value
            #expect(harness.page.readyWaiters.isEmpty)
            #expect(harness.loadingAtEnd == [false], "the failure was the last load's")
        }
    }

    @Test("the look after a navigation waits for its load, then reads the new page once it holds still")
    func navigationLookReadsTheLoadedPage() async throws {
        let harness = BrowserPageHarness()
        try await harness.hold(Self.page, at: Self.address)
        defer { harness.release(.cancel) }

        let letting = Task { @MainActor in harness.release(.allow) }
        let snapshot = try await harness.page.snapshotAfterNavigation(Self.look)
        await letting.value

        #expect(snapshot.url == Self.address)
        #expect(snapshot.title == "Choose a size")
        #expect(snapshot.readyState == .complete)
        #expect(snapshot.nodes.contains { $0.role == "combobox" })
        #expect(harness.page.navigationsStarted > 0, "the page counted the navigation it waited for")
    }

    @Test("the look after a navigation whose response is held past every load budget reads the new page once it commits, never the page it leaves")
    func navigationHeldBeforeItsCommitIsReadOnceItCommits() async throws {
        try await Self.withPageFile(Self.page) { file in
            let next = try Self.writeNextPage(beside: file)
            let harness = BrowserPageHarness()
            try await harness.load(file: file)
            await harness.holdResponse(file: next)
            defer { harness.releaseResponse(.cancel) }
            let waits = LoadWaits()
            waits.outlived = { harness.holdsResponse }
            waits.whenCommitAsked = { harness.releaseResponse(.allow) }

            let snapshot = try await harness.actions(recording: waits).lookAfterNavigation(Self.look)

            #expect(snapshot.title == "Next", "neither the page it leaves nor the empty document")
            #expect(snapshot.url.hasSuffix("/next.html"), "\(snapshot.url)")
            #expect(waits.commitBudgets == [BrowserPageSettle.navigationTimeout], "held until the look waited for its commit")
            #expect(waits.budgets == [BrowserPageSettle.navigationBudget], "its load had the whole budget, from the commit")
            #expect(harness.page.commitWaiters.isEmpty)
        }
    }

    @Test("the look after a navigation that does not commit within its timeout fails as one that ended without a page, naming the address")
    func navigationThatNeverCommitsFails() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            try await harness.load(Self.page, at: Self.address)
            await harness.holdResponse(file: file)
            defer { harness.releaseResponse(.cancel) }
            let waits = LoadWaits()
            waits.outlived = { harness.holdsResponse }

            do {
                let snapshot = try await harness.actions(recording: waits).lookAfterNavigation(Self.look, within: .milliseconds(50))
                Issue.record("a navigation that never commits is not read: \(snapshot.url)")
            } catch {
                let reason = try #require(Self.navigationFailure(error), "\(error)")
                #expect(reason.hasPrefix("the page did not start loading within "), "\(reason)")
                #expect(reason.hasSuffix("/choose.html"), "\(reason)")
            }
            #expect(waits.commitBudgets == [.milliseconds(50)])
            #expect(waits.budgets.isEmpty, "no load waited for, and nothing read")
            #expect(harness.page.commitWaiters.isEmpty, "the wait left the list when its timeout ran out")
        }
    }

    @Test("a commit WebKit tells of an earlier navigation is not the requested one's, so the wait for that commit stays parked")
    func earlierCommitIsNotTheRequestedOnes() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            try await harness.load(Self.delayedPage, at: Self.address)
            let earlier = try #require(harness.finished.last)
            await harness.holdResponse(file: file)
            defer { harness.releaseResponse(.cancel) }

            let late = Task { @MainActor in
                harness.page.webView(harness.webView, didCommit: earlier)
                let parked = harness.page.commitWaiters.count
                harness.releaseResponse(.allow)
                return parked
            }
            let committed = try await harness.page.waitForCommit(within: .seconds(8))

            #expect(await late.value == 1, "the earlier navigation's commit released nothing")
            #expect(committed)
            #expect(harness.page.commitWaiters.isEmpty)
        }
    }

    @Test("a finish WebKit tells of an earlier navigation leaves a wait on the load in flight parked, and that load's own finish releases it")
    func earlierFinishLeavesTheWaitParked() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.delayedPage, at: Self.address)
        let earlier = try #require(harness.finished.last)
        try await harness.hold(Self.page, at: Self.nextAddress)
        defer { harness.release(.cancel) }

        let late = Task { @MainActor in
            harness.page.webView(harness.webView, didFinish: earlier)
            let parked = harness.page.readyWaiters.count
            harness.release(.allow)
            return parked
        }
        let loaded = try await harness.page.waitForLoad(within: .seconds(8))

        #expect(await late.value == 1, "the earlier navigation's finish released nothing")
        #expect(loaded)
        #expect(try await harness.pageString("location.href") == Self.nextAddress, "released by the load it waited on")
    }

    @Test("WebKit reports nothing loading by the time it tells of a load's finish or failure, so the last load's ending is the one that releases waits")
    func nothingLoadsAtTheLastEnding() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            try await harness.load(file: file)
            let missing = file.deletingLastPathComponent().appending(path: "missing.html", directoryHint: .notDirectory)

            await #expect(throws: (any Error).self) { try await harness.load(file: missing) }

            #expect(harness.loadingAtEnd == [false, false], "a finish, then a failure")
        }
    }

    @Test("the look after a navigation within the document shown reads it with no wait run out: WebKit tells of no commit for it")
    func navigationWithinTheDocumentIsReadAtOnce() async throws {
        try await Self.withPageFile(Self.page) { file in
            let harness = BrowserPageHarness()
            try await harness.load(file: file)
            harness.move(within: try requireURL(file.absoluteString + "#out"), readAccess: file.deletingLastPathComponent())
            let waits = LoadWaits()

            let snapshot = try await harness.actions(recording: waits).lookAfterNavigation(Self.look, within: .seconds(5))

            #expect(snapshot.title == "Choose a size")
            #expect(snapshot.url.hasSuffix("#out"), "\(snapshot.url)")
            #expect(waits.answers.allSatisfy { $0 }, "each wait ended with its navigation, not its budget: \(waits.answers)")
            #expect(harness.page.commitWaiters.isEmpty)
        }
    }

    @Test("the fingerprint counts the body's text, so a change of words alone moves the page")
    func fingerprintSeesATextOnlyChange() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)
        let before: BrowserPageFingerprint = try await harness.call("fingerprint", [])

        try await harness.pageWorld("document.getElementById('out').textContent = 'Saved';")
        let after: BrowserPageFingerprint = try await harness.call("fingerprint", [])

        #expect(after.elements == before.elements)
        #expect(after.text == before.text + "Saved".count)
        #expect(!after.isSamePage(as: before))
    }

    @Test("a snapshot says how far its document had loaded")
    func snapshotCarriesTheReadyState() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)

        let snapshot = try await harness.page.snapshot(BrowserSnapshotRequest(mode: .interactive, maxChars: 50_000, depth: 50))

        #expect(snapshot.readyState == .complete)
        #expect(!snapshot.tabLoading)
        #expect(snapshot.reportedReadyState == .complete)
    }

    @Test("a snapshot read while a load is in flight says the tab was loading, so its complete document reports loading")
    func snapshotReadDuringALoad() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)
        try await harness.hold(Self.page, at: Self.nextAddress)
        defer { harness.release(.cancel) }

        let snapshot = try await harness.page.snapshot(BrowserSnapshotRequest(mode: .interactive, maxChars: 50_000, depth: 50))

        #expect(snapshot.readyState == .complete, "the document being left")
        #expect(snapshot.tabLoading)
        #expect(snapshot.reportedReadyState == .loading)
    }
}

private extension BrowserPageLookTests {
    /// Writes `html` to a file in a folder of its own for the length of
    /// `body`, and removes the folder on every path.
    static func withPageFile(_ html: String, _ body: @MainActor (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "fermix-look-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { removeFolder(folder) }

        let file = folder.appending(path: "choose.html", directoryHint: .notDirectory)
        try Data(html.utf8).write(to: file)
        try await body(file)
    }

    static func isNavigationFailure(_ error: any Error) -> Bool {
        navigationFailure(error) != nil
    }

    /// The reason a navigation ended without a page, nil for any other error.
    static func navigationFailure(_ error: any Error) -> String? {
        guard let error = error as? BrowserPageDriveError, case .navigationFailed(let reason) = error else { return nil }

        return reason
    }

    /// Writes the page titled "Next" beside `file`, as `next.html`.
    static func writeNextPage(beside file: URL) throws -> URL {
        let next = file.deletingLastPathComponent().appending(path: "next.html", directoryHint: .notDirectory)
        try Data(nextPage.utf8).write(to: next)
        return next
    }

    static func removeFolder(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Issue.record(error, "the page file's folder stayed behind")
        }
    }
}

/// Every budget a look asked the page to wait for a load with, and for its
/// navigation's commit, in order, what each wait answered, and what the case
/// does as each is asked.
@MainActor
private final class LoadWaits {
    private(set) var budgets: [Duration] = []
    private(set) var commitBudgets: [Duration] = []
    /// What each wait answered, commit and load, in order: false is a budget
    /// that ran out.
    private(set) var answers: [Bool] = []
    var whenAsked: @MainActor () -> Void = {}
    var whenCommitAsked: @MainActor () -> Void = {}
    /// Whether a load wait asked for now runs out its budget at once, as one
    /// on a response held past every budget does.
    var outlived: @MainActor () -> Bool = { false }

    func record(_ budget: Duration) {
        budgets.append(budget)
        whenAsked()
    }

    func recordCommit(_ budget: Duration) {
        commitBudgets.append(budget)
        whenCommitAsked()
    }

    func answer(_ answer: Bool) -> Bool {
        answers.append(answer)
        return answer
    }
}

private extension BrowserPageHarness {
    /// The page's act kinds on its own script, wired as `pageActions()` wires
    /// them, with every wait a look asks for recorded in `waits` before it
    /// reaches the page, and its answer after; a load wait `waits` says is
    /// outlived answers at once that its budget ran out.
    func actions(recording waits: LoadWaits) throws -> WebKitPageActions {
        WebKitPageActions(
            webView: webView,
            script: try page.pageScriptResult.get(),
            expectUpload: { _ in },
            waitForLoad: { budget in
                waits.record(budget)
                guard !waits.outlived() else { return waits.answer(false) }
                return waits.answer(try await self.page.waitForLoad(within: budget))
            },
            waitForCommit: { budget in
                waits.recordCommit(budget)
                return waits.answer(try await self.page.waitForCommit(within: budget))
            },
            navigations: { self.page.navigationsStarted }
        )
    }

    /// The ref of the first node with `role`, from the page script's own snapshot.
    func ref(role: String) async throws -> Int {
        let snapshot = try await page.snapshot(BrowserSnapshotRequest(mode: .full, maxChars: 200_000, depth: 200))
        return try #require(snapshot.nodes.first { $0.role == role }?.ref)
    }
}
