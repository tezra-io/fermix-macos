import Foundation
import Testing

@testable import FermixAppCore

/// What the launch reconcile decides, as a table (M34 §6, R4).
///
/// The decision is pure, so every case R4 names is provable here without a
/// filesystem, a socket or a registration: which side of the update is
/// installed, which engine answered, and whether this account's registration
/// owns the daemon.
@Suite("Update reconcile decision")
struct UpdateReconcileDecisionTests {
    private func decide(
        journal: UpdateJournalEntry? = nil,
        _ observation: UpdateObservation
    ) -> UpdateReconcileDecision {
        UpdateReconcileDecision.decide(journal: journal, observation: observation)
    }

    // MARK: - No journal: a bundle replaced outside any transaction

    @Test("an aligned launch with no record does nothing")
    func alignedWithoutARecord() {
        #expect(decide(UpdateFixture.observation()) == .proceed)
    }

    @Test("a daemon that never answered leaves nothing to reconcile")
    func unreachableWithoutARecord() {
        #expect(
            decide(UpdateFixture.observation(engines: .daemonUnreachable))
                == .proceed
        )
    }

    /// A Homebrew cask upgrade or a manual re-drag of the DMG replaces the
    /// bundle with no journal at all. launchd owns the daemon and both sides
    /// speak, so the restart is supported and is the whole remedy.
    @Test("a bundle replaced outside any record offers the restart when it is supported")
    func replacedOutsideAJournal() {
        let decision = decide(
            UpdateFixture.observation(
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                )
            )
        )

        #expect(
            decision
                == .restartToFinish(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                )
        )
    }

    /// The same replacement with the registration off. launchd would not bring
    /// the daemon back, so "Restart to finish updating" would be a promise the
    /// app cannot keep: the answer is the defined recovery path instead.
    @Test(
        "a replacement this account's registration does not own goes to recovery",
        arguments: [ServiceRegistrationStatus.notRegistered, .notFound]
    )
    func replacedWithoutOwningTheDaemon(_ registration: ServiceRegistrationStatus) {
        let decision = decide(
            UpdateFixture.observation(
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                ),
                registration: registration
            )
        )

        #expect(decision == .openRecovery(.conflictingRegistration))
    }

    /// The one registration state with a one-click remedy. It is this account's
    /// own item, waiting on the operator's switch, so being told another
    /// account owns the daemon would send them hunting a fault that is not
    /// there.
    @Test("a replacement waiting on login-item approval says so rather than blaming another account")
    func replacedWhileTheItemAwaitsApproval() {
        let decision = decide(
            UpdateFixture.observation(
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                ),
                registration: .requiresApproval
            )
        )

        #expect(decision == .openRecovery(.registrationNeedsApproval))
    }

    /// With no version in common there is no management call left, and the
    /// restart is a management call. Nothing is promised and nothing is
    /// mutated.
    @Test("a daemon sharing no protocol version goes to recovery rather than to a restart")
    func noSharedProtocolWithoutARecord() {
        #expect(
            decide(
                UpdateFixture.observation(
                    engines: .daemonUnreachable,
                    protocolMismatch: true
                )
            ) == .openRecovery(.noSharedProtocol)
        )
    }

    @Test("no shared protocol version wins over an outstanding record")
    func noSharedProtocolWithARecord() {
        #expect(
            decide(
                journal: UpdateFixture.entry(phase: .verifying),
                UpdateFixture.observation(
                    installedApp: UpdateFixture.targetApp,
                    bundledEngine: UpdateFixture.targetEngine,
                    engines: .daemonUnreachable,
                    protocolMismatch: true
                )
            ) == .openRecovery(.noSharedProtocol)
        )
    }

    // MARK: - A record, and the source still installed

    /// Nothing had been mutated when the record was written, so there is
    /// nothing to put back: the record is discarded and the launch is ordinary.
    @Test("a record written before anything was mutated is discarded")
    func recordedPhase() {
        #expect(
            decide(journal: UpdateFixture.entry(phase: .recorded), UpdateFixture.observation())
                == .discardJournal
        )
    }

    /// Interrupted shutdown, and reboot at any boundary before the bundle was
    /// replaced: the app that came up is still the source, so the transaction
    /// is rolled back to it.
    @Test(
        "an interruption before the replacement restores the source",
        arguments: [UpdatePhase.draining, .stopped, .replacing, .verifying]
    )
    func interruptedBeforeTheReplacement(_ phase: UpdatePhase) {
        let decision = decide(
            journal: UpdateFixture.entry(phase: phase),
            UpdateFixture.observation(engines: .daemonUnreachable)
        )

        #expect(
            decision
                == .restoreSource(
                    UpdateRestorePlan(
                        expected: UpdateFixture.sourceEngine,
                        registration: .enabled,
                        previousPid: 4242
                    )
                )
        )
    }

    /// The bundle was never replaced and something else is on the socket. The
    /// restore would be proven against an engine that is neither side of the
    /// record, so it is refused before anything is mutated.
    @Test("a third engine answering while the source is installed is refused before any mutation")
    func foreignEngineWhileSourceInstalled() {
        let decision = decide(
            journal: UpdateFixture.entry(phase: .stopped),
            UpdateFixture.observation(
                engines: .pendingEngineRestart(
                    running: UpdateFixture.foreignEngine,
                    bundled: UpdateFixture.sourceEngine
                )
            )
        )

        #expect(decision == .openRecovery(.unexpectedEngine))
    }

    /// The source bundle has to carry the engine the record named, exactly as
    /// the target bundle does. A source shipping something else is a
    /// replacement nobody recorded, and restoring would start an engine nobody
    /// chose.
    @Test(
        "a source bundle shipping an engine the record did not name is refused",
        arguments: [UpdateFixture.foreignEngine, nil]
    )
    func unexpectedSourceEngine(_ bundled: EngineBuild?) {
        #expect(
            decide(
                journal: UpdateFixture.entry(phase: .stopped),
                UpdateFixture.observation(bundledEngine: bundled, engines: .daemonUnreachable)
            ) == .openRecovery(.unexpectedEngine)
        )
    }

    // MARK: - A record, and the target installed

    /// Replacement succeeded but the relaunch did not finish the transaction,
    /// including the case where it never happened at all: whatever opens the
    /// app next completes it.
    @Test(
        "the target being installed completes the transaction",
        arguments: [UpdatePhase.replacing, .verifying]
    )
    func targetInstalled(_ phase: UpdatePhase) {
        let decision = decide(
            journal: UpdateFixture.entry(phase: phase),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine,
                engines: .daemonUnreachable,
                registration: .notRegistered
            )
        )

        #expect(
            decision
                == .completeTarget(
                    UpdateRestorePlan(
                        expected: UpdateFixture.targetEngine,
                        registration: .enabled,
                        previousPid: 4242
                    )
                )
        )
    }

    /// The service was off before the update, and it stays off. The plan
    /// carries the recorded state, so the reconciler never enables a service to
    /// complete a health check.
    @Test("a service that was disabled before the update keeps its recorded state")
    func targetInstalledWithADisabledService() {
        let decision = decide(
            journal: UpdateFixture.entry(phase: .replacing, previousRegistration: .notRegistered),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine,
                engines: .daemonUnreachable,
                registration: .notRegistered
            )
        )

        #expect(
            decision
                == .completeTarget(
                    UpdateRestorePlan(
                        expected: UpdateFixture.targetEngine,
                        registration: .notRegistered,
                        previousPid: 4242
                    )
                )
        )
    }

    /// The barrier holding the installer is bounded, so the replacement can go
    /// ahead with the old engine still writing this home. It is checked before
    /// the restart is offered, and it does not matter whether that engine is
    /// still answering now: what the home was written by is already done.
    @Test(
        "a replacement that happened under a live engine goes to recovery",
        arguments: [
            EngineReconcileOutcome.pendingEngineRestart(
                running: UpdateFixture.sourceEngine,
                bundled: UpdateFixture.targetEngine
            ),
            .daemonUnreachable
        ]
    )
    func replacedWithoutStoppingTheEngine(_ engines: EngineReconcileOutcome) {
        #expect(
            decide(
                journal: UpdateFixture.entry(phase: .replacing, engineStopped: false),
                UpdateFixture.observation(
                    installedApp: UpdateFixture.targetApp,
                    bundledEngine: UpdateFixture.targetEngine,
                    engines: engines
                )
            ) == .openRecovery(.engineNotStopped)
        )
    }

    /// The bundle that arrived is not the one the record was written against.
    /// Running it anyway would be running an engine nobody chose.
    @Test("a target bundle shipping an engine the record did not name is refused")
    func unexpectedTargetEngine() {
        #expect(
            decide(
                journal: UpdateFixture.entry(phase: .verifying),
                UpdateFixture.observation(
                    installedApp: UpdateFixture.targetApp,
                    bundledEngine: UpdateFixture.foreignEngine,
                    engines: .daemonUnreachable
                )
            ) == .openRecovery(.unexpectedEngine)
        )
    }

    @Test("a target bundle with no readable engine manifest is refused")
    func targetWithoutAnEngineManifest() {
        #expect(
            decide(
                journal: UpdateFixture.entry(phase: .verifying),
                UpdateFixture.observation(
                    installedApp: UpdateFixture.targetApp,
                    bundledEngine: nil,
                    engines: .daemonUnreachable
                )
            ) == .openRecovery(.unexpectedEngine)
        )
    }

    /// The old daemon survived the replacement. One restart puts the target in
    /// memory, and it is the same restart the unjournaled path offers, so the
    /// record stays until the engine that answers is the target.
    @Test("an old daemon that survived the replacement takes the supported restart")
    func oldDaemonSurvivedTheReplacement() {
        let decision = decide(
            journal: UpdateFixture.entry(phase: .verifying),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                )
            )
        )

        #expect(
            decision
                == .restartToFinish(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                )
        )
    }

    /// The daemon that survived the replacement has to be the one the record
    /// started from. A third engine on the socket would be restarted away by a
    /// step this record does not describe, so it is refused before anything is
    /// mutated, exactly as it is on the source side.
    @Test("a third engine surviving the replacement is refused rather than restarted away")
    func foreignEngineSurvivedTheReplacement() {
        let decision = decide(
            journal: UpdateFixture.entry(phase: .verifying),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.foreignEngine,
                    bundled: UpdateFixture.targetEngine
                )
            )
        )

        #expect(decision == .openRecovery(.unexpectedEngine))
    }

    /// Another account's registration is holding the daemon: this account
    /// cannot restart it, so the promise is withheld here too.
    @Test("an old daemon this account cannot restart goes to recovery")
    func oldDaemonWithAConflictingRegistration() {
        let decision = decide(
            journal: UpdateFixture.entry(phase: .verifying),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                ),
                registration: .notRegistered
            )
        )

        #expect(decision == .openRecovery(.conflictingRegistration))
    }

    /// The same daemon with the item awaiting approval: one switch in System
    /// Settings is the whole remedy, and the sentence has to say that.
    @Test("an old daemon whose item awaits approval names the approval")
    func oldDaemonWhileTheItemAwaitsApproval() {
        let decision = decide(
            journal: UpdateFixture.entry(phase: .verifying),
            UpdateFixture.observation(
                installedApp: UpdateFixture.targetApp,
                bundledEngine: UpdateFixture.targetEngine,
                engines: .pendingEngineRestart(
                    running: UpdateFixture.sourceEngine,
                    bundled: UpdateFixture.targetEngine
                ),
                registration: .requiresApproval
            )
        )

        #expect(decision == .openRecovery(.registrationNeedsApproval))
    }

    // MARK: - A record naming neither installed app

    @Test("an app that is neither side of the record is refused")
    func unexpectedApp() {
        #expect(
            decide(
                journal: UpdateFixture.entry(phase: .replacing),
                UpdateFixture.observation(
                    installedApp: AppBuild(marketingVersion: "0.9.9", buildNumber: 99),
                    bundledEngine: UpdateFixture.foreignEngine,
                    engines: .daemonUnreachable
                )
            ) == .openRecovery(.unexpectedApp)
        )
    }
}

/// What the launch reconcile does about what it decided.
///
/// The registration is the durable state: it is put back only where the record
/// says it was on, and only what this reconcile turned on is turned off again.
@Suite("Update reconciler")
@MainActor
struct UpdateReconcilerTests {
    @Test("an aligned launch with no record touches nothing")
    func alignedLaunch() async throws {
        let harness = try UpdateReconcileHarness(bundled: UpdateFixture.sourceEngine)

        #expect(try await harness.reconciler.reconcile() == .proceed)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.journal.isEmpty)
    }

    @Test("a record written before anything was mutated is cleared without a transaction")
    func discardsARecordThatMutatedNothing() async throws {
        let harness = try UpdateReconcileHarness(bundled: UpdateFixture.sourceEngine)
        try harness.journal.write(UpdateFixture.entry(phase: .recorded))

        #expect(try await harness.reconciler.reconcile() == .proceed)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.journal.isEmpty)
    }

    /// Interrupted shutdown: the agent was unregistered and the daemon
    /// drained, and the replacement never happened. The registration goes back
    /// and the source engine is proven before the record is cleared.
    @Test("an interrupted shutdown restores the registration and proves the source")
    func restoresAnInterruptedShutdown() async throws {
        let harness = try UpdateReconcileHarness(
            bundled: UpdateFixture.sourceEngine,
            registration: .notRegistered,
            answers: [.unreachable, .answered(try UpdateReconcileHarness.hello(.source))]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .draining))

        #expect(try await harness.reconciler.reconcile() == .proceed)
        #expect(harness.lifecycle.calls == [.enable])
        #expect(harness.journal.isEmpty)
    }

    /// The replacement succeeded and the relaunch did not finish the
    /// transaction. The next launch re-registers, proves the target engine in a
    /// new process, and clears the record.
    @Test("a completed replacement is finished by whatever opens the app next")
    func completesTheTarget() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable, .answered(try UpdateReconcileHarness.hello(.target, pid: "5150"))]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        #expect(try await harness.reconciler.reconcile() == .proceed)
        #expect(harness.lifecycle.calls == [.enable])
        #expect(harness.journal.isEmpty)
    }

    /// The old daemon answering again is not a completed transaction, whatever
    /// engine it claims: step 9 requires a new process.
    @Test("the same process answering again does not complete the transaction")
    func requiresANewProcess() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            answers: [.answered(try UpdateReconcileHarness.hello(.target, pid: "4242"))]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .verifying))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .targetEngineUnverified)
        #expect(!harness.journal.isEmpty)
    }

    /// A pid that cannot be read is not proof of anything, and this is the one
    /// step that proves the replacement actually produced a new process.
    @Test("a daemon whose pid cannot be read does not complete the transaction")
    func unreadablePidIsNotProof() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            answers: [
                .answered(
                    try ManagementValueFixture.hello(
                        version: UpdateFixture.targetEngine.productVersion,
                        pid: "not a number",
                        buildId: UpdateFixture.targetEngine.buildId
                    )
                )
            ]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .verifying))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .targetEngineUnverified)
    }

    /// A service that was off before the update stays off, and nothing is
    /// enabled to run a health check on it.
    @Test("a service that was disabled before the update is left disabled")
    func preservesADisabledService() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable]
        )
        try harness.journal.write(
            UpdateFixture.entry(phase: .verifying, previousRegistration: .notRegistered)
        )

        #expect(try await harness.reconciler.reconcile() == .proceed)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.journal.isEmpty)
    }

    /// The new engine failed after the replacement. The registration this
    /// reconcile turned on for the check is turned off again, the record is
    /// kept, and Recovery opens with the prior installer.
    @Test("a new engine that never comes back is disabled again and opens recovery")
    func newEngineNeverComesBack() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .targetEngineUnverified)
        #expect(report.priorInstaller == UpdateFixture.priorInstaller)
        #expect(report.source == UpdateFixture.source)
        #expect(report.target == UpdateFixture.target)
        #expect(report.phase == .replacing)
        #expect(report.rollbackSupported)
        #expect(!report.disableRefused)
        #expect(harness.lifecycle.calls == [.enable, .disable])
        #expect(!harness.journal.isEmpty, "recovery reads the record, so it is kept")
    }

    /// The disable is a mutation that can be refused, and a refusal that only
    /// reached the log would leave the operator with a service they were told
    /// was off.
    @Test("a disable that macOS refuses is reported in the recovery report")
    func failedDisableIsReported() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable]
        )
        harness.lifecycle.disableScript = [
            .registration(.unregistrationFailed(principal: .agent, underlying: "operation not permitted"))
        ]
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .targetEngineUnverified)
        #expect(report.disableRefused)
    }

    /// Nothing this reconcile turned on, nothing it turns off: a service the
    /// operator already had running is theirs.
    @Test("a registration this reconcile did not restore is not turned off")
    func doesNotDisableWhatItDidNotRestore() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .enabled,
            answers: [.unreachable]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .verifying))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .targetEngineUnverified)
        #expect(harness.lifecycle.calls.isEmpty)
    }

    @Test("a registration that cannot be put back opens recovery")
    func restoreThatCouldNotRun() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable]
        )
        harness.lifecycle.stageFailure(.daemonNotManaged(.requiresApproval))
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .registrationNotRestored)
        #expect(harness.lifecycle.calls == [.enable])
    }

    /// The one file that would have said what happened cannot be read, which is
    /// itself a reason to stop rather than to launch as if nothing had.
    @Test("a record that cannot be read opens recovery from nothing but the reason")
    func unreadableRecord() async throws {
        let harness = try UpdateReconcileHarness(bundled: UpdateFixture.sourceEngine)
        try Data("{".utf8).write(to: harness.journal.url)

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .journalUnusable)
        #expect(report.priorInstaller == nil)
        #expect(!report.rollbackSupported, "nothing is promised about data the record cannot describe")
        #expect(harness.probe.reads == 0, "an unreadable record is decided before the daemon is asked")
    }

    /// A record that is there and cannot be read is the same answer as one
    /// whose bytes are nonsense: it is the one file that says what the last
    /// transaction did, and reading "no record" off it would proceed over an
    /// update nothing has resolved. A directory at the path is the cheapest
    /// unreadable file there is.
    @Test("a record that is present and unreadable opens recovery")
    func presentButUnreadableRecord() async throws {
        let harness = try UpdateReconcileHarness(bundled: UpdateFixture.sourceEngine)
        try FileManager.default.createDirectory(
            at: harness.journal.url,
            withIntermediateDirectories: false
        )

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .journalUnusable)
        #expect(harness.probe.reads == 0, "an unreadable record is decided before the daemon is asked")
        #expect(harness.lifecycle.calls.isEmpty)
    }

    /// The one destructive step around the record, and it is not the
    /// reconcile's own: the reconcile keeps the evidence, and Recovery's Try
    /// again is what asks for the install back. Until the file is gone every
    /// launch answers the same way.
    @Test("discarding an unusable record removes it and lets the next launch proceed")
    func discardsAnUnusableRecord() async throws {
        let harness = try UpdateReconcileHarness(bundled: UpdateFixture.sourceEngine)
        try Data("{".utf8).write(to: harness.journal.url)

        try harness.reconciler.discardUnusableRecord()

        #expect(harness.journal.isEmpty)
        #expect(try await harness.reconciler.reconcile() == .proceed)
    }

    /// A daemon that shares no protocol version is not a slow start: no
    /// management call can reach it, so the rest of the budget would prove
    /// nothing and "the new engine did not answer" would send the operator
    /// looking for a daemon that is running.
    @Test("a target engine sharing no protocol version stops the wait and says so")
    func targetSharingNoProtocolStopsTheWait() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .enabled,
            answers: [.unreachable, .noSharedProtocol]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .noSharedProtocol)
        // The one read the observation made, plus the one that answered. The
        // rest of the budget is not spent on a daemon nothing can reach.
        #expect(harness.probe.reads == 2)
        #expect(harness.sleeper.sleeps.isEmpty)
        #expect(!harness.journal.isEmpty, "recovery reads the record, so it is kept")
    }

    /// Enabling registers before it checks health, so a failed restore leaves
    /// both a registration and that enable's own record. The record is what a
    /// later transaction is refused by, and only the enable's is this
    /// reconcile's to clear.
    @Test(
        "the undo resolves the failed enable's own record and no other kind",
        arguments: [LifecycleTransactionKind.enable, .restart]
    )
    func undoResolvesOnlyItsOwnRecord(_ kind: LifecycleTransactionKind) async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable]
        )
        harness.stageAFailedRestore(leaving: kind)
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .registrationNotRestored)
        #expect(!report.disableRefused)
        #expect(harness.loginItems.status(.agent) == .notRegistered)
        #expect((try harness.lifecycle.interruptedTransaction() == nil) == (kind == .enable))
    }

    /// The record is resolved before the registration is taken back, which is
    /// what an unregister macOS refuses proves: the reverse order leaves a
    /// record on disk describing a step that has already been undone, and every
    /// later transaction is refused by it.
    @Test("the failed enable's record is resolved even when the unregister is refused")
    func undoResolvesTheRecordBeforeUnregistering() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .notRegistered,
            answers: [.unreachable]
        )
        harness.stageAFailedRestore(leaving: .enable)
        harness.loginItems.unregisterError = ServiceControlError.unregistrationFailed(
            principal: .agent,
            underlying: "operation not permitted"
        )
        try harness.journal.write(UpdateFixture.entry(phase: .replacing))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .registrationNotRestored)
        #expect(report.disableRefused)
        #expect(try harness.lifecycle.interruptedTransaction() == nil)
    }

    /// The verification is a bounded wait with a defined outcome, so a daemon
    /// that never comes back ends the launch instead of hanging it.
    @Test("the verification wait is bounded")
    func boundedVerification() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: UpdateFixture.targetApp,
            bundled: UpdateFixture.targetEngine,
            registration: .enabled,
            answers: [.unreachable]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .verifying))

        _ = try await harness.reconciler.reconcile()

        // The one read the observation made, plus the whole verification
        // budget and no more.
        let policy = LifecyclePolicy.engineVerification
        #expect(harness.probe.reads == policy.attempts + 1)
        #expect(harness.sleeper.sleeps.count == policy.attempts - 1)
        #expect(harness.sleeper.sleeps.allSatisfy { $0 == policy.interval })
    }

    /// Recovery opens from the record alone: no daemon, no feed, no network.
    @Test("a recovery report states the prior installer without reaching anything")
    func recoveryReadsOnlyTheRecord() async throws {
        let harness = try UpdateReconcileHarness(
            installedApp: AppBuild(marketingVersion: "0.9.9", buildNumber: 99),
            bundled: UpdateFixture.foreignEngine,
            answers: [.unreachable]
        )
        try harness.journal.write(UpdateFixture.entry(phase: .replacing, rollbackSupported: false))

        let outcome = try await harness.reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("expected recovery, got \(outcome)")
            return
        }
        #expect(report.reason == .unexpectedApp)
        #expect(report.priorInstaller?.url == UpdateFixture.priorInstaller.url)
        #expect(report.priorInstaller?.sha256 == UpdateFixture.priorInstaller.sha256)
        #expect(report.migration == UpdateFixture.migration)
        #expect(!report.rollbackSupported)
        #expect(harness.lifecycle.calls.isEmpty)
    }
}

/// The reconciler over doubles: one throwaway journal directory, the lifecycle
/// transactions recorded rather than run, and a scripted `hello`.
@MainActor
final class UpdateReconcileHarness {
    let files: UpdateJournalHarness
    let lifecycle = FakeLifecycleController()
    let loginItems = FakeLoginItemService()
    let probe: FakeUpdateEngineProbe
    let sleeper = RecordingSleeper()
    let reconciler: UpdateReconciler

    var journal: UpdateJournal { files.journal }

    init(
        installedApp: AppBuild = UpdateFixture.sourceApp,
        bundled: EngineBuild?,
        registration: ServiceRegistrationStatus = .enabled,
        answers: [UpdateEngineAnswer] = [.unreachable]
    ) throws {
        files = try UpdateJournalHarness()
        loginItems.preregister(.agent, as: registration)
        probe = FakeUpdateEngineProbe(answers)
        reconciler = UpdateReconciler(
            journal: files.journal,
            lifecycle: lifecycle,
            services: ServiceController(loginItems: loginItems),
            engines: EngineReconciler(bundled: bundled, bundledPlistDigest: nil),
            probe: probe,
            installedApp: installedApp,
            sleeper: sleeper
        )
    }

    /// A restore that registered the agent and then failed, leaving one
    /// lifecycle record behind.
    ///
    /// It is the real shape of the step: `enableBackgroundService` registers
    /// before it checks health, so a failure there owes the account both an
    /// unregister and a resolved record.
    func stageAFailedRestore(leaving kind: LifecycleTransactionKind) {
        lifecycle.loginItems = loginItems
        lifecycle.registerOnFailedEnable = true
        lifecycle.stageFailure(.daemonNotManaged(.requiresApproval))
        lifecycle.stageInterruptedTransaction(
            LifecycleJournalEntry(
                transactionId: UUID(),
                kind: kind,
                phase: .verify,
                originalPid: 4242,
                previousRegistration: .notRegistered,
                startedAt: Date(timeIntervalSince1970: 1_757_000_000)
            )
        )
    }

    enum Side {
        case source
        case target
    }

    /// A `hello` from one side of the fixture update.
    nonisolated static func hello(_ side: Side, pid: String = "5150") throws -> ManagementHello {
        let engine = side == .source ? UpdateFixture.sourceEngine : UpdateFixture.targetEngine

        return try ManagementValueFixture.hello(
            version: engine.productVersion,
            pid: pid,
            buildId: engine.buildId
        )
    }
}
