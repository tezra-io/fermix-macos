import Foundation
import Testing

@testable import FermixAppCore

/// The bounded onboarding machine: Welcome, Activate, Configure, Ready, and
/// Recovery, plus the boot-failure state that replaces Activate.
///
/// Every assertion here is about a transition, not a view: the machine is a
/// value, so the whole journey is provable without a window server, a daemon,
/// or a web view.
@Suite("Onboarding machine")
struct OnboardingMachineTests {
    @Test("a fresh machine starts on Welcome")
    func startsOnWelcome() {
        #expect(OnboardingMachine().stage == .welcome)
    }

    @Test("the Welcome action begins activation at its first stage")
    func welcomeBeginsActivation() {
        var machine = OnboardingMachine()

        machine.apply(.begin)

        #expect(machine.stage == .activate)
        #expect(machine.activation == .registering)
    }

    @Test("activation progress moves the ladder without changing the stage")
    func activationProgressTracksTheLadder() {
        var machine = OnboardingMachine()
        machine.apply(.begin)

        machine.apply(.activationProgressed(.starting))
        #expect(machine.activation == .starting)
        #expect(machine.stage == .activate)

        machine.apply(.activationProgressed(.preparing))
        #expect(machine.activation == .preparing)
    }

    /// The ladder is the redline's three provable states, and the headline
    /// tracks the active one.
    @Test("the ladder carries exactly the three provable rows")
    func ladderRows() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationProgressed(.starting))

        let ladder = machine.ladder

        #expect(ladder.rows.map(\.id) == ["service", "daemon", "setup"])
        #expect(ladder.rows.map(\.state) == [.done, .active, .pending])
        #expect(ladder.headline == ProductStrings[.activateHeadlineStarting])
    }

    @Test("a successful activation lands on the first configure surface")
    func successLandsOnConfigure() {
        var machine = OnboardingMachine()
        machine.apply(.begin)

        machine.apply(.activationSucceeded)

        #expect(machine.stage == .configureAI)
        #expect(machine.failure == nil)
    }

    /// Every one of the eight causes replaces Activate with the boot-failure
    /// surface and keeps the cause, so the sentence the user reads is the one
    /// the failure earned.
    @Test("every boot-failure cause replaces Activate and is preserved", arguments: BootFailureCause.allCases)
    func failureReplacesActivate(cause: BootFailureCause) {
        var machine = OnboardingMachine()
        machine.apply(.begin)

        machine.apply(.activationFailed(cause))

        #expect(machine.stage == .bootFailed)
        #expect(machine.failure == cause)
        #expect(machine.progress == nil, "the boot-failure surface carries no progress dots")
    }

    @Test("retrying a failed activation returns to Activate and clears the cause")
    func retryClearsTheFailure() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationFailed(.crashLoop))

        machine.apply(.retryActivation)

        #expect(machine.stage == .activate)
        #expect(machine.activation == .registering)
        #expect(machine.failure == nil)
    }

    // MARK: - Configure

    @Test("the hosted Setup opens over a configure step and returns to it")
    func hostedSetupReturnsToItsOrigin() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationSucceeded)
        machine.apply(.advance)
        #expect(machine.stage == .configureChannel)

        machine.apply(.openHostedSetup)
        #expect(machine.stage == .configureSetup)

        machine.apply(.closeHostedSetup)
        #expect(machine.stage == .configureChannel)
    }

    /// M34 §5: Ready requires a live compatible daemon and at least one
    /// configured provider. A channel stays optional.
    @Test("Ready is refused until a provider is configured")
    func readyRequiresAProvider() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationSucceeded)
        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, providerConfigured: false)))
        machine.apply(.advance)

        machine.apply(.advance)

        #expect(machine.stage == .configureChannel)
        #expect(machine.blocked == .providerRequired)
    }

    @Test("Ready is refused while the daemon is not live")
    func readyRequiresALiveDaemon() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationSucceeded)
        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: false, providerConfigured: true)))
        machine.apply(.advance)

        machine.apply(.advance)

        #expect(machine.stage == .configureChannel)
        #expect(machine.blocked == .daemonNotLive)
    }

    @Test("a configured provider reaches Ready with no channel at all")
    func channelIsOptional() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationSucceeded)
        machine.apply(
            .readinessChanged(
                OnboardingReadiness(daemonLive: true, providerConfigured: true, channelConfigured: false)
            )
        )

        machine.apply(.advance)
        machine.apply(.advance)

        #expect(machine.stage == .ready)
        #expect(machine.blocked == nil)
    }

    /// Readiness arriving after the refusal clears it: the block is a fact about
    /// the last attempt, not a latch.
    @Test("readiness arriving after a refusal clears the block")
    func readinessClearsTheBlock() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationSucceeded)
        machine.apply(.advance)
        machine.apply(.advance)
        #expect(machine.blocked == .daemonNotLive)

        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, providerConfigured: true)))

        #expect(machine.blocked == nil)
    }

    // MARK: - Progress

    @Test("the shipped ladder counts five steps and marks the current one")
    func progressDots() {
        var machine = OnboardingMachine()
        #expect(machine.progress == ProgressDotsModel(total: 5, activeIndex: 0))

        machine.apply(.begin)
        #expect(machine.progress == ProgressDotsModel(total: 5, activeIndex: 1))

        machine.apply(.activationSucceeded)
        #expect(machine.progress == ProgressDotsModel(total: 5, activeIndex: 2))

        machine.apply(.advance)
        #expect(machine.progress == ProgressDotsModel(total: 5, activeIndex: 3))

        // The hosted Setup is a surface over the step it was opened from, so it
        // does not advance the dots.
        machine.apply(.openHostedSetup)
        #expect(machine.progress == ProgressDotsModel(total: 5, activeIndex: 3))
    }

    @Test("recovery carries no progress dots and can be entered from anywhere")
    func recoveryFromAnywhere() {
        for start in [OnboardingStage.welcome, .activate, .configureAI, .ready] {
            var machine = OnboardingMachine(stage: start)

            machine.apply(.enterRecovery)

            #expect(machine.stage == .recovery, "from \(start.rawValue)")
            #expect(machine.progress == nil)
        }
    }

    /// Closing onboarding does not complete it: nothing about the machine marks
    /// the journey done, and Home shows `Setup required` from the same readiness.
    @Test("readiness alone decides completion, and an incomplete setup says so")
    func completionComesFromReadiness() {
        let incomplete = OnboardingReadiness(daemonLive: true, providerConfigured: false)
        let complete = OnboardingReadiness(daemonLive: true, providerConfigured: true)

        #expect(!incomplete.canFinish)
        #expect(complete.canFinish)
    }

    @Test("readiness is read from the daemon's own overview")
    func readinessFromOverview() throws {
        let configured = try ManagementValueFixture.overview()
        let unconfigured = try ManagementValueFixture.overview(provider: nil, channelEnabled: false)

        #expect(
            OnboardingReadiness(overview: configured, daemonLive: true)
                == OnboardingReadiness(daemonLive: true, providerConfigured: true, channelConfigured: true)
        )
        #expect(
            OnboardingReadiness(overview: unconfigured, daemonLive: true)
                == OnboardingReadiness(daemonLive: true, providerConfigured: false, channelConfigured: false)
        )
    }
}
