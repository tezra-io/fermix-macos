import AppKit
import Foundation

/// Quitting, behind a seam. `NSApp.terminate` is the one thing a test must
/// never actually do.
@MainActor
public protocol TerminationRequesting: AnyObject {
    /// Asks macOS to quit, which is what routes the app's own Quit through the
    /// same `applicationShouldTerminate` hook the Dock and a log out reach.
    func requestTermination()
    /// Answers a termination this app asked AppKit to hold, once the work that
    /// had to happen first has happened.
    func completeTermination()
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

/// What the two recovery journals say about the last transaction.
public enum RecoveryCondition: Equatable, Sendable {
    case none
    /// A lifecycle transaction stopped part-way and left its record behind.
    case interrupted(kind: LifecycleTransactionKind, phase: LifecyclePhase)
    /// The record exists but cannot be read, which is itself a broken install.
    case journalUnreadable
    /// An update did not finish and the launch reconcile found no safe step
    /// left to take (M34 §6). It is the same door as the other two, so a launch
    /// or a route cannot land on ordinary UI while it stands.
    case updateFailed(UpdateRecoveryReason)

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
    /// The one launch reconcile (M34 §6, R4). Every launch and every route asks
    /// it, and nothing else compares an update transaction with the machine.
    private let updates: any UpdateReconciling
    private let bootstrap: () -> BootstrapCondition
    private let termination: any TerminationRequesting
    /// The one settings model, so opening a pane by url and opening it from the
    /// sidebar write the same selection.
    private let settings: SettingsModel
    /// Whether the primary window is showing settings (decision D1). The
    /// coordinator owns entering, because every door into settings — a url,
    /// Command-comma, an Attention row, a Doctor row — goes through it.
    private let presentation: SettingsPresentation
    /// The one lock over everything that can change the background service
    /// (M34 §6, R3). The lifecycle transactions, the launch reconcile and the
    /// update transaction all take it, so two of them can never mutate the
    /// account at once.
    private let gate: ServiceMutationGate
    private let log = AppLog.logger(.app)
    private var transaction: Task<Void, Never>?
    /// The quit in flight. Quitting can have work to finish first, so it is a
    /// task rather than a call, and one quit is enough.
    private var quitting: Task<Void, Never>?
    /// The read `fermix://setup` makes before it decides where to land.
    private var setupRouting: Task<Void, Never>?
    /// The launch reconcile in flight. One at a time: it can re-register the
    /// background service, and two of those racing is the thing the journals
    /// exist to prevent.
    private var updateReconcile: Task<Void, Never>?
    /// What the last reconcile found, where it found no safe step left. It is
    /// read by the recovery condition, so a later launch or route lands on
    /// Recovery too rather than on ordinary UI.
    public private(set) var updateRecovery: UpdateRecoveryReport?
    /// What the last transaction ended as, so a caller that waited can be told
    /// whether it worked rather than inferring it from the model.
    private var lastOutcome: LifecycleOutcome?

    public init(
        model: AppModel,
        windows: WindowCoordinator,
        voice: any VoiceControlling,
        lifecycle: any DaemonLifecycleControlling,
        updates: any UpdateReconciling,
        gate: ServiceMutationGate,
        bootstrap: @escaping () -> BootstrapCondition,
        termination: any TerminationRequesting,
        settings: SettingsModel,
        presentation: SettingsPresentation
    ) {
        self.model = model
        self.windows = windows
        self.voice = voice
        self.lifecycle = lifecycle
        self.updates = updates
        self.gate = gate
        self.bootstrap = bootstrap
        self.termination = termination
        self.settings = settings
        self.presentation = presentation
    }

    /// What the recovery journal says about the last transaction. A journal that
    /// cannot be read is itself a reason to open Recovery: it is the one file
    /// that would have said what happened.
    private func recoveryCondition() -> RecoveryCondition {
        // The update record is read first because it is the one that can be
        // outstanding while the lifecycle journal is clean: the update's own
        // registration steps run through lifecycle transactions, which clear
        // their record on the way out.
        if let updateRecovery { return .updateFailed(updateRecovery.reason) }

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

    /// Try again on an update that did not finish (M34 §6, R4).
    ///
    /// Activation is not the way out of this one: the record belongs to the
    /// update, and the only thing that resolves it is the reconcile looking at
    /// the machine again — which is what a restart, a reinstall or a daemon
    /// quitting in between will have changed. So this re-runs the launch.
    ///
    /// A record that cannot be read is the one reason a second look would
    /// answer identically, so the file goes first. It is the only place the
    /// unreadable record is discarded: the reconcile keeps it, because it is
    /// the evidence, until the person on this screen asks for the install back.
    public func retryUpdateRecovery() {
        guard updateRecovery?.reason == .journalUnusable else {
            start(reason: .user)
            return
        }

        do {
            try updates.discardUnusableRecord()
        } catch {
            log.error(
                "the unreadable update record could not be discarded: \(String(describing: error), privacy: .public)"
            )
            return
        }

        start(reason: .user)
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
        setupRouting = nil
        let previous = updateReconcile
        let lifecycle = transaction
        let requested: AppDestination?
        if case .route(let destination) = reason { requested = destination } else { requested = nil }
        model.pendingNavigation = requested
        updateReconcile = Task { @MainActor [weak self] in
            await previous?.value
            await lifecycle?.value
            guard let self else { return }
            defer {
                if self.model.pendingNavigation == requested { self.model.pendingNavigation = nil }
            }

            self.setupRouting?.cancel()
            self.setupRouting = nil
            await self.reconcileUpdate()
            self.presentLaunch(reason)
        }
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
        start(reason: .route(destination))
    }

    private func presentLaunch(_ reason: LaunchReason) {
        noteUninstall(reason)
        // Recovery's Doctor button remains usable after the record has been
        // checked. Other destinations cannot bypass an unfinished update.
        let recovery = reason == .route(.surface(.doctor)) ? RecoveryCondition.none : recoveryCondition()
        if updateRecovery != nil, recovery.needsRecovery {
            enterRecovery()
            return
        }

        // `fermix://setup` lands on what the daemon reports (M34 §3.4), so it
        // asks. Starting is where the route lands when nothing answers, not
        // where it lands because nothing has been asked yet — which is every
        // cold launch, and is how `fermix setup` on a configured home came to
        // re-run activation.
        guard reason == .route(.surface(.setup)) else {
            present(
                Self.presentation(
                    for: reason,
                    bootstrap: bootstrap(),
                    recovery: recovery,
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
                    for: reason,
                    bootstrap: self.bootstrap(),
                    recovery: self.recoveryCondition(),
                    setupState: self.settings.setupState.value
                )
            )
        }
    }

    /// Command-comma. The pane is whichever one the window last showed, which
    /// is restored from user defaults on the first open.
    public func openSettings() {
        navigate(to: .settings(settings.selectedPane))
    }

    /// Opens a route the app itself asked for, as onboarding does when its
    /// boot-failure card sends the user to Doctor or Logs.
    /// An explicit request wins over an unresolved recovery record: Doctor and
    /// Logs are exactly what an install in that state needs to reach.
    public func open(_ route: AppRoute) {
        log.log("opening route \(route.rawValue, privacy: .public)")
        navigate(to: .surface(route))
    }

    /// Moves the window the app already has open to another of its surfaces.
    ///
    /// Navigation inside a running app is not a launch, so it runs no reconcile
    /// (M34 §6, R4): the record has been read, and reading it again per click
    /// would re-run a restore, a bounded verify and a disable with every
    /// control on screen disabled while it went. It still goes through
    /// `presentLaunch`, so a standing recovery condition and the Doctor
    /// exemption are the same ones a launch honours.
    private func navigate(to destination: AppDestination) {
        setupRouting?.cancel()
        setupRouting = nil
        presentLaunch(.route(destination))
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

    /// Releases the GUI's own resources and asks macOS to quit. No daemon
    /// lifecycle command is sent: the background service is a registration, and
    /// it survives the window closing.
    ///
    /// The request goes to AppKit rather than straight to the work, so the app's
    /// own Quit lands in `applicationShouldTerminate` exactly as the Dock's
    /// Quit, an AppleScript quit and a log out do. That is the whole point of
    /// routing it: there is one barrier, and a staged update's stop is spent on
    /// every exit rather than only on the one the menu bar can reach.
    public func quit() {
        voice.shutdown()
        termination.requestTermination()
    }

    /// macOS is about to end this process, however it was asked.
    ///
    /// From the moment an update is staged, any exit replaces the bundle with no
    /// call back into this process — so an exit taken while the engine is still
    /// up is the exact case M34 §6 forbids, and this is the last bounded chance
    /// to stop it. It cannot be refused into safety, because a force quit
    /// reaches the same installer without asking, so termination is held rather
    /// than declined and is answered as soon as the work is done.
    ///
    /// - Returns: `.terminateLater` always. A second request arriving while the
    ///   first is finishing joins it rather than starting a second one: the
    ///   reply the in-flight work sends is the reply to both.
    public func terminationRequested() -> NSApplication.TerminateReply {
        guard quitting == nil else {
            log.log("a quit is already finishing, so this request waits for the same work")
            return .terminateLater
        }

        quitting = Task { @MainActor [weak self] in
            await self?.prepareForQuit?()
            self?.termination.completeTermination()
        }

        return .terminateLater
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

    /// What a quit has to finish before the process ends, where anything does.
    ///
    /// Set by the composition once the update transaction exists, because that
    /// transaction is built over this coordinator's own lifecycle owner: the
    /// closure is the backwards edge, exactly as the two below are.
    public var prepareForQuit: (() async -> Void)?

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

    /// Whether anything is changing the background service right now, or is
    /// waiting to, which is what a surface disables its own controls on.
    ///
    /// Two facts, one question: the gate says something owns the service, and
    /// the task says a request of the person's is still in flight behind it. A
    /// staged update holds the gate until the bundle is replaced, which is
    /// exactly right — nothing else may register or restart the agent under a
    /// bundle about to be swapped.
    public var isRunningTransaction: Bool { gate.isHeld || transaction != nil }

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
        // The launch reconcile can re-register the service, and it runs on
        // every launch and every route. A transaction the person asked for
        // while it is in flight therefore waits for it rather than racing it or
        // vanishing. It is the one owner a lifecycle action ever waits behind:
        // an update transaction is refused instead, because that one ends by
        // replacing this process.
        let reconcile = updateReconcile
        transaction = Task { @MainActor [weak self, gate] in
            await reconcile?.value

            defer {
                self?.transaction = nil
                self?.model.transactionInFlight = false
                // Home reads registration through ServiceController, so it
                // needs its own refresh after every outcome, including failure.
                self?.readDaemonCondition?()
            }

            guard gate.acquire(.lifecycle) else {
                self?.refuseTransaction()
                return
            }
            defer { gate.release(.lifecycle) }

            do {
                let outcome = try await work()
                self?.apply(outcome)
            } catch {
                self?.transactionFailed(error)
            }
        }
    }

    /// Another owner holds the service, so the transaction never ran and
    /// nothing was changed. The person asked for it, so the refusal reaches the
    /// screen rather than only the log.
    private func refuseTransaction() {
        log.error("\(self.gate.holder?.rawValue ?? "another owner", privacy: .public) holds the service")
        lastOutcome = nil
        model.restartRefusal = ProductStrings[.lifecycleServiceBusy]
        model.needsAttention = true
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

    // MARK: - The launch reconcile

    /// Reconciles the update record before ordinary UI, on the paths a launch
    /// arrives through and on no others.
    ///
    /// Those paths are `start(reason:)` for a login and a user launch,
    /// `reopen()`, and `open(_ destination:)` as the AppKit url handler calls
    /// it, so a login launch, a manual launch, a `fermix://` route and the
    /// relaunch after a replacement all run this one owner. Navigation the app
    /// performs for itself — `openSettings()` and `open(_ route:)` — does not:
    /// it goes through `navigate(to:)` straight to the presentation, because
    /// the record has already been read this launch and the reconcile is a
    /// restore, a bounded verify and a disable.
    ///
    /// The work is a task rather than a wait because it can re-register the
    /// background service and prove an engine, which is seconds of bounded
    /// polling. Launch tasks preserve navigation order and wait for this before
    /// presenting their destination.
    private func reconcileUpdate() async {
        guard gate.acquire(.reconcile) else {
            noteReconcileWasNotRun()
            return
        }
        defer { gate.release(.reconcile) }

        do {
            apply(try await updates.reconcile())
        } catch {
            log.error("the update reconcile stopped: \(String(describing: error), privacy: .public)")
            updateRecovery = UpdateRecoveryReport(reason: .reconcileInterrupted, entry: nil)
        }
    }

    /// Says why a launch reconciled nothing. It never stops the presentation:
    /// a launch that puts nothing on screen is the one outcome worse than a
    /// record read a moment late.
    ///
    /// The update transaction holding the gate is the ordinary case rather than
    /// a fault. It is live in this very process and holds the record it wrote,
    /// so there is nothing on disk for a second reader to resolve.
    private func noteReconcileWasNotRun() {
        guard gate.holder != .update else {
            log.log("an update transaction is running here, so this launch has no record to reconcile")
            return
        }

        log.error(
            "\(self.gate.holder?.rawValue ?? "another owner", privacy: .public) holds the service, so no record was read"
        )
    }

    /// What the reconcile found. Only the recovery outcome puts anything on
    /// screen: the pending restart is already drawn by the Attention row and
    /// the status line, which read the same engine comparison.
    private func apply(_ outcome: UpdateReconcileOutcome) {
        guard case .recovery(let report) = outcome else {
            updateRecovery = nil
            return
        }

        log.error("an update did not finish: \(report.reason.rawValue, privacy: .public)")
        updateRecovery = report
        model.needsAttention = true
    }

    /// Waits for the in-flight transaction, if there is one. The window this
    /// opens is what a test uses to observe a transaction that the UI starts
    /// and forgets.
    public func drainPendingWork() async throws {
        await updateReconcile?.value
        await setupRouting?.value
        await transaction?.value
        await quitting?.value
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
