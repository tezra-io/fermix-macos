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

/// The voice facts, separate from how they draw.
public struct VoiceState: Equatable, Sendable {
    public var mode: VoiceMode = .offline
    public var connected = false
    public var callActive = false
    public var muted = false
    /// True while voice audio is still leaving the speaker, which outlasts the
    /// daemon's speaking state by the length of the buffered tail.
    public var audioActive = false
    public var status: VoiceStatus = .offline

    public var presentation: VoicePresentation {
        VoicePresentation(mode: mode, callActive: callActive, audioActive: audioActive)
    }

    /// What the microphone is doing while a call is live.
    var activeInputMode: VoiceMode { muted ? .muted : .listening }
}

/// Which Setup Assistant screen the app is showing.
///
/// The eight screens of M34 §4: Welcome, Starting, Connect your AI, About you,
/// Applying, Ready, plus the two the journey can be replaced by, Boot failed and
/// Recovery. There is no hosted-Setup state and no channel step: a channel is
/// advisory in the readiness split, so it lives in the Channels pane.
public enum OnboardingStage: String, CaseIterable, Sendable {
    case welcome
    /// The masked boot: the four-row ladder of M34 §4.
    case starting
    /// The one required decision.
    case connectAI
    /// The owner's name, time zone, style, and what to call the assistant.
    case aboutYou
    /// The two-row ladder that saves those answers and restarts the daemon.
    case applying
    case ready
    /// Replaces Starting when activation ends in one of its named causes.
    case bootFailed
    case recovery

    /// The steps the progress dots count.
    ///
    /// Four, not eight: the two mechanical stages inherit the step they run
    /// inside (redlines §5.8), and the two failure screens carry no dots at all.
    public static let progressStepCount = 4

    /// Which dot is lit, or nil where the design draws none.
    public var progressIndex: Int? {
        switch self {
        case .welcome, .starting: return 0
        case .connectAI: return 1
        case .aboutYou, .applying: return 2
        case .ready: return 3
        case .bootFailed, .recovery: return nil
        }
    }

    /// Whether this stage runs on its own and takes no decision, which is what
    /// leaves the bottom bar without a continue action while it does.
    public var isMechanical: Bool { self == .starting || self == .applying }
}

/// How the daemon is doing, as the menu bar reads it.
public enum DaemonCondition: String, CaseIterable, Sendable {
    case running
    case starting
    case stopped
}

/// What one look at the daemon found.
///
/// The condition has exactly one writer, `AppCoordinator`, and two sources that
/// speak through this value: the read Home already makes on every refresh, and
/// the lifecycle transaction the user runs. Two sources and one shape is what
/// stops a launch against a daemon that is already up from sitting on
/// `starting` for the whole session, without giving the menu bar a poll of its
/// own to disagree with Home's.
public struct DaemonObservation: Equatable, Sendable {
    public let condition: DaemonCondition
    /// Whether the operator has something to look at. It reaches the menu bar
    /// as a shape cut into the glyph, never as a colour cue alone.
    public let needsAttention: Bool

    public init(condition: DaemonCondition, needsAttention: Bool) {
        self.condition = condition
        self.needsAttention = needsAttention
    }
}

/// Application-scoped presentation state, and the routing that drives it.
///
/// The model owns no socket, no audio engine, and no window. It holds what the
/// surfaces draw and answers a server event with the effects that event calls
/// for.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var voice = VoiceState()
    @Published public var route: AppRoute = .home
    // Requested navigation can precede presentation while recovery is checked.
    // Keep it unpublished so List callbacks never publish a speculative route.
    var pendingNavigation: AppDestination?
    @Published public var onboardingStage: OnboardingStage = .welcome
    /// Starting, until something authoritative says otherwise. A launch has not
    /// asked the daemon anything yet, and the attention badge is a claim: it
    /// must mean "look at this", not "nobody has looked yet".
    ///
    /// Home's first refresh is what answers, through
    /// `AppCoordinator.daemonObserved`. Nothing else may write this: a second
    /// writer is how the glyph and the status line come to say different
    /// things about the same daemon.
    @Published public var daemon: DaemonCondition = .starting
    @Published public var petShown = false
    @Published public var needsAttention = false
    @Published public var transactionInFlight = false
    /// Whether the Restart sheet is asking, in the one window that can host it.
    ///
    /// One owner for the whole app (M34 §5.10): Home's Attention row, the
    /// Settings banner, the Daemon menu and the status item all ask through
    /// `AppCoordinator.askForRestart`, so a restart is never taken without the
    /// sheet naming its reasons and the work it would interrupt.
    @Published public var restartSheetShown = false
    /// Why the last lifecycle transaction was refused, in one sentence, or nil
    /// where it was not.
    ///
    /// One writer, `AppCoordinator`, like the daemon condition beside it. It is
    /// what the Restart sheet reads: a refusal that only reached the log left
    /// the operator clicking a button that did nothing (owner report of
    /// 2026-09-04).
    @Published public var restartRefusal: String?
    /// The sheet of commands a surface asked to show, where one asked.
    ///
    /// One owner, like the Restart sheet: Home's Attention row, a Doctor
    /// remediation and the Help menu all ask through
    /// `AppCoordinator.showInstructions`, so the same lines are drawn the same
    /// way whichever door opened them (M34 §15.2).
    @Published public var instructionsShown: CoexistenceInstructions?

    /// Normalized RMS (0...1) of the model's voice output. A plain property, not
    /// published: the pet's timeline samples it every frame, so a per-chunk
    /// update must not invalidate the SwiftUI tree.
    public private(set) var audioLevel: Float = 0

    private let log = AppLog.logger(.app)

    public init() {}

    public var menuGlyph: MenuBarGlyphState {
        MenuBarGlyphState(daemon: daemon, hasAttention: needsAttention)
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
        voice.callActive = true
        voice.muted = false
        voice.mode = .idle
        voice.status = .connecting
    }

    public func voiceCallEnded() {
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
    /// microphone is doing; the daemon confirms with its own next state.
    public func voiceInterrupted() {
        voice.audioActive = false
        audioLevel = 0

        guard voice.callActive else { return }

        voice.mode = voice.activeInputMode
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

    public func voicePlaybackDrained() {
        guard voice.audioActive else { return }

        voice.audioActive = false
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
            voice.mode = .speaking
            voice.status = .speaking
            voice.audioActive = true
            return [.play(base64: base64)]
        case .playbackStop:
            return applyPlaybackStop()
        case .toolEvent(let status, let reason):
            return applyToolEvent(status: status, reason: reason)
        case .error(let failure):
            return applyServerError(failure)
        case .serverHello, .transcriptDelta, .assistantTextDelta, .usage:
            return []
        case .unrecognized(let type):
            log.debug("no presentation for realtime event \(type, privacy: .public)")
            return []
        }
    }

    private func applyTurnState(_ turnState: RealtimeTurnState, audioIsPlaying: Bool) -> [VoiceEffect] {
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
        voice.mode = (voice.muted && presented == .listening) ? .muted : presented
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

    private func applyPlaybackStop() -> [VoiceEffect] {
        voice.audioActive = false

        if voice.callActive {
            voice.mode = voice.activeInputMode
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
