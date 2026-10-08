import AppKit
import Combine
import Foundation

/// Home's narrow model.
///
/// It reads three management methods and owns two independent registrations. It
/// never mutates the background service itself: that is a journaled lifecycle
/// transaction, and `AppCoordinator` is the one place that runs one.
@MainActor
public final class HomeModel: ObservableObject {
    @Published public private(set) var snapshot: HomeSnapshot
    /// What an Attention row's action had to say, where it had anything. A
    /// refusal is the daemon's own sentence, shown under the section.
    @Published public private(set) var actionMessage: String?
    /// The two login registrations as macOS last answered. Held rather than
    /// read through, because each read is a slow XPC round trip and the
    /// switches drawing them ask on every redraw (`LoginRegistrations`). It is
    /// read again only where the answer can change: the first refresh after a
    /// lifecycle transaction ends, this app's own Open at login change, and the
    /// app coming to the front, since System Settings is the other writer.
    /// Every route opening refreshes Home, and re-reading on each of those
    /// kept macOS verifying this app's signature twice per click for nothing.
    @Published public private(set) var registrations: LoginRegistrations
    /// Set when a lifecycle transaction ends, which is when this app itself
    /// may have registered or unregistered the agent.
    private var registrationsMayHaveMoved = false

    private let gateway: any DaemonQuerying
    private let services: ServiceController
    private let coordinator: AppCoordinator
    private let updates: any UpdateChecking
    /// The one settings model (M34 §8). Home reads the shared
    /// `setup.state.get` snapshot from it rather than making a second read of
    /// its own, which is what keeps Home and the Settings window from showing
    /// two different answers to the same question.
    private let settings: SettingsModel
    /// The launch reconcile (M34 §7.2). It runs on every refresh, not only at
    /// launch, because replacing the bundle while the app is open is exactly the
    /// case it exists for.
    private let reconciler: EngineReconciler
    /// The status item, so the Background section can take Fermix off the menu
    /// bar and put it back. It is read through rather than mirrored: macOS owns
    /// the answer, and a copy here would drift the moment somebody
    /// Command-dragged the item off the bar.
    private let menuBar: any MenuBarItemPresenting
    /// The removal commands for a service Fermix did not install, where this Mac
    /// has one (M34 §15.2). A closure because the answer is a fact about the
    /// machine — the unit's scope and whether a verb-capable `fermix` is on
    /// PATH — that the composition already knows how to read.
    private let instructions: () -> CoexistenceInstructions?
    /// Shows the settings file in the Finder. The one implementation lives on
    /// `DoctorModel`, which owns the reveal seam; this is that one, not a
    /// second.
    private let revealSettingsFile: () -> Void
    /// The coordinator's transaction as it starts and ends. Home reads that fact
    /// through rather than holding a copy, so this is only what tells the view
    /// to read it again.
    private var transactionChanges: AnyCancellable?
    /// The refresh in flight, and whether someone asked for another while it
    /// ran. Home appearing, every other route opening and every finished
    /// transaction all ask, so quick clicks used to stack a full set of daemon
    /// reads per click. Now one runs at a time, and a request that arrives
    /// during it gets one more read that starts after it asked.
    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    /// The app coming to the front, which is when a change made in System
    /// Settings, the registrations' other writer, can first be seen.
    private var activations: AnyCancellable?
    /// A settings write the daemon accepted, which can be the one that set
    /// voice up (M56 §4.1).
    private var settingsSaves: AnyCancellable?
    /// A call the daemon refused, which is the freshest word there is about
    /// voice readiness (M56 §4.1).
    private var callRefusals: AnyCancellable?
    /// The check two minutes after each read, which reads again while a call
    /// control is on screen.
    private let deadlines: any DeadlineScheduling
    private var voiceReadinessCheck: DeadlineToken?
    private let log = AppLog.logger(.app)

    /// How old voice readiness may grow while a call control is on screen
    /// (M56 §4.1). The overview is otherwise read on no clock at all.
    static let voiceReadinessInterval: TimeInterval = 120

    /// What the reconcile last found, read back from the one model that owns it
    /// (M34 §8). Home is the surface that reads `hello`, so Home is what writes
    /// it; the status item, the Restart sheet and the Settings banner all read
    /// this same answer rather than each holding one of their own.
    public var engineReconcile: EngineReconcileOutcome { settings.engineReconcile.builds }

    public init(
        gateway: any DaemonQuerying,
        services: ServiceController,
        coordinator: AppCoordinator,
        updates: any UpdateChecking,
        settings: SettingsModel,
        reconciler: EngineReconciler,
        menuBar: any MenuBarItemPresenting,
        call: VoiceCallModel,
        deadlines: any DeadlineScheduling,
        instructions: @escaping () -> CoexistenceInstructions? = { nil },
        revealSettingsFile: @escaping () -> Void = {}
    ) {
        self.gateway = gateway
        self.services = services
        self.coordinator = coordinator
        self.updates = updates
        self.settings = settings
        self.reconciler = reconciler
        self.menuBar = menuBar
        self.deadlines = deadlines
        self.instructions = instructions
        self.revealSettingsFile = revealSettingsFile
        // Nothing has been read yet, so Attention says that rather than drawing
        // the empty state, which would claim the daemon reported no gaps.
        self.snapshot = HomeSnapshot.unreachable(
            attention: .unavailable(ProductStrings[.homeAttentionUnread])
        )
        // Once, before the first draw, so the switches never open on a guess.
        self.registrations = LoginRegistrations(agent: services.status(.agent), mainApp: services.status(.mainApp))
        self.transactionChanges = coordinator.transactionChanges.dropFirst().sink { [weak self] transaction in
            if transaction == nil { self?.registrationsMayHaveMoved = true }
            self?.objectWillChange.send()
        }
        self.activations = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.refreshRegistrations() }
            }
        self.settingsSaves = settings.saves.sink { [weak self] in
            Task { await self?.refresh() }
        }
        self.callRefusals = call.$voice
            .map { Self.refusedByTheDaemon($0.phase) }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    /// Whether a call ended on a failure the daemon named. A failure this Mac
    /// raised, the microphone or a socket that never answered, carries no
    /// kind and says nothing about voice readiness.
    private static func refusedByTheDaemon(_ phase: VoiceCallPhase) -> Bool {
        guard case .ended(.failed(_?, _)) = phase else { return false }

        return true
    }

    /// Whether the GUI opens at login. Independent of the background service in
    /// both directions: two registrations, two consents.
    public var openAtLogin: Bool {
        registrations.mainApp == .enabled
    }

    public var backgroundServiceEnabled: Bool {
        registrations.agent == .enabled
    }

    /// The section Home draws: the daemon's own, led by the held item's row
    /// while macOS is holding the background item for the person. Whether it
    /// was held by setup, by the switch below, or switched off in System
    /// Settings since, it is the same fact and the same row.
    public var attention: AttentionSection {
        guard registrations.agent == .requiresApproval else { return snapshot.attention }

        return snapshot.attention.led(by: .backgroundApproval)
    }

    /// Whether Fermix shows a menu bar item. Independent of both registrations:
    /// hiding the item changes nothing about what runs.
    public var menuBarItemShown: Bool {
        menuBar.menuBarItemShown
    }

    public var transactionInFlight: Bool {
        coordinator.isRunningTransaction
    }

    /// What the Status row says: the transaction this app is running, where it
    /// is running one, and the daemon's last answer otherwise.
    public var status: HomeStatus {
        HomeStatus(transaction: coordinator.transactionInFlight, snapshot: snapshot)
    }

    /// The one sentence under the Attention section: an Attention row's own
    /// refusal, or what the last background-service transaction refused with.
    ///
    /// Read through the coordinator, exactly as the in-flight flag is: the
    /// transaction is the coordinator's and a copy kept here would drift from
    /// it. Home's own refresh runs after every outcome, which is what redraws
    /// this.
    public var attentionMessage: String? {
        actionMessage ?? coordinator.transactionRefusal
    }

    public func refresh() async {
        guard let refreshing else {
            let task = Task { await refreshUntilSettled() }
            self.refreshing = task
            await task.value
            return
        }

        refreshAgain = true
        await refreshing.value
    }

    private func refreshUntilSettled() async {
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
        refreshing = nil
    }

    private func refreshOnce() async {
        let update = updates.availability()
        let read = await read(update: update)
        // Published only where it moved: an unchanged answer redrew Home and
        // everything observing it on every refresh.
        if read != snapshot { snapshot = read }
        if registrationsMayHaveMoved {
            registrationsMayHaveMoved = false
            await refreshRegistrations()
        }
        // This is the only read of the daemon an ordinary launch makes, so it
        // is also what moves the menu bar glyph and the status line off
        // "starting". The coordinator owns the write; Home only reports what it
        // just saw.
        coordinator.daemonObserved(DaemonObservation(snapshot: snapshot))
        scheduleVoiceReadinessCheck()
    }

    /// Arms the check two minutes from this read, replacing the last one, so
    /// readiness on a call control's screen is never older than that whatever
    /// read came before.
    private func scheduleVoiceReadinessCheck() {
        voiceReadinessCheck?.cancel()
        voiceReadinessCheck = deadlines.schedule(after: Self.voiceReadinessInterval) { [weak self] in
            self?.voiceReadinessCheckDue()
        }
    }

    /// Reads while a call control is on screen. With none showing it only
    /// looks again later: a call control coming back on screen is not an
    /// event every surface reports, but it is one this check will find.
    private func voiceReadinessCheckDue() {
        voiceReadinessCheck = nil
        guard coordinator.showsCallControl else {
            scheduleVoiceReadinessCheck()
            return
        }

        Task { await refresh() }
    }

    /// Reads both registrations off the main thread, and publishes only a
    /// change: an unchanged answer redrawing Home is the cost this avoids.
    ///
    /// An agent macOS has just allowed is a daemon launchd is starting, and
    /// Home has no poll of its own to find it, so that change reads the daemon
    /// too. A refresh already running reads it once more rather than being
    /// awaited from inside itself, which is where this is called from.
    public func refreshRegistrations() async {
        let current = await services.registrations()
        guard current != registrations else { return }

        let allowed = registrations.agent == .requiresApproval && current.agent == .enabled
        registrations = current
        guard allowed else { return }

        if refreshing == nil {
            Task { await refresh() }
        } else {
            refreshAgain = true
        }
    }

    private func read(update: UpdateAvailability) async -> HomeSnapshot {
        do {
            let hello = try await gateway.negotiate()
            let overview = try await gateway.overview()
            settings.noteEngineBuilds(reconciler.reconcile(hello: hello))

            // `attention()` refreshes the shared setup state, so it is read
            // after that call and never before: the provider label the Runtime
            // row shows is the one this poll just saw.
            let attention = await attention(update: update)

            let setup = settings.setupState.value

            return HomeSnapshot(
                hello: hello,
                overview: overview,
                attention: attention,
                update: update,
                setup: setup,
                names: setup.map(names(for:)) ?? .unread
            )
        } catch {
            settings.noteEngineBuilds(.daemonUnreachable)
            let sentence = ManagementMessage.sentence(for: error)
            log.error("home could not read the daemon: \(sentence, privacy: .public)")
            // The refusal is the only thing Home knows, so Attention carries it.
            // An empty section here would read as "nothing is wrong" under a
            // header that just said the daemon cannot be reached.
            return HomeSnapshot.unreachable(attention: .unavailable(sentence))
        }
    }

    /// The Attention section, which is protocol v2's alone. Against a daemon
    /// one release behind it is a named state, never an error and never an
    /// empty list that would read as "nothing is wrong" (M34 §7.1).
    ///
    /// The read is the shared model's, so Home's poll is also what keeps the
    /// Settings window current.
    /// - Parameter update: the answer this refresh already took from the update
    ///   seam. It is passed rather than asked for again: two reads inside one
    ///   refresh can disagree, and the card and the row would then say
    ///   different things about the same check.
    private func attention(update: UpdateAvailability) async -> AttentionSection {
        await settings.refreshSetupState()
        // The section index names the channels a gap can be about. It is boot
        // bound, so it is read once and then left alone.
        if settings.inventory.value == nil { await settings.loadInventory() }

        // The reconcile's row leads: an engine the operator has already replaced
        // on disk is the reason every other row may be reporting a stale world.
        // The update row sits with it, so an offered or staged update reaches
        // the menu bar mark through the same section Home draws (M34 §6, R2).
        let engine = EngineReconcilePresentation.attentionRow(for: engineReconcile)
        let offered = UpdatePresentation.attentionRow(for: update)
        let pending = [engine, offered].compactMap { $0 }

        switch settings.setupState {
        case .loaded(let state):
            return .rows(pending + AttentionProjection.rows(for: state, names: names(for: state)))
        // Which of the two the refusal is: a bundle that ships a newer engine
        // takes the restart, and a bundle whose own engine is the one refusing
        // takes nothing (M34 §7.1, §7.2).
        case .requiresNewerEngine:
            return settings.engineReconcile.isFinishingUpdate ? .requiresNewerEngine : .engineBehindApp
        case .unavailable(let sentence) where !pending.isEmpty:
            log.error("setup state refused: \(sentence, privacy: .public)")
            return .rows(pending)
        case .unavailable(let sentence):
            log.error("setup state refused: \(sentence, privacy: .public)")
            return .unavailable(sentence)
        case .unread, .loading:
            return .unavailable(ProductStrings[.homeAttentionUnread])
        }
    }

    /// The product's own names for the ids a gap carries: provider labels off
    /// the same snapshot, and channel titles off the section index the Settings
    /// window reads. The index is read once per launch, because without it a row
    /// says `Connect openai_codex` (M34 §3.2).
    private func names(for state: ManagementSetupState) -> AttentionNames {
        AttentionNames(state: state, sections: settings.inventory.value ?? [])
    }

    // MARK: - Actions

    /// Whether the sheet the Attention row opens is the one that finishes an
    /// update, which is what gives it the `Finish updating Fermix` title. Both
    /// facts that can make it so are on the one value (M34 §7.1, §7.2).
    public var isFinishingUpdate: Bool { settings.engineReconcile.isFinishingUpdate }

    /// What the Update surface states (M34 §3.4, decision 12): the engine
    /// answering now, the one this copy of Fermix ships, and whatever the update
    /// seam last reported.
    public var updateSurface: UpdateSurfaceModel {
        UpdateSurfaceModel(
            running: snapshot.engineVersion,
            bundled: reconciler.bundledVersion,
            summary: snapshot.updateSummary
        )
    }

    /// What Home's toolbar needs to know right now (M34 §3.2): the daemon's own
    /// readiness, and what the launch reconcile found.
    public var toolbarCondition: ToolbarCondition {
        ToolbarCondition(
            setupComplete: snapshot.setupComplete,
            reconcilePending: engineReconcile.isPending
        )
    }

    /// The one action an Attention row carries, where it carries one.
    public func perform(_ action: AttentionAction) {
        actionMessage = nil

        switch action {
        // The one Restart sheet, owned by the coordinator, so an Attention row,
        // the Daemon menu and the status item all ask through one door
        // (M34 §5.10).
        case .restartDaemon:
            coordinator.askForRestart()
        case .reloadSettings:
            Task { await reloadSettings() }
        case .openSettings(let pane):
            // The one door into settings, so an Attention row, Command-comma
            // and a url all enter the same presentation (decision D1).
            coordinator.open(.settings(pane))
        case .showInstructions:
            showInstructions()
        case .revealSettingsFile:
            revealSettingsFile()
        // The updater's own alert owns Install, Remind Later and Skip
        // (M34 §6). Asking for a check is what raises it, and what brings one
        // that is already showing back into focus.
        case .showUpdate:
            updates.checkForUpdates()
        case .openLoginItems:
            services.openLoginItemsSettings()
        }
    }

    /// Opens the removal sheet. A Mac with no such unit any more has nothing to
    /// show, and the row says so rather than opening an empty sheet.
    private func showInstructions() {
        guard let found = instructions() else {
            log.log("no coexistence instructions to show: nothing is installed")
            actionMessage = ProductStrings[.coexistenceUnavailable]
            return
        }

        coordinator.showInstructions(found)
    }

    /// Re-reads the settings file the daemon refused to write over. The daemon
    /// re-records its own baseline, which is what lets the next write succeed.
    private func reloadSettings() async {
        guard let sentence = await settings.reloadFromDisk() else {
            await refresh()
            return
        }

        actionMessage = sentence
    }

    /// Enable or disable the background service. The verb is never start or
    /// stop: registration is the durable state, and the transaction is
    /// journaled by the lifecycle coordinator.
    ///
    /// Home sets the state it wants rather than toggling, because a switch and
    /// a menu row can disagree about what "the other one" is while a
    /// transaction is in flight.
    public func setBackgroundService(_ enabled: Bool) {
        coordinator.setBackgroundService(enabled: enabled)
    }

    /// Shows or hides the menu bar item. macOS remembers the answer under the
    /// item's autosave name, so nothing is written here.
    ///
    /// The switch is not republished here either: the item reports every change
    /// to its own visibility through `menuBarItemVisibilityChanged`, and one
    /// notice for both this write and a Command-drag off the bar is what stops
    /// the two from drifting.
    public func setMenuBarItemShown(_ shown: Bool) {
        menuBar.setMenuBarItemShown(shown)
    }

    /// The item went on or off the bar. Nothing is stored — the switch reads
    /// through to the item — so the view only has to be told to read it again.
    public func menuBarItemVisibilityChanged() {
        objectWillChange.send()
    }

    /// The GUI's own login registration. Turning it off never touches the
    /// daemon's.
    public func setOpenAtLogin(_ enabled: Bool) {
        do {
            try enabled ? services.enable(.mainApp) : services.disable(.mainApp)
        } catch {
            log.error("the GUI login item could not be changed: \(String(describing: error), privacy: .public)")
        }
        // Read here rather than on the next refresh, and published even when
        // unchanged, so a refused change puts the switch straight back.
        registrations.mainApp = services.status(.mainApp)
    }
}

/// Where voice readiness is read: the one overview reader (M56 §4.1).
///
/// A seam rather than the reader itself, so the call control and the surfaces
/// that draw it are provable without a daemon behind them.
@MainActor
public protocol VoiceReadinessReading: AnyObject {
    /// What the last overview said about voice.
    var voiceReadiness: VoiceReadiness { get }
    /// That value each time it moves, for a surface that draws it.
    var voiceReadinessChanges: AnyPublisher<VoiceReadiness, Never> { get }
}

/// Home is the one overview reader, so it is where voice readiness is read
/// (M56 §4.1): the same snapshot, never a second read.
extension HomeModel: VoiceReadinessReading {
    public var voiceReadiness: VoiceReadiness { snapshot.voiceReadiness }

    public var voiceReadinessChanges: AnyPublisher<VoiceReadiness, Never> {
        $snapshot.map(\.voiceReadiness).removeDuplicates().dropFirst().eraseToAnyPublisher()
    }
}
