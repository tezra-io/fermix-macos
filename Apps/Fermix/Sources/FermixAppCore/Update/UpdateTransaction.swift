import Foundation

/// Everything one update transaction needs in order to record itself.
///
/// Decided on the main actor when the barrier opens and handed over whole: the
/// transaction runs off the main actor, so what crosses that boundary is one
/// immutable value rather than a set of reads the two sides could disagree
/// about.
public struct UpdateTransactionPlan: Equatable, Sendable {
    public let transactionId: UUID
    public let source: UpdateRelease
    public let target: UpdateRelease
    /// The installer the source came from, for an explicit reinstall.
    public let priorInstaller: UpdateInstaller
    public let startedAt: Date

    public init(
        transactionId: UUID,
        source: UpdateRelease,
        target: UpdateRelease,
        priorInstaller: UpdateInstaller,
        startedAt: Date
    ) {
        self.transactionId = transactionId
        self.source = source
        self.target = target
        self.priorInstaller = priorInstaller
        self.startedAt = startedAt
    }
}

/// The mutating half of an update transaction (M34 §6, R3, steps 2 to 5):
/// record it, drain the engine, unregister the agent, prove the daemon is
/// gone, and put it all back if the update never happens.
///
/// **It is not main-actor isolated, and that is the whole point.** The last
/// callback before Sparkle's installer arms is synchronous and main-actor
/// isolated, so the only way to hold it is to block the thread it runs on. A
/// main actor held by a synchronous frame is not re-entrant, so a drain
/// written on that actor could not run while the frame waited for it: it would
/// spend the whole budget suspended and the callback would return having done
/// nothing. Running the drain here, off that actor, is what makes the barrier
/// a barrier. `UpdateCoordinator` keeps the presentation state and delegates
/// to this.
public actor UpdateTransaction {
    private let journal: UpdateJournal
    /// The one owner of draining, unregistering and re-registering. This
    /// transaction writes no second way to stop the engine.
    private let lifecycle: any DaemonLifecycleControlling
    private let services: ServiceController
    /// The one daemon read this transaction makes: who is answering before the
    /// drain, so the record names the process the launch reconcile has to see
    /// replaced.
    private let probe: any UpdateEngineProbing
    private let sleeper: any Sleeping
    private let log = AppLog.logger(.lifecycle)

    /// The record on disk, mirrored here so each boundary is written as one
    /// whole document rather than as a read-modify-write of a file a crash can
    /// catch half way.
    private var entry: UpdateJournalEntry?
    /// The drain in flight, cleared by its own completion. It is what tells a
    /// later barrier "still running" from "finished and did not stop it", so a
    /// repeated callback waits for this drain rather than offering the daemon a
    /// second lease.
    private var stopping: Task<Void, Never>?

    public init(
        journal: UpdateJournal,
        lifecycle: any DaemonLifecycleControlling,
        services: ServiceController,
        probe: any UpdateEngineProbing,
        sleeper: any Sleeping
    ) {
        self.journal = journal
        self.lifecycle = lifecycle
        self.services = services
        self.probe = probe
        self.sleeper = sleeper
    }

    // MARK: - The barrier

    /// Records the transaction, stops the engine, and answers whether it is
    /// down.
    ///
    /// Idempotent: a duplicated extraction notice waits for the same drain
    /// rather than starting a second. It keeps no clock of its own — the
    /// extraction barrier blocks a thread for exactly this call, and that block
    /// is the bound — so it waits for the drain to finish and then answers.
    public func prepare(_ plan: UpdateTransactionPlan) async -> UpdateBarrierOutcome {
        if entry == nil, stopping == nil { begin(plan) }
        await stopping?.value

        return outcome()
    }

    /// The last bounded chance before the postponed relaunch is released.
    ///
    /// The installer is armed by then, so this proves rather than prevents.
    public func commit() async -> UpdateBarrierOutcome {
        await finish(within: UpdatePolicy.relaunchBarrier)
    }

    /// One more bounded budget, spent at quit on a stop that never finished.
    public func finishOnQuit() async -> UpdateBarrierOutcome {
        await finish(within: UpdatePolicy.quitBarrier)
    }

    // MARK: - The boundaries the callbacks record

    /// The installer is armed: from here any exit of this process replaces the
    /// bundle.
    public func markStaged() {
        advance(to: .replacing)
    }

    /// The last in-process notice before the swap.
    public func markVerifying() {
        advance(to: .verifying)
    }

    /// Puts the recorded registration back and clears the record.
    ///
    /// The caller decides whether a rollback is still allowed: from the moment
    /// the installer arms it is not, because putting the old engine back under
    /// a bundle that is about to be swapped is the one thing that must not
    /// happen. The registration is the durable state, so it is restored only
    /// where the record says it was on and macOS says it is not.
    public func rollBack() async {
        await stopping?.value

        guard let recorded = entry else { return }
        entry = nil

        guard recorded.previousRegistration == .enabled, services.status(.agent) != .enabled else {
            clear()
            return
        }

        do {
            _ = try await lifecycle.enableBackgroundService()
            clear()
        } catch {
            // The record stays on disk deliberately: the launch reconcile is
            // what restores a registration this process could not, and it holds
            // the only copy of the prior artifact.
            log.error(
                "the update rolled back and the background service could not be restored: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Running it

    /// Starts the one drain. The task clears `stopping` itself, so whether a
    /// drain is in flight has one owner rather than a flag kept in step by
    /// hand.
    private func begin(_ plan: UpdateTransactionPlan) {
        stopping = Task {
            await self.run(plan)
            self.drainFinished()
        }
    }

    /// Offers the stop again for a transaction whose barrier gave up on it.
    private func resume() {
        stopping = Task {
            await self.stopEngine()
            self.drainFinished()
        }
    }

    private func drainFinished() {
        stopping = nil
    }

    /// Record, drain, prove the daemon is gone.
    ///
    /// Steps three to five are one call, because `LifecycleCoordinator` already
    /// owns the lease, the unregister, the commit and both bounded waits, and
    /// journals every one of them. Writing them again here would be a second
    /// way to stop the engine.
    private func run(_ plan: UpdateTransactionPlan) async {
        let registration = services.status(.agent)
        // Who is answering right now. The launch reconcile proves the target by
        // finding a *different* process, so a record with no pid in it cannot
        // tell "the new engine came up" from "the old one never left".
        let running = await runningProcessIdentifier()

        guard write(record(plan, registration: registration, originalPid: running)) else { return }

        // A service that was disabled and stopped keeps both facts: there is
        // nothing of ours to drain, and nothing is enabled to prove anything
        // with (M34 §6).
        guard registration == .enabled else {
            noteEngineStopped()
            return
        }

        await stopEngine()
    }

    /// Stops the engine and records the boundary on each side of it.
    private func stopEngine() async {
        // A boundary that cannot be recorded is a boundary nothing recovers, so
        // the step is not taken.
        guard advance(to: .draining) else { return }
        guard await drain() else { return }

        noteEngineStopped()
        advance(to: .stopped)
    }

    /// One drain, deferred while the daemon is mid-turn.
    ///
    /// Busy is the one refusal that is safe to offer again: the daemon refuses
    /// the lease before anything is mutated, which is exactly what
    /// `LifecycleFailure.deferredWhileBusy` documents. Every other failure is
    /// reported once and left alone.
    private func drain() async -> Bool {
        for attempt in 0..<UpdatePolicy.busyDeferral.attempts {
            switch await drainOnce() {
            case .stopped:
                return true
            case .refused:
                return false
            case .busy:
                break
            }

            guard attempt + 1 < UpdatePolicy.busyDeferral.attempts else { break }
            guard (try? await sleeper.sleep(seconds: UpdatePolicy.busyDeferral.interval)) != nil else { return false }
        }

        log.error("the daemon stayed busy for the whole deferral budget, so the update did not stop it")
        return false
    }

    private enum DrainAttempt {
        case stopped
        /// The daemon is mid-turn. Nothing was changed.
        case busy
        case refused
    }

    private func drainOnce() async -> DrainAttempt {
        do {
            _ = try await lifecycle.disableBackgroundService()
            return .stopped
        } catch LifecycleFailure.deferredWhileBusy(let message) {
            log.log("the daemon is mid-turn, so the update drain is deferred: \(message, privacy: .public)")
            return discardDeferredRecord() ? .busy : .refused
        } catch {
            log.error("the update could not stop the engine: \(String(describing: error), privacy: .public)")
            return .refused
        }
    }

    /// Clears the record a deferred drain left behind, so the next offer is not
    /// refused as an unresolved transaction. It is called for the one failure
    /// whose own contract says nothing was changed, and for no other.
    private func discardDeferredRecord() -> Bool {
        do {
            try lifecycle.discardInterruptedTransaction()
            return true
        } catch {
            log.error(
                "the deferred drain's record could not be cleared: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// The daemon that is answering, where one is and where it named a pid the
    /// app can read. A daemon that answered nothing leaves the field empty
    /// rather than guessed: an invented pid would make the reconcile prove the
    /// target against a process that never existed.
    private func runningProcessIdentifier() async -> Int32? {
        guard case .answered(let hello) = await probe.read() else { return nil }

        return Int32(hello.engine.pid)
    }

    // MARK: - Waiting

    /// One more bounded attempt at the stop, for a transaction whose barrier
    /// gave up on it. The postponed relaunch and the quit are the two chances
    /// left, and each brings its own bound.
    private func finish(within policy: PollingPolicy) async -> UpdateBarrierOutcome {
        guard entry != nil else { return .noTransaction }
        guard outcome() != .ready else { return .ready }
        if stopping == nil { resume() }

        for attempt in 0..<policy.attempts {
            if stopping == nil { return outcome() }
            guard attempt + 1 < policy.attempts else { break }
            guard (try? await sleeper.sleep(seconds: policy.interval)) != nil else { break }
        }

        log.error("the update's last bounded stop ran out with the engine still running")
        return .barrierExpired
    }

    /// What the record says, once nothing is in flight.
    private func outcome() -> UpdateBarrierOutcome {
        guard let entry else { return .noTransaction }

        return entry.engineStopped ? .ready : .engineStillRunning
    }

    // MARK: - The record

    private func record(
        _ plan: UpdateTransactionPlan,
        registration: ServiceRegistrationStatus,
        originalPid: Int32?
    ) -> UpdateJournalEntry {
        UpdateJournalEntry(
            transactionId: plan.transactionId,
            phase: .recorded,
            originalPid: originalPid,
            source: plan.source,
            target: plan.target,
            migration: UpdateMigrationEdge(
                fromEngineVersion: plan.source.engine.productVersion,
                toEngineVersion: plan.target.engine.productVersion,
                declaredBridge: false
            ),
            previousRegistration: registration,
            priorInstaller: plan.priorInstaller,
            // Nothing has been stopped yet, and this is written before the
            // first mutation, so an interruption anywhere from here on leaves a
            // record that says the engine was never proven down.
            engineStopped: false,
            // True until the target has migrated this home. Nothing in this
            // process can flip it: the migration runs in the engine that
            // arrives, and Recovery reads the flag as it was left.
            rollbackSupported: true,
            startedAt: plan.startedAt
        )
    }

    private func write(_ recorded: UpdateJournalEntry) -> Bool {
        do {
            try journal.write(recorded)
            entry = recorded
            return true
        } catch {
            log.error("the update record could not be written: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Moves the record forward, and only forward.
    ///
    /// A resumed stop crosses the drain boundary again, and a record that has
    /// already reached `replacing` must not lose that: the phase says what has
    /// become inevitable, not which step is running.
    @discardableResult
    private func advance(to phase: UpdatePhase) -> Bool {
        guard var recorded = entry else { return false }
        guard Self.rank(phase) > Self.rank(recorded.phase) else { return true }

        recorded.phase = phase
        return write(recorded)
    }

    /// Records that the engine is proven stopped.
    ///
    /// The record is created saying it is not, and this is the one write that
    /// changes that. So a barrier that expired needs no write of its own to be
    /// recorded, and the launch after a replacement reads the fact that was
    /// already on disk rather than one a dying process still had to flush.
    private func noteEngineStopped() {
        guard var recorded = entry, !recorded.engineStopped else { return }

        recorded.engineStopped = true
        _ = write(recorded)
    }

    /// How far a phase is through the transaction. `UpdatePhase` declares its
    /// cases in the order the steps mutate this Mac, which is what makes the
    /// position meaningful.
    private static func rank(_ phase: UpdatePhase) -> Int {
        UpdatePhase.allCases.firstIndex(of: phase) ?? 0
    }

    private func clear() {
        do {
            try journal.clear()
        } catch {
            log.error("the update record could not be cleared: \(String(describing: error), privacy: .public)")
        }
    }
}
