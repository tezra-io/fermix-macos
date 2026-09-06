import Foundation

/// Everything the surfaces ask the daemon.
///
/// The surfaces depend on this and never on `ManagementClient`, which is what
/// keeps the daemon logic on the daemon side of the socket: nothing above this
/// line parses a config file, reads a log file, or decides what a check means.
///
/// A method whose minimum protocol version the negotiated session does not
/// reach throws `ManagementError.methodRequiresNewerEngine`. That is a state the
/// surfaces render, not an error they report: against a daemon one release
/// behind, everything at minimum 1 keeps working and the restart that fixes the
/// rest is itself one of those calls.
public protocol DaemonQuerying: Sendable {
    /// Establishes the daemon's protocol window. Every other method is refused
    /// until it has answered.
    func negotiate() async throws -> ManagementHello
    /// Forgets the negotiated window and the connection it was learned on.
    ///
    /// A restart replaces the daemon behind the socket, and its protocol window
    /// is a property of that daemon: after an upgrade the cached window is the
    /// one that refused every v2 method, so the next call has to learn the new
    /// one rather than being gated against the old (M34 §7.2).
    func invalidateNegotiation() async
    func overview() async throws -> ManagementOverview
    func startDoctor(scope: ManagementDoctorScope) async throws -> ManagementDoctorSession
    func doctorSession(id: String) async throws -> ManagementDoctorSession
    func cancelDoctorSession(id: String) async throws -> ManagementDoctorSession
    func queryLogs(_ query: ManagementLogsQuery) async throws -> ManagementLogPage
    func buildDiagnostics() async throws -> ManagementDiagnostics

    // Protocol v2 (M34 §7.3).
    func setupState() async throws -> ManagementSetupState
    func detect(_ targets: [ManagementDetectTarget]) async throws -> ManagementDetections
    func settingsSections() async throws -> ManagementSettingsInventory
    func settings(section: String) async throws -> ManagementSettingsSectionRows
    func applySettings(
        section: String,
        values: [String: ManagementSettingValue]
    ) async throws -> ManagementSettingsApplied
    func reloadSettings() async throws -> ManagementSettingsReloaded
    func setSecret(id: String, value: String) async throws -> ManagementSecretState
    func clearSecret(id: String) async throws -> ManagementSecretState
    func setPrimaryProvider(_ provider: String) async throws -> ManagementPrimaryProviderResult
    func providerModels(
        provider: String,
        live: Bool,
        query: String?,
        cursor: String?,
        limit: Int?
    ) async throws -> ManagementProviderModels
    func startProviderProbe(provider: String) async throws -> ManagementJob
    func job(id: String) async throws -> ManagementJob
    func cancelJob(id: String) async throws -> ManagementJob
    func jobs() async throws -> ManagementJobList
    func startAuth(provider: String) async throws -> ManagementAuthStart
    func startAuthImport(source: ManagementAuthImportSource) async throws -> ManagementJob
    func logOut(provider: String) async throws -> ManagementRestartOnly
    func plugins() async throws -> ManagementPluginCatalog
    func startPluginInstall(name: String) async throws -> ManagementJob
    func startPluginCheck(name: String) async throws -> ManagementJob
    func startWorkspaceDiscovery(name: String) async throws -> ManagementJob
    func startWorkspaceSelection(
        name: String,
        profile: String,
        workspaceId: String,
        label: String
    ) async throws -> ManagementJob
    func enablePlugin(name: String) async throws -> ManagementPluginRow
    func disablePlugin(name: String) async throws -> ManagementPluginRow
    func disconnectPlugin(name: String) async throws -> ManagementPluginRow
    func setOAuthClient(
        provider: String,
        clientId: String,
        redirectPort: Int?
    ) async throws -> ManagementPluginOAuthClientRow
    func setPluginSetting(
        name: String,
        key: String,
        value: ManagementSettingValue
    ) async throws -> ManagementPluginRow
    func startCapabilityInstall(target: ManagementCapabilityTarget) async throws -> ManagementJob
    func startMeetingsSignIn() async throws -> ManagementJob
    func startComputerUseGrant() async throws -> ManagementJob
    func computerUsePermissions() async throws -> ManagementComputerUsePermissions
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

    /// Drops both the window and the client, so the next call dials the daemon
    /// that is there now and learns its window from it.
    public func invalidateNegotiation() {
        negotiatedHello = nil
        client = nil
    }

    public func overview() async throws -> ManagementOverview {
        try await negotiated().overview()
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

    func negotiated() async throws -> ManagementClient {
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
            return daemonSentence(failure)
        case .transport(.socketMissing), .transport(.daemonNotListening):
            return ProductStrings[.daemonStateNotRunning]
        case .incompatibleProtocol, .notNegotiated:
            return ProductStrings[.daemonErrorIncompatible]
        // Not an error the operator can act on by retrying: the engine in the
        // bundle already serves this method, and the restart applies it.
        case .methodRequiresNewerEngine:
            return ProductStrings[.daemonErrorRequiresNewerEngine]
        // The daemon answered, and the shape it answered with is not the one the
        // vendored contract publishes. That is drift between this bundle and the
        // engine it is talking to, not an outage, and saying "could not be
        // reached" of a daemon that just replied sends every reader to the wrong
        // half of the system.
        case .malformedEnvelope, .correlationMismatch:
            return ProductStrings[.daemonErrorUnexpectedShape]
        case .transport, .requestTooLarge, .invalidParameter, .invalidRequestIdentifier:
            return ProductStrings[.daemonErrorUnreachable]
        }
    }

    /// The daemon's own words for a structured refusal.
    ///
    /// `message` is fixed per code. Two codes cover a whole family of distinct
    /// refusals and carry the sentence that separates them in `details.sentence`
    /// — `invalid_params` (`This provider has no browser sign-in.`, `A secret
    /// cannot be empty.`, every settings validation) and `config_unreadable`
    /// (the parser's own line). For those, the detail sentence IS the message
    /// the operator has to read; everywhere else `message` already is.
    private static func daemonSentence(_ failure: ManagementFailure) -> String {
        switch failure.code {
        case .invalidParams, .configUnreadable:
            guard let sentence = failure.details.sentence, !sentence.isEmpty else {
                return failure.message
            }

            return sentence
        default:
            return failure.message
        }
    }

    /// Whether this failure is the designed N-1 state: the daemon is one
    /// release behind the bundle and the method needs the newer engine.
    ///
    /// The surfaces render it as a state with one action, never as an error and
    /// never as an empty pane (M34 §7.1).
    public static func requiresNewerEngine(_ error: any Error) -> Bool {
        guard case .methodRequiresNewerEngine? = error as? ManagementError else { return false }

        return true
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

    /// What went wrong, in the contract's own vocabulary, for a log line.
    ///
    /// Never shown to an operator: the sentence is what they read. This is what
    /// a support log needs and what the operator sentence deliberately does not
    /// carry — which method, which field, which code — because on a contract
    /// vendored from an uncommitted upstream tree, drift is the failure that
    /// reads as an outage and leaves nothing behind to say so.
    public static func diagnostic(for error: any Error) -> String {
        guard let management = error as? ManagementError else {
            return String(describing: error)
        }

        switch management {
        case .daemon(let failure):
            return "daemon \(failure.code.wireValue)"
                + (failure.details.field.map { " field \($0)" } ?? "")
        case .malformedEnvelope(.resultShapeMismatch(let method, let field)):
            return "\(method.rawValue) answered an unpublished shape at \(field)"
        case .malformedEnvelope(let defect):
            return "malformed envelope: \(defect)"
        case .correlationMismatch(let expected, let received):
            return "correlation mismatch: sent \(expected), got \(received ?? "none")"
        case .methodRequiresNewerEngine(let method, let required, let negotiated):
            return "\(method.rawValue) needs protocol \(required), negotiated \(negotiated)"
        case .notNegotiated(let method):
            return "\(method.rawValue) called before hello"
        case .incompatibleProtocol(let app, let daemon):
            return "no shared protocol: app \(app), daemon \(daemon.minimum)-\(daemon.maximum)"
        case .transport(let failure):
            return "transport: \(failure)"
        case .requestTooLarge(let byteCount, let limit):
            return "request of \(byteCount) bytes exceeds \(limit)"
        case .invalidParameter(let defect):
            return "invalid parameter: \(defect)"
        case .invalidRequestIdentifier(let identifier):
            return "invalid request id: \(identifier)"
        }
    }

    /// The details a daemon failure carried, where it carried any.
    public static func details(of error: any Error) -> ManagementErrorDetails? {
        guard case .daemon(let failure)? = error as? ManagementError else { return nil }

        return failure.details
    }

    /// The published error code a daemon failure carried, where it carried one.
    public static func code(of error: any Error) -> ManagementErrorCode? {
        guard case .daemon(let failure)? = error as? ManagementError else { return nil }

        return failure.code
    }
}
