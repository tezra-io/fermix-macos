import Foundation
import Testing

@testable import FermixAppCore

/// Home: the status hero, Runtime and Attention, and the two independent
/// registrations. The mock Recent Activity feed is gone; every row here comes
/// from `overview.get` and `hello`.
@Suite("Home surface")
@MainActor
struct HomeSurfaceTests {
    private func snapshot(
        provider: String? = "openai_codex",
        channelEnabled: Bool = true,
        channelStatus: String = "ok",
        health: String = "ok",
        restartRequired: Bool = false,
        failedJobs: Int = 0,
        serviceEnabled: Bool = true,
        update: UpdateAvailability = .unknown
    ) throws -> HomeSnapshot {
        HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: try ManagementValueFixture.overview(
                provider: provider,
                channelEnabled: channelEnabled,
                channelStatus: channelStatus,
                health: health,
                restartRequired: restartRequired,
                failedJobs: failedJobs
            ),
            serviceEnabled: serviceEnabled,
            update: update
        )
    }

    @Test("a running daemon with a provider reads as running, with a humane uptime")
    func runningHero() throws {
        let home = try snapshot()

        #expect(home.statusTitle == ProductStrings[.homeStatusRunning])
        #expect(home.statusTone == .pass)
        #expect(home.uptime == "for 3 days 4 hours")
    }

    /// Setup completeness is the same fact onboarding gates Ready on, so Home
    /// says `Setup required` rather than inventing a second definition.
    @Test("an unconfigured provider reads as setup required")
    func setupRequiredHero() throws {
        let home = try snapshot(provider: nil)

        #expect(home.statusTitle == ProductStrings[.homeStatusSetupRequired])
        #expect(home.statusTone == .warn)
        #expect(!home.setupComplete)
    }

    @Test("the hero chips name the provider and the enabled channel")
    func heroChips() throws {
        let home = try snapshot()

        #expect(home.chips == ["openai_codex · gpt-5.6-sol", "telegram"])
    }

    // MARK: - Runtime

    /// Runtime carries authoritative facts only: the engine version, the
    /// protocol window, uptime, the provider, and the channels.
    @Test("runtime rows are authoritative facts, in a stable order")
    func runtimeRows() throws {
        let home = try snapshot()

        #expect(home.runtime.map(\.id) == ["engine", "protocol", "uptime", "provider", "channels"])
        #expect(home.runtime.first?.detail == "0.9.0")
    }

    @Test("the protocol row states the window the daemon published")
    func protocolRow() throws {
        let home = try snapshot()

        #expect(home.runtime.first { $0.id == "protocol" }?.detail == "v1")
    }

    @Test("with nothing to report, Runtime draws its empty state rather than a blank card")
    func runtimeEmptyState() {
        let home = HomeSnapshot(hello: nil, overview: nil, serviceEnabled: false, update: .unknown)

        #expect(home.runtime.isEmpty)
        #expect(home.runtimeEmpty.message == ProductStrings[.homeRuntimeEmpty])
    }

    // MARK: - Attention

    @Test("a healthy daemon needs no attention and says so")
    func nothingNeedsAttention() throws {
        let home = try snapshot()

        #expect(home.attention.isEmpty)
        #expect(home.attentionEmpty.message == ProductStrings[.homeAttentionEmpty])
    }

    @Test("an incomplete setup is the first thing Attention names")
    func setupRequiredIsAnAttentionRow() throws {
        let home = try snapshot(provider: nil)

        #expect(home.attention.first?.id == "setup")
        #expect(home.attention.first?.tone == .warn)
    }

    @Test("a restart-required health report reaches Attention with its one next action")
    func restartRequiredIsAnAttentionRow() throws {
        let home = try snapshot(restartRequired: true)

        let row = home.attention.first { $0.id == "restart_required" }
        #expect(row != nil)
        #expect(row?.detail == ProductStrings[.homeAttentionRestartRequired])
    }

    @Test("an enabled channel that is not ok reaches Attention")
    func brokenChannelIsAnAttentionRow() throws {
        let home = try snapshot(channelStatus: "error")

        #expect(home.attention.contains { $0.id == "channel.telegram" })
    }

    @Test("a disabled channel is not a warning, it is a choice")
    func disabledChannelIsNotAWarning() throws {
        let home = try snapshot(channelEnabled: false)

        #expect(!home.attention.contains { $0.id.hasPrefix("channel.") })
    }

    @Test("recently failed jobs reach Attention with their count")
    func failedJobsReachAttention() throws {
        let home = try snapshot(failedJobs: 3)

        let row = home.attention.first { $0.id == "jobs" }
        #expect(row?.meta == "3")
    }

    /// The background service being off is a fact about the machine, not a
    /// defect, but it is the first thing a user with a silent Fermix needs.
    @Test("a disabled background service is named in Attention")
    func disabledServiceIsNamed() throws {
        let home = try snapshot(serviceEnabled: false)

        #expect(home.attention.contains { $0.id == "background_service" })
    }

    // MARK: - Update card

    /// Sparkle is §6 work. The card is wired to a seam that reports `unknown`
    /// in this build, and the card says exactly that rather than claiming the
    /// app is up to date.
    @Test("the update card reports only what the seam can observe")
    func updateCardIsHonest() throws {
        #expect(try snapshot(update: .unknown).updateSummary == ProductStrings[.homeUpdateUnknown])
        #expect(try snapshot(update: .upToDate(lastCheckedAt: nil)).updateSummary == ProductStrings[.homeUpdateCurrent])

        let available = try snapshot(update: .available(version: "0.9.1")).updateSummary
        #expect(available.contains("0.9.1"))
    }

    @Test("the unwired update checker claims nothing")
    func unwiredCheckerClaimsNothing() async {
        #expect(await UnwiredUpdateChecker().availability() == .unknown)
    }

    // MARK: - Actions

    @Test("the service action is enable or disable, never start or stop")
    func serviceActionWording() throws {
        #expect(try snapshot(serviceEnabled: true).serviceActionTitle == ProductStrings[.serviceDisable])
        #expect(try snapshot(serviceEnabled: false).serviceActionTitle == ProductStrings[.serviceEnable])
    }

    @Test("the model refreshes from the daemon and reports what it read")
    func modelRefresh() async throws {
        let harness = try HomeHarness()

        await harness.model.refresh()

        #expect(harness.gateway.calls == [.negotiate, .overview])
        #expect(harness.model.snapshot.statusTitle == ProductStrings[.homeStatusRunning])
    }

    @Test("a daemon that cannot be reached leaves Home truthful rather than blank")
    func modelReportsAFailure() async throws {
        let harness = try HomeHarness()
        harness.gateway.negotiateFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        await harness.model.refresh()

        #expect(harness.model.snapshot.statusTitle == ProductStrings[.homeStatusUnreachable])
        #expect(harness.model.snapshot.statusTone == .fail)
    }

    /// The two login registrations are independent in both directions: turning
    /// the GUI's off never touches the daemon's.
    @Test("the GUI login toggle never changes the background service")
    func loginTogglesAreIndependent() async throws {
        let harness = try HomeHarness()
        try harness.loginItems.register(.agent)

        harness.model.setOpenAtLogin(true)
        #expect(harness.loginItems.status(.mainApp) == .enabled)
        #expect(harness.loginItems.status(.agent) == .enabled)

        harness.model.setOpenAtLogin(false)
        #expect(harness.loginItems.status(.mainApp) == .notRegistered)
        #expect(harness.loginItems.status(.agent) == .enabled, "the daemon's registration is untouched")
    }

    @Test("the background-service action runs the lifecycle transaction, not a process kill")
    func serviceActionRunsTheTransaction() async throws {
        let harness = try HomeHarness()
        harness.model.setBackgroundService(false)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == [.disable])
    }
}

@MainActor
final class HomeHarness {
    let gateway = FakeDaemonGateway()
    let loginItems = FakeLoginItemService()
    let lifecycle = FakeLifecycleController()
    let appModel = AppModel()
    let windows = FakeWindowHost()
    let coordinator: AppCoordinator
    let model: HomeModel

    init() throws {
        gateway.hello = try ManagementValueFixture.hello()
        gateway.overviewResult = try ManagementValueFixture.overview()

        appModel.serviceEnabled = true
        coordinator = AppCoordinator(
            model: appModel,
            windows: WindowCoordinator(host: windows),
            voice: FakeVoiceController(),
            lifecycle: lifecycle,
            bootstrap: { .present },
            termination: FakeTerminationRequester()
        )
        model = HomeModel(
            gateway: gateway,
            services: ServiceController(loginItems: loginItems),
            coordinator: coordinator,
            updates: UnwiredUpdateChecker()
        )
    }
}
