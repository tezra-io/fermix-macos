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

/// Where this app is running from, and whether a Homebrew-era Fermix service
/// unit exists on this account — the two facts activation must refuse on
/// before it mutates anything (M34 §5: activation validates canonical
/// installation and migration first).
public protocol InstallationProbing {
    /// True only when the bundle sits under `/Applications` and is not running
    /// from an App Translocation mount, so the agent registration would pin a
    /// version-stable path.
    func isCanonicallyInstalled() -> Bool
    /// True when the legacy `io.tezra.fermix` LaunchAgent plist exists —
    /// a recognized Homebrew-managed install that `fermix migrate-to-app`
    /// owns moving.
    func legacyServiceUnitExists() -> Bool
}

public struct BundleInstallationProbe: InstallationProbing {
    /// The one legacy unit the migration recognizes, mirrored from
    /// `Fermix.CLI.Service` (`io.tezra.fermix`).
    public static let legacyUnitPath = "Library/LaunchAgents/io.tezra.fermix.plist"

    private let bundlePath: String
    private let home: String

    public init(
        bundlePath: String = Bundle.main.bundlePath,
        home: String = NSHomeDirectory()
    ) {
        self.bundlePath = bundlePath
        self.home = home
    }

    public func isCanonicallyInstalled() -> Bool {
        let resolved = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path

        guard !resolved.contains("/AppTranslocation/") else { return false }

        return resolved.hasPrefix("/Applications/")
    }

    public func legacyServiceUnitExists() -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: home).appendingPathComponent(Self.legacyUnitPath).path
        )
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
