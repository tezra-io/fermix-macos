import Foundation
import Testing

@testable import FermixAppCore

/// Enable, disable, and restart as journaled transactions, over injected
/// service, control-plane, process, socket, web, and clock seams.
///
/// Nothing here registers a background item, opens a socket, or sends a signal:
/// every step the daemon would perform is a recorded call on a double.
@Suite("Lifecycle coordinator")
@MainActor
struct LifecycleCoordinatorTests {
    private func makeHarness(
        registered: Bool = false,
        daemonRunning: Bool = false,
        registrationReceipt: String? = LifecycleHarness.bundledPlistDigest
    ) throws -> LifecycleHarness {
        try LifecycleHarness(
            registered: registered,
            daemonRunning: daemonRunning,
            registrationReceipt: registrationReceipt
        )
    }

    // MARK: - Enable

    @Test("enabling registers the agent, waits for the socket, negotiates, and verifies the web surface")
    func enableRunsEveryStepInOrder() async throws {
        let harness = try makeHarness()
        harness.plane.helloPid = "4242"

        let outcome = try await harness.coordinator.enableBackgroundService()

        #expect(outcome == .enabled(pid: 4_242))
        #expect(harness.loginItems.registerCalls == [.agent])
        #expect(harness.plane.calls == [.hello])
        #expect(harness.web.probedOrigins == ["http://127.0.0.1:4030"])
        #expect(harness.journal.isEmpty)
    }

    @Test("a successful enable records the bundled agent registration receipt")
    func enableRecordsRegistrationReceipt() async throws {
        let harness = try makeHarness(registrationReceipt: nil)

        let outcome = try await harness.coordinator.enableBackgroundService()

        #expect(outcome == .enabled(pid: 4_242))
        #expect(try harness.registrationReceipt() == LifecycleHarness.bundledPlistDigest)
        #expect(harness.journal.isEmpty)
    }

    @Test("an enable with an invalid daemon PID cannot record a success receipt")
    func invalidEnableDoesNotRecordReceipt() async throws {
        let harness = try makeHarness(registrationReceipt: nil)
        harness.plane.helloPid = "0"

        await #expect(throws: LifecycleFailure.daemonIdentityUnreadable(pid: "0")) {
            try await harness.coordinator.enableBackgroundService()
        }
        #expect(try harness.registrationReceipt() == nil)
    }

    @Test("enabling without a bootstrap record refuses before touching the service")
    func enableRefusesWithoutBootstrap() async throws {
        let harness = try makeHarness()
        try harness.removeBootstrap()

        await #expect(throws: LifecycleFailure.bootstrapMissing) {
            try await harness.coordinator.enableBackgroundService()
        }
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// A socket that never appears is a truthful failure with the path that was
    /// watched, not a hang.
    @Test("a socket that never appears fails with the path that was watched")
    func enableFailsWhenTheSocketNeverAppears() async throws {
        let harness = try makeHarness()
        harness.socket.presentAfterPolls = .max

        await #expect(throws: LifecycleFailure.socketNeverAppeared(path: harness.socketPath)) {
            try await harness.coordinator.enableBackgroundService()
        }
        // One wait between attempts, and none after the last one.
        #expect(harness.sleeper.sleeps.count == LifecyclePolicy.socketPolling.attempts - 1)
    }

    @Test("a daemon whose web surface never answers fails after the bounded wait")
    func enableFailsWhenTheWebSurfaceNeverAnswers() async throws {
        let harness = try makeHarness(registrationReceipt: nil)
        harness.web.isLive = false

        await #expect(throws: LifecycleFailure.webNeverAnswered(origin: "http://127.0.0.1:4030")) {
            try await harness.coordinator.enableBackgroundService()
        }
        #expect(try harness.registrationReceipt() == nil)
    }

    // MARK: - Disable

    @Test("disabling prepares a drain, unregisters, commits, and verifies the daemon is gone")
    func disableRunsEveryStepInOrder() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = 1
        harness.socket.disappearsAfterPolls = 1

        let outcome = try await harness.coordinator.disableBackgroundService()

        #expect(outcome == .disabled)
        #expect(harness.plane.calls == [.hello, .prepare, .commit("lease-1")])
        #expect(harness.loginItems.unregisterCalls == [.agent])
        #expect(harness.journal.isEmpty)
    }

    /// The registration is the durable state, so a failed unregister must leave
    /// the service enabled and the drain cancelled rather than half-disabled.
    @Test("a failed unregister cancels the drain and leaves the service enabled")
    func failedUnregisterRollsBack() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.loginItems.unregisterError = ServiceControlError.unregistrationFailed(
            principal: .agent,
            underlying: "operation not permitted"
        )

        await #expect(throws: LifecycleFailure.registration(
            .unregistrationFailed(principal: .agent, underlying: "operation not permitted")
        )) {
            try await harness.coordinator.disableBackgroundService()
        }

        #expect(harness.plane.calls == [.hello, .prepare, .cancel("lease-1")])
        #expect(harness.loginItems.status(.agent) == .enabled)
    }

    /// A socket that never appeared and a socket that never went away are
    /// opposite failures. Reporting both as "never appeared" sends whoever reads
    /// the log looking for a daemon that never started.
    @Test("a socket left behind after the daemon exits is reported as never released")
    func disableFailsWhenTheSocketSurvives() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = 1
        harness.socket.disappearsAfterPolls = .max

        await #expect(throws: LifecycleFailure.socketNeverReleased(path: harness.socketPath)) {
            try await harness.coordinator.disableBackgroundService()
        }
    }

    @Test("a daemon that never exits is reported with the pid that stayed alive")
    func disableFailsWhenTheDaemonSurvives() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = .max

        await #expect(throws: LifecycleFailure.daemonNeverExited(pid: 77)) {
            try await harness.coordinator.disableBackgroundService()
        }
    }

    /// A busy daemon defers the transaction; the service is untouched, which is
    /// what makes deferral safe to retry.
    @Test("a busy daemon defers the disable with the service untouched")
    func busyDaemonDefersTheDisable() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.prepareFailure = ManagementError.daemon(
            ManagementFailure(code: .busy, message: "a turn is in flight", details: ManagementScalarMap(values: [:]))
        )

        await #expect(throws: LifecycleFailure.deferredWhileBusy(message: "a turn is in flight")) {
            try await harness.coordinator.disableBackgroundService()
        }

        #expect(harness.loginItems.unregisterCalls.isEmpty)
        #expect(harness.loginItems.status(.agent) == .enabled)
    }

    // MARK: - Restart

    /// The preflight that had to exist (owner report of 2026-09-04). launchd
    /// relaunches only a daemon it owns, so on any registration but `enabled`
    /// the drain committed, the daemon exited, and nothing brought it back: the
    /// operator's Fermix was gone until the next login. It refuses before the
    /// journal is written, so the next launch is not told a recovery is pending.
    @Test(
        "a restart is refused before any mutation while the agent is not registered",
        arguments: [ServiceRegistrationStatus.notFound, .requiresApproval, .notRegistered]
    )
    func restartRefusesAnUnmanagedDaemon(status: ServiceRegistrationStatus) async throws {
        let harness = try makeHarness(daemonRunning: true)
        harness.loginItems.preregister(.agent, as: status)

        await #expect(throws: LifecycleFailure.daemonNotManaged(status)) {
            try await harness.coordinator.restartDaemon()
        }

        #expect(harness.plane.calls.isEmpty, "nothing was prepared or committed")
        #expect(harness.loginItems.unregisterCalls.isEmpty)
        #expect(harness.loginItems.registerCalls.isEmpty)
        #expect(harness.journal.isEmpty, "a refused preflight leaves no recovery record")
    }

    /// And the refusal says why, in one sentence the sheet and the assistant
    /// both render. A refusal that only reached the log left `Restart now`
    /// looking like a button that does nothing.
    @Test("the refusal carries the sentence a surface can show")
    func unmanagedRefusalCarriesItsSentence() {
        #expect(
            LifecycleFailure.daemonNotManaged(.notFound).sentence
                == ProductStrings[.lifecycleDaemonNotManaged]
        )
        #expect(LifecycleFailure.daemonNeverReturned.sentence == nil)
    }

    /// The registration is touched only where the bundled plist has changed
    /// (M34 §7.2 step 5), which this healthy install's receipt says it has not.
    @Test("restarting an unchanged install keeps the registration and waits for a different pid")
    func restartKeepsTheRegistration() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.plane.helloPidAfterRestart = "99"
        harness.process.exitsAfterPolls = 1
        harness.socket.disappearsAfterPolls = 1

        let outcome = try await harness.coordinator.restartDaemon()

        #expect(outcome == .restarted(previousPid: 77, currentPid: 99))
        #expect(harness.loginItems.registerCalls.isEmpty)
        #expect(harness.loginItems.unregisterCalls.isEmpty)
        #expect(harness.plane.calls == [.hello, .prepare, .commit("lease-1"), .hello])
        #expect(harness.web.probedOrigins.count == 1)
    }

    /// M34 §7.2 step 5. A receipt that names the plist this bundle ships means
    /// launchd is already running what the bundle asks for, so the restart
    /// leaves the registration alone.
    @Test("a receipt matching the bundled plist renews no registration")
    func restartLeavesAMatchingRegistrationAlone() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.plane.helloPidAfterRestart = "99"
        harness.process.exitsAfterPolls = 1

        _ = try await harness.coordinator.restartDaemon()

        #expect(harness.loginItems.unregisterCalls.isEmpty)
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// A bundle whose plist differs from the one that was registered has to
    /// unregister and register before launchd brings the daemon back, or the
    /// changed `ProgramArguments` is applied to nothing.
    @Test("a receipt that differs from the bundled plist unregisters and registers")
    func restartRenewsAChangedRegistration() async throws {
        let harness = try makeHarness(
            registered: true,
            daemonRunning: true,
            registrationReceipt: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        harness.plane.helloPid = "77"
        harness.plane.helloPidAfterRestart = "99"
        harness.process.exitsAfterPolls = 1

        _ = try await harness.coordinator.restartDaemon()

        #expect(harness.loginItems.unregisterCalls == [.agent])
        #expect(harness.loginItems.registerCalls == [.agent])
        // The new receipt is written, so the next restart renews nothing.
        #expect(try harness.registrationReceipt() == LifecycleHarness.bundledPlistDigest)
    }

    /// A record written before the receipt field existed carries no receipt at
    /// all, and §7.2 reads that as a difference rather than a match.
    @Test("a record with no receipt renews the registration")
    func restartRenewsWhenNoReceiptWasEverWritten() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true, registrationReceipt: nil)
        harness.plane.helloPid = "77"
        harness.plane.helloPidAfterRestart = "99"
        harness.process.exitsAfterPolls = 1

        _ = try await harness.coordinator.restartDaemon()

        #expect(harness.loginItems.unregisterCalls == [.agent])
        #expect(harness.loginItems.registerCalls == [.agent])
    }

    /// The same pid answering again is not a restart: launchd may not have
    /// relaunched at all, and reporting success there would be a lie.
    @Test("the same pid answering again is not accepted as a restart")
    func restartRefusesTheSamePid() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.plane.helloPidAfterRestart = "77"
        harness.process.exitsAfterPolls = 1

        await #expect(throws: LifecycleFailure.daemonNeverReturned) {
            try await harness.coordinator.restartDaemon()
        }
    }

    // MARK: - Journal

    /// Every transaction is preflight, prepare, mutate, verify, then clear. An
    /// interrupted one leaves exactly the record recovery needs.
    @Test("an interrupted transaction leaves its journal entry behind")
    func interruptedTransactionLeavesAJournalEntry() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = .max

        await #expect(throws: (any Error).self) {
            try await harness.coordinator.disableBackgroundService()
        }

        let entry = try #require(try harness.journal.load())
        #expect(entry.kind == .disable)
        #expect(entry.phase == .verify)
        #expect(entry.originalPid == 77)
        #expect(entry.previousRegistration == .enabled)
    }

    @Test("a completed transaction clears its journal entry")
    func completedTransactionClearsTheJournal() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = 1
        harness.socket.disappearsAfterPolls = 1

        _ = try await harness.coordinator.disableBackgroundService()

        #expect(try harness.journal.load() == nil)
    }

    @Test("the journal survives a write and reads back the same record")
    func journalRoundTrips() throws {
        let harness = try makeHarness()
        let entry = LifecycleJournalEntry(
            transactionId: UUID(uuidString: "2f7d4e2c-2b1a-4f4e-9a1e-2f0a0b1c2d3e")!,
            kind: .restart,
            phase: .mutate,
            originalPid: 4_242,
            previousRegistration: .enabled,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try harness.journal.write(entry)

        #expect(try harness.journal.load() == entry)
        #expect(harness.journal.isEmpty == false)
    }

    @Test("the journal lives beside the bootstrap record, outside the app bundle")
    func journalLivesOutsideTheBundle() throws {
        let harness = try makeHarness()

        #expect(harness.journal.url.lastPathComponent == "lifecycle-journal.json")
        #expect(harness.journal.url.deletingLastPathComponent() == harness.location.directoryURL)
    }

    /// The journal holds one transaction because they are serialized. Starting a
    /// second one over an unresolved record destroys the only evidence of what
    /// was interrupted, which is the whole reason the record is written.
    @Test("a new transaction refuses to overwrite an unresolved record")
    func beginRefusesOverAnInterruptedRecord() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = .max

        await #expect(throws: (any Error).self) {
            try await harness.coordinator.disableBackgroundService()
        }
        let interrupted = try #require(try harness.journal.load())

        await #expect(throws: LifecycleFailure.recoveryPending(kind: .disable, phase: .verify)) {
            try await harness.coordinator.enableBackgroundService()
        }

        #expect(try harness.journal.load() == interrupted, "the record survived the refusal")
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// The record has a production reader, which is what makes it a recovery
    /// journal rather than a write-only file.
    @Test("the coordinator reports and resolves the interrupted transaction")
    func interruptedTransactionIsReadableAndResolvable() async throws {
        let harness = try makeHarness(registered: true, daemonRunning: true)
        harness.plane.helloPid = "77"
        harness.process.exitsAfterPolls = .max

        await #expect(throws: (any Error).self) {
            try await harness.coordinator.disableBackgroundService()
        }

        let pending = try harness.coordinator.interruptedTransaction()
        #expect(pending?.kind == .disable)
        #expect(pending?.phase == .verify)
        #expect(pending?.originalPid == 77)

        try harness.coordinator.discardInterruptedTransaction()

        #expect(try harness.coordinator.interruptedTransaction() == nil)
        #expect(harness.journal.isEmpty)
    }

    @Test("a clean account reports no interrupted transaction")
    func noInterruptedTransactionWhenClean() throws {
        let harness = try makeHarness()

        #expect(try harness.coordinator.interruptedTransaction() == nil)
    }

    /// A record that is there and cannot be read is not a clean account. Both
    /// journals answer this the same way, because both read through the same
    /// file layer: a caller told the record is absent starts a transaction over
    /// one nothing has resolved. A directory at the path is the cheapest
    /// unreadable file there is, and it is inside the harness's own temporary
    /// root.
    @Test("a record that is present and unreadable is not a clean account")
    func presentButUnreadableRecord() throws {
        let harness = try makeHarness()
        try FileManager.default.createDirectory(
            at: harness.journal.url,
            withIntermediateDirectories: true
        )

        #expect(throws: (any Error).self) {
            try harness.coordinator.interruptedTransaction()
        }
        #expect(!harness.journal.isEmpty)
    }
}
