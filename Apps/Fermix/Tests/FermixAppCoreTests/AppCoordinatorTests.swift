import Foundation
import Testing

@testable import FermixAppCore

/// The composition root: what a launch opens, what a `fermix://` url opens,
/// what a menu row does, and what quitting is allowed to touch.
@Suite("App coordinator")
@MainActor
struct AppCoordinatorTests {
    private func makeCoordinator(bootstrap: BootstrapCondition = .present) throws -> CoordinatorHarness {
        try CoordinatorHarness(bootstrap: bootstrap)
    }

    @Test("Home, Setup, Home and Settings reuse the primary window")
    func onboardingUsesThePrimaryWindow() throws {
        let harness = try makeCoordinator()
        var resumed: [OnboardingStage] = []
        harness.coordinator.resumeAssistant = { resumed.append($0) }

        harness.coordinator.open(.home)
        harness.coordinator.openAssistant(at: .aboutYou)
        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .setup)
        #expect(resumed == [.aboutYou])
        #expect(harness.windows.growth.last?.kind == .main)
        #expect(harness.windows.growth.last?.size == WindowMetrics.onboardingSize)

        harness.coordinator.open(.home)
        harness.coordinator.openSettings()

        #expect(harness.windows.presented == [.main])
        #expect(harness.windows.presentations.count == 1)
        #expect(harness.presentation.isShowing)
    }

    @Test(
        "a delayed setup reply cannot replace newer navigation",
        arguments: [AppDestination.surface(.home), .settings(.providers)]
    )
    func newerNavigationWins(_ destination: AppDestination) async throws {
        let harness = try makeCoordinator()
        let reply = PausedSetupReply()
        harness.settingsGateway.setupStateGate = { await reply.wait() }
        defer { reply.released = true }

        harness.coordinator.open(.setup)
        try await reply.waitUntilEntered()
        harness.coordinator.open(destination)
        let route = harness.model.route
        let showingSettings = harness.presentation.isShowing

        reply.released = true
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.route == route)
        #expect(harness.presentation.isShowing == showingSettings)
    }

    @Test("a login launch presents no window")
    func loginLaunchOpensNothing() throws {
        let harness = try makeCoordinator()

        harness.coordinator.start(reason: .login)

        #expect(harness.windows.presented.isEmpty)
    }

    /// The launch that has to read the daemon for itself. It opens no window,
    /// so Home's own refresh never runs, and a menu bar left with nothing to
    /// draw shows the starting glyph and "Fermix is starting" for the whole
    /// session against a daemon that is up.
    @Test("a login launch reads the daemon, since no window will")
    func loginLaunchReadsTheDaemon() throws {
        let harness = try makeCoordinator()
        var reads = 0
        harness.coordinator.readDaemonCondition = { reads += 1 }

        harness.coordinator.start(reason: .login)

        #expect(reads == 1)
    }

    @Test("a user launch opens the main window on Home")
    func userLaunchOpensHome() throws {
        let harness = try makeCoordinator()
        var reads = 0
        harness.coordinator.readDaemonCondition = { reads += 1 }

        harness.coordinator.start(reason: .user)

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .home)
        // The window Home is drawn in makes the read itself; a second one here
        // would be two reads racing on one launch.
        #expect(reads == 0)
    }

    @Test("a fresh account opens onboarding in the primary window")
    func freshAccountOpensOnboarding() throws {
        let harness = try makeCoordinator(bootstrap: .absent)

        harness.coordinator.start(reason: .user)

        #expect(harness.windows.presented == [.main])
    }

    /// The menu bar item is the user's to remove, so the Dock, Launchpad and
    /// Spotlight have to be a way back in. Without this the app can be running
    /// with no window, no status item, and nothing that opens one.
    @Test("reopening with nothing on screen opens the main window")
    func reopenOpensTheWindow() throws {
        let harness = try makeCoordinator()

        harness.coordinator.reopen()

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .home)
    }

    /// A fresh account has nothing to show but onboarding, exactly as a user
    /// launch does: a reopen resolves the same launch rather than a fixed route.
    @Test("reopening a fresh account opens onboarding")
    func reopenOnAFreshAccountOpensOnboarding() throws {
        let harness = try makeCoordinator(bootstrap: .absent)

        harness.coordinator.reopen()

        #expect(harness.windows.presented == [.main])
    }

    /// macOS brings an existing window forward itself. Presenting one here
    /// would move the user off whatever they already had open.
    ///
    /// The question is which windows *this app* has open, not AppKit's count of
    /// visible ones: the floating pet is visible and is not a way back in, so a
    /// pet-only screen has to reopen (M34 §3.1).
    @Test("reopening with a window already up presents nothing")
    func reopenWithAWindowUpDoesNothing() throws {
        let harness = try makeCoordinator()

        harness.coordinator.open(.home)
        let onScreen = harness.windows.presented
        harness.coordinator.reopen()

        #expect(harness.windows.presented == onScreen)
    }

    @Test("reopening an existing primary window refreshes Home without changing its page", arguments: [false, true])
    func reopenRefreshesExistingWindow(showingSettings: Bool) throws {
        let harness = try makeCoordinator()
        harness.coordinator.open(.home)
        if showingSettings { harness.coordinator.openSettings() }
        var reads = 0
        harness.coordinator.readDaemonCondition = { reads += 1 }

        harness.coordinator.reopen()

        #expect(reads == 1)
        #expect(harness.model.route == .home)
        #expect(harness.presentation.isShowing == showingSettings)
        #expect(harness.windows.presentations.count == 1)
    }

    /// The pet floats without a main window, so it must not answer for one.
    @Test("reopening with only the pet on screen opens the main window")
    func reopenWithOnlyThePetOpensTheWindow() throws {
        let harness = try makeCoordinator()

        harness.coordinator.setPetWindow(true)
        harness.coordinator.reopen()

        #expect(harness.windows.presented == [.pet, .main])
    }

    /// §4 writes a record for every interrupted transaction so recovery can
    /// read it. The launch path is that reader; without it the record is a file
    /// nothing opens and the app claims everything is normal.
    @Test("a launch reads the recovery journal and opens recovery")
    func launchReadsTheRecoveryJournal() throws {
        let harness = try makeCoordinator()
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

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.onboardingStage == .recovery)
    }

    /// Acknowledging it is what lets the next transaction start: the coordinator
    /// refuses to begin one over an unresolved record.
    @Test("resolving the interrupted transaction clears the record")
    func resolvingClearsTheRecord() throws {
        let harness = try makeCoordinator()
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
        let harness = try makeCoordinator()

        try harness.coordinator.open(url: URL(string: "fermix://doctor")!)

        #expect(harness.model.route == .doctor)
        #expect(harness.windows.presented == [.main])
    }

    /// An unknown url is refused loudly rather than silently opening Home,
    /// which would tell the user their command worked.
    @Test("an unknown url is refused and opens nothing")
    func unknownUrlIsRefused() throws {
        let harness = try makeCoordinator()

        #expect(throws: AppRouteError.unknownRoute("teleport")) {
            try harness.coordinator.open(url: URL(string: "fermix://teleport")!)
        }
        #expect(harness.windows.presented.isEmpty)
    }

    /// Quitting the GUI releases audio and the realtime socket and sends no
    /// daemon lifecycle command: the daemon outlives the window.
    @Test("quitting releases voice and never touches the daemon")
    func quitReleasesVoiceOnly() throws {
        let harness = try makeCoordinator()

        harness.coordinator.quit()

        #expect(harness.voice.shutdownCount == 1)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.termination.requested == 1)
    }

    @Test("the pet window is toggled rather than opened as a surface")
    func petWindowToggles() throws {
        let harness = try makeCoordinator()

        harness.coordinator.setPetWindow(true)
        #expect(harness.windows.presented == [.pet])

        harness.coordinator.setPetWindow(false)
        #expect(harness.windows.presented.isEmpty)
    }

    @Test("restart runs the daemon restart transaction and nothing else")
    func restartRunsTheTransaction() async throws {
        let harness = try makeCoordinator()

        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == [.restart])
    }

    /// The surfaces state the registration they want rather than toggling: a
    /// switch and a menu row can disagree about what "the other one" is while a
    /// transaction is in flight.
    @Test("the background service is set to a state, not toggled")
    func serviceIsSetToAState() async throws {
        let harness = try makeCoordinator()

        harness.coordinator.setBackgroundService(enabled: false)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.lifecycle.calls == [.disable])

        harness.coordinator.setBackgroundService(enabled: true)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.lifecycle.calls == [.disable, .enable])
    }

    @Test("engine lifecycle actions preserve the GUI on success and failure", arguments: [false, true])
    func engineActionsPreserveTheGUI(fails: Bool) async throws {
        let harness = try makeCoordinator()
        harness.coordinator.open(.logs)
        harness.coordinator.openSettings()
        if fails { harness.lifecycle.stageFailure(.socketNeverAppeared(path: "/tmp/test-daemon.sock")) }

        harness.coordinator.setBackgroundService(enabled: true)
        try await harness.coordinator.drainPendingWork()
        harness.coordinator.setBackgroundService(enabled: false)
        try await harness.coordinator.drainPendingWork()
        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == [.enable, .disable, .restart])
        #expect(harness.windows.presented == [.main])
        #expect(harness.windows.presentations.count == 1)
        #expect(harness.model.route == .logs)
        #expect(harness.presentation.isShowing)
        #expect(harness.termination.requested == 0)
        #expect(harness.voice.shutdownCount == 0)
    }

    @Test("every lifecycle completion refreshes Home after clearing transaction state", arguments: [false, true])
    func lifecycleCompletionRefreshesHome(fails: Bool) async throws {
        let harness = try makeCoordinator()
        var busyAtRefresh: [Bool] = []
        harness.coordinator.readDaemonCondition = { [weak coordinator = harness.coordinator] in
            busyAtRefresh.append(coordinator?.isRunningTransaction == true)
        }
        if fails { harness.lifecycle.stageFailure(.socketNeverAppeared(path: "/tmp/test-daemon.sock")) }

        harness.coordinator.setBackgroundService(enabled: true)
        try await harness.coordinator.drainPendingWork()
        harness.coordinator.setBackgroundService(enabled: false)
        try await harness.coordinator.drainPendingWork()
        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()

        #expect(busyAtRefresh == [false, false, false])
    }

    @Test("recovery opens the assistant in the primary window")
    func recoveryOpensOnboarding() throws {
        let harness = try makeCoordinator()

        harness.coordinator.enterRecovery()

        #expect(harness.windows.presented == [.main])
        #expect(harness.model.onboardingStage == .recovery)
    }
}

@MainActor
private final class PausedSetupReply {
    var entered = false
    var released = false

    func wait() async {
        entered = true
        for _ in 0..<10_000 {
            if released { return }
            await Task.yield()
        }

        Issue.record("the delayed setup reply was not released")
    }

    func waitUntilEntered() async throws {
        for _ in 0..<10_000 {
            if entered { return }
            await Task.yield()
        }

        try #require(entered, "setup routing never requested its deferred reply")
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
    let settings: SettingsModel
    let settingsGateway: FakeDaemonGateway
    /// Whether the primary window is showing settings (decision D1). The
    /// harness holds it so a case can read what a route did to the
    /// presentation, not only to the window.
    let presentation: SettingsPresentation

    init(bootstrap: BootstrapCondition) throws {
        windows = FakeWindowHost()
        settingsGateway = try SettingsFixture.gateway()
        settings = SettingsFixture.model(gateway: settingsGateway)
        let coordinated = WindowCoordinator(host: windows)
        presentation = SettingsPresentation { coordinated.growForSettings() }
        coordinator = AppCoordinator(
            model: model,
            windows: coordinated,
            voice: voice,
            lifecycle: lifecycle,
            bootstrap: { bootstrap },
            termination: termination,
            settings: settings,
            presentation: presentation
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
    private var failure: LifecycleFailure?

    func stageFailure(_ failure: LifecycleFailure) {
        lock.lock()
        self.failure = failure
        lock.unlock()
    }

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

    private func record(_ call: Call) throws {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        if let failure { throw failure }
    }

    func enableBackgroundService() async throws -> LifecycleOutcome {
        try record(.enable)
        return .enabled(pid: 1)
    }

    func disableBackgroundService() async throws -> LifecycleOutcome {
        try record(.disable)
        return .disabled
    }

    func restartDaemon() async throws -> LifecycleOutcome {
        try record(.restart)
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
