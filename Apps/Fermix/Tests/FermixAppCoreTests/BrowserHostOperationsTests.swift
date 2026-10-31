import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The operations that answered `not yet implemented` or the wrong shape
/// after the wire client's first end-to-end run: `page.act`'s `get` and
/// `wait`, `page.screenshot`, `page.pdf`, `cookies.get`/`cookies.clear`, the
/// tab caps `tab.open` itself names, and a popup's opener carried into
/// `tab.list`.
///
/// Driven against `FakeHostCoordinator`, the seam `BrowserHostCoordinating`
/// exists for, rather than the whole `BrowserCoordinator`: what matters here
/// is the client's own dispatch, not the coordinator's tab placement or
/// engine building.
@MainActor
@Suite("Browser host operations")
struct BrowserHostOperationsTests {
    private typealias Transport = FakeLineSocketTransport<BrowserHostInbound, BrowserHostDecodeFailure>

    // MARK: - get

    @Test("page.act get answers a text field as a string")
    func getAnswersATextField() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.actResult = .success(
            BrowserActOutcome(effect: .unobserved, input: .scripted, url: "https://example.com/", read: .text("hello"))
        )

        let response = try await Self.send(
            transport,
            .pageAct(id: 10, Self.actRequest(tab.wireID, kind: .get, field: .text))
        )

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["value"] as? String == "hello")
        #expect(tab.page.actedOn == [.get(field: .text, selector: nil)])
        _ = client
    }

    @Test("page.act get field=count answers a number")
    func getAnswersACount() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.actResult = .success(
            BrowserActOutcome(effect: .unobserved, input: .scripted, url: "https://example.com/", read: .count(5))
        )

        let response = try await Self.send(
            transport,
            .pageAct(id: 10, Self.actRequest(tab.wireID, kind: .get, field: .count))
        )

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["value"] as? Int == 5)
        _ = client
    }

    @Test("page.act get field=rect answers the box")
    func getAnswersARect() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.actResult = .success(
            BrowserActOutcome(
                effect: .unobserved, input: .scripted, url: "https://example.com/",
                read: .rect(BrowserRect(x: 1, y: 2, width: 3, height: 4))
            )
        )

        let response = try await Self.send(
            transport,
            .pageAct(id: 10, Self.actRequest(tab.wireID, kind: .get, field: .rect, selector: "#a"))
        )

        let result = try #require(response["result"] as? [String: Any])
        let value = try #require(result["value"] as? [String: Any])
        #expect(value["x"] as? Double == 1)
        #expect(value["height"] as? Double == 4)
        #expect(tab.page.actedOn == [.get(field: .rect, selector: "#a")])
        _ = client
    }

    // MARK: - wait

    @Test("page.act wait forwards its condition and answers once it holds")
    func waitAnswersOnceTrue() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.actResult = .success(
            BrowserActOutcome(effect: .unobserved, input: .scripted, url: "https://example.com/")
        )

        let response = try await Self.send(
            transport,
            .pageAct(id: 10, Self.actRequest(
                tab.wireID, kind: .wait, selector: "#a", waitUntil: .element, timeoutMs: 500
            ))
        )

        #expect(response["ok"] as? Bool == true)
        #expect(tab.page.actedOn == [.wait(until: .element, text: nil, selector: "#a", ref: nil, timeoutMs: 500)])
        _ = client
    }

    @Test("a wait that never becomes true answers wait_timeout")
    func waitTimesOut() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.actResult = .failure(BrowserPageDriveError.waitTimedOut)

        let response = try await Self.send(
            transport,
            .pageAct(id: 10, Self.actRequest(
                tab.wireID, kind: .wait, text: "done", waitUntil: .text, timeoutMs: 100
            ))
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "wait_timeout")
        _ = client
    }

    // MARK: - screenshot

    @Test("a screenshot path outside the engine's browser directory is refused before any capture")
    func screenshotOutsideBrowserDirectoryRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let outside = "/tmp/fermix-host-ops-outside/\(UUID().uuidString).png"

        let response = try await Self.send(
            transport,
            .pageScreenshot(id: 10, BrowserHostPageScreenshotRequest(tabId: tab.wireID, fullPage: false, path: outside))
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "write_failed")
        #expect(tab.page.screenshotFullPageRequests.isEmpty, "the path was refused before any capture was taken")
        #expect(!FileManager.default.fileExists(atPath: outside))
        _ = client
    }

    @Test("a screenshot path inside the upload workspace is refused: captures have their own root")
    func screenshotInsideWorkspaceRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let path = tab.workspace.appendingPathComponent("shot.png").path

        let response = try await Self.send(
            transport,
            .pageScreenshot(id: 10, BrowserHostPageScreenshotRequest(tabId: tab.wireID, fullPage: false, path: path))
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "write_failed")
        #expect(tab.page.screenshotFullPageRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        _ = client
    }

    /// Where a path lands decides, not how it is spelled (`BrowserHostPathTests`
    /// has every case): a link inside a root that points out of it is outside.
    @Test("a screenshot path through a link out of the browser directory is refused before any capture")
    func screenshotThroughAnEscapingLinkRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let outside = try tab.outsideDirectory()
        try FileManager.default.createDirectory(at: tab.browserDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tab.browserDirectory.appendingPathComponent("artifacts"), withDestinationURL: outside)
        let path = tab.browserDirectory.appendingPathComponent("artifacts/1.png").path

        let response = try await Self.send(
            transport,
            .pageScreenshot(id: 10, BrowserHostPageScreenshotRequest(tabId: tab.wireID, fullPage: false, path: path))
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "write_failed")
        #expect(tab.page.screenshotFullPageRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("1.png").path))
        _ = client
    }

    @Test("an upload through a link out of the workspace is refused, and the page is never touched")
    func uploadThroughAnEscapingLinkRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let outside = try tab.outsideDirectory()
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createDirectory(at: tab.workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tab.workspace.appendingPathComponent("notes"), withDestinationURL: outside)
        let path = tab.workspace.appendingPathComponent("notes/secret.txt").path

        let response = try await Self.send(transport, .pageUpload(id: 10, tabId: tab.wireID, ref: 7, path: path))

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "upload_failed")
        #expect(tab.page.actedOn.isEmpty)
        _ = client
    }

    @Test("a screenshot inside the engine's browser directory is written and answered")
    func screenshotWritesTheFile() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let path = try tab.capturePath("screenshots/1.png")
        tab.page.screenshotResult = .success(BrowserPageCapture(data: Data("png-bytes".utf8), mimeType: "image/png", devicePixelRatio: 2))

        let response = try await Self.send(
            transport,
            .pageScreenshot(id: 10, BrowserHostPageScreenshotRequest(tabId: tab.wireID, fullPage: true, path: path))
        )

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["path"] as? String == path)
        #expect(result["mime_type"] as? String == "image/png")
        #expect(result["bytes"] as? Int == "png-bytes".utf8.count)
        #expect(result["device_pixel_ratio"] as? Double == 2)
        #expect(tab.page.screenshotFullPageRequests == [true])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("png-bytes".utf8))
        _ = client
    }

    // MARK: - pdf

    @Test("a pdf path outside the engine's browser directory is refused before any capture")
    func pdfOutsideBrowserDirectoryRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let outside = "/tmp/fermix-host-ops-outside/\(UUID().uuidString).pdf"

        let response = try await Self.send(transport, .pagePdf(id: 10, tabId: tab.wireID, path: outside))

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "write_failed")
        #expect(!FileManager.default.fileExists(atPath: outside))
        _ = client
    }

    @Test("a pdf inside the engine's browser directory is written and answered")
    func pdfWritesTheFile() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let path = try tab.capturePath("pdfs/1.pdf")
        tab.page.pdfResult = .success(Data("pdf-bytes".utf8))

        let response = try await Self.send(transport, .pagePdf(id: 10, tabId: tab.wireID, path: path))

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["mime_type"] as? String == "application/pdf")
        #expect(result["bytes"] as? Int == "pdf-bytes".utf8.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("pdf-bytes".utf8))
        _ = client
    }

    // MARK: - cookies

    @Test("cookies.get and cookies.clear read and clear exactly the named tab's own store")
    func cookiesActOnTheNamedTabsStoreAlone() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let other = FakeOperationsPage()
        let otherTab = BrowserTab(profile: .private, page: other)
        tab.coordinator.admit(otherTab, for: BrowserTaskID("task-2"))
        tab.page.cookiesResult = .success([BrowserCookie(name: "session", domain: "example.com")])
        tab.page.clearCookiesResult = .success(3)
        other.clearCookiesResult = .success(99)

        let getResponse = try await Self.send(transport, .cookiesGet(id: 10, tabId: tab.wireID))
        let getResult = try #require(getResponse["result"] as? [String: Any])
        let cookies = try #require(getResult["cookies"] as? [[String: Any]])
        #expect(cookies.first?["name"] as? String == "session")

        let clearResponse = try await Self.send(transport, .cookiesClear(id: 11, tabId: tab.wireID))
        let clearResult = try #require(clearResponse["result"] as? [String: Any])
        #expect(clearResult["cleared"] as? Int == 3, "only the named tab's store was cleared")
        #expect(other.clearCalls == 0, "the other tab's own store was never touched")
        _ = client
    }

    // MARK: - tab caps from the wire

    @Test("tab.open's own caps become the connection's, and hold for a later tab.open")
    func tabOpenCapsBecomeTheConnections() async throws {
        let coordinator = FakeHostCoordinator()
        let (client, transport) = Self.attachedClient(coordinator: coordinator)

        let first = try await Self.send(transport, .tabOpen(id: 1, Self.openRequest(task: "task-1", taskTabCap: 1, tabCap: 1)))
        #expect(first["ok"] as? Bool == true)

        let second = try await Self.send(transport, .tabOpen(id: 2, Self.openRequest(task: "task-1", taskTabCap: 1, tabCap: 1)))
        let error = try #require(second["error"] as? [String: Any])
        #expect(error["reason"] as? String == "cap_reached", "the first tab.open's own cap now governs the task")
        _ = client
    }

    @Test("a later tab.open naming different caps is refused rather than adopted")
    func laterTabOpenWithDifferentCapsRefused() async throws {
        let coordinator = FakeHostCoordinator()
        let (client, transport) = Self.attachedClient(coordinator: coordinator)

        let first = try await Self.send(transport, .tabOpen(id: 1, Self.openRequest(task: "task-1", taskTabCap: 2, tabCap: 4)))
        #expect(first["ok"] as? Bool == true)

        let second = try await Self.send(transport, .tabOpen(id: 2, Self.openRequest(task: "task-2", taskTabCap: 3, tabCap: 4)))
        let error = try #require(second["error"] as? [String: Any])
        #expect(error["reason"] as? String == "invalid_request")
        _ = client
    }

    @Test("caps the wire's own contract cannot express are refused")
    func unusableCapsAreRefused() async throws {
        let coordinator = FakeHostCoordinator()
        let (client, transport) = Self.attachedClient(coordinator: coordinator)

        let response = try await Self.send(transport, .tabOpen(id: 1, Self.openRequest(task: "task-1", taskTabCap: 0, tabCap: 0)))

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "invalid_request")
        _ = client
    }

    // MARK: - opener tracking

    @Test("tab.list carries a popup's opener, and nothing for a tab that opened nothing")
    func tabListCarriesAPopupsOpener() async throws {
        let coordinator = FakeHostCoordinator()
        let (client, transport) = Self.attachedClient(coordinator: coordinator)
        let opened = try await Self.send(transport, .tabOpen(id: 1, Self.openRequest(task: "task-1")))
        let openerID = try #require((opened["result"] as? [String: Any])?["tab_id"] as? String)
        let popup = BrowserTab(profile: .shared, page: FakeOperationsPage())
        #expect(coordinator.admitPopup(popup, from: UUID(uuidString: openerID)!))

        let listed = try await Self.send(transport, .tabList(id: 2, taskId: "task-1"))
        let tabs = try #require((listed["result"] as? [String: Any])?["tabs"] as? [[String: Any]])
        let openerRow = try #require(tabs.first { $0["tab_id"] as? String == openerID })
        let popupRow = try #require(tabs.first { $0["tab_id"] as? String == popup.id.uuidString })

        #expect(openerRow["opener_tab_id"] == nil)
        #expect(popupRow["opener_tab_id"] as? String == openerID)
        _ = client
    }

    // MARK: - Sign-in (protocol 2)

    @Test("page.login_for answers the saved login's site and username and nothing else")
    func loginForAnswersTheLogin() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.loginForResult = .success(SavedLogin(id: UUID(), site: "example.com", username: "person@example.com"))

        let response = try await Self.send(
            transport,
            .pageLoginFor(id: 28, BrowserHostPageLoginForRequest(tabId: tab.wireID, site: "www.example.com"))
        )

        let result = try #require(response["result"] as? [String: Any])
        #expect(NSDictionary(dictionary: result).isEqual(to: ["login_site": "example.com", "username": "person@example.com"]))
        #expect(tab.page.loginForSites == ["www.example.com"])
        _ = client
    }

    @Test("page.sign_in answers the fields it typed, the page when observed, and never a value or a username")
    func signInAnswersTheFields() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.signInResult = .success(BrowserSignInOutcome(filled: [.username, .password], effect: .unchanged, url: "https://example.com/login"))

        let response = try await Self.send(transport, .pageSignIn(id: 29, Self.signInRequest(tab.wireID)))

        let result = try #require(response["result"] as? [String: Any])
        #expect(Set(result.keys) == ["url", "title", "filled"])
        #expect(result["filled"] as? [String] == ["username", "password"])
        #expect(result["url"] as? String == "https://example.com/login")
        #expect(tab.page.signInRequests == [
            BrowserSignInRequest(site: "example.com", loginSite: "example.com", usernameRef: 11, passwordRef: 12)
        ])
        #expect(tab.page.signInLooks == [nil], "a sign-in the engine does not observe takes no look")
        _ = client
    }

    @Test("page.sign_in observed on a page that changed hands the page its look and carries the page back")
    func signInCarriesTheChangedPage() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let snapshot = BrowserPageSnapshot(
            title: "Welcome", url: "https://example.com/home", readyState: .complete, tabLoading: false,
            nodes: [BrowserPageNode(id: 0, role: "RootWebArea")],
            elements: 1, crossOriginFrames: 0, closedShadowRoots: false, evaluateMilliseconds: 1
        )
        tab.page.signInResult = .success(BrowserSignInOutcome(filled: [.password], effect: .changed(snapshot), url: "https://example.com/home"))

        let response = try await Self.send(
            transport,
            .pageSignIn(id: 29, Self.signInRequest(tab.wireID, usernameRef: nil, observe: true))
        )

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["filled"] as? [String] == ["password"])
        #expect((result["page"] as? [String: Any])?["url"] as? String == "https://example.com/home")
        #expect(tab.page.signInLooks == [.some(Self.look)])
        _ = client
    }

    @Test("page.sign_in naming neither field is refused before the page is asked")
    func signInWithNoFieldRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()

        let response = try await Self.send(
            transport,
            .pageSignIn(id: 29, Self.signInRequest(tab.wireID, usernameRef: nil, passwordRef: nil))
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "invalid_request")
        #expect(tab.page.signInRequests.isEmpty)
        _ = client
    }

    @Test("each sign-in refusal answers its own reason, and no message names the username")
    func signInRefusalsAnswerTheirReasons() async throws {
        let cases: [(BrowserLoginRefusal, String)] = [
            (.insecurePage, "sign_in_insecure_page"),
            (.wrongSite(site: "example.com"), "sign_in_wrong_site"),
            (.noLogin(host: "example.com"), "sign_in_no_login"),
            (.field(ref: 12, .notPassword), "sign_in_field"),
            (.field(ref: 11, .notUsername), "sign_in_field"),
            (.field(ref: nil, .twoDocuments), "sign_in_field"),
            (.field(ref: 12, .focus), "sign_in_field"),
            (.pageMoved(.origin), "sign_in_page_moved"),
            (.pageMoved(.documentOrigin), "sign_in_page_moved"),
            (.pageMoved(.login), "sign_in_page_moved"),
            (.storeUnavailable(.unavailable(status: -34018)), "sign_in_store_unavailable"),
            (.storeUnavailable(.unavailable(status: nil)), "sign_in_store_unavailable"),
            (.storeUnavailable(.timedOut), "sign_in_store_unavailable")
        ]
        let (client, transport, tab) = try await Self.attachedWithOneTab()

        var messages: Set<String> = []
        for (refusal, reason) in cases {
            tab.page.signInResult = .failure(refusal)
            let response = try await Self.send(transport, .pageSignIn(id: 29, Self.signInRequest(tab.wireID)))

            let error = try #require(response["error"] as? [String: Any])
            #expect(error["reason"] as? String == reason, "\(refusal)")
            let message = try #require(error["message"] as? String)
            #expect(!message.isEmpty && !message.contains("person@example.com"))
            messages.insert(message)
        }
        #expect(messages.count == cases.count, "every refusal has its own sentence")
        #expect(messages.contains("the keychain refused (OSStatus -34018)"))
        _ = client
    }

    @Test("while the ledger holds a password, a screenshot the page refuses answers secret_on_screen and writes nothing")
    func screenshotRefusedWhileASecretShows() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        client.ledger.add(LoginSecret("correct-horse-battery"))
        tab.page.shownSecretsResult = .failure(BrowserLoginRefusal.secretOnScreen)
        let path = try tab.capturePath("screenshots/2.png")

        let response = try await Self.send(
            transport,
            .pageScreenshot(id: 8, BrowserHostPageScreenshotRequest(tabId: tab.wireID, fullPage: false, path: path))
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "secret_on_screen")
        #expect(tab.page.guardedFingerprints.map(\.count) == [1])
        #expect(tab.page.screenshotFullPageRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        _ = client
    }

    @Test("while the ledger holds a password, a pdf the page refuses answers secret_on_screen")
    func pdfRefusedWhileASecretShows() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        client.ledger.add(LoginSecret("correct-horse-battery"))
        tab.page.shownSecretsResult = .failure(BrowserLoginRefusal.secretOnScreen)
        let path = try tab.capturePath("pdfs/2.pdf")

        let response = try await Self.send(transport, .pagePdf(id: 9, tabId: tab.wireID, path: path))

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "secret_on_screen")
        #expect(!FileManager.default.fileExists(atPath: path))
        _ = client
    }

    @Test("with nothing in the ledger, a capture never asks the page for the guard")
    func emptyLedgerSkipsTheGuard() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let path = try tab.capturePath("screenshots/3.png")

        _ = try await Self.send(
            transport,
            .pageScreenshot(id: 8, BrowserHostPageScreenshotRequest(tabId: tab.wireID, fullPage: false, path: path))
        )

        #expect(tab.page.guardedFingerprints.isEmpty)
        #expect(tab.page.screenshotFullPageRequests == [false])
        _ = client
    }

    @Test("every line the client sends while the ledger holds a password is scrubbed: an answer and an event")
    func clientScrubsAnswersAndEvents() async throws {
        let password = LedgerForms.awkward
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        client.ledger.add(LoginSecret(password))
        tab.page.actResult = .success(
            BrowserActOutcome(effect: .unobserved, input: .scripted, url: "https://example.com/", read: .text("echo \(password) end"))
        )

        let response = try await Self.send(transport, .pageAct(id: 10, Self.actRequest(tab.wireID, kind: .get, field: .text)))
        let before = transport.sent.count
        client.downloadRefused(UUID(), tab: try #require(tab.coordinator.model.tabs.first).id, filename: password, reason: "refused")

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["value"] as? String == "echo \(LoginLedger.hidden) end")
        let events = try transport.sentObjects().dropFirst(before)
        #expect(events.count == 2)
        #expect(events.first?["filename"] as? String == LoginLedger.hidden)
        for line in transport.sent {
            #expect(!String(decoding: line, as: UTF8.self).contains("w<o>rd"))
        }
        _ = client
    }

    // MARK: - Looks

    @Test("an act the engine does not observe reaches the page with no look, and answers with no page")
    func unobservedActTakesNoLook() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()

        let response = try await Self.send(transport, .pageAct(id: 10, Self.actRequest(tab.wireID, kind: .click, ref: 4)))

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["page"] == nil)
        #expect(tab.page.actedOn == [.click(ref: 4)])
        #expect(tab.page.actLooks == [nil])
        #expect(tab.page.loadBudgets.isEmpty)
        #expect(tab.page.snapshotRequests.isEmpty)
        _ = client
    }

    @Test("an observed act hands the page the engine's look, and its page carries the document's ready state")
    func observedActHandsItsLook() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let page = Self.page(readyState: .interactive)
        tab.page.actResult = .success(BrowserActOutcome(effect: .changed(page), input: .trusted, url: page.url))

        let response = try await Self.send(
            transport, .pageAct(id: 10, Self.actRequest(tab.wireID, kind: .click, ref: 4, observe: true))
        )

        let result = try #require(response["result"] as? [String: Any])
        let wirePage = try #require(result["page"] as? [String: Any])
        #expect(wirePage["ready_state"] as? String == "interactive")
        #expect(tab.page.actLooks == [.some(Self.look)])
        _ = client
    }

    @Test("an upload reaches the page with no look")
    func uploadTakesNoLook() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        try FileManager.default.createDirectory(at: tab.workspace, withIntermediateDirectories: true)
        let file = tab.workspace.appendingPathComponent("photo.png")
        try Data("png-bytes".utf8).write(to: file)

        let response = try await Self.send(transport, .pageUpload(id: 10, tabId: tab.wireID, ref: 7, path: file.path))

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["tab_id"] as? String == tab.wireID)
        #expect(tab.page.actedOn == [.upload(ref: 7, path: file.path)])
        #expect(tab.page.actLooks == [nil])
        #expect(tab.page.loadBudgets.isEmpty)
        _ = client
    }

    @Test("page.snapshot on a load still in flight waits the settle budget, then answers the page as it stands")
    func snapshotReadsASlowLoadAtTheBudget() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.loaded = false
        tab.page.snapshotResult = Self.page(readyState: .interactive)

        let response = try await Self.send(transport, .pageSnapshot(id: 9, Self.snapshotRequest(tab.wireID)))

        let result = try #require(response["result"] as? [String: Any], "a slow load is never wait_timeout")
        #expect(result["ready_state"] as? String == "interactive")
        #expect(tab.page.loadBudgets == [BrowserPageSettle.settleBudget])
        #expect(tab.page.snapshotRequests.count == 1)
        _ = client
    }

    @Test("a complete document read while the tab was still loading answers ready_state loading, though the load is over by the answer")
    func snapshotOfAPageBeingLeftIsLoading() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let browserTab = try #require(tab.coordinator.model.tabs.first)
        tab.page.snapshotResult = Self.page(readyState: .complete, tabLoading: true)

        let response = try await Self.send(transport, .pageSnapshot(id: 9, Self.snapshotRequest(tab.wireID)))

        let result = try #require(response["result"] as? [String: Any])
        #expect(!browserTab.isLoading, "the tab shows no load when the answer goes")
        #expect(result["ready_state"] as? String == "loading", "the state when the page was read")
        _ = client
    }

    @Test("a complete document read before a navigation began answers ready_state complete, though the tab is loading by the answer")
    func snapshotReadBeforeANavigationIsComplete() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        let browserTab = try #require(tab.coordinator.model.tabs.first)
        browserTab.pageChanged(BrowserPageState(url: URL(string: "https://example.com/"), isLoading: true))
        tab.page.loaded = false
        tab.page.snapshotResult = Self.page(readyState: .complete, tabLoading: false)

        let response = try await Self.send(transport, .pageSnapshot(id: 9, Self.snapshotRequest(tab.wireID)))

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["ready_state"] as? String == "complete")
        _ = client
    }

    @Test("tab.open observed takes the page's own look after a navigation, with no other wait in front of it")
    func openTakesTheNavigationLook() async throws {
        let coordinator = FakeHostCoordinator()
        let (client, transport) = Self.attachedClient(coordinator: coordinator)

        let response = try await Self.send(transport, .tabOpen(id: 1, Self.openRequest(task: "task-1", observe: true)))

        let result = try #require(response["result"] as? [String: Any])
        #expect((result["page"] as? [String: Any])?["ready_state"] as? String == "complete")
        #expect(coordinator.page.navigationLooks == [Self.look])
        #expect(coordinator.page.loadBudgets.isEmpty)
        #expect(coordinator.page.snapshotRequests.isEmpty)
        _ = client
    }

    @Test("tab.navigate whose navigation never commits answers navigation_refused, saying the page did not start loading at that address")
    func navigationThatNeverCommitsIsRefused() async throws {
        let (client, transport, tab) = try await Self.attachedWithOneTab()
        tab.page.navigationLookFailure = BrowserPageDriveError.notStarted(
            "https://example.com/next", within: BrowserPageSettle.navigationTimeout
        )
        let navigate = BrowserHostTabNavigateRequest(
            tabId: tab.wireID, url: "https://example.com/next", observe: true, snapshot: Self.lookOptions
        )

        let response = try await Self.send(transport, .tabNavigate(id: 2, navigate))

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "navigation_refused", "as a navigation that ended without a page")
        #expect(error["message"] as? String == "the page did not start loading within 30 seconds: https://example.com/next")
        #expect(tab.page.navigationLooks == [Self.look])
        _ = client
    }

    // MARK: - Mechanics

    /// The look every observed request in this suite names.
    private static let look = BrowserSnapshotRequest(mode: .interactive, maxChars: 50_000, depth: 5)
    private static let lookOptions = BrowserHostSnapshotOptions(mode: .interactive, maxChars: 50_000, depth: 5)

    private static func page(readyState: BrowserReadyState, tabLoading: Bool = false) -> BrowserPageSnapshot {
        BrowserPageSnapshot(
            title: "Example", url: "https://example.com/next", readyState: readyState, tabLoading: tabLoading,
            nodes: [BrowserPageNode(id: 0, role: "RootWebArea")],
            elements: 1, crossOriginFrames: 0, closedShadowRoots: false, evaluateMilliseconds: 1
        )
    }

    private static func snapshotRequest(_ tabId: String) -> BrowserHostPageSnapshotRequest {
        BrowserHostPageSnapshotRequest(tabId: tabId, mode: .interactive, maxChars: 50_000, depth: 5)
    }

    private static func signInRequest(
        _ tabId: String,
        usernameRef: Int? = 11,
        passwordRef: Int? = 12,
        observe: Bool = false
    ) -> BrowserHostPageSignInRequest {
        BrowserHostPageSignInRequest(
            tabId: tabId, site: "example.com", loginSite: "example.com", observe: observe,
            usernameRef: usernameRef, passwordRef: passwordRef,
            snapshot: observe ? Self.lookOptions : nil
        )
    }

    private static func actRequest(
        _ tabId: String,
        kind: BrowserHostActKind,
        ref: Int? = nil,
        observe: Bool = false,
        field: BrowserHostGetField? = nil,
        selector: String? = nil,
        text: String? = nil,
        waitUntil: BrowserHostWaitUntil? = nil,
        timeoutMs: Int? = nil
    ) -> BrowserHostPageActRequest {
        BrowserHostPageActRequest(
            tabId: tabId, kind: kind, observe: observe, snapshot: observe ? Self.lookOptions : nil, ref: ref, x: nil, y: nil,
            text: text, key: nil, fields: nil, field: field, selector: selector,
            waitUntil: waitUntil, timeoutMs: timeoutMs
        )
    }

    private static func openRequest(
        task: String, taskTabCap: Int = 10, tabCap: Int = 60, observe: Bool = false
    ) -> BrowserHostTabOpenRequest {
        BrowserHostTabOpenRequest(
            taskId: task, url: "https://example.com/", observe: observe,
            downloadDir: "/tmp/fermix-test/workspace/downloads", taskTabCap: taskTabCap, tabCap: tabCap,
            snapshot: observe ? Self.lookOptions : nil, visible: nil
        )
    }

    /// A client already attached to a fresh `FakeHostCoordinator`, with one
    /// task tab already open on `task-1` and its wire id resolved.
    private static func attachedWithOneTab() async throws -> (client: BrowserHostClient, transport: Transport, tab: OpenTab) {
        let coordinator = FakeHostCoordinator()
        let (client, transport) = Self.attachedClient(coordinator: coordinator)
        let opened = try await Self.send(transport, .tabOpen(id: 1, Self.openRequest(task: "task-1")))
        let wireID = try #require((opened["result"] as? [String: Any])?["tab_id"] as? String)

        return (client, transport, OpenTab(coordinator: coordinator, wireID: wireID, page: coordinator.page))
    }

    private static func makeClient(coordinator: FakeHostCoordinator, transport: Transport) -> BrowserHostClient {
        let client = BrowserHostClient(
            lines: transport,
            socketPath: { "/tmp/fermix-test/browser_host.sock" },
            profileID: { "profile-1" },
            workspaceRoot: { coordinator.workspace },
            browserRoot: { coordinator.browserDirectory },
            hostVersion: "0.2.0",
            coordinator: coordinator,
            deadlines: ManualDeadlineScheduler(),
            loginStore: InMemoryLoginStore()
        )
        client.connect()
        return client
    }

    private static func attachedClient(coordinator: FakeHostCoordinator) -> (client: BrowserHostClient, transport: Transport) {
        let transport = Transport()
        let client = Self.makeClient(coordinator: coordinator, transport: transport)
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 2))

        return (client, transport)
    }

    /// Sends one request and waits for its answer, the next line the client
    /// sends after it.
    private static func send(_ transport: Transport, _ request: BrowserHostRequest) async throws -> NSDictionary {
        let before = transport.sent.count
        transport.deliver(.request(request))
        await Self.waitUntil { transport.sent.count > before }

        return try #require(transport.sentObjects().last)
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            await Task.yield()
        }
    }
}

/// One already-open tab's wire id and the fake page behind it, for a case
/// that only ever drives that one tab; `coordinator` is there for a case
/// that needs a second tab besides it.
private struct OpenTab {
    let coordinator: FakeHostCoordinator
    let wireID: String
    let page: FakeOperationsPage
    var workspace: URL { coordinator.workspace }
    var browserDirectory: URL { coordinator.browserDirectory }

    /// A capture path as the engine names one: under its browser directory's
    /// `artifacts/<task>/<kind>`, a directory the engine has made before it asks.
    func capturePath(_ file: String) throws -> String {
        let path = browserDirectory.appendingPathComponent("artifacts/task-1/\(file)")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return path.path
    }

    /// A directory beside both roots and inside neither, for a link to point
    /// at.
    func outsideDirectory() throws -> URL {
        let outside = workspace.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return outside
    }
}

/// A page with a web engine, a capture surface and a cookie store behind it,
/// standing in for `WebKitBrowserPage` in the operations this suite proves.
@MainActor
private final class FakeOperationsPage: BrowserPage, BrowserPageDriving, BrowserPageCapturing, BrowserPageCookies,
                                        BrowserPageSigningIn {
    weak var events: (any BrowserPageEvents)?
    lazy var view = NSView()

    private(set) var actedOn: [BrowserPageAction] = []
    /// The look each act was handed, nil where the engine asked for none.
    private(set) var actLooks: [BrowserSnapshotRequest?] = []
    var actResult: Result<BrowserActOutcome, any Error> = .success(
        BrowserActOutcome(effect: .unobserved, input: .scripted, url: "https://example.com/")
    )

    /// The budget of every wait for a load, and its answer: false is a load
    /// still in flight when the budget ran out.
    private(set) var loadBudgets: [Duration] = []
    var loaded = true
    private(set) var snapshotRequests: [BrowserSnapshotRequest] = []
    private(set) var navigationLooks: [BrowserSnapshotRequest] = []
    /// What the look after a navigation throws, nil where it reads the page.
    var navigationLookFailure: (any Error)?
    var snapshotResult: BrowserPageSnapshot = .empty

    private(set) var screenshotFullPageRequests: [Bool] = []
    var screenshotResult: Result<BrowserPageCapture, any Error> = .success(
        BrowserPageCapture(data: Data(), mimeType: "image/png", devicePixelRatio: 1)
    )

    var pdfResult: Result<Data, any Error> = .success(Data())
    var cookiesResult: Result<[BrowserCookie], any Error> = .success([])
    var clearCookiesResult: Result<Int, any Error> = .success(0)
    private(set) var clearCalls = 0

    func load(_ url: URL) {}
    func loadFile(_ url: URL, as kind: BrowserFileKind, readAccess: URL) {}
    func back() {}
    func forward() {}
    func reload() {}
    func stop() {}
    func find(_ text: String) {}
    func zoom(_ zoom: BrowserZoom) {}
    func close() {}

    func waitForLoad(within budget: Duration) async throws -> Bool {
        loadBudgets.append(budget)
        return loaded
    }

    func snapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        snapshotRequests.append(request)
        return snapshotResult
    }

    func snapshotAfterNavigation(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        navigationLooks.append(request)
        if let navigationLookFailure { throw navigationLookFailure }
        return snapshotResult
    }

    func act(_ action: BrowserPageAction, observing look: BrowserSnapshotRequest?) async throws -> BrowserActOutcome {
        actedOn.append(action)
        actLooks.append(look)
        return try actResult.get()
    }

    func screenshot(fullPage: Bool) async throws -> BrowserPageCapture {
        screenshotFullPageRequests.append(fullPage)
        return try screenshotResult.get()
    }

    func pdf() async throws -> Data { try pdfResult.get() }
    func cookies() async throws -> [BrowserCookie] { try cookiesResult.get() }

    func clearCookies() async throws -> Int {
        clearCalls += 1
        return try clearCookiesResult.get()
    }

    var loginForResult: Result<SavedLogin, any Error> = .failure(BrowserLoginRefusal.noLogin(host: "example.com"))
    private(set) var loginForSites: [String] = []
    var signInResult: Result<BrowserSignInOutcome, any Error> = .failure(BrowserLoginRefusal.pageMoved(.origin))
    private(set) var signInRequests: [BrowserSignInRequest] = []
    /// The look each sign-in was handed, nil where the engine asked for none.
    private(set) var signInLooks: [BrowserSnapshotRequest?] = []
    var shownSecretsResult: Result<Void, any Error> = .success(())
    private(set) var guardedFingerprints: [[BrowserSecretFingerprint]] = []

    func loginFor(site: String, store: any LoginStore) async throws -> SavedLogin {
        loginForSites.append(site)
        return try loginForResult.get()
    }

    func signIn(
        _ request: BrowserSignInRequest,
        store: any LoginStore,
        ledger: LoginLedger,
        observing look: BrowserSnapshotRequest?
    ) async throws -> BrowserSignInOutcome {
        signInRequests.append(request)
        signInLooks.append(look)
        return try signInResult.get()
    }

    func refuseShownSecrets(_ fingerprints: [BrowserSecretFingerprint]) async throws {
        guardedFingerprints.append(fingerprints)
        try shownSecretsResult.get()
    }
}

/// `BrowserHostCoordinating`'s own fake (its doc comment's whole point): a
/// real model and reducer, fake pages, and none of `BrowserCoordinator`'s
/// engine, profile or workspace building.
@MainActor
private final class FakeHostCoordinator: BrowserHostCoordinating {
    let model = BrowserModel()
    /// The engine's upload root and its capture root, laid out as the engine
    /// lays out its home: uploads under `workspace`, captures under `browser`.
    let workspace: URL
    let browserDirectory: URL

    init() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-browser-host-ops-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspace = home.appendingPathComponent("workspace", isDirectory: true)
        browserDirectory = home.appendingPathComponent("browser", isDirectory: true)
    }

    /// The one page behind the last tab `openTaskTab` admitted, for a case
    /// that opens one tab and drives it.
    private(set) var page = FakeOperationsPage()

    func hostAttached(_ link: any BrowserHostLink, caps: BrowserTabCaps?) -> BrowserHostConnection? {
        model.host.attach(caps: caps)
    }

    func hostDetached(_ connection: BrowserHostConnection) {
        _ = model.host.detach(connection)
    }

    func establishTabCaps(_ caps: BrowserTabCaps) -> Bool {
        model.host.establishCaps(caps)
    }

    func openTaskTab(_ url: URL, for task: BrowserTaskID, visible: Bool) -> Result<BrowserTab.ID, BrowserTabRefusal> {
        let newPage = FakeOperationsPage()
        let tab = BrowserTab(profile: .shared, page: newPage)
        switch model.host.openTaskTab(tab.id, for: task) {
        case .refused(let refusal):
            return .failure(refusal)
        case .admitted:
            tab.load(url)
            model.tabs.append(tab)
            page = newPage
            return .success(tab.id)
        }
    }

    func closeTaskTab(_ tab: BrowserTab.ID) {
        model.tabs.removeAll { $0.id == tab }
    }

    func releaseTask(_ task: BrowserTaskID) {
        let released = model.host.release(task)
        model.tabs.removeAll { released.contains($0.id) }
    }

    func select(_ tab: BrowserTab) {
        model.selectedTabID = tab.id
    }

    func answer(_ answer: BrowserDialogAnswer) {}

    /// A second tab, admitted directly rather than through `tab.open`, for a
    /// case that needs two tabs with two distinct stores.
    func admit(_ tab: BrowserTab, for task: BrowserTaskID) {
        guard case .admitted = model.host.openTaskTab(tab.id, for: task) else { return }

        model.tabs.append(tab)
    }

    /// A popup admitted the way a page's own window is, its opener kept.
    func admitPopup(_ tab: BrowserTab, from opener: BrowserTab.ID) -> Bool {
        guard case .admitted = model.host.openPopup(tab.id, from: opener) else { return false }

        model.tabs.append(tab)
        return true
    }
}
