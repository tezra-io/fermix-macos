import Foundation

public enum PetExpression: String, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking

    /// The pose for a mode. Listening is the daemon's word, never inferred
    /// from a call being up: from `call_start` until the daemon first says
    /// listening the provider is still connecting and the microphone sends
    /// nothing, and both engines say idle only while a call ends or
    /// reconnects. A pet drawn listening then invited the person to talk to
    /// no one (owner, 2026-10-08), so idle is the resting pose in and out of a
    /// call.
    static func resolve(for mode: VoiceMode) -> PetExpression {
        switch mode {
        case .listening, .muted:
            return .listening
        case .speaking:
            return .speaking
        case .thinking, .toolUse:
            return .thinking
        case .offline, .idle, .error:
            return .idle
        }
    }
}
