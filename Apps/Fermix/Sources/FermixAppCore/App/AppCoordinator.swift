import Foundation

/// Quitting, behind a seam. `NSApp.terminate` is the one thing a test must
/// never actually do.
@MainActor
public protocol TerminationRequesting: AnyObject {
    func requestTermination()
}

/// What the app puts on screen for a launch.
public enum AppPresentation: Equatable, Sendable {
    /// The menu bar is the app. A login launch opens nothing.
    case menuBarOnly
    case onboarding
    case recovery
    case main(AppRoute)
}

/// What the lifecycle recovery journal says about the last transaction.
public enum RecoveryCondition: Equatable, Sendable {
    case none
    /// A transaction stopped part-way and left its record behind.
    case interrupted(kind: LifecycleTransactionKind, phase: LifecyclePhase)
    /// The record exists but cannot be read, which is itself a broken install.
    case journalUnreadable

    public var needsRecovery: Bool { self != .none }
}

/// The composition root: launch reasons, routes, menu actions, recovery, and
/// quitting.
///
/// It owns no state of its own — the model holds presentation, the window
/// coordinator holds windows, the lifecycle coordinator holds transactions.
/// What lives here is the decision about which of them a request belongs to.
@MainActor
public final class AppCoordinator {
    private let model: AppModel
    private let windows: WindowCoordinator
    private let voice: any VoiceControlling
    private let lifecycle: any DaemonLifecycleControlling
    private let bootstrap: () -> BootstrapCondition
    private let termination: any TerminationRequesting
    private let log = AppLog.logger(.app)
    private var transaction: Task<Void, Never>?

    public init(
        model: AppModel,
        windows: WindowCoordinator,
        voice: any VoiceControlling,
        lifecycle: any DaemonLifecycleControlling,
        bootstrap: @escaping () -> BootstrapCondition,
        termination: any TerminationRequesting
    ) {
        self.model = model
        self.windows = windows
        self.voice = voice
        self.lifecycle = lifecycle
        self.bootstrap = bootstrap
        self.termination = termination
    }

    /// What the recovery journal says about the last transaction. A journal that
    /// cannot be read is itself a reason to open Recovery: it is the one file
    /// that would have said what happened.
    private func recoveryCondition() -> RecoveryCondition {
        do {
            guard let entry = try lifecycle.interruptedTransaction() else { return .none }

            return .interrupted(kind: entry.kind, phase: entry.phase)
        } catch {
            log.error("recovery journal unreadable: \(String(describing: error), privacy: .public)")
            return .journalUnreadable
        }
    }

    /// The user acknowledged whatever put the app into recovery. The record has
    /// served its purpose, and clearing it is what lets the next transaction
    /// start.
    public func resolveInterruptedTransaction() {
        do {
            try lifecycle.discardInterruptedTransaction()
        } catch {
            log.error("recovery journal could not be cleared: \(String(describing: error), privacy: .public)")
            model.needsAttention = true
        }
    }

    // MARK: - Launch

    /// What a launch means, as a value. A login launch is quiet, a fresh
    /// account has nothing to show but onboarding, a broken record goes
    /// straight to recovery, and a url is an explicit request for one surface.
    nonisolated public static func presentation(
        for reason: LaunchReason,
        bootstrap: BootstrapCondition,
        recovery: RecoveryCondition = .none
    ) -> AppPresentation {
        if case .login = reason { return .menuBarOnly }
        if case .unreadable = bootstrap { return .recovery }
        if recovery.needsRecovery { return .recovery }

        switch reason {
        case .login:
            return .menuBarOnly
        case .user:
            return bootstrap == .present ? .main(.home) : .onboarding
        case .route(.recovery):
            return .recovery
        case .route(let route):
            return .main(route)
        }
    }

    public func start(reason: LaunchReason) {
        present(Self.presentation(for: reason, bootstrap: bootstrap(), recovery: recoveryCondition()))
    }

    /// Handles a `fermix://` url. An unknown one is refused: opening Home
    /// instead would tell the user their command worked.
    public func open(url: URL) throws {
        open(try AppRoute.parse(url))
    }

    /// Opens a route the app itself asked for, as onboarding does when its
    /// boot-failure card sends the user to Doctor or Logs.
    /// An explicit request wins over an unresolved recovery record: Doctor and
    /// Logs are exactly what an install in that state needs to reach.
    public func open(_ route: AppRoute) {
        log.log("opening route \(route.rawValue, privacy: .public)")
        present(Self.presentation(for: .route(route), bootstrap: bootstrap(), recovery: .none))
    }

    public func enterRecovery() {
        present(.recovery)
    }

    private func present(_ presentation: AppPresentation) {
        switch presentation {
        case .menuBarOnly:
            return
        case .onboarding:
            model.onboardingStage = .welcome
            windows.show(.onboarding)
        case .recovery:
            model.onboardingStage = .recovery
            windows.show(.onboarding)
        case .main(let route):
            model.route = route
            windows.show(.main)
        }
    }

    // MARK: - Menu

    public func perform(_ action: MenuAction) {
        switch action {
        case .openFermix:
            present(.main(.home))
        case .setup:
            present(.main(.setup))
        case .runDoctor:
            present(.main(.doctor))
        case .checkForUpdates:
            present(.main(.update))
        case .togglePet:
            togglePet()
        case .pauseNotifications:
            // Owned by the notification surface, which does not exist yet. The
            // row is in the panel because the design publishes it; wiring it to
            // nothing would be worse than saying so here.
            log.log("pause notifications has no owner in this build")
        case .restartDaemon:
            runTransaction { try await self.lifecycle.restartDaemon() }
        case .toggleService:
            toggleBackgroundService()
        case .quit:
            quit()
        }
    }

    /// Releases the GUI's own resources and quits. No daemon lifecycle command
    /// is sent: the background service is a registration, and it survives the
    /// window closing.
    public func quit() {
        voice.shutdown()
        termination.requestTermination()
    }

    private func togglePet() {
        setPetWindow(!windows.isOpen(.pet))
    }

    private func toggleBackgroundService() {
        setBackgroundService(enabled: !model.serviceEnabled)
    }

    /// Runs the enable or disable transaction for the state the caller wants.
    ///
    /// Home has a switch and the menu bar has a row; a toggle would let the two
    /// disagree about what "the other one" is while a transaction is in flight,
    /// so the surfaces state the target and this decides which transaction that
    /// is.
    public func setBackgroundService(enabled: Bool) {
        runTransaction {
            enabled
                ? try await self.lifecycle.enableBackgroundService()
                : try await self.lifecycle.disableBackgroundService()
        }
    }

    /// Whether a lifecycle transaction is running right now, which is what a
    /// surface disables its own controls on.
    public var isRunningTransaction: Bool { transaction != nil }

    // MARK: - Transactions

    /// One lifecycle transaction at a time. A second request while one is in
    /// flight is refused rather than queued: two overlapping drains of the same
    /// daemon is exactly what the journal exists to prevent.
    private func runTransaction(_ work: @escaping () async throws -> LifecycleOutcome) {
        guard transaction == nil else {
            log.log("a lifecycle transaction is already running")
            return
        }

        model.transactionInFlight = true
        transaction = Task { @MainActor [weak self] in
            defer {
                self?.transaction = nil
                self?.model.transactionInFlight = false
            }

            do {
                let outcome = try await work()
                self?.apply(outcome)
            } catch {
                self?.transactionFailed(error)
            }
        }
    }

    private func apply(_ outcome: LifecycleOutcome) {
        switch outcome {
        case .enabled:
            model.serviceEnabled = true
            model.daemon = .running
            model.needsAttention = false
        case .disabled:
            model.serviceEnabled = false
            model.daemon = .stopped
        case .restarted:
            model.daemon = .running
            model.needsAttention = false
        }
    }

    private func transactionFailed(_ error: any Error) {
        log.error("lifecycle transaction failed: \(String(describing: error), privacy: .public)")
        model.needsAttention = true
    }

    /// Waits for the in-flight transaction, if there is one. The window this
    /// opens is what a test uses to observe a transaction that the UI starts
    /// and forgets.
    public func drainPendingWork() async throws {
        await transaction?.value
    }
}

/// The pet window, as the pet surface asks for it.
extension AppCoordinator: PetWindowPresenting {
    public var isPetWindowOpen: Bool { windows.isOpen(.pet) }

    public func setPetWindow(_ shown: Bool) {
        shown ? windows.show(.pet) : windows.close(.pet)
        model.petShown = windows.isOpen(.pet)
    }
}
