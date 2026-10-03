#if DEBUG
import Foundation
import Testing

@testable import FermixAppCore

/// The scripted realtime daemon and the silent audio engine a fixture launch's
/// voice stands on: what the daemon says and in what order, how it answers the
/// app's controls, and that nothing under it reaches the Mac's audio.
@MainActor
@Suite("Fixture realtime daemon")
struct FixtureRealtimeTransportTests {

    // MARK: - The handshake

    @Test("the daemon answers the handshake at once, and says nothing else until a call starts")
    func handshakeFirst() throws {
        let daemon = ScriptedDaemon(.conversation)

        try daemon.send(.clientHello(protocolVersion: RealtimeProtocol.version))

        #expect(daemon.heard == [.serverHello(minVersion: 1, maxVersion: 2)])
        #expect(daemon.deadlines.liveCount == 0)
    }

    @Test("the window it advertises is the one the vendored contract publishes")
    func windowIsTheContracts() throws {
        let schema = try VendoredContracts.data(.realtime, "protocol.schema.json")
        let object = try JSONSerialization.jsonObject(with: schema) as? [String: Any]
        let range = object?["x-supported-version-range"] as? [String: Any]

        #expect(range?["min"] as? Int == FixtureRealtimeScript.window.minimum)
        #expect(range?["max"] as? Int == FixtureRealtimeScript.window.maximum)
        #expect(FixtureRealtimeScript.window.contains(RealtimeProtocol.version))
    }

    // MARK: - The conversation

    /// The Live sequence the contract publishes: ready, listening, the
    /// person's words, thinking, the reply, listening again, then the task and
    /// the running bill.
    @Test("a started call plays the conversation in the contract's order, each frame after a pause")
    func conversationPlaysInOrder() throws {
        let daemon = try ScriptedDaemon(.conversation).started()

        #expect(daemon.heard.isEmpty, "the first frame waits for its pause")
        let pauses = daemon.playAll()
        let labels = daemon.heard.map(Self.label)

        #expect(pauses.count == labels.count)
        #expect(pauses.allSatisfy { $0 > 0 })
        #expect(pauses.reduce(0, +) > 5, "the call is paced like a call")
        #expect(Array(labels.prefix(2)) == ["call_ready", "state listening"])

        let thinking = try #require(labels.firstIndex(of: "state thinking"))
        let speaking = try #require(labels.firstIndex(of: "state speaking"))
        let listeningAgain = try #require(labels.lastIndex(of: "state listening"))
        #expect(Set(labels[2..<thinking]) == ["caption user"])
        #expect(speaking == thinking + 1)
        #expect(Set(labels[(speaking + 1)..<listeningAgain]) == ["audio", "caption assistant"])
        #expect(Array(labels[listeningAgain...]) == ["state listening", "task running", "task completed", "usage running"])
    }

    @Test("the call is Live's: its engine, its id, and captions promised")
    func callReadyIsLive() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.playAll()

        #expect(daemon.heard.first == .callReady(
            RealtimeCallReady(
                engine: "openai_live",
                callId: FixtureRealtimeScript.callId,
                captions: true
            )
        ))
    }

    /// Fragments are joined byte for byte, as the contract says, so each
    /// speaker's deltas read as one sentence with its own spacing.
    @Test("the captions are verbatim fragments that join into what each side said")
    func captionsJoin() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.playAll()

        let captions = daemon.heard.compactMap { event -> RealtimeCaption? in
            guard case .caption(let caption) = event else { return nil }
            return caption
        }
        let user = captions.filter { $0.speaker == .user }
        let assistant = captions.filter { $0.speaker == .assistant }

        #expect(user.map(\.delta).joined() == "Can you find the lease and check when it renews?")
        #expect(assistant.map(\.delta).joined() == "Sure. I will find the lease and check the renewal date.")
        for side in [user, assistant] {
            #expect(side.allSatisfy { $0.startMs < $0.endMs })
            #expect(zip(side, side.dropFirst()).allSatisfy { $0.endMs <= $1.startMs })
        }
    }

    /// Live pads its output with digital silence, which plays but is not
    /// voice, so the reply never leaves anything queued to wait for.
    @Test("the reply's audio is silence")
    func replyIsSilence() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.playAll()

        let audio = daemon.heard.compactMap { event -> String? in
            guard case .audioDelta(let base64) = event else { return nil }
            return base64
        }

        #expect(audio.count >= 3)
        #expect(audio.allSatisfy { !PCM16.isVoiced(base64: $0) })
        #expect(audio.allSatisfy { Data(base64Encoded: $0)?.isEmpty == false })
    }

    @Test("the task runs, then completes with the daemon's summary, and the bill carries the Live fields")
    func taskAndBill() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.playAll()

        let tasks = daemon.heard.compactMap { event -> RealtimeTask? in
            guard case .task(let task) = event else { return nil }
            return task
        }
        #expect(tasks.map(\.status) == [.running, .completed])
        #expect(Set(tasks.map(\.delegationId)) == [FixtureRealtimeScript.delegationId])
        #expect(tasks.allSatisfy { $0.revision == 1 && $0.summary?.isEmpty == false })
        #expect(tasks.allSatisfy { ($0.summary?.count ?? 0) <= 240 })

        guard case .usage(let bill) = daemon.heard.last else {
            Issue.record("the conversation does not end on its bill")
            return
        }
        #expect(bill.status == "live")
        #expect(bill.accounting == "running")
        #expect(bill.backendCost == "unknown")
        #expect(bill.voiceSeconds != nil && bill.voiceCostCents != nil && bill.backendTurns != nil)
    }

    // MARK: - The app's controls

    /// The pinned engine settles the call, cancelling nothing because nothing
    /// is running, and the socket then writes its own `idle`, so `idle` is the
    /// call's last frame. The connection stays for the next call.
    @Test("ending the call settles the bill between two idles and keeps the connection")
    func callStopSettles() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.playAll()
        daemon.heard.removeAll()

        try daemon.send(.callStop)

        #expect(daemon.heard.map(Self.label) == ["state idle", "usage complete", "state idle"])
        #expect(daemon.failures.isEmpty)

        daemon.heard.removeAll()
        try daemon.send(.callStart)
        daemon.playAll()
        #expect(daemon.heard.first.map(Self.label) == "call_ready", "a second call plays again")
    }

    @Test("ending the call mid-script stops the script and cancels the running task")
    func callStopMidScript() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.play(until: "task running")
        daemon.heard.removeAll()

        try daemon.send(.callStop)
        daemon.playAll()

        #expect(daemon.heard.map(Self.label) == ["state idle", "task cancelled", "usage complete", "state idle"])
        #expect(daemon.deadlines.liveCount == 0)
    }

    @Test("mute and unmute answer with the state the daemon is in")
    func muteAnswers() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.play(until: "state listening")
        daemon.heard.removeAll()

        try daemon.send(.mute(enabled: true))
        try daemon.send(.mute(enabled: false))

        #expect(daemon.heard == [.state(.muted), .state(.listening)])
    }

    /// Live cannot cancel a reply, so the daemon stops it at the relay and
    /// forwards none of the rest of it; the call carries on from there.
    @Test("an interrupt stops the reply at the relay and the call carries on")
    func interruptStopsTheReply() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.play(until: "audio")
        daemon.heard.removeAll()

        try daemon.send(.interrupt(audioEndMs: nil))
        #expect(daemon.heard == [.playbackStop, .state(.listening)])

        daemon.playAll()
        let rest = daemon.heard.dropFirst(2).map(Self.label)
        #expect(!rest.contains("audio"))
        #expect(!rest.contains("caption assistant"))
        #expect(rest.suffix(3) == ["task running", "task completed", "usage running"])
    }

    @Test("cancelling the running task answers cancelled, and its completion never comes")
    func cancelRunningTask() throws {
        let daemon = try ScriptedDaemon(.conversation).started()
        daemon.play(until: "task running")
        daemon.heard.removeAll()

        try daemon.send(.taskCancel(delegationId: FixtureRealtimeScript.delegationId))
        #expect(daemon.heard == [.task(RealtimeTask(
            delegationId: FixtureRealtimeScript.delegationId,
            revision: 1,
            status: .cancelled,
            summary: "cancelled"
        ))])

        daemon.playAll()
        #expect(!daemon.heard.map(Self.label).contains("task completed"))
        #expect(daemon.failures.isEmpty)
    }

    /// The pinned engine refuses a cancel of a delegation it does not hold
    /// with `unknown_delegation` and closes the connection.
    @Test("cancelling a task the daemon is not running is refused, and the socket closes")
    func cancelUnknownTask() throws {
        let daemon = try ScriptedDaemon(.conversation).started()

        try daemon.send(.taskCancel(delegationId: "dg_nothing"))

        #expect(daemon.heard == [.error(RealtimeServerError(reason: "unknown_delegation"))])
        #expect(daemon.failures == [.peerClosed])
        #expect(daemon.deadlines.liveCount == 0)
    }

    @Test("closing the connection stops the script")
    func closeStops() throws {
        let daemon = try ScriptedDaemon(.conversation).started()

        daemon.transport.close()

        #expect(daemon.deadlines.liveCount == 0)
        #expect(daemon.heard.isEmpty)
    }

    // MARK: - The failed call

    /// A call the daemon ends itself sends `idle` and the bill that says why,
    /// then the refusal carrying its kind, and the socket closes behind it.
    @Test("the cost-limit call ends in the refusal and the socket closing")
    func costLimitEnds() throws {
        let daemon = try ScriptedDaemon(.costLimit).started()
        daemon.playAll()

        let labels = daemon.heard.map(Self.label)
        #expect(Array(labels.prefix(2)) == ["call_ready", "state listening"])
        #expect(Array(labels.suffix(3)) == ["state idle", "usage limit_reached", "error cost_limit"])
        #expect(daemon.failures == [.peerClosed])
        #expect(daemon.deadlines.liveCount == 0)

        guard case .error(let refusal) = daemon.heard.last else {
            Issue.record("the failed call does not end on its refusal")
            return
        }
        #expect(refusal.reason == "cost_limit")
        #expect(refusal.kind == .costLimit)
        #expect(refusal.detail?.isEmpty == false)
    }

    // MARK: - The silent engine

    /// The microphone is granted without a prompt and nothing is captured: the
    /// handler a call hands it is never called.
    @Test("the silent engine grants the microphone without asking and captures nothing")
    func silentEngineCapturesNothing() async throws {
        let deadlines = ManualDeadlineScheduler()
        let engine = FixtureAudioEngine(deadlines: deadlines)
        let chunks = ChunkCounter()

        try await engine.requestCapturePermission()
        try engine.prepareCapture()
        try engine.beginStreaming(onChunk: { _ in chunks.count() })
        engine.setCaptureMuted(false)
        engine.play(base64PCM16: FixtureRealtimeScript.silence)
        Self.drain(deadlines)

        #expect(chunks.total == 0)
        #expect(!engine.isPlayingBack)
        #expect(engine.currentUtterancePlayedMs() == nil)
    }

    /// The mascot moves with the level while a reply arrives and comes back to
    /// rest after it, the way Live's padding takes a real engine's level there.
    @Test("the silent engine reports a gentle level while a reply plays, then rest")
    func silentEngineLevel() {
        let deadlines = ManualDeadlineScheduler()
        let engine = FixtureAudioEngine(deadlines: deadlines)
        var levels: [Float] = []
        engine.onOutputLevel = { levels.append($0) }

        for _ in 0..<3 {
            engine.play(base64PCM16: FixtureRealtimeScript.silence)
        }
        let playing = levels
        Self.drain(deadlines)
        let resting = levels.dropFirst(playing.count)

        #expect(playing.count == 3)
        #expect(playing.allSatisfy { $0 > 0.005 && $0 < 0.15 }, "a voice's level, never a shout: \(playing)")
        #expect(Set(playing).count > 1, "the level moves")
        #expect(resting.count == FixtureAudioEngine.restingReports)
        #expect(resting.allSatisfy { $0 == 0 })
    }

    @Test("shutting the silent engine down ends its level reports")
    func silentEngineShutdown() {
        let deadlines = ManualDeadlineScheduler()
        let engine = FixtureAudioEngine(deadlines: deadlines)

        engine.play(base64PCM16: FixtureRealtimeScript.silence)
        engine.shutdown()

        #expect(deadlines.liveCount == 0)
    }

    /// The claim that a fixture run never touches the microphone holds by
    /// construction: the voice's audio source compiles without the frameworks
    /// that could ask macOS for it.
    @Test("the fixture voice source reaches none of the system's audio")
    func fixtureVoiceSourceIsSilent() throws {
        let sources = try SourceTree.swiftFiles(matching: "Voice/FixtureRealtimeTransport.swift")
        #expect(sources.count == 1)

        for forbidden in ["AVFoundation", "AVFAudio", "AVCaptureDevice", "AVAudio", "CoreAudio", "AudioToolbox"] {
            #expect(!sources[0].text.contains(forbidden), "the fixture voice names \(forbidden)")
        }
    }

    // MARK: - The whole voice stack

    /// The voice stack exactly as the composition builds it, over the two
    /// fixture seams: the click drives the handshake, the silent engine grants
    /// the microphone, `call_start` goes out, and the call settles at
    /// listening with the script's facts.
    @Test("a fixture call over the real session, routing and audio owner reaches listening")
    func callReachesListening() async throws {
        let model = VoiceCallModel()
        let deadlines = ManualDeadlineScheduler()
        let lines = FixtureRealtimeTransport(call: .conversation, deadlines: deadlines)
        let voice = VoiceCoordinator(
            model: model,
            session: VoiceSession(
                transport: RealtimeSocketClient(lines: lines),
                socketPath: { "/fixture/realtime.sock" },
                deadlines: ManualDeadlineScheduler()
            ),
            audio: AudioOwner(engine: FixtureAudioEngine(deadlines: deadlines), deadlines: ManualDeadlineScheduler()),
            deadlines: ManualDeadlineScheduler()
        )

        voice.toggleCall()
        for _ in 0..<8 {
            await Task.yield()
        }
        Self.drain(deadlines)

        #expect(model.voice.phase == .active)
        #expect(model.voice.callActive)
        #expect(model.voice.status == .listening)
        #expect(model.voice.engine == "openai_live")
        #expect(model.voice.task?.status == .completed)
        #expect(model.voice.usage?.accounting == "running")
        #expect(model.voice.captions != VoiceState().captions)
    }

    // MARK: - Helpers

    /// A compact name for a frame, for reading an order at a glance.
    static func label(_ event: RealtimeServerEvent) -> String {
        switch event {
        case .serverHello: return "server_hello"
        case .callReady: return "call_ready"
        case .state(let state): return "state \(Self.word(state))"
        case .caption(let caption): return "caption \(caption.speaker == .user ? "user" : "assistant")"
        case .audioDelta: return "audio"
        case .task(let task): return "task \(Self.word(task.status))"
        case .usage(let usage): return "usage \(usage.status == "live" ? usage.accounting ?? "" : usage.status ?? "")"
        case .error(let error): return "error \(error.reason)"
        case .playbackStop: return "playback_stop"
        default: return event.wireType
        }
    }

    private static func word(_ state: RealtimeTurnState) -> String {
        switch state {
        case .idle: return "idle"
        case .listening: return "listening"
        case .speaking: return "speaking"
        case .muted: return "muted"
        case .thinking: return "thinking"
        case .reconnecting: return "reconnecting"
        case .unrecognized(let word): return word
        }
    }

    private static func word(_ status: RealtimeTaskStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .unrecognized(let word): return word
        }
    }

    /// Fires deadlines until none is left, the way the main queue would.
    static func drain(_ deadlines: ManualDeadlineScheduler) {
        while deadlines.liveCount > 0 {
            deadlines.fireAll()
        }
    }
}

/// The scripted daemon with no main-actor hop in front of it, so every answer
/// lands before the frame that asked for it returns, and its pauses on a
/// scheduler the case drives.
@MainActor
final class ScriptedDaemon {
    let deadlines = ManualDeadlineScheduler()
    let transport: FixtureRealtimeTransport
    var heard: [RealtimeServerEvent] = []
    private(set) var failures: [RealtimeTransportFailure] = []

    init(_ call: FixtureRealtimeCall) {
        transport = FixtureRealtimeTransport(call: call, deadlines: deadlines)
        transport.onMessage = { [unowned self] event in self.heard.append(event) }
        transport.onFailure = { [unowned self] failure in self.failures.append(failure) }
    }

    func send(_ event: RealtimeClientEvent) throws {
        transport.send(try event.line())
    }

    /// Handshaken and asked for a call, with the hello already read.
    func started() throws -> ScriptedDaemon {
        try send(.clientHello(protocolVersion: RealtimeProtocol.version))
        try send(.callStart)
        heard.removeAll()
        return self
    }

    /// Plays the script to its end and answers each pause it waited.
    @discardableResult
    func playAll() -> [TimeInterval] {
        var pauses: [TimeInterval] = []
        while deadlines.liveCount > 0 {
            pauses += deadlines.scheduledDelays
            deadlines.fireAll()
        }
        return pauses
    }

    /// Plays frames one at a time until one carries `label`.
    func play(until label: String) {
        while deadlines.liveCount > 0, !heard.map(FixtureRealtimeTransportTests.label).contains(label) {
            deadlines.fireAll()
        }
    }
}

/// Counts capture chunks from whichever thread delivers them.
final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = 0

    var total: Int { lock.withLock { chunks } }

    func count() {
        lock.withLock { chunks += 1 }
    }
}
#endif
