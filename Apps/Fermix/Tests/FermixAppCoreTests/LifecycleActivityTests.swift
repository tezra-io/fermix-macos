import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// What the app says while a lifecycle transaction it started is running
/// (owner report of 2026-09-20: after `Restart now` the sheet closed, the daemon
/// went away for several seconds, and nothing on screen said a restart was
/// running until it was over).
///
/// One fact, `AppModel.transactionInFlight`, with one writer. These cases hold
/// its lifetime, the one sentence per transaction, and each surface's reading of
/// it, so the toolbar, Home's Status row and the status item's state line cannot
/// come to describe one restart three ways.
@Suite("Lifecycle activity")
@MainActor
struct LifecycleActivityTests {
    /// Waits until the coordinator's task has actually reached the transaction,
    /// so a case reads the app mid-restart rather than before it began.
    private func waitUntilRunning(_ lifecycle: FakeLifecycleController, _ call: FakeLifecycleController.Call) async throws {
        for _ in 0..<10_000 {
            if lifecycle.calls.contains(call) { return }
            await Task.yield()
        }

        try #require(lifecycle.calls.contains(call), "the transaction never reached the lifecycle owner")
    }

    // MARK: - The one fact

    @Test("a restart is in flight from the moment it is taken until it completes, and its end is spoken")
    func restartIsInFlightWhileItRuns() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        let hold = AsyncGate()
        harness.lifecycle.holdRestart = hold
        #expect(harness.model.transactionInFlight == nil)

        harness.coordinator.restartDaemon()
        #expect(harness.model.transactionInFlight == .restart, "the sheet has closed, so the window says so at once")

        try await waitUntilRunning(harness.lifecycle, .restart)
        #expect(harness.model.transactionInFlight == .restart)
        #expect(harness.coordinator.transactionInFlight == .restart)
        #expect(harness.announcer.sentences.isEmpty, "nothing has finished yet")

        hold.release()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.transactionInFlight == nil)
        #expect(harness.announcer.sentences == ["Fermix restarted"])
    }

    /// The preflight refusal of 2026-09-04 and every failure after it. The
    /// refusal path stays exactly as it was; what is new is only that the
    /// sentence goes away, and that VoiceOver is not told a restart worked.
    @Test("a restart that fails clears the fact, keeps its refusal, and announces nothing")
    func failedRestartClears() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        harness.lifecycle.stageFailure(.daemonNotManaged(.notRegistered))

        harness.coordinator.restartDaemon()
        #expect(harness.model.transactionInFlight == .restart)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.transactionInFlight == nil)
        #expect(harness.model.restartRefusal == ProductStrings[.lifecycleDaemonNotManaged])
        #expect(harness.announcer.sentences.isEmpty)
    }

    @Test("a restart refused at the gate clears the fact and never ran")
    func refusedRestartClears() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        #expect(harness.gate.acquire(.update))

        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.transactionInFlight == nil)
        #expect(harness.model.restartRefusal == ProductStrings[.lifecycleServiceBusy])
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.announcer.sentences.isEmpty)
    }

    /// `Restart when idle` has not started anything while it waits, so nothing
    /// may claim a restart is running until the transaction is actually taken.
    @Test("Restart when idle claims nothing while it waits, and nothing at all at the cap")
    func whenIdleDoesNotClaimEarly() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        harness.settingsGateway.overviewScript = [
            try ManagementValueFixture.overview(activeConversations: 2),
            try ManagementValueFixture.overview()
        ]
        var seen: [LifecycleTransactionKind?] = []

        await harness.settings.beginRestart(.whenIdle) {
            seen.append(harness.model.transactionInFlight)
            harness.coordinator.restartDaemon()
            seen.append(harness.model.transactionInFlight)
        }
        try await harness.coordinator.drainPendingWork()

        #expect(seen == [nil, .restart], "the wait itself claimed a restart")
        #expect(harness.model.transactionInFlight == nil)

        let capped = try CoordinatorHarness(bootstrap: .present)
        capped.settingsGateway.overviewScript = [try ManagementValueFixture.overview(activeConversations: 1)]

        await capped.settings.beginRestart(.whenIdle) { capped.coordinator.restartDaemon() }

        #expect(capped.settings.restartProgress == .stillBusy)
        #expect(capped.model.transactionInFlight == nil)
        #expect(capped.lifecycle.calls.isEmpty)
    }

    /// The `Run in the background` switch had the same silent seconds. It is the
    /// same task, so it is the same fact with its own word.
    @Test("the background switch's transactions name themselves the same way")
    func backgroundServiceNamesItsTransaction() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        let hold = AsyncGate()
        harness.lifecycle.holdDisable = hold

        harness.coordinator.setBackgroundService(enabled: false)
        try await waitUntilRunning(harness.lifecycle, .disable)
        #expect(harness.model.transactionInFlight == .disable)

        hold.release()
        try await harness.coordinator.drainPendingWork()
        #expect(harness.model.transactionInFlight == nil)

        harness.coordinator.setBackgroundService(enabled: true)
        #expect(harness.model.transactionInFlight == .enable)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.transactionInFlight == nil)
        #expect(harness.announcer.sentences == ["Background service disabled", "Background service enabled"])
    }

    // MARK: - The sentences

    @Test("each transaction has one sentence, in the deck's voice")
    func sentences() {
        #expect(LifecycleActivity.sentence(for: .restart) == "Restarting Fermix")
        #expect(LifecycleActivity.sentence(for: .enable) == "Enabling the background service")
        #expect(LifecycleActivity.sentence(for: .disable) == "Disabling the background service")

        #expect(LifecycleActivity.completion(of: .restarted(previousPid: 1, currentPid: 2)) == "Fermix restarted")
        #expect(LifecycleActivity.completion(of: .enabled(pid: 1)) == "Background service enabled")
        #expect(LifecycleActivity.completion(of: .disabled) == "Background service disabled")
    }

    // MARK: - The toolbar

    /// Every surface of the primary window, and the settings presentation, which
    /// keeps the route it was entered from. The assistant is the exception: its
    /// ladder already draws the restart as a row with its own indicator.
    @Test("the toolbar says so on every surface but the assistant, and only while it is true")
    func toolbarSentence() {
        for route in AppRoute.allCases {
            let sentence = LifecycleActivity.toolbarSentence(for: .restart, on: route)

            if route == .setup || route == .recovery {
                #expect(sentence == nil, "\(route.rawValue) repeats its own ladder row")
            } else {
                #expect(sentence == "Restarting Fermix", "\(route.rawValue)")
            }

            #expect(LifecycleActivity.toolbarSentence(for: nil, on: route) == nil, "\(route.rawValue)")
        }
    }

    /// In the settings presentation the toolbar carries `Restart…`. While the
    /// restart it asked for is running, offering it again is the one thing that
    /// control must not do, and the window's sentence stands in its place.
    @Test("the settings restart action steps aside while a transaction runs")
    func settingsActionStepsAside() throws {
        let model = SettingsFixture.model(gateway: FakeDaemonGateway())
        model.restart = try ManagementValueFixture.setupState().restart
        let router = FakeCommandRouter()

        let idle = SettingsRestartControl(model: model, router: router, transaction: nil)
        #expect(idle.actionTitle == ProductStrings[.settingsRestartAction])

        let restarting = SettingsRestartControl(model: model, router: router, transaction: .restart)
        #expect(restarting.actionTitle == nil)
        restarting.requestRestart()
        #expect(router.performed.isEmpty)
    }

    // MARK: - Home's Status row

    @Test("Home's Status row states the transaction, and the daemon's own answer otherwise")
    func homeStatusProjection() throws {
        let unreachable = HomeSnapshot.unreachable(attention: .unavailable("the socket is not there"))
        let running = HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: try ManagementValueFixture.overview(),
            attention: .rows([]),
            update: .unknown
        )

        let restarting = HomeStatus(transaction: .restart, snapshot: unreachable)
        #expect(restarting.title == "Restarting Fermix")
        #expect(restarting.inProgress)

        for snapshot in [unreachable, running] {
            let settled = HomeStatus(transaction: nil, snapshot: snapshot)

            #expect(settled.title == snapshot.statusTitle)
            #expect(!settled.inProgress)
        }
    }

    /// The defect itself: a refresh that lands mid-restart finds nothing
    /// answering, and the row used to say Fermix isn't running about a restart
    /// the person had just asked for.
    @Test("a refresh that finds the daemon gone mid-restart does not read as a failure")
    func homeTellsTheTruthMidRestart() async throws {
        let harness = try HomeHarness()
        await harness.model.refresh()
        #expect(harness.model.status.title == ProductStrings[.homeStatusRunning])

        let hold = AsyncGate()
        harness.lifecycle.holdRestart = hold
        var redraws = 0
        let subscription = harness.model.objectWillChange.sink { _ in redraws += 1 }
        defer { subscription.cancel() }

        // The restart is taken from the sheet, not from Home, so Home has to be
        // told to read the transaction again.
        harness.coordinator.restartDaemon()
        #expect(redraws > 0, "Home never learned that a transaction began")

        try await waitUntilRunning(harness.lifecycle, .restart)
        harness.gateway.negotiateFailure = ManagementError.transport(.socketMissing(path: "/tmp/test-daemon.sock"))
        await harness.model.refresh()

        #expect(harness.model.snapshot.unreachable)
        #expect(harness.model.status == HomeStatus(transaction: .restart, snapshot: harness.model.snapshot))
        #expect(harness.model.status.title == "Restarting Fermix")
        #expect(harness.statusLine() == .transaction(.restart))

        harness.gateway.negotiateFailure = nil
        hold.release()
        try await harness.coordinator.drainPendingWork()
        await harness.model.refresh()

        #expect(harness.model.status.title == ProductStrings[.homeStatusRunning])
        #expect(!harness.model.status.inProgress)
        #expect(harness.statusLine() != .transaction(.restart))
    }

    // MARK: - The status item

    @Test("the state line says the same sentence, ahead of whatever the last read found")
    func stateLine() {
        let model = AppModel()
        let source = StatusMenuSource(
            model: model,
            snapshot: { HomeSnapshot.unreachable(attention: .unavailable("the socket is not there")) }
        )
        model.daemon = .stopped
        #expect(source.line() == .notRunning)

        model.transactionInFlight = .restart
        #expect(source.line() == .transaction(.restart))
        #expect(source.line().text == LifecycleActivity.sentence(for: .restart))

        model.transactionInFlight = nil
        #expect(source.line() == .notRunning)
    }
}
