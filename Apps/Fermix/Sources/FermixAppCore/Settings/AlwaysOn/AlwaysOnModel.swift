import Foundation

/// Raises the system's own notifications for Always On. `MacNotifications`
/// is the one in the app.
@MainActor
public protocol AlwaysOnNotifying: AnyObject {
    func post(_ notification: MacNotification) async -> NotificationPostOutcome
}

extension MacNotifications: AlwaysOnNotifying {}

/// The Always On pane's reads and writes (M75 lean v1 §7).
///
/// `home.status.summary` is the one source: every screen, sentence and action
/// label is the engine's, and every write is followed by a read of it rather
/// than by a guess at what changed. This owns when each call is made, the few
/// steps the app keeps itself (`AlwaysOnLocal`), and the follow that reads the
/// summary while the app runs, which is where the notifications come from.
@MainActor
public final class AlwaysOnModel: ObservableObject {
    /// The last `home.status` the daemon answered, kept while a later read
    /// fails.
    @Published public private(set) var status: ManagementHomeStatus?
    /// The last read's refusal, while it is the latest word.
    @Published public private(set) var readFailure: SettingsReadState<ManagementHomeStatus>?
    /// The methods the daemon's `hello` lists, of the ones this build models.
    @Published public private(set) var served: Set<ManagementMethod> = []
    @Published public internal(set) var local = AlwaysOnLocal()
    /// What Hetzner sells, read for Create server, Change and Replace.
    @Published public internal(set) var options: SettingsReadState<ManagementProvisionOptions> = .unread
    /// The size and location the owner chose; the recommendation until then.
    @Published public internal(set) var chosen: ManagementProvisionPick?
    /// The action on its way, which holds the screen's buttons.
    @Published public internal(set) var working: ManagementHomeActionId?
    /// The daemon's refusal of the last action, said under it.
    @Published public internal(set) var refusal: String?
    /// A word that is no failure: a move's start whose answer was lost.
    @Published public internal(set) var notice: String?
    @Published public internal(set) var checkingToken = false
    @Published public internal(set) var tokenRefusal: String?
    @Published public internal(set) var settingPassphrase = false
    @Published public internal(set) var passphraseRefusal: String?
    /// The warnings and blocks of the last review this app asked for, which
    /// the ready screen lists where the summary carries none: during a
    /// replace the review is the old server's own, and the summary never
    /// lists it.
    @Published public internal(set) var reviewed: [ManagementReadinessItem] = []
    /// Move now waits for the recovery passphrase, which a sheet asks for.
    @Published public internal(set) var asksMovePassphrase = false
    /// Replace the server's sheet is up.
    @Published public internal(set) var replacing = false
    /// The code for a server of the owner's own, shown once, while the pane
    /// shows it.
    @Published public internal(set) var handout: ManagementEnrollmentCode?
    @Published public internal(set) var gettingCode = false
    @Published public internal(set) var codeRefusal: String?

    /// The app's own update, which the composition hands over: Update's one
    /// action is not the engine's.
    public var checkForUpdates: (() -> Void)?
    /// Where the notifications go. Handed in by the composition, which builds
    /// the app's one `MacNotifications` before this model's owner.
    public weak var notifier: (any AlwaysOnNotifying)?

    /// The one settings model, which owns the gateway, the opener and the
    /// restart this model re-reads after. It owns this model, so it outlives
    /// it.
    unowned let settings: SettingsModel
    let sleeper: any Sleeping
    let now: @Sendable () -> Date
    let log = AppLog.logger(.app)

    /// The recovery passphrase the owner typed for this move, held only until
    /// the move starts: `home.move.start` takes it again, and the engine
    /// never stores it.
    var passphrase: String?

    /// The last answered read, which the next one is compared with.
    private var last: AlwaysOnReading?
    /// The reads in order: each waits for the one before it.
    private var reading: Task<Void, Never>?
    private var deadlines: (any DeadlineScheduling)?
    private var nextRead: (any DeadlineToken)?
    private var paneVisible = false
    /// Reads answered since this app's own move started, which bounds how
    /// long the pane says it is moving before the engine says so itself.
    private var ownMoveReads = 0
    /// The engine answered after the restart this app's own move took, so
    /// everything Settings shows is read again once the read that saw it is
    /// done.
    private var restartSeen = false

    /// How many answered reads the app's own moving screen outlasts the
    /// engine's silence on it: about ten minutes at the brisk cadence.
    static let ownMoveBound = 200

    public init(settings: SettingsModel, sleeper: any Sleeping, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.sleeper = sleeper
        self.now = now
    }

    var gateway: any DaemonQuerying { settings.gateway }

    /// What the pane shows.
    public var page: AlwaysOnPage {
        AlwaysOnPage.page(status: status, failure: readFailure, local: local, served: served)
    }

    /// The Hetzner path is drawn only where every provisioner method is
    /// listed.
    public var servesHetzner: Bool { served.isSuperset(of: ManagementMethod.homeProvisionMethods) }

    // MARK: - The pane

    /// The pane appeared: it reads now, and the follow reads briskly while it
    /// shows. A screen whose summary rests on the provisioner's record reads
    /// that record back from Hetzner first, so Hetzner's power and a server
    /// deleted outside Fermix show.
    public func paneAppeared() async {
        paneVisible = true
        if served.isEmpty { await readServed() }
        await refresh()
        if needsReconcile { await reconcile() }
        if status?.summary?.state == .choose { await readOptions() }
        schedule()
    }

    /// The pane went: the code it showed leaves memory with it.
    public func paneDisappeared() {
        paneVisible = false
        handout = nil
        schedule()
    }

    // MARK: - The follow

    /// Reads the summary now, and from then on at `AlwaysOnCadence`'s pace
    /// for as long as the app runs, each read on a deadline of its own. The
    /// composition starts it once, at launch.
    public func follow(with deadlines: any DeadlineScheduling) async {
        precondition(self.deadlines == nil, "the summary is followed once")

        self.deadlines = deadlines
        await tick()
    }

    /// One read of the follow, and the deadline of the next.
    func tick() async {
        if served.isEmpty { await readServed() }
        if served.contains(.homeStatus) { await refresh() }
        schedule()
    }

    /// The wait before the next read, as the last read leaves it. Until
    /// `hello`'s methods are read, which fails while the daemon starts, the
    /// next read comes at the settled pace rather than the idle one, so a
    /// launch during a create is followed within a minute.
    var nextWait: TimeInterval {
        guard !served.isEmpty else { return AlwaysOnCadence.settled }

        return AlwaysOnCadence.wait(
            after: served.contains(.homeStatus) ? status : nil,
            failed: readFailure != nil || !served.contains(.homeStatus),
            paneVisible: paneVisible,
            ownMove: local.moveStarted != nil
        )
    }

    private func schedule() {
        guard let deadlines else { return }

        nextRead?.cancel()
        nextRead = deadlines.schedule(after: nextWait) { [weak self] in
            Task { await self?.tick() }
        }
    }

    // MARK: - Reads

    /// Reads `home.status`, after any read still out, and raises the
    /// notification the change from the last answer calls for.
    public func refresh() async {
        let previous = reading
        let read = Task { [weak self] in
            await previous?.value
            await self?.readOnce()
        }
        reading = read
        await read.value
        guard restartSeen else { return }

        restartSeen = false
        await settings.restartCompleted()
    }

    private func readOnce() async {
        do {
            let home = try await gateway.homeStatus()
            let reading = AlwaysOnReading(status: home, at: now())
            if let notice = AlwaysOnNotices.notice(after: last, reading, ownMove: local.moveStarted != nil) {
                await post(notice)
            }
            last = reading
            publish(home, to: \.status)
            publish(nil, to: \.readFailure)
            settle(home)
        } catch {
            publish(SettingsReadState.failure(error), to: \.readFailure)
            settings.noteRead(error, "home.status")
        }
    }

    /// The methods `hello` lists, read again after a restart.
    func readServed() async {
        do {
            publish(try await gateway.servedMethods(), to: \.served)
        } catch {
            settings.noteRead(error, "hello methods")
        }
    }

    /// What Hetzner sells, for the choice of size and location.
    public func readOptions() async {
        if options.value == nil { options = .loading }
        do {
            options = .loaded(try await gateway.provisionOptions())
        } catch {
            options = .failure(error)
            settings.noteRead(error, "home.provision.options")
        }
    }

    /// Reads the provisioner's record back from Hetzner, then the summary
    /// that rests on it. Answers the record, or nil where it was refused,
    /// which is logged: the summary then says what the record last held.
    @discardableResult
    func reconcile() async -> ManagementProvisionView? {
        guard servesHetzner else { return nil }

        do {
            let view = try await gateway.provisionResources()
            await refresh()
            return view
        } catch {
            settings.noteRead(error, "home.provision.resources")
            return nil
        }
    }

    /// Whether the summary rests on what Hetzner last said of the server.
    private var needsReconcile: Bool {
        switch status?.summary?.state {
        case .problem?, .creating?, .ready?: return servesHetzner
        default: return false
        }
    }

    /// A restart finished: the methods and the summary are the new engine's,
    /// and an engine without the home is asked nothing.
    func restartCompleted() async {
        await readServed()
        if served.contains(.homeStatus) { await refresh() }
    }

    // MARK: - What the app keeps itself

    /// Lets go of each step the app keeps once the engine's summary has moved
    /// past it. The app's own moving screen goes when the engine says where
    /// the move is, or past its bound; everything Settings shows is boot
    /// bound, so the restart the move took is read as one.
    private func settle(_ home: ManagementHomeStatus) {
        let state = home.summary?.state
        if state != .off { local.settingUp = false }
        if state != .ready { reviewed = [] }
        if home.summary?.action?.id != .pasteToken { local.pastingToken = false }
        guard local.moveStarted != nil else { return }

        ownMoveReads += 1
        let engineSays = AlwaysOnPage.saysWhereTheMoveStands(state)
        guard engineSays || ownMoveReads > Self.ownMoveBound else { return }

        if !engineSays {
            log.error("the engine did not say where the move stands within \(Self.ownMoveBound, privacy: .public) reads")
        }
        local.moveStarted = nil
        ownMoveReads = 0
        restartSeen = true
    }

    private func post(_ notice: AlwaysOnNotice) async {
        guard let notifier else {
            log.notice("no notifier for the Always On notice \(notice.kind.rawValue, privacy: .public)")
            return
        }

        let outcome = await notifier.post(
            MacNotification(
                title: ProductStrings[.alwaysOnNoticeTitle],
                body: notice.body,
                sound: true,
                reminderID: nil,
                actions: []
            )
        )
        if case .posted = outcome { return }
        log.notice("the Always On notice \(notice.kind.rawValue, privacy: .public) was not shown: \(String(describing: outcome), privacy: .public)")
    }

    /// Writes one published value, and only where it changed.
    func publish<Value: Equatable>(_ value: Value, to property: ReferenceWritableKeyPath<AlwaysOnModel, Value>) {
        guard self[keyPath: property] != value else { return }

        self[keyPath: property] = value
    }
}
