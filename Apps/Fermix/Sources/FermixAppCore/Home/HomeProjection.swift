import Foundation

/// What the app can say about an update (M34 §6, R2).
///
/// Six states rather than three, because the distinctions are the whole point:
/// a check that has not run, a build that runs no updater, a check in flight,
/// and a check that *failed* are four different truths, and rendering any of
/// them as "up to date" is the one untruth this surface exists to avoid.
public enum UpdateAvailability: Equatable, Sendable {
    /// No check has run yet in this process.
    case unknown
    /// This bundle declares an update policy it may not run on, so no updater
    /// was started. A packaging defect rather than a condition of this Mac.
    case unconfigured
    case checking
    case upToDate(lastCheckedAt: Date?)
    case available(version: String, releaseClass: UpdateReleaseClass)
    /// The update is staged: quitting Fermix replaces the bundle, whatever else
    /// the person does. It is a state of the update rather than of a window, so
    /// it travels on the same value every surface already reads.
    case staged(version: String)
    /// A check ran and did not complete. The date is the last one that did.
    case checkFailed(lastCheckedAt: Date?)
}

/// The Attention row an update draws (M34 §6, R2).
///
/// A row rather than a surface of its own, so Home's section, the menu bar mark
/// and the status item all read one answer. The action shows the updater's own
/// alert, which owns Install, Remind Later and Skip.
public enum UpdatePresentation {
    public static func attentionRow(for availability: UpdateAvailability) -> AttentionRow? {
        switch availability {
        case .available(let version, let releaseClass):
            return AttentionRow(
                id: "update_available",
                title: String(format: ProductStrings[.homeUpdateAvailableFormat], version),
                body: ProductStrings[body(for: releaseClass)],
                action: .showUpdate
            )
        case .staged:
            return AttentionRow(
                id: "update_staged",
                title: ProductStrings[.attentionUpdateStagedTitle],
                body: ProductStrings[.attentionUpdateStagedBody],
                action: .showUpdate
            )
        case .unknown, .unconfigured, .checking, .upToDate, .checkFailed:
            return nil
        }
    }

    private static func body(for releaseClass: UpdateReleaseClass) -> ProductStringKey {
        releaseClass == .critical ? .attentionUpdateCriticalBody : .attentionUpdateAvailableBody
    }
}

/// The update seam every surface reads: what the updater last found, whether it
/// would take a check, and the one command that asks for one.
///
/// `UpdateCoordinator` implements it. The seam stays in this library and
/// imports nothing, because both executables link this library and M34 §6
/// forbids `FermixAgent` from loading the updater framework.
@MainActor
public protocol UpdateChecking: AnyObject {
    func availability() -> UpdateAvailability
    /// The updater's own answer, which the menu row and Home follow rather than
    /// deciding for themselves.
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// Home's Attention section (M34 §3.2).
///
/// Its three sources — readiness failures, restart reasons and the standing
/// coexistence descriptors — all arrive on `setup.state.get`, which is a
/// protocol v2 method. Against a daemon one release behind, the section renders
/// the designed "requires a newer engine" state rather than an error or an
/// empty list (M34 §7.1).
public enum AttentionSection: Equatable, Sendable {
    case rows([AttentionRow])
    case requiresNewerEngine
    /// The v2 reads refuse and the daemon in memory already is the engine this
    /// copy ships, so the restart that clears `requiresNewerEngine` would bring
    /// the same engine back. The row states that and carries no action.
    case engineBehindApp
    /// The daemon refused the call, in its own words.
    case unavailable(String)

    public var rows: [AttentionRow] {
        guard case .rows(let rows) = self else { return [] }

        return rows
    }

    /// What the section draws, whichever state it is in.
    ///
    /// The two non-row states are rows too: M34 §7.1 renders them as one line
    /// with no action, never as an error and never as an empty list that would
    /// read as "nothing is wrong".
    public var displayRows: [AttentionRow] {
        switch self {
        case .rows(let rows):
            return rows
        case .requiresNewerEngine:
            // The one action that clears it. Without it the row states the
            // problem in the exact state the `Finish updating Fermix` sheet
            // exists for and offers no way to reach it (M34 §7.1, §7.2).
            return [
                AttentionRow(
                    id: "requires_newer_engine",
                    title: ProductStrings[.homeAttentionNewerEngineTitle],
                    body: ProductStrings[.daemonErrorRequiresNewerEngine],
                    action: .restartDaemon
                )
            ]
        case .engineBehindApp:
            // No action at all. `Restart` was the action here, and on this
            // state it drained the daemon to bring the same engine back
            // (owner report of 2026-09-04).
            return [
                AttentionRow(
                    id: "engine_behind_app",
                    title: ProductStrings[.homeAttentionNewerEngineTitle],
                    body: ProductStrings[.settingsEngineBehindApp],
                    action: nil
                )
            ]
        case .unavailable(let sentence):
            return [
                AttentionRow(
                    id: "attention_unavailable",
                    title: ProductStrings[.homeAttentionUnavailableTitle],
                    body: sentence,
                    action: nil
                )
            ]
        }
    }
}

/// Home, as data.
///
/// Every row comes from `hello`, `overview.get` and `setup.state.get`. There is
/// no activity database and nothing reads model-facing memory: Runtime carries
/// authoritative facts, Attention carries the daemon's own gaps, and a fact the
/// daemon did not report simply has no row.
public struct HomeSnapshot: Equatable, Sendable {
    public let statusTitle: String
    public let statusTone: StatusTone
    public let uptime: String?
    /// The same fact the sentence above is built from, in seconds, for the
    /// surfaces that render it at a different resolution. One resolver, two
    /// renderings: Home's "for 3 days 4 hours" and the status item's "3 days".
    public let uptimeSeconds: Int?
    public let runtime: [StatusRowModel]
    public let attention: AttentionSection
    public let setupComplete: Bool
    public let restartPending: Bool
    public let unreachable: Bool
    public let update: UpdateAvailability
    /// The version of the engine answering right now, where one answered.
    public let engineVersion: String?

    /// - Parameter setup: the shared `setup.state.get` snapshot, read for one
    ///   thing: the label the daemon publishes for the provider `overview.get`
    ///   names by its wire key. Without it the Runtime section printed
    ///   `openai_codex` beside six rows of plain English.
    public init(
        hello: ManagementHello?,
        overview: ManagementOverview?,
        attention: AttentionSection,
        update: UpdateAvailability,
        setup: ManagementSetupState? = nil,
        unreachable: Bool = false
    ) {
        // The daemon owns "ready": M34 §4 makes `readiness.status` answer ready
        // exactly when no gating failure remains, so Swift gains no second
        // definition of it.
        self.engineVersion = hello?.engine.productVersion
        self.setupComplete = overview?.readiness.status == "ready"
        self.restartPending = overview?.health.restartRequired ?? false
        self.unreachable = unreachable
        self.update = update
        self.attention = attention
        self.uptimeSeconds = overview.flatMap { HomeSnapshot.uptimeSeconds($0) }
        self.uptime = overview.flatMap { HomeSnapshot.uptime($0) }
        self.runtime = HomeSnapshot.runtimeRows(hello: hello, overview: overview, setup: setup)

        if unreachable {
            statusTitle = ProductStrings[.daemonStateNotRunning]
            statusTone = .fail
        } else if setupComplete {
            statusTitle = ProductStrings[.homeStatusRunning]
            statusTone = .pass
        } else {
            statusTitle = ProductStrings[.homeStatusSetupRequired]
            statusTone = .warn
        }
    }

    /// The daemon could not be reached at all. Home says so instead of drawing
    /// a header that implies everything is fine.
    ///
    /// The Attention section is named by the caller rather than defaulted,
    /// because the only default that would fit is an empty row list, and an
    /// empty Attention section renders "nothing needs your attention" — the one
    /// claim a snapshot with no daemon behind it must never make (M34 §7.1).
    public static func unreachable(attention: AttentionSection) -> HomeSnapshot {
        HomeSnapshot(
            hello: nil,
            overview: nil,
            attention: attention,
            update: .unknown,
            unreachable: true
        )
    }

    public var runtimeEmpty: EmptyStateModel {
        EmptyStateModel(message: ProductStrings[.homeRuntimeEmpty])
    }

    public var attentionEmpty: EmptyStateModel {
        EmptyStateModel(message: ProductStrings[.homeAttentionEmpty])
    }

    /// What the update card states (M34 §6, R2): the offered version and its
    /// release class where there is one, and the last check that actually
    /// succeeded beside every other answer.
    public var updateSummary: String {
        switch update {
        case .unknown:
            return ProductStrings[.homeUpdateUnknown]
        case .unconfigured:
            return ProductStrings[.homeUpdateUnconfigured]
        case .checking:
            return ProductStrings[.homeUpdateChecking]
        case .upToDate(let checked):
            return HomeSnapshot.checked(ProductStrings[.homeUpdateCurrent], at: checked)
        case .available(let version, .normal):
            return String(format: ProductStrings[.homeUpdateAvailableFormat], version)
        case .available(let version, .critical):
            return String(format: ProductStrings[.homeUpdateCriticalFormat], version)
        case .staged(let version):
            return String(format: ProductStrings[.homeUpdateStagedFormat], version)
        case .checkFailed(let checked):
            return HomeSnapshot.checked(ProductStrings[.homeUpdateCheckFailed], at: checked)
        }
    }

    /// One sentence with the last successful check appended, where there was
    /// one. The moment is absolute rather than relative: this value is only
    /// recomputed on a refresh, and "three hours ago" held in it would go stale
    /// where it stands.
    private static func checked(_ sentence: String, at moment: Date?) -> String {
        guard let moment else { return sentence }

        return ProductStrings.middot(
            sentence,
            String(format: ProductStrings[.homeUpdateCheckedFormat], HumaneTime.moment(moment))
        )
    }

    // MARK: - Header

    /// The one place the daemon's reported uptime is resolved. A zero or absent
    /// value is no uptime at all rather than "just now": the daemon has not
    /// answered the question.
    private static func uptimeSeconds(_ overview: ManagementOverview) -> Int? {
        guard let milliseconds = overview.daemon.uptimeMs, milliseconds > 0 else { return nil }

        return milliseconds / 1000
    }

    private static func uptime(_ overview: ManagementOverview) -> String? {
        guard let seconds = uptimeSeconds(overview) else { return nil }

        return String(format: ProductStrings[.homeUptimeFormat], HumaneTime.uptime(seconds: seconds))
    }

    // MARK: - Runtime

    /// The seven labelled facts of M34 §3.2, in order. Skills and Tools are
    /// counts only: the operator and guest split, the hidden-capability count
    /// and the policy groups are Doctor's evidence, not Home's.
    private static func runtimeRows(
        hello: ManagementHello?,
        overview: ManagementOverview?,
        setup: ManagementSetupState?
    ) -> [StatusRowModel] {
        guard let hello else { return [] }

        var rows = [
            fact(id: "engine", title: .homeRuntimeEngine, detail: hello.engine.productVersion),
            fact(id: "protocol", title: .homeRuntimeProtocol, detail: "v\(hello.protocolRange.currentVersion)")
        ]

        guard let overview else { return rows }

        if let uptime = uptime(overview) {
            rows.append(fact(id: "uptime", title: .homeRuntimeUptime, detail: uptime))
        }

        // No mark on this row, deliberately. Runtime is seven labelled facts in
        // one flush column, and a leading tile on the single row that names a
        // vendor indents that label alone against the other six (§5.1). The
        // provider's mark is drawn where a row is *about* the vendor: the
        // Providers pane, the assistant's Connect your AI discs, and the
        // provider sheet.
        rows.append(
            fact(id: "provider", title: .homeRuntimeProvider, detail: providerSummary(overview, setup: setup))
        )
        rows.append(fact(id: "channels", title: .homeRuntimeChannels, detail: channelSummary(overview)))
        rows.append(fact(id: "skills", title: .homeRuntimeSkills, detail: String(overview.capabilities.skill)))
        rows.append(
            fact(
                id: "tools",
                title: .homeRuntimeTools,
                detail: String(overview.capabilities.builtin + overview.capabilities.mcp)
            )
        )

        return rows
    }

    private static func fact(id: String, title: ProductStringKey, detail: String) -> StatusRowModel {
        StatusRowModel(id: id, title: ProductStrings[title], detail: detail)
    }

    /// The provider fact carries the model beside it: the fact lives only here.
    ///
    /// `overview.get` names the provider by its wire key (`openai_codex`), and
    /// `setup.state.get` is the one place the daemon publishes a label for it
    /// (`ChatGPT`) — the same label the assistant's rows and the Providers pane
    /// draw. A key the setup state does not list is written as the daemon's own
    /// word, which is the only name that machine has for it.
    private static func providerSummary(
        _ overview: ManagementOverview,
        setup: ManagementSetupState?
    ) -> String {
        guard let provider = overview.provider.active, !provider.isEmpty else {
            return ProductStrings[.homeRuntimeNone]
        }

        let label = setup?.providers.first { $0.id == provider }?.label ?? WireIdentifier.word(provider)

        return overview.provider.model.map { ProductStrings.middot(label, $0) } ?? label
    }

    private static func channelSummary(_ overview: ManagementOverview) -> String {
        let enabled = overview.channels.filter(\.enabled).compactMap(\.name)
        guard !enabled.isEmpty else { return ProductStrings[.homeRuntimeNone] }

        return enabled.joined(separator: ", ")
    }
}

/// One Home read, as the menu bar reads it.
///
/// The badge is the Attention section itself — exactly the rows Home draws, so
/// the glyph and the window can never disagree about whether something needs
/// looking at. A snapshot with no daemon behind it is a stopped daemon rather
/// than a badged one: the stopped glyph already carries its own mark, and the
/// status line says it in words.
extension DaemonObservation {
    public init(snapshot: HomeSnapshot) {
        guard !snapshot.unreachable else {
            self.init(condition: .stopped, needsAttention: false)
            return
        }

        self.init(condition: .running, needsAttention: !snapshot.attention.displayRows.isEmpty)
    }
}

/// Turning `setup.state.get` into Attention rows (M34 §3.2).
///
/// The order is the design's own: the readiness failures that gate first, the
/// advisory ones next, then the pending restart, then the standing coexistence
/// descriptors.
public enum AttentionProjection {
    public static func rows(
        for state: ManagementSetupState,
        names: AttentionNames = .unread
    ) -> [AttentionRow] {
        readinessRows(state, names: names) + restartRows(state) + coexistenceRows(state)
    }

    private static func readinessRows(
        _ state: ManagementSetupState,
        names: AttentionNames
    ) -> [AttentionRow] {
        let ordered = state.readiness.failures.filter(\.gating) + state.readiness.failures.filter { !$0.gating }

        return ordered.map { failure in
            AttentionCatalogue.row(for: AttentionDetail(detailKey: failure.detailKey), names: names)
        }
    }

    private static func restartRows(_ state: ManagementSetupState) -> [AttentionRow] {
        guard state.restart.required else { return [] }

        let sentences = state.restart.reasons.map(\.sentence).joined(separator: " ")

        return [
            AttentionCatalogue.row(
                for: .restartPending,
                evidence: sentences.isEmpty ? nil : sentences
            )
        ]
    }

    /// The standing descriptors M34 §5.8 publishes, as far as the contract
    /// carries them. `engine_path_baseline` has no field on `setup.state.get`,
    /// so it is a Doctor row only until the engine publishes one.
    private static func coexistenceRows(_ state: ManagementSetupState) -> [AttentionRow] {
        var rows: [AttentionRow] = []

        switch state.coexistence.configState {
        case .externalChange:
            rows.append(AttentionCatalogue.row(for: .externalConfigChange))
        case .configUnreadable:
            rows.append(AttentionCatalogue.row(for: .configUnreadable))
        case .clear, .unrecognized:
            break
        }

        if state.coexistence.legacyServiceUnit.present {
            rows.append(
                AttentionCatalogue.row(
                    for: .legacyServiceUnit,
                    evidence: state.coexistence.legacyServiceUnit.path
                )
            )
        }

        if state.coexistence.secretACLRestricted.isRestricted {
            rows.append(AttentionCatalogue.row(for: .secretACLRestricted))
        }

        return rows
    }
}
