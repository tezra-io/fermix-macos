import AppKit
import Foundation

/// Everything the GUI is, assembled once.
///
/// The graph is explicit and one-directional: configuration and bootstrap at
/// the bottom, then the model, then the coordinators that drive it, then the
/// two surfaces that draw it. Nothing here reads `FERMIX_HOME` or any other
/// environment value — the bootstrap record is the only macOS source, and
/// everything else outside the process arrives as an `AppEnvironment`.
///
/// There are two declared configurations and one graph. `AppComposition()` is
/// the product. `AppComposition(fixture:)` — DEBUG builds only, in
/// `FixtureConfiguration.swift` — is the same graph standing on the contract's
/// own golden answers, so every surface can be seen before the engine publishes
/// protocol v2. Neither configuration branches inside the other: they differ
/// only in the environment they are handed.
@MainActor
final class AppComposition {
    let configuration: ProductConfiguration
    let location: BootstrapLocation
    let store: BootstrapStore
    let model: AppModel
    let windowHost: AppKitWindowHost
    let windows: WindowCoordinator
    let voice: VoiceCoordinator
    let petModel: PetFeatureModel
    let services: ServiceController
    let lifecycle: LifecycleCoordinator
    /// The one lock over everything that can change the background service
    /// (M34 §6, R3): the lifecycle transactions, the launch reconcile, and the
    /// update transaction.
    let gate: ServiceMutationGate
    /// The updater behind the seam, held for the life of the process because a
    /// scheduled check belongs to a live updater (M34 §6, R1).
    let updater: any UpdaterDriving
    /// The update transaction and the seam every update surface reads
    /// (M34 §6, R2 and R3).
    let updates: UpdateCoordinator
    let coordinator: AppCoordinator
    let sidebar: SidebarModel
    let router: CommandRouter
    let mainMenu: MainMenuController
    /// The status item. Built before the surfaces because Home's switch and the
    /// status menu's Hide row both write to it, and one owner is what keeps the
    /// two from disagreeing.
    let menuBar: MenuBarController
    let statusMenu: StatusMenuController
    let gateway: ManagementGateway
    let surfaces: MainWindowSurfaces
    let settings: SettingsModel
    /// Whether the primary window is showing settings (decision D1). One
    /// instance, built here, because the coordinator enters it and the window
    /// view draws it.
    let settingsPresentation: SettingsPresentation
    let journal: LifecycleJournal
    /// The update transaction's own record, beside the lifecycle one and
    /// outside the bundle an update replaces (M34 §6, R4).
    let updateJournal: UpdateJournal
    let handoff: MigrationHandoffReader
    /// Asked on every restart whether the registered agent plist is still the
    /// bundled one (M34 §7.2 step 5).
    let engineReconciler: EngineReconciler

    /// The shipped configuration: this Mac, this account, this bundle, and the
    /// updater the executable owns.
    convenience init(updater: any UpdaterDriving) {
        self.init(environment: .product(updater: updater))
    }

    init(environment: AppEnvironment) {
        configuration = environment.configuration
        location = environment.location
        store = BootstrapStore(location: location)
        journal = LifecycleJournal(location: location)
        updateJournal = UpdateJournal(location: location)
        handoff = MigrationHandoffReader(location: location)

        model = AppModel()
        windowHost = AppKitWindowHost()
        windows = WindowCoordinator(host: windowHost)
        voice = Self.buildVoice(model: model, bootstrap: store)
        services = ServiceController(loginItems: environment.loginItems, plists: environment.plists)
        engineReconciler = environment.reconciler
        menuBar = MenuBarController(model: model)
        gate = ServiceMutationGate()
        updater = environment.updater

        let management = Self.buildManagement(environment: environment, services: services)
        gateway = management.gateway
        settings = management.settings
        // Entering settings grows the window (decision D3), which the window
        // coordinator owns; the presentation only says when.
        settingsPresentation = SettingsPresentation(grow: { [windows] in windows.growForSettings() })

        let plane = Self.buildControlPlane(
            environment: environment,
            store: store,
            journal: journal,
            updateJournal: updateJournal,
            services: services,
            reconciler: engineReconciler,
            gateway: gateway,
            gate: gate,
            model: model,
            windows: windows,
            voice: voice,
            settings: settings,
            presentation: settingsPresentation
        )
        lifecycle = plane.lifecycle
        coordinator = plane.coordinator
        updates = Self.buildUpdateCoordinator(
            environment: environment,
            store: store,
            journal: updateJournal,
            lifecycle: plane.lifecycle,
            services: services,
            reconciler: engineReconciler,
            gateway: gateway,
            gate: gate
        )
        petModel = Self.buildPet(model: model, voice: voice, coordinator: coordinator)

        let interface = Self.buildInterface(
            environment: environment,
            model: model,
            store: store,
            handoff: handoff,
            reconciler: engineReconciler,
            services: services,
            coordinator: coordinator,
            gateway: gateway,
            petModel: petModel,
            settings: settings,
            menuBar: menuBar,
            updates: updates
        )
        surfaces = interface.surfaces
        sidebar = interface.sidebar
        router = interface.router
        mainMenu = interface.mainMenu
        statusMenu = interface.statusMenu

        finishAssembly()
    }

    /// The edges that only exist once both ends do — the coordinator's two
    /// callbacks into surfaces it created, and the window host's view of the
    /// whole graph — plus the two first reads. Everything else points one way.
    private func finishAssembly() {
        // The updater starts once, with the transaction bound as its delegate.
        // A bundle whose declared policy is wrong runs none at all, and the
        // update surface states that rather than the framework's own alert
        // (M34 §6, R2).
        updates.start(updater)
        // A staged update replaces the bundle on any exit of this process, so
        // the quit path finishes the stop first (M34 §6, R3). The closure is a
        // backwards edge for the same reason the two below are: the update
        // transaction is built over the coordinator's own lifecycle owner.
        coordinator.prepareForQuit = { [updates] in await updates.prepareForQuit() }
        // A `fermix://setup` url names an assistant screen, and the assistant's
        // model is built with this coordinator's own router.
        coordinator.resumeAssistant = { [surfaces] stage in surfaces.onboarding.resume(at: stage) }
        coordinator.showUninstallNotice = { [surfaces] shown in surfaces.doctor.uninstallNoticeShown = shown }
        // A login launch opens nothing, so Home's own refresh never runs and
        // the menu bar would have no answer to draw.
        coordinator.readDaemonCondition = { [surfaces] in Task { await surfaces.home.refresh() } }

        windowHost.surfaces = AppSurfaces(
            model: model,
            surfaces: surfaces,
            sidebar: sidebar,
            router: router,
            settingsPresentation: settingsPresentation,
            leaveSettings: { [coordinator] in coordinator.leaveSettings() },
            openRecovery: { [coordinator] in coordinator.enterRecovery() },
            restart: { [coordinator] in coordinator.restartDaemon() }
        )
        // Every report goes through the coordinator, which owns whether a window
        // is on screen; the pet reads that answer rather than the raw signal.
        windowHost.onVisibilityChanged = { [petModel, windows] kind, visible in
            let onScreen = windows.visibilityChanged(visible, for: kind)
            guard kind == .pet else { return }

            petModel.setWindowVisible(onScreen)
        }

        // Home's Background switch reads through to the status item, so a
        // Command-drag off the bar while that window is open is a change only
        // the item can report.
        menuBar.onMenuBarItemShownChanged = { [surfaces] in surfaces.home.menuBarItemVisibilityChanged() }

        PetAssetCache.shared.preload()
    }

    /// The interim mark: the FermixPet mascot in one ink, which is the icon
    /// everywhere until the owner has a Fermix logo.
    func installApplicationIcon() {
        guard
            let url = AppResources.bundle.url(forResource: "FermixMonochromeIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: url)
        else {
            preconditionFailure("the application icon is missing from the resource bundle")
        }

        NSApp.applicationIconImage = icon
    }

    /// Puts the status item on the menu bar under the menu the command table
    /// built. The menu is passed in rather than held by the controller, because
    /// the controller is built before the router the menu's rows come from.
    func installMenuBar() {
        menuBar.install(menu: statusMenu.menu())
    }

    /// The voice stack: one audio owner, one realtime session, one coordinator.
    private static func buildVoice(model: AppModel, bootstrap: BootstrapStore) -> VoiceCoordinator {
        let session = VoiceSession(
            transport: MainActorRealtimeDelivery(wrapping: RealtimeSocketClient()),
            // Resolved per connect from the bootstrap record, never from the
            // environment: §4 makes that record the sole macOS source.
            socketPath: { try bootstrap.realtimeSocketPath() },
            deadlines: MainQueueDeadlineScheduler()
        )

        return VoiceCoordinator(
            model: model,
            session: session,
            audio: AudioOwner(engine: AudioController())
        )
    }

    /// The one gateway and the one settings model, built as a pair because the
    /// second is nothing but a reader of the first.
    private static func buildManagement(
        environment: AppEnvironment,
        services: ServiceController
    ) -> (gateway: ManagementGateway, settings: SettingsModel) {
        // One gateway for every surface: `hello` is negotiated once, and the
        // window it reports is what refuses a call the daemon cannot serve.
        let gateway = ManagementGateway(makeClient: environment.makeClient)
        // Exactly one `SettingsModel`, built before the coordinator because the
        // coordinator selects a pane when a `fermix://settings/<pane>` url
        // arrives. One instance is the invariant M34 §8 names: the Settings
        // window, Home and onboarding read this one.
        let settings = SettingsModel(
            gateway: gateway,
            store: environment.settingsPanes,
            sleeper: environment.sleeper,
            opener: environment.opener,
            permissions: PermissionLedger(
                gateway: gateway,
                services: services,
                microphone: environment.microphone
            )
        )

        return (gateway, settings)
    }

    /// The lifecycle transaction owner and the one coordinator that drives it.
    /// Built as a pair because the coordinator is nothing without the plane it
    /// runs its transactions on.
    private static func buildControlPlane(
        environment: AppEnvironment,
        store: BootstrapStore,
        journal: LifecycleJournal,
        updateJournal: UpdateJournal,
        services: ServiceController,
        reconciler: EngineReconciler,
        gateway: ManagementGateway,
        gate: ServiceMutationGate,
        model: AppModel,
        windows: WindowCoordinator,
        voice: VoiceCoordinator,
        settings: SettingsModel,
        presentation: SettingsPresentation
    ) -> (lifecycle: LifecycleCoordinator, coordinator: AppCoordinator) {
        let lifecycle = buildLifecycle(
            environment: environment,
            store: store,
            journal: journal,
            services: services,
            reconciler: reconciler
        )

        return (
            lifecycle,
            buildCoordinator(
                environment: environment,
                model: model,
                windows: windows,
                voice: voice,
                lifecycle: lifecycle,
                updates: buildUpdateReconciler(
                    environment: environment,
                    journal: updateJournal,
                    lifecycle: lifecycle,
                    services: services,
                    reconciler: reconciler,
                    gateway: gateway
                ),
                gate: gate,
                store: store,
                settings: settings,
                presentation: presentation
            )
        )
    }

    /// The update transaction (M34 §6, R2 and R3).
    ///
    /// It stops the engine through the same `LifecycleCoordinator` every other
    /// transaction uses, and it takes the same gate, so an update and a restart
    /// can never mutate the account at once.
    private static func buildUpdateCoordinator(
        environment: AppEnvironment,
        store: BootstrapStore,
        journal: UpdateJournal,
        lifecycle: LifecycleCoordinator,
        services: ServiceController,
        reconciler: EngineReconciler,
        gateway: ManagementGateway,
        gate: ServiceMutationGate
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            journal: journal,
            lifecycle: lifecycle,
            services: services,
            engines: reconciler,
            probe: ManagementUpdateEngineProbe(gateway: gateway),
            ownership: ServiceDaemonOwnership(
                services: services,
                paths: environment.paths,
                socketPath: { BootstrapRecord(fermixHome: try store.resolvedHome()).daemonSocketURL.path }
            ),
            gate: gate,
            installedApp: environment.appBuild,
            sleeper: environment.sleeper
        )
    }

    /// The one launch reconcile (M34 §6, R4).
    ///
    /// It puts registrations back through the lifecycle coordinator rather than
    /// through a second registration owner, and it asks the same
    /// `EngineReconciler` every other surface asks which engine is answering.
    private static func buildUpdateReconciler(
        environment: AppEnvironment,
        journal: UpdateJournal,
        lifecycle: LifecycleCoordinator,
        services: ServiceController,
        reconciler: EngineReconciler,
        gateway: ManagementGateway
    ) -> UpdateReconciler {
        UpdateReconciler(
            journal: journal,
            lifecycle: lifecycle,
            services: services,
            engines: reconciler,
            probe: ManagementUpdateEngineProbe(gateway: gateway),
            installedApp: environment.appBuild,
            sleeper: environment.sleeper
        )
    }

    /// The companion's own model, which reads the voice stack and the
    /// coordinator and owns nothing else.
    private static func buildPet(
        model: AppModel,
        voice: VoiceCoordinator,
        coordinator: AppCoordinator
    ) -> PetFeatureModel {
        PetFeatureModel(
            model: model,
            voice: voice,
            coordinator: coordinator,
            openFermix: { coordinator.open(.home) }
        )
    }

    /// The lifecycle control plane: the transaction owner and the probes it
    /// proves each transaction against.
    private static func buildLifecycle(
        environment: AppEnvironment,
        store: BootstrapStore,
        journal: LifecycleJournal,
        services: ServiceController,
        reconciler: EngineReconciler
    ) -> LifecycleCoordinator {
        LifecycleCoordinator(
            store: store,
            journal: journal,
            services: services,
            reconciler: reconciler,
            plane: environment.makePlane,
            processes: environment.processes,
            paths: environment.paths,
            web: environment.web,
            sleeper: environment.sleeper
        )
    }

    /// The one coordinator that owns which window is on screen. It reads the
    /// bootstrap condition through the store rather than holding a record, so a
    /// home written after launch is seen.
    private static func buildCoordinator(
        environment: AppEnvironment,
        model: AppModel,
        windows: WindowCoordinator,
        voice: VoiceCoordinator,
        lifecycle: LifecycleCoordinator,
        updates: any UpdateReconciling,
        gate: ServiceMutationGate,
        store: BootstrapStore,
        settings: SettingsModel,
        presentation: SettingsPresentation
    ) -> AppCoordinator {
        AppCoordinator(
            model: model,
            windows: windows,
            voice: voice,
            lifecycle: lifecycle,
            updates: updates,
            gate: gate,
            bootstrap: { store.condition() },
            termination: environment.termination,
            settings: settings,
            presentation: presentation
        )
    }

    /// The sidebar's own remembered visibility. The window has one floor now
    /// (decision D3), so a collapse moves nothing outside this model.
    private static func buildSidebar(environment: AppEnvironment) -> SidebarModel {
        SidebarModel(store: environment.sidebarVisibility)
    }

    /// One router behind the main menu, the status item and every toolbar, so
    /// the three cannot answer differently.
    private static func buildCommands(
        model: AppModel,
        coordinator: AppCoordinator,
        surfaces: MainWindowSurfaces,
        sidebar: SidebarModel,
        menuBar: MenuBarController,
        updates: any UpdateChecking,
        commandLine: @escaping () -> CoexistenceInstructions?
    ) -> (router: CommandRouter, mainMenu: MainMenuController, statusMenu: StatusMenuController) {
        let router = CommandRouter(
            model: model,
            coordinator: coordinator,
            surfaces: surfaces,
            sidebar: sidebar,
            menuBar: menuBar,
            updates: updates,
            commandLine: commandLine
        )
        // The status line reads the facts Home already resolved, so the two
        // surfaces cannot disagree about how much the app knows.
        let statusMenu = StatusMenuController(
            router: router,
            source: StatusMenuSource(
                model: model,
                snapshot: { surfaces.home.snapshot },
                reconcile: { surfaces.home.engineReconcile }
            ),
            // With the window closed nothing else ever reads the daemon, so the
            // menu asks as it opens (M34 §7.2).
            refresh: { Task { await surfaces.home.refresh() } }
        )

        return (router, MainMenuController(router: router), statusMenu)
    }

    /// What the person sees and what they can ask for: the surfaces, the
    /// sidebar's own state, and the three tables built over them.
    ///
    /// One value rather than five out-parameters, and one builder because the
    /// command tables read the surfaces they command: the router, the main menu
    /// and the status item are one router seen three ways.
    private struct UserInterface {
        let surfaces: MainWindowSurfaces
        let sidebar: SidebarModel
        let router: CommandRouter
        let mainMenu: MainMenuController
        let statusMenu: StatusMenuController
    }

    private static func buildInterface(
        environment: AppEnvironment,
        model: AppModel,
        store: BootstrapStore,
        handoff: MigrationHandoffReader,
        reconciler: EngineReconciler,
        services: ServiceController,
        coordinator: AppCoordinator,
        gateway: ManagementGateway,
        petModel: PetFeatureModel,
        settings: SettingsModel,
        menuBar: MenuBarController,
        updates: any UpdateChecking
    ) -> UserInterface {
        // The Terminal link's plan, read once: the surfaces draw its row and the
        // Help menu names the same command.
        let planner = CLILinkPlanner(launcherPath: environment.launcherPath)
        let surfaces = buildSurfaces(
            environment: environment,
            planner: planner,
            store: store,
            handoff: handoff,
            reconciler: reconciler,
            services: services,
            coordinator: coordinator,
            gateway: gateway,
            petModel: petModel,
            settings: settings,
            menuBar: menuBar,
            updates: updates
        )
        let sidebar = buildSidebar(environment: environment)
        let commands = buildCommands(
            model: model,
            coordinator: coordinator,
            surfaces: surfaces,
            sidebar: sidebar,
            menuBar: menuBar,
            updates: updates,
            commandLine: { CoexistenceInstructions.commandLine(planner.plan()) }
        )

        return UserInterface(
            surfaces: surfaces,
            sidebar: sidebar,
            router: commands.router,
            mainMenu: commands.mainMenu,
            statusMenu: commands.statusMenu
        )
    }

    /// Builds the four surfaces plus onboarding. Everything they need is passed
    /// in, so the graph stays one-directional and nothing here reaches back into
    /// the composition.
    private static func buildSurfaces(
        environment: AppEnvironment,
        planner: CLILinkPlanner,
        store: BootstrapStore,
        handoff: MigrationHandoffReader,
        reconciler: EngineReconciler,
        services: ServiceController,
        coordinator: AppCoordinator,
        gateway: ManagementGateway,
        petModel: PetFeatureModel,
        settings: SettingsModel,
        menuBar: any MenuBarItemPresenting,
        updates: any UpdateChecking
    ) -> MainWindowSurfaces {
        let instructions = coexistenceInstructions(settings: settings, planner: planner)
        let doctor = buildDoctor(
            store: store,
            gateway: gateway,
            coordinator: coordinator,
            settings: settings,
            instructions: instructions
        )

        return MainWindowSurfaces(
            home: HomeModel(
                gateway: gateway,
                services: services,
                coordinator: coordinator,
                updates: updates,
                settings: settings,
                reconciler: reconciler,
                menuBar: menuBar,
                instructions: instructions,
                // The reveal seam lives on Doctor, and this is that one rather
                // than a second implementation of the same gesture.
                revealSettingsFile: { doctor.revealSettingsFile() }
            ),
            doctor: doctor,
            logs: LogsModel(gateway: gateway),
            pet: petModel,
            onboarding: buildOnboarding(
                environment: environment,
                planner: planner,
                store: store,
                handoff: handoff,
                services: services,
                coordinator: coordinator,
                gateway: gateway,
                settings: settings,
                doctor: doctor
            ),
            settings: settings
        )
    }

    /// The removal commands both doors show, read from the daemon's own
    /// `coexistence.legacy_service_unit` (M34 §15.2).
    ///
    /// The scope and the path are the daemon's, not this app's: it is the
    /// process that owns the home, and a unit it reports under a `HOME` the app
    /// cannot see is exactly the case the filesystem probe answered with
    /// "Fermix cannot find that service". The probe stays where it belongs — the
    /// activation preflight, which runs before a daemon exists to ask.
    private static func coexistenceInstructions(
        settings: SettingsModel,
        planner: CLILinkPlanner
    ) -> () -> CoexistenceInstructions? {
        { [settings] in
            CoexistenceInstructions.legacyServiceUnit(
                unit: settings.setupState.value?.coexistence.legacyServiceUnit,
                cli: planner.plan()
            )
        }
    }

    /// Doctor: the checks, the two places on disk it can show, and the two
    /// remediations that leave the surface.
    private static func buildDoctor(
        store: BootstrapStore,
        gateway: ManagementGateway,
        coordinator: AppCoordinator,
        settings: SettingsModel,
        instructions: @escaping () -> CoexistenceInstructions?
    ) -> DoctorModel {
        DoctorModel(
            gateway: gateway,
            // The daemon owns its rotated log set; the app only shows the
            // operator where it is.
            logFolder: { try store.resolvedHome().appendingPathComponent("logs", isDirectory: true) },
            settingsFile: { try store.resolvedHome().appendingPathComponent("config.toml", isDirectory: false) },
            // A remediation that names a pane opens the settings presentation of
            // this window (decision D1).
            openSettingsPane: { coordinator.open(.settings($0)) },
            instructions: instructions,
            showInstructions: { coordinator.showInstructions($0) },
            // The three remediations that leave Doctor for a surface something
            // else owns: the one Restart sheet, the one settings reload, and
            // Recovery.
            askForRestart: { coordinator.askForRestart() },
            reloadSettings: { await settings.reloadFromDisk() },
            openRecovery: { coordinator.enterRecovery() }
        )
    }

    /// The Setup Assistant: the activation transaction it drives, the two files
    /// Recovery states, and the one settings model every surface shares.
    private static func buildOnboarding(
        environment: AppEnvironment,
        planner: CLILinkPlanner,
        store: BootstrapStore,
        handoff: MigrationHandoffReader,
        services: ServiceController,
        coordinator: AppCoordinator,
        gateway: ManagementGateway,
        settings: SettingsModel,
        doctor: DoctorModel
    ) -> OnboardingModel {
        OnboardingModel(
            gateway: gateway,
            activation: ActivationCoordinator(
                store: store,
                handoff: handoff,
                services: services,
                gateway: gateway,
                paths: environment.paths,
                installation: environment.installation,
                identities: environment.identities,
                web: environment.web,
                ports: environment.ports,
                sleeper: environment.sleeper,
                plan: environment.activationPlan
            ),
            store: store,
            handoff: handoff,
            chooser: environment.chooser,
            restarter: coordinator,
            planner: planner,
            settingsFiles: { recoveryEvidence(store: store, paths: environment.paths) },
            // Recovery states what the launch reconcile found, and offers the
            // exact installer the previous version came from (M34 §6, R4).
            updateRecovery: { coordinator.updateRecovery },
            openInstaller: { _ = environment.opener.open($0) },
            revealSettingsFile: { doctor.revealSettingsFile() },
            onRoute: { coordinator.open($0) },
            onRecoveryResolved: { coordinator.resolveInterruptedTransaction() },
            // Try again on an unfinished update re-runs the launch reconcile:
            // activation would register the agent over a record only the
            // reconcile can resolve (M34 §6, R4).
            onRetryUpdateRecovery: { coordinator.retryUpdateRecovery() },
            settings: settings,
            sleeper: environment.sleeper
        )
    }

    /// Where the settings file is, and whether the daemon kept the copy from
    /// before. Recovery states both (M34 §7.5).
    private static func recoveryEvidence(store: BootstrapStore, paths: any PathPresence) -> RecoveryEvidence {
        let settings = try? store.resolvedHome()
            .appendingPathComponent("config.toml", isDirectory: false)
        let previous = settings.map { $0.path + RecoveryEvidence.previousSuffix }

        return RecoveryEvidence(
            sentence: nil,
            settingsFile: settings?.path,
            previousFile: previous.flatMap { paths.exists(atPath: $0) ? $0 : nil }
        )
    }
}

/// `NSApp.terminate`, behind the seam.
@MainActor
final class ApplicationTermination: TerminationRequesting {
    func requestTermination() {
        NSApp.terminate(nil)
    }

    /// Answers the `.terminateLater` the delegate returned. AppKit is holding
    /// the exit on this reply, so it is sent whether the work it waited for
    /// finished or spent its whole bound.
    func completeTermination() {
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
