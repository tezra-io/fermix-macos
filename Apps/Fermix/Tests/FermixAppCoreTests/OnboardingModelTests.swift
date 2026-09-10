import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// The Setup Assistant's model: the journey as it actually runs, with
/// activation, the daemon, the file dialog and the restart behind seams.
@Suite("Onboarding model")
@MainActor
struct OnboardingModelTests {
    @Test("beginning runs activation and lands on the screen the daemon's readiness names")
    func beginActivates() async throws {
        let harness = try OnboardingHarness()

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.activation.runs == 1)
        // The golden setup state's one gating failure is the personalization
        // one, which is the About you screen.
        #expect(harness.model.stage == .aboutYou)
    }

    /// Activation's stages reach the ladder, so the headline the user reads is
    /// the one the transaction actually got to.
    @Test("the ladder follows activation's reported stages")
    func ladderFollowsActivation() async throws {
        let harness = try OnboardingHarness()
        harness.activation.reportedStages = [.registering, .starting, .answering, .reading]
        // A failed run keeps the assistant on a stage that draws the ladder, so
        // the rows it reached are still readable.
        harness.activation.outcome = .failed(.timedOut)

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.machine.activation == .reading)
    }

    @Test("a failed activation shows its cause and the last log lines")
    func failureShowsItsCause() async throws {
        let harness = try OnboardingHarness()
        harness.activation.outcome = .failed(.bindFailure)
        harness.gateway.logPages = [
            try ManagementValueFixture.logPage(messages: ["one", "two", "three", "four"])
        ]

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.stage == .bootFailed)
        #expect(harness.model.failurePanel?.body == ProductStrings.bootFailure(.bindFailure))
        #expect(harness.model.failurePanel?.logLines == ["two", "three", "four"])
    }

    /// A daemon that never started has no lines to show, and the card carries
    /// the cause without inventing filler.
    @Test("a failure with no readable log still draws its cause")
    func failureWithoutLogs() async throws {
        let harness = try OnboardingHarness()
        harness.activation.outcome = .failed(.crashLoop)
        harness.gateway.logsFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.failurePanel?.logLines.isEmpty == true)
        #expect(harness.model.failurePanel?.body == ProductStrings.bootFailure(.crashLoop))
    }

    /// The two halves of the owner's stuck ladder (2026-09-04): the refusal has
    /// to draw its card, and the next `fermix://setup` has to land on that card
    /// rather than on four rows with nothing running behind them.
    @Test("a refused activation draws the card, and resuming again keeps it there")
    func refusalDrawsTheCardOnEveryResume() async throws {
        let harness = try OnboardingHarness()
        harness.activation.outcome = .failed(.notInApplications, evidence: [])

        harness.model.resume(at: .starting)
        await harness.model.drainPendingWork()

        #expect(harness.model.stage == .bootFailed)
        #expect(harness.model.ladder == nil, "the card replaces the ladder")
        #expect(harness.model.failurePanel?.body == ProductStrings.bootFailure(.notInApplications))

        harness.model.resume(at: .starting)
        await harness.model.drainPendingWork()

        #expect(harness.model.stage == .bootFailed)
        #expect(harness.activation.runs == 1, "nothing re-ran over the unresolved refusal")
    }

    /// The way off the ladder. Activation is one bounded transaction with no
    /// decision on it, and the owner's only way out of a Starting screen that
    /// was not running was to close the window.
    @Test("cancelling Starting cancels the activation and returns to Home")
    func cancelStartingStopsActivation() async throws {
        let harness = try OnboardingHarness()
        harness.activation.blocksUntilCancelled = true

        harness.model.begin()
        await harness.settle()
        #expect(harness.model.stage == .starting)

        harness.model.cancelStarting()
        await harness.model.drainPendingWork()

        #expect(harness.activation.cancelled, "the activation task was cancelled")
        #expect(harness.routes == [.surface(.home)])
        // A cancellation is not a refusal the person has to read: they asked to
        // leave, so no boot-failure card is drawn behind them.
        #expect(harness.model.stage == .starting)
        #expect(harness.model.failurePanel == nil)
    }

    /// Cancel belongs to the ladder alone, so a stray call from anywhere else
    /// neither routes nor cancels.
    @Test("cancelling from a screen that is not Starting does nothing")
    func cancelIsStartingOnly() async throws {
        let harness = try OnboardingHarness()

        harness.model.resume(at: .aboutYou)
        harness.model.cancelStarting()

        #expect(harness.routes.isEmpty)
        #expect(harness.model.stage == .aboutYou)
    }

    /// Doctor answers from the running daemon, so it is the useful next step
    /// even when the daemon never started.
    @Test("the boot-failure actions route to Doctor and Logs")
    func failureActionsRoute() async throws {
        let harness = try OnboardingHarness()

        harness.model.openDoctor()
        harness.model.openLogs()
        harness.model.finish()

        #expect(harness.routes == [.surface(.doctor), .surface(.logs), .surface(.home)])
    }

    /// Ready's next steps are deep links into the Settings window, which is the
    /// one place a day-2 setting lives (M34 §4).
    @Test("the next steps deep-link into Settings")
    func nextStepsOpenSettings() throws {
        let harness = try OnboardingHarness()

        harness.model.open(.settings(.channels))
        harness.model.open(.settings(.voice))

        #expect(harness.routes == [.settings(.channels), .settings(.voice)])
    }

    // MARK: - Readiness

    /// Readiness comes off `setup.state.get` through the one settings model, so
    /// Home, the Settings window and the assistant cannot disagree (M34 §8).
    @Test("readiness is read through the one settings model")
    func readinessFromSettings() async throws {
        let harness = try OnboardingHarness()

        await harness.model.refreshReadiness()

        #expect(harness.gateway.calls.contains(.v2(.setupStateGet)))
        #expect(harness.model.readiness.daemonLive)
        #expect(harness.model.readiness.gaps == [.personalization])
        #expect(!harness.model.readiness.canFinish)
    }

    /// A daemon that cannot answer is not a configured one. Readiness falls to
    /// nothing rather than keeping the last good answer, which would let Ready
    /// open on a daemon that has since died.
    @Test("an unreachable daemon reads as not ready")
    func unreachableDaemonIsNotReady() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.v2Failure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        await harness.model.refreshReadiness()

        #expect(!harness.model.readiness.canFinish)
        #expect(harness.model.readiness.block == .daemonNotLive)
    }

    /// M34 §7.1: an N-1 daemon refuses every v2 method, and that is a named
    /// state with one action rather than an error.
    @Test("a daemon one release behind reads as the newer-engine state")
    func n1DaemonIsANamedState() async throws {
        let harness = try OnboardingHarness(n1: true)

        await harness.model.refreshReadiness()

        #expect(harness.model.readiness.requiresNewerEngine)
        #expect(harness.model.readiness.block == .requiresNewerEngine)
    }

    /// A home that already answers shows the already-connected form, and the
    /// one link on it re-opens the decision *here*. The Providers pane it used
    /// to open lives in the other window, and the two windows are exclusive, so
    /// that link shut the assistant mid-journey with nothing said about where
    /// it had gone.
    @Test("Change provider re-opens the rows on this screen rather than a pane")
    func changeProviderStaysInTheAssistant() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(failures: false)

        harness.model.resume(at: .connectAI)
        await harness.model.refreshReadiness()
        #expect(harness.model.alreadyConnected?.id == "openai_codex")

        harness.model.changeProvider()

        #expect(harness.model.alreadyConnected == nil, "the rows did not come back")
        #expect(harness.routes.isEmpty, "the assistant routed away from itself")
    }

    /// Row four's reads are folded into the shared model rather than made twice.
    @Test("what Starting read is adopted rather than re-asked")
    func rowFourIsAdopted() async throws {
        let harness = try OnboardingHarness()

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.settings.setupState.value != nil)
        #expect(harness.model.settings.detections.value != nil)
        #expect(!harness.gateway.calls.contains(.v2(.setupStateGet)), "the assistant re-read what it was handed")
    }

    /// A refusal of row four is carried rather than swallowed: the daemon is up,
    /// and the screen states what it said.
    @Test("a refused fourth row is stated on the screen")
    func rowFourRefusalIsStated() async throws {
        let harness = try OnboardingHarness()
        harness.activation.prepared = ActivationPreparation(refusal: "The daemon refused.")

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.preparationRefusal == "The daemon refused.")
    }

    // MARK: - Applying

    @Test("restart-only entry runs once and preserves existing personalization", arguments: [true, false])
    func restartOnlyEntryRunsWithoutSaving(fromActivation: Bool) async throws {
        let harness = try OnboardingHarness()
        let pending = try ManagementValueFixture.setupState(failures: false)
        harness.gateway.setupStateResult = pending
        await harness.model.refreshReadiness()
        harness.activation.prepared = ActivationPreparation(state: pending)
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(
            failures: false, restartRequired: false
        )

        if fromActivation {
            harness.model.begin()
        } else {
            harness.model.resume(at: .applying)
        }
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 1)
        #expect(harness.gateway.appliedSettings.isEmpty)
        #expect(harness.model.stage == .ready)
    }

    @Test("a refused restart-only entry stays recoverable without saving personalization")
    func restartOnlyRefusalOffersRetry() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(failures: false)
        harness.restarter.refusal = ProductStrings[.lifecycleDaemonNotManaged]
        await harness.model.refreshReadiness()

        harness.model.resume(at: .applying)
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 1)
        #expect(harness.gateway.appliedSettings.isEmpty)
        #expect(harness.model.stage == .applying)
        #expect(harness.model.offersRestart)
        #expect(harness.model.restartRefusal == ProductStrings[.lifecycleDaemonNotManaged])
    }

    @Test("a refused replacement of valid personalization never completes onboarding")
    func refusedReplacementStaysOnAboutYou() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(
            failures: false, restartRequired: false
        )
        await harness.model.refreshReadiness()
        harness.gateway.v2Failures[.settingsApply] = ManagementRefusal.daemon(.externalChange, "Save refused.")
        harness.model.answers.name = "Updated name"

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        #expect(harness.model.stage == .aboutYou)
        #expect(harness.model.answers.name == "Updated name")
        #expect(harness.restarter.restarts == 0)
        #expect(harness.model.settings.message(for: SettingsDraftKey(
            section: AboutYouAnswers.personalizationSection, key: AboutYouAnswers.nameKey
        )) == "Save refused.")
    }

    /// A refused save lands the person back on About you, and the screen says
    /// why.
    ///
    /// It used to return them to a form that looked exactly as they left it,
    /// having been told nothing: `machine.blocked` was set and the row sentence
    /// was recorded, and `AboutYouSurface` read neither. The same invisible
    /// refusal the owner met on Connect your AI.
    @Test("a refused About you save says why, on About you")
    func aboutYouShowsARefusedSave() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.v2Failures[.settingsApply] = ManagementRefusal.daemon(
            .externalChange,
            "The settings file changed outside Fermix."
        )
        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        let key = SettingsDraftKey(
            section: AboutYouAnswers.personalizationSection,
            key: AboutYouAnswers.nameKey
        )
        let sentence = try #require(harness.model.settings.message(for: key))

        #expect(sentence == "The settings file changed outside Fermix.")
        #expect(harness.model.stage == .aboutYou)
        #expect(harness.restarter.restarts == 0)
        #expect(
            AboutYouAnswers.prefilled().personalizationValues.keys.contains(key.key),
            "the sentence is read under a key this form actually writes"
        )
    }

    /// One write, into the one section the daemon publishes for all four keys.
    ///
    /// The assistant's name is `personalization.bot_name`, under the label the
    /// Personality pane shows. It used to go to an `agent` section that does not
    /// exist on the wire: the daemon answered `invalid_params {field: section}`,
    /// the refusal was recorded under a row no assistant screen reads, and Ready
    /// landed as if the name had been saved.
    @Test("Applying writes personalization and the assistant name")
    func applyingWritesBothSections() async throws {
        let harness = try OnboardingHarness()
        harness.model.answers = AboutYouAnswers(
            name: "Sam",
            timezone: "Europe/Berlin",
            style: .concise,
            assistantName: "Fermix"
        )

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        let sections = harness.gateway.appliedSettings.map(\.section)
        #expect(sections == [AboutYouAnswers.personalizationSection])
        #expect(
            harness.gateway.appliedSettings.first?.values == [
                "user_name": .text("Sam"),
                "timezone": .text("Europe/Berlin"),
                "communication_style": .text(AssistantStyle.concise.sentence),
                "bot_name": .text("Fermix")
            ]
        )
    }

    /// Decision 11: a fresh install with nothing in flight restarts without
    /// asking.
    @Test("Applying restarts without asking when nothing is in flight")
    func applyingRestartsWhenIdle() async throws {
        let harness = try OnboardingHarness()

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 1)
        #expect(!harness.model.restartSheetPresented)
    }

    /// Anything in flight asks first, because a restart that interrupts a turn
    /// without saying so is exactly what the sheet exists to prevent.
    @Test("Applying asks first when a conversation is in flight")
    func applyingAsksWhenBusy() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.overviewResult = try ManagementValueFixture.overview(activeConversations: 1)

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 0)
        #expect(harness.model.restartSheetPresented)
    }

    /// An unanswered count is not a report that the daemon is quiet.
    @Test("Applying asks first when the count cannot be read")
    func applyingAsksWhenTheCountIsUnknown() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.overviewFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 0)
        #expect(harness.model.restartSheetPresented)
    }

    /// A provable row must never claim a step that did not happen: a home the
    /// daemon says needs no restart never enters the restarting row.
    @Test("Applying enters the restarting row only when a restart is taken")
    func applyingLadderFollowsTheRestart() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(
            failures: false,
            restartRequired: false
        )

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 0)
        #expect(harness.model.machine.applying == .saving)
    }

    /// A restart that was asked for and refused is stated, in the words the
    /// refusal earned. Dropping the answer would leave the ladder claiming a
    /// restart the daemon never took, and replacing it with a general sentence
    /// would hide which refusal was read (owner report of 2026-09-04).
    @Test("a restart that did not finish states the refusal's own sentence")
    func applyingStatesARefusedRestart() async throws {
        let harness = try OnboardingHarness()
        harness.restarter.refusal = ProductStrings[.lifecycleDaemonNotManaged]

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 1)
        #expect(harness.model.restartRefusal == ProductStrings[.lifecycleDaemonNotManaged])
    }

    /// A cancelled sheet must not leave Applying with a warning and no action:
    /// the screen offers the restart itself once the gate has refused for one.
    @Test("a cancelled restart leaves Applying offering the restart")
    func applyingOffersTheRestartAfterACancel() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.overviewResult = try ManagementValueFixture.overview(activeConversations: 1)
        // The restart is the only thing left, so the gate can refuse for it
        // rather than for a gap that has its own screen.
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(failures: false)

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()
        #expect(harness.model.restartSheetPresented)

        // Cancel is the sheet's dismiss and nothing else.
        harness.model.restartSheetPresented = false

        #expect(harness.model.stage == .applying)
        #expect(harness.model.blocked == .restartPending)
        #expect(harness.model.offersRestart)
    }

    /// The sheet decides when; the model runs the same journaled transaction the
    /// automatic path runs.
    @Test("the sheet's restart runs the journaled transaction and closes the sheet")
    func sheetRestartRunsTheTransaction() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.overviewResult = try ManagementValueFixture.overview(activeConversations: 1)

        harness.model.resume(at: .aboutYou)
        harness.model.advance()
        await harness.model.drainPendingWork()

        harness.model.takeRestartFromSheet()
        await harness.model.drainPendingWork()

        #expect(harness.restarter.restarts == 1)
        #expect(!harness.model.restartSheetPresented)
    }

    // MARK: - Connect your AI

    /// A key verb writes to the slot the daemon named in that provider's own
    /// section. Without those sections the row is advertised and permanently
    /// dead, on the one screen the assistant cannot finish without.
    @Test("the key row is performable once a provider's section is read")
    func keyRowIsPerformableOnceSectionsAreRead() async throws {
        let harness = try OnboardingHarness()
        harness.activation.prepared = ActivationPreparation(
            state: try ManagementValueFixture.setupState(keyOnlyProvider: true),
            detections: try ManagementValueFixture.detections()
        )

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.keyTargets.isEmpty, "no slot has been named yet")

        await harness.model.loadProviderSections()

        let target = try #require(harness.model.keyTargets.first { $0.provider == "xai" })
        #expect(!target.secret.isEmpty)
        #expect(harness.gateway.readSections.contains(ProviderRowProjection.sectionId(for: target.provider)))
    }

    /// Connect your AI draws the design's three rows and no more: two vendors,
    /// and the one door to every provider that takes a typed key. Seven
    /// descriptor rows did not fit the fixed 800 by 520 window and pushed the
    /// bottom bar off it (M34 §4).
    @Test("Connect your AI draws the two named vendors and nothing else")
    func connectAIDrawsThreeRows() async throws {
        let harness = try OnboardingHarness()
        harness.activation.prepared = ActivationPreparation(
            state: try FakeDaemonGateway.fixtureResult(named: "setup_state_get", as: ManagementSetupState.self),
            detections: try ManagementValueFixture.detections()
        )

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.model.providers.count > 2, "the daemon publishes more than the assistant draws")
        #expect(harness.model.providerRows.map(\.id) == ProviderRowProjection.assistantProviders)
    }

    /// The seam every assistant surface reads through: the surfaces observe the
    /// onboarding model and read their facts off the settings model, so a change
    /// published there has to reach here. Without it the rows never repaint
    /// after their sections arrive and every key verb stays dead (M34 §8).
    @Test("a change published on the settings model republishes the assistant")
    func settingsChangesReachTheAssistant() async throws {
        let harness = try OnboardingHarness()
        harness.activation.prepared = ActivationPreparation(
            state: try ManagementValueFixture.setupState(keyOnlyProvider: true),
            detections: try ManagementValueFixture.detections()
        )
        harness.model.begin()
        await harness.model.drainPendingWork()

        var republished = 0
        let subscription = harness.model.objectWillChange.sink { _ in republished += 1 }
        defer { subscription.cancel() }

        await harness.model.loadProviderSections()

        #expect(republished > 0, "the sections arrived and nothing told the surface")
        #expect(!harness.model.keyTargets.isEmpty)
    }

    /// The waiting sheet is bound to the settings model's own `signingIn`, so
    /// starting a sign-in has to publish here or the browser opens with nothing
    /// on screen and the row stays `Not connected` forever.
    @Test("starting a sign-in publishes the waiting state on the assistant")
    func startingASignInPublishes() async throws {
        let harness = try OnboardingHarness()
        harness.activation.prepared = ActivationPreparation(
            state: try ManagementValueFixture.setupState(),
            detections: try ManagementValueFixture.detections()
        )
        harness.model.begin()
        await harness.model.drainPendingWork()

        var republished = 0
        let subscription = harness.model.objectWillChange.sink { _ in republished += 1 }
        defer { subscription.cancel() }

        await harness.model.startSignIn(provider: "openai_codex")

        #expect(harness.model.settings.signingInProvider == "openai_codex")
        #expect(republished > 0)
    }

    /// A start the daemon refused is the one the owner clicked into on
    /// 2026-09-04: the engine served `setup.state.get` and not `auth.start`, so
    /// the row did nothing at all. The sentence lands where the screen reads it
    /// and no waiting sheet opens over a flow that never began.
    @Test("a refused sign-in start states the daemon's own sentence")
    func refusedSignInStatesItsSentence() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.v2Failures[.authStart] = ManagementRefusal.daemon(
            .methodNotFound,
            "This daemon does not serve auth.start."
        )
        harness.model.resume(at: .connectAI)

        await harness.model.startSignIn(provider: "openai_codex")

        #expect(harness.model.signIn.failure == "This daemon does not serve auth.start.")
        #expect(harness.model.settings.signingInProvider == nil, "nothing is in flight")
        #expect(harness.opener.urls.isEmpty, "no browser opened for a flow that never started")
    }

    /// The other half of the same click, which is what the owner asked about:
    /// a start the daemon accepts opens the browser at the url it minted.
    @Test("a started sign-in opens the browser at the daemon's authorize url")
    func startedSignInOpensTheBrowser() async throws {
        let harness = try OnboardingHarness()
        let minted = try FakeDaemonGateway.fixtureResult(named: "auth_start", as: ManagementAuthStart.self)
        let authorize = try #require(minted.authorizeURL)

        await harness.model.startSignIn(provider: "openai_codex")
        await harness.model.signIn.drainPendingWork()

        #expect(harness.opener.urls.map(\.absoluteString) == [authorize])
        #expect(harness.model.settings.signingInProvider == "openai_codex")
    }

    /// The sentence is a fact about the last attempt, not a latch: the next
    /// click clears it, so a screen never states a refusal beside a flow that
    /// is running.
    @Test("the refusal clears when the next attempt starts")
    func refusalClearsOnTheNextAttempt() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.v2Failures[.authStart] = ManagementRefusal.daemon(
            .methodNotFound,
            "This daemon does not serve auth.start."
        )
        await harness.model.startSignIn(provider: "openai_codex")
        #expect(harness.model.signIn.failure != nil)

        harness.gateway.v2Failures[.authStart] = nil
        await harness.model.startSignIn(provider: "openai_codex")
        await harness.model.signIn.drainPendingWork()

        #expect(harness.model.signIn.failure == nil)
    }

    /// And walking on is refused for the same reason the link leaves: the
    /// person used to reach About you and Applying, where the finish gate
    /// refused for the provider that was never connected and sent them back
    /// here (owner report of 2026-09-04, "So basically its in the loop").
    @Test("Continue on Connect your AI refuses while no provider is connected")
    func continueRefusesWithoutAProvider() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.providerReadiness = FakeProviderReadiness()
        harness.model.resume(at: .connectAI)
        await harness.model.refreshReadiness()

        harness.model.advance()

        #expect(harness.model.stage == .connectAI)
        #expect(harness.model.blocked == .providerRequired)
    }

    /// And the block clears from the daemon's own next answer, with no second
    /// call to make it true.
    ///
    /// The daemon gates on the PRIMARY provider, and a fresh home has none, so a
    /// sign-in that only stored a session left the gate exactly where it was:
    /// job completes, `setup.state.get` still reports
    /// `provider:missing_credentials:openai` gating, Continue still says
    /// "connect a provider". The engine now promotes the first configured
    /// provider on this door as it always did on the browser one, so the app has
    /// nothing to do but re-read.
    @Test("a finished sign-in clears the provider gate without a second call")
    func signInClearsTheProviderGate() async throws {
        let harness = try OnboardingHarness()
        let daemon = FakeProviderReadiness()
        harness.gateway.providerReadiness = daemon
        harness.model.resume(at: .connectAI)
        await harness.model.refreshReadiness()

        // The loop as reported: Continue refuses, because the daemon gates on a
        // primary provider and this home has none.
        harness.model.advance()

        #expect(harness.model.stage == .connectAI)
        #expect(harness.model.blocked == .providerRequired)

        let runner = harness.model.settings.makeJobRunner()
        _ = await harness.model.settings.startSignIn(provider: "openai_codex", on: runner)
        await runner.drainPendingWork()
        await harness.model.signInFinished()

        #expect(daemon.primaryProvider == "openai_codex", "the daemon promoted what it connected")
        #expect(harness.model.readiness.gaps.isEmpty)
        #expect(harness.model.blocked == nil)
        #expect(
            !harness.gateway.calls.contains(.v2(.providersSetPrimary)),
            "the app never has to make the provider primary itself"
        )

        harness.model.advance()
        #expect(harness.model.stage == .aboutYou)
    }

    /// The other door onto the same gate: a key typed for a provider the daemon
    /// has no primary for. It used to leave the gate standing in exactly the
    /// same way.
    @Test("a stored provider key clears the provider gate without a second call")
    func storedKeyClearsTheProviderGate() async throws {
        let harness = try OnboardingHarness()
        let daemon = FakeProviderReadiness()
        harness.gateway.providerReadiness = daemon
        harness.model.resume(at: .connectAI)
        await harness.model.refreshReadiness()
        harness.model.advance()

        #expect(harness.model.blocked == .providerRequired)

        _ = await harness.model.settings.setSecret(id: "anthropic_api_key", value: "sk-not-real")
        await harness.model.refreshReadiness()

        #expect(daemon.primaryProvider == "anthropic")
        #expect(harness.model.blocked == nil)
        #expect(!harness.gateway.calls.contains(.v2(.providersSetPrimary)))
    }

    /// The gate is the daemon's answer, so a home that already reports one
    /// walks on exactly as before.
    @Test("Continue advances once the daemon reports a provider")
    func continueAdvancesWithAProvider() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(failures: false)
        harness.model.resume(at: .connectAI)
        await harness.model.refreshReadiness()

        harness.model.advance()

        #expect(harness.model.stage == .aboutYou)
        #expect(harness.model.blocked == nil)
    }

    // MARK: - Welcome

    /// The picker writes through the same record writer and the same validator
    /// every other path uses; Swift parses nothing inside the home.
    @Test("a chosen home is recorded through the bootstrap store")
    func chosenHomeIsRecorded() throws {
        let harness = try OnboardingHarness()
        harness.chooser.answer = harness.root.appendingPathComponent("chosen-home", isDirectory: true)

        harness.model.chooseExistingHome()

        #expect(harness.model.homeRefusal == nil)
        #expect(try harness.store.load().fermixHome.path == harness.chooser.answer?.path)
    }

    @Test("a refused home names the path and changes nothing")
    func refusedHomeNamesThePath() throws {
        let harness = try OnboardingHarness()
        harness.chooser.answer = URL(fileURLWithPath: "/", isDirectory: true)

        harness.model.chooseExistingHome()

        #expect(harness.model.homeRefusal?.contains("/") == true)
        #expect(harness.store.condition() == .absent)
    }

    /// The link is offered only when no migration handoff exists: the journal
    /// already answers the question the picker would ask (M34 §15.2).
    @Test("the existing-home link is hidden while a handoff journal exists")
    func pickerIsHiddenBehindAJournal() throws {
        let harness = try OnboardingHarness()
        #expect(harness.model.offersExistingHomePicker)

        try harness.writeHandoff(home: harness.root.appendingPathComponent("journal-home", isDirectory: true))

        #expect(!harness.model.offersExistingHomePicker)
    }

    // MARK: - The CLI row

    @Test("the CLI row starts unchecked and reads the planner")
    func cliRowStartsFromThePlanner() throws {
        let harness = try OnboardingHarness()

        #expect(harness.model.cliSelected == CLILinkPlanner.startsChecked)
        #expect(harness.model.cliPlan.offersCommand)
    }

    /// Try again is the user resolving whatever left the app in recovery, so it
    /// clears the interrupted transaction's record before running anything.
    @Test("try again resolves the recovery record before re-running activation")
    func retryResolvesTheRecoveryRecord() async throws {
        let harness = try OnboardingHarness()

        harness.model.retry()
        await harness.model.drainPendingWork()

        #expect(harness.recoveryResolutions == 1)
        #expect(harness.updateRetries == 0)
    }

    /// An update that did not finish is the one recovery activation cannot
    /// clear: the record is the update's, and registering the agent and
    /// starting the engine over it leaves the same report standing. Try again
    /// re-runs the launch reconcile there instead (M34 §6, R4).
    @Test("try again on an unfinished update re-runs the reconcile rather than activation")
    func retryOnAnUnfinishedUpdateRunsTheReconcile() async throws {
        let harness = try OnboardingHarness()
        harness.updateRecovery.set(
            UpdateRecoveryReport(reason: .targetEngineUnverified, entry: UpdateFixture.entry(phase: .replacing))
        )

        harness.model.retry()
        await harness.model.drainPendingWork()

        #expect(harness.updateRetries == 1)
        #expect(harness.activation.runs == 0)
        #expect(harness.recoveryResolutions == 0, "the lifecycle record is not this recovery's to clear")
    }

    /// About you is prefilled from macOS, so zero typing is a valid answer.
    @Test("About you is prefilled from the account and the system time zone")
    func aboutYouIsPrefilled() {
        let answers = AboutYouAnswers.prefilled(fullName: "Sam Fermi", timezone: "Europe/Berlin")

        #expect(answers.name == "Sam Fermi")
        #expect(answers.timezone == "Europe/Berlin")
        #expect(answers.style == .balanced)
        #expect(!answers.assistantName.isEmpty)
    }

    /// The segmented control shows the word and the daemon stores the sentence,
    /// which is what the prompt seeder actually reads.
    @Test("every style has a word and a stored sentence")
    func styleSentences() {
        for style in AssistantStyle.allCases {
            #expect(!style.title.isEmpty, "\(style.rawValue)")
            #expect(!style.sentence.isEmpty, "\(style.rawValue)")
            #expect(style.sentence != style.title, "\(style.rawValue)")
        }
    }
}

@MainActor
final class OnboardingHarness {
    let root: URL
    let location: BootstrapLocation
    let store: BootstrapStore
    let handoff: MigrationHandoffReader
    let gateway = FakeDaemonGateway()
    let activation = FakeActivationDriver()
    let chooser = FakeDirectoryChooser()
    let restarter = FakeDaemonRestarter()
    let recorder = RouteRecorder()
    /// The system browser, recorded rather than opened, because the sign-in
    /// hop is the assistant's half of the flow.
    let opener = RecordingExternalOpener()
    /// What the launch reconcile found, as a case states it. Recovery reads it
    /// through the same closure the app wires to the coordinator, so a case can
    /// stand an unfinished update in front of the screen without a record on
    /// disk or a daemon behind it.
    let updateRecovery = ValueBox<UpdateRecoveryReport>()
    let model: OnboardingModel

    static let launcherPath = "/Applications/Fermix.app/Contents/MacOS/fermix"

    var routes: [AppDestination] { recorder.routes }
    var recoveryResolutions: Int { recorder.recoveryResolutions }
    var updateRetries: Int { recorder.updateRetries }

    init(n1: Bool = false) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-onboarding-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        location = BootstrapLocation(homeDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BootstrapStore(location: location)
        handoff = MigrationHandoffReader(location: location)

        gateway.hello = try ManagementValueFixture.hello(maximum: n1 ? 1 : nil)
        gateway.overviewResult = try ManagementValueFixture.overview()
        gateway.logPages = [try ManagementValueFixture.logPage(messages: ["a line"])]
        activation.hello = try ManagementValueFixture.hello()
        activation.prepared = ActivationPreparation(
            state: try ManagementValueFixture.setupState(),
            detections: try ManagementValueFixture.detections()
        )

        let recorder = self.recorder
        model = OnboardingModel(
            gateway: gateway,
            activation: activation,
            store: store,
            handoff: handoff,
            chooser: chooser,
            restarter: restarter,
            planner: CLILinkPlanner(
                launcherPath: OnboardingHarness.launcherPath,
                // The bundle ships the launcher the command links to; with no
                // launcher there is nothing to offer.
                inspector: StubLinkInspector(files: [OnboardingHarness.launcherPath])
            ),
            updateRecovery: { [updateRecovery] in updateRecovery.value },
            onRoute: { destination in recorder.record(destination) },
            onRecoveryResolved: { recorder.recordRecoveryResolved() },
            onRetryUpdateRecovery: { recorder.recordUpdateRetry() },
            settings: SettingsFixture.model(gateway: gateway, opener: opener),
            sleeper: NoWaitSleeper()
        )
    }

    /// Writes a handoff journal the way `fermix migrate-to-app` would.
    func writeHandoff(home: URL) throws {
        try FileManager.default.createDirectory(at: location.directoryURL, withIntermediateDirectories: true)
        try Data(
            """
            {"schema_version": 1, "fermix_home": "\(home.path)"}
            """.utf8
        ).write(to: handoff.journalURL)
    }

    /// Lets any main-actor continuation the model started run, without a
    /// wall-clock wait.
    func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    deinit {
        let path = root.path
        guard path.contains("fermix-onboarding-tests"), path.split(separator: "/").count >= 4 else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Records the destinations the assistant asked the app to open.
@MainActor
final class RouteRecorder {
    private(set) var routes: [AppDestination] = []
    private(set) var recoveryResolutions = 0
    private(set) var updateRetries = 0

    func record(_ destination: AppDestination) {
        routes.append(destination)
    }

    func recordRecoveryResolved() {
        recoveryResolutions += 1
    }

    func recordUpdateRetry() {
        updateRetries += 1
    }
}

/// The directory dialog, scripted. No test ever raises an `NSOpenPanel`.
@MainActor
final class FakeDirectoryChooser: DirectoryChoosing {
    var answer: URL?
    private(set) var prompts: [String] = []

    func chooseDirectory(prompt: String) -> URL? {
        prompts.append(prompt)
        return answer
    }
}

/// The journaled restart, counted rather than run.
@MainActor
final class FakeDaemonRestarter: DaemonRestarting {
    private(set) var restarts = 0
    /// The sentence a refusal answers with, or nil where the restart worked.
    var refusal: String?

    func restartDaemonAwaitingCompletion() async -> String? {
        restarts += 1
        return refusal
    }
}

/// Activation, scripted. It reports whatever stages a test names and ends in
/// whatever outcome the test chose, so the model's half of the journey is
/// provable without a daemon, a socket, or a login item.
@MainActor
final class FakeActivationDriver: ActivationDriving {
    /// How many yields the blocking mode waits for a cancellation before giving
    /// up, so a test that never cancels fails rather than hangs.
    static let cancellationPolls = 1_000

    var plan: ActivationPlan = .installed
    private(set) var runs = 0
    /// Whether the run this driver was asked for was cancelled under it, which
    /// is the only way to observe what a cancelled activation leaves behind.
    private(set) var cancelled = false

    var outcome: ActivationOutcome?
    var reportedStages: [ActivationStage] = []
    var hello: ManagementHello?
    var prepared = ActivationPreparation()
    /// Waits for the task to be cancelled instead of answering, the way a real
    /// activation sits in its bounded socket wait.
    var blocksUntilCancelled = false

    func activate(progress: @escaping (ActivationStage) -> Void) async -> ActivationOutcome {
        runs += 1

        for stage in reportedStages {
            progress(stage)
        }

        if blocksUntilCancelled { return await waitForCancellation() }
        if let outcome { return outcome }
        guard let hello else { return .failed(.invalidPackage) }

        return .activated(hello, prepared: prepared)
    }

    /// The outcome a cancelled bounded wait actually produces: the sleep throws,
    /// the poll gives up, and the transaction reports it timed out.
    private func waitForCancellation() async -> ActivationOutcome {
        for _ in 0..<Self.cancellationPolls where !Task.isCancelled {
            await Task.yield()
        }

        cancelled = Task.isCancelled
        return .failed(.timedOut)
    }
}

/// The assistant's own anatomy, asserted on the shipped surfaces.
///
/// Owner directive of 2026-09-03: "The onboarding screen needs update. Too many
/// subtexts/headings throws off. doesnt look elegant. The large blue dot feels
/// like slop." What follows is that directive as gates: one title and one line
/// per screen, one text column, and the mascot where the orb was.
@Suite("Assistant anatomy")
struct AssistantAnatomyTests {
    static let surfaces = [
        "Onboarding/OnboardingWindowView.swift",
        "Onboarding/StartingSurface.swift",
        "Onboarding/ConnectAISurface.swift",
        "Onboarding/AboutYouSurface.swift",
        "Onboarding/ReadySurface.swift"
    ]

    /// The orb is gone, and so is everything it needed. A view deleted while
    /// its six palette tokens and its motion role stayed behind is dead weight
    /// that reads as a design still in the product.
    @Test("the activation orb and everything only it used are gone")
    func orbIsGone() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        for needle in ["ActivationOrb", "orbHalo", "orbHighlight", "orbLow", "orbRim", "orbShadow", "orbCoreGlow", ".orbBreath"] {
            let holders = files.filter { $0.text.contains(needle) }.map(\.path)
            #expect(holders.isEmpty, "\(needle) survives in \(holders)")
        }

    }

    @Test("mechanical setup screens use the shared progress column without decorative artwork")
    func mechanicalScreensUseProgress() throws {
        let starting = try SourceTree.swiftFiles(matching: "Onboarding/StartingSurface.swift")
        let text = try #require(starting.first?.text)

        #expect(text.contains("ProgressLadder(model: ladder)"))
        #expect(!text.contains("MascotArtwork("))
        #expect(!text.contains("drawsMascot"))
    }

    /// One row grammar across the three decision screens.
    ///
    /// Connect your AI drew hand-made cards, About you a grouped form and Ready
    /// bare rows plus one hand-drawn card — three container shapes in three
    /// consecutive screens, which read as three designs rather than one
    /// journey. All three are grouped forms now, and the chrome they take is
    /// declared once so they cannot drift apart again.
    @Test("the three decision screens draw one row grammar")
    func oneRowGrammar() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let chrome = files.filter { $0.text.contains("func assistantFormChrome(") }

        #expect(chrome.count == 1, "the assistant's form chrome has \(chrome.count) owners")

        for path in [
            "Onboarding/ConnectAISurface.swift",
            "Onboarding/AboutYouSurface.swift",
            "Onboarding/ReadySurface.swift"
        ] {
            let text = try #require(files.first { $0.path.hasSuffix(path) }?.text, "\(path)")

            #expect(text.contains(".assistantFormChrome("), "\(path) draws a container of its own")
            // No card, hairline or radius drawn by hand: the section is the box.
            #expect(!text.contains("RoundedRectangle(cornerRadius: Radius.card"), "\(path) still draws a card")
            #expect(!text.contains("Palette.cardFill"), "\(path) still fills a card")
        }
    }

    /// One window colour in the app. The assistant painted `base100` under its
    /// whole window while every other window shows the system's, which made
    /// moving between them read as moving between two applications.
    @Test("the assistant paints no ground of its own")
    func theAssistantTakesTheSystemGround() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        let painters = files.filter { $0.text.contains("Palette.base100") }.map(\.path)
        #expect(
            painters.allSatisfy { $0.hasSuffix("Design/Tokens/Palette.swift") },
            "a window paints its own ground: \(painters)"
        )
    }

    /// One text column across the eight screens. A width literal on a surface
    /// is that surface picking its own measure, which is how the assistant came
    /// to read as eight layouts rather than one.
    @Test("every assistant surface measures its text from one place")
    func oneTextColumn() throws {
        for path in Self.surfaces {
            let file = try SourceTree.swiftFiles(matching: path)
            let text = try #require(file.first?.text, "\(path)")
            let literals = ["maxWidth: 4", "maxWidth: 5", "maxWidth: 3"]

            for literal in literals {
                #expect(!text.contains(literal), "\(path) writes its own width: \(literal)")
            }
        }
    }

    /// A refusal the model holds and no screen draws is a dead button: the
    /// waiting sheet the sign-in runner used to be drawn in only opens for a
    /// flow that actually started, so a refused start left the row exactly as
    /// it was (owner report of 2026-09-04).
    ///
    /// Driven through the model rather than read off the view's source: the
    /// value the screen draws is the runner's own failure, and it carries the
    /// daemon's sentence rather than the fixed message its code shares with
    /// every other refusal in the same family.
    @Test("Connect your AI states a refused sign-in beneath its rows")
    @MainActor
    func connectAIStatesARefusedSignIn() async throws {
        let harness = try OnboardingHarness()
        let refusal = try ManagementRefusal.published("invalid_params_with_sentence")
        let sentence = try #require(ManagementMessage.details(of: refusal)?.sentence)
        harness.gateway.v2Failures[.authStart] = refusal
        harness.model.resume(at: .connectAI)

        await harness.model.startSignIn(provider: "anthropic")

        // The screen draws the runner's failure, so the refusal has to reach it
        // rather than being logged and dropped.
        #expect(sentence == "This provider has no browser sign-in.")
        #expect(harness.model.signIn.failure == sentence)
        #expect(harness.model.signIn.failure != "Request parameters are invalid.")
        #expect(!harness.model.signIn.isRunning, "a refused start leaves no flow in progress")
    }

    /// The caption tier is gone from the deck, not just from the views: a key
    /// nothing draws is copy that still has to be translated and reviewed.
    @Test("the retired captions are gone from the copy deck")
    func retiredCopyIsGone() {
        let deck = Set(ProductStringKey.allCases.map(\.rawValue))

        #expect(!deck.contains("welcome.caption"))
        #expect(!deck.contains("ready.nextSection"))
        #expect(!deck.contains("settings.back"))
        // The line Starting still says is the one line that screen is allowed,
        // and it moved up a tier rather than being deleted: it explains a
        // system prompt the operator is about to see.
        #expect(deck.contains("starting.caption"))
    }
}
