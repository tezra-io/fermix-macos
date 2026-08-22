import Foundation

/// The typed client for the daemon's management socket.
///
/// It speaks protocol v1 only and never retries through the historical
/// unversioned protocol: every frame carries both a request id and a declared
/// version, which is exactly what makes it unclassifiable as v0.
///
/// `hello` is how the daemon's window is learned, so it is the one call allowed
/// before negotiation. Every later call is refused while the recorded window
/// excludes the version this app speaks, rather than being sent to a daemon
/// that has already said it cannot serve it.
public actor ManagementClient {
    private let transport: ManagementTransport
    private let contract: ManagementContract
    private let clock: ManagementClock
    private let timeouts: ManagementTimeoutPolicy
    private let identifiers: ManagementRequestIdentifierGenerator
    private var window: ManagementProtocolRange?

    public init(
        transport: ManagementTransport,
        contract: ManagementContract,
        clock: ManagementClock = SystemManagementClock(),
        timeouts: ManagementTimeoutPolicy = DefaultManagementTimeoutPolicy(),
        identifiers: ManagementRequestIdentifierGenerator = UUIDRequestIdentifierGenerator()
    ) {
        self.transport = transport
        self.contract = contract
        self.clock = clock
        self.timeouts = timeouts
        self.identifiers = identifiers
    }

    /// A client for one Fermix home's `daemon.sock`, wired to the vendored
    /// contract.
    public static func connected(
        to record: BootstrapRecord,
        clock: ManagementClock = SystemManagementClock(),
        timeouts: ManagementTimeoutPolicy = DefaultManagementTimeoutPolicy()
    ) throws -> ManagementClient {
        let contract = try ManagementContract.vendored()
        return ManagementClient(
            transport: UnixSocketManagementTransport(
                socketPath: record.daemonSocketURL.path,
                limits: contract.limits
            ),
            contract: contract,
            clock: clock,
            timeouts: timeouts
        )
    }

    /// The window `hello` reported, once it has been negotiated.
    public var negotiatedRange: ManagementProtocolRange? { window }

    /// The version this app declares on every request.
    public var declaredVersion: Int { contract.protocolVersion }

    // MARK: - Methods

    public func hello() async throws -> ManagementHello {
        let hello: ManagementHello = try await send(
            .hello,
            params: ManagementEmptyParams(),
            as: ManagementHello.self
        )
        window = hello.protocolRange
        return hello
    }

    public func overview() async throws -> ManagementOverview {
        try await send(.overviewGet, params: ManagementEmptyParams(), as: ManagementOverview.self)
    }

    public func createSetupSession() async throws -> ManagementSetupSession {
        try await send(
            .setupSessionCreate,
            params: ManagementEmptyParams(),
            as: ManagementSetupSession.self
        )
    }

    /// Starts a Doctor run. An omitted scope takes the daemon's published
    /// default, which is `local`.
    public func startDoctor(
        scope: ManagementDoctorScope? = nil
    ) async throws -> ManagementDoctorSession {
        try await send(
            .doctorStart,
            params: ManagementDoctorStartParams(scope: scope),
            as: ManagementDoctorSession.self
        )
    }

    public func doctorSession(id: String) async throws -> ManagementDoctorSession {
        try await send(
            .doctorGet,
            params: ManagementSessionParams(sessionId: try requireText(id, field: "session_id")),
            as: ManagementDoctorSession.self
        )
    }

    public func cancelDoctorSession(id: String) async throws -> ManagementDoctorSession {
        try await send(
            .doctorCancel,
            params: ManagementSessionParams(sessionId: try requireText(id, field: "session_id")),
            as: ManagementDoctorSession.self
        )
    }

    public func queryLogs(_ query: ManagementLogsQuery) async throws -> ManagementLogPage {
        try await send(
            .logsQuery,
            params: ManagementLogsQueryParams(query: try query.validated()),
            as: ManagementLogPage.self
        )
    }

    public func prepareLifecycle() async throws -> ManagementLifecycleLease {
        let prepared: ManagementLifecyclePrepared = try await send(
            .lifecyclePrepare,
            params: ManagementEmptyParams(),
            as: ManagementLifecyclePrepared.self
        )
        return ManagementLifecycleLease(
            leaseId: prepared.leaseId,
            ttlMs: prepared.ttlMs,
            expiresAt: clock.now.addingTimeInterval(Double(prepared.ttlMs) / 1000)
        )
    }

    public func commitLifecycle(leaseId: String) async throws -> ManagementLifecycleTransition {
        try await send(
            .lifecycleCommit,
            params: ManagementLeaseParams(leaseId: try requireText(leaseId, field: "lease_id")),
            as: ManagementLifecycleTransition.self
        )
    }

    public func cancelLifecycle(leaseId: String) async throws -> ManagementLifecycleTransition {
        try await send(
            .lifecycleCancel,
            params: ManagementLeaseParams(leaseId: try requireText(leaseId, field: "lease_id")),
            as: ManagementLifecycleTransition.self
        )
    }

    public func buildDiagnostics() async throws -> ManagementDiagnostics {
        try await send(
            .diagnosticsBuild,
            params: ManagementEmptyParams(),
            as: ManagementDiagnostics.self
        )
    }

    // MARK: - One exchange

    private func send<Result: Decodable>(
        _ method: ManagementMethod,
        params: some Encodable,
        as type: Result.Type
    ) async throws -> Result {
        try checkNegotiation(for: method)

        let identifier = identifiers.nextIdentifier(for: method)
        guard ManagementRequestIdentifier.isValid(identifier) else {
            throw ManagementError.invalidRequestIdentifier(identifier)
        }

        let payload = try encode(identifier: identifier, method: method, params: params)
        let response: Data
        do {
            response = try await transport.exchange(payload, timeout: timeouts.timeout(for: method))
        } catch let failure as ManagementTransportFailure {
            throw ManagementError.transport(failure)
        }

        return try ManagementResponse.decode(
            response,
            expecting: identifier,
            method: method,
            as: Result.self
        )
    }

    private func encode(
        identifier: String,
        method: ManagementMethod,
        params: some Encodable
    ) throws -> Data {
        let encoder = JSONEncoder()
        let encodedParams = try encoder.encode(params)
        guard encodedParams.count <= contract.limits.maxParamsBytes else {
            throw ManagementError.invalidParameter(
                .encodedParamsTooLarge(
                    byteCount: encodedParams.count,
                    limit: contract.limits.maxParamsBytes
                )
            )
        }

        let payload = try encoder.encode(
            ManagementRequestEnvelope(
                requestId: identifier,
                protocolVersion: contract.protocolVersion,
                method: method.rawValue,
                params: params
            )
        )
        guard payload.count <= contract.limits.maxFrameBytes else {
            throw ManagementError.requestTooLarge(
                byteCount: payload.count,
                limit: contract.limits.maxFrameBytes
            )
        }
        return payload
    }

    private func checkNegotiation(for method: ManagementMethod) throws {
        guard method != .hello else { return }
        guard let window else { throw ManagementError.notNegotiated(method: method) }
        guard window.window.contains(contract.protocolVersion) else {
            throw ManagementError.unsupportedProtocolVersion(
                declared: contract.protocolVersion,
                minimum: window.minimum,
                maximum: window.maximum
            )
        }
    }

    private func requireText(_ value: String, field: String) throws -> String {
        guard !value.isEmpty else {
            throw ManagementError.invalidParameter(.empty(field: field))
        }
        return value
    }
}
