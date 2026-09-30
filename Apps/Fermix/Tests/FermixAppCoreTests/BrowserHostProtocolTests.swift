import Foundation
import Testing

@testable import FermixAppCore

/// The typed `browser_host` wire, driven by the vendored golden fixtures.
///
/// Direction is reversed from the other wires: `requests.jsonl` is decoded
/// (the handshake reply, every daemon request, and every daemon error),
/// `events.jsonl` and `responses.jsonl` are encoded (everything this build
/// sends). Every fixture in all three files is exercised, and each direction
/// asserts its fixtures cover every type the schema publishes for it.
@Suite("Browser host protocol")
struct BrowserHostProtocolTests {
    @Test("this build declares the version, window and line cap the vendored contract publishes")
    func declaredConstantsMatchTheContract() throws {
        let schema = try BrowserHostFixtures.schema()
        let range = schema["x-supported-version-range"] as? [String: Any]

        #expect(schema["x-protocol-version"] as? Int == BrowserHostProtocol.version)
        #expect(range?["min"] as? Int == BrowserHostProtocol.supportedWindow.minimum)
        #expect(range?["max"] as? Int == BrowserHostProtocol.supportedWindow.maximum)
        #expect(BrowserHostProtocol.supportedWindow.contains(BrowserHostProtocol.version))
        #expect(schema["x-max-line-bytes"] as? Int == BrowserHostProtocol.maximumLineBytes)
        #expect(schema["x-max-message-chars"] as? Int == BrowserHostProtocol.maximumMessageChars)
        #expect(schema["x-max-reason-chars"] as? Int == BrowserHostProtocol.maximumReasonChars)
        #expect(schema["x-max-nodes"] as? Int == BrowserHostProtocol.maximumNodes)
    }

    // MARK: - requests.jsonl (decoded)

    @Test("every golden daemon frame decodes and writes back as itself")
    func roundTripsEveryDaemonFixture() throws {
        let fixtures = try BrowserHostFixtures.load(.requests)
        let daemonFrameTypes = try BrowserHostFixtures.publishedTypes("daemonFrame")
        let seenTypes = Set(fixtures.compactMap { $0.object["type"] as? String })

        #expect(seenTypes == daemonFrameTypes, "the fixture file covers every type the schema publishes")

        for fixture in fixtures {
            let inbound = try BrowserHostInbound.decode(fixture.line)
            let written = BrowserHostDaemonWire.object(inbound)

            #expect(
                NSDictionary(dictionary: written).isEqual(to: fixture.object),
                "\(fixture.object["type"] ?? "?") came back as \(written)"
            )
        }
    }

    @Test("the handshake reply and a numbered request decode into their typed fields")
    func specificDaemonFixtureFields() throws {
        let fixtures = try BrowserHostFixtures.load(.requests)

        func request(_ id: Int) throws -> BrowserHostRequest {
            guard case .request(let request) = try inbound(id) else {
                Issue.record("id \(id) is not a numbered request")
                throw BrowserHostFixtureDefect.fileIsEmpty(file: "requests.jsonl")
            }
            return request
        }

        func inbound(_ id: Int) throws -> BrowserHostInbound {
            guard let fixture = fixtures.first(where: { $0.object["id"] as? Int == id }) else {
                Issue.record("no fixture with id \(id)")
                throw BrowserHostFixtureDefect.fileIsEmpty(file: "requests.jsonl")
            }
            return try BrowserHostInbound.decode(fixture.line)
        }

        guard case .serverHello(let minVersion, let maxVersion) = try BrowserHostInbound.decode(fixtures[0].line) else {
            Issue.record("the first fixture line is not server_hello")
            return
        }
        #expect(minVersion == 1)
        #expect(maxVersion == 1)

        guard case .tabOpen(1, let opened) = try request(1) else {
            Issue.record("id 1 is not tab.open")
            return
        }
        #expect(opened.taskId == "task-9f2c1a7e4b0d")
        #expect(opened.observe)
        #expect(opened.taskTabCap == 10)
        #expect(opened.tabCap == 60)
        #expect(opened.snapshot == BrowserHostSnapshotOptions(mode: .interactive, maxChars: 50_000, depth: 5))

        guard case .pageAct(12, let fillForm) = try request(12) else {
            Issue.record("id 12 is not page.act")
            return
        }
        #expect(fillForm.kind == .fillForm)
        #expect(fillForm.fields == [
            BrowserHostFormField(ref: 11, text: "person@example.com"),
            BrowserHostFormField(ref: 12, text: "correct horse")
        ])

        guard case .pageAct(18, let wait) = try request(18) else {
            Issue.record("id 18 is not page.act")
            return
        }
        #expect(wait.waitUntil == .text)
        #expect(wait.timeoutMs == 5000)
        #expect(wait.text == "Order placed")

        guard case .dialogResolve(21, "t1", true, "yes") = try request(21) else {
            Issue.record("id 21 is not the expected dialog.resolve")
            return
        }

        // The unsupported_protocol_version fixture carries no id, so it is
        // found by its own reason among the fourteen daemon-error lines.
        let refusals = try fixtures
            .map { try BrowserHostInbound.decode($0.line) }
            .compactMap { frame -> BrowserHostDaemonError? in
                guard case .error(let error) = frame else { return nil }
                return error
            }
        let versionRefusal = try #require(refusals.first { $0.reason == "unsupported_protocol_version" })
        #expect(versionRefusal.direction == .clientTooNew)
        #expect(versionRefusal.clientVersion == 2)
        #expect(versionRefusal.window == BrowserHostVersionWindow(minimum: 1, maximum: 1))

        let untrustedHost = try #require(refusals.first { $0.reason == "untrusted_host" })
        #expect(untrustedHost.message?.contains("daemon did not start") == true)
    }

    /// `visible` is not yet in the vendored fixtures: `tab.open` decodes with
    /// it absent today, and a future golden line naming it true decodes
    /// straight into the same optional, with no decoder change.
    @Test("tab.open decodes visible as an optional, absent today and true once the engine sends it")
    func tabOpenVisibleIsAnOptional() throws {
        let withoutVisible = #"""
            {"id":1,"type":"tab.open","task_id":"t","url":"https://x","observe":true,
             "download_dir":"/d","task_tab_cap":1,"tab_cap":1}
            """#
        guard case .request(.tabOpen(1, let absent)) = try BrowserHostInbound.decode(Data(withoutVisible.utf8)) else {
            Issue.record("id 1 is not tab.open")
            return
        }
        #expect(absent.visible == nil)

        let withVisible = #"""
            {"id":1,"type":"tab.open","task_id":"t","url":"https://x","observe":true,
             "download_dir":"/d","task_tab_cap":1,"tab_cap":1,"visible":true}
            """#
        guard case .request(.tabOpen(1, let present)) = try BrowserHostInbound.decode(Data(withVisible.utf8)) else {
            Issue.record("id 1 is not tab.open")
            return
        }
        #expect(present.visible == true)
    }

    // MARK: - events.jsonl (encoded)

    @Test("every golden event is produced by a typed value")
    func encodesEveryEventFixture() throws {
        let fixtures = try BrowserHostFixtures.load(.events)
        let produced: [BrowserHostEvent] = [
            .clientHello(protocolVersion: BrowserHostProtocol.version),
            .attached(hostVersion: "0.2.0", profileId: "fermix-web-3c9a"),
            .availability(available: true, reason: nil),
            .availability(available: false, reason: "the Mac is locked"),
            .tabClosed(tabId: "t2", by: .task),
            .tabClosed(tabId: "t5", by: .page),
            .dialogOpened(tabId: "t1", kind: .confirm, message: "Leave this page?", defaultText: nil),
            .dialogOpened(tabId: "t1", kind: .prompt, message: "Your name", defaultText: "Guest"),
            .downloadBegan(downloadId: "d1", tabId: "t2", filename: "report.pdf"),
            .downloadProgress(downloadId: "d1", receivedBytes: 65536, totalBytes: 91022),
            .downloadFinished(
                downloadId: "d1", tabId: "t2", state: .completed,
                path: "/Users/person/.fermix/workspace/browser/downloads/0bqP3d/report.pdf",
                bytes: 91022, reason: nil
            ),
            .downloadFinished(
                downloadId: "d2", tabId: "t2", state: .failed,
                path: nil, bytes: nil, reason: "the server closed the connection"
            ),
            .taskCancel(taskId: "task-2", reason: "cancelled by the person"),
            .hostStopping
        ]

        #expect(produced.count == fixtures.count)
        let eventTypes = try BrowserHostFixtures.publishedTypes("hostEvent")
        #expect(Set(fixtures.compactMap { $0.object["type"] as? String }) == eventTypes)

        for (event, fixture) in zip(produced, fixtures) {
            let line = try event.line()

            #expect(!line.contains(0x0A), "\(event.wireType) must be exactly one line")
            #expect(event.wireType == fixture.object["type"] as? String)
            #expect(
                try BrowserHostFixtures.sameObject(line, fixture.line),
                "\(event.wireType): \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    /// Absent is absent: an optional this client has no value for is a
    /// missing key, never an explicit null.
    @Test("an absent optional is an absent key")
    func absentOptionalsAreAbsentKeys() throws {
        let line = String(decoding: try BrowserHostEvent.availability(available: true, reason: nil).line(), as: UTF8.self)

        #expect(!line.contains("reason"))
        #expect(!line.contains("null"))
    }

    // MARK: - responses.jsonl (encoded)

    @Test("every golden response is produced by a typed value")
    func encodesEveryResponseFixture() throws {
        let fixtures = try BrowserHostFixtures.load(.responses)
        let produced = Self.responseFixtures

        #expect(produced.count == fixtures.count)

        for (response, fixture) in zip(produced, fixtures) {
            let line = try response.line()

            #expect(!line.contains(0x0A))
            #expect(
                try BrowserHostFixtures.sameObject(line, fixture.line),
                "id \(response.id): \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    private static let exampleDomainPage = BrowserHostPage(
        url: "https://example.com/",
        title: "Example Domain",
        readyState: "complete",
        nodes: [
            BrowserHostNode(
                nodeId: .string("1"),
                role: BrowserHostAXValue("RootWebArea"),
                name: BrowserHostAXValue("Example Domain"),
                childIds: [.string("2"), .string("3"), .string("4")]
            ),
            BrowserHostNode(
                nodeId: .string("2"),
                role: BrowserHostAXValue("heading"),
                name: BrowserHostAXValue("Example Domain"),
                properties: [BrowserHostAXProperty(name: "level", value: BrowserHostAXValue(1))]
            ),
            BrowserHostNode(
                nodeId: .string("3"),
                role: BrowserHostAXValue("paragraph"),
                name: BrowserHostAXValue(""),
                childIds: [.string("5")]
            ),
            BrowserHostNode(
                nodeId: .string("4"),
                role: BrowserHostAXValue("link"),
                name: BrowserHostAXValue("More information..."),
                properties: [
                    BrowserHostAXProperty(name: "url", value: BrowserHostAXValue("https://www.iana.org/domains/example"))
                ],
                backendDOMNodeId: 7
            ),
            BrowserHostNode(
                nodeId: .string("5"),
                role: BrowserHostAXValue("StaticText"),
                name: BrowserHostAXValue("This domain is for use in illustrative examples in documents.")
            )
        ]
    )

    private static let signInPage = BrowserHostPage(
        url: "https://example.com/login",
        title: "Sign in",
        readyState: "complete",
        nodes: [
            BrowserHostNode(
                nodeId: .integer(1),
                role: BrowserHostAXValue("RootWebArea"),
                name: BrowserHostAXValue("Sign in"),
                childIds: [.integer(2), .integer(3), .integer(4)]
            ),
            BrowserHostNode(
                nodeId: .integer(2),
                role: BrowserHostAXValue("textbox"),
                name: BrowserHostAXValue("Email"),
                value: BrowserHostAXValue(""),
                properties: [
                    BrowserHostAXProperty(name: "editable", value: BrowserHostAXValue("plaintext")),
                    BrowserHostAXProperty(name: "focused", value: BrowserHostAXValue(true))
                ],
                backendDOMNodeId: 11
            ),
            BrowserHostNode(
                nodeId: .integer(3),
                role: BrowserHostAXValue("textbox"),
                name: BrowserHostAXValue("Password"),
                properties: [BrowserHostAXProperty(name: "editable", value: BrowserHostAXValue("plaintext"))],
                backendDOMNodeId: 12
            ),
            BrowserHostNode(
                nodeId: .integer(4),
                role: BrowserHostAXValue("button"),
                name: BrowserHostAXValue("Sign in"),
                backendDOMNodeId: 13
            )
        ]
    )

    private static let accountPage = BrowserHostPage(
        url: "https://example.com/account",
        title: "Your account",
        readyState: "interactive",
        nodes: exampleDomainPage.nodes
    )

    /// The 40 responses `responses.jsonl` pins, in file order: 27 successes
    /// answering the 27 numbered requests, then 13 host errors, one per
    /// enumerated reason.
    private static let responseFixtures: [BrowserHostResponse] = [
        BrowserHostResponse(
            id: 1,
            result: .tabOpen(
                BrowserHostTabResult(tabId: "t1", url: "https://example.com/", title: "Example Domain", page: exampleDomainPage)
            )
        ),
        BrowserHostResponse(id: 2, result: .tabOpen(BrowserHostTabResult(tabId: "t2", url: "https://example.com/report.pdf", title: "report.pdf"))),
        BrowserHostResponse(
            id: 3,
            result: .tabNavigate(
                BrowserHostTabResult(tabId: "t1", url: "https://example.com/login", title: "Sign in", page: signInPage)
            )
        ),
        BrowserHostResponse(
            id: 4,
            result: .tabList([
                BrowserHostListedTab(tabId: "t1", url: "https://example.com/login", title: "Sign in", active: true),
                BrowserHostListedTab(tabId: "t3", url: "https://example.com/help", title: "Help", active: false, openerTabId: "t1")
            ])
        ),
        BrowserHostResponse(id: 5, result: .tabFocus(tabId: "t1", url: "https://example.com/login", title: "Sign in")),
        BrowserHostResponse(id: 6, result: .tabClose(tabId: "t2")),
        BrowserHostResponse(id: 7, result: .pageSnapshot(signInPage)),
        BrowserHostResponse(
            id: 8,
            result: .pageScreenshot(
                BrowserHostScreenshotResult(
                    path: "/Users/person/.fermix/workspace/browser/artifacts/0bqP3d/screenshots/41.png",
                    mimeType: "image/png",
                    bytes: 48213,
                    url: "https://example.com/login",
                    devicePixelRatio: 2
                )
            )
        ),
        BrowserHostResponse(
            id: 9,
            result: .pagePdf(
                BrowserHostPdfResult(
                    path: "/Users/person/.fermix/workspace/browser/artifacts/0bqP3d/pdf/42.pdf",
                    bytes: 91022,
                    url: "https://example.com/login"
                )
            )
        ),
        BrowserHostResponse(
            id: 10,
            result: .pageAct(BrowserHostActResult(url: "https://example.com/", title: "Example Domain", page: exampleDomainPage))
        ),
        BrowserHostResponse(id: 11, result: .pageAct(BrowserHostActResult(url: "https://example.com/login", title: "Sign in"))),
        BrowserHostResponse(id: 12, result: .pageAct(BrowserHostActResult(url: "https://example.com/login", title: "Sign in"))),
        BrowserHostResponse(id: 13, result: .pageAct(BrowserHostActResult(url: "https://example.com/login", title: "Sign in"))),
        BrowserHostResponse(
            id: 14,
            result: .pageAct(BrowserHostActResult(url: "https://example.com/account", title: "Your account", page: accountPage))
        ),
        BrowserHostResponse(
            id: 15,
            result: .pageAct(BrowserHostActResult(url: "https://example.com/login", title: "Sign in", page: signInPage))
        ),
        BrowserHostResponse(id: 16, result: .pageAct(BrowserHostActResult(url: "https://example.com/", title: "Example Domain"))),
        BrowserHostResponse(
            id: 17,
            result: .pageAct(
                BrowserHostActResult(
                    url: "https://example.com/cart",
                    title: "Cart",
                    value: .object(["x": .integer(20), "y": .integer(480), "width": .integer(320), "height": .integer(44)])
                )
            )
        ),
        BrowserHostResponse(id: 18, result: .pageAct(BrowserHostActResult(url: "https://example.com/cart", title: "Order placed"))),
        BrowserHostResponse(
            id: 19,
            result: .pageAct(BrowserHostActResult(url: "https://example.com/", title: "Example Domain", page: exampleDomainPage))
        ),
        BrowserHostResponse(id: 20, result: .pageUpload(tabId: "t1")),
        BrowserHostResponse(id: 21, result: .dialogResolve(tabId: "t1")),
        BrowserHostResponse(
            id: 22,
            result: .cookiesGet(
                url: "https://example.com/login",
                cookies: [
                    BrowserHostCookie(
                        name: "session", domain: "example.com", path: "/",
                        secure: true, httpOnly: true, sameSite: "Lax", session: true
                    ),
                    BrowserHostCookie(
                        name: "theme", domain: ".example.com", path: "/",
                        secure: false, httpOnly: false, expires: 1_822_000_000, session: false
                    )
                ]
            )
        ),
        BrowserHostResponse(id: 23, result: .cookiesClear(cleared: 2)),
        BrowserHostResponse(
            id: 24,
            result: .hostStatus(
                BrowserHostStatusResult(hostVersion: "0.2.0", profileId: "fermix-web-3c9a", available: true, taskTabs: 2, personTabs: 1)
            )
        ),
        BrowserHostResponse(id: 25, result: .taskRelease(["t1", "t3"])),
        BrowserHostResponse(id: 26, result: .hostStopAck),
        BrowserHostResponse(id: 27, result: .pageAct(BrowserHostActResult(url: "https://example.com/login", title: "Sign in"))),
        BrowserHostResponse(id: 5, error: BrowserHostError(reason: .tabNotFound, message: "no tab t9 in this host")),
        BrowserHostResponse(id: 1, error: BrowserHostError(reason: .capReached, message: "task task-9f2c1a7e4b0d already owns 10 tabs")),
        BrowserHostResponse(id: 5, error: BrowserHostError(reason: .notOwner, message: "tab t4 is the person's")),
        BrowserHostResponse(id: 3, error: BrowserHostError(reason: .navigationRefused, message: "the pane does not open mailto: links")),
        BrowserHostResponse(id: 16, error: BrowserHostError(reason: .actFailed, message: "the element has no box on screen")),
        BrowserHostResponse(id: 10, error: BrowserHostError(reason: .staleRef, message: "no element 13 on this page")),
        BrowserHostResponse(id: 11, error: BrowserHostError(reason: .dialogBlocked, message: "a confirm dialog is open on t1")),
        BrowserHostResponse(id: 21, error: BrowserHostError(reason: .noDialog, message: "no dialog is open on t1")),
        BrowserHostResponse(id: 18, error: BrowserHostError(reason: .waitTimeout, message: "the text did not appear within 5000 ms")),
        BrowserHostResponse(id: 8, error: BrowserHostError(reason: .writeFailed, message: "the disk is full")),
        BrowserHostResponse(id: 20, error: BrowserHostError(reason: .uploadFailed, message: "the element is not a file input")),
        BrowserHostResponse(id: 12, error: BrowserHostError(reason: .invalidRequest, message: "fields must name inputs")),
        BrowserHostResponse(id: 10, error: BrowserHostError(reason: .hostUnavailable, message: "the Mac is locked"))
    ]

    // MARK: - Failure shapes

    @Test("a missing required field is refused by its name")
    func missingFieldIsNamed() {
        #expect(throws: BrowserHostDecodeFailure.missingField("task_id")) {
            _ = try BrowserHostInbound.decode(Data(#"{"id":1,"type":"tab.open","url":"https://x","observe":false,"download_dir":"/d","task_tab_cap":1,"tab_cap":1}"#.utf8))
        }
        #expect(throws: BrowserHostDecodeFailure.missingField("id")) {
            _ = try BrowserHostInbound.decode(Data(#"{"type":"tab.list","task_id":"t"}"#.utf8))
        }
        #expect(throws: BrowserHostDecodeFailure.missingField("min_version")) {
            _ = try BrowserHostInbound.decode(Data(#"{"type":"server_hello","max_version":1}"#.utf8))
        }
    }

    @Test("a field of the wrong shape is refused by its name")
    func invalidFieldIsNamed() {
        #expect(throws: BrowserHostDecodeFailure.invalidField("kind")) {
            _ = try BrowserHostInbound.decode(
                Data(#"{"id":1,"type":"page.act","tab_id":"t1","kind":"scroll_page","observe":false}"#.utf8)
            )
        }
        #expect(throws: BrowserHostDecodeFailure.invalidField("snapshot.mode")) {
            let line = #"{"id":1,"type":"tab.open","task_id":"t","url":"https://x","observe":true,"#
                + #""download_dir":"/d","task_tab_cap":1,"tab_cap":1,"#
                + #""snapshot":{"mode":"sideways","max_chars":1,"depth":1}}"#
            _ = try BrowserHostInbound.decode(Data(line.utf8))
        }
    }

    @Test("a line that is not an object, or names an unknown type, is refused")
    func structurallyInvalidLinesAreRefused() {
        #expect(throws: BrowserHostDecodeFailure.notAnObject) {
            _ = try BrowserHostInbound.decode(Data("[1,2,3]".utf8))
        }
        #expect(throws: BrowserHostDecodeFailure.missingType) {
            _ = try BrowserHostInbound.decode(Data(#"{"tab_id":"t"}"#.utf8))
        }
        #expect(throws: BrowserHostDecodeFailure.malformedJSON) {
            _ = try BrowserHostInbound.decode(Data("{not json".utf8))
        }
        #expect(throws: BrowserHostDecodeFailure.invalidField("type")) {
            _ = try BrowserHostInbound.decode(Data(#"{"id":1,"type":"tab.teleport","tab_id":"t"}"#.utf8))
        }
    }

    /// The daemon refuses a longer line and closes the connection, so this
    /// build refuses one of its own before sending it.
    @Test("a line over the contract's cap is refused")
    func lineOverTheCapIsRefused() throws {
        func event(_ reason: String) -> BrowserHostEvent {
            .availability(available: false, reason: reason)
        }
        let overhead = try event("").line().count
        let cap = BrowserHostProtocol.maximumLineBytes
        let longest = String(repeating: "a", count: cap - overhead)

        #expect(try event(longest).line().count == cap)
        #expect(throws: BrowserHostEncodeFailure.lineTooLarge(bytes: cap + 1)) {
            _ = try event(longest + "a").line()
        }
    }

    @Test("a version window names the side that must update")
    func windowNamesTheOutdatedSide() {
        let window = BrowserHostVersionWindow(minimum: 2, maximum: 3)

        #expect(window.contains(2))
        #expect(!window.contains(BrowserHostProtocol.version))
        #expect(window.direction(for: 1) == .clientTooOld)
        #expect(window.direction(for: 4) == .clientTooNew)
    }

    /// An error's `message` never sends the daemon a line past its own bound,
    /// even if a diagnostic string somehow ran long.
    @Test("a host error's message is bounded to the contract's cap")
    func hostErrorMessageIsBounded() {
        let over = String(repeating: "a", count: BrowserHostProtocol.maximumMessageChars + 50)
        let error = BrowserHostError(reason: .actFailed, message: over)

        #expect(error.message.count == BrowserHostProtocol.maximumMessageChars)
    }

    /// `task.cancel`'s `reason` never sends the daemon a value past the
    /// contract's own cap, even if the caller passed a longer one.
    @Test("a task.cancel reason is bounded to the contract's cap")
    func taskCancelReasonIsBounded() throws {
        let over = String(repeating: "a", count: BrowserHostProtocol.maximumReasonChars + 50)
        let line = try BrowserHostEvent.taskCancel(taskId: "task-2", reason: over).line()
        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]

        #expect((object?["reason"] as? String)?.count == BrowserHostProtocol.maximumReasonChars)
    }
}
