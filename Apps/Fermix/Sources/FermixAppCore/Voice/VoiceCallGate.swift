import Combine
import Foundation

/// What a click on the one call control does right now (M56 §4.1).
public enum VoiceCallAction: Equatable, Sendable {
    /// Voice is ready: the click begins a call.
    case begin
    /// A start or a call is up: the click ends it, whatever readiness says.
    case end
    /// Voice is not set up: the click opens Settings, Voice.
    case setUp
    /// Voice is degraded, or nothing has been read yet: the click does
    /// nothing, and the readiness sentence says why.
    case unavailable
}

/// The gate in front of the one call control (M56 §4.1).
///
/// The menus, the status item, the Pet page and the floating pet all click
/// through here, so they behave the same: the daemon's readiness word decides
/// whether a click begins a call, opens Settings, Voice, or does nothing, and
/// ending a call is never gated. It holds nothing of its own: the phase is the
/// call model's and the readiness is the overview reader's.
@MainActor
public final class VoiceCallGate {
    private let call: VoiceCallModel
    private let voice: any VoiceControlling
    private let reader: any VoiceReadinessReading
    /// Opens Settings, Voice, which is the coordinator's door into settings.
    private let setUpVoice: () -> Void
    private let log = AppLog.logger(.voice)

    public init(
        call: VoiceCallModel,
        voice: any VoiceControlling,
        readiness: any VoiceReadinessReading,
        setUpVoice: @escaping () -> Void
    ) {
        self.call = call
        self.voice = voice
        self.reader = readiness
        self.setUpVoice = setUpVoice
    }

    public var readiness: VoiceReadiness { reader.voiceReadiness }

    public var readinessChanges: AnyPublisher<VoiceReadiness, Never> { reader.voiceReadinessChanges }

    public var action: VoiceCallAction {
        guard !call.voice.phase.callControlEnds else { return .end }

        switch readiness {
        case .ready: return .begin
        case .setupRequired: return .setUp
        case .degraded, .unknown: return .unavailable
        }
    }

    /// The click. A call that is still ending takes `begin` like any other
    /// moment with no call up: the controller holds that start until the last
    /// call has ended.
    public func toggleCall() {
        switch action {
        case .begin, .end:
            voice.toggleCall()
        case .setUp:
            setUpVoice()
        case .unavailable:
            log.log("not beginning a call: voice is not ready to take one")
        }
    }
}
