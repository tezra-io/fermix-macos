import Foundation
import Testing

@testable import FermixAppCore

@Suite("Update review regressions")
@MainActor
struct UpdateRegressionTests {
    @Test("the real gateway probe rejects a disjoint protocol window")
    func probeChecksProtocolOverlap() async throws {
        let transport = try WindowedFixtureTransport(window: (minimum: 3, maximum: 4))
        let contract = try ManagementContract.vendored()
        let gateway = ManagementGateway {
            try ManagementTestClient.make(transport: transport, contract: contract)
        }

        let answer = await ManagementUpdateEngineProbe(gateway: gateway).read()

        #expect(answer == .noSharedProtocol)
    }

    @Test("launch presents nothing before update reconciliation completes")
    func launchWaitsForReconciliation() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        let barrier = AsyncGate()
        harness.updates.barrier = barrier

        harness.coordinator.start(reason: .user)

        #expect(harness.windows.presented.isEmpty)
        barrier.release()
        try await harness.coordinator.drainPendingWork()
        #expect(harness.windows.presented == [.main])
    }

    @Test("a URL cannot open settings before recovery is resolved")
    func routeWaitsForRecovery() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        let barrier = AsyncGate()
        harness.updates.barrier = barrier
        harness.updates.outcome = .recovery(UpdateRecoveryReport(reason: .journalUnusable, entry: nil))

        harness.coordinator.open(.settings(.providers))

        #expect(harness.windows.presented.isEmpty)
        barrier.release()
        try await harness.coordinator.drainPendingWork()
        #expect(harness.model.route == .recovery)
    }

    @Test("a partial enable is undone or its failed disable is reported", arguments: [false, true])
    func failedRealEnableIsUndone(disableRefused: Bool) async throws {
        let lifecycle = try LifecycleHarness(registered: false, daemonRunning: false)
        lifecycle.socket.presentAfterPolls = .max
        if disableRefused {
            lifecycle.loginItems.unregisterError = ServiceControlError.unregistrationFailed(
                principal: .agent, underlying: "operation not permitted"
            )
        }
        let journal = UpdateJournal(location: lifecycle.location)
        try journal.write(UpdateFixture.entry(phase: .replacing))
        let reconciler = UpdateReconciler(
            journal: journal,
            lifecycle: lifecycle.coordinator,
            services: ServiceController(loginItems: lifecycle.loginItems),
            engines: EngineReconciler(bundled: UpdateFixture.targetEngine, bundledPlistDigest: nil),
            probe: FakeUpdateEngineProbe([.unreachable]),
            installedApp: UpdateFixture.targetApp,
            sleeper: lifecycle.sleeper
        )

        let outcome = try await reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("a failed engine start must open Recovery")
            return
        }
        #expect(report.reason == .registrationNotRestored)
        #expect(report.disableRefused == disableRefused)
        #expect(lifecycle.loginItems.status(.agent) == (disableRefused ? .enabled : .notRegistered))
        #expect(lifecycle.loginItems.unregisterCalls == [.agent])
        #expect(!journal.isEmpty)
    }

    @Test("interrupted target verification undoes registration and preserves recovery facts")
    func interruptedVerificationIsUndone() async throws {
        let lifecycle = try LifecycleHarness(registered: false, daemonRunning: false)
        lifecycle.socket.present = true
        lifecycle.socket.disappearsAfterPolls = 1
        let journal = UpdateJournal(location: lifecycle.location)
        try journal.write(UpdateFixture.entry(phase: .replacing))
        let reconciler = UpdateReconciler(
            journal: journal,
            lifecycle: lifecycle.coordinator,
            services: ServiceController(loginItems: lifecycle.loginItems),
            engines: EngineReconciler(bundled: UpdateFixture.targetEngine, bundledPlistDigest: nil),
            probe: FakeUpdateEngineProbe([.unreachable]),
            installedApp: UpdateFixture.targetApp,
            sleeper: InterruptedUpdateSleeper()
        )

        let outcome = try await reconciler.reconcile()

        guard case .recovery(let report) = outcome else {
            Issue.record("interrupted verification must open Recovery")
            return
        }
        #expect(report.reason == .targetEngineUnverified)
        #expect(report.priorInstaller == UpdateFixture.priorInstaller)
        #expect(!report.disableRefused)
        #expect(lifecycle.loginItems.status(.agent) == .notRegistered)
        #expect(!journal.isEmpty)
    }
}

private struct InterruptedUpdateSleeper: Sleeping {
    func sleep(seconds: TimeInterval) async throws { throw CancellationError() }
}
