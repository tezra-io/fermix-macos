import AppKit
import Darwin
import Foundation

/// Is that process still alive?
public protocol ProcessLiveness {
    func isRunning(pid: Int32) -> Bool
}

/// Is that path there?
public protocol PathPresence {
    func exists(atPath path: String) -> Bool
}

/// Does the daemon's local web surface answer?
public protocol WebLiveness {
    func isLive(origin: String) async -> Bool
}

/// The wait between polls, injected so a bounded wait can be proven without
/// spending its wall-clock time. It throws so cancellation ends the wait rather
/// than turning it into a spin through the remaining attempts.
public protocol Sleeping {
    func sleep(seconds: TimeInterval) async throws
}

/// `kill(pid, 0)` asks the kernel whether a signal could be delivered, which is
/// the cheapest truthful liveness answer available without a handle.
public struct SystemProcessLiveness: ProcessLiveness {
    public init() {}

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }

        // EPERM means the process exists and belongs to someone else. Only
        // ESRCH means it is gone.
        return errno == EPERM
    }
}

public struct FileSystemPathPresence: PathPresence {
    public init() {}

    public func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// Which account a legacy Fermix service unit was installed for.
///
/// The scope decides both the sentence and the removal command, so it is read
/// rather than inferred: a system-scope unit needs administrator rights the app
/// does not take (M34 §15.2).
public enum LegacyServiceScope: String, CaseIterable, Sendable {
    case user
    case system
}

/// The installation facts activation must refuse on before it mutates anything
/// (M34 §4, §15.2).
public protocol InstallationProbing {
    /// True only when the bundle sits under `/Applications` and is not running
    /// from an App Translocation mount, so the agent registration would pin a
    /// version-stable path.
    func isCanonicallyInstalled() -> Bool
    /// The scope of the legacy `io.tezra.fermix` unit on this Mac, or nil where
    /// there is none. Scope-complete: both the user LaunchAgent and the system
    /// LaunchDaemon path are checked, and the **system** scope wins when both
    /// exist, because that is the order the removal enforces (M34 §15.0 retires
    /// the system-scope install first, and `fermix migrate-to-app` refuses
    /// while one is present). Reporting the user scope first sent the operator
    /// to a verb that then refused, and bounced them between two refusals.
    func legacyServiceUnitScope() -> LegacyServiceScope?
    /// The copies of this bundle id that are actually installed on this Mac.
    ///
    /// More than one means the registration would pin whichever copy macOS
    /// happened to resolve, which is the `duplicateCopyPresent` refusal, and the
    /// paths are what the refusal names. LaunchServices remembers every url it
    /// has ever seen, so build outputs, staging caches and trashed bundles are
    /// filtered out here rather than counted: with the unified app sharing the
    /// pet's bundle id, an ordinary install beside `/Applications/FermixPet.app`
    /// was being refused by four ghosts (M34 §15.6).
    func installedCopies() -> [String]
}

extension InstallationProbing {
    /// How many copies are installed. Zero is one as far as this gate is
    /// concerned: the running app is the copy.
    public func installedCopyCount() -> Int {
        max(installedCopies().count, 1)
    }
}

public struct BundleInstallationProbe: InstallationProbing {
    /// The two legacy unit paths the migration recognizes, mirrored from
    /// `Fermix.CLI.Service` (`io.tezra.fermix`).
    public static let legacyUserUnitPath = "Library/LaunchAgents/io.tezra.fermix.plist"
    public static let legacySystemUnitPath = "/Library/LaunchDaemons/io.tezra.fermix.plist"

    private let bundlePath: String
    private let bundleIdentifier: String
    private let home: String
    /// The system-scope unit's path. A fixed location on a real Mac, injected
    /// so the order this probe answers in can be proven without writing into
    /// `/Library` (the one thing a test may never do).
    private let systemUnitPath: String

    /// - Parameter home: the account home to look for a user-scope unit under.
    ///   It has no default on purpose: `NSHomeDirectory()` honours a `HOME`
    ///   override and `BootstrapLocation.currentAccount()` deliberately does
    ///   not, so a defaulted probe could inspect a different account than the
    ///   bootstrap record names. One resolver for the account, passed in.
    public init(
        bundlePath: String = Bundle.main.bundlePath,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        home: String,
        systemUnitPath: String = BundleInstallationProbe.legacySystemUnitPath
    ) {
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.home = home
        self.systemUnitPath = systemUnitPath
    }

    public func isCanonicallyInstalled() -> Bool {
        let resolved = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path

        guard !resolved.contains("/AppTranslocation/") else { return false }

        return resolved.hasPrefix("/Applications/")
    }

    public func legacyServiceUnitScope() -> LegacyServiceScope? {
        // System first: it is the one the migration verb refuses on, so with
        // both present the user-scope answer sent the operator to a command
        // that would not run (M34 §15.0).
        if FileManager.default.fileExists(atPath: systemUnitPath) { return .system }

        let userUnit = URL(fileURLWithPath: home).appendingPathComponent(Self.legacyUserUnitPath).path
        return FileManager.default.fileExists(atPath: userUnit) ? .user : nil
    }

    /// The installed copies, in the order LaunchServices reports them.
    ///
    /// A url it remembers is not a copy: it keeps every bundle it has ever
    /// registered, including one that has since been deleted and one dragged to
    /// the Trash. Both are filtered on disk rather than trusted.
    public func installedCopies() -> [String] {
        guard !bundleIdentifier.isEmpty else { return [] }

        return NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: bundleIdentifier)
            .map { $0.resolvingSymlinksInPath() }
            .filter { Self.isInstalled($0) }
            .map(\.path)
    }

    /// Whether that url is a bundle a person could still launch: it exists, and
    /// it is not sitting in a Trash folder waiting to be emptied.
    static func isInstalled(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        return !url.pathComponents.contains(".Trash")
    }
}

/// Who is already answering on a Fermix home's management socket.
///
/// Distinct from `PathPresence`, which asks whether the socket file is there:
/// this asks the daemon behind it who it is, which is what separates an
/// app-managed home from one a standalone or a pre-management daemon owns
/// (M34 §15.2).
public enum DaemonIdentityAnswer: Equatable, Sendable {
    /// Nothing is listening on that home at all.
    case none
    /// A management daemon that reports this app's own distribution identity.
    case app
    /// A management daemon from another distribution, named by what it reported.
    case foreign(String)
    /// Something answered and did not speak management v1, which is the
    /// pre-management (0.9.x) daemon (M34 §15.2): an answer arrived and did not
    /// decode.
    case preManagement
    /// Something is behind the socket and did not answer at all. A management
    /// daemon mid-restart, one that crashed after accept, or one that stalled.
    /// It is not an older daemon, and telling its owner to run the upgrade
    /// commands would be a wrong diagnosis and, on a DMG install with no
    /// Homebrew, a dead end.
    case unresponsive
    /// A management daemon answered `hello` in management's own vocabulary and
    /// the answer was not an identity: a structured `error`, a window with no
    /// intersection, or a refusal of the request itself. It speaks management,
    /// so it is not the pre-management daemon; it answered, so it is not
    /// unresponsive. Carries the daemon's own sentence, which is the only thing
    /// that can say which of those it was.
    case refusedIdentity(String)
}

public protocol DaemonIdentityProbing: Sendable {
    /// Throws where the probe could not be made at all, which is a broken app
    /// rather than an answer about the home.
    func identify(home: URL) async throws -> DaemonIdentityAnswer
}

/// The shipped probe: one `hello` on that home's `daemon.sock`, and nothing
/// else. It sends no other method and writes nothing.
public struct ManagementDaemonIdentityProbe: DaemonIdentityProbing {
    /// The distribution identity an app-managed engine reports.
    public static let appDistribution = EngineManifest.expectedDistribution

    public init() {}

    public func identify(home: URL) async throws -> DaemonIdentityAnswer {
        let record = BootstrapRecord(fermixHome: home)
        // A vendored contract this bundle cannot read is a broken app, not a
        // report that the home is quiet, so it is raised rather than answered.
        let client = try ManagementClient.connected(to: record)

        do {
            let hello = try await client.hello()
            let identity = hello.engine.distributionIdentity

            return identity == Self.appDistribution ? .app : .foreign(identity)
        } catch let failure as ManagementError {
            return Self.classify(failure)
        }
    }

    /// Four answers, keyed on what actually happened (M34 §15.2).
    ///
    /// The pre-management daemon is the one that **answered** and whose answer
    /// did not decode as management v1, so only the decode-class failures earn
    /// it: a malformed envelope, a mismatched correlation, and a frame that is
    /// not a frame. A daemon that answers in management's own vocabulary — a
    /// structured `error`, an empty version intersection, a refusal of the
    /// request — is a management daemon whose identity this app could not read,
    /// and folding it onto `preManagement` told its owner to run `brew upgrade
    /// fermix` against a daemon that is already newer than that.
    ///
    /// Everything that reached no peer is `none`, and everything that reached a
    /// peer which then said nothing is `unresponsive`. There is no `default`
    /// here on purpose — a failure kind added later has to be classified rather
    /// than falling open into "nothing is listening", which would activate onto
    /// another daemon's home.
    static func classify(_ failure: ManagementError) -> DaemonIdentityAnswer {
        switch failure {
        case .transport(let transport):
            return classify(transport)
        case .malformedEnvelope, .correlationMismatch:
            return .preManagement
        case .daemon, .incompatibleProtocol, .requestTooLarge, .invalidParameter,
             .invalidRequestIdentifier, .notNegotiated, .methodRequiresNewerEngine:
            return .refusedIdentity(ManagementMessage.sentence(for: failure))
        }
    }

    private static func classify(_ transport: ManagementTransportFailure) -> DaemonIdentityAnswer {
        switch transport {
        case .socketMissing, .daemonNotListening, .connectFailed, .socketPathTooLong, .invalidTimeout:
            return .none
        case .shortFrame, .frameTooLarge, .emptyFrame:
            return .preManagement
        case .writeFailed, .readFailed, .pollFailed, .peerClosedBeforeResponse, .timedOut:
            return .unresponsive
        }
    }
}

/// `GET <origin>/health/live` with a short deadline.
///
/// Liveness is a question about right now, so every way of not answering — a
/// refused connection, a timeout, a non-200 — is the same no. The caller polls,
/// and the bound is what turns a run of no answers into a failure that names
/// the origin it asked.
public struct HTTPWebLiveness: WebLiveness {
    public static let path = "/health/live"
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2) {
        self.timeout = timeout
    }

    public func isLive(origin: String) async -> Bool {
        guard let url = URL(string: origin + Self.path) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false

        guard let (_, response) = try? await URLSession(configuration: configuration).data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }

        return http.statusCode == 200
    }
}

public struct TaskSleeper: Sleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// How long a lifecycle step waits, and how often it looks.
///
/// Every wait is bounded and every bound is named: a step that runs out reports
/// what it was watching rather than hanging.
public struct PollingPolicy: Equatable, Sendable {
    public let interval: TimeInterval
    public let attempts: Int

    public init(interval: TimeInterval, attempts: Int) {
        precondition(interval > 0, "a poll needs an interval")
        precondition(attempts > 0, "a poll needs at least one attempt")

        self.interval = interval
        self.attempts = attempts
    }

    public var budget: TimeInterval { interval * Double(attempts) }
}

public enum LifecyclePolicy {
    /// M34 §5 gives activation 90 seconds to reach a failure state, and the
    /// socket is the first thing that has to appear inside it.
    public static let socketPolling = PollingPolicy(interval: 0.25, attempts: 240)
    /// A drained daemon exits promptly; 15 seconds is a stall, not a slow exit.
    public static let exitPolling = PollingPolicy(interval: 0.25, attempts: 60)
    /// launchd relaunches a KeepAlive job within seconds.
    public static let relaunchPolling = PollingPolicy(interval: 0.5, attempts: 60)
    /// The web surface comes up after the socket, inside the same 90 seconds.
    public static let webPolling = PollingPolicy(interval: 0.5, attempts: 60)
}
