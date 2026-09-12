import Foundation
import Testing

@testable import FermixAppCore

/// The bounded Setup Assistant machine: the eight screens of M34 §4 and the
/// three-part finish gate.
///
/// Every assertion here is about a transition, not a view: the machine is a
/// value, so the whole journey is provable without a window server, a daemon, or
/// a socket.
@Suite("Onboarding machine")
struct OnboardingMachineTests {
    /// Readiness that clears the whole gate.
    private var ready: OnboardingReadiness {
        OnboardingReadiness(daemonLive: true)
    }

    @Test("the assistant has exactly the eight screens M34 names")
    func theEightStages() {
        #expect(
            OnboardingStage.allCases == [
                .welcome, .starting, .connectAI, .aboutYou, .applying, .ready, .bootFailed, .recovery
            ]
        )
        #expect(OnboardingStage.starting.isMechanical)
        #expect(OnboardingStage.applying.isMechanical)
        #expect(!OnboardingStage.connectAI.isMechanical)
    }

    @Test("a fresh machine starts on Welcome")
    func startsOnWelcome() {
        #expect(OnboardingMachine().stage == .welcome)
    }

    @Test("the Welcome action begins Starting at its first row")
    func welcomeBeginsActivation() {
        var machine = OnboardingMachine()

        machine.apply(.begin)

        #expect(machine.stage == .starting)
        #expect(machine.activation == .registering)
    }

    @Test("activation progress moves the ladder without changing the stage")
    func activationProgressTracksTheLadder() {
        var machine = OnboardingMachine()
        machine.apply(.begin)

        machine.apply(.activationProgressed(.answering))

        #expect(machine.activation == .answering)
        #expect(machine.stage == .starting)
    }

    /// Four rows, not three. Row four is what makes an upgrade land on Ready
    /// rather than re-asking a configured home.
    @Test("the Starting ladder carries exactly the four provable rows")
    func startingLadderRows() throws {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationProgressed(.starting))

        let ladder = try #require(machine.ladder(restartRequired: false))

        #expect(ladder.rows.map(\.id) == ["service", "daemon", "answering", "reading"])
        #expect(ladder.rows.map(\.state) == [.done, .active, .pending, .pending])
        #expect(ladder.headline == ProductStrings[.startingTitle])
    }

    @Test("the Applying ladder carries its two rows while a restart is required")
    func applyingLadderRows() throws {
        var machine = OnboardingMachine(readiness: OnboardingReadiness(daemonLive: true))
        machine.apply(.resume(.applying))
        machine.apply(.applyingProgressed(.restarting))

        let ladder = try #require(machine.ladder(restartRequired: true))

        #expect(ladder.rows.map(\.id) == ["saving", "restarting"])
        #expect(ladder.rows.map(\.state) == [.done, .active])
        #expect(ladder.headline == ProductStrings[.applyingTitle])
    }

    /// A home that needs no restart is shown the one step it takes. The row it
    /// used to draw sat pending until the screen left, which reads as a step
    /// that never finished rather than one that never happened.
    @Test("the Applying ladder drops the restart row when no restart is required")
    func applyingLadderWithoutARestart() throws {
        var machine = OnboardingMachine(readiness: OnboardingReadiness(daemonLive: true))
        machine.apply(.resume(.applying))

        let ladder = try #require(machine.ladder(restartRequired: false))

        #expect(ladder.rows.map(\.id) == ["saving"])
        #expect(ladder.rows.map(\.state) == [.active])
    }

    /// The daemon stops requiring a restart the moment it takes one, so the
    /// row that is running has to survive its own reason going away.
    @Test("a restart under way keeps its row after the requirement clears")
    func applyingKeepsARunningRestartRow() throws {
        var machine = OnboardingMachine(readiness: OnboardingReadiness(daemonLive: true))
        machine.apply(.resume(.applying))
        machine.apply(.applyingProgressed(.restarting))

        let ladder = try #require(machine.ladder(restartRequired: false))

        #expect(ladder.rows.map(\.id) == ["saving", "restarting"])
        #expect(ladder.rows.map(\.state) == [.done, .active])
    }

    @Test("only a mechanical stage draws a ladder")
    func laddersAreMechanicalOnly() {
        for stage in OnboardingStage.allCases {
            var machine = OnboardingMachine()
            machine.apply(.resume(stage))

            #expect((machine.ladder(restartRequired: true) != nil) == stage.isMechanical, "\(stage.rawValue)")
        }
    }

    // MARK: - Where a finished boot lands

    @Test("no provider lands on Connect your AI")
    func noProviderLandsOnConnect() {
        var machine = OnboardingMachine()
        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, gaps: [.provider])))
        machine.apply(.begin)

        machine.apply(.activationSucceeded)

        #expect(machine.stage == .connectAI)
    }

    @Test("blank personalization lands on About you")
    func blankPersonalizationLandsOnAboutYou() {
        var machine = OnboardingMachine()
        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, gaps: [.personalization])))
        machine.apply(.begin)

        machine.apply(.activationSucceeded)

        #expect(machine.stage == .aboutYou)
    }

    /// M34 §15.2: a home the daemon already reports as configured is not asked
    /// anything again.
    @Test("a configured home lands straight on Ready")
    func configuredHomeLandsOnReady() {
        var machine = OnboardingMachine()
        machine.apply(.readinessChanged(ready))
        machine.apply(.begin)

        machine.apply(.activationSucceeded)

        #expect(machine.stage == .ready)
    }

    @Test("a home that only needs a restart lands on Applying, which takes it")
    func restartOnlyLandsOnApplying() {
        var machine = OnboardingMachine()
        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, restartRequired: true)))
        machine.apply(.begin)

        machine.apply(.activationSucceeded)

        #expect(machine.stage == .applying)
    }

    /// An N-1 daemon can answer nothing above `hello`, so the first decision
    /// screen is where the app says so (M34 §7.1).
    @Test("a daemon one release behind lands on Connect your AI with the named state")
    func newerEngineLandsOnConnect() {
        var machine = OnboardingMachine()
        machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, requiresNewerEngine: true)))
        machine.apply(.begin)

        machine.apply(.activationSucceeded)

        #expect(machine.stage == .connectAI)
        #expect(machine.readiness.block == .requiresNewerEngine)
    }

    /// Every one of the causes replaces Starting and keeps the cause, so the
    /// sentence the user reads is the one the failure earned.
    @Test("every boot-failure cause replaces Starting and is preserved", arguments: BootFailureCause.allCases)
    func failureReplacesStarting(cause: BootFailureCause) {
        var machine = OnboardingMachine()
        machine.apply(.begin)

        machine.apply(.activationFailed(cause, evidence: []))

        #expect(machine.stage == .bootFailed)
        #expect(machine.failure == cause)
        #expect(machine.progress == nil, "the boot-failure screen carries no progress dots")
    }

    @Test("retrying a failed activation returns to Starting and clears the cause")
    func retryClearsTheFailure() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationFailed(.crashLoop, evidence: []))

        machine.apply(.retryActivation)

        #expect(machine.stage == .starting)
        #expect(machine.activation == .registering)
        #expect(machine.failure == nil)
    }

    // MARK: - The journey between the decision screens

    @Test("Connect your AI advances to About you, which advances to Applying")
    func decisionScreensAdvanceInOrder() {
        var machine = OnboardingMachine(stage: .connectAI, readiness: ready)

        machine.apply(.advance)
        #expect(machine.stage == .aboutYou)

        machine.apply(.advance)
        #expect(machine.stage == .applying)
        #expect(machine.applying == .saving)
    }

    /// Owner decision of 2026-09-04: connecting an AI is the one required
    /// decision, so nothing walks past this screen without it. Advancing used
    /// to reach About you and Applying, where the finish gate refused for the
    /// provider that was never connected and landed back here: Connect your AI,
    /// About you, Applying, Connect your AI.
    @Test("Connect your AI refuses to advance while the provider gap stands")
    func connectAIRefusesToWalkOnWithoutAProvider() {
        var machine = OnboardingMachine(
            stage: .connectAI,
            readiness: OnboardingReadiness(daemonLive: true, gaps: [.provider])
        )

        machine.apply(.advance)

        #expect(machine.stage == .connectAI)
        #expect(machine.blocked == .providerRequired)
    }

    /// And the refusal is not a latch: the sign-in that answers the decision
    /// publishes readiness, and the same click then advances.
    @Test("answering the decision lets the same advance through")
    func connectAIAdvancesOnceTheProviderIsAnswered() {
        var machine = OnboardingMachine(
            stage: .connectAI,
            readiness: OnboardingReadiness(daemonLive: true, gaps: [.provider])
        )
        machine.apply(.advance)

        machine.apply(.readinessChanged(ready))
        machine.apply(.advance)

        #expect(machine.stage == .aboutYou)
        #expect(machine.blocked == nil)
    }

    /// A gap belonging to another screen is not this screen's gate: only the
    /// one decision this screen exists for holds it shut.
    @Test("a gap belonging to another screen does not hold Connect your AI shut")
    func connectAIAdvancesOverAnotherScreensGap() {
        var machine = OnboardingMachine(
            stage: .connectAI,
            readiness: OnboardingReadiness(daemonLive: true, gaps: [.personalization])
        )

        machine.apply(.advance)

        #expect(machine.stage == .aboutYou)
    }

    /// Back exists on the one screen with somewhere to go. Going back over
    /// Starting would re-run activation, which is not what Back means.
    @Test("Back is offered on About you and nowhere else")
    func backIsAboutYouOnly() {
        for stage in OnboardingStage.allCases {
            var machine = OnboardingMachine(stage: stage)

            #expect(machine.canGoBack == (stage == .aboutYou), "\(stage.rawValue)")

            machine.apply(.back)
            #expect(machine.stage == (stage == .aboutYou ? .connectAI : stage), "\(stage.rawValue)")
        }
    }

    @Test("no screen offers a skip: the one required decision cannot be deferred")
    func noScreenSkips() throws {
        let machine = try SourceTree.swiftFiles(matching: "Onboarding/OnboardingMachine.swift")
        let text = try #require(machine.first?.text)

        #expect(!text.contains("canSkip"))
    }

    // MARK: - The three-part finish gate

    @Test("the gate holds only with a live daemon, no gating failure, and no pending restart")
    func gateIsThreeParts() {
        #expect(ready.canFinish)
        #expect(!OnboardingReadiness(daemonLive: false).canFinish)
        #expect(!OnboardingReadiness(daemonLive: true, gaps: [.provider]).canFinish)
        #expect(!OnboardingReadiness(daemonLive: true, restartRequired: true).canFinish)
        #expect(!OnboardingReadiness(daemonLive: true, requiresNewerEngine: true).canFinish)
    }

    @Test("the refusal names the missing half in the order the gate checks it")
    func blockNamesTheMissingHalf() {
        #expect(OnboardingReadiness(daemonLive: false).block == .daemonNotLive)
        #expect(OnboardingReadiness(daemonLive: true, requiresNewerEngine: true).block == .requiresNewerEngine)
        #expect(OnboardingReadiness(daemonLive: true, gaps: [.provider]).block == .providerRequired)
        #expect(OnboardingReadiness(daemonLive: true, gaps: [.personalization]).block == .personalizationRequired)
        #expect(
            OnboardingReadiness(daemonLive: true, gaps: [.elsewhere(.channels)]).block
                == .settingsElsewhere(.channels)
        )
        #expect(OnboardingReadiness(daemonLive: true, restartRequired: true).block == .restartPending)
        #expect(ready.block == nil)

        // The newer-engine sentence has one owner, `SettingsState`, and it is
        // passed in: which of its two states this is depends on the build
        // comparison, and a block that looked the sentence up itself offered a
        // restart that brings the same engine back.
        let newerEngine = "the sentence the settings model owns"
        for block in [
            OnboardingBlock.daemonNotLive, .requiresNewerEngine, .providerRequired,
            .personalizationRequired, .settingsElsewhere(.channels), .restartPending
        ] {
            #expect(!block.message(newerEngine: newerEngine).isEmpty, "\(block)")
        }
        #expect(OnboardingBlock.requiresNewerEngine.message(newerEngine: newerEngine) == newerEngine)
    }

    /// A gating failure on a pane the assistant has no screen for keeps that
    /// pane, and the block resolves it to the route that opens it. Folding it
    /// onto Connect your AI asked for something that was not missing, and the
    /// sentence alone was a dead end (M34 §3.4).
    @Test("a gap the assistant cannot clear carries the pane that can")
    func elsewhereGapCarriesItsPane() {
        let block = OnboardingReadiness(daemonLive: true, gaps: [.elsewhere(.channels)]).block

        #expect(block?.pane == .channels)
        #expect(OnboardingBlock.providerRequired.pane == nil)
        #expect(OnboardingGap.elsewhere(.channels).stage == nil)

        // And it lands on Ready, which is the screen that states the block and
        // now carries the way into the pane.
        var machine = OnboardingMachine(
            stage: .starting,
            readiness: OnboardingReadiness(daemonLive: true, gaps: [.elsewhere(.channels)])
        )
        machine.apply(.activationSucceeded)

        #expect(machine.stage == .ready)
    }

    @Test("Applying reaches Ready once every part of the gate holds")
    func applyingReachesReady() {
        var machine = OnboardingMachine(stage: .applying, readiness: OnboardingReadiness(daemonLive: true))

        machine.apply(.applyingFinished)

        #expect(machine.stage == .ready)
        #expect(machine.blocked == nil)
    }

    /// A gap with a screen sends the person to that screen: leaving them on a
    /// finished ladder with a sentence would be a dead end.
    @Test("a gating gap after Applying returns to the screen that clears it")
    func applyingReturnsToTheBlockingScreen() {
        var machine = OnboardingMachine(
            stage: .applying,
            readiness: OnboardingReadiness(daemonLive: true, gaps: [.provider])
        )

        machine.apply(.applyingFinished)

        #expect(machine.stage == .connectAI)
        #expect(machine.blocked == .providerRequired)
    }

    /// A pending restart has no screen of its own, so Applying keeps it and the
    /// sheet asks (M34 §5.10, §14 decision 11).
    @Test("a pending restart keeps Applying and names the block")
    func applyingKeepsAPendingRestart() {
        var machine = OnboardingMachine(
            stage: .applying,
            readiness: OnboardingReadiness(daemonLive: true, restartRequired: true)
        )

        machine.apply(.applyingFinished)

        #expect(machine.stage == .applying)
        #expect(machine.blocked == .restartPending)
    }

    /// Readiness arriving after the refusal clears it: the block is a fact about
    /// the last attempt, not a latch.
    @Test("readiness arriving after a refusal clears the block")
    func readinessClearsTheBlock() {
        var machine = OnboardingMachine(stage: .applying)
        machine.apply(.applyingFinished)
        #expect(machine.blocked == .daemonNotLive)

        machine.apply(.readinessChanged(ready))

        #expect(machine.blocked == nil)
    }

    // MARK: - Readiness from the wire

    /// The gating split is the daemon's, read off `setup.state.get`: Swift gains
    /// no second definition of ready (M34 §4).
    @Test("readiness is read from the daemon's own setup state")
    func readinessFromSetupState() throws {
        let state = try ManagementValueFixture.setupState()
        let readiness = OnboardingReadiness(state: state)

        #expect(readiness.daemonLive)
        // The golden home has its provider connected and its own description
        // missing, so the gate is the personalization one and the advisory is a
        // channel that is switched on with nothing to answer with.
        #expect(readiness.gaps == [.personalization])
        #expect(readiness.advisory == [.channels])
        #expect(readiness.restartRequired)
        #expect(!readiness.canFinish)
    }

    @Test("a readiness failure's pane names the screen that clears it")
    func gapsMapOntoScreens() {
        #expect(OnboardingGap(pane: .providers) == .provider)
        #expect(OnboardingGap(pane: .personality) == .personalization)
        #expect(OnboardingGap(pane: .channels) == .elsewhere(.channels))

        #expect(OnboardingGap.provider.stage == .connectAI)
        #expect(OnboardingGap.personalization.stage == .aboutYou)
        #expect(OnboardingGap.elsewhere(.channels).stage == nil)
    }

    /// A live daemon is `daemonLive`'s fact and nothing else's: the gate reads
    /// it before it looks at a gap, so a gap can never spell it a second way.
    @Test("a dead daemon is not one of the gaps")
    func daemonLivenessIsNotAGap() {
        let readiness = OnboardingReadiness(daemonLive: false, gaps: [], restartRequired: false)

        #expect(!readiness.canFinish)
        #expect(readiness.block == .daemonNotLive)
        #expect(readiness.gaps.isEmpty)
    }

    // MARK: - Progress

    /// Four dots, not eight: the two mechanical stages inherit the step they run
    /// inside, and the two failure screens carry none.
    @Test("the dots count four steps and the mechanical stages inherit one")
    func progressDots() {
        let expected: [OnboardingStage: Int?] = [
            .welcome: 0, .starting: 0, .connectAI: 1, .aboutYou: 2,
            .applying: 2, .ready: 3, .bootFailed: nil, .recovery: nil
        ]

        #expect(OnboardingStage.progressStepCount == 4)
        for stage in OnboardingStage.allCases {
            var machine = OnboardingMachine()
            machine.apply(.resume(stage))

            guard let index = expected[stage] ?? nil else {
                #expect(machine.progress == nil, "\(stage.rawValue)")
                continue
            }

            #expect(machine.progress == ProgressDotsModel(total: 4, activeIndex: index), "\(stage.rawValue)")
        }
    }

    @Test("recovery carries no progress dots and can be entered from anywhere")
    func recoveryFromAnywhere() {
        for start in OnboardingStage.allCases {
            var machine = OnboardingMachine(stage: start)

            machine.apply(.enterRecovery)

            #expect(machine.stage == .recovery, "from \(start.rawValue)")
            #expect(machine.progress == nil)
        }
    }

    /// The one screen a resume does not land on as asked. A refusal that stands
    /// has to be read, and the ladder the resume used to draw had nothing
    /// running behind it: the model refuses to re-run activation over an
    /// unresolved failure, so the four rows sat at `registering` with no way
    /// off the screen (owner report of 2026-09-04).
    @Test("resuming at Starting over an unresolved refusal lands on Boot failed")
    func resumeOverAFailureLandsOnTheCard() {
        var machine = OnboardingMachine()
        machine.apply(.begin)
        machine.apply(.activationFailed(.notInApplications, evidence: []))

        machine.apply(.resume(.starting))

        #expect(machine.stage == .bootFailed)
        #expect(machine.failure == .notInApplications, "the cause the card names is kept")
        #expect(machine.ladder(restartRequired: false) == nil)
    }

    /// And the same resume with nothing outstanding is still the ladder: the
    /// refusal is what redirects it, never the screen's name.
    @Test("resuming at Starting with no refusal outstanding is still the ladder")
    func resumeWithoutAFailureIsTheLadder() {
        var machine = OnboardingMachine()

        machine.apply(.resume(.starting))

        #expect(machine.stage == .starting)
        #expect(machine.ladder(restartRequired: false) != nil)
    }

    /// Starting is the one screen whose way out is stopping what runs on it,
    /// rather than stepping back over a decision.
    @Test("only the Starting ladder offers a cancel")
    func onlyStartingOffersCancel() {
        for stage in OnboardingStage.allCases {
            var machine = OnboardingMachine()
            machine.apply(.resume(stage))

            #expect(machine.canCancel == (stage == .starting), "\(stage.rawValue)")
        }
    }

    /// A route names a screen and the machine goes there, which is what
    /// `fermix://setup` resolves to (M34 §3.4).
    @Test("a resumed screen is the screen the machine shows")
    func resumeOpensTheNamedScreen() {
        for stage in OnboardingStage.allCases {
            var machine = OnboardingMachine()

            machine.apply(.resume(stage))

            #expect(machine.stage == stage, "\(stage.rawValue)")
        }
    }
}
