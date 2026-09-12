import Foundation

/// What the app is doing with voice, as one word.
///
/// Six of these mirror the daemon's turn states; `toolUse` and `error` are
/// local presentation states with no wire equivalent.
public enum VoiceMode: String, CaseIterable, Sendable {
    case offline
    case idle
    case listening
    case muted
    case thinking
    case speaking
    case toolUse
    case error

    /// The presentation for a turn state, including one this build has never
    /// seen: an unknown state reads as idle rather than as nothing.
    public init(turnState: RealtimeTurnState) {
        switch turnState {
        case .idle: self = .idle
        case .listening: self = .listening
        case .speaking: self = .speaking
        case .muted: self = .muted
        case .thinking: self = .thinking
        case .reconnecting: self = .idle
        case .unrecognized: self = .idle
        }
    }
}

/// What the voice surface says right now. The two cases carrying prose carry
/// the daemon's or the system's own words; everything else is product copy.
public enum VoiceStatus: Equatable, Sendable {
    case offline
    case connecting
    case idle
    case listening
    case muted
    case thinking
    case speaking
    case toolUse
    /// The daemon's protocol window excludes this build, or the reverse.
    case updateRequired
    /// This account's Fermix home could not be resolved.
    case homeUnavailable
    /// A refusal, in the daemon's own word.
    case refused(String)
    /// Capture could not start, in the system's own sentence.
    case microphoneUnavailable(String)

    public var text: String {
        switch self {
        case .offline: return ProductStrings[.voiceStatusOffline]
        case .connecting: return ProductStrings[.voiceStatusConnecting]
        case .idle: return ProductStrings[.voiceStatusIdle]
        case .listening: return ProductStrings[.voiceStatusListening]
        case .muted: return ProductStrings[.voiceStatusMuted]
        case .thinking: return ProductStrings[.voiceStatusThinking]
        case .speaking: return ProductStrings[.voiceStatusSpeaking]
        case .toolUse: return ProductStrings[.voiceStatusToolUse]
        case .updateRequired: return ProductStrings[.voiceStatusUpdateRequired]
        case .homeUnavailable: return ProductStrings[.voiceStatusHomeUnavailable]
        case .refused(let reason): return String(format: ProductStrings[.voiceStatusRefusedFormat], reason)
        // The capture errors are already whole sentences from the copy deck,
        // so wrapping them in a second sentence would say it twice.
        case .microphoneUnavailable(let sentence): return sentence
        }
    }

    /// Whether this status says something `VoiceStatus(mode:)` cannot rebuild.
    ///
    /// Every failure records its own sentence, and `.error` reconstructs as
    /// `.offline` — so a surface that derives its words from the mode reports a
    /// healthy disconnection for a machine that is refusing for a reason it has
    /// already put into words. These four are the statuses a surface must read
    /// from the status itself. Enumerated rather than defaulted, so a status
    /// added later has to decide which half it belongs to.
    public var carriesItsOwnSentence: Bool {
        switch self {
        case .updateRequired, .homeUnavailable, .refused, .microphoneUnavailable:
            return true
        case .offline, .connecting, .idle, .listening, .muted, .thinking, .speaking, .toolUse:
            return false
        }
    }

    /// The plain status for a mode, before anything more specific is known.
    public init(mode: VoiceMode) {
        switch mode {
        case .offline: self = .offline
        case .idle: self = .idle
        case .listening: self = .listening
        case .muted: self = .muted
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        case .toolUse: self = .toolUse
        case .error: self = .offline
        }
    }
}

/// How a voice state draws.
///
/// The design has one accent and otherwise neutral surfaces, so the tints are
/// palette tokens: the accent marks a live microphone, the two status colours
/// mark muted and failed, and everything else is neutral. Nothing is carried by
/// colour alone — the symbol and the status word both say it too.
public struct VoicePresentation: Equatable, Sendable {
    public let mode: VoiceMode
    public let callActive: Bool
    public let audioActive: Bool

    public init(mode: VoiceMode, callActive: Bool, audioActive: Bool) {
        self.mode = mode
        self.callActive = callActive
        self.audioActive = audioActive
    }

    /// While voice audio is still playing out, the pet reads as speaking even
    /// though the daemon's turn state has already returned to listening: the
    /// buffered audio keeps playing for seconds after generation stops.
    public var visualMode: VoiceMode {
        (callActive && audioActive) ? .speaking : mode
    }

    public var tint: ThemedColor {
        switch visualMode {
        case .offline: return Palette.faint
        case .idle: return Palette.secondary
        case .listening: return Palette.accent
        case .muted: return Palette.warning
        case .thinking: return Palette.secondary
        case .speaking: return Palette.success
        case .toolUse: return Palette.secondary
        case .error: return Palette.error
        }
    }

    public var iconName: String {
        switch visualMode {
        case .offline: return "wifi.slash"
        case .idle: return "circle"
        case .listening: return "mic.fill"
        case .muted: return "mic.slash.fill"
        case .thinking: return "sparkles"
        case .speaking: return "waveform"
        case .toolUse: return "wrench.and.screwdriver"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    public var expression: PetExpression {
        PetExpression.resolve(for: visualMode, callActive: callActive)
    }

    public var accessibilityLabel: String {
        VoiceStatus(mode: visualMode).text
    }
}
