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
    /// Starting, on a Mac whose background item macOS is holding for the
    /// person. It is a state of Starting rather than a screen, so like Boot
    /// failed it opens on Starting and the machine produces the wait.
    case approvalStep
    /// Chat over a timeline with nothing in it, which is the only way its
    /// empty state is drawn: `chat` itself opens on the full timeline.
    case emptyChat
    /// Chat with the browser pane open beside it on two fake tabs. The pane
    /// closed is `chat` itself.
    case browser
    /// Chat with a voice call begun on launch, which the scripted daemon
    /// carries through a conversation to listening.
    case chatCall
    /// Chat with a voice call begun on launch, which the scripted daemon ends
    /// at its cost ceiling.
    case failedChatCall
    /// Settings, Channels, with the Phone sheet up on one of its steps. The
    /// sheet is presented from the phone model's own flag, which is the flag
    /// the row's button and the last setup screen set.
    case phone(FixturePhoneStart)

    static let settingsPrefix = "settings/"
    static let assistantPrefix = "assistant/"
    static let phonePrefix = "phone/"
    static let restartSheetName = "restart-sheet"
    static let approvalStepName = "assistant/approval"
    static let emptyChatName = "chat-empty"
    static let browserName = "browser"
    static let chatCallName = "chat-call"
    static let failedChatCallName = "chat-call-failed"

    /// The start a launch argument named, or nil where this build publishes no
    /// such surface. A mistyped name is refused by the caller rather than
    /// opening Home, which would look like the argument worked.
    init?(name: String) {
        if name == Self.restartSheetName {
            self = .restartSheet
        } else if name == Self.approvalStepName {
            self = .approvalStep
        } else if name == Self.emptyChatName {
            self = .emptyChat
        } else if name == Self.browserName {
            self = .browser
        } else if name == Self.chatCallName {
            self = .chatCall
        } else if name == Self.failedChatCallName {
            self = .failedChatCall
        } else if let slug = name.dropping(prefix: Self.settingsPrefix) {
            guard let pane = SettingsPane(rawValue: slug) else { return nil }
            self = .settings(pane)
        } else if let stage = name.dropping(prefix: Self.assistantPrefix) {
            guard let screen = OnboardingStage(rawValue: stage) else { return nil }
            self = .assistant(screen)
        } else if let step = name.dropping(prefix: Self.phonePrefix) {
            guard let start = FixturePhoneStart(rawValue: step) else { return nil }
            self = .phone(start)
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
            + [restartSheetName, approvalStepName, emptyChatName, browserName, chatCallName, failedChatCallName]
            + FixturePhoneStart.allCases.map { phonePrefix + $0.rawValue }
    }
}

/// The Phone sheet's steps a fixture launch opens on (M60).
///
/// Each one is a phone channel on the fixture machine, never a step set on the
/// sheet: the sheet opens the way the row's button opens it, and the daemon's
/// golden answers walk it to the step. A window waiting for a scan stays on
/// Scan; every other moment is read a second after the window opens.
enum FixturePhoneStart: String, CaseIterable {
    case scan
    case compare
    case paired
    case ended

    /// What the sheet is opened for.
    var intent: PhoneSheetIntent { .pair }

    /// The channel the machine has: running, with the window in the moment the
    /// step is read from.
    var channel: FixturePhoneChannel {
        switch self {
        case .scan: return FixturePhoneChannel(switchedOn: true, running: true, moment: "awaiting_scan")
        case .compare: return FixturePhoneChannel(switchedOn: true, running: true, moment: "awaiting_decision")
        case .paired: return FixturePhoneChannel(switchedOn: true, running: true, moment: "approved")
        case .ended: return FixturePhoneChannel(switchedOn: true, running: true, moment: "expired")
        }
    }
}

/// The phone channel on the fixture machine (M60): its switch, whether it
/// runs, and the moment of the pairing window the daemon answers from.
///
/// The channel starts only at boot, so the switch moves `running` only through
/// a restart, exactly as the daemon's does.
struct FixturePhoneChannel: Equatable {
    var switchedOn: Bool
    var running: Bool
    /// The state `mobile.pair.get` answers in, as the golden published for
    /// it. Nil is the moment `mobile.status` itself publishes.
    let moment: String?

    /// The goldens as published: a running channel, read in the moment its
    /// status names.
    static let published = FixturePhoneChannel(switchedOn: true, running: true, moment: nil)

    /// A channel nobody has turned on.
    static let switchedOff = FixturePhoneChannel(switchedOn: false, running: false, moment: nil)
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
    /// macOS is holding the background item for the person, so the Starting
    /// ladder waits on its service row and launchd starts nothing.
    case awaitingApproval
    /// The daemon is up and every readiness gate has passed, which is the only
    /// machine Ready renders on: the screen claims the install is live, so it
    /// refuses to draw while a gating failure stands (M34 §4). The default home
    /// carries the gating provider failure that Home's Attention section and
    /// the Connect your AI screen are looked at through, so on that machine
    /// Ready draws its refusal notice and the screen itself was unreachable.
    case configured
    /// Nothing has been set up: no configured provider and no channel, with the
    /// personalization the daemon's first boot seeds from the machine. It is
    /// the machine the assistant's decision screens are actually
    /// used on, and no fixture home was ever in it — which is how the two
    /// first-run defects on Connect your AI shipped without anyone seeing them
    /// (M34 §4).
    case fresh

    /// The machine each start is looked at on.
    static func forStart(_ start: FixtureStart) -> FixtureHome {
        switch start {
        case .assistant(.starting): return .daemonStarting
        case .assistant(.bootFailed): return .notInApplications
        case .approvalStep: return .awaitingApproval
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
        case .settled, .daemonStarting, .notInApplications, .awaitingApproval: return .gatingFailure
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
    /// Chat, with the browser pane open on the fixture's two pages.
    case chatWithBrowser
    /// Chat, with a voice call begun.
    case chatWithCall
    /// Settings, Channels, with the Phone sheet up for what it was asked.
    case channelsWithPhone(PhoneSheetIntent)
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
        case .assistant(.bootFailed), .approvalStep: return .assistant(.starting)
        case .assistant(let stage): return .assistant(stage)
        case .surface(let route): return .route(route)
        case .settings(let pane): return .settings(pane)
        case .restartSheet: return .homeWithRestartSheet
        case .emptyChat: return .route(.chat)
        case .browser: return .chatWithBrowser
        case .chatCall, .failedChatCall: return .chatWithCall
        case .phone(let step): return .channelsWithPhone(step.intent)
        }
    }

    /// The phone channel the machine has: the Phone sheet's own for its
    /// steps, switched off on a first run, where nothing is on yet, and the
    /// goldens as published everywhere else.
    var phoneChannel: FixturePhoneChannel {
        if case .phone(let step) = start { return step.channel }

        return home == .fresh ? .switchedOff : .published
    }

    /// The timeline the chat holds. Every start but the empty one gets the
    /// full timeline, so Chat reached from any of them shows a conversation.
    var companionTimeline: FixtureCompanionTimeline {
        start == .emptyChat ? .empty : .full
    }

    /// The call the voice socket's scripted daemon plays. Every start but the
    /// failed call's gets the conversation, so a call begun from the Pet page
    /// of any of them has a daemon to answer it.
    var realtimeCall: FixtureRealtimeCall {
        start == .failedChatCall ? .costLimit : .conversation
    }

    /// A filesystem-safe name for this start, which is what keeps two starts
    /// from sharing one throwaway home.
    var startSlug: String {
        switch start {
        case .surface(let route): return route.rawValue
        case .settings(let pane): return "settings-\(pane.slug)"
        case .assistant(let stage): return "assistant-\(stage.rawValue)"
        case .restartSheet: return FixtureStart.restartSheetName
        case .approvalStep: return "assistant-approval"
        case .emptyChat: return FixtureStart.emptyChatName
        case .browser: return FixtureStart.browserName
        case .chatCall: return FixtureStart.chatCallName
        case .failedChatCall: return FixtureStart.failedChatCallName
        case .phone(let step): return "phone-\(step.rawValue)"
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
    /// macOS holding the agent for the person once it is registered, as on a
    /// first install: the switch in System Settings is the only thing that
    /// moves it.
    private let agentHeldForApproval: Bool
    private var registered: Set<LoginItemPrincipal> = [.agent]
    private var running: Bool
    private var pid = FixtureMachine.firstPid
    private var phone: FixturePhoneChannel

    init(daemonUp: Bool, agentHeldForApproval: Bool = false, phone: FixturePhoneChannel = .published) {
        launchdStartsTheDaemon = daemonUp
        running = daemonUp
        self.agentHeldForApproval = agentHeldForApproval
        self.phone = phone
        // A first install: nothing is registered until setup asks.
        if agentHeldForApproval { registered = [] }
    }

    var currentPid: Int32 { withLock { pid } }
    var daemonRunning: Bool { withLock { running } }
    var phoneChannel: FixturePhoneChannel { withLock { phone } }

    func isRegistered(_ principal: LoginItemPrincipal) -> Bool {
        withLock { registered.contains(principal) }
    }

    /// What macOS says about a principal on this machine.
    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        guard isRegistered(principal) else { return .notRegistered }

        return principal == .agent && agentHeldForApproval ? .requiresApproval : .enabled
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

    /// launchd loading the job, which is what changes the pid. The phone
    /// channel starts at boot, as whatever its switch says.
    private func start() {
        guard launchdStartsTheDaemon else { return }

        pid += 1
        running = true
        phone.running = phone.switchedOn
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
        machine.status(principal)
    }

    /// A fixture run never opens System Settings.
    func openSettings() {}
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

/// The remembered choices, in memory. User defaults are shared with the
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

/// The link preference at its default, the pane, and never written to the
/// operator's defaults.
@MainActor
final class FixtureLinkPreferenceStore: LinkPreferenceStoring {
    var linkDestination = UserDefaultsLinkPreferenceStore.defaultDestination
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
    /// golden answers, and probes that report the declared machine. The mascot
    /// is the real renderer the executable handed in, so a fixture capture
    /// shows the animation the product draws.
    static func fixture(_ launch: FixtureLaunch, mascot: any MascotRendering) throws -> AppEnvironment {
        let location = try FixtureRoot.prepared(for: launch.startSlug)
        let contract = try ManagementContract.vendored()
        // One machine behind every seam that can see it, so a transaction the
        // transport commits is the same one the probes report on.
        let machine = FixtureMachine(
            daemonUp: launch.home != .daemonStarting && launch.home != .awaitingApproval,
            agentHeldForApproval: launch.home == .awaitingApproval,
            phone: launch.phoneChannel
        )
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
            linkPreference: FixtureLinkPreferenceStore(),
            opener: FixtureExternalOpener(),
            updater: UnwiredUpdater(),
            mascot: mascot,
            // Fake pages, so the pane is looked at with no web engine and no
            // network behind it.
            makeBrowser: { _ in FixtureBrowserEngine() },
            // A session with nothing to hear: the fixture's Mac is unlocked
            // and awake for the whole run.
            session: SessionAvailability(standing: [], distributed: NotificationCenter(), workspace: NotificationCenter()),
            workspace: FixtureWorkspaceOpener(),
            chooser: FixtureDirectoryChooser(),
            processes: probes,
            paths: probes,
            web: probes,
            ports: probes,
            installation: FixtureInstallation(
                canonicallyInstalled: launch.home != .notInApplications
            ),
            identities: FixtureDaemonIdentity(),
            companionLines: FixtureCompanionTransport(timeline: launch.companionTimeline),
            browserHostLines: FixtureBrowserHostTransport(),
            // A scripted daemon on the voice socket and a silent engine under
            // the call, so a call begun from any surface reaches neither the
            // realtime socket nor the microphone: the claim at the top of this
            // file holds by construction.
            realtimeLines: FixtureRealtimeTransport(call: launch.realtimeCall, deadlines: MainQueueDeadlineScheduler()),
            voiceAudio: FixtureAudioEngine(deadlines: MainQueueDeadlineScheduler()),
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
    convenience init(fixture launch: FixtureLaunch, mascot: any MascotRendering) throws {
        self.init(environment: try .fixture(launch, mascot: mascot))
    }

    /// Opens what the launch asked for.
    ///
    /// The product's own entry is `coordinator.start(reason:)`, which resolves a
    /// launch reason; a fixture launch names its surface outright, so it goes
    /// through the same coordinator by the same public verbs.
    func present(fixture launch: FixtureLaunch) {
        launch.present(
            with: coordinator,
            showRestartSheet: { [coordinator] in coordinator.askForRestart() },
            openBrowser: { [browser] in FixtureWebPage.openTabs(in: browser) },
            beginCall: { [voice] in voice.toggleCall() },
            presentPhone: { [settings] intent in settings.phone.present(intent) }
        )
    }
}

extension FixtureLaunch {
    /// Opens this launch through the coordinator's own verbs.
    ///
    /// The restart sheet is the coordinator's, the same door the Attention row,
    /// the Daemon menu and the status item ask through, so it arrives as a
    /// closure rather than a second owner of it. The browser pane is the
    /// browser coordinator's, and the call is the voice coordinator's, the one
    /// the Pet page's button asks; both arrive the same way. The Phone sheet
    /// is the phone model's, the one the Channels row asks.
    @MainActor
    func present(
        with coordinator: AppCoordinator,
        showRestartSheet: () -> Void,
        openBrowser: () -> Void,
        beginCall: () -> Void,
        presentPhone: (PhoneSheetIntent) -> Void
    ) {
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
        case .chatWithBrowser:
            coordinator.open(.chat)
            openBrowser()
        case .chatWithCall:
            coordinator.open(.chat)
            beginCall()
        case .channelsWithPhone(let intent):
            coordinator.open(.settings(.channels))
            presentPhone(intent)
        }
    }
}
#endif
