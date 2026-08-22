import Foundation
import Testing

@testable import FermixAppCore

/// Activation: register both principals independently, wait for the daemon,
/// negotiate, and prove the local web surface answers — inside one 90-second
/// budget, with every failure it can end in named separately.
@Suite("Activation coordinator")
@MainActor
struct ActivationCoordinatorTests {
    private func harness(
        registered: Bool = false,
        daemonRunning: Bool = true
    ) throws -> ActivationHarness {
        try ActivationHarness(registered: registered, daemonRunning: daemonRunning)
    }

    @Test("a clean activation registers, negotiates, and proves the web surface")
    func cleanActivation() async throws {
        let harness = try harness()

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated(let hello) = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
        #expect(hello.engine.pid == "4242")
        #expect(harness.loginItems.registerCalls.contains(.agent))
        #expect(harness.gateway.calls.contains(.negotiate))
        #expect(harness.web.probedOrigins == ["http://127.0.0.1:4030"])
    }

    /// Both login registrations default on and are registered independently.
    @Test("activation registers the daemon and the GUI as two separate items")
    func bothPrincipalsAreRegistered() async throws {
        let harness = try harness()

        _ = await harness.coordinator.activate { _ in }

        #expect(Set(harness.loginItems.registerCalls) == Set(LoginItemPrincipal.allCases))
    }

    @Test("the ladder is reported in order, once per stage")
    func stagesAreReportedInOrder() async throws {
        let harness = try harness()
        let stages = StageRecorder()

        _ = await harness.coordinator.activate { stages.record($0) }

        #expect(stages.recorded == [.registering, .starting, .preparing])
    }

    // MARK: - The seven named failures

    /// macOS reports one status for "waiting for your approval" and "you turned
    /// it off", so the second signal is whether this activation is the one that
    /// registered: a fresh registration awaiting consent is approval pending.
    @Test("a fresh registration awaiting consent is approval pending")
    func approvalPending() async throws {
        let harness = try harness()
        harness.loginItems.nextStatus[.agent] = .requiresApproval

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.approvalPending))
    }

    /// The same status on an item that was already registered before this run
    /// means the user turned the background item off.
    @Test("an already-registered item still awaiting approval is a disabled background item")
    func backgroundItemDisabled() async throws {
        let harness = try harness()
        harness.loginItems.preregisterApprovalPending(.agent)
        harness.loginItems.nextStatus[.agent] = .requiresApproval

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.backgroundItemDisabled))
    }

    @Test("an item macOS cannot find is an invalid package, not a retry")
    func invalidPackage() async throws {
        let harness = try harness()
        harness.loginItems.nextStatus[.agent] = .notFound

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.invalidPackage))
    }

    @Test("a daemon outside this app's protocol window is an incompatible version")
    func incompatibleVersion() async throws {
        let harness = try harness()
        harness.gateway.negotiateFailure = ManagementError.unsupportedProtocolVersion(
            declared: 1,
            minimum: 2,
            maximum: 3
        )

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.incompatibleVersion))
    }

    @Test("a daemon-too-old refusal is also an incompatible version")
    func daemonTooOld() async throws {
        let harness = try harness()
        harness.gateway.negotiateFailure = ManagementError.daemon(
            ManagementFailure(
                code: .daemonTooOld,
                message: "daemon speaks v0 only",
                details: ManagementScalarMap(values: [:])
            )
        )

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.incompatibleVersion))
    }

    /// A socket that appears and vanishes three times is launchd restarting a
    /// daemon that keeps dying, which is a different failure from a slow start.
    @Test("three socket disappearances are a crash loop")
    func crashLoop() async throws {
        let harness = try harness(daemonRunning: true)
        harness.socket.flapCount = ActivationPolicy.crashLoopThreshold

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.crashLoop))
        #expect(harness.gateway.calls.isEmpty, "a crash loop never reaches negotiation")
    }

    /// The daemon answered, so the engine is alive; something else is holding
    /// the port it needs.
    @Test("a live daemon whose origin is held by another program is a bind failure")
    func bindFailure() async throws {
        let harness = try harness()
        harness.web.isLive = false
        harness.ports.accepting = true

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.bindFailure))
        #expect(harness.ports.probedOrigins == ["http://127.0.0.1:4030"])
    }

    @Test("a live daemon with nothing listening at its origin is a web-unavailable failure")
    func webUnavailable() async throws {
        let harness = try harness()
        harness.web.isLive = false
        harness.ports.accepting = false

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.webUnavailable))
    }

    @Test("a socket that never appears inside the budget times out")
    func timesOut() async throws {
        let harness = try harness(daemonRunning: false)
        harness.socket.neverAppears = true

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.timedOut))
    }

    /// The whole run is bounded at 90 seconds, and the bound is what turns a
    /// stalled start into a surface the user can act on.
    @Test("activation spends no more than its 90-second budget")
    func budgetIsNinetySeconds() async throws {
        let harness = try harness(daemonRunning: false)
        harness.socket.neverAppears = true

        _ = await harness.coordinator.activate { _ in }

        let elapsed = harness.clock.now.timeIntervalSince(harness.start)
        #expect(ActivationPolicy.budget == 90)
        #expect(elapsed <= ActivationPolicy.budget + ActivationPolicy.pollInterval)
    }

    /// Onboarding asks for no microphone and no computer-use permission. The
    /// whole consent surface of activation is the two login registrations, and
    /// no cause it can end in names a permission it would have had to prompt for.
    @Test("the only consent activation touches is the two login registrations")
    func consentSurfaceIsOnlyLoginItems() async throws {
        let harness = try harness()

        _ = await harness.coordinator.activate { _ in }

        #expect(Set(harness.loginItems.registerCalls) == Set(LoginItemPrincipal.allCases))
        #expect(!BootFailureCause.allCases.contains { $0.rawValue.lowercased().contains("microphone") })
        #expect(!BootFailureCause.allCases.contains { $0.rawValue.lowercased().contains("permission") })
    }

    /// The liveness gate is `/health/live`. `/health/ready` reports whether the
    /// daemon has finished warming, which is a different question and would keep
    /// Setup hidden long after it works.
    @Test("the liveness gate is health/live and never health/ready")
    func gatesOnHealthLive() {
        #expect(HTTPWebLiveness.path == "/health/live")
    }

    /// The live incident this guards: a dist-staged bundle activated by the
    /// masked window's default button wrote the record and registered login
    /// items. A refusal must precede every mutation.
    @Test("a bundle outside Applications is refused before anything is written or registered")
    func refusesOutsideApplications() async throws {
        let harness = try ActivationHarness(registered: false, daemonRunning: true)
        harness.installation.canonical = false

        let outcome = await harness.coordinator.activate { _ in }

        guard case .failed(let cause) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(cause == .notInApplications)
        #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
        #expect(harness.loginItems.status(.agent) != .enabled)
        #expect(harness.loginItems.status(.mainApp) != .enabled)
    }

    @Test("a recognized Homebrew service unit is refused toward migrate-to-app, mutating nothing")
    func refusesBesideLegacyInstall() async throws {
        let harness = try ActivationHarness(registered: false, daemonRunning: true)
        harness.installation.legacyUnit = true

        let outcome = await harness.coordinator.activate { _ in }

        guard case .failed(let cause) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(cause == .legacyInstallPresent)
        #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
        #expect(harness.loginItems.status(.agent) != .enabled)
    }
}

/// The activation coordinator with every seam replaced, wired to a throwaway
/// directory so no real account is touched.
@MainActor
final class ActivationHarness {
    let root: URL
    let location: BootstrapLocation
    let store: BootstrapStore
    let loginItems: ApprovalAwareLoginItemService
    let gateway = FakeDaemonGateway()
    let socket = FlappingPathPresence()
    let installation = FakeInstallationProbe()
    let web = FakeWebLiveness()
    let ports = FakePortProbe()
    let clock = ManualClock()
    let start: Date
    let coordinator: ActivationCoordinator

    init(registered: Bool, daemonRunning: Bool) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-activation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        location = BootstrapLocation(homeDirectory: root)
        try FileManager.default.createDirectory(
            at: location.defaultFermixHome,
            withIntermediateDirectories: true
        )

        store = BootstrapStore(location: location)
        loginItems = ApprovalAwareLoginItemService()
        if registered {
            loginItems.preregister(.agent)
        }
        socket.present = daemonRunning
        start = clock.now

        gateway.hello = try ManagementValueFixture.hello()
        gateway.overviewResult = try ManagementValueFixture.overview()

        coordinator = ActivationCoordinator(
            store: store,
            services: ServiceController(loginItems: loginItems),
            gateway: gateway,
            paths: socket,
            installation: installation,
            web: web,
            ports: ports,
            sleeper: ClockAdvancingSleeper(clock: clock),
            now: clock.reader
        )
    }

    deinit {
        let path = root.path
        guard path.contains("fermix-activation-tests"), path.split(separator: "/").count >= 4 else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The installation facts activation preflights on: canonical by default so
/// the existing scenarios run unrefused; each refusal test flips one fact.
final class FakeInstallationProbe: InstallationProbing, @unchecked Sendable {
    var canonical = true
    var legacyUnit = false

    func isCanonicallyInstalled() -> Bool { canonical }
    func legacyServiceUnitExists() -> Bool { legacyUnit }
}

/// Records the ladder stages activation reported, in order.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ActivationStage] = []

    var recorded: [ActivationStage] { lock.withLock { stages } }

    func record(_ stage: ActivationStage) {
        lock.withLock { stages.append(stage) }
    }
}

/// A login-item double that can start in the approval-pending state, which is
/// what separates "waiting for consent" from "the user turned it off".
final class ApprovalAwareLoginItemService: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]

    var nextStatus: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]
    var registerError: (any Error)?

    private(set) var registerCalls: [LoginItemPrincipal] = []

    func preregister(_ principal: LoginItemPrincipal) {
        lock.withLock { statuses[principal] = .enabled }
    }

    func preregisterApprovalPending(_ principal: LoginItemPrincipal) {
        lock.withLock { statuses[principal] = .requiresApproval }
    }

    func register(_ principal: LoginItemPrincipal) throws {
        try lock.withLock {
            registerCalls.append(principal)
            if let registerError { throw registerError }
            statuses[principal] = nextStatus[principal] ?? .enabled
        }
    }

    func unregister(_ principal: LoginItemPrincipal) throws {
        lock.withLock { statuses[principal] = .notRegistered }
    }

    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        lock.withLock { statuses[principal] ?? .notRegistered }
    }
}

/// A socket path that can be absent forever, present immediately, or flap a
/// chosen number of times before settling.
final class FlappingPathPresence: PathPresence, @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0

    var present = true
    var neverAppears = false
    /// How many present-then-absent transitions to produce before settling.
    var flapCount = 0

    func exists(atPath path: String) -> Bool {
        lock.withLock {
            guard !neverAppears else { return false }
            polls += 1
            guard flapCount > 0 else { return present }

            // Alternate present/absent for twice the flap count, then settle.
            let flapping = polls <= flapCount * 2
            return flapping ? polls.isMultiple(of: 2) == false : true
        }
    }
}

/// Counts microphone permission requests so a surface that asks for one can be
/// caught. Nothing else on the engine is exercised here.
final class PermissionCountingAudioEngine: VoiceAudioEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var isPlayingBack = false

    var permissionRequests: Int { lock.withLock { requests } }

    func requestCapturePermission() async throws {
        lock.withLock { requests += 1 }
    }

    func prepareCapture() throws {}
    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {}
    func setCaptureMuted(_ muted: Bool) {}
    func play(base64PCM16 encoded: String) {}
    func stopPlayback() {}
    func resetUtteranceAnchor() {}
    func currentUtterancePlayedMs() -> Int? { nil }
    func shutdown() {}
    func diagnostics() -> String { "stub" }
}
