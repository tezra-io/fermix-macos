import Foundation
import Testing

@testable import FermixAppCore

/// The onboarding model: the journey as it actually runs, with activation and
/// the daemon behind seams.
@Suite("Onboarding model")
@MainActor
struct OnboardingModelTests {
    @Test("beginning runs activation and lands on the first configure surface")
    func beginActivates() async throws {
        let harness = try OnboardingHarness()

        harness.model.begin()
        await harness.model.drainPendingWork()

        #expect(harness.activation.runs == 1)
        #expect(harness.model.stage == .configureAI)
    }

    /// Activation's stages reach the ladder, so the headline the user reads is
    /// the one the transaction actually got to.
    @Test("the ladder follows activation's reported stages")
    func ladderFollowsActivation() async throws {
        let harness = try OnboardingHarness()
        harness.activation.reportedStages = [.registering, .starting, .preparing]

        harness.model.begin()
        await harness.model.drainPendingWork()
        await harness.settle()

        #expect(harness.model.ladder.rows.map(\.state) == [.done, .done, .active])
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

    /// Doctor answers from the running daemon, so it is the useful next step
    /// even when the daemon never started. The card's actions go there and to
    /// Logs, not back into the same failed screen.
    @Test("the boot-failure actions route to Doctor and Logs")
    func failureActionsRoute() async throws {
        let harness = try OnboardingHarness()

        harness.model.openDoctor()
        harness.model.openLogs()
        harness.model.finish()

        #expect(harness.routes == [.doctor, .logs, .home])
    }

    @Test("readiness comes from the daemon's own overview")
    func readinessFromTheDaemon() async throws {
        let harness = try OnboardingHarness()

        await harness.model.refreshReadiness()

        #expect(harness.model.machine.readiness.canFinish)
        #expect(harness.gateway.calls.contains(.overview))
    }

    /// A daemon that cannot answer is not a configured one. Readiness falls to
    /// nothing rather than keeping the last good answer, which would let Ready
    /// open on a daemon that has since died.
    @Test("an unreachable daemon reads as not ready")
    func unreachableDaemonIsNotReady() async throws {
        let harness = try OnboardingHarness()
        harness.gateway.overviewFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        await harness.model.refreshReadiness()

        #expect(!harness.model.machine.readiness.canFinish)
    }

    @Test("retrying a failure runs activation again")
    func retryRunsActivationAgain() async throws {
        let harness = try OnboardingHarness()
        harness.activation.outcome = .failed(.timedOut)

        harness.model.begin()
        await harness.model.drainPendingWork()
        harness.model.retry()
        await harness.model.drainPendingWork()

        #expect(harness.activation.runs == 2)
        #expect(harness.model.stage == .bootFailed)
    }

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
    }
}

@MainActor
final class OnboardingHarness {
    let gateway = FakeDaemonGateway()
    let activation = FakeActivationDriver()
    let opener = RecordingExternalOpener()
    let recorder = RouteRecorder()
    let model: OnboardingModel

    static let launcherPath = "/Applications/Fermix.app/Contents/MacOS/fermix"

    var routes: [AppRoute] { recorder.routes }
    var recoveryResolutions: Int { recorder.recoveryResolutions }

    init() throws {
        gateway.hello = try ManagementValueFixture.hello()
        gateway.overviewResult = try ManagementValueFixture.overview()
        gateway.setupSession = try ManagementValueFixture.setupSession()
        gateway.logPages = [try ManagementValueFixture.logPage(messages: ["a line"])]
        activation.hello = try ManagementValueFixture.hello()

        let recorder = self.recorder
        model = OnboardingModel(
            gateway: gateway,
            activation: activation,
            setup: SetupModel(gateway: gateway, opener: opener),
            planner: CLILinkPlanner(
                launcherPath: OnboardingHarness.launcherPath,
                // The bundle ships the launcher the command links to; with no
                // launcher there is nothing to offer.
                inspector: StubLinkInspector(files: [OnboardingHarness.launcherPath])
            ),
            onRoute: { route in recorder.record(route) },
            onRecoveryResolved: { recorder.recordRecoveryResolved() }
        )
    }

    /// Lets any main-actor continuation the model started run, without a
    /// wall-clock wait.
    func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

/// Records the routes onboarding asked the app to open.
@MainActor
final class RouteRecorder {
    private(set) var routes: [AppRoute] = []
    private(set) var recoveryResolutions = 0

    func record(_ route: AppRoute) {
        routes.append(route)
    }

    func recordRecoveryResolved() {
        recoveryResolutions += 1
    }
}

/// Activation, scripted. It reports whatever stages a test names and ends in
/// whatever outcome the test chose, so the model's half of the journey is
/// provable without a daemon, a socket, or a login item.
@MainActor
final class FakeActivationDriver: ActivationDriving {
    private(set) var runs = 0

    var outcome: ActivationOutcome?
    var reportedStages: [ActivationStage] = []
    var hello: ManagementHello?

    func activate(progress: @escaping (ActivationStage) -> Void) async -> ActivationOutcome {
        runs += 1

        for stage in reportedStages {
            progress(stage)
        }

        if let outcome { return outcome }
        guard let hello else {
            return .failed(.invalidPackage)
        }

        return .activated(hello)
    }
}
