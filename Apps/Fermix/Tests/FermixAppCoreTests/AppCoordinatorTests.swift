import Foundation
import Testing

@testable import FermixAppCore

/// The composition root: what a launch opens, what a `fermix://` url opens,
/// what a menu row does, and what quitting is allowed to touch.
@Suite("App coordinator")
@MainActor
struct AppCoordinatorTests {
    private func makeCoordinator(bootstrap: BootstrapCondition = .present) -> CoordinatorHarness {
        CoordinatorHarness(bootstrap: bootstrap)
    }

    @Test("a login launch presents no window")
    func loginLaunchOpensNothing() {
        let harness = makeCoordinator()

        harness.coordinator.start(reason: .login)

        #expect(harness.windows.presented.isEmpty)
    }

    @Test("a user launch opens the main window on Home")
    func userLaunchOpensHome() {
        let harness = makeCoordinator()

        harness.coordinator.start(reason: .user)

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .home)
    }

    @Test("a fresh account opens onboarding instead of a main window")
    func freshAccountOpensOnboarding() {
        let harness = makeCoordinator(bootstrap: .absent)

        harness.coordinator.start(reason: .user)

        #expect(harness.windows.presented == [.onboarding])
    }

    /// §4 writes a record for every interrupted transaction so recovery can
    /// read it. The launch path is that reader; without it the record is a file
    /// nothing opens and the app claims everything is normal.
    @Test("a launch reads the recovery journal and opens recovery")
    func launchReadsTheRecoveryJournal() {
        let harness = makeCoordinator()
        harness.lifecycle.stageInterruptedTransaction(
            LifecycleJournalEntry(
                transactionId: UUID(),
                kind: .disable,
                phase: .mutate,
                originalPid: 4_242,
                previousRegistration: .enabled,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        harness.coordinator.start(reason: .user)

        #expect(harness.windows.presented == [.onboarding])
        #expect(harness.model.onboardingStage == .recovery)
    }

    /// Acknowledging it is what lets the next transaction start: the coordinator
    /// refuses to begin one over an unresolved record.
    @Test("resolving the interrupted transaction clears the record")
    func resolvingClearsTheRecord() throws {
        let harness = makeCoordinator()
        harness.lifecycle.stageInterruptedTransaction(
            LifecycleJournalEntry(
                transactionId: UUID(),
                kind: .disable,
                phase: .verify,
                originalPid: 77,
                previousRegistration: .enabled,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        harness.coordinator.resolveInterruptedTransaction()

        #expect(harness.lifecycle.calls == [.discardRecovery])
        #expect(try harness.lifecycle.interruptedTransaction() == nil)

        harness.coordinator.start(reason: .user)
        #expect(harness.windows.presented == [.main])
    }

    @Test("a fermix url selects its route and raises the window")
    func urlSelectsItsRoute() throws {
        let harness = makeCoordinator()

        try harness.coordinator.open(url: URL(string: "fermix://doctor")!)

        #expect(harness.model.route == .doctor)
        #expect(harness.windows.presented == [.main])
    }

    /// An unknown url is refused loudly rather than silently opening Home,
    /// which would tell the user their command worked.
    @Test("an unknown url is refused and opens nothing")
    func unknownUrlIsRefused() {
        let harness = makeCoordinator()

        #expect(throws: AppRouteError.unknownRoute("teleport")) {
            try harness.coordinator.open(url: URL(string: "fermix://teleport")!)
        }
        #expect(harness.windows.presented.isEmpty)
    }

    /// Quitting the GUI releases audio and the realtime socket and sends no
    /// daemon lifecycle command: the daemon outlives the window.
    @Test("quitting releases voice and never touches the daemon")
    func quitReleasesVoiceOnly() {
        let harness = makeCoordinator()

        harness.coordinator.quit()

        #expect(harness.voice.shutdownCount == 1)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.termination.requested == 1)
    }

    @Test("the quit menu row is what quits, and it quits exactly once")
    func quitRowQuits() {
        let harness = makeCoordinator()

        harness.coordinator.perform(.quit)

        #expect(harness.termination.requested == 1)
    }

    @Test("the pet row toggles the floating window rather than opening a surface")
    func petRowTogglesTheWindow() {
        let harness = makeCoordinator()

        harness.coordinator.perform(.togglePet)
        #expect(harness.windows.presented == [.pet])

        harness.coordinator.perform(.togglePet)
        #expect(harness.windows.presented.isEmpty)
    }

    @Test("the setup and doctor rows open their sidebar routes")
    func menuRowsOpenRoutes() {
        let harness = makeCoordinator()

        harness.coordinator.perform(.setup)
        #expect(harness.model.route == .setup)

        harness.coordinator.perform(.runDoctor)
        #expect(harness.model.route == .doctor)
    }

    @Test("restart runs the daemon restart transaction and nothing else")
    func restartRunsTheTransaction() async throws {
        let harness = makeCoordinator()

        harness.coordinator.perform(.restartDaemon)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == [.restart])
    }

    @Test("the service row enables or disables the background service")
    func serviceRowTogglesRegistration() async throws {
        let harness = makeCoordinator()
        harness.model.serviceEnabled = true

        harness.coordinator.perform(.toggleService)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.lifecycle.calls == [.disable])

        harness.model.serviceEnabled = false
        harness.coordinator.perform(.toggleService)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.lifecycle.calls == [.disable, .enable])
    }

    @Test("recovery opens the onboarding window in its recovery state")
    func recoveryOpensOnboarding() {
        let harness = makeCoordinator()

        harness.coordinator.enterRecovery()

        #expect(harness.windows.presented == [.onboarding])
        #expect(harness.model.onboardingStage == .recovery)
    }
}

@MainActor
final class CoordinatorHarness {
    let model = AppModel()
    let windows: FakeWindowHost
    let voice = FakeVoiceController()
    let lifecycle = FakeLifecycleController()
    let termination = FakeTerminationRequester()
    let coordinator: AppCoordinator

    init(bootstrap: BootstrapCondition) {
        windows = FakeWindowHost()
        coordinator = AppCoordinator(
            model: model,
            windows: WindowCoordinator(host: windows),
            voice: voice,
            lifecycle: lifecycle,
            bootstrap: { bootstrap },
            termination: termination
        )
    }
}

@MainActor
final class FakeVoiceController: VoiceControlling {
    private(set) var shutdownCount = 0
    private(set) var toggleCallCount = 0

    func toggleCall() { toggleCallCount += 1 }
    func setMuted(_ muted: Bool) {}
    func interrupt() {}
    func shutdown() { shutdownCount += 1 }
}

final class FakeLifecycleController: DaemonLifecycleControlling, @unchecked Sendable {
    enum Call: Equatable {
        case enable
        case disable
        case restart
        case discardRecovery
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var interrupted: LifecycleJournalEntry?

    /// The recovery record this account is carrying. A scenario sets the state
    /// it is in; there is no journal file behind this.
    func stageInterruptedTransaction(_ entry: LifecycleJournalEntry) {
        lock.lock()
        interrupted = entry
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }

    func enableBackgroundService() async throws -> LifecycleOutcome {
        record(.enable)
        return .enabled(pid: 1)
    }

    func disableBackgroundService() async throws -> LifecycleOutcome {
        record(.disable)
        return .disabled
    }

    func restartDaemon() async throws -> LifecycleOutcome {
        record(.restart)
        return .restarted(previousPid: 1, currentPid: 2)
    }

    func interruptedTransaction() throws -> LifecycleJournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func discardInterruptedTransaction() throws {
        lock.lock()
        interrupted = nil
        recorded.append(.discardRecovery)
        lock.unlock()
    }
}

@MainActor
final class FakeTerminationRequester: TerminationRequesting {
    private(set) var requested = 0

    func requestTermination() {
        requested += 1
    }
}
