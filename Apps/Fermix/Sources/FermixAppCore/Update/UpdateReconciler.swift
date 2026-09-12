import Foundation

/// What the management socket answered the one time the reconcile asked.
public enum UpdateEngineAnswer: Equatable, Sendable {
    /// A daemon answered and this app can read it.
    case answered(ManagementHello)
    /// A daemon answered and shares no protocol version with this app, so no
    /// management operation can reach it, the restart included.
    case noSharedProtocol
    /// Nothing answered, or what answered could not be read as management.
    case unreachable
}

/// The one read the update reconcile makes of the daemon.
///
/// Narrow on purpose: the reconcile needs `hello` and nothing else, and a seam
/// the width of the whole gateway would invite a second reader of state the
/// surfaces already own.
public protocol UpdateEngineProbing: Sendable {
    func read() async -> UpdateEngineAnswer
}

/// The shipped probe: one `hello` on this home's management socket.
public struct ManagementUpdateEngineProbe: UpdateEngineProbing {
    private let gateway: any DaemonQuerying

    public init(gateway: any DaemonQuerying) {
        self.gateway = gateway
    }

    public func read() async -> UpdateEngineAnswer {
        // The reconcile runs across a daemon being replaced, so the window the
        // gateway learned belongs to a process that may be gone. Dropping it
        // first is what makes this read address the daemon that is there now.
        await gateway.invalidateNegotiation()

        do {
            let hello = try await gateway.negotiate()
            let contract = try ManagementContract.vendored()
            guard ManagementNegotiation.highestShared(
                speakable: contract.speakableVersions,
                daemon: hello.protocolRange
            ) != nil else { return .noSharedProtocol }

            return .answered(hello)
        } catch let failure as ManagementError {
            return Self.classify(failure)
        } catch {
            AppLog.logger(.lifecycle).error(
                "the update reconcile could not read the daemon: \(String(describing: error), privacy: .public)"
            )
            return .unreachable
        }
    }

    /// No `default` on purpose: a refusal kind added later has to be classified
    /// rather than falling into "nothing is listening", which is the answer
    /// that would let a reconcile mutate a registration against a daemon it
    /// never actually saw.
    static func classify(_ failure: ManagementError) -> UpdateEngineAnswer {
        switch failure {
        case .incompatibleProtocol:
            return .noSharedProtocol
        case .transport, .malformedEnvelope, .correlationMismatch, .daemon,
             .requestTooLarge, .invalidParameter, .invalidRequestIdentifier,
             .notNegotiated, .methodRequiresNewerEngine:
            return .unreachable
        }
    }
}

/// The launch reconcile, behind a seam. Every launch path asks this one owner,
/// and nothing else compares an update transaction with the machine.
public protocol UpdateReconciling {
    func reconcile() async throws -> UpdateReconcileOutcome
    /// Throws away a record this reconcile could not read.
    ///
    /// A record is evidence, so the reconcile never deletes one it cannot
    /// understand: it opens Recovery on `journalUnusable`, and every later
    /// launch answers the same way until something removes the file. Recovery's
    /// own Try again is that something, and it is the only caller.
    func discardUnusableRecord() throws
}

/// The one owner of the update reconcile (M34 §6, R4).
///
/// It reads the record, looks at the machine once, decides through the pure
/// table in `UpdateReconcileDecision`, and then performs the one thing that
/// decision calls for. The registration mutations go through the existing
/// lifecycle transactions rather than through a second registration owner, so
/// the drain, the bounded waits and the service journal are the ones already
/// proven.
public struct UpdateReconciler: UpdateReconciling {
    private let journal: UpdateJournal
    private let lifecycle: any DaemonLifecycleControlling
    private let services: ServiceController
    /// The one engine comparison (M34 §7.2), asked rather than repeated.
    private let engines: EngineReconciler
    private let probe: any UpdateEngineProbing
    private let installedApp: AppBuild
    private let sleeper: any Sleeping
    private let log = AppLog.logger(.lifecycle)

    public init(
        journal: UpdateJournal,
        lifecycle: any DaemonLifecycleControlling,
        services: ServiceController,
        engines: EngineReconciler,
        probe: any UpdateEngineProbing,
        installedApp: AppBuild,
        sleeper: any Sleeping
    ) {
        self.journal = journal
        self.lifecycle = lifecycle
        self.services = services
        self.engines = engines
        self.probe = probe
        self.installedApp = installedApp
        self.sleeper = sleeper
    }

    /// Reconciles this launch. Interrupted verification returns Recovery after
    /// undoing any registration this reconcile restored.
    public func reconcile() async throws -> UpdateReconcileOutcome {
        let entry: UpdateJournalEntry?
        do {
            entry = try journal.load()
        } catch {
            log.error("the update record could not be read: \(String(describing: error), privacy: .public)")
            return .recovery(UpdateRecoveryReport(reason: .journalUnusable, entry: nil))
        }

        let decision = UpdateReconcileDecision.decide(journal: entry, observation: await observe())
        log.log("update reconcile decided \(String(describing: decision), privacy: .public)")

        switch decision {
        case .proceed:
            return .proceed
        case .discardJournal:
            return clear(entry)
        case .restartToFinish(let running, let bundled):
            return .restartToFinish(running: running, bundled: bundled)
        case .openRecovery(let reason):
            return .recovery(UpdateRecoveryReport(reason: reason, entry: entry))
        case .restoreSource(let plan):
            return await finish(plan, side: .source, entry: entry)
        case .completeTarget(let plan):
            return await finish(plan, side: .target, entry: entry)
        }
    }

    public func discardUnusableRecord() throws {
        try journal.clear()
    }

    /// One look at the machine, so every branch of the decision is made against
    /// the same moment.
    private func observe() async -> UpdateObservation {
        let answer = await probe.read()

        return UpdateObservation(
            installedApp: installedApp,
            bundledEngine: engines.bundledBuild,
            engines: engines.reconcile(hello: answer.hello),
            protocolMismatch: answer == .noSharedProtocol,
            registration: services.status(.agent)
        )
    }

    // MARK: - Finishing a transaction

    private enum Side {
        case source
        case target

        var unverified: UpdateRecoveryReason {
            self == .source ? .sourceEngineUnverified : .targetEngineUnverified
        }

        /// Only the target has to be a different process: the source may never
        /// have exited, and that daemon answering again is the restored state.
        var requiresANewProcess: Bool { self == .target }
    }

    /// What one bounded verification wait ended as.
    private enum Verification: Equatable {
        case proven
        /// The engine the plan names never answered inside the budget.
        case unproven
        /// A daemon answered that shares no protocol version with this app.
        case noSharedProtocol

        /// Why Recovery opens, for a wait that proved nothing. A daemon this
        /// app cannot speak to is its own reason: "the engine did not answer"
        /// would send the operator looking for a daemon that is running.
        func reason(_ side: Side) -> UpdateRecoveryReason {
            self == .noSharedProtocol ? .noSharedProtocol : side.unverified
        }
    }

    /// Puts the recorded registration back, proves the engine, and clears the
    /// record. Nothing here enables a service the record says was off, and
    /// nothing disables a registration this reconcile did not turn on.
    private func finish(
        _ plan: UpdateRestorePlan,
        side: Side,
        entry: UpdateJournalEntry?
    ) async -> UpdateReconcileOutcome {
        // A service that was disabled before the update stays disabled, and is
        // never enabled merely to complete a health check (M34 §6).
        guard plan.registration == .enabled else { return clear(entry) }

        let restored: Bool
        do {
            restored = try await restoreRegistration()
        } catch {
            log.error("the registration could not be restored: \(String(describing: error), privacy: .public)")
            return .recovery(UpdateRecoveryReport(
                reason: .registrationNotRestored,
                entry: entry,
                disableRefused: undoFailedRegistration()
            ))
        }

        let verification = await verify(plan, requiringANewProcess: side.requiresANewProcess)
        guard verification == .proven else {
            return .recovery(
                UpdateRecoveryReport(
                    reason: verification.reason(side),
                    entry: entry,
                    // The record stays: Recovery reads it, and it is the only
                    // place the prior installer is written down.
                    disableRefused: restored ? await disableRestoredRegistration() : false
                )
            )
        }

        return clear(entry)
    }

    /// Re-registers the agent where the record says it was registered and macOS
    /// says it is not. The lifecycle transaction owns the registration, the
    /// bounded waits and the health check; this only decides that it should
    /// run.
    ///
    /// - Returns: whether this reconcile is what turned the service on, which
    ///   is the only registration it is allowed to turn off again.
    private func restoreRegistration() async throws -> Bool {
        guard services.status(.agent) != .enabled else { return false }

        _ = try await lifecycle.enableBackgroundService()
        return true
    }

    /// Enabling registers before checking health. Undo that partial success
    /// through the service owner; a new lifecycle transaction would be refused
    /// by the failed enable's journal. Keep the update record for Recovery.
    ///
    /// The record is resolved before the registration is taken back, because
    /// the reverse order has a step that can fail in between: an unregister
    /// that succeeds and a record still on disk leaves an install whose next
    /// transaction is refused by evidence of a step already undone.
    private func undoFailedRegistration() -> Bool {
        guard services.status(.agent) == .enabled else { return false }

        resolveFailedEnableRecord()

        do {
            try services.disable(.agent)
        } catch {
            log.error("the failed restore could not be disabled: \(String(describing: error), privacy: .public)")
            return true
        }
        guard services.status(.agent) != .enabled else {
            log.error("the failed restore is still registered after unregistering")
            return true
        }

        return false
    }

    /// Discards the failed enable's own record, which is what lets the next
    /// lifecycle transaction start.
    ///
    /// A record of any other kind belongs to a transaction this reconcile did
    /// not run, so it is left alone and named in the log: clearing it would
    /// throw away someone else's evidence, and passing over it in silence is
    /// how a record nothing explains comes to block every later transaction.
    private func resolveFailedEnableRecord() {
        do {
            guard let interrupted = try lifecycle.interruptedTransaction() else { return }
            guard interrupted.kind == .enable else {
                log.error(
                    "a \(interrupted.kind.rawValue, privacy: .public) record outlived the failed restore"
                )
                return
            }

            try lifecycle.discardInterruptedTransaction()
        } catch {
            log.error("the failed enable record could not be resolved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Takes back the registration this reconcile turned on to run the check.
    ///
    /// - Returns: whether the disable was refused, so a service the operator
    ///   was told is off but is not says so on the screen rather than only in
    ///   the log. The refusal itself goes to the log, because macOS's own
    ///   description of it is not a sentence a window can render.
    private func disableRestoredRegistration() async -> Bool {
        do {
            _ = try await lifecycle.disableBackgroundService()
            return false
        } catch {
            log.error(
                "the restored registration could not be disabled again: \(String(describing: error), privacy: .public)"
            )
            return true
        }
    }

    /// One bounded wait, with a defined outcome: a daemon that never comes back
    /// ends the launch in Recovery rather than hanging it.
    ///
    /// What this proves is identity, process and protocol; the engine's health
    /// is proven by the lifecycle transaction that restored the registration,
    /// which is why nothing here asks a second time.
    ///
    /// A daemon that shares no protocol version stops the wait where it is: no
    /// management call can reach it, so the remaining budget would prove
    /// nothing and would report the wrong reason at the end of it.
    private func verify(_ plan: UpdateRestorePlan, requiringANewProcess: Bool) async -> Verification {
        let policy = LifecyclePolicy.engineVerification

        for attempt in 0..<policy.attempts {
            let answer = await probe.read()
            if answers(plan, requiringANewProcess: requiringANewProcess, answer) { return .proven }
            if answer == .noSharedProtocol { return .noSharedProtocol }
            guard attempt + 1 < policy.attempts else { break }
            do {
                try await sleeper.sleep(seconds: policy.interval)
            } catch {
                log.error("update verification was interrupted: \(String(describing: error), privacy: .public)")
                return .unproven
            }
        }

        log.error(
            "the engine \(plan.expected.buildId, privacy: .public) never answered within the verification budget"
        )
        return .unproven
    }

    /// Whether that answer is the engine the plan expects, from the process the
    /// plan expects it from.
    private func answers(
        _ plan: UpdateRestorePlan,
        requiringANewProcess: Bool,
        _ answer: UpdateEngineAnswer
    ) -> Bool {
        guard let hello = answer.hello, EngineBuild(hello: hello) == plan.expected else { return false }
        guard requiringANewProcess, let previous = plan.previousPid else { return true }
        // A pid that cannot be read is not proof of a new process, and this is
        // the step that proves the replacement actually happened.
        guard let current = Int32(hello.engine.pid) else { return false }

        return current != previous
    }

    /// Clears a resolved record. A record that cannot be cleared would put this
    /// launch and every later one through the same reconcile, so it is a broken
    /// install rather than a completed transaction.
    private func clear(_ entry: UpdateJournalEntry?) -> UpdateReconcileOutcome {
        do {
            try journal.clear()
            return .proceed
        } catch {
            log.error("the update record could not be cleared: \(String(describing: error), privacy: .public)")
            return .recovery(UpdateRecoveryReport(reason: .journalUnusable, entry: entry))
        }
    }
}

private extension UpdateEngineAnswer {
    /// The daemon's own answer, where there was one. The engine comparison
    /// takes an optional `hello` for exactly this reason.
    var hello: ManagementHello? {
        guard case .answered(let hello) = self else { return nil }

        return hello
    }
}
