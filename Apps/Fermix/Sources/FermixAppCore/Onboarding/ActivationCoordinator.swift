import Foundation

/// Is anything at all accepting connections on that origin?
///
/// Distinct from `WebLiveness`, which asks whether *the daemon's* health
/// endpoint answers. The pair is what separates "another program holds the
/// port" from "nothing is listening at all", which are different failures with
/// different remedies.
public protocol PortProbing: Sendable {
    func isAccepting(origin: String) async -> Bool
}

/// A TCP connect to the origin, and nothing more. It sends no request and reads
/// no body: the question is only whether something answered the handshake.
public struct TCPPortProbe: PortProbing {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1) {
        self.timeout = timeout
    }

    public func isAccepting(origin: String) async -> Bool {
        guard let components = URLComponents(string: origin),
              let host = components.host
        else { return false }

        let port = components.port ?? (components.scheme == "https" ? 443 : 80)
        let probe = SocketProbe(host: host, port: port, timeout: timeout)

        // The connect itself blocks for up to `timeout`, so it runs off
        // whatever actor asked. Activation runs on the main actor, and a
        // one-second stall there is a frame the user watches drop.
        return await Task.detached(priority: .utility) { probe.connects() }.value
    }
}

/// How long activation may take, and how often it looks.
public enum ActivationPolicy {
    /// M34 §5: at most 90 seconds to a failure state.
    public static let budget: TimeInterval = 90
    public static let pollInterval: TimeInterval = 0.25
    /// §5 resource budgets: three automatic relaunch attempts before the
    /// service parks in the attention state.
    public static let crashLoopThreshold = 3
    /// The targets row four probes (M34 §4). The daemon owns the 5-second budget
    /// for the probe itself; a second timer here would be a competing bound.
    public static let detectTargets: [ManagementDetectTarget] = [
        .existingPrimary, .claudeCode, .codexCLI, .ollama
    ]
}

/// What row four read, so the assistant opens on what is already there rather
/// than re-asking a configured home (M34 §15.2).
public struct ActivationPreparation: Equatable, Sendable {
    public let state: ManagementSetupState?
    public let detections: ManagementDetections?
    /// The daemon is one release behind the bundle, so the v2 reads refused.
    /// A named state with one action, never a boot failure (M34 §7.1).
    public let requiresNewerEngine: Bool
    /// Any other refusal, in the daemon's own words. Carried rather than
    /// swallowed: the assistant renders it and the daemon is still up.
    public let refusal: String?

    public init(
        state: ManagementSetupState? = nil,
        detections: ManagementDetections? = nil,
        requiresNewerEngine: Bool = false,
        refusal: String? = nil
    ) {
        self.state = state
        self.detections = detections
        self.requiresNewerEngine = requiresNewerEngine
        self.refusal = refusal
    }
}

/// What activation ended as.
///
/// A refusal carries the facts its own sentence needs: the copies it found, the
/// journal it could not use. Without them the card names a condition and not the
/// thing on this Mac that is in it (M34 §15.2).
public enum ActivationOutcome: Equatable, Sendable {
    case activated(ManagementHello, prepared: ActivationPreparation)
    case failed(BootFailureCause, evidence: [String])

    public static func failed(_ cause: BootFailureCause) -> ActivationOutcome {
        .failed(cause, evidence: [])
    }
}

/// Which steps an activation runs, and therefore which rows the Starting ladder
/// draws.
///
/// One value rather than two flags read in two places: the ladder has to draw
/// exactly the steps the transaction takes, and a row shown for work nobody
/// does is the defect Applying's restart row already earned once.
///
/// It compiles into every build, exactly as `DevelopmentEngineLaunchRequest`
/// does. Only the configuration that *selects* `developmentBackgroundService` is
/// debug-only, so no drawn surface is compiled differently in a release build.
public enum ActivationPlan: Equatable, Sendable {
    /// The shipped transaction: refuse on the three conditions that name an
    /// installed copy, register both login items, then wait, negotiate and read.
    case installed
    /// The staged debug bundle uses the same background agent, with its own
    /// port and home. Installation checks do not apply to its build directory.
    case developmentBackgroundService

    /// The stages this plan reports, in the order it reports them.
    ///
    /// Derived from the whole ladder minus the one row a plan can drop, so a
    /// stage added later joins both plans instead of only the one somebody
    /// remembered to edit.
    public var stages: [ActivationStage] {
        ActivationStage.allCases.filter { registersLoginItems || $0 != .registering }
    }

    /// The stage a fresh activation starts on.
    public var firstStage: ActivationStage {
        guard let first = stages.first else { preconditionFailure("\(self) runs no stage") }

        return first
    }

    /// Whether the transaction registers the two login items, which is also
    /// whether the ladder draws the row that says so.
    public var registersLoginItems: Bool { true }

    /// A development bundle must not become the account's default login app.
    public var registersGUILoginItem: Bool { self == .installed }

    /// Whether the preflight asks the three questions about where this bundle is
    /// installed. The daemon identity probe is deliberately not one of them: a
    /// foreign or pre-management daemon on the home is a refusal no plan
    /// overrides.
    public var inspectsInstallation: Bool { self == .installed }

    /// Where a stage sits on this plan's ladder.
    public func rowIndex(of stage: ActivationStage) -> Int {
        guard let index = stages.firstIndex(of: stage) else {
            preconditionFailure("\(stage) is not a stage of \(self)")
        }

        return index
    }
}

/// Bringing the daemon up, as one bounded transaction.
///
/// Main-actor isolated on purpose. Progress and the final outcome then arrive
/// in the order they happened: a stage hopping to the main actor on its own
/// could land after the outcome that supersedes it, and the ladder would show a
/// step the transaction had already moved past.
@MainActor
public protocol ActivationDriving {
    /// The steps this driver runs. The Starting ladder is built from it, so the
    /// screen draws exactly what the transaction behind it does.
    var plan: ActivationPlan { get }

    func activate(progress: @escaping (ActivationStage) -> Void) async -> ActivationOutcome
}

/// Activation: adopt whatever `fermix migrate-to-app` handed over, refuse on
/// every condition that would make the mutation wrong, register both login
/// items independently, wait for the daemon, negotiate, prove the local web
/// surface answers, and read what is already set up — inside one 90-second
/// budget.
///
/// Every way this can end is one of the named causes. Nothing here retries
/// through a second mechanism: a step that cannot succeed reports which step it
/// was and what it saw.
@MainActor
public struct ActivationCoordinator: ActivationDriving {
    public let plan: ActivationPlan
    private let store: BootstrapStore
    private let handoff: MigrationHandoffReader
    private let services: ServiceController
    private let gateway: any DaemonQuerying
    private let paths: any PathPresence
    private let installation: any InstallationProbing
    private let identities: any DaemonIdentityProbing
    private let web: any WebLiveness
    private let ports: any PortProbing
    private let sleeper: any Sleeping
    private let now: () -> Date
    private let log = AppLog.logger(.lifecycle)

    /// - Parameter plan: which steps this activation runs. The shipped
    ///   configuration is the default; the development configuration in
    ///   `DevelopmentEngineConfiguration.swift` is the only other caller.
    public init(
        store: BootstrapStore,
        handoff: MigrationHandoffReader,
        services: ServiceController,
        gateway: any DaemonQuerying,
        paths: any PathPresence,
        installation: any InstallationProbing,
        identities: any DaemonIdentityProbing,
        web: any WebLiveness,
        ports: any PortProbing,
        sleeper: any Sleeping,
        plan: ActivationPlan = .installed,
        now: @escaping () -> Date = { Date() }
    ) {
        self.plan = plan
        self.store = store
        self.handoff = handoff
        self.services = services
        self.gateway = gateway
        self.paths = paths
        self.installation = installation
        self.identities = identities
        self.web = web
        self.ports = ports
        self.sleeper = sleeper
        self.now = now
    }

    public func activate(progress: @escaping (ActivationStage) -> Void) async -> ActivationOutcome {
        let deadline = now().addingTimeInterval(ActivationPolicy.budget)

        // The handoff comes first, before every refusal, because the home it
        // names is the home the refusals have to be asked about: probing the
        // account default would clear a foreign daemon that is sitting on the
        // operator's real home (M34 §15.0 step 5).
        if let refusal = adoptHandoff() { return refusal }

        // The one home every refusal below is asked about, resolved once. A
        // record that exists and cannot be read is neither a fresh account nor a
        // clear home: answering "no foreign daemon" from a read failure would
        // skip all three coexistence probes and mutate anyway. It is refused as
        // the same cause an unwritable record already earns.
        guard let home = resolveHome() else { return .failed(.bootstrapRecordUnusable) }

        // Refusals come before any mutation: nothing below this guard runs on a
        // home another daemon already owns, nor — on the installed plan — for an
        // app outside /Applications or beside a recognized Homebrew install.
        if let refusal = await preflight(home: home) { return refusal }

        // Whether this account has ever been activated, read before the record
        // is written: the GUI login item is a consent, and a re-run must not
        // switch back on what the operator turned off in Home (M34 §7.2).
        let firstActivation = !store.hasRegistrationReceipt()
        guard let record = recordBootstrap(home: home) else { return .failed(.bootstrapRecordUnusable) }
        if let cause = registerLoginItems(firstActivation: firstActivation, progress: progress) {
            return .failed(cause)
        }

        progress(.starting)
        if let cause = await waitForSocket(at: record.daemonSocketURL.path, deadline: deadline) {
            return .failed(cause)
        }

        progress(.answering)
        let hello: ManagementHello
        do {
            hello = try await gateway.negotiate()
        } catch {
            return .failed(negotiationCause(error))
        }
        if let cause = await waitForWeb(origin: hello.setup.origin, deadline: deadline) {
            return .failed(cause)
        }

        // A daemon on the adopted home has answered, so the journal has done its
        // job. It is cleared only here, so a boot that failed part-way leaves it
        // for the next attempt.
        clearHandoff()

        progress(.reading)
        return .activated(hello, prepared: await readWhatIsSetUp())
    }

    // MARK: - Steps

    /// Adopts the home `fermix migrate-to-app` recorded, if it left one.
    ///
    /// The journal wins over `launcher.json` and is consumed once (M34 §15.2).
    /// A journal that cannot be adopted refuses and stays: re-running the verb
    /// is the remedy, and clearing it here would delete the only record of the
    /// home the operator was using.
    private func adoptHandoff() -> ActivationOutcome? {
        do {
            guard let journal = try handoff.read() else { return nil }

            try store.save(fermixHome: journal.fermixHome)
            log.log("adopted the migration handoff home")
            return nil
        } catch let defect as MigrationHandoffDefect {
            return handoffRefusal(defect)
        } catch BootstrapStoreError.invalidHome(let defect) {
            // The journal parsed, and the home it names cannot be used by this
            // account. That is a defect in the journal's home rather than in
            // the record this activation was about to write, so it earns the
            // journal's own refusal and not the record's.
            return handoffRefusal(.invalidHome(defect))
        } catch {
            log.error("the handoff home could not be recorded: \(String(describing: error), privacy: .public)")
            return .failed(.bootstrapRecordUnusable)
        }
    }

    /// The refusal card's two lines: the journal's path, and the sentence for
    /// the validator failure that refused it. Without both, the card names a
    /// file nobody can find and a condition nobody can read (M34 §15.2); a
    /// `String(describing:)` of the defect is a Swift enum dump, not a sentence.
    private func handoffRefusal(_ defect: MigrationHandoffDefect) -> ActivationOutcome {
        let sentence = ProductStrings.handoffDefect(defect)
        log.error("the migration handoff was refused: \(sentence, privacy: .public)")

        return .failed(.migrationHandoffInvalid, evidence: [handoff.journalURL.path, sentence])
    }

    private func clearHandoff() {
        do {
            try handoff.clear()
        } catch {
            log.error("the migration handoff could not be cleared: \(String(describing: error), privacy: .public)")
        }
    }

    /// The refusals that precede every mutation, in M34 §4's order: the wrong
    /// location is the cheapest fix, so it is named first, and the three
    /// coexistence probes follow because each costs a socket or LaunchServices.
    ///
    /// The three that inspect the installation belong to the installed plan. A
    /// developer-run engine is deliberately launched from a build directory
    /// beside whatever else the machine has, so asking them would refuse every
    /// launch. The daemon identity probe is asked on both plans, because who
    /// already owns the recorded home is a fact about the home rather than
    /// about this bundle.
    private func preflight(home: URL) async -> ActivationOutcome? {
        if plan.inspectsInstallation, let refusal = locationRefusal() { return refusal }
        if let refusal = await foreignDaemonRefusal(home: home) { return refusal }
        if plan.inspectsInstallation, let refusal = duplicateCopyRefusal() { return refusal }

        return nil
    }

    /// Where this bundle is running from, and what else on this Mac already
    /// claims to be Fermix.
    private func locationRefusal() -> ActivationOutcome? {
        guard installation.isCanonicallyInstalled() else {
            log.error("refusing activation: the app is not running from /Applications")
            return .failed(.notInApplications)
        }

        guard let scope = installation.legacyServiceUnitScope() else { return nil }

        log.error("refusing activation: a \(scope.rawValue, privacy: .public)-scope legacy unit exists")
        return .failed(scope == .system ? .legacySystemInstallPresent : .legacyInstallPresent)
    }

    /// A second installed copy, which is the one refusal that carries the paths
    /// it found so the card can name them.
    private func duplicateCopyRefusal() -> ActivationOutcome? {
        let copies = installation.installedCopies()
        guard copies.count > 1 else { return nil }

        log.error("refusing activation: \(copies.count, privacy: .public) copies of this bundle are installed")
        return .failed(.duplicateCopyPresent, evidence: copies)
    }

    /// The home this activation is about: the journal's where one was adopted,
    /// the recorded one otherwise, and the account default on a fresh account.
    private func resolveHome() -> URL? {
        do {
            return try store.resolvedHome()
        } catch {
            log.error("the bootstrap record could not be read: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Who already owns the home this activation is about.
    ///
    /// A refusal rather than a bare cause, because one of the answers carries
    /// the daemon's own sentence and a card that names a condition without it
    /// cannot say which refusal was read (M34 §15.2).
    private func foreignDaemonRefusal(home: URL) async -> ActivationOutcome? {
        let answer: DaemonIdentityAnswer
        do {
            answer = try await identities.identify(home: home)
        } catch {
            // The probe could not be made at all, which is this bundle's own
            // contract failing to load. It is not a report that the home is
            // free, so activation refuses rather than mutating on a guess.
            log.error("the daemon identity probe could not run: \(String(describing: error), privacy: .public)")
            return .failed(.invalidPackage)
        }

        switch answer {
        case .none, .app:
            return nil
        case .foreign(let distribution):
            log.error("refusing activation: a \(distribution, privacy: .public) daemon owns this home")
            return .failed(.foreignDaemonRunning)
        case .preManagement:
            log.error("refusing activation: a pre-management daemon owns this home")
            return .failed(.preManagementDaemonRunning)
        case .unresponsive:
            log.error("refusing activation: something on this home's socket did not answer")
            return .failed(.daemonUnresponsive)
        case .refusedIdentity(let sentence):
            log.error("refusing activation: the daemon on this home answered \(sentence, privacy: .public)")
            return .failed(.daemonRefusedIdentity, evidence: [sentence])
        }
    }

    /// Writes or confirms this account's bootstrap record. The Fermix home
    /// itself is not created: the engine's first-boot path owns that, and a
    /// second creation path would drift from it.
    private func recordBootstrap(home: URL) -> BootstrapRecord? {
        do {
            return try store.save(fermixHome: home)
        } catch {
            log.error("the bootstrap record could not be written: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Registers both principals. They are independent, so a GUI-login refusal
    /// is logged and does not fail activation: the background service is what
    /// the daemon needs, and the GUI opening at login is a separate consent.
    ///
    /// The ladder row is lit here rather than by the caller, so the row that
    /// says the background service is being registered is drawn by the step that
    /// registers it and by nothing else.
    private func registerLoginItems(
        firstActivation: Bool,
        progress: (ActivationStage) -> Void
    ) -> BootFailureCause? {
        guard plan.registersLoginItems else { return nil }

        progress(.registering)
        let priorAgentStatus = services.status(.agent)

        do {
            try services.enable(.agent)
        } catch {
            log.error("the background item could not be registered: \(String(describing: error), privacy: .public)")
            return .registrationFailed
        }

        registerGUILoginItem(firstActivation: firstActivation)

        switch services.status(.agent) {
        case .enabled:
            recordRegistrationReceipt()
            return nil
        case .requiresApproval:
            // macOS publishes one status for "waiting for your approval" and
            // "you turned it off". The second signal is whether this run is the
            // one that registered it: an item already in that state before we
            // asked is one the user disabled.
            return priorAgentStatus == .requiresApproval ? .backgroundItemDisabled : .approvalPending
        case .notRegistered:
            return .backgroundItemDisabled
        case .notFound:
            return .registrationFailed
        }
    }

    /// The GUI's own login registration, which is a separate consent from the
    /// background service.
    ///
    /// It is asked for once, on the first activation of an account. Every later
    /// activation — and `fermix setup` on a configured home is one — leaves it
    /// exactly as the operator left it in Home, because switching it back on
    /// without asking is a consent taken rather than given (M34 §7.2).
    private func registerGUILoginItem(firstActivation: Bool) {
        guard firstActivation, plan.registersGUILoginItem else { return }

        do {
            try services.enable(.mainApp)
        } catch {
            log.error("the GUI login item could not be registered: \(String(describing: error), privacy: .public)")
        }
    }

    /// Records which plist was registered, so the next launch can tell a changed
    /// one from an unchanged one (M34 §7.2 step 5). A receipt that cannot be
    /// written is logged and never fatal: the reconciler reads an absent receipt
    /// as a difference, which re-registers rather than skipping.
    private func recordRegistrationReceipt() {
        guard let digest = services.bundledAgentPlistDigest() else { return }

        do {
            try store.recordAgentRegistration(plistSHA256: digest)
        } catch {
            log.error("the registration receipt could not be written: \(String(describing: error), privacy: .public)")
        }
    }

    /// Waits for `daemon.sock`, counting the times it appears and vanishes. A
    /// socket that keeps flapping is launchd restarting a daemon that keeps
    /// dying, which is a different failure from a slow first start.
    ///
    /// The socket has to be there twice in a row to count as up. A socket that
    /// exists once and is gone the next moment belongs to a daemon that did not
    /// survive its own start, and returning on the first sighting would make a
    /// crash loop unobservable — the wait would end before the second attempt.
    private func waitForSocket(at path: String, deadline: Date) async -> BootFailureCause? {
        var sawSocket = false
        var vanished = 0

        while now() < deadline {
            let present = paths.exists(atPath: path)

            if present {
                guard vanished < ActivationPolicy.crashLoopThreshold else { return .crashLoop }
                if sawSocket { return nil }
                sawSocket = true
            } else if sawSocket {
                sawSocket = false
                vanished += 1
                if vanished >= ActivationPolicy.crashLoopThreshold { return .crashLoop }
            }

            guard await tick() else { return .timedOut }
        }

        return .timedOut
    }

    /// Proves the daemon's own web surface answers. `/health/live` is the gate:
    /// `/health/ready` answers whether the daemon has finished warming, which
    /// would keep the assistant waiting long after it works.
    private func waitForWeb(origin: String, deadline: Date) async -> BootFailureCause? {
        while now() < deadline {
            if await web.isLive(origin: origin) { return nil }
            guard await tick() else { break }
        }

        // The daemon answered on its own socket, so the engine is alive. If
        // something is nonetheless accepting connections on the origin it
        // needs, that something is holding the port.
        return await ports.isAccepting(origin: origin) ? .bindFailure : .webUnavailable
    }

    /// Row four: what this home already has. Both reads are protocol v2, so a
    /// daemon one release behind refuses them — which is a named state carried
    /// on the outcome, not a boot failure (M34 §7.1).
    private func readWhatIsSetUp() async -> ActivationPreparation {
        do {
            let state = try await gateway.setupState()
            let detections = try await gateway.detect(ActivationPolicy.detectTargets)

            return ActivationPreparation(state: state, detections: detections)
        } catch {
            guard !ManagementMessage.requiresNewerEngine(error) else {
                return ActivationPreparation(requiresNewerEngine: true)
            }

            let sentence = ManagementMessage.sentence(for: error)
            log.error("reading the existing setup was refused: \(sentence, privacy: .public)")
            return ActivationPreparation(refusal: sentence)
        }
    }

    private func negotiationCause(_ error: any Error) -> BootFailureCause {
        guard let management = error as? ManagementError else { return .timedOut }

        switch management {
        // An empty intersection is the only version failure that stops a boot.
        // `methodRequiresNewerEngine` cannot reach here: `hello`'s minimum is 1
        // and it is the only call this path makes.
        case .incompatibleProtocol:
            return .incompatibleVersion
        case .daemon(let failure) where failure.code == .clientTooOld || failure.code == .daemonTooOld:
            return .incompatibleVersion
        case .transport(.socketMissing), .transport(.daemonNotListening):
            return .timedOut
        default:
            log.error("negotiation failed: \(String(describing: management), privacy: .public)")
            return .webUnavailable
        }
    }

    /// One bounded step of a poll. A cancelled sleep ends the wait rather than
    /// spinning through the remaining attempts.
    private func tick() async -> Bool {
        do {
            try await sleeper.sleep(seconds: ActivationPolicy.pollInterval)
            return true
        } catch {
            return false
        }
    }
}

/// A blocking connect with a deadline, used only to ask whether a port answers.
private struct SocketProbe {
    let host: String
    let port: Int
    let timeout: TimeInterval

    func connects() -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else { return false }
        defer { freeaddrinfo(results) }

        let descriptor = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var window = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))

        return connect(descriptor, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0
    }
}
