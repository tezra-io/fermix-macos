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
}

/// What activation ended as.
public enum ActivationOutcome: Equatable, Sendable {
    case activated(ManagementHello)
    case failed(BootFailureCause)
}

/// Bringing the daemon up, as one bounded transaction.
///
/// Main-actor isolated on purpose. Progress and the final outcome then arrive
/// in the order they happened: a stage hopping to the main actor on its own
/// could land after the outcome that supersedes it, and the ladder would show a
/// step the transaction had already moved past.
@MainActor
public protocol ActivationDriving {
    func activate(progress: @escaping (ActivationStage) -> Void) async -> ActivationOutcome
}

/// Activation: confirm the bootstrap record, register both login items
/// independently, wait for the daemon, negotiate, and prove the local web
/// surface answers — inside one 90-second budget.
///
/// Every way this can end is one of the eight named causes. Nothing here
/// retries through a second mechanism: a step that cannot succeed reports which
/// step it was and what it saw.
@MainActor
public struct ActivationCoordinator: ActivationDriving {
    private let store: BootstrapStore
    private let services: ServiceController
    private let gateway: any DaemonQuerying
    private let paths: any PathPresence
    private let installation: any InstallationProbing
    private let web: any WebLiveness
    private let ports: any PortProbing
    private let sleeper: any Sleeping
    private let now: () -> Date
    private let log = AppLog.logger(.lifecycle)

    public init(
        store: BootstrapStore,
        services: ServiceController,
        gateway: any DaemonQuerying,
        paths: any PathPresence,
        installation: any InstallationProbing,
        web: any WebLiveness,
        ports: any PortProbing,
        sleeper: any Sleeping,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.services = services
        self.gateway = gateway
        self.paths = paths
        self.installation = installation
        self.web = web
        self.ports = ports
        self.sleeper = sleeper
        self.now = now
    }

    public func activate(progress: @escaping (ActivationStage) -> Void) async -> ActivationOutcome {
        let deadline = now().addingTimeInterval(ActivationPolicy.budget)

        // Refusals come before any mutation: nothing below this guard runs
        // for an app outside /Applications or beside a recognized Homebrew
        // install, so a refused activation has written and registered nothing.
        if let cause = preflight() { return .failed(cause) }

        progress(.registering)
        guard let record = recordBootstrap() else { return .failed(.invalidPackage) }
        if let cause = registerLoginItems() { return .failed(cause) }

        progress(.starting)
        if let cause = await waitForSocket(at: record.daemonSocketURL.path, deadline: deadline) {
            return .failed(cause)
        }

        let hello: ManagementHello
        do {
            hello = try await gateway.negotiate()
        } catch {
            return .failed(negotiationCause(error))
        }

        progress(.preparing)
        if let cause = await waitForWeb(origin: hello.setup.origin, deadline: deadline) {
            return .failed(cause)
        }

        return .activated(hello)
    }

    // MARK: - Steps

    /// The two refusals that precede every mutation. Order matters only for
    /// the message: the wrong location is the cheaper fix, so it is named
    /// first.
    private func preflight() -> BootFailureCause? {
        guard installation.isCanonicallyInstalled() else {
            log.error("refusing activation: the app is not running from /Applications")
            return .notInApplications
        }

        guard !installation.legacyServiceUnitExists() else {
            log.error("refusing activation: a recognized legacy service unit exists")
            return .legacyInstallPresent
        }

        return nil
    }

    /// Writes or confirms this account's bootstrap record. The Fermix home
    /// itself is not created: the engine's first-boot path owns that, and a
    /// second creation path would drift from it.
    private func recordBootstrap() -> BootstrapRecord? {
        do {
            return try store.save(fermixHome: try store.resolvedHome())
        } catch {
            log.error("the bootstrap record could not be written: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Registers both principals. They are independent, so a GUI-login refusal
    /// is logged and does not fail activation: the background service is what
    /// the daemon needs, and the GUI opening at login is a separate consent.
    private func registerLoginItems() -> BootFailureCause? {
        let priorAgentStatus = services.status(.agent)

        do {
            try services.enable(.agent)
        } catch {
            log.error("the background item could not be registered: \(String(describing: error), privacy: .public)")
            return .invalidPackage
        }

        do {
            try services.enable(.mainApp)
        } catch {
            log.error("the GUI login item could not be registered: \(String(describing: error), privacy: .public)")
        }

        switch services.status(.agent) {
        case .enabled:
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
            return .invalidPackage
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
    /// would keep Setup hidden long after it works.
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

    private func negotiationCause(_ error: any Error) -> BootFailureCause {
        guard let management = error as? ManagementError else { return .timedOut }

        switch management {
        case .unsupportedProtocolVersion:
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
