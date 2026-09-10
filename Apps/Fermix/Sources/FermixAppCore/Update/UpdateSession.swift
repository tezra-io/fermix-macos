import Foundation

/// What the person answered on the updater's own alert (M34 §6).
public enum UpdateUserChoice: String, CaseIterable, Equatable, Sendable {
    case install
    /// Remind me later, and — once the update is staged — the button the
    /// updater re-titles `Install on Quit`, which is why dismissing at that
    /// stage is an armed state rather than a cancellation.
    case dismiss
    /// Skip this version. The one choice that disarms a staged installer.
    case skip
}

/// How far the update had got when the person answered.
public enum UpdateUserStage: String, CaseIterable, Equatable, Sendable {
    case notDownloaded
    case downloaded
    /// Already staged: the installer exists and will replace the bundle when
    /// this process exits, whatever the answer was.
    case installing
}

/// How one check ended (M34 §6, R2).
///
/// The distinction is the whole point: a check that failed must never be
/// rendered as `Up to date`, which is the untruth the update surface exists to
/// avoid.
public enum UpdateCycleOutcome: Equatable, Sendable {
    /// The feed was read. Whether it offered anything is the offer's business.
    case completed
    /// The person dismissed, skipped, or cancelled. Nothing failed.
    case dismissed
    /// The check did not complete. The description is the updater's own, for
    /// the log.
    case failed(String)
}

/// What a bounded barrier ended as.
///
/// One of the four is safe. The other three are the states the whole design
/// exists to make rare: the replacement is going to happen and the engine is
/// still up, so the record on disk is what the next launch recovers from. They
/// are kept apart because they send an operator to different places — a daemon
/// that refused to stop, a bound that ran out while it was still trying, and a
/// replacement this app never recorded at all.
public enum UpdateBarrierOutcome: String, CaseIterable, Equatable, Sendable {
    /// The engine is stopped, or was never registered to run.
    case ready
    /// The drain finished and the engine is still answering.
    case engineStillRunning
    /// The barrier's bound ran out with the drain still in flight. The drain is
    /// left running: it owns the record, and the step after this one waits for
    /// it again.
    case barrierExpired
    /// This coordinator has no transaction, so nothing it owns is being
    /// replaced.
    case noTransaction
}

/// Why an update is refused before anything is downloaded.
///
/// Every case is checked at the one veto the updater offers before it stages
/// anything, so a refusal here means nothing was downloaded, nothing was shown
/// and nothing can arm.
public enum UpdateRefusal: Error, Equatable, Sendable {
    /// This bundle may not run an updater at all.
    case notConfigured(UpdateConfigurationRefusal)
    /// A lifecycle transaction, another update, or the launch reconcile is
    /// already mutating the service.
    case busy(ServiceMutation)
    /// An interrupted transaction's record is still open. Starting over it
    /// would destroy the only evidence of what stopped.
    case recoveryPending
    /// Something is answering on the management socket that this account's
    /// registration does not own, so stopping it would be a takeover.
    case unownedDaemon(ServiceRegistrationStatus)
    /// This bundle ships no readable engine manifest, so the source side of the
    /// record cannot be written.
    case bundledEngineUnknown
    /// The feed does not describe the release that is installed, so the prior
    /// artifact Recovery would reinstall is unknown.
    case priorReleaseUnknown(build: Int)
    /// The offered entry cannot be transacted.
    case feed(UpdateFeedRefusal)
    /// The offered release is not newer than the one installed.
    case notAnUpgrade(installed: Int, offered: Int)
}

/// Where the update transaction has got to.
///
/// Ordered by what has been mutated and by what is now inevitable, which is
/// what every barrier and the quit gate read.
public enum UpdateTransactionState: Equatable, Sendable {
    case idle
    /// The engine is stopped and the agent unregistered, or the service was
    /// already off. The bundle may be replaced.
    case ready(UUID)
    /// The updater has staged the update. Any exit of this process now replaces
    /// the bundle, with no further call into this process.
    case armed(UUID)
    /// The engine could not be stopped inside the barrier's bound.
    case stalled(UUID)

    public var transactionId: UUID? {
        switch self {
        case .idle: return nil
        case .ready(let id), .armed(let id), .stalled(let id): return id
        }
    }

    /// Whether a replacement is now inevitable, which is what the quit gate
    /// acts on.
    public var isArmed: Bool {
        guard case .armed = self else { return false }

        return true
    }
}

/// Who owns the daemon behind the management socket, as far as this account can
/// tell.
///
/// `SMAppService` publishes no cross-account registration state, so this is the
/// sharpest signal available: what this account registered, and whether
/// anything is listening.
public enum DaemonOwnership: Equatable, Sendable {
    /// launchd owns it on this account.
    case thisAccount
    /// Nothing is registered and nothing is listening.
    case none
    /// Something is listening that this account's registration does not own:
    /// another account's registration, or a daemon started by hand.
    case unowned(ServiceRegistrationStatus)
}

/// The one synchronous read of who owns the daemon.
///
/// Synchronous because the updater's only pre-download veto is a synchronous
/// callback: an answer that needs a round trip cannot be had there, and
/// refusing after the person has chosen Install is not a refusal at all.
public protocol DaemonOwnershipReading {
    func ownership() -> DaemonOwnership
}

/// The shipped read: this account's registration, plus whether the management
/// socket node exists.
///
/// A socket left behind by a daemon that is gone reads as `unowned`, which
/// refuses the update. That is the safe direction: the alternative is draining
/// something this app did not start.
public struct ServiceDaemonOwnership: DaemonOwnershipReading {
    private let services: ServiceController
    private let paths: any PathPresence
    private let socketPath: () throws -> String

    public init(
        services: ServiceController,
        paths: any PathPresence,
        socketPath: @escaping () throws -> String
    ) {
        self.services = services
        self.paths = paths
        self.socketPath = socketPath
    }

    public func ownership() -> DaemonOwnership {
        let registration = services.status(.agent)
        guard registration != .enabled else { return .thisAccount }

        guard let path = try? socketPath() else { return .none }

        return paths.exists(atPath: path) ? .unowned(registration) : .none
    }
}

/// The updater itself, behind a seam.
///
/// Sparkle lives on the other side of it: `FermixAppCore` declares this and
/// imports nothing, because both executables link this library and M34 §6
/// forbids `FermixAgent` from loading the framework.
@MainActor
public protocol UpdaterDriving: AnyObject {
    /// Whether the updater would accept a check right now. The menu row and
    /// Home follow this rather than deciding for themselves.
    var canCheckForUpdates: Bool { get }
    /// Starts the updater with `coordinator` bound as its delegate, and answers
    /// what stopped it where it could not start. Called once.
    func start(_ coordinator: UpdateCoordinator) -> UpdateConfigurationRefusal?
    /// A check the person asked for. It surfaces releases they skipped, and
    /// while an update is already showing it brings that alert back into focus.
    func checkForUpdates()
}

/// The updater seam for a build with no updater behind it.
///
/// The fixture configuration, which replaces the machine wholesale and must
/// never reach a feed. It is a second declared configuration rather than a
/// fallback: nothing selects it at runtime.
@MainActor
public final class UnwiredUpdater: UpdaterDriving {
    public init() {}

    public var canCheckForUpdates: Bool { false }

    public func start(_ coordinator: UpdateCoordinator) -> UpdateConfigurationRefusal? { .feedMissing }

    public func checkForUpdates() {}
}

/// Every bound the update transaction waits inside.
///
/// Each has one job and one defined outcome, because the transaction runs
/// across a bundle replacement: a wait with no cap here is a Mac that never
/// finishes updating.
public enum UpdatePolicy {
    /// How long the transaction keeps offering to drain a daemon that is
    /// mid-turn. A busy daemon is the one refusal that is safe to retry: the
    /// lease is refused before anything is mutated.
    public static let busyDeferral = PollingPolicy(interval: 2, attempts: 10)
    /// How long the extraction barrier holds the updater while the engine
    /// stops. It is the last point before the installer can arm, so the bound
    /// covers a whole drain (the daemon's lease, its exit, and its socket)
    /// plus the deferral above. It is spent by blocking the thread the
    /// callback runs on, which is why it is the one bound in this file that is
    /// read as a budget rather than polled.
    public static let replacementBarrier = PollingPolicy(interval: 0.25, attempts: 240)
    /// How long a record boundary written from inside a Sparkle callback holds
    /// that callback. It is one local file write, so a bound this size means a
    /// disk that is not answering rather than a slow write; the callbacks that
    /// take it are the ones the process may not outlive.
    public static let recordBudget: TimeInterval = 5
    /// How long the postponed relaunch waits before it is released. The
    /// installer is already armed by then, so holding it longer would leave the
    /// app armed and unusable rather than making it safer.
    public static let relaunchBarrier = PollingPolicy(interval: 0.25, attempts: 60)
    /// How long a quit waits for a stop it has to finish first.
    public static let quitBarrier = PollingPolicy(interval: 0.25, attempts: 60)
}
