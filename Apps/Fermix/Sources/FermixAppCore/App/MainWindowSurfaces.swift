import Foundation

/// The primary-window surfaces plus onboarding, built once and handed to the
/// windows that draw them.
///
/// They are assembled here rather than inside the views so each one keeps a
/// single instance across route changes: a Doctor run and a Logs page survive
/// the user visiting Home and coming back.
@MainActor
public final class MainWindowSurfaces {
    public let home: HomeModel
    public let doctor: DoctorModel
    public let logs: LogsModel
    public let pet: PetFeatureModel
    /// The one call's facts, which every view of the call reads: the Pet page,
    /// the floating pet and, through this, the chat window.
    public let voiceCall: VoiceCallModel
    /// The gate every call control clicks through: the menus, the status item,
    /// the Pet page and the floating pet (M56 §4.1).
    public let callGate: VoiceCallGate
    public let onboarding: OnboardingModel
    /// The one `SettingsModel` (M34 §8). It is built before these surfaces and
    /// handed in, because Home and onboarding read the same snapshot: two
    /// instances is the defect this single reference exists to prevent.
    public let settings: SettingsModel
    /// The one chat session, and through it the model a chat surface observes.
    /// One instance for the same reason: the outbox and the held timeline
    /// outlive any view that shows them.
    public let companion: CompanionSession

    public init(
        home: HomeModel,
        doctor: DoctorModel,
        logs: LogsModel,
        pet: PetFeatureModel,
        voiceCall: VoiceCallModel,
        callGate: VoiceCallGate,
        onboarding: OnboardingModel,
        settings: SettingsModel,
        companion: CompanionSession
    ) {
        self.home = home
        self.doctor = doctor
        self.logs = logs
        self.pet = pet
        self.voiceCall = voiceCall
        self.callGate = callGate
        self.onboarding = onboarding
        self.settings = settings
        self.companion = companion
    }
}
