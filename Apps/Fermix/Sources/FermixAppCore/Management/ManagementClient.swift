import Foundation

/// The typed client for the daemon's management socket.
///
/// It never retries through the historical unversioned protocol: every frame
/// carries both a request id and a declared version, which is exactly what
/// makes it unclassifiable as v0.
///
/// **The version is a window on both sides** (M34 §7.1). The app speaks the set
/// its contract publishes; `hello` reports the daemon's; the negotiated version
/// is the highest the two share and is stamped on every later request. Two
/// distinct refusals follow, and they mean opposite things: an empty
/// intersection is `incompatibleProtocol` and there is nothing to be done, while
/// a method whose minimum exceeds the negotiated version is
/// `methodRequiresNewerEngine` and the restart onto the bundled engine is
/// exactly what fixes it. That second case is why the client does not refuse
/// wholesale: against a daemon one release behind, `lifecycle.prepare` — the
/// call that performs the restart — must still go through.
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

    /// Every version this app can speak, ascending.
    public var speakableVersions: [Int] { contract.speakableVersions }

    /// The version stamped on requests: the highest both sides speak, once
    /// `hello` has answered, and the floor of the speakable set before that.
    public var declaredVersion: Int { negotiatedVersion ?? speakableFloor }

    // MARK: - Methods

    /// Learns the daemon's window and fixes the version every later request is
    /// stamped with.
    ///
    /// `hello` itself is stamped with the floor of the speakable set, because it
    /// is the one call made before the window is known and the floor is the
    /// version every daemon inside the supported window serves: a daemon
    /// publishing protocol `v` publishes the window `{max(1, v - 1), v}`, so a
    /// v1 and a v2 daemon both contain 1.
    public func hello() async throws -> ManagementHello {
        let hello: ManagementHello = try await send(
            .hello,
            params: ManagementEmptyParams(),
            as: ManagementHello.self
        )
        window = hello.protocolRange
        return hello
    }

    /// The highest version both sides speak, derived from the window `hello`
    /// reported rather than stored beside it, so the window is the one fact.
    private var negotiatedVersion: Int? {
        guard let window else { return nil }
        return ManagementNegotiation.highestShared(
            speakable: contract.speakableVersions,
            daemon: window
        )
    }

    private var speakableFloor: Int { contract.publishedRange.minimum }

    /// The version a request declares. `hello` always declares the floor, even
    /// after a window is known: it is the call that *learns* the window, and a
    /// client that stamped a negotiated version on it could not re-learn a
    /// window that changed underneath it — which is exactly what a daemon
    /// restarted onto a different engine does.
    private func protocolVersion(for method: ManagementMethod) -> Int {
        method == .hello ? speakableFloor : declaredVersion
    }

    public func overview() async throws -> ManagementOverview {
        try await send(.overviewGet, params: ManagementEmptyParams(), as: ManagementOverview.self)
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

    func send<Result: Decodable>(
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
                protocolVersion: protocolVersion(for: method),
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

    /// The M34 §7.1 ladder, applied to a live session. The two refusals live in
    /// `ManagementNegotiation` so the fixture gateway applies the same rule; what
    /// belongs to the client alone is that a window has to have been learned.
    private func checkNegotiation(for method: ManagementMethod) throws {
        guard method != .hello else { return }
        guard let window else { throw ManagementError.notNegotiated(method: method) }

        _ = try ManagementNegotiation.negotiate(
            method: method,
            contract: contract,
            daemon: window
        )
    }

    func requireText(_ value: String, field: String) throws -> String {
        guard !value.isEmpty else {
            throw ManagementError.invalidParameter(.empty(field: field))
        }
        return value
    }
}
