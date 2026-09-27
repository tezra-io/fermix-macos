import Foundation
import Testing

@testable import FermixAppCore

/// The `browser_host` wire client, driven with the fake line transport, a
/// manual deadline scheduler, and the real `BrowserCoordinator` `BrowserHarness`
/// already builds over fake pages: the goldens in `BrowserHostProtocolTests`
/// prove the wire shapes, and this proves the client dispatches onto the
/// coordinator and a tab's driving API, and answers by id.
@MainActor
@Suite("Browser host client")
struct BrowserHostClientTests {
    private typealias Transport = FakeLineSocketTransport<BrowserHostInbound, BrowserHostDecodeFailure>

    @Test("the handshake attaches and sends the current availability right after")
    func handshakeAttachesWithAvailability() throws {
        let harness = BrowserHarness()
        let transport = Transport()
        // Named, not discarded: before the attach completes nothing else
        // holds this client, and a discarded result is deallocated at once,
        // so the `serverHello` below would arrive at nobody.
        let client = Self.makeClient(harness: harness, transport: transport)

        let hello = try transport.sentObjects()
        #expect(transport.connectedPaths == ["/tmp/fermix-test/browser_host.sock"])
        #expect(hello.count == 1)
        #expect(hello[0]["type"] as? String == "client_hello")
        #expect(hello[0]["protocol_version"] as? Int == BrowserHostProtocol.version)

        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))

        let sent = try transport.sentObjects()
        #expect(sent.count == 3)
        #expect(sent[1]["type"] as? String == "attached")
        #expect(sent[1]["host_version"] as? String == "0.2.0")
        #expect(sent[1]["profile_id"] as? String == "profile-1")
        #expect(sent[2]["type"] as? String == "availability")
        #expect(sent[2]["available"] as? Bool == true)
        #expect(sent[2]["reason"] == nil)
        _ = client
    }

    @Test("a request is dispatched to the coordinator and answered by id")
    func requestDispatchedAndAnsweredByID() async throws {
        let harness = BrowserHarness()
        let (_, transport) = Self.attachedClient(harness: harness)

        transport.deliver(.request(.tabOpen(id: 7, BrowserHostTabOpenRequest(
            taskId: "task-1",
            url: "https://example.com/",
            observe: false,
            downloadDir: "/tmp/fermix-test/workspace/downloads",
            taskTabCap: 10,
            tabCap: 60,
            snapshot: nil
        ))))

        await Self.waitUntil { transport.sent.count >= 4 }

        let response = try #require(transport.sentObjects().last)
        #expect(response["id"] as? Int == 7)
        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["url"] as? String == "https://example.com/")
        #expect(harness.page(0).loaded == [URL(string: "https://example.com/")!])
    }

    @Test("a request naming a tab the host does not have answers tab_not_found")
    func unknownTabAnswersTabNotFound() throws {
        let harness = BrowserHarness()
        let (_, transport) = Self.attachedClient(harness: harness)

        transport.deliver(.request(.tabFocus(id: 3, tabId: UUID().uuidString)))

        let response = try #require(transport.sentObjects().last)
        #expect(response["id"] as? Int == 3)
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "tab_not_found")
    }

    /// A tab that exists but is the person's, not any task's, is `not_owner`
    /// rather than `tab_not_found`: the daemon is the sole issuer of every id
    /// it ever names, so a real tab it does not recognise as its own is the
    /// person's.
    @Test("a request naming the person's tab answers not_owner")
    func personsTabAnswersNotOwner() throws {
        let harness = BrowserHarness()
        harness.coordinator.newTab(profile: .shared)
        let personsTab = try #require(harness.model.tabs.first)
        let (_, transport) = Self.attachedClient(harness: harness)

        transport.deliver(.request(.tabClose(id: 4, tabId: personsTab.id.uuidString)))

        let response = try #require(transport.sentObjects().last)
        #expect(response["id"] as? Int == 4)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["reason"] as? String == "not_owner")
    }

    @Test("host.stop_ack completes the quit hold sendHostStopping started")
    func hostStopAckCompletesTheQuitHold() throws {
        let harness = BrowserHarness()
        let (client, transport) = Self.attachedClient(harness: harness)
        var completed = false

        client.sendHostStopping { completed = true }

        let stopping = try #require(transport.sentObjects().last)
        #expect(stopping["type"] as? String == "host_stopping")
        #expect(!completed)

        transport.deliver(.request(.hostStopAck(id: 99)))

        let ack = try #require(transport.sentObjects().last)
        #expect(ack["id"] as? Int == 99)
        #expect(ack["ok"] as? Bool == true)
        #expect(completed)
    }

    @Test("a lost connection is retried after the backoff")
    func reconnectsAfterAFailure() throws {
        let harness = BrowserHarness()
        let transport = Transport()
        let deadlines = ManualDeadlineScheduler()
        // Named for the same reason as above: the handshake has not attached
        // yet when `serverHello` arrives, so nothing else is holding this
        // client alive until it does.
        let client = Self.makeClient(harness: harness, transport: transport, deadlines: deadlines)
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        #expect(transport.closeCount == 0)

        transport.fail(.peerClosed)

        #expect(transport.closeCount == 1)
        #expect(deadlines.scheduledDelays == [1])

        deadlines.fireAll()

        #expect(transport.connectedPaths.count == 2)
        _ = client
    }

    @Test("an availability change is forwarded to the daemon as it happens")
    func availabilityForwardedOnChange() throws {
        let harness = BrowserHarness()
        let (_, transport) = Self.attachedClient(harness: harness)

        harness.session.set(.unavailable(.screenLocked))

        let sent = try #require(transport.sentObjects().last)
        #expect(sent["type"] as? String == "availability")
        #expect(sent["available"] as? Bool == false)
        #expect(sent["reason"] as? String == "the Mac is locked")
    }

    // MARK: - Mechanics

    private static func makeClient(
        harness: BrowserHarness,
        transport: Transport,
        deadlines: ManualDeadlineScheduler? = nil,
        hostVersion: String = "0.2.0",
        profileID: String = "profile-1"
    ) -> BrowserHostClient {
        let client = BrowserHostClient(
            lines: transport,
            socketPath: { "/tmp/fermix-test/browser_host.sock" },
            profileID: { profileID },
            workspaceRoot: { URL(fileURLWithPath: "/tmp/fermix-test/workspace", isDirectory: true) },
            hostVersion: hostVersion,
            coordinator: harness.coordinator,
            deadlines: deadlines ?? ManualDeadlineScheduler()
        )
        client.connect()
        return client
    }

    /// A client that has already completed the handshake and attached, with
    /// the availability the attach sent already drained from `transport.sent`
    /// so a case starts counting from its own first request.
    private static func attachedClient(
        harness: BrowserHarness
    ) -> (client: BrowserHostClient, transport: Transport) {
        let transport = Transport()
        let client = Self.makeClient(harness: harness, transport: transport)
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))

        return (client, transport)
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            await Task.yield()
        }
    }
}
