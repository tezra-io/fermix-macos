import Foundation

/// Everything the composition takes from outside the process.
///
/// The graph in `AppComposition` is one shape with one wiring; this is the
/// boundary that shape stands on — the account's directories, the management
/// socket, `SMAppService`, the microphone, user defaults, the browser, the
/// liveness probes, and the clock the waits sleep on. Naming the boundary once
/// is what lets a second configuration exist without a second graph, and what
/// keeps a surface from reaching past the graph to read the machine directly.
///
/// Every field is consumed by the graph in `AppComposition` and nowhere else:
/// nothing reaches past the environment to read the machine directly. That is
/// the invariant, and it is gated by a source scan rather than trusted here.
@MainActor
struct AppEnvironment {
    let configuration: ProductConfiguration
    let location: BootstrapLocation
    /// A fresh management client. It is a factory rather than a client because
    /// the gateway makes one lazily and the lifecycle coordinator makes its own
    /// per transaction.
    let makeClient: @Sendable () throws -> ManagementClient
    /// The control plane for one home's daemon, which a lifecycle transaction
    /// makes fresh: the transaction restarts the process it is talking to, and
    /// a client held across that would be addressing the daemon it replaced.
    let makePlane: (BootstrapRecord) throws -> any DaemonControlPlane
    let loginItems: any LoginItemService
    let plists: any AgentPlistDigesting
    let microphone: any MicrophoneAuthorizationReading
    let settingsPanes: any SettingsPaneStoring
    let sidebarVisibility: any SidebarVisibilityStoring
    let opener: any ExternalOpening
    let updates: any UpdateChecking
    let chooser: any DirectoryChoosing
    let processes: any ProcessLiveness
    let paths: any PathPresence
    let web: any WebLiveness
    let ports: any PortProbing
    let installation: any InstallationProbing
    let identities: any DaemonIdentityProbing
    /// Which steps activation runs on this configuration's machine.
    let activationPlan: ActivationPlan
    let sleeper: any Sleeping
    /// The launch reconcile's two operands, resolved outside the graph because
    /// one of them is a file inside the running bundle.
    let reconciler: EngineReconciler
    let termination: any TerminationRequesting
    /// The CLI launcher the Terminal command links to, resolved from the
    /// running bundle rather than assumed to be in `/Applications`.
    let launcherPath: String
}

extension AppEnvironment {
    /// The shipped configuration: this Mac, this account, this bundle, and the
    /// activation that registers the background service launchd runs.
    static func product() -> AppEnvironment {
        onThisMac(activation: .installed)
    }

    /// The boundary this Mac provides, under one declared activation plan.
    ///
    /// Internal rather than private because the development configuration in
    /// `DevelopmentEngineConfiguration.swift` is the second caller: the two
    /// differ in exactly this one value and in nothing else.
    static func onThisMac(activation plan: ActivationPlan) -> AppEnvironment {
        // A bundle that cannot answer these two questions is broken, not
        // degraded: there is no second place to read them from.
        let configuration = loadConfiguration()
        let location = loadLocation()
        let loginItems = SMAppServiceLoginItems(configuration: configuration)
        let plists = BundledAgentPlistDigest(configuration: configuration)
        // A stateless reader over `location`, not a second owner of anything:
        // the client factory has to resolve the recorded home on every call,
        // and the composition builds its own from the same location.
        let store = BootstrapStore(location: location)

        return AppEnvironment(
            configuration: configuration,
            location: location,
            makeClient: {
                try ManagementClient.connected(to: BootstrapRecord(fermixHome: try store.resolvedHome()))
            },
            makePlane: { record in
                ManagementControlPlane(client: try ManagementClient.connected(to: record))
            },
            loginItems: loginItems,
            plists: plists,
            microphone: SystemMicrophoneAuthorization(),
            settingsPanes: UserDefaultsSettingsPaneStore(),
            sidebarVisibility: UserDefaultsSidebarStore(),
            opener: WorkspaceExternalOpener(),
            updates: UnwiredUpdateChecker(),
            chooser: OpenPanelDirectoryChooser(),
            processes: SystemProcessLiveness(),
            paths: FileSystemPathPresence(),
            web: HTTPWebLiveness(),
            ports: TCPPortProbe(),
            installation: BundleInstallationProbe(home: location.homeDirectory.path),
            identities: ManagementDaemonIdentityProbe(),
            activationPlan: plan,
            sleeper: TaskSleeper(),
            reconciler: EngineReconciler(
                manifestURL: bundledEngineManifestURL(configuration),
                plists: plists
            ),
            termination: ApplicationTermination(),
            launcherPath: bundledLauncherPath()
        )
    }

    /// The engine manifest inside this bundle, which is one half of the launch
    /// reconcile (M34 §7.2).
    private static func bundledEngineManifestURL(_ configuration: ProductConfiguration) -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent(configuration.engineRelativePath, isDirectory: true)
            .appendingPathComponent(EngineManifest.fileName, isDirectory: false)
    }

    /// The CLI launcher inside this bundle. It is the target the Terminal
    /// command links to, and it is resolved from the running bundle rather than
    /// assumed to be in `/Applications`.
    private static func bundledLauncherPath() -> String {
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
