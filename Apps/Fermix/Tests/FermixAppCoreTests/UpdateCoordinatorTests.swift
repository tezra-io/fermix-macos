import Foundation
import Testing

@testable import FermixAppCore

/// The update transaction (M34 §6, R3) and what the update surface may say
/// about a check (R2).
///
/// Everything here runs over fake service, clock and updater adapters: the
/// transaction is proved without a framework, a feed, a signature or a bundle
/// to replace, which is exactly what R7 asks the automated half to do. The
/// half it cannot reach is named at the bottom of this file.
@Suite("Update transaction")
@MainActor
struct UpdateCoordinatorTests {
    // MARK: - The veto

    @Test("an update is refused while another owner holds the service")
    func refusedWhileBusy() throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()
        #expect(harness.gate.acquire(.lifecycle))

        #expect(throws: UpdateRefusal.busy(.lifecycle)) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }
    }

    @Test("an update is refused while an interrupted transaction's record is open")
    func refusedWhileRecoveryPending() throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()
        harness.lifecycle.stageInterruptedTransaction(
            LifecycleJournalEntry(
                transactionId: UUID(),
                kind: .disable,
                phase: .mutate,
                originalPid: nil,
                previousRegistration: .enabled,
                startedAt: Date()
            )
        )

        #expect(throws: UpdateRefusal.recoveryPending) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }
    }

    @Test("an update is refused while an earlier update's record is still on disk")
    func refusedWhileUpdateRecordOpen() throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()
        try harness.journals.journal.write(UpdateFixture.entry(phase: .draining))

        #expect(throws: UpdateRefusal.recoveryPending) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }
    }

    /// An unowned daemon is a refusal, never a takeover: stopping something
    /// this account did not register is the one thing M34 §6 forbids outright.
    @Test("an update is refused while a daemon this account does not own is answering")
    func refusedWhileDaemonUnowned() throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()
        harness.ownership.answer = .unowned(.notRegistered)

        #expect(throws: UpdateRefusal.unownedDaemon(.notRegistered)) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }
    }

    @Test("an update is refused while the feed does not describe the release that is installed")
    func refusedWithoutThePriorRelease() throws {
        let harness = try UpdateHarness()
        harness.coordinator.feedLoaded([UpdateFeedFixture.offered])

        #expect(throws: UpdateRefusal.priorReleaseUnknown(build: 1)) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }
    }

    @Test("an update is refused while this bundle ships no readable engine manifest")
    func refusedWithoutABundledEngine() throws {
        let harness = try UpdateHarness(bundledEngine: nil)
        harness.offerAFeed()

        #expect(throws: UpdateRefusal.bundledEngineUnknown) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }
    }

    /// Each required element is named in its own refusal, so an operator
    /// reading the log can fix the appcast rather than guess at it.
    @Test("an entry that declares no target engine is refused", arguments: UpdateFeedElement.required)
    func refusedWithoutTheTargetFacts(element: String) throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()

        #expect(throws: UpdateRefusal.feed(.missingElement(element))) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.entry(dropping: element))
        }
    }

    @Test("an entry that is not newer than the installed build is refused")
    func refusedWhenNotAnUpgrade() throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()

        #expect(throws: UpdateRefusal.notAnUpgrade(installed: 1, offered: 1)) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.entry(versionString: "1"))
        }
    }

    /// A refusal leaves no offer behind: the person is never shown an item the
    /// transaction has already decided it cannot install.
    @Test("a refused update is not left on the update surface")
    func refusalClearsTheOffer() throws {
        let harness = try UpdateHarness()
        harness.offerAFeed()
        harness.coordinator.found(UpdateFeedFixture.offered)
        harness.ownership.answer = .unowned(.requiresApproval)

        #expect(throws: (any Error).self) {
            try harness.coordinator.mayProceed(with: UpdateFeedFixture.offered)
        }

        #expect(harness.coordinator.availability() == .unknown)
    }

    // MARK: - The transaction

    @Test("choosing Install records the transaction and stops the engine")
    func installStopsTheEngine() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        let outcome = harness.coordinator.prepareForReplacement()

        #expect(outcome == .ready)
        #expect(harness.lifecycle.calls == [.disable])
        #expect(harness.loginItems.status(.agent) != .enabled)

        let record = try #require(try harness.journals.journal.load())
        #expect(record.phase == .stopped)
        #expect(record.source.app == UpdateFixture.sourceApp)
        #expect(record.target.app.buildNumber == 2)
        #expect(record.target.engine == UpdateFixture.targetEngine)
        #expect(record.previousRegistration == .enabled)
        #expect(record.priorInstaller.url == UpdateFeedFixture.installedURL)
        #expect(record.rollbackSupported)
        // The process the launch reconcile has to see replaced. Without it,
        // the old daemon answering again would pass for the new one.
        #expect(record.originalPid != nil)
    }

    /// M34 §6: a service that was disabled and stopped keeps both facts. It is
    /// never enabled to complete a check, and there is nothing of ours to
    /// drain.
    @Test("a service that was already disabled is neither drained nor enabled")
    func disabledServiceStaysDisabled() async throws {
        let harness = try UpdateHarness(registration: .notRegistered)
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        let outcome = harness.coordinator.prepareForReplacement()

        #expect(outcome == .ready)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.loginItems.registerCalls.isEmpty)

        let record = try #require(try harness.journals.journal.load())
        #expect(record.phase == .recorded)
        #expect(record.previousRegistration == .notRegistered)
    }

    /// The one refusal that is safe to offer again: the daemon refuses the
    /// lease before anything is mutated.
    @Test("a daemon that is mid-turn defers the drain and is offered it again")
    func busyDaemonIsDeferred() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.disableScript = [.deferredWhileBusy(message: "a turn is running"), nil]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        let outcome = harness.coordinator.prepareForReplacement()

        #expect(outcome == .ready)
        #expect(harness.lifecycle.calls == [.disable, .discardRecovery, .disable])
        #expect(harness.loginItems.status(.agent) != .enabled)
    }

    /// Install is recorded and nothing else: the download can still fail, and
    /// taking the engine away for its whole length would be a mutation nobody
    /// asked for. The transaction begins at the barrier.
    @Test("an Install choice alone changes nothing before the barrier")
    func installAloneChangesNothing() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        await harness.settle()

        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(try harness.journals.journal.load() == nil)
        #expect(harness.gate.holder == nil)
        #expect(harness.coordinator.transactionState == .idle)
    }

    /// The whole deferral budget spent on a daemon that never frees up, with
    /// the update already being extracted. The replacement is inevitable from
    /// here, so the record is kept and the transaction stalls rather than
    /// rolling back into a state nothing recovers.
    @Test("a daemon that stays busy at the barrier stalls and keeps its record")
    func busyAtTheBarrierStalls() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.disableScript = [.deferredWhileBusy(message: "a turn is running")]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        let outcome = harness.coordinator.prepareForReplacement()

        #expect(outcome == .engineStillRunning)
        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(harness.loginItems.unregisterCalls.isEmpty)
        #expect(!harness.lifecycle.calls.contains(.enable))
        #expect(
            harness.lifecycle.calls.filter { $0 == .disable }.count
                == UpdatePolicy.busyDeferral.attempts
        )
        #expect(harness.coordinator.transactionState == .stalled(
            try #require(harness.coordinator.transactionState.transactionId)
        ))

        let record = try #require(try harness.journals.journal.load())
        #expect(record.phase == .draining)
        #expect(record.previousRegistration == .enabled)
    }

    /// A failed unregister is the lifecycle transaction's own rollback: it
    /// cancels the drain and leaves the service enabled. The barrier reports
    /// the engine still running, and the update transaction, once aborted, has
    /// nothing to put back and clears its record without enabling anything.
    @Test("a refused unregister leaves the service enabled and clears the record")
    func refusedUnregisterLeavesTheServiceEnabled() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.disableScript = [
            .registration(.unregistrationFailed(principal: .agent, underlying: "operation not permitted"))
        ]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .engineStillRunning)
        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(try harness.journals.journal.load()?.phase == .draining)

        harness.coordinator.aborted("the archive could not be extracted")
        await harness.settle()

        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(harness.lifecycle.calls == [.disable])
        #expect(try harness.journals.journal.load() == nil)
        #expect(harness.gate.holder == nil)
    }

    /// The lease ran out mid-transaction: the agent is unregistered and the
    /// daemon never exited. The barrier answers that the engine is still
    /// running and the transaction stalls; an extraction that then fails
    /// aborts the cycle, and the registration is the durable state, so it goes
    /// back before anything else.
    @Test("a stop that fails after unregistering stalls, and the abort puts the registration back")
    func failedStopRestoresTheRegistration() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.unregisterOnFailedDisable = true
        harness.lifecycle.disableScript = [.daemonNeverExited(pid: 4242)]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        let outcome = harness.coordinator.prepareForReplacement()

        #expect(outcome == .engineStillRunning)
        #expect(harness.lifecycle.calls == [.disable])
        #expect(harness.loginItems.status(.agent) != .enabled)
        #expect(try harness.journals.journal.load()?.phase == .draining)

        harness.coordinator.aborted("the archive could not be extracted")
        await harness.settle()

        #expect(harness.lifecycle.calls == [.disable, .enable])
        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(try harness.journals.journal.load() == nil)
        #expect(harness.gate.holder == nil)
    }

    /// Nothing is enabled that was not enabled before, whatever fails.
    @Test("a stop that fails on a disabled service enables nothing")
    func failedStopOnADisabledServiceEnablesNothing() async throws {
        let harness = try UpdateHarness(registration: .notRegistered)
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .ready)
        harness.coordinator.aborted("the archive could not be extracted")
        await harness.settle()

        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.loginItems.registerCalls.isEmpty)
        #expect(try harness.journals.journal.load() == nil)
    }

    // MARK: - Undoing it

    @Test(
        "cancel, remind later, skip and a failed download all restore the prior state",
        arguments: [UpdateUndo.dismiss, .skip, .downloadFailed, .downloadCancelled, .aborted]
    )
    func everyCancellationRestoresThePriorState(undo: UpdateUndo) async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .ready)
        #expect(harness.loginItems.status(.agent) != .enabled)

        undo.apply(to: harness.coordinator)
        await harness.settle()

        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(harness.lifecycle.calls == [.disable, .enable])
        #expect(try harness.journals.journal.load() == nil)
        #expect(harness.gate.holder == nil)
        #expect(harness.coordinator.transactionState == .idle)
    }

    /// A restore the account refuses is not claimed as finished: the record
    /// stays on disk, which is what the launch reconcile reads and the only
    /// copy of the prior artifact.
    @Test("a restore macOS refuses keeps the record for the launch reconcile")
    func refusedRestoreKeepsTheRecord() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .ready)

        harness.lifecycle.stageFailure(.registration(
            .registrationFailed(principal: .agent, underlying: "operation not permitted")
        ))
        harness.coordinator.downloadCancelled()
        await harness.settle()

        let record = try #require(try harness.journals.journal.load())
        #expect(record.phase == .stopped)
        #expect(record.priorInstaller.url == UpdateFeedFixture.installedURL)
        #expect(harness.gate.holder == nil)
    }

    // MARK: - Staged, and what that forbids

    /// The updater re-titles Remind Me Later as `Install on Quit` once the
    /// update is staged, so dismissing at that stage is an armed state rather
    /// than a cancellation. Treating it as a cancel would put the old engine
    /// back under a bundle that is about to be replaced.
    @Test("dismissing a staged update is an armed state and never a rollback")
    func dismissingAStagedUpdateIsArmed() async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()

        harness.coordinator.userChose(.dismiss, stage: .installing)
        await harness.settle()

        #expect(harness.coordinator.transactionState.isArmed)
        #expect(harness.loginItems.status(.agent) != .enabled)
        #expect(!harness.lifecycle.calls.contains(.enable))
        #expect(try harness.journals.journal.load()?.phase == .replacing)
    }

    @Test(
        "nothing undoes a staged update",
        arguments: [UpdateUndo.dismiss, .skip, .downloadFailed, .downloadCancelled, .aborted]
    )
    func nothingUndoesAStagedUpdate(undo: UpdateUndo) async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()

        undo.apply(to: harness.coordinator)
        await harness.settle()

        #expect(harness.loginItems.status(.agent) != .enabled)
        #expect(!harness.lifecycle.calls.contains(.enable))
        #expect(try harness.journals.journal.load() != nil)
    }

    /// The invariant, written over every path that can reach the staged phase
    /// rather than over the callbacks that happen to reach it today: a record
    /// that says the bundle is being replaced means the engine was stopped and
    /// the agent unregistered, or the record says the service was off to begin
    /// with.
    @Test(
        "a record at the replacing phase means the engine was stopped",
        arguments: [UpdateStaging.throughTheBarrier, .afterADeferral]
    )
    func stagedImpliesTheEngineIsStopped(staging: UpdateStaging) async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        await staging.reach(harness)

        let record = try #require(try harness.journals.journal.load())
        try #require(record.phase == .replacing)
        #expect(record.previousRegistration == .enabled)
        #expect(harness.loginItems.status(.agent) != .enabled)
        #expect(harness.lifecycle.calls.contains(.disable))
    }

    /// A staging notice with no transaction behind it is the one state the
    /// launch reconcile cannot resolve. It is reported, and nothing is invented
    /// to cover it: no record, no drain, and nothing on the update surface that
    /// names a version this process never recorded.
    @Test("a staging notice with no transaction records nothing and stops nothing")
    func stagedWithoutATransactionRecordsNothing() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        harness.coordinator.staged()

        #expect(harness.coordinator.transactionState == .idle)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(try harness.journals.journal.load() == nil)
        #expect(harness.coordinator.availability() == .available(version: "0.2.0", releaseClass: .normal))
    }

    // MARK: - Repeated callbacks

    @Test("a second Install runs no second transaction")
    func duplicateInstallIsOneTransaction() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        harness.coordinator.userChose(.install, stage: .downloaded)
        let first = harness.coordinator.prepareForReplacement()
        let second = harness.coordinator.prepareForReplacement()

        #expect(first == .ready)
        #expect(second == .ready)
        #expect(harness.lifecycle.calls == [.disable])
    }

    @Test("a repeated staging notice is one phase, not two transactions")
    func duplicateStagingIsOnePhase() async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()
        let id = harness.coordinator.transactionState.transactionId

        harness.coordinator.staged()
        harness.coordinator.staged()

        #expect(harness.coordinator.transactionState.transactionId == id)
        #expect(harness.lifecycle.calls == [.disable])
    }

    /// The postponed relaunch is released exactly once. A second release is not
    /// consulted by the updater, so the transaction has to be idempotent on the
    /// transaction rather than on the callback count.
    @Test("the postponed relaunch commits once")
    func postponementCommitsOnce() async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()

        #expect(await harness.coordinator.commitBeforeRelaunch() == .ready)
        #expect(await harness.coordinator.commitBeforeRelaunch() == .ready)
        #expect(harness.lifecycle.calls == [.disable])
    }

    @Test("the last notice before the swap records that the target must be proven")
    func relaunchRecordsTheVerifyingPhase() async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()

        harness.coordinator.willRelaunch()

        #expect(try harness.journals.journal.load()?.phase == .verifying)
    }

    // MARK: - Quitting

    /// The engine was never stopped and the update is staged, so any exit
    /// replaces the bundle under a live daemon. Quitting spends one more
    /// bounded budget on the stop rather than pretending it can refuse.
    @Test("quitting with a staged update and a live engine offers the stop again")
    func quittingFinishesAStalledStop() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.disableScript = [.deferredWhileBusy(message: "a turn is running")]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .engineStillRunning)
        harness.coordinator.staged()
        harness.lifecycle.disableScript = [nil]

        await harness.coordinator.prepareForQuit()

        #expect(harness.loginItems.status(.agent) != .enabled)
        // The record keeps the phase it reached: it says what has become
        // inevitable, not which step ran last.
        #expect(try harness.journals.journal.load()?.phase == .replacing)
    }

    @Test("quitting with nothing staged waits for nothing")
    func quittingWithNoTransactionDoesNothing() async throws {
        let harness = try UpdateHarness()

        await harness.coordinator.prepareForQuit()

        #expect(harness.lifecycle.calls.isEmpty)
    }

    /// Nothing is staged, so quitting replaces no bundle and has nothing to
    /// finish, however the barrier answered. The record the stalled stop left
    /// behind is the launch reconcile's.
    @Test("quitting with a stalled stop and nothing staged waits for nothing")
    func quittingWithAStalledStopWaitsForNothing() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.disableScript = [.deferredWhileBusy(message: "a turn is running")]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .engineStillRunning)
        let offered = harness.lifecycle.calls.count

        await harness.coordinator.prepareForQuit()

        #expect(harness.lifecycle.calls.count == offered)
        #expect(try harness.journals.journal.load()?.phase == .draining)
    }

    /// Extraction reached the transaction with nothing it could record: the
    /// bundle is going to be replaced and no record will name what it replaced.
    /// The barrier says so rather than pretending the engine is down.
    @Test("an extraction with no transactable update answers that it has none")
    func extractionWithoutAnOfferHasNoTransaction() async throws {
        let harness = try UpdateHarness()

        let outcome = harness.coordinator.prepareForReplacement()

        #expect(outcome == .noTransaction)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(try harness.journals.journal.load() == nil)
    }

    // MARK: - Interruption at every boundary

    /// Every phase is a real boundary a crash can land on, and each one leaves
    /// a record the launch reconcile has an answer for. The case set is
    /// `UpdatePhase.allCases` rather than a hand-written list, so a phase added
    /// later either gets a decision or fails here, and it is asserted against
    /// both sides of the update: which bundle came up is what decides whether
    /// the record is restored or completed, and a boundary nothing recovers on
    /// one side is a boundary nothing recovers.
    @Test("every phase the transaction writes is one the reconcile decides on")
    func everyWrittenPhaseHasADecision() {
        let observations = [
            UpdateFixture.observation(),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine
            )
        ]

        for phase in UpdatePhase.allCases {
            for observation in observations {
                let decision = UpdateReconcileDecision.decide(
                    journal: UpdateFixture.entry(phase: phase),
                    observation: observation
                )

                #expect(
                    decision != .proceed,
                    "\(phase.rawValue) on \(observation.installedApp.marketingVersion) left the launch with nothing to do"
                )
            }
        }
    }

    @Test("an interruption before the drain leaves a record that changed nothing")
    func interruptedAtRecorded() async throws {
        let harness = try UpdateHarness(registration: .notRegistered)
        try harness.offerAndAccept()

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .ready)

        let record = try #require(try harness.journals.journal.load())
        #expect(record.phase == .recorded)
        #expect(
            UpdateReconcileDecision.decide(journal: record, observation: UpdateFixture.observation())
                == .discardJournal
        )
    }

    /// A drain that unregistered the agent and then failed leaves the record
    /// at the drain boundary, which is what an interruption inside the step
    /// leaves too: a registration owed back.
    @Test("an interruption inside the drain leaves a record that owes the registration back")
    func interruptedAtDraining() async throws {
        let harness = try UpdateHarness()
        try harness.offerAndAccept()
        harness.lifecycle.unregisterOnFailedDisable = true
        harness.lifecycle.disableScript = [.daemonNeverExited(pid: 4242)]

        harness.coordinator.userChose(.install, stage: .notDownloaded)
        #expect(harness.coordinator.prepareForReplacement() == .engineStillRunning)

        let record = try #require(try harness.journals.journal.load())
        #expect(record.phase == .draining)

        guard case .restoreSource(let plan) = UpdateReconcileDecision.decide(
            journal: record,
            observation: UpdateFixture.observation()
        ) else {
            Issue.record("a drain interrupted mid-flight left the launch with nothing to restore")
            return
        }

        #expect(plan.registration == .enabled)
    }

    // MARK: - Discovery (R2)

    @Test("nothing is claimed before a check has run")
    func nothingIsClaimedBeforeACheck() throws {
        let harness = try UpdateHarness()

        #expect(harness.coordinator.availability() == .unknown)
    }

    /// The one untruth this surface exists to avoid.
    @Test("a check that failed never reads as up to date")
    func failedCheckIsNeverUpToDate() throws {
        let harness = try UpdateHarness()

        harness.coordinator.cycleFinished(.failed("the feed could not be read"))

        #expect(harness.coordinator.availability() == .checkFailed(lastCheckedAt: nil))
    }

    @Test("only a completed cycle stamps the last successful check")
    func onlyACompletedCycleStampsTheDate() throws {
        let stamped = Date(timeIntervalSince1970: 1_757_000_000)
        let harness = try UpdateHarness(now: { stamped })

        harness.coordinator.cycleFinished(.completed)
        #expect(harness.coordinator.availability() == .upToDate(lastCheckedAt: stamped))

        harness.coordinator.cycleFinished(.failed("the feed could not be read"))
        #expect(harness.coordinator.availability() == .checkFailed(lastCheckedAt: stamped))
    }

    @Test("an offered release carries its version and its release class", arguments: [false, true])
    func offerCarriesItsClass(critical: Bool) throws {
        let harness = try UpdateHarness()

        harness.coordinator.found(UpdateFeedFixture.entry(isCritical: critical))

        #expect(
            harness.coordinator.availability()
                == .available(version: "0.2.0", releaseClass: critical ? .critical : .normal)
        )
    }

    @Test("a staged update outranks anything else the surface could say")
    func stagedOutranksEverything() async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()

        harness.coordinator.cycleFinished(.completed)

        #expect(harness.coordinator.availability() == .staged(version: "0.2.0"))
    }

    @Test("the menu row and Home follow the updater's own answer", arguments: [false, true])
    func checkFollowsTheUpdater(accepts: Bool) throws {
        let harness = try UpdateHarness()
        harness.updater.accepts = accepts

        #expect(harness.coordinator.canCheckForUpdates == accepts)

        harness.coordinator.checkForUpdates()

        #expect(harness.updater.checks == (accepts ? 1 : 0))
    }

    /// A bundle whose declared policy is wrong runs no updater, and the surface
    /// says that rather than reporting a check that never happened.
    @Test("a build that runs no updater says so")
    func unconfiguredBuildSaysSo() throws {
        let harness = try UpdateHarness(startRefusal: .publicKeyNotBase64)

        #expect(harness.coordinator.availability() == .unconfigured)
        #expect(throws: UpdateRefusal.notConfigured(.publicKeyNotBase64)) {
            try harness.coordinator.mayCheck()
        }
    }

    @Test("a check is refused while another owner is changing the service")
    func checkRefusedWhileBusy() throws {
        let harness = try UpdateHarness()
        #expect(harness.gate.acquire(.reconcile))

        #expect(throws: UpdateRefusal.busy(.reconcile)) {
            try harness.coordinator.mayCheck()
        }
    }

    /// The resumption of a staged installer is the one cycle that proceeds
    /// while this transaction holds the gate. Refusing it would strand an
    /// installer that is already armed.
    @Test("a check is permitted while this transaction's own update is staged")
    func checkPermittedWhileStaged() async throws {
        let harness = try UpdateHarness()
        try await harness.stageAnUpdate()

        #expect(throws: Never.self) { try harness.coordinator.mayCheck() }
    }

    // MARK: - The Attention row

    @Test("an offered update reaches the menu bar through Home's own section")
    func offerDrawsAnAttentionRow() throws {
        let row = try #require(
            UpdatePresentation.attentionRow(for: .available(version: "0.2.0", releaseClass: .normal))
        )

        #expect(row.title.contains("0.2.0"))
        #expect(row.action == .showUpdate)
        #expect(UpdatePresentation.attentionRow(for: .upToDate(lastCheckedAt: nil)) == nil)
        #expect(UpdatePresentation.attentionRow(for: .checkFailed(lastCheckedAt: nil)) == nil)
    }

    @Test("a critical release says what makes it critical without forcing anything")
    func criticalRowSaysWhy() throws {
        let row = try #require(
            UpdatePresentation.attentionRow(for: .available(version: "0.2.0", releaseClass: .critical))
        )

        #expect(row.body == ProductStrings[.attentionUpdateCriticalBody])
        #expect(row.action == .showUpdate)
    }

    @Test("a staged update says the replacement happens on quit")
    func stagedRowSaysWhenItInstalls() throws {
        let row = try #require(UpdatePresentation.attentionRow(for: .staged(version: "0.2.0")))

        #expect(row.title == ProductStrings[.attentionUpdateStagedTitle])
    }
}

/// The ways a cycle can be undone, as one set, so every case that has to leave
/// the prior state intact is driven from the same list rather than from a
/// hand-picked pair.
enum UpdateUndo: CaseIterable, Sendable {
    case dismiss
    case skip
    case downloadFailed
    case downloadCancelled
    case aborted

    @MainActor
    func apply(to coordinator: UpdateCoordinator) {
        switch self {
        case .dismiss:
            coordinator.userChose(.dismiss, stage: .downloaded)
        case .skip:
            coordinator.userChose(.skip, stage: .downloaded)
        case .downloadFailed:
            coordinator.downloadFailed("the connection was lost")
        case .downloadCancelled:
            coordinator.downloadCancelled()
        case .aborted:
            coordinator.aborted("the cycle stopped")
        }
    }
}

/// The ways an update can reach the staged phase, so the invariant is written
/// over the state rather than over the callbacks that happen to produce it.
enum UpdateStaging: CaseIterable, Sendable {
    /// The ordinary path: the barrier ran and the engine stopped.
    case throughTheBarrier
    /// The daemon was mid-turn once, then not.
    case afterADeferral

    @MainActor
    func reach(_ harness: UpdateHarness) async {
        switch self {
        case .throughTheBarrier:
            harness.coordinator.userChose(.install, stage: .notDownloaded)
            _ = harness.coordinator.prepareForReplacement()
        case .afterADeferral:
            harness.lifecycle.disableScript = [.deferredWhileBusy(message: "a turn is running"), nil]
            harness.coordinator.userChose(.install, stage: .notDownloaded)
            _ = harness.coordinator.prepareForReplacement()
        }

        harness.coordinator.staged()
    }
}

/// The update transaction over fake service, clock and updater adapters.
@MainActor
final class UpdateHarness {
    let journals: UpdateJournalHarness
    let lifecycle = FakeLifecycleController()
    let loginItems = FakeLoginItemService()
    let services: ServiceController
    let gate = ServiceMutationGate()
    let updater = FakeUpdater()
    var ownership = FakeDaemonOwnership()
    /// The one daemon read the transaction makes, scripted: it is where the
    /// record's original pid comes from.
    let probe: FakeUpdateEngineProbe
    let sleeper = RecordingSleeper()
    let coordinator: UpdateCoordinator

    init(
        registration: ServiceRegistrationStatus = .enabled,
        bundledEngine: EngineBuild? = UpdateFixture.sourceEngine,
        startRefusal: UpdateConfigurationRefusal? = nil,
        answers: [UpdateEngineAnswer]? = nil,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_757_000_000) }
    ) throws {
        journals = try UpdateJournalHarness()
        // A daemon is answering unless a case says otherwise: that is the
        // ordinary Mac, and it is where the record's original pid comes from.
        probe = FakeUpdateEngineProbe(try answers ?? [.answered(ManagementValueFixture.hello())])
        loginItems.preregister(.agent, as: registration)
        services = ServiceController(loginItems: loginItems)
        lifecycle.loginItems = loginItems
        updater.startRefusal = startRefusal
        // The ownership probe answers what this account registered. A case that
        // wants the conflicting-registration refusal says so.
        ownership.answer = registration == .enabled ? .thisAccount : .none

        let ownership = self.ownership
        coordinator = UpdateCoordinator(
            journal: journals.journal,
            lifecycle: lifecycle,
            services: services,
            engines: EngineReconciler(bundled: bundledEngine, bundledPlistDigest: nil),
            probe: probe,
            ownership: ownership,
            gate: gate,
            installedApp: UpdateFixture.sourceApp,
            sleeper: sleeper,
            now: now
        )
        coordinator.start(updater)
    }

    /// The feed both sides of an update come from.
    func offerAFeed() {
        coordinator.feedLoaded([UpdateFeedFixture.installed, UpdateFeedFixture.offered])
    }

    /// A feed, a found update, and the veto passed: the state a transaction can
    /// actually start from.
    func offerAndAccept() throws {
        offerAFeed()
        coordinator.found(UpdateFeedFixture.offered)
        try coordinator.mayProceed(with: UpdateFeedFixture.offered)
    }

    /// An update that is downloaded, stopped and staged.
    func stageAnUpdate() async throws {
        try offerAndAccept()
        coordinator.userChose(.install, stage: .notDownloaded)
        _ = coordinator.prepareForReplacement()
        coordinator.staged()
    }

    /// Lets the transaction's own tasks finish without a wall-clock wait: the
    /// sleeper consumes every bound instantly.
    func settle() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }
}
