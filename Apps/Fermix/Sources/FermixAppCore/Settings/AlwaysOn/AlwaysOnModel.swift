import Foundation

/// Raises the system's own notifications for Always On. `MacNotifications`
/// is the one in the app.
@MainActor
public protocol AlwaysOnNotifying: AnyObject {
    func post(_ notification: MacNotification) async -> NotificationPostOutcome
}

extension MacNotifications: AlwaysOnNotifying {}

/// The Always On pane's reads and presses (Always On setup §8.3).
///
/// `home.status.summary` is the screen, and every press is one `home.act`
/// whose answer is the summary after the step, drawn as it comes. Nothing
/// reads on a timer. The summary is read when the engine says it changed
/// (`home_status_changed`, companion protocol 6, which never comes while
/// Always On stays off), when the pane is shown, after a press the engine
/// refused, and on a desktop whose server cannot be reached, where no notice
/// can arrive (`listen(to:)`). So while Always On is off and the pane is
/// closed, the app asks nothing about it. A summary's `notice` is raised as
/// a notification the first time its id is seen.
@MainActor
public final class AlwaysOnModel: ObservableObject {
    /// The last summary a read or a press answered, kept while a later read
    /// fails.
    @Published public private(set) var summary: ManagementHomeSummary?
    /// The last read answered a `home.status` with no summary.
    @Published public private(set) var olderEngine = false
    /// The last read's refusal, while it is the latest word.
    @Published public private(set) var readFailure: SettingsReadState<ManagementHomeStatus>?
    /// The press waiting on the owner: the token field, a sheet, a confirm.
    @Published public internal(set) var asking: AlwaysOnAsk?
    /// The provider the owner picked on the token step, by its id, where the
    /// summary lists more than one.
    @Published public internal(set) var picked: String?
    /// What the provider in use sells, read as a choice opens.
    @Published public internal(set) var options: SettingsReadState<ManagementProvisionOptions> = .unread
    /// The action whose `home.act` is out, which holds every button.
    @Published public internal(set) var working: ManagementHomeActionId?
    /// The engine's refusal of the last press, said under the action.
    @Published public internal(set) var refusal: String?
    /// A word that is no failure: a step the server took but whose answer
    /// was lost.
    @Published public internal(set) var notice: String?
    /// `own_server`'s code and command, shown once, while the pane shows it.
    @Published public internal(set) var ownServer: ManagementOwnServerCode?
    /// The key of the summary this app's own Move now answered, while the
    /// engine restarts to carry the move out.
    @Published public internal(set) var restartingFrom: String?

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
    let log = AppLog.logger(.app)

    /// The notices raised already, so each is raised once.
    private var posted = AlwaysOnPosted()
    /// The reads in order: each waits for the one before it.
    private var reading: Task<Void, Never>?
    /// The read the last cue from the chat wire started; each cue's read
    /// waits for the one before it.
    private(set) var cued: Task<Void, Never>?
    private var paneVisible = false
    /// The engine answered after the restart this app's own move took, so
    /// everything Settings shows is read again once the read that saw it is
    /// done.
    private var restartSeen = false

    public init(settings: SettingsModel) {
        self.settings = settings
    }

    var gateway: any DaemonQuerying { settings.gateway }

    /// What the pane shows.
    public var page: AlwaysOnPage {
        AlwaysOnPage.page(summary: summary, olderEngine: olderEngine, failure: readFailure, restarting: restartingFrom != nil)
    }

    // MARK: - The pane

    /// The pane appeared, which is when the off line is read, since the
    /// engine never says it changed.
    public func paneAppeared() async {
        paneVisible = true
        await refresh()
    }

    /// The pane went: the code it showed, the press it waited on and the
    /// provider picked on it leave with it.
    public func paneDisappeared() {
        paneVisible = false
        ownServer = nil
        closeAsk()
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

    /// Reads `home.status`, after any read still out.
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
            publish(nil, to: \.readFailure)
            publish(home.summary == nil, to: \.olderEngine)
            if let summary = home.summary { await take(summary) }
        } catch {
            publish(SettingsReadState.failure(error), to: \.readFailure)
            settings.noteRead(error, "home.status")
        }
    }

    /// A restart finished: the summary is read again while the pane shows;
    /// otherwise the new engine's notice says when to read.
    func restartCompleted() async {
        guard paneVisible else { return }

        await refresh()
    }

    // MARK: - One summary

    /// Draws one summary, from a read or a press: raises its notice the first
    /// time its id is seen, lets go of a press the summary no longer offers,
    /// and ends the restart screen of this app's own Move now once the engine
    /// answers with a summary that moved.
    func take(_ summary: ManagementHomeSummary) async {
        publish(summary, to: \.summary)
        if let asked = asking, !summary.offers(asked.action) { closeAsk() }
        if let from = restartingFrom, summary.key != from {
            restartingFrom = nil
            restartSeen = true
        }
        guard let notice = summary.notice, posted.first(notice.id) else { return }

        await post(notice)
    }

    func closeAsk() {
        asking = nil
        picked = nil
        options = .unread
    }

    private func post(_ notice: ManagementHomeNotice) async {
        let kind = notice.id.prefix { $0 != ":" }
        guard let notifier else {
            log.notice("no notifier for the Always On notice \(kind, privacy: .public)")
            return
        }

        let outcome = await notifier.post(
            MacNotification(
                title: ProductStrings[.alwaysOnNoticeTitle],
                body: notice.sentence,
                sound: true,
                reminderID: nil,
                actions: []
            )
        )
        if case .posted = outcome { return }
        log.notice("the Always On notice \(kind, privacy: .public) was not shown: \(String(describing: outcome), privacy: .public)")
    }

    /// Writes one published value, and only where it changed.
    func publish<Value: Equatable>(_ value: Value, to property: ReferenceWritableKeyPath<AlwaysOnModel, Value>) {
        guard self[keyPath: property] != value else { return }

        self[keyPath: property] = value
    }
}
