import Foundation

/// Who is behind the management socket right now.
public struct DaemonIdentity: Equatable, Sendable {
    public let pid: String
    public let setupOrigin: String
    public let productVersion: String

    public init(pid: String, setupOrigin: String, productVersion: String) {
        self.pid = pid
        self.setupOrigin = setupOrigin
        self.productVersion = productVersion
    }

    public var processIdentifier: Int32? { Int32(pid) }
}

/// The daemon operations a lifecycle transaction needs, as a seam: negotiate,
/// take a drain lease, and either commit or cancel it.
public protocol DaemonControlPlane {
    func hello() async throws -> DaemonIdentity
    func prepare() async throws -> ManagementLifecycleLease
    func commit(leaseId: String) async throws -> ManagementLifecycleOutcome
    func cancel(leaseId: String) async throws -> ManagementLifecycleOutcome
}

/// The production plane: one negotiated `ManagementClient` per transaction.
public struct ManagementControlPlane: DaemonControlPlane {
    private let client: ManagementClient

    public init(client: ManagementClient) {
        self.client = client
    }

    public func hello() async throws -> DaemonIdentity {
        let hello = try await client.hello()
        return DaemonIdentity(
            pid: hello.engine.pid,
            setupOrigin: hello.setup.origin,
            productVersion: hello.engine.productVersion
        )
    }

    public func prepare() async throws -> ManagementLifecycleLease {
        try await client.prepareLifecycle()
    }

    public func commit(leaseId: String) async throws -> ManagementLifecycleOutcome {
        try await client.commitLifecycle(leaseId: leaseId).status
    }

    public func cancel(leaseId: String) async throws -> ManagementLifecycleOutcome {
        try await client.cancelLifecycle(leaseId: leaseId).status
    }
}

/// What a completed transaction did.
public enum LifecycleOutcome: Equatable, Sendable {
    case enabled(pid: Int32)
    case disabled
    case restarted(previousPid: Int32, currentPid: Int32)
}

/// Why a transaction did not complete. Every case names what was inspected.
public enum LifecycleFailure: Error, Equatable, Sendable {
    case bootstrapMissing
    case registration(ServiceControlError)
    case socketNeverAppeared(path: String)
    /// The daemon exited but its socket node is still on disk. The opposite
    /// failure from the one above, and a reader told the wrong one goes looking
    /// for a daemon that never started.
    case socketNeverReleased(path: String)
    case webNeverAnswered(origin: String)
    case daemonNeverExited(pid: Int32)
    /// launchd never brought a different daemon back.
    case daemonNeverReturned
    /// The daemon is mid-turn. Nothing was changed, so this is safe to retry.
    case deferredWhileBusy(message: String)
    case negotiationFailed(ManagementError)
    case daemonIdentityUnreadable(pid: String)
    case journalUnavailable(LifecycleJournalError)
    /// An earlier transaction was interrupted and its record has not been
    /// resolved. Transactions are serialized, so a second one starting over
    /// that record would destroy the only evidence of what stopped.
    case recoveryPending(kind: LifecycleTransactionKind, phase: LifecyclePhase)
    /// launchd does not own this daemon, so a restart would drain it and
    /// nothing would bring it back. Refused before any mutation, which is why
    /// it carries the registration status that was read rather than a report of
    /// what a half-run transaction left behind.
    case daemonNotManaged(ServiceRegistrationStatus)

    /// The one sentence a surface shows for this failure, where this build has
    /// copy for it.
    ///
    /// Only the preflight refusal has one. Every other case is a step that
    /// stopped part-way, which the journal records and Recovery reads; inventing
    /// a sentence per case here would put copy on states no screen renders.
    public var sentence: String? {
        guard case .daemonNotManaged = self else { return nil }

        return ProductStrings[.lifecycleDaemonNotManaged]
    }
}

/// The three lifecycle transactions, as M34 §4 defines them.
///
/// Each is preflight, prepare, mutate, verify, then clear, and each step is
/// journaled so an interruption leaves a record recovery can read. The
/// registration is the durable state: a failed mutation rolls the drain back
/// and leaves the service exactly as it was.
public protocol DaemonLifecycleControlling {
    func enableBackgroundService() async throws -> LifecycleOutcome
    func disableBackgroundService() async throws -> LifecycleOutcome
    func restartDaemon() async throws -> LifecycleOutcome
    /// The record an interrupted transaction left behind, and the acknowledgement
    /// that resolves it.
    func interruptedTransaction() throws -> LifecycleJournalEntry?
    func discardInterruptedTransaction() throws
}

public struct LifecycleCoordinator: DaemonLifecycleControlling {
    private let store: BootstrapStore
    private let journal: LifecycleJournal
    private let services: ServiceController
    /// The one owner of the registration-receipt comparison (M34 §7.2 step 5).
    private let reconciler: EngineReconciler
    private let makePlane: (BootstrapRecord) throws -> any DaemonControlPlane
    private let processes: any ProcessLiveness
    private let paths: any PathPresence
    private let web: any WebLiveness
    private let sleeper: any Sleeping
    private let log = AppLog.logger(.lifecycle)

    public init(
        store: BootstrapStore,
        journal: LifecycleJournal,
        services: ServiceController,
        reconciler: EngineReconciler,
        plane: @escaping (BootstrapRecord) throws -> any DaemonControlPlane,
        processes: any ProcessLiveness,
        paths: any PathPresence,
        web: any WebLiveness,
        sleeper: any Sleeping
    ) {
        self.store = store
        self.journal = journal
        self.services = services
        self.reconciler = reconciler
        self.makePlane = plane
        self.processes = processes
        self.paths = paths
        self.web = web
        self.sleeper = sleeper
    }

    // MARK: - Enable

    /// Validate the bootstrap, register the agent, wait for the socket,
    /// negotiate, then verify the local web surface answers.
    public func enableBackgroundService() async throws -> LifecycleOutcome {
        let record = try loadBootstrap()
        var entry = try begin(.enable, registration: services.status(.agent))

        do {
            try advance(&entry, to: .mutate)
            try register()

            try advance(&entry, to: .verify)
            try await waitForSocket(at: record.daemonSocketURL.path)
            let identity = try await negotiate(record)
            entry = try note(identity, in: entry)
            try await waitForWeb(origin: identity.setupOrigin)

            let pid = try processIdentifier(identity)
            try journal.clear()
            recordRegistrationReceipt()
            return .enabled(pid: pid)
        } catch {
            log.error("enable failed at \(entry.phase.rawValue, privacy: .public)")
            throw error
        }
    }

    // MARK: - Disable

    /// Prepare a drain, unregister, commit the shutdown, then prove the daemon
    /// that was running is gone. A failed unregister cancels the drain and
    /// leaves the service enabled: registration is the durable state.
    public func disableBackgroundService() async throws -> LifecycleOutcome {
        let record = try loadBootstrap()
        let previous = services.status(.agent)
        var entry = try begin(.disable, registration: previous)

        guard let reachable = try await reachablePlane(record) else {
            // The daemon is not running, so there is nothing to drain. The
            // registration is still the durable state, and removing it is the
            // whole of the transaction.
            try advance(&entry, to: .mutate)
            try unregister()
            try journal.clear()
            return .disabled
        }

        let plane = reachable.plane
        entry = try note(reachable.identity, in: entry)
        let pid = try processIdentifier(reachable.identity)

        try advance(&entry, to: .prepare)
        let lease = try await prepare(plane)

        try advance(&entry, to: .mutate)
        do {
            try unregister()
        } catch {
            await cancelDrain(plane, lease: lease)
            throw error
        }

        if processes.isRunning(pid: pid) {
            _ = try await commit(plane, lease: lease)
        }

        try advance(&entry, to: .verify)
        try await waitForExit(pid: pid)
        try await waitForSocketRelease(at: record.daemonSocketURL.path)

        try journal.clear()
        return .disabled
    }

    // MARK: - Restart

    /// Refuse unless launchd owns this daemon, then prepare and commit a
    /// shutdown, renew the agent registration where this bundle ships a
    /// different plist than the one that was registered, and wait for launchd to
    /// bring a *different* daemon back and prove it.
    public func restartDaemon() async throws -> LifecycleOutcome {
        // Before anything is journaled or drained. launchd relaunches only a
        // daemon it owns, so on an unregistered agent the drain succeeds, the
        // daemon exits, and nothing starts it again: the operator's Fermix was
        // gone until the next login (owner report of 2026-09-04).
        let registration = services.status(.agent)
        guard registration == .enabled else {
            log.error(
                "refusing the restart: the agent registration is \(registration.rawValue, privacy: .public)"
            )
            throw LifecycleFailure.daemonNotManaged(registration)
        }

        let record = try loadBootstrap()
        var entry = try begin(.restart, registration: registration)

        let plane = try makePlane(record)
        let previous = try await plane.hello()
        entry = try note(previous, in: entry)
        let previousPid = try processIdentifier(previous)

        try advance(&entry, to: .prepare)
        let lease = try await prepare(plane)

        try advance(&entry, to: .mutate)
        if processes.isRunning(pid: previousPid) {
            _ = try await commit(plane, lease: lease)
        }

        try advance(&entry, to: .verify)
        try await waitForExit(pid: previousPid)
        try renewRegistration(recordedIn: record)
        let current = try await waitForRelaunch(plane, replacing: previous.pid)
        try await waitForWeb(origin: current.setupOrigin)

        try journal.clear()
        return .restarted(previousPid: previousPid, currentPid: try processIdentifier(current))
    }

    /// Unregisters and registers the agent when the bundled plist differs from
    /// the receipt the last registration wrote, or when no receipt exists
    /// (M34 §7.2 step 5), so a changed `ProgramArguments` or label is applied
    /// rather than silently ignored.
    ///
    /// It runs after the old daemon has exited and before launchd is waited on,
    /// which is the one moment where the registration can be replaced without
    /// interrupting the turn the drain exists to protect, and still governs the
    /// process that comes back.
    private func renewRegistration(recordedIn record: BootstrapRecord) throws {
        guard reconciler.registration(recordedIn: record) == .renew else { return }

        log.log("the bundled agent plist differs from the registered one")
        try unregister()
        try register()
        recordRegistrationReceipt()
    }

    /// Records which plist is now registered.
    ///
    /// Never fatal, and for the same reason activation's own receipt write is
    /// not: the reconciler reads an absent or unwritten receipt as a difference,
    /// so the next restart renews again rather than skipping. A bundle that
    /// ships no plist has no digest to record at all.
    private func recordRegistrationReceipt() {
        guard let digest = services.bundledAgentPlistDigest() else {
            log.error("this bundle ships no agent plist, so no receipt was recorded")
            return
        }

        do {
            try store.recordAgentRegistration(plistSHA256: digest)
        } catch {
            log.error("the registration receipt could not be written: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Steps

    private func loadBootstrap() throws -> BootstrapRecord {
        do {
            return try store.load()
        } catch {
            throw LifecycleFailure.bootstrapMissing
        }
    }

    private func register() throws {
        do {
            try services.enable(.agent)
        } catch let failure as ServiceControlError {
            throw LifecycleFailure.registration(failure)
        }
    }

    private func unregister() throws {
        do {
            try services.disable(.agent)
        } catch let failure as ServiceControlError {
            throw LifecycleFailure.registration(failure)
        }
    }

    private func negotiate(_ record: BootstrapRecord) async throws -> DaemonIdentity {
        do {
            return try await makePlane(record).hello()
        } catch let failure as ManagementError {
            throw LifecycleFailure.negotiationFailed(failure)
        }
    }

    /// The plane for a daemon that is actually there, and who answered. A
    /// socket nobody is listening on means there is nothing to drain, which is
    /// a different world from a daemon that refused.
    private func reachablePlane(
        _ record: BootstrapRecord
    ) async throws -> (plane: any DaemonControlPlane, identity: DaemonIdentity)? {
        let plane = try makePlane(record)
        do {
            return (plane, try await plane.hello())
        } catch ManagementError.transport(.socketMissing), ManagementError.transport(.daemonNotListening) {
            log.log("no daemon behind the management socket; disabling the registration only")
            return nil
        } catch let failure as ManagementError {
            throw LifecycleFailure.negotiationFailed(failure)
        }
    }

    private func prepare(_ plane: any DaemonControlPlane) async throws -> ManagementLifecycleLease {
        do {
            return try await plane.prepare()
        } catch ManagementError.daemon(let failure) where failure.code == .busy {
            throw LifecycleFailure.deferredWhileBusy(message: failure.message)
        } catch let failure as ManagementError {
            throw LifecycleFailure.negotiationFailed(failure)
        }
    }

    private func commit(
        _ plane: any DaemonControlPlane,
        lease: ManagementLifecycleLease
    ) async throws -> ManagementLifecycleOutcome {
        do {
            return try await plane.commit(leaseId: lease.leaseId)
        } catch let failure as ManagementError {
            throw LifecycleFailure.negotiationFailed(failure)
        }
    }

    /// Rolls the drain back after a failed mutation. The lease expires on its
    /// own if this never reaches the daemon, so the failure is reported and the
    /// original one is what the caller sees.
    private func cancelDrain(_ plane: any DaemonControlPlane, lease: ManagementLifecycleLease) async {
        do {
            _ = try await plane.cancel(leaseId: lease.leaseId)
            log.error("unregister failed, drain cancelled, service left enabled")
        } catch {
            log.error(
                "unregister failed, and the drain could not be cancelled either: \(String(describing: error), privacy: .public). The lease expires on its own."
            )
        }
    }

    private func processIdentifier(_ identity: DaemonIdentity) throws -> Int32 {
        guard let pid = identity.processIdentifier, pid > 0 else {
            throw LifecycleFailure.daemonIdentityUnreadable(pid: identity.pid)
        }
        return pid
    }

    // MARK: - Bounded waits

    private func waitForSocket(at path: String) async throws {
        try await poll(LifecyclePolicy.socketPolling, until: { paths.exists(atPath: path) })
            .orThrow(LifecycleFailure.socketNeverAppeared(path: path))
    }

    private func waitForSocketRelease(at path: String) async throws {
        try await poll(LifecyclePolicy.exitPolling, until: { !paths.exists(atPath: path) })
            .orThrow(LifecycleFailure.socketNeverReleased(path: path))
    }

    private func waitForExit(pid: Int32) async throws {
        try await poll(LifecyclePolicy.exitPolling, until: { !processes.isRunning(pid: pid) })
            .orThrow(LifecycleFailure.daemonNeverExited(pid: pid))
    }

    private func waitForWeb(origin: String) async throws {
        let policy = LifecyclePolicy.webPolling
        for attempt in 0..<policy.attempts {
            if await web.isLive(origin: origin) { return }
            if attempt + 1 < policy.attempts {
                try await sleeper.sleep(seconds: policy.interval)
            }
        }

        throw LifecycleFailure.webNeverAnswered(origin: origin)
    }

    /// Polls `hello` until a *different* daemon answers. The same pid answering
    /// again is not a restart: launchd may never have relaunched at all.
    private func waitForRelaunch(
        _ plane: any DaemonControlPlane,
        replacing previousPid: String
    ) async throws -> DaemonIdentity {
        let policy = LifecyclePolicy.relaunchPolling
        var lastFailure: (any Error)?

        for attempt in 0..<policy.attempts {
            do {
                let identity = try await plane.hello()
                if identity.pid != previousPid { return identity }
            } catch {
                // Expected while launchd is still bringing the daemon up; the
                // last one is reported if the whole budget runs out.
                lastFailure = error
            }
            if attempt + 1 < policy.attempts {
                try await sleeper.sleep(seconds: policy.interval)
            }
        }

        if let lastFailure {
            log.error("daemon never returned: \(String(describing: lastFailure), privacy: .public)")
        }
        throw LifecycleFailure.daemonNeverReturned
    }

    /// One bounded poll. Every wait in this file goes through it, so no loop
    /// can be written without a cap.
    private func poll(_ policy: PollingPolicy, until condition: () -> Bool) async throws -> Bool {
        for attempt in 0..<policy.attempts {
            if condition() { return true }
            if attempt + 1 < policy.attempts {
                try await sleeper.sleep(seconds: policy.interval)
            }
        }

        return false
    }

    // MARK: - Journal

    /// The record an interrupted transaction left behind, if there is one.
    ///
    /// This is what makes the journal a recovery record rather than a
    /// write-only file: the launch path reads it and opens Recovery instead of
    /// claiming everything is normal.
    public func interruptedTransaction() throws -> LifecycleJournalEntry? {
        do {
            return try journal.load()
        } catch let failure as LifecycleJournalError {
            throw LifecycleFailure.journalUnavailable(failure)
        }
    }

    /// Resolves the interrupted transaction: the user has acknowledged it, and
    /// the record has served its purpose. The daemon's own drain lease expires
    /// on its own, so nothing is left half-applied behind this.
    public func discardInterruptedTransaction() throws {
        do {
            try journal.clear()
        } catch let failure as LifecycleJournalError {
            throw LifecycleFailure.journalUnavailable(failure)
        }
    }

    private func begin(
        _ kind: LifecycleTransactionKind,
        registration: ServiceRegistrationStatus
    ) throws -> LifecycleJournalEntry {
        if let pending = try interruptedTransaction() {
            throw LifecycleFailure.recoveryPending(kind: pending.kind, phase: pending.phase)
        }

        let entry = LifecycleJournalEntry(
            transactionId: UUID(),
            kind: kind,
            phase: .preflight,
            originalPid: nil,
            previousRegistration: registration,
            startedAt: Date()
        )
        try write(entry)
        return entry
    }

    private func advance(_ entry: inout LifecycleJournalEntry, to phase: LifecyclePhase) throws {
        entry.phase = phase
        try write(entry)
    }

    /// Records who was running when the transaction started, so recovery can
    /// tell "it exited" from "a different one is running".
    private func note(
        _ identity: DaemonIdentity,
        in entry: LifecycleJournalEntry
    ) throws -> LifecycleJournalEntry {
        let updated = LifecycleJournalEntry(
            transactionId: entry.transactionId,
            kind: entry.kind,
            phase: entry.phase,
            originalPid: identity.processIdentifier,
            previousRegistration: entry.previousRegistration,
            startedAt: entry.startedAt
        )
        try write(updated)
        return updated
    }

    private func write(_ entry: LifecycleJournalEntry) throws {
        do {
            try journal.write(entry)
        } catch let failure as LifecycleJournalError {
            throw LifecycleFailure.journalUnavailable(failure)
        }
    }
}

private extension Bool {
    /// Turns an exhausted bounded wait into the failure that names what was
    /// being watched.
    func orThrow(_ failure: LifecycleFailure) throws {
        guard !self else { return }

        throw failure
    }
}
