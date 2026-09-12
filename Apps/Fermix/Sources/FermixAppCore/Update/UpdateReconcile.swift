import Foundation

/// What the launch reconcile saw, gathered once before it decides anything.
///
/// Every field is a fact about this Mac right now. The engine comparison is
/// `EngineReconciler`'s, not a second one: this value carries its answer.
public struct UpdateObservation: Equatable, Sendable {
    /// The app bundle that is running, which is what says whether a
    /// replacement happened.
    public let installedApp: AppBuild
    /// The engine this bundle ships, where its manifest could be read.
    public let bundledEngine: EngineBuild?
    /// What the one engine comparison found.
    public let engines: EngineReconcileOutcome
    /// A daemon answered and shares no protocol version with this app. The
    /// engine comparison is `daemonUnreachable` then, because negotiation
    /// refused before any build could be read, and the two are different
    /// worlds: one has nothing to talk to, the other has something it cannot
    /// talk to.
    public let protocolMismatch: Bool
    /// What macOS says about this account's background service registration.
    public let registration: ServiceRegistrationStatus

    public init(
        installedApp: AppBuild,
        bundledEngine: EngineBuild?,
        engines: EngineReconcileOutcome,
        protocolMismatch: Bool,
        registration: ServiceRegistrationStatus
    ) {
        self.installedApp = installedApp
        self.bundledEngine = bundledEngine
        self.engines = engines
        self.protocolMismatch = protocolMismatch
        self.registration = registration
    }

    /// Whether launchd owns the daemon on this account, which is what makes a
    /// restart something the app can actually perform: with any other
    /// registration state the drain would stop Fermix and nothing would bring
    /// it back.
    var restartIsSupported: Bool { registration == .enabled }
}

/// What a completed transaction has to put back, and what it has to prove.
public struct UpdateRestorePlan: Equatable, Sendable {
    /// The engine that must be answering when this is done.
    public let expected: EngineBuild
    /// The registration the record captured before the transaction started.
    /// The registration is the durable state: it is restored only where this
    /// says it was on.
    public let registration: ServiceRegistrationStatus
    /// The process that was answering when the transaction started.
    public let previousPid: Int32?

    public init(expected: EngineBuild, registration: ServiceRegistrationStatus, previousPid: Int32?) {
        self.expected = expected
        self.registration = registration
        self.previousPid = previousPid
    }
}

/// Why an update cannot be finished automatically.
///
/// Each case is a different remedy, so none of them is folded onto a
/// neighbour: an app that is not either side of the record and an engine that
/// is not the one the record named send an operator to different places.
public enum UpdateRecoveryReason: String, Codable, CaseIterable, Equatable, Sendable {
    case reconcileInterrupted
    /// The one file that would have said what happened cannot be read or
    /// cleared.
    case journalUnusable
    /// The app that is running is neither side of the recorded update.
    case unexpectedApp
    /// The bundle ships an engine the record did not name, or ships none at
    /// all. Running it would be running an engine nobody chose.
    case unexpectedEngine
    /// The bundle was replaced while the engine the update started from was
    /// still answering. The barrier that holds the installer is bounded, and
    /// when its bound ran out the replacement went ahead anyway, so this home
    /// was written by an engine that was being swapped out from under it.
    case engineNotStopped
    /// The transaction was rolled back to the source and the source engine did
    /// not come back.
    case sourceEngineUnverified
    /// The replacement happened and the new engine did not come back.
    case targetEngineUnverified
    /// The registration the record says was on could not be put back, so the
    /// update is left half applied rather than claimed finished. macOS
    /// refusing the item is one way in; an outstanding lifecycle record and a
    /// daemon that never came up are others, which is why the case is named
    /// for the step rather than for one of its causes.
    case registrationNotRestored
    /// A daemon is answering that this account's registration does not own, so
    /// no restart this app can perform would replace it. Either another macOS
    /// account holds the registration for this bundle, or the daemon was
    /// started outside launchd.
    case conflictingRegistration
    /// macOS is holding this account's background item until the operator
    /// allows it. It is kept apart from `conflictingRegistration` because it is
    /// the one registration state with a one-click remedy, and being told
    /// another account owns the daemon sends the operator hunting a fault that
    /// is not there.
    case registrationNeedsApproval
    /// The daemon answering shares no protocol version with this app, so no
    /// management operation can reach it, the restart included.
    case noSharedProtocol
}

/// What Recovery states about an update that did not finish.
///
/// Every field comes from the record on disk, so the screen opens with no
/// daemon, no feed and no network.
public struct UpdateRecoveryReport: Equatable, Sendable {
    public let reason: UpdateRecoveryReason
    public let phase: UpdatePhase?
    public let source: UpdateRelease?
    public let target: UpdateRelease?
    public let migration: UpdateMigrationEdge?
    /// The installer the source came from, for an explicit reinstall.
    public let priorInstaller: UpdateInstaller?
    /// Whether returning to exactly that source is data safe. False where there
    /// is no record: nothing is promised about data nothing describes.
    public let rollbackSupported: Bool
    /// Whether the registration this reconcile turned on to prove the new
    /// engine could not be turned off again. A refusal that reached only the
    /// log would leave the operator with a service they were told is off.
    public let disableRefused: Bool

    public init(
        reason: UpdateRecoveryReason,
        entry: UpdateJournalEntry?,
        disableRefused: Bool = false
    ) {
        self.reason = reason
        self.phase = entry?.phase
        self.source = entry?.source
        self.target = entry?.target
        self.migration = entry?.migration
        self.priorInstaller = entry?.priorInstaller
        self.rollbackSupported = entry?.rollbackSupported ?? false
        self.disableRefused = disableRefused
    }
}

/// What the reconcile will do about what it saw.
///
/// Pure: no seam is touched to compute it, so the whole table is provable in
/// one place, and the reconciler below is only the actions.
public enum UpdateReconcileDecision: Equatable, Sendable {
    /// Nothing about an update is outstanding.
    case proceed
    /// A record whose transaction mutated nothing: discard it.
    case discardJournal
    /// The bundle was not replaced. Put the recorded registration back and
    /// prove the source engine answers.
    case restoreSource(UpdateRestorePlan)
    /// The bundle was replaced with the target. Put the recorded registration
    /// back and prove the target engine answers in a new process.
    case completeTarget(UpdateRestorePlan)
    /// One restart finishes it, and this account can perform that restart.
    case restartToFinish(running: EngineBuild, bundled: EngineBuild)
    /// No safe automatic step: Recovery opens with what the record can state.
    case openRecovery(UpdateRecoveryReason)

    /// The whole table, in one place.
    ///
    /// - Parameter journal: the record an interrupted transaction left, if any.
    ///   Absent is the ordinary launch, and also the bundle replaced outside
    ///   any transaction of ours: a Homebrew cask upgrade or a manual re-drag
    ///   of the DMG over a running install.
    public static func decide(
        journal: UpdateJournalEntry?,
        observation: UpdateObservation
    ) -> UpdateReconcileDecision {
        // A daemon this app cannot speak to leaves no safe automatic step,
        // whatever the record says: the restart is itself a management call,
        // and no engine identity could be read to compare.
        guard !observation.protocolMismatch else { return .openRecovery(.noSharedProtocol) }
        guard let journal else { return unjournaled(observation) }

        switch journal.side(of: observation.installedApp) {
        case .source:
            return sourceInstalled(journal, observation)
        case .target:
            return targetInstalled(journal, observation)
        case .neither:
            return .openRecovery(.unexpectedApp)
        }
    }

    /// No record of ours, so the only question is whether the bundle was
    /// replaced under the running daemon by something else.
    private static func unjournaled(_ observation: UpdateObservation) -> UpdateReconcileDecision {
        guard case .pendingEngineRestart(let running, let bundled) = observation.engines else {
            return .proceed
        }

        return restart(running: running, bundled: bundled, observation)
    }

    /// The bundle was never replaced: an interrupted shutdown, a reboot at a
    /// boundary before the replacement, or a replacement that failed.
    private static func sourceInstalled(
        _ journal: UpdateJournalEntry,
        _ observation: UpdateObservation
    ) -> UpdateReconcileDecision {
        // Nothing had been mutated when the record was written, so there is
        // nothing to put back.
        guard journal.phase != .recorded else { return .discardJournal }
        // The bundle that is running has to be the one the record was written
        // against, on this side too: a source bundle carrying some other
        // engine is a replacement nobody recorded, and restoring would start an
        // engine nobody chose.
        guard observation.bundledEngine == journal.source.engine else {
            return .openRecovery(.unexpectedEngine)
        }
        // Refused before any mutation: restoring would be proven against an
        // engine that is neither side of this record.
        guard answersTheExpectedEngine(journal.source.engine, observation) else {
            return .openRecovery(.unexpectedEngine)
        }

        return .restoreSource(plan(expecting: journal.source.engine, journal))
    }

    /// The bundle was replaced and the app running now is the target.
    private static func targetInstalled(
        _ journal: UpdateJournalEntry,
        _ observation: UpdateObservation
    ) -> UpdateReconcileDecision {
        // The bundle that arrived has to be the bundle the record was written
        // against. Running a different embedded engine is exactly what M34
        // forbids doing silently.
        guard observation.bundledEngine == journal.target.engine else {
            return .openRecovery(.unexpectedEngine)
        }
        // The replacement happened with the engine still up. It is checked
        // before the restart is offered, because a restart would put the new
        // engine over a home the old one may have been mid-write on.
        guard journal.engineStopped else { return .openRecovery(.engineNotStopped) }
        // The old daemon survived the replacement, so the target is on disk and
        // not in memory. One restart puts it there, and it is the same restart
        // an unjournaled replacement offers — but only if what survived is the
        // engine the record started from. A third engine on the socket would be
        // restarted away by a step this record does not describe.
        if case .pendingEngineRestart(let running, let bundled) = observation.engines {
            guard running == journal.source.engine else { return .openRecovery(.unexpectedEngine) }

            return restart(running: running, bundled: bundled, observation)
        }

        return .completeTarget(plan(expecting: journal.target.engine, journal))
    }

    /// The restart, offered only where this account can actually perform it.
    ///
    /// An item macOS is holding for approval is named as that rather than
    /// folded onto the conflict: it is this account's own registration, and one
    /// switch in System Settings is the whole remedy.
    private static func restart(
        running: EngineBuild,
        bundled: EngineBuild,
        _ observation: UpdateObservation
    ) -> UpdateReconcileDecision {
        if observation.registration == .requiresApproval {
            return .openRecovery(.registrationNeedsApproval)
        }
        guard observation.restartIsSupported else { return .openRecovery(.conflictingRegistration) }

        return .restartToFinish(running: running, bundled: bundled)
    }

    private static func plan(
        expecting engine: EngineBuild,
        _ journal: UpdateJournalEntry
    ) -> UpdateRestorePlan {
        UpdateRestorePlan(
            expected: engine,
            registration: journal.previousRegistration,
            previousPid: journal.originalPid
        )
    }

    /// Whether what is answering is the engine this side of the record names.
    /// A daemon that answered nothing to compare is not a mismatch: the restore
    /// is what brings one back.
    private static func answersTheExpectedEngine(
        _ expected: EngineBuild,
        _ observation: UpdateObservation
    ) -> Bool {
        guard case .pendingEngineRestart(let running, _) = observation.engines else { return true }

        return running == expected
    }
}

/// What the reconcile ended as, once its actions have run.
public enum UpdateReconcileOutcome: Equatable, Sendable {
    /// Ordinary UI. Nothing about an update is outstanding.
    case proceed
    /// One restart finishes it. The existing pending-restart surfaces are what
    /// draw it; this is the reconcile agreeing that the promise is keepable.
    case restartToFinish(running: EngineBuild, bundled: EngineBuild)
    /// Recovery opens, with what the record can state offline.
    case recovery(UpdateRecoveryReport)
}
