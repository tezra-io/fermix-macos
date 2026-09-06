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
    /// The Setup Assistant, at the screen the request named. One case rather
    /// than one per screen, so `fermix://setup`, `fermix://recovery` and a fresh
    /// account all resolve into the same window through the same value.
    case assistant(OnboardingStage)
    case main(AppRoute)
    /// The settings presentation of the primary window, at the pane the request
    /// named (decision D1). It is not a second window: the same window shows it,
    /// and the back control returns to the surface it replaced.
    case settings(SettingsPane)
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
    /// The one settings model, so opening a pane by url and opening it from the
    /// sidebar write the same selection.
    private let settings: SettingsModel
    /// Whether the primary window is showing settings (decision D1). The
    /// coordinator owns entering, because every door into settings — a url,
    /// Command-comma, an Attention row, a Doctor row — goes through it.
    private let presentation: SettingsPresentation
    private let log = AppLog.logger(.app)
    private var transaction: Task<Void, Never>?
    /// The read `fermix://setup` makes before it decides where to land.
    private var setupRouting: Task<Void, Never>?
    /// What the last transaction ended as, so a caller that waited can be told
    /// whether it worked rather than inferring it from the model.
    private var lastOutcome: LifecycleOutcome?

    public init(
        model: AppModel,
        windows: WindowCoordinator,
        voice: any VoiceControlling,
        lifecycle: any DaemonLifecycleControlling,
        bootstrap: @escaping () -> BootstrapCondition,
        termination: any TerminationRequesting,
        settings: SettingsModel,
        presentation: SettingsPresentation
    ) {
        self.model = model
        self.windows = windows
        self.voice = voice
        self.lifecycle = lifecycle
        self.bootstrap = bootstrap
        self.termination = termination
        self.settings = settings
        self.presentation = presentation
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
    /// - Parameter setupState: the daemon's own `setup.state.get` snapshot,
    ///   which is what `fermix://setup` lands on (M34 §3.4). Absent means the
    ///   daemon has not answered, and the assistant's Starting screen owns that.
    nonisolated public static func presentation(
        for reason: LaunchReason,
        bootstrap: BootstrapCondition,
        recovery: RecoveryCondition = .none,
        setupState: ManagementSetupState? = nil
    ) -> AppPresentation {
        if case .login = reason { return .menuBarOnly }
        if case .unreadable = bootstrap { return .assistant(.recovery) }
        if recovery.needsRecovery { return .assistant(.recovery) }

        switch reason {
        case .login:
            return .menuBarOnly
        case .user:
            return bootstrap == .present ? .main(.home) : .assistant(.welcome)
        case .route(.settings(let pane)):
            return .settings(pane)
        case .route(.surface(.recovery)):
            return .assistant(.recovery)
        case .route(.surface(.setup)):
            return SetupRouting.presentation(for: setupState)
        // No Uninstall sheet ships in the first release, so the verb lands on
        // Doctor with one named sentence and the reveal action (M34 §3.1).
        case .route(.surface(.uninstall)):
            return .main(.doctor)
        case .route(.surface(let route)):
            return .main(route)
        }
    }

    public func start(reason: LaunchReason) {
        setupRouting?.cancel()
        noteUninstall(reason)
        present(
            Self.presentation(
                for: reason,
                bootstrap: bootstrap(),
                recovery: recoveryCondition(),
                setupState: settings.setupState.value
            )
        )
    }

    /// The user reopened the app from the Dock, Launchpad or Spotlight.
    ///
    /// The menu bar item is the user's to remove, so this is what keeps the app
    /// reachable without it: with nothing on screen, a reopen opens the window a
    /// user launch would. macOS raises an existing window, whose appearance
    /// task will not run again, so its shared Home state is refreshed here.
    public func reopen() {
        // AppKit counts the floating pet, which is not a way back into Fermix:
        // with the pet showing, the menu bar item hidden and the main window
        // closed, a Launchpad click answered "there is already a window" and
        // did nothing at all.
        guard !windows.isOpen(.main) else {
            readDaemonCondition?()
            return
        }

        start(reason: .user)
    }

    /// Records what a look at the daemon found.
    ///
    /// Home reads `hello` and `overview.get` on every refresh and already holds
    /// the answer; this is what turns that read into the condition the menu bar
    /// glyph and the status line draw. Without it an ordinary launch never
    /// leaves `starting`, because a lifecycle transaction is the only other
    /// thing that speaks here and a launch runs none.
    ///
    /// The most recent answer wins, whichever source it came from. A failed
    /// transaction badges the glyph until the next read says otherwise, and a
    /// read that finds the daemon gone mid-restart says so, because it is true
    /// while it lasts.
    public func daemonObserved(_ observation: DaemonObservation) {
        model.daemon = observation.condition
        model.needsAttention = observation.needsAttention
    }

    /// Handles a `fermix://` url. An unknown one is refused: opening Home
    /// instead would tell the user their command worked.
    public func open(url: URL) throws {
        open(try AppRoute.parse(url))
    }

    /// Opens a parsed destination, which is what a url resolves to.
    public func open(_ destination: AppDestination) {
        setupRouting?.cancel()
        noteUninstall(.route(destination))

        // `fermix://setup` lands on what the daemon reports (M34 §3.4), so it
        // asks. Starting is where the route lands when nothing answers, not
        // where it lands because nothing has been asked yet — which is every
        // cold launch, and is how `fermix setup` on a configured home came to
        // re-run activation.
        guard destination == .surface(.setup) else {
            present(
                Self.presentation(
                    for: .route(destination),
                    bootstrap: bootstrap(),
                    recovery: .none,
                    setupState: settings.setupState.value
                )
            )
            return
        }

        setupRouting = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.settings.refreshSetupState()
            guard !Task.isCancelled else { return }

            self.present(
                Self.presentation(
                    for: .route(destination),
                    bootstrap: self.bootstrap(),
                    recovery: .none,
                    setupState: self.settings.setupState.value
                )
            )
        }
    }

    /// Command-comma. The pane is whichever one the window last showed, which
    /// is restored from user defaults on the first open.
    public func openSettings() {
        open(.settings(settings.selectedPane))
    }

    /// Opens a route the app itself asked for, as onboarding does when its
    /// boot-failure card sends the user to Doctor or Logs.
    /// An explicit request wins over an unresolved recovery record: Doctor and
    /// Logs are exactly what an install in that state needs to reach.
    public func open(_ route: AppRoute) {
        log.log("opening route \(route.rawValue, privacy: .public)")
        open(.surface(route))
    }

    /// Puts the Setup Assistant on screen at one named screen.
    ///
    /// The one way in, so the window, the model's stage and the assistant's own
    /// resume cannot be moved by three different code paths.
    public func openAssistant(at stage: OnboardingStage) {
        setupRouting?.cancel()
        present(.assistant(stage))
    }

    public func enterRecovery() {
        openAssistant(at: .recovery)
    }

    private func present(_ requested: AppPresentation) {
        // Every launch and every route activation compares the daemon in memory
        // with the engine in this bundle before a window draws content
        // (M34 §7.2). Home's own view already reads on appear, so it is the one
        // presentation this does not ask twice for; a cold
        // `fermix://settings/<pane>` never compared build ids at all, and the
        // operator edited settings against the stale engine.
        if requested != .main(.home) { readDaemonCondition?() }

        switch requested {
        case .menuBarOnly:
            // The menu bar is the app. No window opens, so Home's own refresh
            // never runs and nothing else reads the daemon: the read above is
            // what keeps a login launch from drawing `starting` for the whole
            // session against a daemon that has been up for days.
            return
        case .assistant(let stage):
            presentation.leave()
            model.route = stage == .recovery ? .recovery : .setup
            model.onboardingStage = stage
            resumeAssistant?(stage)
            windows.show(.main)
            windows.growForAssistant()
        case .main(let route):
            // A route is a request for a surface of this window, and settings
            // is the other presentation of that same window (decision D1). Any
            // route arriving while settings shows therefore leaves it first:
            // without this the status menu, the View menu and every
            // `fermix://` surface url write a route nobody can see, and the
            // next Back overwrites it with the route entry recorded. The
            // destination is the caller's rather than the recorded one, which
            // is the only thing that separates this from `leaveSettings`.
            presentation.leave()
            model.route = route
            windows.show(.main)
        case .settings(let pane):
            // One window, two presentations (decision D1). The route the user
            // is on is recorded before the window opens, so the back control
            // returns to what they left; a launch straight into settings
            // returns to whatever `AppModel` starts on, which is Home.
            settings.selectedPane = pane
            // The window opens first: entering grows it, and a window that is
            // not on screen yet has no frame to grow.
            windows.show(.main)
            presentation.enter(from: model.route)
        }
    }

    /// Leaves the settings presentation and returns to the surface the user
    /// came from, which is what the toolbar's back control and Escape both do.
    ///
    /// The one implementation of the gesture: the window view calls this rather
    /// than writing the route itself, so a command and a click cannot go two
    /// different places. `present` leaves the same switch for a *stated*
    /// destination, which is the only difference between the two.
    public func leaveSettings() {
        guard presentation.isShowing else { return }

        setupRouting?.cancel()
        model.route = presentation.leave()
    }

    // MARK: - Commands

    /// Releases the GUI's own resources and quits. No daemon lifecycle command
    /// is sent: the background service is a registration, and it survives the
    /// window closing.
    public func quit() {
        voice.shutdown()
        termination.requestTermination()
    }

    /// Asks before restarting (M34 §5.10).
    ///
    /// The command never restarts on the click: the sheet states the daemon's
    /// reasons and how much work a restart would interrupt, and only its own
    /// action takes the transaction. The primary window hosts the sheet, so a
    /// request that arrives from the status item with nothing on screen brings
    /// that window up first rather than restarting silently behind it.
    public func askForRestart() {
        windows.show(.main)
        model.restartSheetShown = true
    }

    /// Shows a set of commands the operator has to run, in the one window that
    /// can host the sheet.
    public func showInstructions(_ instructions: CoexistenceInstructions) {
        windows.show(.main)
        model.instructionsShown = instructions
    }

    /// Restarts the daemon as a journaled lifecycle transaction. Only the
    /// Restart sheet and the assistant's own ladder call it.
    public func restartDaemon() {
        runTransaction { try await self.lifecycle.restartDaemon() }
    }

    /// Shows or clears Doctor's uninstall notice.
    ///
    /// `fermix://uninstall` lands on Doctor with one named sentence while no
    /// Uninstall sheet ships (M34 §3.1), and every other navigation clears it,
    /// so the sentence answers the url that asked for it and never appears on
    /// an ordinary visit.
    public var showUninstallNotice: ((Bool) -> Void)?

    private func noteUninstall(_ reason: LaunchReason) {
        showUninstallNotice?(reason == .route(.surface(.uninstall)))
    }

    /// Moves the assistant to the screen a route named.
    ///
    /// Set by the composition once the assistant's model exists, because that
    /// model is built with this coordinator's own router: the closure is the one
    /// edge of the graph that has to point backwards.
    public var resumeAssistant: ((OnboardingStage) -> Void)?

    /// Reads the daemon on a launch that puts no window on screen.
    ///
    /// Home's shared refresh, used by quiet launches, routes and completed
    /// lifecycle transactions. The composition supplies it after building Home.
    public var readDaemonCondition: (() -> Void)?

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
        model.restartRefusal = nil
        transaction = Task { @MainActor [weak self] in
            defer {
                self?.transaction = nil
                self?.model.transactionInFlight = false
                // Home reads registration through ServiceController, so it
                // needs its own refresh after every outcome, including failure.
                self?.readDaemonCondition?()
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
        lastOutcome = outcome

        switch outcome {
        case .enabled:
            model.daemon = .running
            model.needsAttention = false
        case .disabled:
            model.daemon = .stopped
        case .restarted:
            model.daemon = .running
            model.needsAttention = false
            // Everything the panes show is boot-bound, and this is the one
            // place that knows the restart actually finished.
            Task { await settings.restartCompleted() }
        }
    }

    /// A transaction ended in a failure. The sentence a surface can show is
    /// published where there is one, so a refusal reaches the person who asked
    /// rather than only the log.
    private func transactionFailed(_ error: any Error) {
        lastOutcome = nil
        log.error("lifecycle transaction failed: \(String(describing: error), privacy: .public)")
        model.restartRefusal = (error as? LifecycleFailure)?.sentence
        model.needsAttention = true
    }

    /// Waits for the in-flight transaction, if there is one. The window this
    /// opens is what a test uses to observe a transaction that the UI starts
    /// and forgets.
    public func drainPendingWork() async throws {
        await setupRouting?.value
        await transaction?.value
    }
}

/// The journaled restart, as the Setup Assistant asks for it.
///
/// The assistant decides when a restart runs; this owns how, including the
/// journal and the one-transaction-at-a-time rule.
extension AppCoordinator: DaemonRestarting {
    public func restartDaemonAwaitingCompletion() async -> String? {
        lastOutcome = nil
        restartDaemon()
        await transaction?.value

        guard case .restarted = lastOutcome else {
            return model.restartRefusal ?? ProductStrings[.applyingRestartRefused]
        }

        return nil
    }
}

/// Where `fermix://setup` lands (M34 §3.4).
///
/// A gating readiness failure names the assistant screen that can clear it; a
/// gating failure on a pane the assistant has no screen for opens that pane
/// instead of being folded onto a neighbour. With nothing gating, the first
/// advisory failure's pane wins, and Providers is the default.
public enum SetupRouting {
    public static func presentation(for state: ManagementSetupState?) -> AppPresentation {
        // No answer is not an answer: the daemon has not reported, and Starting
        // is the screen that finds out.
        guard let state else { return .assistant(.starting) }

        if let failure = state.readiness.failures.first(where: \.gating) {
            let gap = OnboardingGap(pane: failure.pane)
            guard let stage = gap.stage else { return settings(for: failure.pane) }

            return .assistant(stage)
        }

        guard let advisory = state.readiness.failures.first else { return .settings(.providers) }

        return settings(for: advisory.pane)
    }

    /// A pane the daemon named that this build does not publish opens Providers,
    /// which is the pane the design names as the default: a url the app cannot
    /// honour exactly still lands somewhere it can be acted on.
    private static func settings(for pane: ManagementSettingsPane) -> AppPresentation {
        .settings(SettingsPane.pane(for: pane) ?? .providers)
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
