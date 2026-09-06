import Foundation

/// Where the Settings window remembers which pane was last open.
///
/// Main-actor isolated because the one model that reads it is, and a store the
/// window writes from a background context would be a data race rather than a
/// convenience.
@MainActor
public protocol SettingsPaneStoring: AnyObject {
    /// The stored slug, or nil where the operator has never opened a pane.
    var lastSettingsPane: String? { get set }
}

/// The shipped store. The key is M34 §3.1's `settings.lastPane`.
@MainActor
public final class UserDefaultsSettingsPaneStore: SettingsPaneStoring {
    public static let key = "settings.lastPane"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastSettingsPane: String? {
        get { defaults.string(forKey: Self.key) }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.key)
                return
            }

            defaults.set(newValue, forKey: Self.key)
        }
    }
}

/// The one model behind every daemon-owned setting (M34 §8).
///
/// Exactly one instance exists, built in `AppComposition` and shared by the
/// Settings window, Home and onboarding, so the three cannot hold three
/// different answers to "what is configured". It owns the `setup.state.get`
/// snapshot, the per-section descriptor cache, the restart and external-change
/// state, the engine reconcile state, the running jobs, the selected pane and
/// the per-pane drafts.
///
/// It decides nothing the daemon decides: every label, bound, option and
/// refusal sentence here came off the wire.
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public internal(set) var setupState: SettingsReadState<ManagementSetupState> = .unread
    @Published public internal(set) var inventory: SettingsReadState<[ManagementSettingsSection]> = .unread
    @Published public internal(set) var sections: [String: SettingsReadState<ManagementSettingsSectionRows>] = [:]
    @Published public internal(set) var detections: SettingsReadState<ManagementDetections> = .unread
    @Published public internal(set) var plugins: SettingsReadState<ManagementPluginCatalog> = .unread
    @Published public internal(set) var restart = ManagementRestartState(required: false, reasons: [])
    @Published public internal(set) var configState: ManagementConfigState = .clear
    /// The one answer to "can the daemon in memory serve this bundle's
    /// surface" (M34 §7.1, §7.2). Home writes the build comparison into it
    /// after every `hello`; the reads below write the other half.
    @Published public internal(set) var engineReconcile = EngineReconcile()
    @Published public internal(set) var jobs: [ManagementJob] = []
    /// Uncommitted edits, so a rebuilt pane keeps what was typed into it.
    @Published public internal(set) var drafts: [SettingsDraftKey: ManagementSettingValue] = [:]
    /// The daemon's refusal for one row, shown under that row.
    @Published public internal(set) var rowMessages: [SettingsDraftKey: String] = [:]
    /// Changes the operator did not type, in the daemon's own sentences.
    @Published public internal(set) var sideEffects: [String] = []
    @Published public internal(set) var restartProgress: RestartProgress = .idle
    /// Conversations that a restart would interrupt, read before asking.
    ///
    /// Optional because "nobody answered" is a third answer and not a zero: an
    /// unanswered poll that read as idle would restart the daemon in the middle
    /// of a turn, which is the one thing `Restart when idle` exists to prevent.
    @Published public internal(set) var conversationsInFlight: Int?
    /// The parser's own sentence for a settings file the daemon cannot read.
    /// It arrives on a refusal, not on `setup.state.get`, which carries the
    /// state and no words.
    @Published public internal(set) var configSentence: String?
    /// The provider whose sign-in is in flight, which is the one status word no
    /// daemon field can report: the browser hop happens outside the daemon.
    @Published public internal(set) var signingInProvider: String?
    /// Covers the request before the daemon has returned a job to observe.
    @Published public internal(set) var startingSignIn = false
    @Published public var searchText = ""
    /// The descriptor field being edited right now, where one is.
    ///
    /// Escape belongs to that field while it is: on the Mac, Escape in a field
    /// puts the value back, and only Escape with nothing being edited leaves the
    /// window (M34 §3.1). Every descriptor field commits on focus loss, so
    /// without this the gesture read as `save this and leave`.
    @Published public internal(set) var editingRow: SettingsDraftKey?
    /// Bumped when Escape asked the focused field to put the daemon's value
    /// back. A counter rather than a flag: two Escapes in a row are two reverts.
    @Published public internal(set) var editReverts = 0

    @Published public var selectedPane: SettingsPane {
        didSet {
            guard selectedPane != oldValue else { return }

            store.lastSettingsPane = selectedPane.slug
        }
    }

    /// The one ledger behind Permissions, Voice and Computer (M34 §5.9). It
    /// hangs off this model because this model is the one instance: two ledgers
    /// is exactly the disagreement §5.9 exists to prevent.
    public let permissions: PermissionLedger

    let gateway: any DaemonQuerying
    private let store: any SettingsPaneStoring
    let sleeper: any Sleeping
    /// The system browser, for the one hop a sign-in needs (RFC 8252).
    let opener: any ExternalOpening
    let log = AppLog.logger(.app)

    public init(
        gateway: any DaemonQuerying,
        store: any SettingsPaneStoring,
        sleeper: any Sleeping,
        opener: any ExternalOpening,
        permissions: PermissionLedger
    ) {
        self.gateway = gateway
        self.store = store
        self.sleeper = sleeper
        self.opener = opener
        self.permissions = permissions
        self.selectedPane = store.lastSettingsPane.flatMap(SettingsPane.init(rawValue:)) ?? .providers
    }

    // MARK: - What the panes read

    /// The sections the daemon assigned to a pane, in the published order.
    public func sections(for pane: SettingsPane) -> [ManagementSettingsSection] {
        (inventory.value ?? []).filter { $0.pane == pane.wire }
    }

    public func section(_ id: String) -> SettingsReadState<ManagementSettingsSectionRows> {
        sections[id] ?? .unread
    }

    /// Each provider's own descriptor rows, by provider id.
    ///
    /// It is where a provider's `secret.set` slot is named (M34 §5.1), and both
    /// doors that draw provider rows read it from here: the Providers pane and
    /// the assistant's Connect your AI. Two lookups would let one of them offer
    /// a key verb the other knows has no slot.
    public func providerDescriptorRows(
        for providers: [ManagementSetupProvider]
    ) -> [String: [ManagementSettingRow]] {
        var found: [String: [ManagementSettingRow]] = [:]
        for provider in providers {
            found[provider.id] = section(ProviderRowProjection.sectionId(for: provider.id)).value?.rows
        }

        return found
    }

    /// Reads every published provider's own section, which is what gives a key
    /// verb the slot it writes to. The loop is bounded by the provider list the
    /// daemon published, which `setup.state.get` caps.
    public func loadProviderSections(for providers: [ManagementSetupProvider]) async {
        for provider in providers {
            await loadSection(ProviderRowProjection.sectionId(for: provider.id))
        }
    }

    /// A row's value as the pane shows it: the operator's uncommitted edit where
    /// there is one, and the daemon's value otherwise.
    public func value(of row: ManagementSettingRow, in section: String) -> ManagementSettingValue {
        drafts[SettingsDraftKey(section: section, key: row.key)] ?? row.value
    }

    public func message(for key: SettingsDraftKey) -> String? { rowMessages[key] }

    /// The panes of one group that answer the sidebar's search field.
    ///
    /// A pane matches on its own title and keywords, and on the labels of any
    /// rows already read: the search covers what the daemon published for the
    /// panes that have been opened, and never pre-reads twelve panes to index
    /// them.
    public func panes(matching query: String, in group: SettingsPaneGroup) -> [SettingsPane] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return group.panes }

        return group.panes.filter { $0.matches(needle) || rowsMatch(needle, in: $0) }
    }

    /// Whether any row this pane has read carries the searched text in its
    /// label. Footers are not searched: they are explanations, and matching them
    /// would light panes whose controls do not mention the word at all.
    public func rowsMatch(_ query: String, in pane: SettingsPane) -> Bool {
        let needle = query.lowercased()

        return sections(for: pane).contains { entry in
            section(entry.id).value?.rows.contains { $0.label.lowercased().contains(needle) } ?? false
        }
    }

    /// Whether a write would be refused right now (M34 §7.6). Only
    /// `external_change` refuses; a file the daemon cannot read is a different
    /// state, and it routes to Recovery rather than to a reload button.
    public var writesBlocked: Bool { configState == .externalChange }

    public var configUnreadable: Bool { configState == .configUnreadable }

    /// Whether this pane can be served at all by the running daemon. Every
    /// settings surface is protocol v2, so an N-1 daemon answers one designed
    /// state for all of them.
    public var requiresNewerEngine: Bool { engineReconcile.requiresNewerEngine }

    /// Whether the restart on offer is the one that finishes an update. Read by
    /// the one restart sheet, whichever door opened it.
    public var isFinishingUpdate: Bool { engineReconcile.isFinishingUpdate }

    /// What a pane says while it cannot be served, which is one of two
    /// sentences: the restart that fixes it, or the fact that no restart can.
    public var newerEngineSentence: String { engineReconcile.newerEngineSentence }

    /// The launch reconcile compared the daemon in memory with the engine in
    /// this bundle. Home is the one caller: it is the surface that reads
    /// `hello` (M34 §7.2).
    public func noteEngineBuilds(_ outcome: EngineReconcileOutcome) {
        engineReconcile.builds = outcome
    }

    /// A protocol v2 read was served, so nothing is refusing.
    func noteServed() {
        engineReconcile.methodsRefused = false
    }

    // MARK: - Refresh

    /// The window appeared. Reads the state every pane shares, then the pane
    /// that is showing.
    public func windowAppeared() async {
        await refreshSetupState()
        await loadInventory()
        await paneAppeared(selectedPane)
    }

    /// A pane appeared. Loads the sections it renders and nothing else: a
    /// pane's rows are read when it is shown, never all thirteen at once.
    public func paneAppeared(_ pane: SettingsPane) async {
        for entry in sections(for: pane) where !isRead(entry.id) {
            await loadSection(entry.id)
        }
    }

    /// Takes over the reads the assistant's fourth ladder row already made
    /// (M34 §4), so the window that opens next does not re-ask the daemon for
    /// what it was just told. An absent read is left alone rather than written
    /// as an empty answer.
    public func adopt(setupState state: ManagementSetupState?, detections probed: ManagementDetections?) {
        if let state {
            setupState = .loaded(state)
            noteServed()
            apply(restart: state.restart)
            configState = state.coexistence.configState
        }

        if let probed {
            detections = .loaded(probed)
        }
    }

    /// A restart finished. Everything the panes show is boot-bound, so all of it
    /// is re-read rather than patched.
    ///
    /// The negotiated protocol window is dropped first. It belongs to the daemon
    /// that just exited, and every read below is gated against it: after an
    /// upgrade restart the window that refused each v2 method is exactly the one
    /// still cached, so the panes would keep saying `Restart to finish updating`
    /// against the newer engine that came back (M34 §7.2).
    public func restartCompleted() async {
        await gateway.invalidateNegotiation()
        restartProgress = .idle
        sections.removeAll()
        await refreshSetupState()
        await loadInventory()
        await paneAppeared(selectedPane)
    }

    public func refreshSetupState() async {
        setupState = .loading
        do {
            let state = try await gateway.setupState()
            setupState = .loaded(state)
            noteServed()
            apply(restart: state.restart)
            configState = state.coexistence.configState
        } catch {
            setupState = .failure(error)
            noteRead(error, "setup.state.get")
        }
    }

    public func loadInventory() async {
        inventory = .loading
        do {
            inventory = .loaded(try await gateway.settingsSections().sections)
            noteServed()
        } catch {
            inventory = .failure(error)
            noteRead(error, "settings.sections")
        }
    }

    /// Reads one section's descriptor rows. `settings.get` serves exactly one
    /// section per call, which is what keeps every result inside the published
    /// depth budget.
    public func loadSection(_ id: String) async {
        precondition(!id.isEmpty, "a section is read by name")

        // A section that already has rows keeps them while it is re-read. The
        // spinner is for a section nobody has seen yet; showing it after every
        // apply would replace the whole pane with a spinner on each write.
        if section(id).value == nil {
            sections[id] = .loading
        }

        do {
            sections[id] = .loaded(try await gateway.settings(section: id))
            noteServed()
        } catch {
            sections[id] = .failure(error)
            noteRead(error, "settings.get \(id)")
        }
    }

    /// Whether a section has been read, or is being read right now. Both count:
    /// the window's own appearance and the detail column's pane change can
    /// arrive together, and two reads of one section is one round trip wasted.
    func isRead(_ id: String) -> Bool {
        section(id).value != nil || section(id) == .loading
    }

    /// Reads one channel's credential rows, once.
    ///
    /// The list draws every channel the daemon reports, and each row needs its
    /// own section to know whether it has an enable row at all, so this is
    /// idempotent: a row that has already been read asks for nothing.
    public func loadChannelSection(_ channel: String) async {
        let id = ChannelRowProjection.sectionId(for: channel)
        guard !isRead(id) else { return }

        await loadSection(id)
    }

    /// Reads the helper's rights through the one ledger, and records the N-1
    /// window when the daemon refuses.
    ///
    /// Permissions is the one pane whose daemon-read half sits behind the
    /// ledger, so a visit that starts on this pane has to learn the state from
    /// this pane: without this the rights would render `Unknown` forever with
    /// nothing saying why (M34 §7.1).
    public func refreshPermissions() async {
        await permissions.refresh()

        guard permissions.computerUse == .requiresNewerEngine else { return }

        noteRequiresNewerEngine()
    }

    /// Probes what is already installed on this Mac. Detections change the verb
    /// a row leads with; they never add a row or a screen.
    public func refreshDetections(_ targets: [ManagementDetectTarget]) async {
        precondition(!targets.isEmpty, "a detection names what it probes")

        detections = .loading
        do {
            detections = .loaded(try await gateway.detect(targets))
            noteServed()
        } catch {
            detections = .failure(error)
            noteRead(error, "setup.detect")
        }
    }

    // MARK: - Shared bookkeeping

    /// Records the restart requirement a read or a write reported.
    func apply(restart state: ManagementRestartState) {
        restart = state
    }

    /// A read failed. Every one of them is logged at error level with the typed
    /// error, because the state they leave behind — a pane saying the daemon
    /// could not be reached — is what a shape mismatch against a contract
    /// vendored from an uncommitted upstream tree looks like, and it left no
    /// trace at all.
    func noteRead(_ error: any Error, _ what: String) {
        log.error(
            "\(what, privacy: .public) failed: \(ManagementMessage.diagnostic(for: error), privacy: .public)"
        )
        noteReconcile(error)
    }

    /// A refusal that names the N-1 window is the engine reconcile signal: the
    /// engine in the bundle serves the method and the restart applies it.
    func noteReconcile(_ error: any Error) {
        guard ManagementMessage.requiresNewerEngine(error) else { return }

        noteRequiresNewerEngine()
    }

    /// A protocol v2 method refused with the N-1 window.
    func noteRequiresNewerEngine() {
        engineReconcile.methodsRefused = true
    }

    func setDraft(_ value: ManagementSettingValue?, for key: SettingsDraftKey) {
        drafts[key] = value
    }

    func setMessage(_ sentence: String?, for key: SettingsDraftKey) {
        rowMessages[key] = sentence
    }

    // MARK: - Which field owns Escape

    public func beginEditing(_ key: SettingsDraftKey) {
        editingRow = key
    }

    /// Only the field that claimed it may release it: a row losing focus to the
    /// row that just took it must not clear the new one.
    public func endEditing(_ key: SettingsDraftKey) {
        guard editingRow == key else { return }

        editingRow = nil
    }

    /// Escape while a field is focused. The field puts the daemon's value back
    /// and gives up focus; nothing is written.
    public func revertEdit() {
        guard editingRow != nil else { return }

        editReverts += 1
    }
}
