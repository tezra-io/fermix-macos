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
}

/// What the daemon said, as the model holds it.
///
/// The wire shapes are the model's shapes: a caption is the fragment that
/// arrived, a task is the frame that arrived, and a parallel struct beside each
/// would only be somewhere for the two to drift apart.
public typealias VoiceCaption = RealtimeCaption
public typealias VoiceTask = RealtimeTask
public typealias VoiceUsage = RealtimeUsage

/// The voice facts, separate from how they draw.
public struct VoiceState: Equatable, Sendable {
    /// How many caption fragments are kept. A Live call emits them for as long
    /// as it runs, so the tail is bounded and the head is dropped.
    public static let captionLimit = 40

    public var mode: VoiceMode = .offline
    public var connected = false
    public var callActive = false
    public var muted = false
    /// True while voice audio is still leaving the speaker, which outlasts the
    /// daemon's speaking state by the length of the buffered tail.
    public var audioActive = false
    public var status: VoiceStatus = .offline
    /// Which engine answered and which call this is, from `call_ready`. Both
    /// are the daemon's own words, and neither changes what the pet draws.
    public var engine: String?
    public var callId: String?
    /// The transcript fragments of this call, oldest first, capped at
    /// `captionLimit`. They are held exactly as they arrived.
    public var captions: [VoiceCaption] = []
    /// The backend delegation the daemon last reported, where the call has one.
    public var task: VoiceTask?
    /// The usage frame the daemon last reported.
    public var usage: VoiceUsage?

    public var presentation: VoicePresentation {
        VoicePresentation(mode: mode, callActive: callActive, audioActive: audioActive)
    }

    /// The sentence a surface shows for this state.
    ///
    /// The presentation's label is the default, because it follows the visual
    /// mode and so keeps saying "Speaking" through the audio tail the daemon
    /// has already moved past. A failure is the exception: its own words are
    /// the only ones that name what went wrong, and rebuilding them from
    /// `.error` yields "Not connected".
    public var statusText: String {
        status.carriesItsOwnSentence ? status.text : presentation.accessibilityLabel
    }

    /// What the microphone is doing while a call is live.
    var activeInputMode: VoiceMode { muted ? .muted : .listening }

    /// Where a live call rests when nothing is being said: backend work that
    /// is still running, which the pet shows as thinking until it ends, or
    /// else the microphone. A reply spoken over the work, or the daemon saying
    /// listening once it has played, does not end the work (RCA of
    /// 2026-09-25: "Retain task activity independently").
    var restingMode: VoiceMode {
        let working = task.map { !$0.status.isTerminal } ?? false
        return working ? .toolUse : activeInputMode
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

    /// Normalized RMS (0...1) of the model's voice output. A plain property, not
    /// published: the pet's timeline samples it every frame, so a per-chunk
    /// update must not invalidate the SwiftUI tree.
    public private(set) var audioLevel: Float = 0

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

    // MARK: - Session lifecycle

    public func voiceConnecting() {
        voice.status = .connecting
        voice.mode = .idle
    }

    public func voiceNegotiated() {
        voice.connected = true
        voice.mode = .idle
        voice.status = .idle
    }

    public func voiceCallBegan() {
        stoppedReplyHeardAt = nil
        voice.callActive = true
        voice.muted = false
        voice.mode = .idle
        voice.status = .connecting
        // Everything the daemon reports about a call belongs to that call. The
        // previous one's captions, delegation and bill are not this one's, and
        // a surface that showed them would be reporting the wrong call.
        voice.engine = nil
        voice.callId = nil
        voice.captions = []
        voice.task = nil
        voice.usage = nil
    }

    public func voiceCallEnded() {
        stoppedReplyHeardAt = nil
        voice.callActive = false
        voice.muted = false
        voice.audioActive = false
        audioLevel = 0
        voice.mode = voice.connected ? .idle : .offline
        voice.status = VoiceStatus(mode: voice.mode)
    }

    public func voiceMuted(_ muted: Bool) {
        voice.muted = muted

        guard voice.callActive else { return }

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

        guard voice.callActive else { return }

        voice.mode = voice.restingMode
        voice.status = VoiceStatus(mode: voice.mode)
    }

    /// The microphone could not start. The system's own sentence is what the
    /// user reads, because "voice failed" tells them nothing.
    public func voiceCaptureFailed(_ sentence: String) {
        voice.callActive = false
        voice.muted = false
        voice.audioActive = false
        voice.mode = .error
        voice.status = .microphoneUnavailable(sentence)
    }

    public func voiceFailed(_ failure: VoiceSessionFailure) {
        voice.connected = false
        voice.callActive = false
        voice.muted = false
        voice.audioActive = false
        audioLevel = 0

        switch failure {
        case .versionUnsupported:
            voice.mode = .error
            voice.status = .updateRequired
        case .refused(let reason):
            voice.mode = .error
            voice.status = .refused(reason)
        case .socketPathUnavailable:
            voice.mode = .error
            voice.status = .homeUnavailable
        case .connectFailed, .handshakeTimedOut, .transport:
            voice.mode = .offline
            voice.status = .offline
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
        guard voice.callActive, voice.mode == .speaking else { return }

        voice.mode = voice.restingMode
        voice.status = VoiceStatus(mode: voice.mode)
    }

    // MARK: - Routing

    /// Routes one server event: updates the voice facts and answers with what
    /// the audio owner must do.
    @discardableResult
    public func apply(_ event: RealtimeServerEvent, audioIsPlaying: Bool) -> [VoiceEffect] {
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

        if voice.callActive {
            voice.mode = voice.restingMode
            voice.status = VoiceStatus(mode: voice.mode)
        }

        return [.stopPlayback, .resetUtteranceAnchor]
    }

    private func applyToolEvent(status: RealtimeToolStatus, reason: String?) -> [VoiceEffect] {
        guard status != .failed else {
            voice.mode = .error
            voice.status = .refused(reason ?? ProductStrings[.voiceStatusToolFailed])
            return []
        }

        voice.mode = voice.callActive ? .toolUse : .idle
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

    /// Fragments are appended exactly as they arrived: the contract says to
    /// concatenate the deltas without trimming them or inserting spaces, and
    /// user and assistant fragments may overlap in time.
    private func applyCaption(_ caption: RealtimeCaption) -> [VoiceEffect] {
        voice.captions.append(caption)

        let overflow = voice.captions.count - VoiceState.captionLimit
        if overflow > 0 {
            voice.captions.removeFirst(overflow)
        }

        return []
    }

    /// A backend delegation presents like a tool call, which is what it is from
    /// this side: the assistant is working while it runs, and back at the
    /// microphone once it stops. A status this build cannot read is not
    /// terminal, so an unknown word never ends the work early.
    private func applyTask(_ task: RealtimeTask) -> [VoiceEffect] {
        voice.task = task

        if task.status.isTerminal {
            voice.mode = voice.callActive ? voice.activeInputMode : .idle
        } else {
            voice.mode = voice.callActive ? .toolUse : .idle
        }

        voice.status = VoiceStatus(mode: voice.mode)
        return []
    }

    /// A server error may mean the socket is unusable, so the microphone is
    /// detached before an in-flight buffer can race back to it.
    private func applyServerError(_ failure: RealtimeServerError) -> [VoiceEffect] {
        voice.callActive = false
        voice.muted = false
        voice.audioActive = false
        voice.mode = .error
        voice.status = .refused(failure.reason)
        audioLevel = 0
        return [.endAudio]
    }
}
