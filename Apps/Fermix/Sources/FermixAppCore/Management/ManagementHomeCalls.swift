import Foundation

/// The `home.*` calls this app makes over `daemon.sock` (M75, Always On setup
/// §3.5): what each sends, the client's one line over `send` per method, and
/// the gateway's negotiated delegate.
///
/// Every one is minimum version 2 and arrived inside protocol 2, so a surface
/// finds them in `hello.capabilities.methods` before it draws anything that
/// calls one (`DaemonQuerying.servedMethods`). The server's own steps
/// (`home.move.readiness`, `home.move.start`, `home.enroll.open`,
/// `home.enroll.withdraw`, `home.snapshots.run`) are rail-only: the socket
/// refuses them, and `home.act` takes each step instead, so the app never
/// sends one.

// MARK: - What a call sends

/// The recovery passphrase, sent once and never kept.
struct ManagementRecoveryPassphraseParams: Encodable {
    let recoveryPassphrase: String

    private enum CodingKeys: String, CodingKey {
        case recoveryPassphrase = "recovery_passphrase"
    }
}

/// One Always On step: the action's id, the key it was drawn with, and what
/// its `needs` collected, sent only when there is something.
struct ManagementHomeActParams: Encodable {
    let action: String
    let key: String
    let input: ManagementHomeActInput?
}

// MARK: - The client

extension ManagementClient {
    public func homeStatus() async throws -> ManagementHomeStatus {
        try await send(.homeStatus, params: ManagementEmptyParams(), as: ManagementHomeStatus.self)
    }

    public func candidates() async throws -> ManagementCandidates {
        try await send(.homeCandidatesList, params: ManagementEmptyParams(), as: ManagementCandidates.self)
    }

    public func snapshotsStatus() async throws -> ManagementHomeSnapshots {
        try await send(.homeSnapshotsStatus, params: ManagementEmptyParams(), as: ManagementHomeSnapshots.self)
    }

    /// Sets the recovery key from the passphrase. A blank one is refused
    /// here; the daemon owns every other rule about it.
    public func setRecoveryPassphrase(_ passphrase: String) async throws -> ManagementRecoveryKey {
        try await send(
            .homeSnapshotsPassphrase,
            params: ManagementRecoveryPassphraseParams(
                recoveryPassphrase: try requireText(passphrase, field: "recovery_passphrase")
            ),
            as: ManagementRecoveryKey.self
        )
    }

    /// One Always On step, as the summary offered it: the engine checks the
    /// key against the summary as it is now, runs every call behind the step
    /// and answers the summary after it. The two actions the app opens itself
    /// are never sent.
    public func homeAct(
        _ action: ManagementHomeActionId,
        key: String,
        input: ManagementHomeActInput? = nil
    ) async throws -> ManagementHomeActed {
        guard action.isPublished, !action.isOpenedHere else {
            throw ManagementError.invalidParameter(.outOfRange(field: "action"))
        }

        return try await send(
            .homeAct,
            params: ManagementHomeActParams(
                action: action.wireValue,
                key: try requireText(key, field: "key"),
                input: input
            ),
            as: ManagementHomeActed.self
        )
    }
}

// MARK: - The gateway

extension ManagementGateway {
    public func homeStatus() async throws -> ManagementHomeStatus {
        try await negotiated().homeStatus()
    }

    public func candidates() async throws -> ManagementCandidates {
        try await negotiated().candidates()
    }

    public func snapshotsStatus() async throws -> ManagementHomeSnapshots {
        try await negotiated().snapshotsStatus()
    }

    public func setRecoveryPassphrase(_ passphrase: String) async throws -> ManagementRecoveryKey {
        try await negotiated().setRecoveryPassphrase(passphrase)
    }

    public func homeAct(
        _ action: ManagementHomeActionId,
        key: String,
        input: ManagementHomeActInput?
    ) async throws -> ManagementHomeActed {
        try await negotiated().homeAct(action, key: key, input: input)
    }
}
