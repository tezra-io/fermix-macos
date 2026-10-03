import Foundation
import Testing

@testable import FermixAppCore

/// The dispatch half of M34 §3.3: what a command actually does, and whether it
/// can run right now.
///
/// `CommandTableTests` and `StatusMenuTests` prove the table and the two menu
/// renderers against a fake router, which leaves the real one — the single owner
/// of both answers — provable only here. Without these, `showLogs` could open
/// Doctor and every menu test would still pass.
@Suite("Command router")
@MainActor
struct CommandRouterTests {
    @Test("each surface command opens the route it names")
    func surfaceCommandsOpenTheirRoutes() async throws {
        let harness = try RouterHarness()

        let routes: [(AppCommand, AppRoute)] = [
            (.showChat, .chat),
            (.showDoctor, .doctor),
            (.showLogs, .logs),
            (.showPet, .pet),
            (.showHome, .home)
        ]

        for (command, route) in routes {
            harness.router.perform(command)
            try await harness.coordinator.drainPendingWork()

            #expect(harness.model.route == route, "\(command.rawValue)")
        }

        harness.model.route = .logs
        harness.router.perform(.openFermix)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.model.route == .home, "the status item's Open Fermix lands on Home")
        #expect(harness.windows.presented == [.main])
    }

    /// "Show browser" opens the pane on its own, with no tab in it, so the
    /// person can watch or browse without waiting for a link (plan §4.10).
    @Test("Show browser opens the pane with nothing to show yet")
    func showBrowserOpensThePane() throws {
        let harness = try RouterHarness()

        #expect(!harness.browserHarness.model.isOpen)
        harness.router.perform(.showBrowser)

        #expect(harness.browserHarness.model.isOpen)
        #expect(harness.browserHarness.model.tabs.isEmpty)
    }

    /// Home's tinted primary takes the same route `fermix://setup` does: the
    /// assistant while a gating readiness failure stands, the settings
    /// presentation once none does (M34 §3.4, decision D1).
    @Test("Continue setup lands where fermix://setup lands")
    func continueSetupOpensTheSameSurface() async throws {
        let harness = try RouterHarness()
        // The golden home is ready; the gate is a primary with no credential.
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(primaryConfigured: false)

        // The route asks the daemon where to land before it lands (M34 §3.4):
        // the gating failure is the primary's missing credential, so it opens
        // the screen that clears it. Starting is where it lands when nothing
        // answers, not where it lands because nothing has been asked yet.
        harness.router.perform(.continueSetup)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.windows.presented == [.main])
        #expect(harness.model.onboardingStage == .connectAI)
        #expect(!harness.presentation.isShowing)
    }

    /// The tinted action exists only while its condition holds: a finished
    /// install has nothing to continue, so Home's toolbar carries no primary at
    /// all rather than a permanently dimmed one (M34 §3.2).
    ///
    /// The *command* stays performable, because the Daemon menu's `Open Setup
    /// Assistant` lands on the settings presentation when nothing gates
    /// (M34 §3.4) and a dimmed row there would refuse a url the app honours.
    @Test("Home carries no primary once readiness is ready")
    func continueSetupFollowsReadiness() async throws {
        let harness = try RouterHarness()

        #expect(
            CommandTable.toolbar(for: .home, condition: harness.surfaces.home.toolbarCondition).primary
                == .continueSetup,
            "nothing has been read yet"
        )

        harness.gateway.overviewResult = try ManagementValueFixture.overview(readiness: "ready")
        await harness.surfaces.home.refresh()

        #expect(harness.surfaces.home.snapshot.setupComplete)
        #expect(CommandTable.toolbar(for: .home, condition: harness.surfaces.home.toolbarCondition).primary == nil)
        #expect(harness.router.canPerform(.continueSetup), "the menu row still opens settings")
    }

    /// The second condition M34 §3.2 names: while the launch reconcile is
    /// pending, Home's primary is the restart that finishes the update.
    @Test("a pending reconcile puts the restart in Home's primary slot")
    func homePrimaryFollowsTheReconcile() {
        let pending = ToolbarCondition(setupComplete: true, reconcilePending: true)

        #expect(CommandTable.toolbar(for: .home, condition: pending).primary == .restartDaemon)
        #expect(CommandTable.toolbar(for: .home, condition: .unknown).primary == .continueSetup)
    }

    /// A refused command performs nothing, so the window never moves.
    @Test("a refused command moves nothing")
    func refusedCommandMovesNothing() throws {
        let harness = try RouterHarness()
        harness.updates.accepts = false

        let before = harness.windows.presented
        harness.router.perform(.checkForUpdates)
        #expect(harness.windows.presented == before)
        #expect(harness.updates.checks == 0)
    }

    /// Command-comma and the pinned sidebar row are the same command, and it
    /// enters the presentation rather than opening a window.
    @Test("the settings command enters the presentation of the primary window")
    func settingsCommandEntersThePresentation() async throws {
        let harness = try RouterHarness()
        harness.model.route = .logs

        harness.router.perform(.openSettings)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.windows.presented == [.main])
        #expect(harness.presentation.isShowing)
        #expect(harness.presentation.returnRoute == .logs)
    }

    @Test("the sidebar toggle flips the sidebar and nothing else")
    func sidebarToggle() throws {
        let harness = try RouterHarness()

        #expect(harness.router.isOn(.toggleSidebar))

        harness.router.perform(.toggleSidebar)
        #expect(harness.sidebar.visibility == .detailOnly)
        #expect(!harness.router.isOn(.toggleSidebar))

        harness.router.perform(.toggleSidebar)
        #expect(harness.sidebar.visibility == .all)
        #expect(harness.windows.presented.isEmpty, "toggling a column opened a window")
    }

    /// A restart is never taken on the click: the command asks, and only the
    /// sheet's own action runs the transaction (M34 §5.10). The title's ellipsis
    /// is what says so.
    @Test("restart asks first and runs no transaction")
    func restartAsksFirst() async throws {
        let harness = try RouterHarness()

        harness.router.perform(.restartDaemon)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.model.restartSheetShown)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.windows.presented == [.main], "the sheet needs a window to sit in")
    }

    /// What the sheet's own confirm runs, which is the one journaled
    /// transaction and not a second path of its own.
    @Test("the restart sheet's confirm runs the transaction")
    func restartSheetConfirmRunsTheTransaction() async throws {
        let harness = try RouterHarness()

        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == [.restart])
    }

    /// M34 §4: the surfaces state the registration they want. The menu row
    /// carries the state the app is in and performs the opposite one, so a row
    /// reading "Disable" can only ever run the disable transaction.
    @Test("the background service command sets the opposite of the state it names")
    func backgroundServiceSetsTheOppositeState() async throws {
        let harness = try RouterHarness()
        harness.loginItems.preregister(.agent)
        await harness.surfaces.home.refreshRegistrations()

        #expect(harness.surfaces.home.backgroundServiceEnabled)
        #expect(harness.router.isOn(.toggleBackgroundService))
        harness.router.perform(.toggleBackgroundService)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.lifecycle.calls == [.disable])

        harness.loginItems.preregister(.agent, as: .notRegistered)
        await harness.surfaces.home.refreshRegistrations()
        #expect(!harness.router.isOn(.toggleBackgroundService))
        harness.router.perform(.toggleBackgroundService)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.lifecycle.calls == [.disable, .enable])
    }

    /// The title and the action read the same fact. Reading `model.petShown` for
    /// the title would let a row say "Show Pet" over an action that hides it.
    @Test("the pet row's title and its action read the same window state")
    func petRowTitleFollowsTheWindow() throws {
        let harness = try RouterHarness()

        #expect(!harness.router.isOn(.toggleFloatingPet))

        harness.router.perform(.toggleFloatingPet)
        #expect(harness.windows.presented == [.pet])
        #expect(harness.router.isOn(.toggleFloatingPet))

        harness.router.perform(.toggleFloatingPet)
        #expect(harness.windows.presented.isEmpty)
        #expect(!harness.router.isOn(.toggleFloatingPet))
    }

    /// The row is the discoverable half of Command-drag. It takes the item off
    /// the bar and touches nothing else: the daemon keeps running, and the app
    /// stays reachable from the Dock.
    @Test("the hide row takes the item off the menu bar and stops nothing")
    func hideRowRemovesTheItem() throws {
        let harness = try RouterHarness()

        #expect(harness.router.canPerform(.hideMenuBarItem))

        harness.router.perform(.hideMenuBarItem)

        #expect(harness.statusItem.isVisible == false)
        #expect(harness.lifecycle.calls.isEmpty, "hiding the item touched the daemon")
        #expect(harness.termination.requested == 0)
    }

    /// A row that would do nothing is dimmed rather than silently inert, which
    /// is the rule every other command in the table follows.
    @Test("the hide row is refused once the item is already off the bar")
    func hideRowIsRefusedWhenAlreadyHidden() throws {
        let harness = try RouterHarness()
        harness.statusItem.isVisible = false

        #expect(harness.router.canPerform(.hideMenuBarItem) == false)
    }

    @Test("quitting releases voice and requests termination")
    func quitRequestsTermination() async throws {
        let harness = try RouterHarness()

        harness.router.perform(.quit)
        // Quitting finishes a staged update's stop first (M34 §6, R3), so it
        // is a task rather than a call.
        try await harness.coordinator.drainPendingWork()

        #expect(harness.termination.requested == 1)
        #expect(harness.lifecycle.calls.isEmpty, "quitting touched the daemon")
    }

    @Test("the log commands act on the Logs surface")
    func logCommandsActOnLogs() async throws {
        let harness = try RouterHarness()
        await harness.surfaces.logs.refresh()

        harness.router.perform(.pauseLogs)
        #expect(harness.surfaces.logs.paused)
        #expect(harness.router.isOn(.pauseLogs))

        harness.router.perform(.exportLogs)
        try await harness.coordinator.drainPendingWork()
        #expect(harness.surfaces.logs.exportRequested)
        #expect(harness.model.route == .logs, "Export opened the surface it exports from")
    }

    /// A support action is Doctor's, and reaching it from the File menu has to
    /// put Doctor on screen rather than run it invisibly.
    @Test("the support bundle command opens Doctor and asks it for the bundle")
    func supportBundleCommandRunsThroughDoctor() async throws {
        let harness = try RouterHarness()

        harness.router.perform(.exportSupportBundle)
        try await harness.settle()

        #expect(harness.model.route == .doctor)
        #expect(harness.gateway.calls.contains(.diagnostics))
    }

    // MARK: - What can run right now

    /// The row follows the updater's own answer rather than a value written
    /// here (M34 §6, R2). A build that runs no updater draws it dimmed, which
    /// is what M34 §3.3 asks for, and a build that does performs a real check.
    @Test("check for updates follows the updater", arguments: [false, true])
    func checkForUpdatesFollowsTheUpdater(accepts: Bool) throws {
        let harness = try RouterHarness()
        harness.updates.accepts = accepts

        #expect(harness.router.canPerform(.checkForUpdates) == accepts)

        harness.router.perform(.checkForUpdates)

        #expect(harness.updates.checks == (accepts ? 1 : 0))
    }

    @Test("exporting and copying logs is refused while there is nothing to export")
    func logExportNeedsEntries() async throws {
        let harness = try RouterHarness()

        #expect(!harness.router.canPerform(.exportLogs))
        #expect(!harness.router.canPerform(.copyLogs))

        await harness.surfaces.logs.refresh()

        #expect(harness.router.canPerform(.exportLogs))
        #expect(harness.router.canPerform(.copyLogs))
    }

    /// A second run while one is in flight would start a session the first one's
    /// poll is still following.
    @Test("the doctor commands are refused while a run is in flight")
    func doctorCommandsAreRefusedWhileRunning() async throws {
        let harness = try RouterHarness()
        let gate = AsyncGate()
        harness.gateway.startGate = { await gate.wait() }

        let running = Task { await harness.surfaces.doctor.runLocal() }
        while !harness.surfaces.doctor.isRunning { await Task.yield() }

        #expect(!harness.router.canPerform(.runLocalChecks))
        #expect(!harness.router.canPerform(.runNetworkChecks))

        gate.release()
        await running.value

        #expect(harness.router.canPerform(.runLocalChecks))
        #expect(harness.router.canPerform(.runNetworkChecks))
    }

    /// One lifecycle transaction at a time: the journal exists to keep two
    /// overlapping drains of the same daemon from happening.
    @Test("the lifecycle commands are refused while a transaction is in flight")
    func lifecycleCommandsAreRefusedDuringATransaction() async throws {
        let harness = try RouterHarness()

        harness.coordinator.restartDaemon()

        #expect(!harness.router.canPerform(.restartDaemon))
        #expect(!harness.router.canPerform(.toggleBackgroundService))

        try await harness.coordinator.drainPendingWork()

        #expect(harness.router.canPerform(.restartDaemon))
        #expect(harness.router.canPerform(.toggleBackgroundService))
    }

    /// The guard is the one place a refusal is enforced, so a refused command
    /// does nothing at all rather than being refused in some renderers only.
    @Test("a refused command performs nothing")
    func aRefusedCommandDoesNothing() throws {
        let harness = try RouterHarness()

        harness.router.perform(.exportLogs)

        #expect(!harness.surfaces.logs.exportRequested)
        #expect(harness.windows.presented.isEmpty)
    }

    // MARK: - The call command (M56 §4.1)

    @Test("the call command begins a call when voice is ready")
    func callCommandBeginsWhenReady() async throws {
        let harness = try RouterHarness()
        try await harness.readVoice("ready")

        #expect(harness.router.canPerform(.toggleVoiceCall))
        harness.router.perform(.toggleVoiceCall)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.voice.toggleCallCount == 1)
        #expect(!harness.presentation.isShowing)
    }

    /// No popup: the one click lands on the pane that sets voice up.
    @Test("the call command opens Settings, Voice when voice is not set up", arguments: ["setup_required", "disabled"])
    func callCommandOpensVoiceSettings(word: String) async throws {
        let harness = try RouterHarness()
        try await harness.readVoice(word)

        #expect(harness.router.canPerform(.toggleVoiceCall))
        harness.router.perform(.toggleVoiceCall)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.voice.toggleCallCount == 0)
        #expect(harness.windows.presented == [.main])
        #expect(harness.presentation.isShowing)
        #expect(harness.settings.selectedPane == .voice)
    }

    /// A row that would do nothing is dimmed, and the guard refuses it anyway.
    @Test("the call command does nothing while voice is degraded or unread", arguments: ["degraded", nil])
    func callCommandRefusedWhenUnavailable(word: String?) async throws {
        let harness = try RouterHarness()
        if let word { try await harness.readVoice(word) }

        #expect(harness.surfaces.callGate.readiness == (word == nil ? .unknown : .degraded))
        #expect(!harness.router.canPerform(.toggleVoiceCall))
        harness.router.perform(.toggleVoiceCall)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.voice.toggleCallCount == 0)
        #expect(harness.windows.presented.isEmpty)
        #expect(!harness.presentation.isShowing)
    }

    /// Ending is never gated: the row is how a call is ended with no window
    /// open, whatever the last overview said.
    @Test("the call command ends a call whatever readiness says", arguments: ["degraded", "setup_required", nil])
    func callCommandAlwaysEnds(word: String?) async throws {
        let harness = try RouterHarness()
        if let word { try await harness.readVoice(word) }
        harness.voiceCall.beginTestCall()

        #expect(harness.router.canPerform(.toggleVoiceCall))
        #expect(harness.router.isOn(.toggleVoiceCall))
        harness.router.perform(.toggleVoiceCall)

        #expect(harness.voice.toggleCallCount == 1)
        #expect(!harness.presentation.isShowing)
    }

    /// The title names where a click goes: a start the daemon has not answered
    /// is ended like a call, and a call still ending begins the next one.
    @Test("the call command's title follows the call's phase")
    func callCommandTitleFollowsThePhase() async throws {
        let harness = try RouterHarness()
        try await harness.readVoice("ready")
        let call = harness.voiceCall

        #expect(harness.router.menuTitle(of: .toggleVoiceCall) == "Begin Voice Call")

        call.callStarting()
        #expect(harness.router.menuTitle(of: .toggleVoiceCall) == "End Voice Call", "starting")

        call.callStarted()
        #expect(harness.router.menuTitle(of: .toggleVoiceCall) == "End Voice Call", "active")
        #expect(harness.router.statusItemTitle(of: .toggleVoiceCall) == "End Voice Call")

        call.callStopping()
        #expect(harness.router.menuTitle(of: .toggleVoiceCall) == "Begin Voice Call", "stopping")

        call.callEnded()
        #expect(call.voice.phase == .ended(.normal(settled: nil)))
        #expect(harness.router.menuTitle(of: .toggleVoiceCall) == "Begin Voice Call", "ended")
        #expect(harness.router.statusItemTitle(of: .toggleVoiceCall) == "Begin Voice Call")
    }

    /// The Pet page, the floating pet and the menus are four doors on one
    /// gate: the pet's click opens the same pane the menu row does.
    @Test("the pet's call control clicks through the command's gate")
    func petClicksThroughTheGate() async throws {
        let harness = try RouterHarness()
        try await harness.readVoice("setup_required")

        harness.surfaces.pet.toggleCall()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.voice.toggleCallCount == 0)
        #expect(harness.presentation.isShowing)
        #expect(harness.settings.selectedPane == .voice)
    }
}

/// The real router over the real surfaces, with the daemon, the windows, the
/// lifecycle and quitting behind their seams.
@MainActor
final class RouterHarness {
    let gateway = FakeDaemonGateway()
    let loginItems = FakeLoginItemService()
    let model = AppModel()
    let voiceCall = VoiceCallModel()
    /// The voice controller behind the call control's gate, recording what it
    /// was asked.
    let voice = FakeVoiceController()
    let windows = FakeWindowHost()
    let lifecycle = FakeLifecycleController()
    let termination = FakeTerminationRequester()
    let sidebar: SidebarModel
    let coordinator: AppCoordinator
    let surfaces: MainWindowSurfaces
    let router: CommandRouter
    let settings: SettingsModel
    /// Whether the primary window is showing settings (decision D1).
    let presentation = SettingsPresentation()
    /// The status item, without a status bar: the harness owns it so the Hide
    /// row's effect is readable.
    let statusItem = FakeStatusItem()
    let menuBar: MenuBarController
    /// The updater behind the `Check for Updates` row, scripted: the row
    /// follows what the updater would actually accept (M34 §6, R2).
    let updates = FakeUpdateChecker()
    /// "Show browser"'s own owner, over the same fakes `BrowserHostCoordinatorTests`
    /// proves the reducer's rules against.
    let browserHarness = BrowserHarness()

    static let launcherPath = "/Applications/Fermix.app/Contents/MacOS/fermix"
    /// A throwaway account root: the router never writes a record, and a store
    /// pointed at the operator's own home would be one that could.
    static let location = BootstrapLocation(
        homeDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-router-tests", isDirectory: true)
    )

    init() throws {
        settings = SettingsFixture.model(gateway: gateway)
        gateway.hello = try ManagementValueFixture.hello()
        gateway.overviewResult = try ManagementValueFixture.overview()
        gateway.diagnostics = try ManagementValueFixture.diagnostics()
        gateway.doctorScript = [try ManagementValueFixture.doctorSession()]
        gateway.logPages = [try ManagementValueFixture.logPage(messages: ["a line", "another line"])]

        coordinator = AppCoordinator(
            model: model,
            windows: WindowCoordinator(host: windows),
            voice: FakeVoiceController(),
            lifecycle: lifecycle,
            updates: FakeUpdateReconciler(),
            gate: ServiceMutationGate(),
            bootstrap: { .present },
            registrationBuild: { .thisBuild },
            termination: termination,
            hostQuitting: ImmediateHostQuitting(),
            settings: settings,
            presentation: presentation,
            announcer: RecordingAnnouncer()
        )
        sidebar = SidebarModel(store: InMemorySidebarStore())
        menuBar = MenuBarController(model: model, item: statusItem)

        let services = ServiceController(loginItems: loginItems)
        let home = HomeModel(
            gateway: gateway,
            services: services,
            coordinator: coordinator,
            updates: updates,
            settings: settings,
            reconciler: EngineReconcilerFixture.aligned(),
            menuBar: menuBar,
            call: voiceCall,
            deadlines: ManualDeadlineScheduler()
        )
        // The gate the composition builds: over the one reader, opening the
        // Voice pane through the coordinator's one door into settings.
        let gate = VoiceCallGate(
            call: voiceCall,
            voice: voice,
            readiness: home,
            setUpVoice: { [coordinator] in coordinator.open(.settings(.voice)) }
        )
        surfaces = MainWindowSurfaces(
            home: home,
            doctor: DoctorModel(
                gateway: gateway,
                logFolder: { URL(fileURLWithPath: "/tmp/fermix-home-fixture/logs", isDirectory: true) },
                settingsFile: { URL(fileURLWithPath: "/tmp/fermix-home-fixture/config.toml", isDirectory: false) },
                revealer: RecordingFolderRevealer(),
                settingsOpener: RecordingSystemSettingsOpener(),
                sleeper: NoWaitSleeper()
            ),
            logs: LogsModel(gateway: gateway),
            pet: PetFeatureModel(call: voiceCall, voice: voice, gate: gate, coordinator: coordinator),
            voiceCall: voiceCall,
            callGate: gate,
            onboarding: OnboardingModel(
                gateway: gateway,
                activation: FakeActivationDriver(),
                store: BootstrapStore(location: RouterHarness.location),
                handoff: MigrationHandoffReader(location: RouterHarness.location),
                chooser: FakeDirectoryChooser(),
                restarter: FakeDaemonRestarter(),
                planner: CLILinkPlanner(
                    launcherPath: RouterHarness.launcherPath,
                    inspector: StubLinkInspector(files: [RouterHarness.launcherPath])
                ),
                onRoute: { _ in },
                onRecoveryResolved: {},
                onRetryUpdateRecovery: {},
                settings: settings,
                sleeper: NoWaitSleeper()
            ),
            settings: settings,
            companion: CompanionSession(
                transport: CompanionSocketClient(lines: FakeCompanionSocket()),
                socketPath: { "/tmp/fermix-test/companion.sock" },
                deadlines: ManualDeadlineScheduler()
            )
        )

        router = CommandRouter(
            model: model,
            coordinator: coordinator,
            surfaces: surfaces,
            sidebar: sidebar,
            menuBar: menuBar,
            updates: updates,
            browser: browserHarness.coordinator
        )
    }

    /// Lets a detached request task finish without a wall-clock wait.
    func settle() async throws {
        for _ in 0..<16 {
            await Task.yield()
        }
    }

    /// The one overview reader, answering with voice in `word`.
    func readVoice(_ word: String) async throws {
        gateway.overviewResult = try ManagementValueFixture.overview(voice: word)
        await surfaces.home.refresh()
    }
}
