import Foundation

/// Everything the five surfaces ask the daemon.
///
/// The surfaces depend on this and never on `ManagementClient`, which is what
/// keeps the daemon logic on the daemon side of the socket: nothing above this
/// line parses a config file, reads a log file, or decides what a check means.
public protocol DaemonQuerying: Sendable {
    /// Establishes the daemon's protocol window. Every other method is refused
    /// until it has answered.
    func negotiate() async throws -> ManagementHello
    func overview() async throws -> ManagementOverview
    func createSetupSession() async throws -> ManagementSetupSession
    func startDoctor(scope: ManagementDoctorScope) async throws -> ManagementDoctorSession
    func doctorSession(id: String) async throws -> ManagementDoctorSession
    func cancelDoctorSession(id: String) async throws -> ManagementDoctorSession
    func queryLogs(_ query: ManagementLogsQuery) async throws -> ManagementLogPage
    func buildDiagnostics() async throws -> ManagementDiagnostics
}

/// The production gateway: one negotiated client, shared by every surface.
///
/// Negotiation happens once and is remembered, because `hello` is how the
/// daemon's window is learned and re-asking it before each call would spend a
/// round trip to re-learn a fact that cannot change while the daemon lives. A
/// daemon that goes away answers a transport failure on the next call, which
/// is the truthful signal — not a reason to reconnect behind the surface's back.
public actor ManagementGateway: DaemonQuerying {
    private let makeClient: @Sendable () throws -> ManagementClient
    private var client: ManagementClient?
    private var negotiatedHello: ManagementHello?

    public init(makeClient: @escaping @Sendable () throws -> ManagementClient) {
        self.makeClient = makeClient
    }

    /// A gateway for one Fermix home's `daemon.sock`.
    public static func forHome(_ record: BootstrapRecord) -> ManagementGateway {
        ManagementGateway { try ManagementClient.connected(to: record) }
    }

    /// The window `hello` reported, once it has been negotiated.
    public var window: ManagementProtocolRange? {
        negotiatedHello?.protocolRange
    }

    public func negotiate() async throws -> ManagementHello {
        let hello = try await resolvedClient().hello()
        negotiatedHello = hello
        return hello
    }

    public func overview() async throws -> ManagementOverview {
        try await negotiated().overview()
    }

    public func createSetupSession() async throws -> ManagementSetupSession {
        try await negotiated().createSetupSession()
    }

    public func startDoctor(scope: ManagementDoctorScope) async throws -> ManagementDoctorSession {
        try await negotiated().startDoctor(scope: scope)
    }

    public func doctorSession(id: String) async throws -> ManagementDoctorSession {
        try await negotiated().doctorSession(id: id)
    }

    public func cancelDoctorSession(id: String) async throws -> ManagementDoctorSession {
        try await negotiated().cancelDoctorSession(id: id)
    }

    public func queryLogs(_ query: ManagementLogsQuery) async throws -> ManagementLogPage {
        try await negotiated().queryLogs(query)
    }

    public func buildDiagnostics() async throws -> ManagementDiagnostics {
        try await negotiated().buildDiagnostics()
    }

    // MARK: - One client, negotiated once

    private func negotiated() async throws -> ManagementClient {
        let client = try resolvedClient()
        guard negotiatedHello == nil else { return client }

        negotiatedHello = try await client.hello()
        return client
    }

    private func resolvedClient() throws -> ManagementClient {
        if let client { return client }

        let created = try makeClient()
        client = created
        return created
    }
}

/// The operator-facing sentence for a management failure.
///
/// A daemon error carries the engine's own words, which is what M34 requires:
/// the app renders what the engine said rather than paraphrasing it. Everything
/// else is a fact about this side of the socket, and gets one sentence of copy.
public enum ManagementMessage {
    public static func sentence(for error: any Error) -> String {
        guard let management = error as? ManagementError else {
            return ProductStrings[.daemonErrorUnreachable]
        }

        switch management {
        case .daemon(let failure):
            return failure.message
        case .transport(.socketMissing), .transport(.daemonNotListening):
            return ProductStrings[.daemonErrorNotRunning]
        case .unsupportedProtocolVersion, .notNegotiated:
            return ProductStrings[.daemonErrorIncompatible]
        case .transport, .correlationMismatch, .malformedEnvelope, .requestTooLarge,
             .invalidParameter, .invalidRequestIdentifier:
            return ProductStrings[.daemonErrorUnreachable]
        }
    }

    /// Whether this failure means the daemon is simply not there, which the
    /// surfaces render as a state rather than as an error.
    public static func isUnreachable(_ error: any Error) -> Bool {
        guard case .transport(let failure)? = error as? ManagementError else { return false }

        switch failure {
        case .socketMissing, .daemonNotListening, .connectFailed, .peerClosedBeforeResponse:
            return true
        default:
            return false
        }
    }

    /// The published error code a daemon failure carried, where it carried one.
    public static func code(of error: any Error) -> ManagementErrorCode? {
        guard case .daemon(let failure)? = error as? ManagementError else { return nil }

        return failure.code
    }
}
