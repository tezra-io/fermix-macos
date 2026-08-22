import Foundation

/// The three provable activation states, in order. They are the only rows the
/// ladder draws, because they are the only three the app can prove happened.
public enum ActivationStage: Int, CaseIterable, Sendable {
    case registering = 0
    case starting = 1
    case preparing = 2
}

/// What the daemon says about this install, as onboarding needs it.
///
/// M34 §5: Ready requires a live compatible daemon and at least one configured
/// provider. A messaging channel is optional, and stays optional here.
public struct OnboardingReadiness: Equatable, Sendable {
    public var daemonLive: Bool
    public var providerConfigured: Bool
    public var channelConfigured: Bool

    public init(
        daemonLive: Bool = false,
        providerConfigured: Bool = false,
        channelConfigured: Bool = false
    ) {
        self.daemonLive = daemonLive
        self.providerConfigured = providerConfigured
        self.channelConfigured = channelConfigured
    }

    /// Read from the daemon's own projection, so Home and onboarding cannot
    /// disagree about whether setup is complete.
    public init(overview: ManagementOverview, daemonLive: Bool) {
        self.daemonLive = daemonLive
        providerConfigured = (overview.provider.active?.isEmpty == false)
        channelConfigured = overview.channels.contains { $0.enabled }
    }

    public var canFinish: Bool { daemonLive && providerConfigured }
}

/// Why an advance to Ready was refused. It is a fact about the last attempt,
/// not a latch: readiness arriving afterwards clears it.
public enum OnboardingBlock: String, Equatable, Sendable {
    case daemonNotLive
    case providerRequired

    public var message: String {
        switch self {
        case .daemonNotLive: return ProductStrings[.onboardingBlockedDaemon]
        case .providerRequired: return ProductStrings[.onboardingBlockedProvider]
        }
    }
}

/// Everything that can move onboarding along.
public enum OnboardingEvent: Equatable, Sendable {
    /// The Welcome CTA.
    case begin
    case activationProgressed(ActivationStage)
    case activationSucceeded
    case activationFailed(BootFailureCause)
    case retryActivation
    case openHostedSetup
    case closeHostedSetup
    /// Move to the next step, or skip an optional one. Both are the same
    /// transition: the step is either passable or it is not.
    case advance
    case readinessChanged(OnboardingReadiness)
    case enterRecovery
}

/// The bounded onboarding state machine.
///
/// It is a value with no clock, no socket, and no window, so the whole journey
/// — including all eight failure causes and the provider gate — is provable
/// without any of them. The model drives it; the views only draw it.
public struct OnboardingMachine: Equatable, Sendable {
    public private(set) var stage: OnboardingStage
    public private(set) var activation: ActivationStage
    public private(set) var failure: BootFailureCause?
    public private(set) var readiness: OnboardingReadiness
    public private(set) var blocked: OnboardingBlock?
    /// The step the hosted Setup was opened from, so closing it returns there
    /// rather than guessing.
    private var setupOrigin: OnboardingStage?

    public init(stage: OnboardingStage = .welcome, readiness: OnboardingReadiness = OnboardingReadiness()) {
        self.stage = stage
        self.activation = .registering
        self.readiness = readiness
    }

    public mutating func apply(_ event: OnboardingEvent) {
        switch event {
        case .begin, .retryActivation:
            startActivation()
        case .activationProgressed(let reached):
            activation = reached
        case .activationSucceeded:
            failure = nil
            stage = .configureAI
        case .activationFailed(let cause):
            failure = cause
            stage = .bootFailed
        case .openHostedSetup:
            openHostedSetup()
        case .closeHostedSetup:
            closeHostedSetup()
        case .advance:
            advance()
        case .readinessChanged(let updated):
            readiness = updated
            blocked = nil
        case .enterRecovery:
            stage = .recovery
        }
    }

    // MARK: - Derived

    /// The ladder card: the three rows and the headline that tracks the active
    /// one.
    public var ladder: ProgressLadderModel {
        ProgressLadderModel.activation(activeIndex: activation.rawValue)
    }

    public var progress: ProgressDotsModel? {
        guard let index = stage.progressIndex else { return nil }

        return ProgressDotsModel(total: OnboardingStage.progressStepCount, activeIndex: index)
    }

    // MARK: - Transitions

    private mutating func startActivation() {
        stage = .activate
        activation = .registering
        failure = nil
    }

    private mutating func openHostedSetup() {
        guard stage != .configureSetup else { return }

        setupOrigin = stage
        stage = .configureSetup
    }

    private mutating func closeHostedSetup() {
        guard stage == .configureSetup else { return }

        stage = setupOrigin ?? .configureAI
        setupOrigin = nil
    }

    private mutating func advance() {
        switch stage {
        case .configureAI:
            stage = .configureChannel
        case .configureChannel:
            finish()
        case .configureSetup:
            closeHostedSetup()
        case .welcome, .activate, .bootFailed, .ready, .recovery:
            return
        }
    }

    /// The one gate: a live compatible daemon and a configured provider. The
    /// refusal names which half is missing rather than disabling a button with
    /// no explanation.
    private mutating func finish() {
        guard readiness.daemonLive else {
            blocked = .daemonNotLive
            return
        }
        guard readiness.providerConfigured else {
            blocked = .providerRequired
            return
        }

        blocked = nil
        stage = .ready
    }
}
