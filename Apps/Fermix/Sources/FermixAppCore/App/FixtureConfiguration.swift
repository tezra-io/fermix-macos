#if DEBUG
import Foundation

/// The app's second declared configuration: the whole graph, over the wire
/// contract's own golden answers, on a throwaway Fermix home.
///
/// It exists because the engine publishes protocol 1 and every v2 surface —
/// Settings, the plugin catalogue, the permission ledger, the assistant's
/// readiness — can only be *seen* against a daemon that answers v2. Waiting for
/// the engine to ship before looking at those screens is how a pane nobody has
/// ever rendered reaches a release.
///
/// It is not a fallback and never runs by accident: it is compiled into DEBUG
/// builds only, reached only by an explicit launch argument (never an
/// environment value), and it replaces the machine wholesale rather than
/// degrading the product configuration. Nothing here touches the operator's
/// Fermix home, `SMAppService`, the microphone, user defaults, or a socket.

// MARK: - Where a fixture launch lands

/// The surface a fixture launch opens on.
///
/// Spelled the way the launch argument spells it, so `--fixture-start
/// settings/voice` and this vocabulary cannot drift.
///
/// It names surfaces and never the sheets inside them, and that is a decision
/// rather than an omission. Providers' `Add an API key`, for instance, is
/// presented from the pane's own `@State`, parameterised by a row the view
/// projects from live data; moving that selection onto `SettingsModel` would be
/// a production state change made to serve a debug need, and the model would
/// then own a view's presentation. A capture of such a sheet is taken by
/// clicking the control that raises it.
enum FixtureStart: Equatable {
    case surface(AppRoute)
    case settings(SettingsPane)
    case assistant(OnboardingStage)
    /// Home, with the restart sheet already asking. The sheet is presented from
    /// Home's own published flag, which is the same flag the Attention row sets.
    case restartSheet

    static let settingsPrefix = "settings/"
    static let assistantPrefix = "assistant/"
    static let restartSheetName = "restart-sheet"

    /// The start a launch argument named, or nil where this build publishes no
    /// such surface. A mistyped name is refused by the caller rather than
    /// opening Home, which would look like the argument worked.
    init?(name: String) {
        if name == Self.restartSheetName {
            self = .restartSheet
        } else if let slug = name.dropping(prefix: Self.settingsPrefix) {
            guard let pane = SettingsPane(rawValue: slug) else { return nil }
            self = .settings(pane)
        } else if let stage = name.dropping(prefix: Self.assistantPrefix) {
            guard let screen = OnboardingStage(rawValue: stage) else { return nil }
            self = .assistant(screen)
        } else {
            guard let route = AppRoute(rawValue: name) else { return nil }
            self = .surface(route)
        }
    }

    /// Every name this build accepts, for the refusal to list.
    static var publishedNames: [String] {
        AppRoute.allCases.map(\.rawValue)
            + SettingsPane.allCases.map { settingsPrefix + $0.slug }
            + OnboardingStage.allCases.map { assistantPrefix + $0.rawValue }
            + [restartSheetName]
    }
}

/// What the Mac under the app looks like.
///
/// Three, because two of the assistant's screens exist only to show a machine
/// that is mid-flight or refused, and a screen shown on the wrong machine is a
/// mock rather than a rendering. Each is a real state the shipped probes report;
/// none is a flag a view reads.
enum FixtureHome: Equatable {
    /// The daemon is up, both login items are settled, and the app is where it
    /// belongs. Every surface but the two below is looked at on this one.
    case settled
    /// The daemon's socket has not appeared yet, so activation waits at the row
    /// that says so and the Starting ladder holds.
    case daemonStarting
    /// The bundle is not in `/Applications`, which is activation's first
    /// refusal and the cause the Boot failed card names.
    case notInApplications
    /// The daemon is up and every readiness gate has passed, which is the only
    /// machine Ready renders on: the screen claims the install is live, so it
    /// refuses to draw while a gating failure stands (M34 §4). The default home
    /// carries the gating provider failure that Home's Attention section and
    /// the Connect your AI screen are looked at through, so on that machine
    /// Ready draws its refusal notice and the screen itself was unreachable.
    case configured
    /// Nothing has been set up: no configured provider, no personalization, no
    /// channel. It is the machine the assistant's decision screens are actually
    /// used on, and no fixture home was ever in it — which is how the two
    /// first-run defects on Connect your AI shipped without anyone seeing them
    /// (M34 §4).
    case fresh

    /// The machine each start is looked at on.
    static func forStart(_ start: FixtureStart) -> FixtureHome {
        switch start {
        case .assistant(.starting): return .daemonStarting
        case .assistant(.bootFailed): return .notInApplications
        case .assistant(.ready): return .configured
        // The three screens a first run walks through, on a first run's machine.
        case .assistant(.welcome), .assistant(.connectAI), .assistant(.aboutYou), .assistant(.applying):
            return .fresh
        default: return .settled
        }
    }

    /// The readiness this machine reports.
    ///
    /// `setup.state.get` and `overview.get` are both shaped by it, so the two
    /// answer one readiness. Paired the other way, Home drew `Running` with
    /// four Attention rows and `Continue setup` at once, which is a state no
    /// real daemon can produce.
    var readiness: FixtureReadiness {
        switch self {
        case .configured: return .ready
        case .fresh: return .fresh
        case .settled, .daemonStarting, .notInApplications: return .gatingFailure
        }
    }
}

/// What a fixture launch asks the coordinator for, once the start has been
/// resolved against the machine it runs on.
///
/// A value rather than a switch inside the presenting method, so what each
/// published start opens can be asserted without building the whole graph.
enum FixturePresentation: Equatable {
    case assistant(OnboardingStage)
    case route(AppRoute)
    case settings(SettingsPane)
    /// Home, with the restart sheet already asking.
    case homeWithRestartSheet
}

/// One fixture launch: where it lands, and the machine it lands on.
struct FixtureLaunch {
    let start: FixtureStart
    let home: FixtureHome

    init(start: FixtureStart) {
        self.start = start
        self.home = FixtureHome.forStart(start)
    }

    /// What this launch opens.
    ///
    /// Boot failed is reached by failing, never by being set: the card names a
    /// cause, and a cause the activation did not actually produce would be a
    /// caption rather than a state. So it opens on Starting, and the machine
    /// decides which of the two is drawn.
    var presentation: FixturePresentation {
        switch start {
        case .assistant(.bootFailed): return .assistant(.starting)
        case .assistant(let stage): return .assistant(stage)
        case .surface(let route): return .route(route)
        case .settings(let pane): return .settings(pane)
        case .restartSheet: return .homeWithRestartSheet
        }
    }

    /// A filesystem-safe name for this start, which is what keeps two starts
    /// from sharing one throwaway home.
    var startSlug: String {
        switch start {
        case .surface(let route): return route.rawValue
        case .settings(let pane): return "settings-\(pane.slug)"
        case .assistant(let stage): return "assistant-\(stage.rawValue)"
        case .restartSheet: return FixtureStart.restartSheetName
        }
    }
}

private extension String {
    /// The remainder after `prefix`, or nil where the string does not carry it.
    func dropping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

// MARK: - The machine, replaced

/// A throwaway Fermix home under the per-user temporary directory.
///
/// Deterministic per start, so repeated runs reuse one directory instead of
/// accumulating them, and never inside the operator's account: the bootstrap
/// record the app reads is this one, written through the shipped writer.
enum FixtureRoot {
    /// The throwaway home for one start: created, recorded, and handed back as
    /// the location the whole graph reads its bootstrap from.
    static func prepared(for name: String) throws -> BootstrapLocation {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-fixture-\(name)", isDirectory: true)
        let location = BootstrapLocation(
            homeDirectory: root,
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true)
        )

        try FileManager.default.createDirectory(
            at: location.defaultFermixHome,
            withIntermediateDirectories: true
        )
        // The shipped writer, with the shipped validation. A hand-written record
        // would be the one bootstrap in the app that nobody checked.
        try BootstrapStore(location: location).save(fermixHome: location.defaultFermixHome)

        return location
    }
}

/// The facts a lifecycle transaction changes, in one place: which pid is behind
/// the socket, whether anything is, and which login items are registered.
///
/// It exists because a fixed answer cannot survive a restart. `restartDaemon`
/// proves its work by watching the old pid stop reporting and a *different* one
/// come back, so probes that answer "running" forever and a `hello` that answers
/// one pid forever make `Restart now` — the Restart sheet's primary action —
/// spend its whole 15-second budget and then refuse. A capture session would
/// read that as a product defect.
///
/// This is launchd's own rule and nothing more: a committed drain ends the
/// process, and a new one comes back only while the agent is registered.
final class FixtureMachine: @unchecked Sendable {
    /// The pid the contract's golden `hello` publishes, so the first answer this
    /// home gives is the contract's own. Each relaunch counts up from it.
    static let firstPid: Int32 = 47_119

    private let lock = NSLock()
    /// False on the machine whose socket never appears: launchd never brings the
    /// daemon up there, so registering the agent does not end the Starting wait.
    private let launchdStartsTheDaemon: Bool
    private var registered: Set<LoginItemPrincipal> = [.agent]
    private var running: Bool
    private var pid = FixtureMachine.firstPid

    init(daemonUp: Bool) {
        launchdStartsTheDaemon = daemonUp
        running = daemonUp
    }

    var currentPid: Int32 { withLock { pid } }
    var daemonRunning: Bool { withLock { running } }

    func isRegistered(_ principal: LoginItemPrincipal) -> Bool {
        withLock { registered.contains(principal) }
    }

    /// True only of the process that is up right now: a pid from before a
    /// restart names a process that exited.
    func isRunning(pid probed: Int32) -> Bool {
        withLock { running && probed == pid }
    }

    /// Registering an already-registered principal changes nothing, exactly as
    /// `SMAppService` does not restart a job that is already loaded.
    func registrationChanged(_ principal: LoginItemPrincipal, to on: Bool) {
        withLock {
            guard on != registered.contains(principal) else { return }

            apply(principal, on)
        }
    }

    /// A committed drain: the process ends, and launchd brings a new one back
    /// only while the agent registration is there.
    func shutdownCommitted() {
        withLock {
            running = false
            guard registered.contains(.agent) else { return }

            start()
        }
    }

    /// Under the lock. The GUI's login item is a separate consent and moves
    /// nothing about the daemon.
    private func apply(_ principal: LoginItemPrincipal, _ on: Bool) {
        if on {
            registered.insert(principal)
        } else {
            registered.remove(principal)
        }
        guard principal == .agent else { return }

        if on { start() } else { running = false }
    }

    /// launchd loading the job, which is what changes the pid.
    private func start() {
        guard launchdStartsTheDaemon else { return }

        pid += 1
        running = true
    }

    private func withLock<Answer>(_ body: () -> Answer) -> Answer {
        lock.lock()
        defer { lock.unlock() }

        return body()
    }
}

/// Both login items, over the machine that owns them. The pair starts mixed —
/// the daemon registered, the GUI not opened at login — because the two
/// registrations are independent and Home draws them separately.
struct FixtureLoginItems: LoginItemService {
    let machine: FixtureMachine

    func register(_ principal: LoginItemPrincipal) throws {
        machine.registrationChanged(principal, to: true)
    }

    func unregister(_ principal: LoginItemPrincipal) throws {
        machine.registrationChanged(principal, to: false)
    }

    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        machine.isRegistered(principal) ? .enabled : .notRegistered
    }
}

/// The microphone, granted. Reading never prompts here and neither does asking:
/// a fixture run must not raise a system dialog.
struct FixtureMicrophone: MicrophoneAuthorizationReading {
    var microphoneState: PermissionState { .granted }

    func requestMicrophone() async -> PermissionState { .granted }
}

/// The liveness probes, reading the machine rather than a fixed answer. Every
/// path but the daemon's own socket is there: the throwaway home is real, and
/// the socket is the one thing a lifecycle transaction takes away.
struct FixtureProbes: ProcessLiveness, PathPresence, WebLiveness, PortProbing {
    let machine: FixtureMachine

    func isRunning(pid: Int32) -> Bool { machine.isRunning(pid: pid) }

    func exists(atPath path: String) -> Bool {
        path.hasSuffix(".sock") ? machine.daemonRunning : true
    }

    func isLive(origin: String) async -> Bool { machine.daemonRunning }

    func isAccepting(origin: String) async -> Bool { machine.daemonRunning }
}

/// Where the bundle is, as activation's refusals ask about it.
struct FixtureInstallation: InstallationProbing {
    let canonicallyInstalled: Bool

    func isCanonicallyInstalled() -> Bool { canonicallyInstalled }

    func legacyServiceUnitScope() -> LegacyServiceScope? { nil }

    func installedCopies() -> [String] { [Bundle.main.bundlePath] }
}

/// The daemon on that home is this app's own engine.
struct FixtureDaemonIdentity: DaemonIdentityProbing {
    func identify(home: URL) async throws -> DaemonIdentityAnswer { .app }
}

/// The two remembered choices, in memory. User defaults are shared with the
/// installed app under one bundle id, and a fixture run must not move the
/// operator's last pane or sidebar.
@MainActor
final class FixturePaneStore: SettingsPaneStoring {
    var lastSettingsPane: String?
}

@MainActor
final class FixtureSidebarStore: SidebarVisibilityStoring {
    var sidebarVisible: Bool?
}

/// The browser, not opened. A fixture sign-in must not send the operator to a
/// provider's consent page.
struct FixtureExternalOpener: ExternalOpening {
    func open(_ url: URL) -> Bool { true }
}

/// No directory dialog. Welcome's `Use an existing Fermix home…` answers as a
/// cancelled panel does.
@MainActor
struct FixtureDirectoryChooser: DirectoryChoosing {
    func chooseDirectory(prompt: String) -> URL? { nil }
}

// MARK: - The environment

extension AppEnvironment {
    /// The fixture configuration's boundary: a throwaway home, the contract's
    /// golden answers, and probes that report the declared machine.
    static func fixture(_ launch: FixtureLaunch) throws -> AppEnvironment {
        let location = try FixtureRoot.prepared(for: launch.startSlug)
        let contract = try ManagementContract.vendored()
        // One machine behind every seam that can see it, so a transaction the
        // transport commits is the same one the probes report on.
        let machine = FixtureMachine(daemonUp: launch.home != .daemonStarting)
        let transport = try FixtureManagementTransport(
            machine: machine,
            readiness: launch.home.readiness
        )
        let makeClient: @Sendable () throws -> ManagementClient = {
            ManagementClient(transport: transport, contract: contract)
        }
        let probes = FixtureProbes(machine: machine)
        let configuration = try ProductConfiguration.bundled()

        return AppEnvironment(
            configuration: configuration,
            appBuild: AppBuild(configuration: configuration),
            location: location,
            makeClient: makeClient,
            makePlane: { _ in ManagementControlPlane(client: try makeClient()) },
            loginItems: FixtureLoginItems(machine: machine),
            // Nothing to compare a registration against, which is what keeps a
            // fixture run from claiming the agent plist changed.
            plists: AbsentAgentPlistDigest(),
            microphone: FixtureMicrophone(),
            settingsPanes: FixturePaneStore(),
            sidebarVisibility: FixtureSidebarStore(),
            opener: FixtureExternalOpener(),
            updater: UnwiredUpdater(),
            chooser: FixtureDirectoryChooser(),
            processes: probes,
            paths: probes,
            web: probes,
            ports: probes,
            installation: FixtureInstallation(
                canonicallyInstalled: launch.home != .notInApplications
            ),
            identities: FixtureDaemonIdentity(),
            // An installed machine: `notInApplications` exists to render the
            // location refusal, and the Starting ladder is looked at with the
            // registration row the shipped activation draws.
            activationPlan: .installed,
            sleeper: TaskSleeper(),
            // No bundled manifest to compare, so the launch reconcile answers
            // aligned and the only restart this home asks for is the daemon's
            // own (M34 §7.2).
            reconciler: EngineReconciler(bundled: nil, bundledPlistDigest: nil),
            termination: ApplicationTermination(),
            launcherPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/fermix")
                .path
        )
    }
}

// MARK: - The second composition root

extension AppComposition {
    /// The same graph as `AppComposition()`, standing on the fixture
    /// environment. There is no branch inside the product configuration: the
    /// two roots differ only in what they are handed.
    convenience init(fixture launch: FixtureLaunch) throws {
        self.init(environment: try .fixture(launch))
    }

    /// Opens what the launch asked for.
    ///
    /// The product's own entry is `coordinator.start(reason:)`, which resolves a
    /// launch reason; a fixture launch names its surface outright, so it goes
    /// through the same coordinator by the same public verbs.
    func present(fixture launch: FixtureLaunch) {
        launch.present(with: coordinator, showRestartSheet: { [coordinator] in coordinator.askForRestart() })
    }
}

extension FixtureLaunch {
    /// Opens this launch through the coordinator's own verbs.
    ///
    /// The restart sheet is the coordinator's, the same door the Attention row,
    /// the Daemon menu and the status item ask through, so it arrives as a
    /// closure rather than a second owner of it.
    @MainActor
    func present(with coordinator: AppCoordinator, showRestartSheet: () -> Void) {
        switch presentation {
        case .assistant(let stage):
            coordinator.openAssistant(at: stage)
        case .route(let route):
            coordinator.open(route)
        case .settings(let pane):
            coordinator.open(.settings(pane))
        case .homeWithRestartSheet:
            coordinator.open(.home)
            showRestartSheet()
        }
    }
}
#endif
