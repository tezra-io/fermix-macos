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
/// The menus, the status item, the chat's toolbar, the Pet page and the
/// floating pet all click through here, so they behave the same: the daemon's
/// readiness word decides whether a click begins a call, opens Settings, Voice,
/// or does nothing, and ending a call is never gated. It holds nothing of its
/// own: the phase is the call model's and the readiness is the overview
/// reader's.
///
/// It announces a change only when its answer moves, so a surface that draws
/// the control without drawing the call (the chat's toolbar) redraws when the
/// call begins or ends and never for a caption.
@MainActor
public final class VoiceCallGate: ObservableObject {
    private let call: VoiceCallModel
    private let voice: any VoiceControlling
    private let reader: any VoiceReadinessReading
    /// Opens Settings, Voice, which is the coordinator's door into settings.
    private let setUpVoice: () -> Void
    private let log = AppLog.logger(.voice)
    private var actionChanges: AnyCancellable?

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
        // Both halves arrive as they are about to change, so the answer is
        // worked out from what they carry, not read back from their owners.
        actionChanges = call.$voice.map(\.phase)
            .combineLatest(readiness.voiceReadinessChanges.prepend(readiness.voiceReadiness))
            .map(Self.action)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public var readiness: VoiceReadiness { reader.voiceReadiness }

    public var readinessChanges: AnyPublisher<VoiceReadiness, Never> { reader.voiceReadinessChanges }

    public var action: VoiceCallAction {
        Self.action(phase: call.voice.phase, readiness: readiness)
    }

    /// The rule, in one place: a start or a call is always the control's to
    /// end, and otherwise the daemon's readiness word decides.
    static func action(phase: VoiceCallPhase, readiness: VoiceReadiness) -> VoiceCallAction {
        guard !phase.callControlEnds else { return .end }

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
