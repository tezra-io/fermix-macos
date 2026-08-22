import AppKit
import Foundation

/// Everything the GUI is, assembled once.
///
/// The graph is explicit and one-directional: configuration and bootstrap at
/// the bottom, then the model, then the coordinators that drive it, then the
/// two surfaces that draw it. Nothing here reads `FERMIX_HOME` or any other
/// environment value — the bootstrap record is the only macOS source.
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
    let coordinator: AppCoordinator
    let menuBar: MenuBarController
    let gateway: ManagementGateway
    let surfaces: MainWindowSurfaces
    let journal: LifecycleJournal

    init() {
        // A bundle that cannot answer these two questions is broken, not
        // degraded: there is no second place to read them from.
        configuration = Self.loadConfiguration()
        location = Self.loadLocation()
        store = BootstrapStore(location: location)
        journal = LifecycleJournal(location: location)

        model = AppModel()
        windowHost = AppKitWindowHost()
        windows = WindowCoordinator(host: windowHost)

        let audio = AudioOwner(engine: AudioController())
        let bootstrap = store
        let session = VoiceSession(
            transport: MainActorRealtimeDelivery(wrapping: RealtimeSocketClient()),
            // Resolved per connect from the bootstrap record, never from the
            // environment: §4 makes that record the sole macOS source.
            socketPath: { try bootstrap.realtimeSocketPath() },
            deadlines: MainQueueDeadlineScheduler()
        )
        voice = VoiceCoordinator(model: model, session: session, audio: audio)

        services = ServiceController(loginItems: SMAppServiceLoginItems(configuration: configuration))
        lifecycle = LifecycleCoordinator(
            store: store,
            journal: journal,
            services: services,
            plane: { record in
                ManagementControlPlane(client: try ManagementClient.connected(to: record))
            },
            processes: SystemProcessLiveness(),
            paths: FileSystemPathPresence(),
            web: HTTPWebLiveness(),
            sleeper: TaskSleeper()
        )

        coordinator = AppCoordinator(
            model: model,
            windows: windows,
            voice: voice,
            lifecycle: lifecycle,
            bootstrap: { bootstrap.condition() },
            termination: ApplicationTermination()
        )
        petModel = PetFeatureModel(model: model, voice: voice, coordinator: coordinator)

        // One gateway for every surface: `hello` is negotiated once, and the
        // window it reports is what refuses a call the daemon cannot serve.
        gateway = ManagementGateway {
            try ManagementClient.connected(to: BootstrapRecord(fermixHome: try bootstrap.resolvedHome()))
        }
        surfaces = Self.buildSurfaces(
            configuration: configuration,
            store: store,
            services: services,
            coordinator: coordinator,
            gateway: gateway,
            petModel: petModel
        )

        // The panel reads the uptime Home already resolved, so the two surfaces
        // cannot disagree about how much the app knows.
        let surfaces = self.surfaces
        menuBar = MenuBarController(
            model: model,
            source: MenuPanelSource(
                model: model,
                version: configuration.marketingVersion,
                uptimeSeconds: { surfaces.home.snapshot.uptimeSeconds }
            ),
            actions: { [coordinator] action in coordinator.perform(action) }
        )

        windowHost.surfaces = AppSurfaces(model: model, surfaces: surfaces, coordinator: coordinator)
        // Every report goes through the coordinator, which owns whether a window
        // is on screen; the pet reads that answer rather than the raw signal.
        windowHost.onVisibilityChanged = { [petModel, windows] kind, visible in
            let onScreen = windows.visibilityChanged(visible, for: kind)
            guard kind == .pet else { return }

            petModel.setWindowVisible(onScreen)
        }

        model.serviceEnabled = services.backgroundServiceEnabled
        PetAssetCache.shared.preload()
    }

    func installApplicationIcon() {
        guard
            let url = Bundle.module.url(forResource: "FermixPetIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: url)
        else {
            preconditionFailure("the application icon is missing from the resource bundle")
        }

        NSApp.applicationIconImage = icon
    }

    /// Builds the five surfaces plus onboarding. Everything they need is passed
    /// in, so the graph stays one-directional and nothing here reaches back into
    /// the composition.
    private static func buildSurfaces(
        configuration: ProductConfiguration,
        store: BootstrapStore,
        services: ServiceController,
        coordinator: AppCoordinator,
        gateway: ManagementGateway,
        petModel: PetFeatureModel
    ) -> MainWindowSurfaces {
        let setup = SetupModel(gateway: gateway, opener: WorkspaceExternalOpener())
        let planner = CLILinkPlanner(launcherPath: bundledLauncherPath(configuration))
        let activation = ActivationCoordinator(
            store: store,
            services: services,
            gateway: gateway,
            paths: FileSystemPathPresence(),
            installation: BundleInstallationProbe(),
            web: HTTPWebLiveness(),
            ports: TCPPortProbe(),
            sleeper: TaskSleeper()
        )

        return MainWindowSurfaces(
            home: HomeModel(
                gateway: gateway,
                services: services,
                coordinator: coordinator,
                updates: UnwiredUpdateChecker()
            ),
            setup: setup,
            doctor: DoctorModel(
                gateway: gateway,
                // The daemon owns its rotated log set; the app only shows the
                // operator where it is.
                logFolder: { try store.resolvedHome().appendingPathComponent("logs", isDirectory: true) }
            ),
            logs: LogsModel(gateway: gateway),
            pet: petModel,
            onboarding: OnboardingModel(
                gateway: gateway,
                activation: activation,
                setup: SetupModel(gateway: gateway, opener: WorkspaceExternalOpener()),
                planner: planner,
                onRoute: { [coordinator] route in coordinator.open(route) },
                onRecoveryResolved: { [coordinator] in coordinator.resolveInterruptedTransaction() }
            ),
            version: configuration.marketingVersion
        )
    }

    /// The CLI launcher inside this bundle. It is the target the Terminal
    /// command links to, and it is resolved from the running bundle rather than
    /// assumed to be in `/Applications`.
    private static func bundledLauncherPath(_ configuration: ProductConfiguration) -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("fermix")
            .path
    }

    private static func loadConfiguration() -> ProductConfiguration {
        do {
            return try ProductConfiguration.bundled()
        } catch let failure as ProductConfigurationError {
            preconditionFailure(failure.message)
        } catch {
            preconditionFailure("the product configuration is unreadable: \(error)")
        }
    }

    private static func loadLocation() -> BootstrapLocation {
        do {
            return try BootstrapLocation.currentAccount()
        } catch {
            preconditionFailure("this macOS account has no home directory the app can read")
        }
    }
}

/// `NSApp.terminate`, behind the seam.
@MainActor
final class ApplicationTermination: TerminationRequesting {
    func requestTermination() {
        NSApp.terminate(nil)
    }
}
