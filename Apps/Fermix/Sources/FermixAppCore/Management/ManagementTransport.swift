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
    /// session id rather than holding the request open, and log pages are
    /// bounded — so a request still outstanding after this has not been
    /// answered at all.
    public static let standard: Duration = .seconds(10)
    /// `lifecycle.commit` runs the daemon's shutdown path and answers before
    /// the VM stops, so it is the one call whose work is not bounded by a
    /// bounded query.
    public static let lifecycleCommit: Duration = .seconds(30)

    public init() {}

    public func timeout(for method: ManagementMethod) -> Duration {
        method == .lifecycleCommit ? Self.lifecycleCommit : Self.standard
    }
}
