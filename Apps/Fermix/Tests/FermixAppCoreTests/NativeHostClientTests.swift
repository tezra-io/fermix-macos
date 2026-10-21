import Foundation
import Testing
import UserNotifications

@testable import FermixAppCore

/// The `native_host` wire client, driven with the fake line transport, a
/// manual deadline scheduler, and the real `MacNotifications` over a scripted
/// center: the goldens in `NativeHostProtocolTests` prove the wire shapes,
/// and this proves the client attaches, reports the grant, answers each
/// request by id, carries the person's presses, and holds the quit.
@MainActor
@Suite("Native host client")
struct NativeHostClientTests {
    private typealias Transport = FakeLineSocketTransport<NativeHostInbound, NativeHostDecodeFailure>

    // MARK: - Attaching

    @Test("the handshake attaches and reports the grant right after")
    func handshakeAttachesAndReportsTheGrant() async throws {
        let harness = Harness(grant: .granted)

        let hello = try harness.transport.sentObjects()
        #expect(harness.transport.connectedPaths == ["/tmp/fermix-test/native_host.sock"])
        #expect(hello.count == 1)
        #expect(hello[0]["type"] as? String == "client_hello")
        #expect(hello[0]["protocol_version"] as? Int == NativeHostProtocol.version)

        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        #expect(await yieldUntil { harness.transport.sent.count == 3 })

        let sent = try harness.transport.sentObjects()
        #expect(sent[1]["type"] as? String == "attached")
        #expect(sent[1]["host_version"] as? String == "0.6.0")
        #expect(sent[2]["type"] as? String == "capabilities")
        #expect(sent[2]["notifications"] as? String == "granted")
    }

    @Test("every attach reports its grant again, read fresh")
    func everyAttachReportsAgain() async throws {
        let harness = try await Harness.attached(grant: .notAsked)

        harness.center.status = .notGranted
        harness.transport.fail(.peerClosed)
        harness.deadlines.fireAll()
        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        #expect(await yieldUntil { (try? harness.capabilities().count) == 2 })

        #expect(try harness.capabilities() == ["not_asked", "not_granted"])
    }

    // MARK: - Requests

    @Test("host.status answers the version and the grant, read fresh and with no prompt")
    func hostStatusAnswersByID() async throws {
        let harness = try await Harness.attached(grant: .notAsked)

        harness.transport.deliver(.request(.hostStatus(id: 3)))
        let answer = try await harness.answer(to: 3)

        #expect(answer["ok"] as? Bool == true)
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["host_version"] as? String == "0.6.0")
        #expect(result["notifications"] as? String == "not_asked")
        #expect(harness.center.promptsRaised == 0)
    }

    /// The contract's own sequence: the prompt is answered, the new grant
    /// goes out as `capabilities`, and then the request is answered.
    @Test("notifications.authorize prompts, reports the new grant, then answers it")
    func authorizeReportsBeforeItAnswers() async throws {
        let harness = try await Harness.attached(grant: .notAsked, promptAnswer: .granted)

        harness.transport.deliver(.request(.notificationsAuthorize(id: 2)))
        let answer = try await harness.answer(to: 2)

        #expect((answer["result"] as? [String: Any])?["state"] as? String == "granted")
        #expect(harness.center.promptsRaised == 1)
        let sent = try harness.transport.sentObjects()
        let reported = try #require(sent.lastIndex { $0["type"] as? String == "capabilities" && $0["notifications"] as? String == "granted" })
        let answered = try #require(sent.lastIndex { $0["id"] as? Int == 2 })
        #expect(reported < answered)
    }

    @Test("notifications.authorize on a decided grant answers at once with no prompt and no report")
    func authorizeOnADecidedGrant() async throws {
        let harness = try await Harness.attached(grant: .notGranted)

        harness.transport.deliver(.request(.notificationsAuthorize(id: 4)))
        let answer = try await harness.answer(to: 4)

        #expect((answer["result"] as? [String: Any])?["state"] as? String == "not_granted")
        #expect(harness.center.promptsRaised == 0)
        #expect(try harness.capabilities() == ["not_granted"])
    }

    @Test("notifications.post answers the notification's own id")
    func postAnswersItsID() async throws {
        let harness = try await Harness.attached(grant: .granted)

        harness.transport.deliver(.request(.notificationsPost(id: 3, Self.tea)))
        let answer = try await harness.answer(to: 3)

        let posted = try #require(harness.center.added.first)
        #expect(answer["ok"] as? Bool == true)
        #expect((answer["result"] as? [String: Any])?["notification_id"] as? String == posted.identifier)
        #expect(posted.content.userInfo[MacNotifications.reminderIDKey] as? String == "rem_8Kf2xQ1vT0w")
    }

    @Test("notifications.post without the grant is refused not_authorized in the sentence for that grant")
    func postWithoutTheGrant() async throws {
        for (grant, sentence) in [
            (NotificationGrant.notGranted, ProductStrings[.nativeHostRefusalTurnedOff]),
            (.notAsked, ProductStrings[.nativeHostRefusalNotAsked])
        ] {
            let harness = try await Harness.attached(grant: grant)

            harness.transport.deliver(.request(.notificationsPost(id: 3, Self.tea)))
            let answer = try await harness.answer(to: 3)

            let error = try #require(answer["error"] as? [String: Any])
            #expect(error["reason"] as? String == "not_authorized")
            #expect(error["message"] as? String == sentence)
            #expect(harness.center.promptsRaised == 0, "a post never prompts")
        }
    }

    @Test("notifications.post the framework refuses is post_failed in the framework's words")
    func postTheFrameworkRefuses() async throws {
        let harness = try await Harness.attached(grant: .granted)
        harness.center.addFailure = FrameworkRefusal(words: "The notification could not be scheduled")

        harness.transport.deliver(.request(.notificationsPost(id: 4, Self.tea)))
        let answer = try await harness.answer(to: 4)

        let error = try #require(answer["error"] as? [String: Any])
        #expect(error["reason"] as? String == "post_failed")
        #expect(error["message"] as? String == "The notification could not be scheduled")
    }

    /// The engine's own protocol holds a post to its bounds before it is
    /// written, so the app keeps no second copy of them: what arrives is shown
    /// as it came.
    @Test("a post is shown as the engine sent it, with no second copy of the engine's bounds")
    func postIsShownAsSent() async throws {
        let harness = try await Harness.attached(grant: .granted)
        let long = NativeHostPostRequest(
            title: String(repeating: "t", count: 300),
            body: String(repeating: "b", count: 2000),
            sound: true,
            actions: [NativeHostAction(id: "snooze_10m", title: String(repeating: "s", count: 80))],
            reminderId: String(repeating: "r", count: 80)
        )

        harness.transport.deliver(.request(.notificationsPost(id: 3, long)))
        let answer = try await harness.answer(to: 3)

        #expect(answer["ok"] as? Bool == true)
        let posted = try #require(harness.center.added.first)
        #expect(posted.content.title.count == 300)
        #expect(posted.content.body.count == 2000)
    }

    /// A request whose fields decode but do not fit what the app can show is
    /// answered by its id, the connection held, and nothing reaches the
    /// framework.
    @Test("a post that does not fit is answered invalid_request and the connection holds")
    func postThatDoesNotFit() async throws {
        let snooze = NativeHostAction(id: "snooze_10m", title: "Snooze 10 minutes")
        let misfits: [(NativeHostPostRequest, String)] = [
            (NativeHostPostRequest(title: "t", body: "b", sound: true, actions: [snooze], reminderId: nil), "names the reminder"),
            (NativeHostPostRequest(title: "t", body: "b", sound: true, actions: [snooze, snooze], reminderId: "r"), "named twice"),
            (NativeHostPostRequest(title: "t", body: "b", sound: true, actions: [NativeHostAction(id: "snooze_1h", title: "Later")], reminderId: "r"), "snooze_1h")
        ]
        let harness = try await Harness.attached(grant: .granted)

        for (index, (payload, words)) in misfits.enumerated() {
            harness.transport.deliver(.request(.notificationsPost(id: 10 + index, payload)))
            let answer = try await harness.answer(to: 10 + index)

            let error = try #require(answer["error"] as? [String: Any])
            #expect(error["reason"] as? String == "invalid_request", "\(words)")
            #expect((error["message"] as? String)?.contains(words) == true, "\(error["message"] ?? "") names \(words)")
        }

        #expect(harness.center.added.isEmpty)
        #expect(harness.transport.closeCount == 0)
    }

    // MARK: - Reporting the grant

    @Test("a grant that changes on a return to the app is reported, and an unchanged one is not")
    func grantChangesAreReported() async throws {
        let harness = try await Harness.attached(grant: .granted)

        harness.center.status = .notGranted
        await harness.notifications.refresh()
        await harness.notifications.refresh()

        #expect(try harness.capabilities() == ["granted", "not_granted"])
    }

    // MARK: - The person's presses

    @Test("a Snooze press is sent as notification.action naming its reminder")
    func pressIsSent() async throws {
        let harness = try await Harness.attached(grant: .granted)

        harness.center.deliver(NotificationResponse(actionIdentifier: "snooze_10m", reminderID: "rem_8Kf2xQ1vT0w"))

        let sent = try #require(harness.transport.sentObjects().last)
        #expect(sent["type"] as? String == "notification.action")
        #expect(sent["reminder_id"] as? String == "rem_8Kf2xQ1vT0w")
        #expect(sent["action"] as? String == "snooze_10m")
    }

    /// A press on a notification can be what launched the app: it waits for
    /// the connection, and goes out behind that connection's first report.
    @Test("a press made before the attach goes out right after the first capabilities")
    func pressBeforeAttachWaits() async throws {
        let harness = Harness(grant: .granted)

        harness.center.deliver(NotificationResponse(actionIdentifier: "snooze_10m", reminderID: "rem_8Kf2xQ1vT0w"))
        #expect(harness.transport.sent.count == 1, "only client_hello so far")

        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        #expect(await yieldUntil { harness.transport.sent.count == 4 })

        let types = try harness.transport.sentObjects().map { $0["type"] as? String }
        #expect(types == ["client_hello", "attached", "capabilities", "notification.action"])
    }

    // MARK: - Reconnecting

    @Test("a lost connection is retried after the backoff, and quick losses grow it")
    func reconnectsWithTheBackoff() async throws {
        let harness = try await Harness.attached(grant: .granted)

        harness.transport.fail(.peerClosed)
        #expect(harness.transport.closeCount == 1)
        #expect(harness.deadlines.scheduledDelays == [1])

        harness.deadlines.fireAll()
        #expect(harness.transport.connectedPaths.count == 2)
        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        harness.transport.fail(.peerClosed)
        #expect(harness.deadlines.scheduledDelays == [2])
    }

    @Test("an attach held past the grace resets the backoff")
    func graceHeldResetsTheBackoff() async throws {
        let harness = Harness(grant: .granted)
        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        harness.transport.fail(.peerClosed)
        harness.deadlines.fireAll()

        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        #expect(harness.deadlines.scheduledDelays == [ReconnectBackoff.grace])
        harness.deadlines.fireAll()
        harness.transport.fail(.peerClosed)

        #expect(harness.deadlines.scheduledDelays == [1])
    }

    @Test("a daemon error while attached closes the connection and it is tried again")
    func daemonErrorWhileAttachedReconnects() async throws {
        let harness = try await Harness.attached(grant: .granted)

        harness.transport.deliver(try Self.daemonError("invalid_frame"))

        #expect(harness.transport.closeCount == 1)
        #expect(harness.deadlines.scheduledDelays == [1])
        harness.deadlines.fireAll()
        #expect(harness.transport.connectedPaths.count == 2)
    }

    /// Another host is attached for now: it is not this build's version, so
    /// the connection is asked for again, never given up on.
    @Test("host_already_attached during the handshake is tried again after the backoff")
    func hostAlreadyAttachedIsRetried() throws {
        let harness = Harness(grant: .granted)

        harness.transport.deliver(try Self.daemonError("host_already_attached"))

        #expect(harness.transport.closeCount == 1)
        #expect(harness.deadlines.scheduledDelays == [1])
        harness.deadlines.fireAll()
        #expect(harness.transport.connectedPaths.count == 2)
    }

    @Test("a daemon that never answers client_hello is dropped at the handshake deadline and tried again")
    func handshakeDeadlineDrops() {
        let harness = Harness(grant: .granted)
        #expect(harness.deadlines.scheduledDelays == [NativeHostProtocol.handshakeTimeout])

        harness.deadlines.fireAll()

        #expect(harness.transport.closeCount == 1)
        #expect(harness.deadlines.scheduledDelays == [1])
        harness.deadlines.fireAll()
        #expect(harness.transport.connectedPaths.count == 2)
    }

    @Test("an engine with no native host socket is asked again after the backoff")
    func absentSocketIsRetried() {
        let transport = Transport()
        transport.connectResult = .failure(.system(errno: ENOENT))
        let harness = Harness(grant: .granted, transport: transport)

        #expect(harness.deadlines.scheduledDelays == [1])
        harness.deadlines.fireAll()
        #expect(harness.transport.connectedPaths.count == 2)
    }

    @Test("a version window that excludes this build refuses and stops retrying")
    func versionRefusalStopsRetrying() {
        let harness = Harness(grant: .granted)

        harness.transport.deliver(.serverHello(minVersion: 2, maxVersion: 2))

        #expect(harness.transport.closeCount == 1)
        #expect(harness.deadlines.liveCount == 0)
        harness.client.connect()
        #expect(harness.transport.connectedPaths.count == 2)
    }

    /// Request ids start over on every connection, so an answer worked out
    /// for the last one must not answer the next one's request of that id.
    @Test("an answer the last connection asked for never goes out on the next one")
    func staleAnswerIsDropped() async throws {
        let harness = try await Harness.attached(grant: .notAsked, promptAnswer: nil)

        harness.transport.deliver(.request(.notificationsAuthorize(id: 1)))
        #expect(await yieldUntil { harness.center.promptIsUp })
        harness.transport.fail(.peerClosed)
        harness.deadlines.fireAll()
        harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        #expect(await yieldUntil { (try? harness.capabilities().count) == 2 })

        harness.center.answerPrompt(.granted)
        #expect(await yieldUntil { (try? harness.capabilities().last) == "granted" })

        #expect(try harness.transport.sentObjects().allSatisfy { $0["id"] == nil }, "nothing answers id 1 on the new connection")
    }

    // MARK: - Quitting

    @Test("an attached quit sends host_stopping and holds until host.stop_ack")
    func quitHoldsForTheStopAck() async throws {
        let harness = try await Harness.attached(grant: .granted)
        var done = 0

        harness.client.stopHost { done += 1 }

        let stopping = try #require(harness.transport.sentObjects().last)
        #expect(stopping["type"] as? String == "host_stopping")
        #expect(done == 0)

        harness.transport.deliver(.request(.hostStopAck(id: 9)))

        let ack = try #require(harness.transport.sentObjects().last)
        #expect(ack["id"] as? Int == 9)
        #expect(ack["ok"] as? Bool == true)
        #expect((ack["result"] as? [String: Any])?.isEmpty == true)
        #expect(done == 1)
        #expect(harness.deadlines.liveCount == 0, "the answer calls off the bound")
        harness.transport.deliver(.request(.hostStopAck(id: 10)))
        #expect(done == 1, "a second answer does not end the hold twice")
    }

    @Test("the quit's own bound ends the hold when the answer never comes")
    func quitBoundEndsTheHold() async throws {
        let harness = try await Harness.attached(grant: .granted)
        var done = 0

        harness.client.stopHost { done += 1 }
        #expect(harness.deadlines.scheduledDelays == [NativeHostClient.quitBound])
        harness.deadlines.fireAll()

        #expect(done == 1)
    }

    @Test("a quit with nothing attached goes on at once, and nothing reconnects after it")
    func unattachedQuitIsImmediate() throws {
        let transport = Transport()
        transport.connectResult = .failure(.system(errno: ENOENT))
        let harness = Harness(grant: .granted, transport: transport)
        var done = 0

        harness.client.stopHost { done += 1 }
        harness.deadlines.fireAll()
        harness.client.connect()

        #expect(done == 1)
        #expect(harness.transport.connectedPaths.count == 1)
        #expect(try harness.transport.sentObjects().isEmpty)
    }

    @Test("while quitting, a request already on the wire is host_unavailable and a press is not sent")
    func requestsWhileQuitting() async throws {
        let harness = try await Harness.attached(grant: .granted)
        harness.client.stopHost {}

        harness.transport.deliver(.request(.notificationsPost(id: 6, Self.tea)))
        harness.center.deliver(NotificationResponse(actionIdentifier: "snooze_10m", reminderID: "rem_8Kf2xQ1vT0w"))

        let answer = try await harness.answer(to: 6)
        let error = try #require(answer["error"] as? [String: Any])
        #expect(error["reason"] as? String == "host_unavailable")
        #expect(error["message"] as? String == ProductStrings[.nativeHostReasonAppQuitting])
        #expect(harness.center.added.isEmpty)
        #expect(try harness.transport.sentObjects().contains { $0["type"] as? String == "notification.action" } == false)
    }

    @Test("a connection lost while quitting ends the hold at once and is not tried again")
    func lossWhileQuitting() async throws {
        let harness = try await Harness.attached(grant: .granted)
        var done = 0
        harness.client.stopHost { done += 1 }

        harness.transport.fail(.peerClosed)
        harness.deadlines.fireAll()

        #expect(done == 1)
        #expect(harness.transport.connectedPaths.count == 1)
    }

    // MARK: - Mechanics

    /// One of the daemon's own refusals, as the line it sends.
    static func daemonError(_ reason: String) throws -> NativeHostInbound {
        try NativeHostInbound.decode(Data(#"{"type":"error","reason":"\#(reason)"}"#.utf8))
    }

    static let tea = NativeHostPostRequest(
        title: "Tea",
        body: "Tea, today at 16:05 (in 10 minutes).",
        sound: true,
        actions: [NativeHostAction(id: "snooze_10m", title: "Snooze 10 minutes")],
        reminderId: "rem_8Kf2xQ1vT0w"
    )

    /// One client over the fake socket, a manual scheduler and the real
    /// notifications owner over a scripted center, connected on build.
    @MainActor
    private struct Harness {
        let transport: Transport
        let deadlines = ManualDeadlineScheduler()
        let center: FakeNotificationCenter
        let notifications: MacNotifications
        let client: NativeHostClient

        init(grant: NotificationGrant, promptAnswer: NotificationGrant? = .granted, transport: Transport = Transport()) {
            self.transport = transport
            center = FakeNotificationCenter(status: grant, promptAnswer: promptAnswer)
            notifications = MacNotifications(center: center, bundleIdentifier: "io.tezra.FermixPet.test", activations: NotificationCenter())
            client = NativeHostClient(
                lines: transport,
                socketPath: { "/tmp/fermix-test/native_host.sock" },
                hostVersion: "0.6.0",
                notifications: notifications,
                deadlines: deadlines
            )
            client.connect()
        }

        /// A client that has attached and reported its first grant.
        static func attached(grant: NotificationGrant, promptAnswer: NotificationGrant? = .granted) async throws -> Harness {
            let harness = Harness(grant: grant, promptAnswer: promptAnswer)
            harness.transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
            guard await yieldUntil({ harness.transport.sent.count == 3 }) else {
                Issue.record("the client never reported its grant")
                return harness
            }
            harness.deadlines.fireAll()

            return harness
        }

        /// The response to `id`, once it has been sent.
        func answer(to id: Int) async throws -> NSDictionary {
            _ = await yieldUntil { (try? transport.sentObjects().contains { $0["id"] as? Int == id }) == true }
            return try #require(transport.sentObjects().last { $0["id"] as? Int == id })
        }

        /// Every grant reported, in order.
        func capabilities() throws -> [String] {
            try transport.sentObjects()
                .filter { $0["type"] as? String == "capabilities" }
                .compactMap { $0["notifications"] as? String }
        }
    }
}
