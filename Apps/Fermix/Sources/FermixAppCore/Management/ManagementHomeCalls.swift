import Foundation

/// The `home.*` calls (M75 §14) and a desktop's executor switch: what each
/// sends, the client's one line over `send` per method, and the gateway's
/// negotiated delegate.
///
/// Every one is minimum version 2 and arrived inside protocol 2, so a surface
/// finds them in `hello.capabilities.methods` before it draws anything that
/// calls one (`DaemonQuerying.servedMethods`).

// MARK: - What a call sends

/// The recovery passphrase, sent once and never kept.
struct ManagementRecoveryPassphraseParams: Encodable {
    let recoveryPassphrase: String

    private enum CodingKeys: String, CodingKey {
        case recoveryPassphrase = "recovery_passphrase"
    }
}

/// The server to move to and the recovery passphrase, sent once and never
/// kept. `keepAsDesktop` is sent only as false, when the home that moves is a
/// server being replaced: the daemon's default keeps the source as a desktop.
struct ManagementMoveParams: Encodable {
    let candidateId: String
    let recoveryPassphrase: String
    let keepAsDesktop: Bool?

    private enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case recoveryPassphrase = "recovery_passphrase"
        case keepAsDesktop = "keep_as_desktop"
    }
}

/// The server a readiness report is about.
struct ManagementCandidateParams: Encodable {
    let candidateId: String

    private enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
    }
}

struct ManagementExecutorParams: Encodable {
    let deviceId: String
    let executor: Bool

    private enum CodingKeys: String, CodingKey {
        case executor
        case deviceId = "device_id"
    }
}

// MARK: - The client

extension ManagementClient {
    public func homeStatus() async throws -> ManagementHomeStatus {
        try await send(.homeStatus, params: ManagementEmptyParams(), as: ManagementHomeStatus.self)
    }

    /// Opens the one enrollment window and answers its code, once.
    public func openEnrollment() async throws -> ManagementEnrollmentCode {
        try await send(.homeEnrollOpen, params: ManagementEmptyParams(), as: ManagementEnrollmentCode.self)
    }

    public func candidates() async throws -> ManagementCandidates {
        try await send(.homeCandidatesList, params: ManagementEmptyParams(), as: ManagementCandidates.self)
    }

    /// What the owner reviews before moving to one server: each fact with
    /// its status and the daemon's sentence, and whether anything blocks.
    public func moveReadiness(candidateId: String) async throws -> ManagementMoveReadiness {
        try await send(
            .homeMoveReadiness,
            params: ManagementCandidateParams(candidateId: try requireText(candidateId, field: "candidate_id")),
            as: ManagementMoveReadiness.self
        )
    }

    /// Starts the move to one server. The engine answers, then restarts in
    /// the device role to carry it out. A server being replaced from a desktop
    /// moves with `keepAsDesktop` false, so it keeps nothing and serves
    /// nothing once the new one runs.
    public func startMove(
        candidateId: String,
        passphrase: String,
        keepAsDesktop: Bool = true
    ) async throws -> ManagementMoveStarted {
        try await send(
            .homeMoveStart,
            params: ManagementMoveParams(
                candidateId: try requireText(candidateId, field: "candidate_id"),
                recoveryPassphrase: try requireText(passphrase, field: "recovery_passphrase"),
                keepAsDesktop: keepAsDesktop ? nil : false
            ),
            as: ManagementMoveStarted.self
        )
    }

    public func snapshotsStatus() async throws -> ManagementHomeSnapshots {
        try await send(.homeSnapshotsStatus, params: ManagementEmptyParams(), as: ManagementHomeSnapshots.self)
    }

    public func runSnapshot() async throws -> ManagementSnapshotsStarted {
        try await send(.homeSnapshotsRun, params: ManagementEmptyParams(), as: ManagementSnapshotsStarted.self)
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

    public func setDeviceExecutor(id: String, executor: Bool) async throws -> ManagementMobileDevice {
        try await send(
            .mobileDevicesSetExecutor,
            params: ManagementExecutorParams(deviceId: try requireText(id, field: "device_id"), executor: executor),
            as: ManagementMobileDevice.self
        )
    }
}

// MARK: - The gateway

extension ManagementGateway {
    public func homeStatus() async throws -> ManagementHomeStatus {
        try await negotiated().homeStatus()
    }

    public func openEnrollment() async throws -> ManagementEnrollmentCode {
        try await negotiated().openEnrollment()
    }

    public func candidates() async throws -> ManagementCandidates {
        try await negotiated().candidates()
    }

    public func moveReadiness(candidateId: String) async throws -> ManagementMoveReadiness {
        try await negotiated().moveReadiness(candidateId: candidateId)
    }

    public func startMove(
        candidateId: String,
        passphrase: String,
        keepAsDesktop: Bool
    ) async throws -> ManagementMoveStarted {
        try await negotiated().startMove(candidateId: candidateId, passphrase: passphrase, keepAsDesktop: keepAsDesktop)
    }

    public func snapshotsStatus() async throws -> ManagementHomeSnapshots {
        try await negotiated().snapshotsStatus()
    }

    public func runSnapshot() async throws -> ManagementSnapshotsStarted {
        try await negotiated().runSnapshot()
    }

    public func setRecoveryPassphrase(_ passphrase: String) async throws -> ManagementRecoveryKey {
        try await negotiated().setRecoveryPassphrase(passphrase)
    }

    public func setDeviceExecutor(id: String, executor: Bool) async throws -> ManagementMobileDevice {
        try await negotiated().setDeviceExecutor(id: id, executor: executor)
    }
}
