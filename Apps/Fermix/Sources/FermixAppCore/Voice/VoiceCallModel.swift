import Combine
import Foundation

/// What routing a server event asks the voice coordinator to do.
///
/// Routing decides; the coordinator performs. That split is what makes every
/// route provable without an audio engine or a socket.
public enum VoiceEffect: Equatable, Sendable {
    /// The daemon is listening: attach the chunk handler and unmute.
    case startCapture
    case setCaptureMuted(Bool)
    case play(base64: String)
    case stopPlayback
    case resetUtteranceAnchor
    /// Tear the microphone all the way down.
    case endAudio
    /// The ending call's last frame arrived: its stop has nothing left to wait
    /// for, and a start asked for meanwhile may go.
    case callEnded
}

/// What the daemon said, as the model holds it.
///
/// The wire shapes are the model's shapes: a task is the frame that arrived,
/// and a parallel struct beside it would only be somewhere for the two to
/// drift apart.
public typealias VoiceTask = RealtimeTask
public typealias VoiceUsage = RealtimeUsage

/// What the call has said, one running text per speaker (M56 §4.2).
///
/// Each text is that speaker's `delta` bytes joined exactly as they arrived:
/// the contract says to concatenate them, never trimming or inserting spaces,
/// and the two speakers may overlap in time. Captions carry no turn boundary
/// and the app implies none, so a text only grows, and `latest` says which
/// grew last. A call can run for minutes, so each keeps its last `byteLimit`
/// bytes.
public struct VoiceCaptions: Equatable, Sendable {
    public enum Speaker: Equatable, Sendable {
        case user
        case assistant
    }

    public static let byteLimit = 1_000

    private var user = ""
    private var assistant = ""
    /// The speaker whose text grew last, or nil before either has spoken.
    public private(set) var latest: Speaker?

    public init() {}

    public func text(of speaker: Speaker) -> String {
        switch speaker {
        case .user: return user
        case .assistant: return assistant
        }
    }

    mutating func append(_ delta: String, from speaker: Speaker) {
        switch speaker {
        case .user: user = Self.tail(of: user + delta)
        case .assistant: assistant = Self.tail(of: assistant + delta)
        }
        latest = speaker
    }

    /// The text's last `byteLimit` bytes, cut where a character begins: the
    /// bound is in bytes, and half a character is not text.
    private static func tail(of text: String) -> String {
        let excess = text.utf8.count - byteLimit
        guard excess > 0 else { return text }

        var cut = text.utf8.index(text.utf8.startIndex, offsetBy: excess)
        while cut < text.endIndex, cut.samePosition(in: text) == nil {
            cut = text.utf8.index(after: cut)
        }

        return String(text[cut...])
    }
}

/// The backend delegations of a call (M56 §4.2).
///
/// Keyed by `delegation_id` and fenced by `revision`: a frame with a lower
/// revision than the one held is a late answer to an earlier ask, and is
/// refused. A finished task stays, for the task line, until newer ones
/// displace it; at most `limit` are held, the oldest finished one first out.
/// Each id's highest revision outlives its eviction for the rest of the call,
/// so a late frame of an evicted task is still refused rather than read as new
/// work.
public struct VoiceTasks: Equatable, Sendable {
    public static let limit = 8

    /// The tasks held, in the order they started.
    public private(set) var held: [VoiceTask] = []
    /// Every delegation's highest revision this call, held or evicted.
    private var revisions: [String: Int] = [:]

    public init() {}

    public subscript(delegationId: String) -> VoiceTask? {
        held.first { $0.delegationId == delegationId }
    }

    /// The newest task that has not finished. A status this build cannot read
    /// is not finished: nothing may claim work whose word is unknown is over.
    public var newestRunning: VoiceTask? {
        held.last { !$0.status.isTerminal }
    }

    /// The task the call's task line draws: the newest one still running, or,
    /// while none is, the last to start, kept until the next one starts.
    public var current: VoiceTask? {
        newestRunning ?? held.last
    }

    /// Takes a frame, or refuses it as late. Answers whether it was taken.
    mutating func apply(_ task: VoiceTask) -> Bool {
        let id = task.delegationId

        if let index = held.firstIndex(where: { $0.delegationId == id }) {
            guard task.revision >= held[index].revision else { return false }

            held[index] = task
        } else {
            // Evicted, then heard from again: only a re-ask is new work.
            if let remembered = revisions[id], task.revision <= remembered { return false }

            if held.count == Self.limit {
                held.remove(at: held.firstIndex { $0.status.isTerminal } ?? held.startIndex)
            }
            held.append(task)
        }

        revisions[id] = task.revision
        return true
    }
}

/// How a call ended.
public enum VoiceCallOutcome: Equatable, Sendable {
    /// Hung up, by either side, with the bill the daemon settled, where it
    /// sent one before the call's last frame.
    case normal(settled: VoiceUsage?)
    /// Refused or broken: the daemon's typed failure, where it named one, and
    /// the sentence the surfaces show for it.
    case failed(kind: RealtimeErrorKind?, sentence: String)
}

/// Where the one call is in its life (M56 §4.1).
///
/// Every frame the daemon sends about a call is read against this: a frame in
/// `stopping` belongs to the call that is ending, and one in `idle` or
/// `ended` belongs to no call and is dropped. Nothing else says whether a call
/// is up.
public enum VoiceCallPhase: Equatable, Sendable {
    /// No call, and none ended since launch.
    case idle
    /// A start, waiting for the handshake or the microphone; `call_start` has
    /// not been sent.
    case starting
    /// `call_start` has been sent: the call is the daemon's.
    case active
    /// `call_stop` has been sent, and the call's last frame has not arrived.
    case stopping
    /// The last call is over. Its facts stay for the surfaces until the next
    /// start.
    case ended(VoiceCallOutcome)

    /// Whether the call control ends something here, a start the daemon has
    /// not answered or a call, rather than beginning one. While a call is
    /// stopping the control begins the next one, which waits for it to end.
    public var callControlEnds: Bool {
        self == .starting || self == .active
    }
}

/// The voice facts, separate from how they draw.
public struct VoiceState: Equatable, Sendable {
    public var phase: VoiceCallPhase = .idle
    /// Which start this is. Minted by every start, so work begun for one start
    /// (the handshake, the permission prompt) can tell it is no longer the
    /// current one.
    public var attempt = 0
    public var mode: VoiceMode = .offline
    public var connected = false
    public var muted = false
    /// True while voice audio is still leaving the speaker, which outlasts the
    /// daemon's speaking state by the length of the buffered tail.
    public var audioActive = false
    public var status: VoiceStatus = .offline
    /// Which engine answered and which call this is, from `call_ready`. Both
    /// are the daemon's own words, and neither changes what the pet draws.
    public var engine: String?
    public var callId: String?
    /// What this call has said, a bounded running text per speaker.
    public var captions = VoiceCaptions()
    /// The call's backend delegations, by id.
    public var tasks = VoiceTasks()
    /// The usage frame the daemon last reported.
    public var usage: VoiceUsage?

    /// Whether a stopping call has heard everything the daemon will say about
    /// it, so its next `state idle` is its last frame.
    ///
    /// The Live engine says idle as it begins to settle, then sends each
    /// running task's cancellation and the settled bill (`accounting`
    /// `complete` or `incomplete`), then idle again (`live_session_server.ex`
    /// `settle/2`, `local_voice_socket.ex` `call_stop`). The Realtime engine
    /// sends no `call_ready` and no accounting: its first idle is the end.
    var settled: Bool {
        if let usage, usage.accounting == "complete" || usage.accounting == "incomplete" {
            return true
        }

        return engine == nil && usage?.accounting == nil
    }

    /// Whether the daemon has a call: from `call_start` until the call's last
    /// frame. Derived, so it cannot disagree with the phase.
    public var callActive: Bool {
        phase == .active || phase == .stopping
    }

    public var presentation: VoicePresentation {
        VoicePresentation(mode: mode, callActive: callActive, audioActive: audioActive)
    }

    /// The sentence a surface shows for this state.
    ///
    /// The presentation's label is the default, because it follows the visual
    /// mode and so keeps saying "Speaking" through the audio tail the daemon
    /// has already moved past. There are two exceptions. A failure's own words
    /// are the only ones that name what went wrong, and rebuilding them from
    /// `.error` yields "Not connected". And a start says "Connecting" from the
    /// click until the daemon says what the turn is doing (M56 §4.2), while
    /// its mode rests at idle, whose label is "Ready".
    public var statusText: String {
        status.carriesItsOwnSentence || status == .connecting ? status.text : presentation.accessibilityLabel
    }

    /// What the call that ended cost, in cents, where the daemon settled a
    /// bill before its last frame. Nothing while a call is up: the figure so
    /// far is not the bill.
    public var settledCostCents: Double? {
        guard case .ended = phase else { return nil }

        return usage?.voiceCostCents
    }

    /// What the surfaces say with no call up: ready on a negotiated socket,
    /// not connected otherwise.
    mutating func restOutsideACall() {
        mode = connected ? .idle : .offline
        status = VoiceStatus(mode: mode)
    }

    /// What the microphone is doing while a call is live.
    var activeInputMode: VoiceMode { muted ? .muted : .listening }

    /// Where a live call rests when nothing is being said: backend work that
    /// is still running, which the pet shows as thinking until it ends, or
    /// else the microphone. A reply spoken over the work, or the daemon saying
    /// listening once it has played, does not end the work (RCA of
    /// 2026-09-25: "Retain task activity independently").
    var restingMode: VoiceMode {
        tasks.newestRunning == nil ? activeInputMode : .toolUse
    }
}

/// The one app-scoped owner of the call's facts, and the routing that drives
/// them.
///
/// It owns no socket, no audio engine and no window: it holds what the
/// surfaces draw of a call and answers a server event with the effects that
/// event calls for. It publishes only call facts, so a surface that observes
/// it redraws for the call and nothing else, and a surface that does not (the
/// main window, which observes `AppModel`) never redraws for a caption.
@MainActor
public final class VoiceCallModel: ObservableObject {
    @Published public private(set) var voice = VoiceState()

    /// Whether the primary window, which draws the chat's call box, is on
    /// screen. The box's mascot animates only while it is, as the floating
    /// pet's does only while its own window is. Held here rather than on the
    /// box, which is rebuilt on every rail change and never hears the window
    /// host; it changes a few times a session, so publishing it costs nothing.
    @Published public private(set) var mainWindowVisible = true

    /// Normalized RMS (0...1) of the model's voice output. A plain property, not
    /// published: the pet's timeline samples it every frame, so a per-chunk
    /// update must not invalidate the SwiftUI tree.
    public private(set) var audioLevel: Float = 0

    /// The start whose mascot has played its intro in the chat's call box. The
    /// box is rebuilt on every rail change, so the box cannot remember
    /// that the two second intro already played for this call, and a mascot
    /// that swelled out of its sphere again on each visit to Chat would read
    /// as a new call. Not published: nothing redraws for it.
    private var introAttempt: Int?

    /// The start whose call box the person closed. The box goes at once, the
    /// call behind it still ending, and stays gone until the next start mints
    /// a new attempt; the call's facts, its cost among them, stay for the Pet
    /// page. Published: the box redraws for it.
    @Published private var closedBoxAttempt: Int?

    /// When the last chunk of a reply the operator stopped arrived, while more
    /// of it may still be coming.
    ///
    /// Stopping a reply does not stop the provider sending it. The Live engine
    /// answers `interrupt` with `playback_stop` and `listening` and leaves the
    /// response running, so the rest of it keeps arriving as `audio_delta`,
    /// each run announced by `state: speaking` again, and the pet started
    /// talking again a moment after Stop (owner report of 2026-09-25: "there
    /// was a stop button which wasnt working"). Those chunks are the reply the
    /// operator stopped: they are dropped until the stream has been quiet for
    /// `stoppedReplyGap`, and audio after that is a new reply.
    private var stoppedReplyHeardAt: TimeInterval?

    /// How long the stopped reply's stream must stay quiet before audio counts
    /// as a new reply. A provider streams a reply faster than it plays, so its
    /// chunks arrive close together; a new reply follows the operator's own
    /// turn, which takes longer than this to say anything.
    static let stoppedReplyGap: TimeInterval = 0.8

    /// A monotonic clock in seconds, a seam so the gap can be proved without
    /// waiting on it.
    private let now: () -> TimeInterval

    private let log = AppLog.logger(.voice)

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    // MARK: - The call's lifecycle
    //
    // Each transition lands as one write, so nothing observing the model ever
    // sees half of one: a phase that has moved on with facts that have not.

    /// A start: mints its attempt and clears the last call's facts.
    ///
    /// Everything the daemon reports about a call belongs to that call. The
    /// previous one's captions, delegation and bill are not this one's, and a
    /// surface that showed them would be reporting the wrong call, so a start
    /// is a fresh state that keeps only the connection and the count.
    @discardableResult
    public func callStarting() -> Int {
        stoppedReplyHeardAt = nil
        audioLevel = 0

        var next = VoiceState()
        next.attempt = voice.attempt + 1
        next.connected = voice.connected
        next.phase = .starting
        next.mode = .idle
        next.status = .connecting
        voice = next
        return next.attempt
    }

    /// `call_start` went out: the call is the daemon's. The status stays
    /// "Connecting" until the daemon says what the turn is doing.
    public func callStarted() {
        voice.phase = .active
    }

    /// A start called off before `call_start` went out. Nothing reached the
    /// daemon, so nothing ended: there is no call to report.
    public func callCancelled() {
        var next = voice
        next.phase = .idle
        next.restOutsideACall()
        voice = next
    }

    /// `call_stop` went out. The call is still the daemon's until its last
    /// frame, but the microphone and the speaker are already released.
    public func callStopping() {
        stoppedReplyHeardAt = nil
        audioLevel = 0

        var next = voice
        next.phase = .stopping
        next.muted = false
        next.audioActive = false
        next.restOutsideACall()
        voice = next
    }

    /// The stopping call's last frame never came. It is over anyway, with
    /// whatever bill had arrived.
    public func callEnded() {
        guard voice.phase == .stopping else { return }

        end(.normal(settled: voice.usage))
    }

    public func voiceNegotiated() {
        var next = voice
        next.connected = true

        switch next.phase {
        case .idle, .ended(.normal):
            next.restOutsideACall()
        case .starting, .active, .stopping, .ended(.failed):
            // A start keeps saying "Connecting", and a failure keeps its words.
            break
        }

        voice = next
    }

    /// The app is quitting: the call, if there is one, is over.
    public func voiceShutDown() {
        voice.connected = false

        switch voice.phase {
        case .starting:
            callCancelled()
        case .active, .stopping:
            end(.normal(settled: voice.usage))
        case .idle, .ended(.normal):
            voice.restOutsideACall()
        case .ended(.failed):
            break
        }
    }

    public func voiceMuted(_ muted: Bool) {
        voice.muted = muted

        guard voice.phase == .active else { return }

        voice.mode = voice.activeInputMode
        voice.status = VoiceStatus(mode: voice.mode)
    }

    /// The user cut the reply off. Presentation returns to whatever the
    /// microphone is doing; the daemon confirms with its own next state. What
    /// is still in flight of the stopped reply is dropped as it arrives
    /// (`stoppedReplyHeardAt`).
    public func voiceInterrupted() {
        voice.audioActive = false
        audioLevel = 0
        stoppedReplyHeardAt = now()

        guard voice.phase == .active else { return }

        voice.mode = voice.restingMode
        voice.status = VoiceStatus(mode: voice.mode)
    }

    /// The microphone could not start. The system's own sentence is what the
    /// user reads, because "voice failed" tells them nothing.
    public func voiceCaptureFailed(_ sentence: String) {
        fail(.microphoneUnavailable(sentence), kind: nil)
    }

    /// The session ended. What that means depends on the call.
    public func voiceFailed(_ failure: VoiceSessionFailure) {
        voice.connected = false
        let (mode, status) = Self.presentation(of: failure)

        switch voice.phase {
        case .starting, .active:
            fail(status, kind: Self.kind(of: failure), mode: mode)
        case .stopping:
            // The call was being hung up: losing the socket ends it as asked.
            end(.normal(settled: voice.usage))
        case .ended(.failed):
            // The daemon closes the socket after most errors (PROTOCOL.md,
            // `error`). The close is the refusal's consequence, and "Not
            // connected" would overwrite the reason the daemon gave.
            break
        case .idle, .ended(.normal):
            var next = voice
            next.mode = mode
            next.status = status
            voice = next
        }
    }

    public func voiceLevelChanged(_ level: Float) {
        audioLevel = level
    }

    /// The reply's audio has finished playing and stayed finished (the audio
    /// owner waits out a gap between chunks first).
    ///
    /// Speaking was this model's own reading of arriving audio, so its end is
    /// too. The Realtime engine has said listening by the time the audio runs
    /// out, but the Live engine publishes no end of a reply (the contract says
    /// there is no spoken-response completion event), and the pet stayed on
    /// its speaking face until the user next spoke (RCA of 2026-09-25). It
    /// returns to what the call is doing: backend work still running, or the
    /// microphone.
    public func voicePlaybackDrained() {
        guard voice.audioActive else { return }

        voice.audioActive = false
        guard voice.phase == .active, voice.mode == .speaking else { return }

        voice.mode = voice.restingMode
        voice.status = VoiceStatus(mode: voice.mode)
    }

    // MARK: - What the chat's call box remembers

    /// Whether this start's mascot has played its intro.
    public var introPlayed: Bool { introAttempt == voice.attempt }

    /// The box's mascot appeared for this start, so its intro is spent.
    public func introShown() {
        introAttempt = voice.attempt
    }

    /// Whether the person closed this start's box.
    public var callBoxClosed: Bool { closedBoxAttempt == voice.attempt }

    /// The person closed the box: the dock's stop, or a call control that
    /// ended the call (owner, 2026-10-08: "the stop should basically close
    /// the mascot").
    public func closeCallBox() {
        closedBoxAttempt = voice.attempt
    }

    public func mainWindowVisibilityChanged(_ visible: Bool) {
        guard visible != mainWindowVisible else { return }

        mainWindowVisible = visible
    }

    // MARK: - Routing

    /// Routes one server event: updates the voice facts and answers with what
    /// the audio owner must do. The phase decides which call, if any, a frame
    /// is about.
    @discardableResult
    public func apply(_ event: RealtimeServerEvent, audioIsPlaying: Bool) -> [VoiceEffect] {
        switch voice.phase {
        case .active:
            return applyDuringCall(event, audioIsPlaying: audioIsPlaying)
        case .stopping:
            return applyWhileStopping(event)
        case .starting:
            return applyBeforeTheCall(event)
        case .idle, .ended:
            return dropped(event)
        }
    }

    /// Frames for a start that has not sent `call_start` yet: no call frame
    /// can be this start's, but a refusal from the daemon ends the start.
    private func applyBeforeTheCall(_ event: RealtimeServerEvent) -> [VoiceEffect] {
        guard case .error(let failure) = event else { return dropped(event) }

        return applyServerError(failure)
    }

    /// Frames after `call_stop` belong to the call that is ending, up to the
    /// `state idle` that follows its settled bill (`VoiceState.settled`).
    /// Nothing here moves the presentation, and no audio plays.
    private func applyWhileStopping(_ event: RealtimeServerEvent) -> [VoiceEffect] {
        switch event {
        case .state(.idle):
            guard voice.settled else { return [] }

            end(.normal(settled: voice.usage))
            return [.callEnded]
        case .error(let failure):
            return applyServerError(failure) + [.callEnded]
        case .usage(let usage):
            voice.usage = usage
            return []
        case .task(let task):
            var tasks = voice.tasks
            if accept(task, into: &tasks) {
                voice.tasks = tasks
            }
            return []
        case .caption(let caption):
            appendCaption(caption)
            return []
        case .callReady(let ready):
            return applyCallReady(ready)
        default:
            return dropped(event)
        }
    }

    /// A frame no call can carry. The handshake's frames are the session's
    /// business and never reach here; the transcript deltas are inert in every
    /// phase.
    private func dropped(_ event: RealtimeServerEvent) -> [VoiceEffect] {
        switch event {
        case .serverHello, .transcriptDelta, .assistantTextDelta:
            break
        default:
            log.info("dropping \(event.wireType, privacy: .public): no call carries it")
        }

        return []
    }

    private func applyDuringCall(_ event: RealtimeServerEvent, audioIsPlaying: Bool) -> [VoiceEffect] {
        switch event {
        case .state(let turnState):
            return applyTurnState(turnState, audioIsPlaying: audioIsPlaying)
        case .audioDelta(let base64):
            // Live pads its output with silence for the whole call, one chunk
            // every 100 ms: padding plays, but it is not speech, and it must
            // neither keep the pet speaking nor keep a stopped reply alive.
            guard PCM16.isVoiced(base64: base64) else { return [.play(base64: base64)] }
            if stoppedReplyContinues() { return [] }
            // Every chunk of a reply lands here, tens a second. Only the first
            // changes anything, and each write publishes, so the window, the
            // status item and the pet redrew three times per chunk.
            var speaking = voice
            speaking.mode = .speaking
            speaking.status = .speaking
            speaking.audioActive = true
            if speaking != voice { voice = speaking }
            return [.play(base64: base64)]
        case .playbackStop:
            return applyPlaybackStop()
        case .toolEvent(let status, let reason):
            return applyToolEvent(status: status, reason: reason)
        case .error(let failure):
            return applyServerError(failure)
        case .callReady(let ready):
            return applyCallReady(ready)
        case .caption(let caption):
            return applyCaption(caption)
        case .task(let task):
            return applyTask(task)
        case .usage(let usage):
            // A bill is a fact, not a state: what a limit does to the call
            // arrives as its own `error`, carrying the cost_limit kind.
            voice.usage = usage
            return []
        case .serverHello, .transcriptDelta, .assistantTextDelta:
            return []
        case .unrecognized(let type):
            log.debug("no presentation for realtime event \(type, privacy: .public)")
            return []
        }
    }

    private func applyTurnState(_ turnState: RealtimeTurnState, audioIsPlaying: Bool) -> [VoiceEffect] {
        // The stopped reply announcing its next run: the operator already
        // stopped it, so the pet stays where Stop left it.
        if turnState == .speaking, stoppedReplyContinues() { return [] }

        var effects: [VoiceEffect] = []
        let wasSpeaking = voice.mode == .speaking

        // The daemon is authoritative about mute: it reports the state the turn
        // is actually in, and the local capture path follows it.
        if turnState == .muted {
            voice.muted = true
            effects.append(.setCaptureMuted(true))
        } else if turnState == .idle {
            voice.muted = false
            effects.append(.setCaptureMuted(false))
        }

        let presented = VoiceMode(turnState: turnState)
        voice.mode = presented == .listening ? voice.restingMode : presented
        voice.status = VoiceStatus(mode: voice.mode)

        if turnState == .listening {
            effects.append(.startCapture)
        }

        if wasSpeaking && voice.mode != .speaking {
            effects.append(.resetUtteranceAnchor)
        }

        // The speaking tail belongs to real playback: once the daemon has moved
        // on and no audio remains, drop it.
        if !audioIsPlaying {
            voice.audioActive = false
        }

        return effects
    }

    /// Whether this frame still belongs to the reply the operator stopped,
    /// extending the quiet window when it does. The first frame after a quiet
    /// gap ends the window: it is a new reply.
    private func stoppedReplyContinues() -> Bool {
        guard let heard = stoppedReplyHeardAt else { return false }

        let time = now()
        guard time - heard < Self.stoppedReplyGap else {
            stoppedReplyHeardAt = nil
            return false
        }

        stoppedReplyHeardAt = time
        return true
    }

    private func applyPlaybackStop() -> [VoiceEffect] {
        voice.audioActive = false
        voice.mode = voice.restingMode
        voice.status = VoiceStatus(mode: voice.mode)
        return [.stopPlayback, .resetUtteranceAnchor]
    }

    private func applyToolEvent(status: RealtimeToolStatus, reason: String?) -> [VoiceEffect] {
        guard status != .failed else {
            voice.mode = .error
            voice.status = .refused(reason ?? ProductStrings[.voiceStatusToolFailed])
            return []
        }

        voice.mode = .toolUse
        voice.status = VoiceStatus(mode: voice.mode)
        return []
    }

    /// `call_ready` is a fact about the call rather than a turn state: it says
    /// which engine answered and which call this is. The daemon reports what
    /// the turn is doing in `state`, so nothing here touches the mode.
    private func applyCallReady(_ ready: RealtimeCallReady) -> [VoiceEffect] {
        voice.engine = ready.engine
        voice.callId = ready.callId
        return []
    }

    private func applyCaption(_ caption: RealtimeCaption) -> [VoiceEffect] {
        appendCaption(caption)
        return []
    }

    /// A fragment joins its speaker's text. The contract names two speakers;
    /// a third would be a word with no line of its own, and crediting it to
    /// either of the two would misquote the call.
    private func appendCaption(_ caption: RealtimeCaption) {
        switch caption.speaker {
        case .user:
            voice.captions.append(caption.delta, from: .user)
        case .assistant:
            voice.captions.append(caption.delta, from: .assistant)
        case .unrecognized(let speaker):
            log.info("dropping a caption from speaker \(speaker, privacy: .public)")
        }
    }

    /// A backend delegation presents like a tool call, which is what it is from
    /// this side: the assistant is working while any runs, and back at the
    /// microphone once none does. A status this build cannot read is not
    /// terminal, so an unknown word never ends the work early.
    private func applyTask(_ task: RealtimeTask) -> [VoiceEffect] {
        var next = voice
        guard accept(task, into: &next.tasks) else { return [] }

        next.mode = next.restingMode
        next.status = VoiceStatus(mode: next.mode)
        voice = next
        return []
    }

    private func accept(_ task: RealtimeTask, into tasks: inout VoiceTasks) -> Bool {
        guard tasks.apply(task) else {
            log.info(
                "dropping a late task frame for \(task.delegationId, privacy: .public) at revision \(task.revision, privacy: .public)"
            )
            return false
        }

        return true
    }

    /// A server error ends the call, and may mean the socket is unusable, so
    /// the microphone is detached before an in-flight buffer can race back to
    /// it.
    private func applyServerError(_ failure: RealtimeServerError) -> [VoiceEffect] {
        fail(.callFailed(failure), kind: failure.kind)
        return [.endAudio]
    }

    // MARK: - Endings

    private func end(_ outcome: VoiceCallOutcome) {
        stoppedReplyHeardAt = nil
        audioLevel = 0

        var next = voice
        next.phase = .ended(outcome)
        next.muted = false
        next.audioActive = false
        next.restOutsideACall()
        voice = next
    }

    /// The call, or the start of one, failed. `status` is the words every
    /// surface reads, and the outcome keeps them beside the daemon's kind.
    private func fail(_ status: VoiceStatus, kind: RealtimeErrorKind?, mode: VoiceMode = .error) {
        stoppedReplyHeardAt = nil
        audioLevel = 0

        var next = voice
        next.phase = .ended(.failed(kind: kind, sentence: status.text))
        next.muted = false
        next.audioActive = false
        next.mode = mode
        next.status = status
        voice = next
    }

    private static func presentation(of failure: VoiceSessionFailure) -> (VoiceMode, VoiceStatus) {
        switch failure {
        case .versionUnsupported:
            return (.error, .updateRequired)
        case .refused(let reason):
            return (.error, .refused(reason))
        case .socketPathUnavailable:
            return (.error, .homeUnavailable)
        case .connectFailed, .handshakeTimedOut, .transport:
            return (.offline, .offline)
        }
    }

    /// A version refusal is the daemon's `update_required` whichever half of
    /// the handshake noticed it.
    private static func kind(of failure: VoiceSessionFailure) -> RealtimeErrorKind? {
        guard case .versionUnsupported = failure else { return nil }

        return .updateRequired
    }
}
