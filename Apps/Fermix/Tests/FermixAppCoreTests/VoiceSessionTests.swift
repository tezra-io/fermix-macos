import Foundation
import Testing

@testable import FermixAppCore

/// The handshake: this build's protocol constant, `client_hello`, the daemon's
/// `server_hello`, the version window, and the three-second deadline.
@Suite("Voice session handshake")
@MainActor
struct VoiceSessionTests {
    private func makeSession(
        transport: FakeRealtimeTransport,
        scheduler: ManualDeadlineScheduler
    ) -> VoiceSession {
        VoiceSession(transport: transport, socketPath: "/tmp/fermix-test/realtime.sock", deadlines: scheduler)
    }

    @Test("connecting sends exactly one client hello and stays unnegotiated")
    func sendsClientHello() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)

        session.connect()

        #expect(transport.connectedPaths == ["/tmp/fermix-test/realtime.sock"])
        #expect(transport.sent == [.clientHello(protocolVersion: RealtimeProtocol.version)])
        #expect(session.phase == .handshaking)
        #expect(scheduler.scheduledDelays == [RealtimeProtocol.handshakeTimeout])
    }

    @Test("a server hello inside the window negotiates and cancels the deadline")
    func negotiatesInsideTheWindow() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var negotiated: RealtimeVersionWindow?
        session.onNegotiated = { negotiated = $0 }

        session.connect()
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))

        #expect(session.phase == .negotiated)
        #expect(negotiated == RealtimeVersionWindow(minimum: 1, maximum: 1))
        #expect(scheduler.liveCount == 0)
    }

    /// A daemon whose window excludes this build must never receive a call: the
    /// session refuses and closes rather than sending `call_start` anyway.
    @Test("a window that excludes this build refuses the session and closes")
    func refusesAnExcludingWindow() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()
        transport.deliver(.serverHello(minVersion: 2, maxVersion: 3))

        #expect(
            failure == .versionUnsupported(direction: .clientTooOld, minimum: 2, maximum: 3)
        )
        #expect(session.phase == .disconnected)
        #expect(transport.closeCount == 1)
    }

    @Test("a daemon older than this build is reported as the daemon being too old")
    func reportsADaemonThatIsTooOld() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()
        transport.deliver(.serverHello(minVersion: 0, maxVersion: 0))

        #expect(failure == .versionUnsupported(direction: .clientTooNew, minimum: 0, maximum: 0))
    }

    @Test("a refusal during the handshake carries the daemon's own reason")
    func carriesTheDaemonReason() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()
        transport.deliver(
            .error(
                RealtimeServerError(
                    reason: "unsupported_protocol_version",
                    direction: .clientTooOld,
                    minVersion: 2,
                    maxVersion: 2
                )
            )
        )

        #expect(failure == .versionUnsupported(direction: .clientTooOld, minimum: 2, maximum: 2))
        #expect(transport.closeCount == 1)
    }

    @Test("a refusal without a version direction is reported verbatim")
    func reportsAPlainRefusal() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()
        transport.deliver(.error(RealtimeServerError(reason: "voice_disabled")))

        #expect(failure == .refused(reason: "voice_disabled"))
    }

    /// A daemon that predates the handshake answers `state` and never
    /// `server_hello`. Nothing is assumed: the deadline is what ends it.
    @Test("a daemon that never says hello times out after three seconds")
    func timesOutWithoutAServerHello() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()
        transport.deliver(.state(.listening))
        #expect(session.phase == .handshaking)

        scheduler.fireAll()

        #expect(failure == .handshakeTimedOut)
        #expect(transport.closeCount == 1)
    }

    @Test("events before negotiation are never routed to the application")
    func withholdsEventsUntilNegotiated() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var routed: [RealtimeServerEvent] = []
        session.onEvent = { routed.append($0) }

        session.connect()
        transport.deliver(.state(.listening))
        transport.deliver(.audioDelta(base64: "AAAA"))
        #expect(routed.isEmpty)

        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        transport.deliver(.state(.listening))

        #expect(routed == [.state(.listening)])
    }

    /// A second `server_hello` is not a re-negotiation: the transition happens
    /// once, and a later one is ignored rather than resetting the session.
    @Test("a server hello after negotiation is ignored")
    func ignoresASecondServerHello() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var negotiations = 0
        session.onNegotiated = { _ in negotiations += 1 }

        session.connect()
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))

        #expect(negotiations == 1)
        #expect(session.phase == .negotiated)
    }

    @Test("a connect failure is reported and leaves nothing half open")
    func reportsConnectFailure() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        transport.connectResult = .failure(RealtimeConnectFailure(errorNumber: ECONNREFUSED))
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()

        #expect(failure == .connectFailed(RealtimeConnectFailure(errorNumber: ECONNREFUSED)))
        #expect(session.phase == .disconnected)
        #expect(transport.sent.isEmpty)
        #expect(scheduler.liveCount == 0)
    }

    /// Connecting is asynchronous, so the deadline must not start before the
    /// socket is up: a slow connect cannot consume the handshake window.
    @Test("the handshake deadline starts only once the socket is connected")
    func deadlineStartsAfterConnect() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        transport.deferConnectCompletion = true
        let session = makeSession(transport: transport, scheduler: scheduler)

        session.connect()
        #expect(session.phase == .connecting)
        #expect(scheduler.liveCount == 0)
        #expect(transport.sent.isEmpty)

        transport.completeConnect(.success(()))

        #expect(session.phase == .handshaking)
        #expect(scheduler.scheduledDelays == [RealtimeProtocol.handshakeTimeout])
    }

    @Test("a transport failure ends the session")
    func transportFailureEndsTheSession() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)
        var failure: VoiceSessionFailure?
        session.onFailed = { failure = $0 }

        session.connect()
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
        transport.fail(.peerClosed)

        #expect(failure == .transport(.peerClosed))
        #expect(session.phase == .disconnected)
    }

    @Test("closing an unnegotiated session cancels the deadline")
    func closeCancelsTheDeadline() {
        let transport = FakeRealtimeTransport()
        let scheduler = ManualDeadlineScheduler()
        let session = makeSession(transport: transport, scheduler: scheduler)

        session.connect()
        session.close()

        #expect(scheduler.liveCount == 0)
        #expect(session.phase == .disconnected)
        #expect(transport.closeCount == 1)
    }
}
