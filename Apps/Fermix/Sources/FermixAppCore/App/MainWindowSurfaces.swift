import Foundation

/// The five surfaces, built once and handed to the windows that draw them.
///
/// They are assembled here rather than inside the views so each one keeps a
/// single instance across route changes: a Doctor run and a Logs page survive
/// the user visiting Home and coming back, and nothing re-mints a Setup session
/// because a view redrew.
@MainActor
public final class MainWindowSurfaces {
    public let home: HomeModel
    public let setup: SetupModel
    public let doctor: DoctorModel
    public let logs: LogsModel
    public let pet: PetFeatureModel
    public let onboarding: OnboardingModel
    public let version: String

    public init(
        home: HomeModel,
        setup: SetupModel,
        doctor: DoctorModel,
        logs: LogsModel,
        pet: PetFeatureModel,
        onboarding: OnboardingModel,
        version: String
    ) {
        precondition(!version.isEmpty, "the sidebar footer shows the running version")

        self.home = home
        self.setup = setup
        self.doctor = doctor
        self.logs = logs
        self.pet = pet
        self.onboarding = onboarding
        self.version = version
    }
}
