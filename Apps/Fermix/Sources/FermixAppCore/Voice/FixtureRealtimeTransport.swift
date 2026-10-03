#if DEBUG
import Foundation

/// Which call a fixture launch's voice socket plays.
enum FixtureRealtimeCall: Equatable {
    /// A Live call that hears a question, answers it aloud, runs the task it
    /// was asked for to completion, and rests at listening until it is ended.
    case conversation
    /// The same call, ended by the daemon at its cost ceiling: the call's last
    /// frames, the refusal, and the socket closing behind it.
    case costLimit
}

/// One frame the scripted daemon sends, and the pause before it.
struct FixtureRealtimeStep: Equatable {
    let pause: TimeInterval
    let event: RealtimeServerEvent
}

/// The realtime socket, replaced by a scripted daemon.
///
/// Only the socket is replaced. Every frame still crosses `RealtimeSocketClient`,
/// the session's handshake and the model's routing, so a call is drawn over the
/// events the contract publishes rather than over voice facts somebody filled
/// in by hand. What the daemon would decide is scripted, and no more: it
/// answers the handshake with the contract's window, plays a Live call once
/// `call_start` arrives, and answers `mute`, `interrupt`, `task_cancel` and
/// `call_stop` the way the pinned engine does.
///
/// The pauses run on the injected deadlines, so the call is paced like one in
/// the app and provable without waiting in a test. Every control frame comes
/// from the voice session, which is on the main actor; microphone audio is the
/// one frame that would not, and the silent engine captures none.
///
/// DEBUG only, by construction: a release build has no scripted daemon.
final class FixtureRealtimeTransport: LineSocketTransport, @unchecked Sendable {
    var onMessage: ((RealtimeServerEvent) -> Void)?
    var onFailure: ((RealtimeTransportFailure) -> Void)?

    private let call: FixtureRealtimeCall
    private let deadlines: any DeadlineScheduling
    private let log = AppLog.logger(.voice)
    /// The frames still to play, the next one first.
    private var remaining: [FixtureRealtimeStep] = []
    /// The pause before the next frame, called off when the call ends.
    private var pending: DeadlineToken?
    /// The tasks reported and not yet settled, at their revision.
    private var running: [String: Int] = [:]

    init(call: FixtureRealtimeCall, deadlines: any DeadlineScheduling) {
        self.call = call
        self.deadlines = deadlines
    }

    func connect(path: String, completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void) {
        completion(.success(()))
    }

    func send(_ line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String
        else {
            preconditionFailure("the fixture daemon was sent a line that is not an event")
        }

        MainActor.assumeIsolated { answer(type, event) }
    }

    /// Microphone audio, which the daemon relays to the provider and answers
    /// nothing for.
    func sendDroppable(_ line: Data) {}

    func sendDroppable(producing line: @escaping @Sendable () -> Data) {}

    /// The app hung up: the connection, and whatever the call was doing, ends.
    func close() {
        MainActor.assumeIsolated {
            stopPlaying()
            running = [:]
        }
    }

    // MARK: - The answers

    @MainActor
    private func answer(_ type: String, _ event: [String: Any]) {
        log.info("fixture realtime daemon heard \(type, privacy: .public)")

        switch type {
        case "client_hello":
            emit(.serverHello(
                minVersion: FixtureRealtimeScript.window.minimum,
                maxVersion: FixtureRealtimeScript.window.maximum
            ))
        case "call_start":
            play(FixtureRealtimeScript.steps(for: call))
        case "mute":
            // The contract's default for `enabled` is to mute.
            let enabled = event["enabled"] as? Bool ?? true
            emit(.state(enabled ? .muted : .listening))
        case "interrupt":
            interrupt()
        case "task_cancel":
            cancel(event["delegation_id"] as? String ?? "")
        case "call_stop":
            stop()
        default:
            preconditionFailure("the fixture daemon has no answer for \(type)")
        }
    }

    /// Live cannot cancel a reply, so the daemon stops it at the relay: it
    /// answers `playback_stop` and `listening`, and forwards none of the rest
    /// of the reply.
    @MainActor
    private func interrupt() {
        drop(where: Self.belongsToTheReply)
        emit(.playbackStop)
        emit(.state(.listening))
    }

    /// A task the daemon is running is cancelled, and its completion never
    /// comes. One it is not running is refused the way the pinned engine
    /// refuses it, with `unknown_delegation`, and the connection closes.
    @MainActor
    private func cancel(_ delegationId: String) {
        guard let revision = running[delegationId] else {
            refuse(RealtimeServerError(reason: "unknown_delegation"))
            return
        }

        drop { event in
            guard case .task(let task) = event else { return false }
            return task.delegationId == delegationId
        }
        emit(.task(Self.cancelled(delegationId, revision: revision)))
    }

    /// `call_stop` ends the call and keeps the connection for the next one.
    /// The pinned engine's settle says `idle`, cancels the tasks still running
    /// and sends the settled bill; the socket then writes its own `idle`, so
    /// `idle` is the call's last frame.
    @MainActor
    private func stop() {
        stopPlaying()
        emit(.state(.idle))
        for (delegationId, revision) in running.sorted(by: { $0.key < $1.key }) {
            emit(.task(Self.cancelled(delegationId, revision: revision)))
        }
        emit(.usage(FixtureRealtimeScript.settledBill))
        emit(.state(.idle))
    }

    /// The daemon's last word on a connection: the refusal, then the socket
    /// closing behind it.
    @MainActor
    private func refuse(_ refusal: RealtimeServerError) {
        stopPlaying()
        emit(.error(refusal))
        log.info("fixture realtime daemon closed the connection after \(refusal.reason, privacy: .public)")
        onFailure?(.peerClosed)
    }

    private static func cancelled(_ delegationId: String, revision: Int) -> RealtimeTask {
        RealtimeTask(delegationId: delegationId, revision: revision, status: .cancelled, summary: "cancelled")
    }

    /// The reply's own frames: its audio, its words, and the state that
    /// announces it.
    private static func belongsToTheReply(_ event: RealtimeServerEvent) -> Bool {
        switch event {
        case .audioDelta, .state(.speaking): return true
        case .caption(let caption): return caption.speaker == .assistant
        default: return false
        }
    }

    // MARK: - The script

    @MainActor
    private func play(_ steps: [FixtureRealtimeStep]) {
        stopPlaying()
        remaining = steps
        scheduleNext()
    }

    @MainActor
    private func scheduleNext() {
        guard let step = remaining.first else {
            pending = nil
            return
        }

        pending = deadlines.schedule(after: step.pause) { [weak self] in self?.playNext() }
    }

    /// A scripted error is the daemon ending the call itself, which is its
    /// last word on the connection.
    @MainActor
    private func playNext() {
        let event = remaining.removeFirst().event
        guard case .error(let refusal) = event else {
            emit(event)
            scheduleNext()
            return
        }

        refuse(refusal)
    }

    /// Drops the frames still to come that `unwanted` names, and times the
    /// next one from now.
    @MainActor
    private func drop(where unwanted: (RealtimeServerEvent) -> Bool) {
        pending?.cancel()
        remaining.removeAll { unwanted($0.event) }
        scheduleNext()
    }

    @MainActor
    private func stopPlaying() {
        pending?.cancel()
        pending = nil
        remaining = []
    }

    @MainActor
    private func emit(_ event: RealtimeServerEvent) {
        if case .task(let task) = event {
            running[task.delegationId] = task.status.isTerminal ? nil : task.revision
        }
        log.info("fixture realtime daemon sent \(Self.describe(event), privacy: .public)")
        onMessage?(event)
    }

    private static func describe(_ event: RealtimeServerEvent) -> String {
        guard case .state(let state) = event else { return event.wireType }

        return "state \(state)"
    }
}

/// What the scripted daemon says: one Live call about a lease, in the order and
/// at the pace the pinned engine sends it.
enum FixtureRealtimeScript {
    /// The window the pinned daemon advertises, which the contract publishes as
    /// its `x-supported-version-range`.
    static let window = RealtimeVersionWindow(minimum: 1, maximum: 2)
    static let callId = "voice_live:fixture"
    static let delegationId = "dg_fixture_lease"
    /// One chunk of Live's padding: 100 ms of digital silence at 24 kHz.
    static let silence = Data(count: 4_800).base64EncodedString()

    /// The bill a hang-up settles once the provider reports the call's length.
    static let settledBill = RealtimeUsage(
        status: "live",
        voiceSeconds: 24.6,
        voiceCostCents: 2.05,
        backendTurns: 1,
        backendCost: "unknown",
        accounting: "complete"
    )

    /// The frames a started call plays.
    static func steps(for call: FixtureRealtimeCall) -> [FixtureRealtimeStep] {
        switch call {
        case .conversation: return exchange + task + [step(0.3, .usage(runningBill))]
        case .costLimit: return exchange + [step(0.3, .usage(runningBill))] + costLimitEnding
        }
    }

    /// The bill while the call is up. `unknown` is the backend's cost on a
    /// subscription allowance, which is not zero.
    private static let runningBill = RealtimeUsage(
        status: "live",
        voiceSeconds: 18.4,
        voiceCostCents: 1.533,
        backendTurns: 1,
        backendCost: "unknown",
        accounting: "running"
    )

    /// What the person asks, as Live's recognition hands it over.
    private static let question: [(delta: String, startMs: Int, endMs: Int)] = [
        ("Can you ", 1_200, 1_560),
        ("find the lease ", 1_560, 2_280),
        ("and check ", 2_280, 2_700),
        ("when it renews?", 2_700, 3_400),
    ]

    /// What Fermix says back, phrase by phrase.
    private static let answer: [(delta: String, startMs: Int, endMs: Int)] = [
        ("Sure. ", 5_200, 5_600),
        ("I will find the lease ", 5_600, 6_500),
        ("and check the renewal date.", 6_500, 7_600),
    ]

    /// The provider session opening, the person asking, and the reply.
    private static var exchange: [FixtureRealtimeStep] {
        [
            step(0.8, .callReady(RealtimeCallReady(engine: "openai_live", callId: callId, captions: true))),
            step(0.2, .state(.listening)),
        ]
            + question.enumerated().map { index, words in
                step(index == 0 ? 0.9 : 0.4, .caption(RealtimeCaption(
                    speaker: .user,
                    delta: words.delta,
                    startMs: words.startMs,
                    endMs: words.endMs
                )))
            }
            + [
                step(0.7, .state(.thinking)),
                step(0.9, .state(.speaking)),
            ]
            + reply
            + [step(0.5, .state(.listening))]
    }

    /// The reply: a chunk of padding every 100 ms, with each phrase's words
    /// arriving just after its first chunk.
    private static var reply: [FixtureRealtimeStep] {
        let chunk = step(0.1, .audioDelta(base64: silence))

        return answer.flatMap { words in
            [
                chunk,
                step(0.05, .caption(RealtimeCaption(
                    speaker: .assistant,
                    delta: words.delta,
                    startMs: words.startMs,
                    endMs: words.endMs
                ))),
            ] + Array(repeating: chunk, count: 6)
        }
    }

    /// The work the person asked for, handed to the backend and finished.
    private static var task: [FixtureRealtimeStep] {
        [
            step(0.8, .task(RealtimeTask(
                delegationId: delegationId,
                revision: 1,
                status: .running,
                summary: "finding the lease in Documents"
            ))),
            step(3.0, .task(RealtimeTask(
                delegationId: delegationId,
                revision: 1,
                status: .completed,
                summary: "The lease renews on 1 March. Notice is due by 1 January."
            ))),
        ]
    }

    /// The daemon ending the call at its ceiling, as the pinned engine's settle
    /// does: `idle`, the bill that says why, then the refusal with its kind.
    /// That engine sends no `detail` for this kind; the fixture carries one so
    /// the failed state is also looked at with a vendor's sentence after it.
    private static var costLimitEnding: [FixtureRealtimeStep] {
        [
            step(1.5, .state(.idle)),
            step(0.1, .usage(RealtimeUsage(
                status: "limit_reached",
                voiceSeconds: 19.2,
                voiceCostCents: 1.6,
                backendTurns: 0,
                backendCost: "unknown",
                accounting: "running"
            ))),
            step(0.1, .error(RealtimeServerError(
                reason: "cost_limit",
                kind: .costLimit,
                detail: "The voice session reached its spending limit."
            ))),
        ]
    }

    private static func step(_ pause: TimeInterval, _ event: RealtimeServerEvent) -> FixtureRealtimeStep {
        FixtureRealtimeStep(pause: pause, event: event)
    }
}

/// The microphone and the speaker, silent.
///
/// It asks macOS for nothing: the microphone is reported granted without a
/// prompt, capture warms and streams nothing, and playback plays nothing. What
/// it does report is a gentle level while a reply's chunks arrive, settling
/// back to rest once they stop, so the mascot moves in a capture as it does
/// over a real call.
///
/// Nothing is ever queued for the speaker, so there is no voice to wait for and
/// no drain to report: the scripted reply is padding, which the product engine
/// does not count either.
final class FixtureAudioEngine: VoiceAudioEngine {
    /// The wire's audio: 24 kHz mono PCM16.
    static let bytesPerSecond: Double = 48_000
    /// How many times the level is reported at rest after a reply, a tenth of a
    /// second apart: enough for the audio owner's smoothing to reach rest, the
    /// way Live's padding takes a real engine's level there.
    static let restingReports = 10
    static let restingInterval: TimeInterval = 0.1

    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var isPlayingBack: Bool { false }

    private let deadlines: any DeadlineScheduling
    private let log = AppLog.logger(.voice)
    private var chunksPlayed = 0
    /// The next report at rest, called off by more of the reply.
    private var settling: DeadlineToken?

    init(deadlines: any DeadlineScheduling) {
        self.deadlines = deadlines
    }

    /// Granted, and macOS is never asked.
    func requestCapturePermission() async throws {}

    func prepareCapture() throws {}

    /// The daemon is listening. Nothing is captured, so the handler is never
    /// called.
    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {
        log.info("fixture audio engine is streaming, silently")
    }

    func setCaptureMuted(_ muted: Bool) {}

    func play(base64PCM16 encoded: String) {
        guard let chunk = Data(base64Encoded: encoded), !chunk.isEmpty else {
            log.error("fixture playback skipped: the daemon sent an empty or undecodable audio chunk")
            return
        }

        MainActor.assumeIsolated { heard(chunk) }
    }

    func stopPlayback() {
        MainActor.assumeIsolated { settle(after: Self.restingInterval, reports: Self.restingReports) }
    }

    func resetUtteranceAnchor() {}

    func currentUtterancePlayedMs() -> Int? { nil }

    func shutdown() {
        MainActor.assumeIsolated {
            settling?.cancel()
            settling = nil
        }
    }

    func diagnostics() -> String {
        "fixture audio engine: silent, nothing captured or played"
    }

    /// The level a voice in the range Live's measured voice reports, swelling
    /// from chunk to chunk.
    static func level(at chunk: Int) -> Float {
        let rms = 1_800 + 1_200 * sin(Double(chunk) * 0.9)
        return Float(rms) / Float(Int16.max)
    }

    @MainActor
    private func heard(_ chunk: Data) {
        chunksPlayed += 1
        onOutputLevel?(Self.level(at: chunksPlayed))
        settle(after: Double(chunk.count) / Self.bytesPerSecond, reports: Self.restingReports)
    }

    /// Reports rest once the chunk would have finished playing, then again
    /// each interval until `reports` have been made.
    @MainActor
    private func settle(after delay: TimeInterval, reports: Int) {
        settling?.cancel()
        settling = deadlines.schedule(after: delay) { [weak self] in
            guard let self else { return }

            self.onOutputLevel?(0)
            guard reports > 1 else {
                self.settling = nil
                return
            }
            self.settle(after: Self.restingInterval, reports: reports - 1)
        }
    }
}
#endif
