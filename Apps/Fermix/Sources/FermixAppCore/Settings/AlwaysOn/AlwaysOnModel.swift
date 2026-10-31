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
/// than by a guess at what changed. Nothing reads it on a timer. It is read
/// when the engine says it changed (`home_status_changed`, companion protocol
/// 6, which never comes while Always On stays off), when the pane is shown,
/// after this app's own action, and on a desktop whose server cannot be
/// reached, where no notice can arrive (`listen(to:)`). So while Always On is
/// off and the pane is closed, the app asks nothing about it. The
/// notifications come from the changes those reads see.
///
/// The cloud provider is the engine's data: `home.provision.providers` names
/// each one and the words its token screen draws, and the provisioner's
/// record names the one in use, so this model names none. This owns when
/// each call is made and the few steps the app keeps itself
/// (`AlwaysOnLocal`).
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
    /// The cloud providers Fermix creates the server on, read as the pane
    /// first shows on an engine that serves the provisioner.
    @Published public private(set) var providers: SettingsReadState<[ManagementProvisionProvider]> = .unread
    /// The provisioner's record as last answered by connect or resources. Its
    /// `provider` is the one options, create and Open console name.
    @Published public internal(set) var record: ManagementProvisionView?
    /// What the provider in use sells, read for Create server, Change and
    /// Replace.
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
    /// The read the last cue from the chat wire started; each cue's read
    /// waits for the one before it.
    private(set) var cued: Task<Void, Never>?
    private var paneVisible = false
    /// When this app's own move started, which bounds how long the pane says
    /// it is moving before the engine says so itself.
    var ownMoveSince: Date?
    /// The engine answered after the restart this app's own move took, so
    /// everything Settings shows is read again once the read that saw it is
    /// done.
    private var restartSeen = false

    /// How long the app's own moving screen outlasts the engine's silence on
    /// it, judged at each read: no timer reads to end it.
    static let ownMoveBound: TimeInterval = 600

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

    /// The provisioner's screens are drawn only where every one of its
    /// methods is listed, `home.provision.providers` among them.
    public var servesProvisioner: Bool { served.isSuperset(of: ManagementMethod.homeProvisionMethods) }

    /// Which provider's token a screen's field takes.
    public func tokenTarget(on screen: AlwaysOnScreen) -> AlwaysOnTokenTarget {
        screen.tokenTarget(providers: providers.value, picked: local.provider, inUse: record?.provider)
    }

    // MARK: - The pane

    /// The pane appeared, which is when the off line is read, since the
    /// engine never says it changed. A screen whose summary rests on the
    /// provisioner's record reads that record back from the provider first, so
    /// the server's power and a server deleted outside Fermix show.
    public func paneAppeared() async {
        paneVisible = true
        if served.isEmpty { await readServed() }
        if servesProvisioner, providers.value == nil { await readProviders() }
        await refresh()
        if needsReconcile { await reconcile() }
        if status?.summary?.state == .choose { await readOptions() }
    }

    /// The pane went: the code it showed and the provider picked on it leave
    /// with it.
    public func paneDisappeared() {
        paneVisible = false
        handout = nil
        local.provider = nil
    }

    // MARK: - The notice

    /// Reads the summary each time the chat wire says it may have moved:
    /// `home_status_changed`, and a desktop's server out of reach or no
    /// longer knowing it (`CompanionSession.homeStatusCue`). The composition
    /// calls this once.
    public func listen(to session: CompanionSession) {
        session.homeStatusCue = { [weak self] in self?.cue() }
    }

    /// One read for one cue, after the one before it.
    func cue() {
        let previous = cued
        cued = Task { [weak self] in
            await previous?.value
            await self?.refresh()
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

    /// The providers the token screen draws, in the order offered.
    func readProviders() async {
        if providers.value == nil { providers = .loading }
        do {
            providers = .loaded(try await gateway.provisionProviders().providers)
        } catch {
            providers = .failure(error)
            settings.noteRead(error, "home.provision.providers")
        }
    }

    /// What the provider in use sells, for the choice of size and location.
    public func readOptions() async {
        if options.value == nil { options = .loading }
        do {
            let provider = try await providerInUse()
            options = .loaded(try await gateway.provisionOptions(provider: provider))
        } catch {
            options = .failure(error)
            settings.noteRead(error, "home.provision.options")
        }
    }

    /// The provider the server lives on, or whose token was given, as the
    /// provisioner's record names it. Where no record was answered yet, it
    /// is read once.
    func providerInUse() async throws -> String {
        if let record { return record.provider }

        return try await readRecord().provider
    }

    /// The provisioner's record, read back from the provider in use.
    func readRecord() async throws -> ManagementProvisionView {
        let read = try await gateway.provisionResources()
        record = read
        return read
    }

    /// Reads the provisioner's record back from the provider, then the
    /// summary that rests on it. A refusal is logged: the summary then says
    /// what the record last held.
    func reconcile() async {
        guard servesProvisioner else { return }

        do {
            _ = try await readRecord()
        } catch {
            settings.noteRead(error, "home.provision.resources")
            return
        }
        await refresh()
    }

    /// Whether the summary rests on what the provider last said of the
    /// server.
    private var needsReconcile: Bool {
        switch status?.summary?.state {
        case .problem?, .creating?, .ready?: return servesProvisioner
        default: return false
        }
    }

    /// A restart finished: what the engine serves may have changed, so its
    /// methods, its providers and the provisioner's record are forgotten.
    /// They are read again now only while the pane shows; otherwise the new
    /// engine's notice says when to read.
    func restartCompleted() async {
        served = []
        providers = .unread
        record = nil
        guard paneVisible else { return }

        await readServed()
        if servesProvisioner { await readProviders() }
        if served.contains(.homeStatus) { await refresh() }
    }

    // MARK: - What the app keeps itself

    /// Lets go of each step the app keeps once the engine's summary has moved
    /// past it. The app's own moving screen goes when the engine says where
    /// the move is, or at the first read past its bound; everything Settings
    /// shows is boot bound, so the restart the move took is read as one.
    private func settle(_ home: ManagementHomeStatus) {
        let state = home.summary?.state
        if state != .off { local.settingUp = false }
        if state != .ready { reviewed = [] }
        if home.summary?.action?.id != .pasteToken { local.pastingToken = false }
        guard local.moveStarted != nil, let since = ownMoveSince else { return }
        guard Self.ownMoveEnds(state, since: since, now: now()) else { return }

        if !AlwaysOnPage.saysWhereTheMoveStands(state) {
            log.error("the engine did not say where the move stands within \(Int(Self.ownMoveBound), privacy: .public) seconds")
        }
        local.moveStarted = nil
        ownMoveSince = nil
        restartSeen = true
    }

    /// Whether the app's own moving screen goes at a read whose summary is in
    /// `state`: the engine says where the move stands, or has not said so
    /// within the bound since the move started.
    static func ownMoveEnds(_ state: ManagementHomeSummaryState?, since: Date, now: Date) -> Bool {
        AlwaysOnPage.saysWhereTheMoveStands(state) || now.timeIntervalSince(since) > ownMoveBound
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
