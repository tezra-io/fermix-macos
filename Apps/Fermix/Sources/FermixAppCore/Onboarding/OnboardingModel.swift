import Foundation

/// Onboarding's narrow model.
///
/// It owns the machine, drives activation, and reads readiness from the daemon.
/// It decides nothing the machine can decide and holds nothing the surfaces can
/// derive.
@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public private(set) var machine = OnboardingMachine()
    @Published public private(set) var cliPlan: CLILinkPlan
    @Published public private(set) var cliInstalled = false
    @Published public var cliSelected = CLILinkPlanner.startsChecked
    /// The last log lines the boot-failure card draws. Empty until a failure
    /// has something to show.
    @Published public private(set) var failureLogLines: [String] = []

    public let setup: SetupModel

    private let gateway: any DaemonQuerying
    private let activation: any ActivationDriving
    private let planner: CLILinkPlanner
    private let route: (AppRoute) -> Void
    private let recoveryResolved: () -> Void
    private let log = AppLog.logger(.app)
    private var activationTask: Task<Void, Never>?

    public init(
        gateway: any DaemonQuerying,
        activation: any ActivationDriving,
        setup: SetupModel,
        planner: CLILinkPlanner,
        onRoute: @escaping (AppRoute) -> Void,
        onRecoveryResolved: @escaping () -> Void
    ) {
        self.gateway = gateway
        self.activation = activation
        self.setup = setup
        self.planner = planner
        self.route = onRoute
        self.recoveryResolved = onRecoveryResolved
        self.cliPlan = planner.plan()
    }

    public var stage: OnboardingStage { machine.stage }
    public var ladder: ProgressLadderModel { machine.ladder }
    public var progress: ProgressDotsModel? { machine.progress }
    public var blocked: OnboardingBlock? { machine.blocked }

    /// The boot-failure card, built from the cause the activation earned.
    public var failurePanel: ErrorPanelModel? {
        machine.failure.map { ErrorPanelModel.bootFailure($0, logLines: failureLogLines) }
    }

    // MARK: - The journey

    public func begin() {
        machine.apply(.begin)
        startActivation()
    }

    /// Try again is the user asking the app to get back to a working state, so
    /// it resolves whatever recovery record is outstanding before running
    /// anything: a transaction refuses to start over an unresolved one.
    public func retry() {
        recoveryResolved()
        machine.apply(.retryActivation)
        startActivation()
    }

    public func advance() {
        machine.apply(.advance)
    }

    public func openHostedSetup() {
        machine.apply(.openHostedSetup)
    }

    public func closeHostedSetup() {
        machine.apply(.closeHostedSetup)
        Task { await refreshReadiness() }
    }

    public func enterRecovery() {
        machine.apply(.enterRecovery)
    }

    /// The Ready action. Onboarding is finished when the user leaves it, not
    /// when a flag says so: readiness is the only completion signal, and Home
    /// reads the same one.
    public func finish() {
        route(.home)
    }

    /// The boot-failure card's primary action. Doctor answers from the running
    /// daemon, so on a daemon that never started it reports exactly that, which
    /// is more use than a screen that only says the start failed.
    public func openDoctor() {
        route(.doctor)
    }

    /// The boot-failure card's secondary action: the daemon's own rotated log,
    /// bounded, rather than a folder in the Finder.
    public func openLogs() {
        route(.logs)
    }

    /// Reads readiness from the daemon's own projection, so Home and onboarding
    /// cannot disagree about whether setup is complete.
    public func refreshReadiness() async {
        do {
            let overview = try await gateway.overview()
            machine.apply(.readinessChanged(OnboardingReadiness(overview: overview, daemonLive: true)))
        } catch {
            log.error("readiness unavailable: \(ManagementMessage.sentence(for: error), privacy: .public)")
            machine.apply(.readinessChanged(OnboardingReadiness()))
        }
    }

    // MARK: - CLI row

    public func refreshCLIPlan() {
        cliPlan = planner.plan()
        cliInstalled = planner.verify()
    }

    /// The one admin moment: a command the user copies and runs. No privileged
    /// helper is involved, so the app's part ends at the clipboard and resumes
    /// at the verification.
    public func copyCLICommand() {
        guard case .available(let command, _) = cliPlan else { return }

        Clipboard.write(command)
    }

    // MARK: - Activation

    private func startActivation() {
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await self.activation.activate { [weak self] stage in
                self?.machine.apply(.activationProgressed(stage))
            }

            switch outcome {
            case .activated:
                self.machine.apply(.activationSucceeded)
                await self.refreshReadiness()
            case .failed(let cause):
                self.machine.apply(.activationFailed(cause))
                await self.loadFailureLogLines()
            }
        }
    }

    /// The last lines the daemon can still show. A daemon that never started
    /// has none, and the card draws the cause without them rather than
    /// inventing filler.
    private func loadFailureLogLines() async {
        do {
            let page = try await gateway.queryLogs(
                ManagementLogsQuery(limit: ErrorPanelModel.logLineCount, direction: .backward)
            )
            failureLogLines = page.entries.map(\.message)
        } catch {
            failureLogLines = []
        }
    }

    /// Lets a caller observe the activation this model started and forgot.
    public func drainPendingWork() async {
        await activationTask?.value
    }
}
