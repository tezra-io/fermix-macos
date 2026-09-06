import Foundation

/// The socket seam.
///
/// One request, one response, then the daemon closes: there is no reader loop,
/// no reconnect, and no retry through the historical unversioned protocol. The
/// deadline travels with the call so exactly one component owns it.
public protocol ManagementTransport: Sendable {
    func exchange(_ payload: Data, timeout: Duration) async throws -> Data
}

/// The clock seam. Used where the daemon answers with a *relative* value the
/// client has to anchor itself, which is the drain lease's `ttl_ms`.
public protocol ManagementClock: Sendable {
    var now: Date { get }
}

public struct SystemManagementClock: ManagementClock {
    public init() {}

    public var now: Date { Date() }
}

/// How long one exchange may take, by method.
public protocol ManagementTimeoutPolicy: Sendable {
    func timeout(for method: ManagementMethod) -> Duration
}

public struct DefaultManagementTimeoutPolicy: ManagementTimeoutPolicy {
    /// Every method answers immediately by design — `doctor.start` returns a
    /// session id rather than holding the request open, long operations are
    /// jobs, and log pages are bounded — so a request still outstanding after
    /// this has not been answered at all. It is also the job-polling budget:
    /// one `job.get` per interval, each bounded by this.
    public static let standard: Duration = .seconds(10)
    /// `lifecycle.commit` runs the daemon's shutdown path and answers before
    /// the VM stops, so it is the one call whose work is not bounded by a
    /// bounded query.
    public static let lifecycleCommit: Duration = .seconds(30)
    /// The two writes that persist `config.toml`. M34 §7.4 budgets
    /// `settings.apply` at 15 s and `secret.set` at 20 s inside the daemon;
    /// this is that budget plus the round trip, so the client never gives up on
    /// a write the daemon is still allowed to be finishing.
    public static let write: Duration = .seconds(20)

    public init() {}

    public func timeout(for method: ManagementMethod) -> Duration {
        switch method {
        case .lifecycleCommit:
            return Self.lifecycleCommit
        case .settingsApply, .secretSet:
            return Self.write
        default:
            return Self.standard
        }
    }
}
