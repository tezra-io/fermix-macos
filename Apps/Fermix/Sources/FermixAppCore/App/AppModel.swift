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

/// Which onboarding surface the app is showing.
///
/// The five M34 stages are Welcome, Activate, Configure, Ready, and Recovery.
/// Configure has three surfaces rather than one — the two connect shells and
/// the daemon-served Setup they hand off to — and Activate has the boot-failure
/// surface that replaces it, so the machine's states are finer than the stage
/// names while the journey is the same one.
public enum OnboardingStage: String, CaseIterable, Sendable {
    case welcome
    case activate
    /// Replaces Activate when activation ends in one of its named causes.
    case bootFailed
    /// Configure, the AI shell. The forms themselves stay daemon-owned.
    case configureAI
    /// Configure, the channel shell.
    case configureChannel
    /// Configure, the daemon-served Setup in the ephemeral web view.
    case configureSetup
    case ready
    case recovery

    /// The five steps the progress dots count. The hosted Setup shares its
    /// step with the shell it was opened from: it is a surface over that step,
    /// not a step of its own.
    public static let progressStepCount = 5

    public var isConfigure: Bool {
        switch self {
        case .configureAI, .configureChannel, .configureSetup: return true
        case .welcome, .activate, .bootFailed, .ready, .recovery: return false
        }
    }

    /// Which dot is lit, or nil where the design draws none.
    public var progressIndex: Int? {
        switch self {
        case .welcome: return 0
        case .activate: return 1
        case .configureAI: return 2
        case .configureChannel, .configureSetup: return 3
        case .ready: return 4
        case .bootFailed, .recovery: return nil
        }
    }
}

/// How the daemon is doing, as the menu bar reads it.
public enum DaemonCondition: String, CaseIterable, Sendable {
    case running
    case starting
    case stopped
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
    @Published public var onboardingStage: OnboardingStage = .welcome
    @Published public var serviceEnabled = false
    /// Starting, until something authoritative says otherwise. A launch has not
    /// asked the daemon anything yet, and the attention badge is a claim: it
    /// must mean "look at this", not "nobody has looked yet".
    @Published public var daemon: DaemonCondition = .starting
    @Published public var petShown = false
    @Published public var needsAttention = false
    @Published public var transactionInFlight = false

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
