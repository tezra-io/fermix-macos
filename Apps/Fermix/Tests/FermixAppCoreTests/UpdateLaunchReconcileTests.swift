import Foundation
import Testing

@testable import FermixAppCore

/// The launch reconcile, as the app runs it (M34 §6, R4).
///
/// Every launch path reconciles before ordinary UI, and there is one owner
/// rather than one call site per path: a login launch, a manual launch and a
/// `fermix://` route all ask the same reconciler, and the relaunch after a
/// replacement is one of the first two.
@Suite("Update launch reconcile")
@MainActor
struct UpdateLaunchReconcileTests {
    private func harness() throws -> CoordinatorHarness {
        try CoordinatorHarness(bootstrap: .present)
    }

    @Test(
        "every launch path reconciles the update record",
        arguments: [LaunchReason.login, .user, .route(.surface(.home)), .route(.settings(.providers))]
    )
    func everyLaunchPathReconciles(_ reason: LaunchReason) async throws {
        let harness = try harness()

        harness.coordinator.start(reason: reason)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.reconcileCount == 1)
    }

    /// A url arrives at `open(_:)` rather than at `start(reason:)`, and it is
    /// the same owner: the four paths cannot drift because there is one to
    /// drift from.
    @Test("a url route reconciles through the same owner")
    func urlRouteReconciles() async throws {
        let harness = try harness()

        try harness.coordinator.open(url: try #require(URL(string: "fermix://doctor")))
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.reconcileCount == 1)
    }

    /// Navigation inside a running app is not a launch. The record was read
    /// when the process came up, and reading it again per click re-runs a
    /// restore, a bounded verify and a disable with every control on screen
    /// disabled while it goes.
    @Test("navigation the app performs for itself reconciles nothing")
    func internalNavigationDoesNotReconcile() async throws {
        let harness = try harness()
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.updates.reconcileCount == 1)

        harness.coordinator.open(.logs)
        harness.coordinator.openSettings()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.reconcileCount == 1)
        #expect(harness.presentation.isShowing)
    }

    /// Recovery's Doctor button is the one route that is exempt from the
    /// recovery gate, and pressing it must not re-run the work that put the app
    /// in Recovery in the first place.
    @Test("Doctor pressed from recovery opens Doctor without a second reconcile")
    func doctorFromRecoveryDoesNotReconcileAgain() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(
            UpdateRecoveryReport(reason: .targetEngineUnverified, entry: UpdateFixture.entry(phase: .replacing))
        )
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.model.route == .recovery)

        harness.coordinator.open(.doctor)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.route == .doctor)
        #expect(harness.updates.reconcileCount == 1)
    }

    /// A staged update holds the gate in this very process until the bundle is
    /// replaced, and it holds the record it wrote, so there is nothing on disk
    /// for a second reader to resolve. A launch that answered the gate by
    /// presenting nothing left the app running with no window and no way in.
    @Test(
        "a launch presents even while another owner holds the service",
        arguments: [ServiceMutation.update, .lifecycle]
    )
    func launchPresentsWhileTheServiceIsHeld(_ holder: ServiceMutation) async throws {
        let harness = try harness()
        #expect(harness.gate.acquire(holder))

        harness.coordinator.open(.settings(.providers))
        try await harness.coordinator.drainPendingWork()

        #expect(harness.windows.presented == [.main])
        #expect(harness.presentation.isShowing)
        #expect(harness.updates.reconcileCount == 0, "the gate is held, so no record was read")
    }

    /// The reopen path answers the same way: with the pet on screen and the
    /// main window closed, a Launchpad click is the only way back in.
    @Test("a reopen presents even while a staged update holds the service")
    func reopenPresentsWhileTheServiceIsHeld() async throws {
        let harness = try harness()
        #expect(harness.gate.acquire(.update))

        harness.coordinator.reopen()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .home)
    }

    /// The reconcile can open Recovery itself, and Recovery is navigation the
    /// app performs rather than an entry point: reconciling again from there
    /// would be a loop.
    @Test("the recovery it opens does not re-enter it")
    func recoveryDoesNotReEnterTheReconcile() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(
            UpdateRecoveryReport(reason: .targetEngineUnverified, entry: UpdateFixture.entry(phase: .replacing))
        )

        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.reconcileCount == 1)
        #expect(harness.model.route == .recovery)
        #expect(harness.windows.presented == [.main])
        #expect(harness.model.needsAttention)
    }

    /// Recovery reads what the reconcile found, so the report is published
    /// rather than only logged.
    @Test("the report the reconcile found is what recovery reads")
    func reportIsPublished() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(
            UpdateRecoveryReport(reason: .unexpectedEngine, entry: UpdateFixture.entry(phase: .verifying))
        )

        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.coordinator.updateRecovery?.reason == .unexpectedEngine)
        #expect(harness.coordinator.updateRecovery?.priorInstaller == UpdateFixture.priorInstaller)
    }

    /// A standing report is a reason to open Recovery on the next launch too:
    /// nothing about the install has changed just because a window was closed.
    @Test("an outstanding update failure routes a later launch to recovery")
    func outstandingFailureRoutesLaterLaunches() {
        let presentation = AppCoordinator.presentation(
            for: .user,
            bootstrap: .present,
            recovery: .updateFailed(.targetEngineUnverified)
        )

        #expect(presentation == .assistant(.recovery))
        #expect(RecoveryCondition.updateFailed(.targetEngineUnverified).needsRecovery)
    }

    /// A login launch opens nothing, and a reconcile that found a broken update
    /// is exactly the case where that silence would be wrong.
    @Test("a login launch that finds a failed update still opens recovery")
    func loginLaunchOpensRecovery() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(
            UpdateRecoveryReport(reason: .conflictingRegistration, entry: nil)
        )

        harness.coordinator.start(reason: .login)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .recovery)
    }

    /// The pending restart is already drawn by the Attention row and the status
    /// line, which read the same engine comparison. The reconcile agreeing that
    /// the restart is keepable puts nothing new on screen.
    @Test("a keepable restart puts nothing new on screen")
    func restartToFinishOpensNothing() async throws {
        let harness = try harness()
        harness.updates.outcome = .restartToFinish(
            running: UpdateFixture.sourceEngine,
            bundled: UpdateFixture.targetEngine
        )

        harness.coordinator.start(reason: .login)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.windows.presented.isEmpty)
        #expect(harness.coordinator.updateRecovery == nil)
    }

    /// The world changes: a conflicting registration is turned back on, a
    /// foreign daemon is quit. A reconcile that then proceeds withdraws the
    /// report rather than leaving the app in Recovery for the session.
    @Test("a reconcile that proceeds withdraws a standing report")
    func proceedWithdrawsTheReport() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(
            UpdateRecoveryReport(reason: .conflictingRegistration, entry: nil)
        )
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.coordinator.updateRecovery != nil)

        harness.updates.outcome = .proceed
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.coordinator.updateRecovery == nil)
        #expect(harness.updates.reconcileCount == 2)
    }

    /// Try again on an update that did not finish re-runs the launch reconcile,
    /// because that is the only thing that resolves the record: a restart, a
    /// reinstall or a daemon quitting in between is what it looks at.
    @Test("try again re-runs the reconcile and proceeds once nothing is outstanding")
    func retryReRunsTheReconcile() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(
            UpdateRecoveryReport(reason: .targetEngineUnverified, entry: UpdateFixture.entry(phase: .replacing))
        )
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.model.route == .recovery)

        harness.updates.outcome = .proceed
        harness.coordinator.retryUpdateRecovery()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.reconcileCount == 2)
        #expect(harness.updates.discardCount == 0, "a readable record is evidence, not something to delete")
        #expect(harness.coordinator.updateRecovery == nil)
        #expect(harness.model.route == .home)
    }

    /// An unreadable record is the one reason a second look would answer
    /// identically, so it goes first. This is the only place it is discarded:
    /// the reconcile keeps it, and until the person on the screen asks for the
    /// install back every launch lands here again.
    @Test("try again on an unusable record discards it, then reconciles")
    func retryDiscardsAnUnusableRecord() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(UpdateRecoveryReport(reason: .journalUnusable, entry: nil))
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()

        harness.updates.outcome = .proceed
        harness.coordinator.retryUpdateRecovery()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.discardCount == 1)
        #expect(harness.updates.reconcileCount == 2)
        #expect(harness.coordinator.updateRecovery == nil)
        #expect(harness.model.route == .home)
    }

    /// A discard that fails leaves Recovery standing: reconciling over a record
    /// that is still unreadable would answer the same way, and would have spent
    /// the one attempt at the evidence to do it.
    @Test("a discard the filesystem refuses leaves recovery standing")
    func refusedDiscardLeavesRecoveryStanding() async throws {
        let harness = try harness()
        harness.updates.outcome = .recovery(UpdateRecoveryReport(reason: .journalUnusable, entry: nil))
        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()
        harness.updates.discardFailure = UpdateJournalError.writeFailed(
            path: "/tmp/fermix-update-tests/update-journal.json",
            errno: 13
        )

        harness.coordinator.retryUpdateRecovery()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.updates.discardCount == 1)
        #expect(harness.updates.reconcileCount == 1, "nothing was reconciled over a record still on disk")
        #expect(harness.coordinator.updateRecovery?.reason == .journalUnusable)
    }

    /// A cancelled reconcile leaves the record on disk, so the launch is not
    /// claimed to have resolved anything.
    @Test("a reconcile that stopped resolves nothing")
    func stoppedReconcileResolvesNothing() async throws {
        let harness = try harness()
        harness.updates.failure = CancellationError()

        harness.coordinator.start(reason: .user)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.coordinator.updateRecovery?.reason == .reconcileInterrupted)
        #expect(harness.model.route == .recovery)
    }
}

/// What Recovery states about an update that did not finish.
///
/// The screen opens from the record alone, so these are assertions about copy
/// and about what the screen is allowed to offer without a connection.
@Suite("Update recovery presentation")
struct UpdateRecoveryPresentationTests {
    private func report(
        reason: UpdateRecoveryReason = .targetEngineUnverified,
        entry: UpdateJournalEntry? = UpdateFixture.entry(phase: .replacing),
        disableRefused: Bool = false
    ) -> UpdateRecoveryReport {
        UpdateRecoveryReport(reason: reason, entry: entry, disableRefused: disableRefused)
    }

    @Test("the two versions and the exact installer are stated from the record")
    func statesTheRecord() {
        let presentation = UpdateRecoveryPresentation(report: report())

        #expect(presentation.sentence == ProductStrings[.updateRecoveryTargetUnverified])
        #expect(presentation.versions == "Was on version 0.1.0, updating to version 0.2.0")
        #expect(presentation.installerSentence?.contains("0.1.0") == true)
        #expect(presentation.installerSentence?.contains("Developer ID Application") == true)
        #expect(presentation.reinstallURL?.absoluteString == UpdateFixture.priorInstaller.url)
    }

    /// The screen is honest about the one thing on it that is not local.
    @Test("the reinstall option says it needs a connection")
    func reinstallNeedsAConnection() {
        let notices = UpdateRecoveryPresentation(report: report()).notices

        #expect(notices == [ProductStrings[.updateRecoveryNeedsNetwork]])
        #expect(ProductStrings[.updateRecoveryNeedsNetwork].lowercased().contains("internet connection"))
    }

    /// Rollback is promised only to the exact recorded source, and only while
    /// the record says going back is data safe.
    @Test("an unsafe rollback is stated before the option that would take it")
    func unsafeRollbackIsStated() {
        let presentation = UpdateRecoveryPresentation(
            report: report(entry: UpdateFixture.entry(phase: .verifying, rollbackSupported: false))
        )

        #expect(
            presentation.notices == [
                ProductStrings[.updateRecoveryRollbackUnsafe],
                ProductStrings[.updateRecoveryNeedsNetwork]
            ]
        )
    }

    /// A mutation that did not happen leads: the operator is looking at a
    /// service they were told is off.
    @Test("a refused disable is reported first")
    func refusedDisableLeads() {
        let notices = UpdateRecoveryPresentation(report: report(disableRefused: true)).notices

        #expect(notices.first == ProductStrings[.updateRecoveryDisableRefused])
        #expect(notices.count == 2)
    }

    /// With no record there is nothing to reinstall and nothing to promise
    /// about data, so the screen offers neither.
    @Test("a reason with no record offers no reinstall and promises nothing")
    func noRecord() {
        let presentation = UpdateRecoveryPresentation(report: report(reason: .noSharedProtocol, entry: nil))

        #expect(presentation.sentence == ProductStrings[.updateRecoveryNoSharedProtocol])
        #expect(presentation.versions == nil)
        #expect(presentation.installerSentence == nil)
        #expect(presentation.reinstallURL == nil)
        #expect(presentation.notices.isEmpty)
    }

    /// The record is read after a crash, so the address in it is not handed to
    /// a browser on trust. Anything but `https` is stated and not offered.
    @Test("an installer address that is not https is not offered")
    func refusesANonHTTPSInstaller() {
        let entry = UpdateJournalEntry(
            transactionId: UUID(),
            phase: .replacing,
            originalPid: 1,
            source: UpdateFixture.source,
            target: UpdateFixture.target,
            migration: UpdateFixture.migration,
            previousRegistration: .enabled,
            priorInstaller: UpdateInstaller(
                url: "file:///tmp/Fermix-previous.dmg",
                version: "0.1.0",
                sha256: String(repeating: "b", count: 64),
                signingIdentity: "Developer ID Application: Example (TEAMID)"
            ),
            engineStopped: true,
            rollbackSupported: true,
            startedAt: Date()
        )

        let presentation = UpdateRecoveryPresentation(report: report(entry: entry))

        #expect(presentation.reinstallURL == nil)
        #expect(presentation.installerSentence != nil, "the record is still stated, it is just not offered")
    }

    /// Every reason gets its own sentence. Derived from the case set, so a
    /// reason added later has to be given copy rather than reaching the
    /// operator as the name of an enum case.
    @Test("every recovery reason has its own shipped sentence")
    func everyReasonHasCopy() {
        var sentences: Set<String> = []

        for reason in UpdateRecoveryReason.allCases {
            let sentence = UpdateRecoveryPresentation(report: report(reason: reason, entry: nil)).sentence

            #expect(!sentence.isEmpty, "\(reason.rawValue)")
            #expect(!sentence.hasPrefix("updateRecovery."), "\(reason.rawValue) is missing from the catalogue")
            #expect(ProductCopyRules.violations(in: sentence).isEmpty, "\(reason.rawValue)")
            sentences.insert(sentence)
        }

        #expect(sentences.count == UpdateRecoveryReason.allCases.count)
    }
}
