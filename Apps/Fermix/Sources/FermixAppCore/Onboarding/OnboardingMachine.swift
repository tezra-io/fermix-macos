import Foundation

/// The four provable rows of the Starting ladder, in order (M34 §4).
///
/// They are the only rows the ladder draws, because they are the only four the
/// app can prove happened. Row four is what makes an upgrade land on Ready
/// rather than re-asking a home that is already configured.
public enum ActivationStage: Int, CaseIterable, Sendable {
    case registering = 0
    case starting = 1
    case answering = 2
    case reading = 3
}

/// The two rows of the Applying ladder (M34 §4).
public enum ApplyingStage: Int, CaseIterable, Sendable {
    case saving = 0
    case restarting = 1
}

/// One gap that stops the assistant finishing, and the screen that clears it.
///
/// The daemon publishes which pane a readiness failure belongs to (M34 §3.4), so
/// the mapping is over the pane and never over a status word. A gating failure
/// on a pane the assistant has no screen for is preserved rather than folded
/// onto a neighbour: it routes to that Settings pane instead.
/// A live daemon is not one of these: `daemonLive` is the one owner of that
/// fact, and the gate reads it before it looks at a gap at all.
public enum OnboardingGap: Equatable, Sendable {
    case provider
    case personalization
    case elsewhere(ManagementSettingsPane)

    /// The assistant screen that can clear this gap, where there is one.
    public var stage: OnboardingStage? {
        switch self {
        case .provider: return .connectAI
        case .personalization: return .aboutYou
        case .elsewhere: return nil
        }
    }

    /// The gap a readiness failure names, read from the pane the daemon gave it.
    public init(pane: ManagementSettingsPane) {
        switch pane {
        case .providers: self = .provider
        case .personality: self = .personalization
        default: self = .elsewhere(pane)
        }
    }
}

/// What the daemon says about this install, as the assistant's finish gate
/// needs it (M34 §4).
///
/// Three parts, not one: a live daemon, no gating readiness failure, and no
/// pending restart. Advisory failures are carried alongside rather than mixed
/// in, because Ready renders them as one line and never as a block.
public struct OnboardingReadiness: Equatable, Sendable {
    public var daemonLive: Bool
    /// The gating failures, in the daemon's own order.
    public var gaps: [OnboardingGap]
    /// The advisory failures' panes, in the daemon's own order.
    public var advisory: [ManagementSettingsPane]
    public var restartRequired: Bool
    /// The daemon is one release behind the bundle, so `setup.state.get` refused
    /// and nothing above can be read at all (M34 §7.1).
    public var requiresNewerEngine: Bool

    public init(
        daemonLive: Bool = false,
        gaps: [OnboardingGap] = [],
        advisory: [ManagementSettingsPane] = [],
        restartRequired: Bool = false,
        requiresNewerEngine: Bool = false
    ) {
        self.daemonLive = daemonLive
        self.gaps = gaps
        self.advisory = advisory
        self.restartRequired = restartRequired
        self.requiresNewerEngine = requiresNewerEngine
    }

    /// Read from `setup.state.get`, which is the one answer Home, the Settings
    /// window and the assistant all read (M34 §4).
    public init(state: ManagementSetupState, daemonLive: Bool = true) {
        self.daemonLive = daemonLive
        self.gaps = state.readiness.failures.filter(\.gating).map { OnboardingGap(pane: $0.pane) }
        self.advisory = state.readiness.failures.filter { !$0.gating }.map(\.pane)
        self.restartRequired = state.restart.required
        self.requiresNewerEngine = false
    }

    /// The three-part gate. `finish()` refuses unless all three hold.
    public var canFinish: Bool {
        daemonLive && !requiresNewerEngine && gaps.isEmpty && !restartRequired
    }

    /// Which half is missing, in the order the gate checks them. Nil once the
    /// gate holds.
    public var block: OnboardingBlock? {
        guard daemonLive else { return .daemonNotLive }
        guard !requiresNewerEngine else { return .requiresNewerEngine }

        if let gap = gaps.first {
            switch gap {
            case .provider: return .providerRequired
            case .personalization: return .personalizationRequired
            case .elsewhere(let pane): return .settingsElsewhere(pane)
            }
        }

        return restartRequired ? .restartPending : nil
    }
}

/// Why an advance was refused, whether off Connect your AI or on to Ready. It
/// is a fact about the last attempt, not a latch: readiness arriving afterwards
/// clears it.
public enum OnboardingBlock: Equatable, Sendable {
    case daemonNotLive
    case requiresNewerEngine
    case providerRequired
    case personalizationRequired
    /// A gating failure on a pane the assistant has no screen for. It carries
    /// the pane the daemon named, because the sentence on its own was a dead
    /// end: the screen said something in Settings still needed an answer and
    /// nothing on it could open the pane that holds the answer (M34 §3.4).
    case settingsElsewhere(ManagementSettingsPane)
    case restartPending

    /// - Parameter newerEngine: the one sentence `SettingsState` owns for a
    ///   daemon that cannot serve the panes. It is passed in rather than looked
    ///   up here, because which of its two states this is depends on the build
    ///   comparison — a restart that finishes an update, or an app ahead of the
    ///   engine it ships — and this value cannot see it. Offering the restart
    ///   in the second state brings the same engine back.
    public func message(newerEngine: String) -> String {
        switch self {
        case .daemonNotLive: return ProductStrings[.onboardingBlockedDaemon]
        case .requiresNewerEngine: return newerEngine
        case .providerRequired: return ProductStrings[.onboardingBlockedProvider]
        case .personalizationRequired: return ProductStrings[.onboardingBlockedPersonalization]
        case .settingsElsewhere: return ProductStrings[.onboardingBlockedSettings]
        case .restartPending: return ProductStrings[.onboardingBlockedRestart]
        }
    }

    /// The Settings pane this block sends the person to, where it names one.
    ///
    /// Nil for a pane this build does not know, which is a gating failure from
    /// a newer engine: the app never invents a route for a value it cannot
    /// resolve, and the sentence still says what happened.
    public var pane: SettingsPane? {
        guard case .settingsElsewhere(let published) = self else { return nil }

        return SettingsPane.pane(for: published)
    }
}

/// Everything that can move the assistant along.
public enum OnboardingEvent: Equatable, Sendable {
    /// The Welcome CTA.
    case begin
    case activationProgressed(ActivationStage)
    case activationSucceeded
    /// The refusal, and the facts on this Mac its own sentence names.
    case activationFailed(BootFailureCause, evidence: [String])
    case retryActivation
    case applyingProgressed(ApplyingStage)
    /// Applying finished its two rows, so the finish gate runs.
    case applyingFinished
    /// The new About you answers were refused, even if the old ones were valid.
    case personalizationRefused
    /// Move to the next step, or skip an optional one. Both are the same
    /// transition: the step is either passable or it is not.
    case advance
    case back
    case readinessChanged(OnboardingReadiness)
    /// A route named a screen to resume at (M34 §3.4).
    case resume(OnboardingStage)
    case enterRecovery
}

/// The bounded Setup Assistant state machine.
///
/// It is a value with no clock, no socket, and no window, so the whole journey —
/// eight screens, every failure cause, and the three-part finish gate — is
/// provable without any of them. The model drives it; the views only draw it.
public struct OnboardingMachine: Equatable, Sendable {
    public private(set) var stage: OnboardingStage
    /// Which steps the activation behind Starting runs, so the ladder draws the
    /// rows that transaction actually takes and no others.
    public let activationPlan: ActivationPlan
    public private(set) var activation: ActivationStage
    public private(set) var applying: ApplyingStage
    public private(set) var failure: BootFailureCause?
    /// What the refusal found: the copies, the journal path and its reason.
    public private(set) var failureEvidence: [String] = []
    public private(set) var readiness: OnboardingReadiness
    public private(set) var blocked: OnboardingBlock?

    public init(
        stage: OnboardingStage = .welcome,
        readiness: OnboardingReadiness = OnboardingReadiness(),
        activationPlan: ActivationPlan = .installed
    ) {
        self.stage = stage
        self.activationPlan = activationPlan
        self.activation = activationPlan.firstStage
        self.applying = .saving
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
            failureEvidence = []
            stage = landingAfterActivation()
        case .activationFailed(let cause, let evidence):
            failure = cause
            failureEvidence = evidence
            stage = .bootFailed
        case .applyingProgressed(let reached):
            applying = reached
        case .applyingFinished:
            finish()
        case .personalizationRefused:
            stage = .aboutYou
            blocked = nil
        case .advance:
            advance()
        case .back:
            goBack()
        case .readinessChanged(let updated):
            readiness = updated
            blocked = nil
        case .resume(let stage):
            resume(at: stage)
        case .enterRecovery:
            stage = .recovery
        }
    }

    // MARK: - Derived

    /// The ladder the current mechanical stage draws, or nil on a stage that
    /// draws none.
    ///
    /// - Parameter restartRequired: what the daemon reports right now, which is
    ///   the one fact this value has no way to know: the machine has no socket.
    ///   Applying draws its restart row when a restart is required or once one
    ///   is under way — the second half matters because the daemon stops
    ///   requiring a restart the moment it takes one, and the row that is
    ///   running must not vanish out from under the person watching it.
    public func ladder(restartRequired: Bool) -> ProgressLadderModel? {
        switch stage {
        case .starting:
            return .starting(
                activeIndex: activationPlan.rowIndex(of: activation),
                includesRegistration: activationPlan.registersLoginItems
            )
        case .applying:
            return .applying(
                activeIndex: applying.rawValue,
                includesRestart: restartRequired || applying == .restarting
            )
        default:
            return nil
        }
    }

    public var progress: ProgressDotsModel? {
        guard let index = stage.progressIndex else { return nil }

        return ProgressDotsModel(total: OnboardingStage.progressStepCount, activeIndex: index)
    }

    /// Whether the bottom bar draws Back. Only About you has somewhere to go:
    /// Starting already ran, and going back over it would re-run activation.
    public var canGoBack: Bool { stage == .aboutYou }

    /// Whether the bottom bar offers the way off the ladder.
    ///
    /// Starting is the one screen with no decision on it and a 90-second
    /// transaction behind it, so the only thing a person can ask for while it
    /// runs is to stop. Without it a ladder that is not running is a dead end:
    /// the owner's only way out on 2026-09-04 was to close the window.
    public var canCancel: Bool { stage == .starting }

    // MARK: - Transitions

    private mutating func startActivation() {
        stage = .starting
        activation = activationPlan.firstStage
        failure = nil
        failureEvidence = []
    }

    /// Where a finished boot lands (M34 §15.2): a configured home goes straight
    /// to Ready, a home with no provider to Connect your AI, one with blank
    /// personalization to About you, and one that only needs a restart to
    /// Applying, which is the screen that takes it.
    private func landingAfterActivation() -> OnboardingStage {
        // An N-1 daemon can answer nothing above `hello`, so the first decision
        // screen is where the app says so and offers the restart (M34 §7.1).
        guard !readiness.requiresNewerEngine else { return .connectAI }

        // The first gap with a screen. A gap the assistant has no screen for
        // used to land on Connect your AI, which asked for something that was
        // not missing; it lands on Ready instead, where the block names the
        // pane and offers the way into it (M34 §3.4).
        if let landing = readiness.gaps.compactMap(\.stage).first { return landing }
        if !readiness.gaps.isEmpty { return .ready }

        return readiness.restartRequired ? .applying : .ready
    }

    private mutating func advance() {
        switch stage {
        case .connectAI:
            // Owner decision of 2026-09-04: connecting an AI is the one
            // required decision, so nothing walks past this screen without it.
            // Advancing used to reach About you and Applying, where the finish
            // gate refused for the provider that was never connected and landed
            // back here: Connect your AI, About you, Applying, Connect your AI.
            // The way on without answering it is leaving the assistant, which
            // the model owns.
            guard !readiness.gaps.contains(.provider) else {
                blocked = .providerRequired
                return
            }

            stage = .aboutYou
        case .aboutYou:
            applying = .saving
            stage = .applying
        case .welcome, .starting, .applying, .ready, .bootFailed, .recovery:
            return
        }
    }

    /// Where a resumed route actually lands (M34 §3.4).
    ///
    /// A resume at Starting while a refusal stands lands on Boot failed
    /// instead. The refusal is what the person has to read, and the ladder the
    /// resume used to draw had nothing running behind it: the model refuses to
    /// re-run activation over an unresolved failure, so the four rows sat at
    /// `registering` forever with no way off the screen.
    private mutating func resume(at requested: OnboardingStage) {
        guard requested == .starting, failure != nil else {
            stage = requested
            return
        }

        stage = .bootFailed
    }

    private mutating func goBack() {
        guard canGoBack else { return }

        stage = .connectAI
    }

    /// The three-part gate of M34 §4: the daemon is live, no gating readiness
    /// failure remains, and no restart is pending. The refusal names the missing
    /// half rather than disabling a button with no explanation.
    private mutating func finish() {
        guard readiness.canFinish else {
            blocked = readiness.block
            // A gap with a screen sends the person to that screen: leaving them
            // on a finished ladder with a sentence would be a dead end. A
            // pending restart has no screen of its own, so Applying keeps it and
            // asks (M34 §5.10).
            if let landing = readiness.gaps.compactMap(\.stage).first { stage = landing }
            return
        }

        blocked = nil
        stage = .ready
    }
}
