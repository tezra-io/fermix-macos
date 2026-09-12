import SwiftUI

/// What an integration row's buttons do, and what they are called.
///
/// The daemon publishes both halves and they are not the same half:
/// `primary_verb` and `verbs` are its English, and `primary_action` and
/// `actions` say which method each of those buttons runs. Dispatch reads only
/// the action ids, and a button is titled from this catalogue by id — painting
/// the daemon's word onto an app-derived action is exactly how a row came to
/// draw `Choose workspace` on a button that ran `plugins.check.start`.
extension ManagementPluginAction {
    /// The app's own word for this action, or nil for an id this build does not
    /// know. An unknown id draws no button rather than a guessed one.
    public var titleKey: ProductStringKey? {
        switch self {
        case .install: return .integrationInstall
        case .enable: return .integrationEnable
        case .disable: return .integrationDisable
        case .signIn: return .integrationSignIn
        case .addToken: return .integrationAddToken
        case .replaceToken: return .integrationReplaceToken
        case .setUpClient: return .integrationSetUpClient
        case .chooseWorkspace: return .integrationWorkspaceChoose
        case .check: return .integrationCheck
        case .disconnect: return .integrationDisconnect
        case .unrecognized: return nil
        }
    }

    public var title: String? { titleKey.map { ProductStrings[$0] } }

    /// Whether the detail draws a button for this action.
    ///
    /// Neither token verb does. The credential slot is the sheet's own
    /// `SecretRow`, which is the one door to that slot; a button beside it would
    /// be a second control for one thing, and the only thing this sheet could do
    /// with it is nothing.
    public var drawsButton: Bool {
        switch self {
        case .addToken, .replaceToken: return false
        case .unrecognized: return false
        case .install, .enable, .disable, .signIn, .setUpClient, .chooseWorkspace,
             .check, .disconnect:
            return true
        }
    }

    /// Whether this action is answered by a sheet rather than by a call.
    ///
    /// The two credential verbs are the `SecretRow` slot, the client verb is the
    /// OAuth client sheet, and a workspace is the operator's own choice. Routing
    /// any of them through the write path would be a defect at the call site
    /// rather than a button that quietly does nothing.
    public var isAnsweredBySheet: Bool {
        switch self {
        case .addToken, .replaceToken, .setUpClient, .chooseWorkspace: return true
        case .install, .enable, .disable, .signIn, .check, .disconnect, .unrecognized: return false
        }
    }
}

/// The four kind pills of decision D6, each with its live count.
///
/// They are the kinds the daemon publishes rather than Codex's own: Installed,
/// Available, MCPs and the three native driver Features.
public enum IntegrationFilter: String, CaseIterable, Identifiable, Sendable {
    case installed
    case available
    case mcps
    case features

    public var id: String { rawValue }

    public var titleKey: ProductStringKey {
        switch self {
        case .installed: return .integrationsFilterInstalled
        case .available: return .integrationsFilterAvailable
        case .mcps: return .integrationsFilterMCPs
        case .features: return .integrationsFilterFeatures
        }
    }

    public var title: String { ProductStrings[titleKey] }

    /// The runtime kinds that make a plugin an MCP server.
    ///
    /// M8's plugin manifest publishes `runtime.kind`, and the two MCP members
    /// of that set are what the pill counts. It is the one runtime vocabulary
    /// the app reads, and it reads it to filter rather than to word anything:
    /// every sentence on the row is still the daemon's.
    public static let mcpRuntimeKinds: Set<ManagementPluginRuntimeKind> = [.remoteMCP, .localStdio]

    public func admits(_ row: IntegrationRowModel) -> Bool {
        switch self {
        case .installed: return row.installed
        case .available: return !row.installed
        case .mcps: return row.runtimeKind.map(Self.mcpRuntimeKinds.contains) ?? false
        case .features: return false
        }
    }
}

/// The page's search rule, written once (decision D6): the name and the
/// one-line description.
///
/// Plugin rows and Features rows are read by the same rule, so the search
/// cannot mean one thing under one pill and something else under another.
public enum IntegrationSearch {
    public static func matches(_ query: String, title: String, summary: String?) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }

        return title.lowercased().contains(needle) || (summary ?? "").lowercased().contains(needle)
    }
}

/// One integration row, resolved from the plugin the daemon published.
public struct IntegrationRowModel: Identifiable, Equatable, Sendable {
    public let name: String
    public let title: String
    /// The one-line description under the name. The manifest's own.
    public let summary: String?
    /// The daemon's own sentence for where this plugin stands.
    public let status: String
    /// Which method the row leads with, from the daemon's own closed set. Null
    /// where it published no leading verb.
    public let primaryAction: ManagementPluginAction?
    /// The daemon's word for the next step, where it published one. Drawn as
    /// text; never a button title and never a routing key.
    public let verb: String?
    /// Every verb the daemon published for this plugin, in its own words,
    /// paired index for index with `actions`.
    public let verbs: [String]
    /// What each of those buttons runs. Empty means the row offers no verb
    /// buttons at all, which is a state the daemon publishes and not a gap.
    public let actions: [ManagementPluginAction]
    public let installed: Bool
    public let enabled: Bool
    public let runtimeKind: ManagementPluginRuntimeKind?
    /// The plugin's own credential kind. Read for the credential slot, never to
    /// decide which verbs the row offers: that is the daemon's answer.
    public let authKind: ManagementPluginAuthKind?
    /// Whether a credential sits behind this plugin, as the daemon published it.
    public let credentialPresent: Bool
    /// The sign-in family this plugin belongs to, which is what names its entry
    /// in the page's sign-in clients section.
    public let authProvider: String?
    public let consent: String
    public let disclosure: String?
    public let accessProfiles: [ManagementPluginAccessProfile]
    public let workspaces: [ManagementPluginWorkspace]
    public let workspaceLabel: String?

    public var id: String { "plugin:\(name)" }

    /// The buttons the detail draws: the daemon's own ids, minus the ones
    /// answered by a slot of their own and the ones this build has no word for.
    public var buttons: [ManagementPluginAction] {
        actions.filter { $0.drawsButton && $0.titleKey != nil }
    }

    /// Whether this plugin binds to a workspace at all, which is what puts the
    /// workspace row in its detail.
    public var bindsWorkspace: Bool { !accessProfiles.isEmpty }

    public var accessibilityLabel: String { ProductStrings.commaPair(title, status) }

    /// The row's second line, which is one rule with two branches (M34 §5.6).
    ///
    /// An installed row reads the daemon's own `status_sentence`: where it
    /// stands is the whole question about something already on this Mac, and
    /// the daemon has already answered it ("Installed and turned off.",
    /// "Turned on and waiting for a sign-in.", "Connected as …"). A row that is
    /// not installed reads the manifest summary, because what it does is the
    /// only question there is about it yet.
    ///
    /// Drawing the summary wherever there was one is what hid the state: a
    /// plugin that was installed, switched on and signed in to nothing said
    /// `Read schedules, find availability` under a switch reading on, and
    /// people read "on" as "working". A row with no description falls to the
    /// same sentence, which is a state and never an empty line.
    public var subtitle: String {
        guard !installed else { return status }
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return status
        }

        return summary
    }

    /// The text the page's search filters on: the name and the description.
    public func matches(_ query: String) -> Bool {
        IntegrationSearch.matches(query, title: title, summary: summary)
    }
}

/// Turning `plugins.list` into rows (M34 §5.6).
public enum IntegrationRowProjection {
    public static func rows(_ catalog: ManagementPluginCatalog?) -> [IntegrationRowModel] {
        (catalog?.plugins ?? []).map { plugin in
            IntegrationRowModel(
                name: plugin.name,
                title: plugin.title,
                summary: plugin.summary,
                status: plugin.statusSentence,
                primaryAction: plugin.primaryAction,
                verb: plugin.primaryVerb,
                verbs: plugin.verbs,
                actions: plugin.actions,
                installed: plugin.installed,
                enabled: plugin.enabled,
                runtimeKind: plugin.runtimeKind,
                authKind: plugin.authKind,
                credentialPresent: plugin.credentialPresent,
                authProvider: plugin.authProvider,
                consent: plugin.consentSentence,
                disclosure: plugin.remoteDisclosure,
                accessProfiles: plugin.accessProfiles,
                workspaces: plugin.workspaces,
                workspaceLabel: plugin.workspaceLabel
            )
        }
    }

    /// The sign-in client this row's credential would be registered under.
    ///
    /// `auth_provider` is the daemon's own tie between a plugin and an entry in
    /// `oauth_clients`; deriving it from the plugin's name would be the app
    /// deciding which family a plugin signs in with.
    public static func client(
        for row: IntegrationRowModel,
        in catalog: ManagementPluginCatalog?
    ) -> ManagementPluginOAuthClient? {
        guard let provider = row.authProvider else { return nil }

        return catalog?.oauthClients.first { $0.provider == provider }
    }

    /// One plugin, by name, out of the catalogue the daemon last published.
    ///
    /// It is what lets a sheet address its plugin rather than capture it: every
    /// verb the sheet performs re-reads the catalogue, and a captured row would
    /// go on describing the state the sheet opened on.
    public static func row(named name: String, in catalog: ManagementPluginCatalog?) -> IntegrationRowModel? {
        precondition(!name.isEmpty, "a plugin is looked up by name")

        return rows(catalog).first { $0.name == name }
    }

    /// The counts the four pills carry. Features is a constant three: the
    /// native drivers are this build's, not the registry's.
    public static func counts(
        rows: [IntegrationRowModel],
        features: Int
    ) -> [IntegrationFilter: Int] {
        var counts: [IntegrationFilter: Int] = [.features: features]
        for filter in IntegrationFilter.allCases where filter != .features {
            counts[filter] = rows.filter(filter.admits).count
        }

        return counts
    }
}

extension ManagementPluginOAuthClient {
    /// The same provider can also be a plugin row in this List.
    var integrationListID: String { "oauth-client:\(provider)" }
}

/// Integrations, laid out as the Codex app's Plugins page (decision D6, owner
/// directive of 2026-09-03: "you have group them like the codex app does",
/// with that page supplied as the reference).
///
/// A page header carrying the pane title and a one-line subtitle, a row of
/// counted kind pills with the search field at its trailing edge, then a flat
/// list: icon tile, name, one-line description, trailing switch. No collapsible
/// groups and no box around the list — this is the one pane that is not a
/// grouped `Form`, because the shape the owner named has no boxes in it.
///
/// The list is the pane's own single scroll, which is how this page meets
/// decision D4's no-nested-scroll rule: the pills and the search keep it short,
/// and the long lists it can open (workspaces, models, apps) are sheets that own
/// their own.
///
/// Nothing here composes a status sentence: the row renders what the registry
/// said. There is no `Browse directory` action, because the catalog has no
/// directory to browse, and no `Add` menu, because nothing the daemon publishes
/// today is addable.
struct IntegrationsPane: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var work: JobRunner
    @State private var filter: IntegrationFilter = .installed
    @State private var query = ""
    @State private var consenting: IntegrationRowModel?
    @State private var detail: IntegrationRowModel?
    @State private var client: OAuthClientTarget?
    @State private var refusal: String?
    /// Which pane a Features row opens. The feature's own switch lives there
    /// and only there: a second switch here would be a second writer of one
    /// daemon key, and it would need that key's name written in Swift.
    let openPane: (SettingsPane) -> Void

    init(model: SettingsModel, openPane: @escaping (SettingsPane) -> Void) {
        self.model = model
        self.openPane = openPane
        _work = StateObject(wrappedValue: model.makeJobRunner())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header

            if model.requiresNewerEngine {
                NewerEngineNotice(sentence: model.newerEngineSentence)
            } else {
                list
            }
        }
        .padding(.horizontal, WindowMetrics.contentPadding)
        .padding(.top, Spacing.l)
        .frame(maxWidth: WindowMetrics.settingsContentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(SettingsPane.integrations.title)
        // The one pane that draws a page header of its own (the Codex-shaped
        // page the owner asked for), so the toolbar's inline title is removed
        // rather than left to say `Integrations` two lines above the header
        // that says it. The window keeps its title: it is what the Window menu
        // and Mission Control name this window by, and only its drawing in the
        // toolbar is dropped.
        .toolbar(removing: .title)
        .sheet(item: $consenting) { row in
            IntegrationConsentSheet(row: row, model: model, runner: work) { consentClosed(row) }
        }
        .sheet(item: $detail) { row in
            IntegrationDetailSheet(name: row.name, model: model, runner: work) { detail = nil }
        }
        .sheet(item: $client) { target in
            OAuthClientSheet(provider: target.provider, model: model) { client = nil }
        }
        .task { await model.refreshPlugins() }
    }

    private var rows: [IntegrationRowModel] {
        IntegrationRowProjection.rows(model.plugins.value)
    }

    private var visible: [IntegrationRowModel] {
        rows.filter { filter.admits($0) && $0.matches(query) }
    }

    private var features: [IntegrationFeature] {
        IntegrationFeature.rows(model.setupState.value?.features)
    }

    private var visibleFeatures: [IntegrationFeature] {
        features.filter { $0.matches(query) }
    }

    private var counts: [IntegrationFilter: Int] {
        IntegrationRowProjection.counts(rows: rows, features: features.count)
    }

    /// The page header: the title, a one-line subtitle, then the pill row with
    /// the search field at its trailing edge.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(SettingsPane.integrations.title)
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)

            Text(ProductStrings[.integrationsSubtitle])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.xs) {
                ForEach(IntegrationFilter.allCases) { entry in
                    IntegrationPill(
                        filter: entry,
                        count: counts[entry] ?? 0,
                        selected: entry == filter
                    ) {
                        filter = entry
                    }
                }

                Spacer(minLength: Spacing.s)

                search
            }
            .padding(.top, Spacing.xxs)
        }
    }

    /// The search field at the trailing edge of the pill row: a rounded search
    /// field with the magnifier at its leading edge, which is the control the
    /// reference page draws.
    private var search: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.faint.color)
                .accessibilityHidden(true)

            TextField(
                ProductStrings[.integrationsSearchPrompt],
                text: $query,
                prompt: Text(ProductStrings[.integrationsSearchPrompt])
            )
            .labelsHidden()
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(Palette.base200.color, in: Capsule())
        .frame(maxWidth: IntegrationMetrics.searchWidth)
        .accessibilityLabel(ProductStrings[.integrationsSearchPrompt])
    }

    /// The flat list, and the sign-in clients once at its foot. Features is the
    /// app's own three rows; every other pill is the registry's plugins.
    ///
    /// The one pane that builds its own scroll container rather than taking
    /// `SettingsPaneForm`'s, so it carries the same two rules that form does:
    /// indicators are never shown, and the fade marks the edge the content runs
    /// past. This is the list that has to scroll, because the registry decides
    /// how many rows there are and the window does not.
    /// No rules between rows (owner directive of 2026-09-03: "remove any extra
    /// horizontal separation. keep it clean"). A plain `List` draws a separator
    /// under every row, which on a page whose rows are already an icon tile plus
    /// two lines of text reads as a ruled ledger. The rhythm is the row's own
    /// vertical padding, which is what separates them now.
    ///
    /// `listRowSeparator` is a **row** modifier, so it is written on each of
    /// the list's own children rather than once on the list: on the container
    /// it is not the row it names, and a rule left behind at the foot of the
    /// page is exactly what the directive is about.
    private var list: some View {
        List {
            if filter == .features {
                ForEach(visibleFeatures) { feature in
                    IntegrationFeatureRow(feature: feature) { openPane(feature.pane) }
                }
                .listRowSeparator(.hidden)
            } else if visible.isEmpty {
                Text(ProductStrings[.integrationsNoResults])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { row in
                    IntegrationRow(row: row, open: { detail = row }, setEnabled: setEnabled)
                }
                .listRowSeparator(.hidden)
            }

            if let refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityAddTraits(.updatesFrequently)
                    .listRowSeparator(.hidden)
            }

            clients
        }
        .listStyle(.plain)
        .id(filter)
        .id(query)
        .id(model.plugins.value != nil)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        .paneScrollEdges()
    }

    /// The sign-in clients the operator registered, as one section at the foot
    /// of the list rather than a group per provider (decision D6). Only
    /// providers whose plugin exists appear, which is the daemon's own list.
    @ViewBuilder
    private var clients: some View {
        let entries = model.plugins.value?.oauthClients ?? []

        if !entries.isEmpty {
            Section(ProductStrings[.integrationsClientsSection]) {
                ForEach(entries, id: \.integrationListID) { entry in
                    OAuthClientRow(client: entry) { client = OAuthClientTarget(provider: entry.provider) }
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    /// The row's switch. Enabling something not yet installed raises the
    /// consent sheet first, so it is one gesture rather than two (decision D6).
    private func setEnabled(_ row: IntegrationRowModel, _ isOn: Bool) {
        guard row.installed else {
            consenting = row
            return
        }

        Task { show(await model.setPluginEnabled(isOn, on: row.name, runner: work)) }
    }

    /// The consent sheet closed. Whatever it did, what happens next is the
    /// daemon's answer for that row: an install that finished leaves a plugin
    /// that may still need its sign-in, and a cancel leaves one that is not
    /// installed and leads with `Install…`, which opens nothing.
    ///
    /// Asked for on the turn after the sheet has gone, because these are two
    /// sheets over one window and the detail is the one that has to be left
    /// standing.
    private func consentClosed(_ row: IntegrationRowModel) {
        consenting = nil
        Task { show(model.nextStep(after: row.name)) }
    }

    /// What the page does with a switch's outcome: the daemon's sentence on the
    /// page, the row's detail, or nothing.
    private func show(_ outcome: SettingsModel.IntegrationEnableOutcome) {
        switch outcome {
        case .refused(let sentence):
            refusal = sentence
        case .configure(let row):
            refusal = nil
            detail = row
        case .done:
            refusal = nil
        }
    }
}

/// One kind pill: its title, its live count beside it, filled while it is the
/// selection.
struct IntegrationPill: View {
    let filter: IntegrationFilter
    let count: Int
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Spacing.xxs) {
                Text(filter.title)
                    .foregroundStyle(selected ? Palette.ink.color : Palette.secondary.color)

                Text(String(count))
                    .foregroundStyle(Palette.faint.color)
            }
            .fermixType(Typography.style(.calloutSmall))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(selected ? Palette.base200.color : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ProductStrings.commaPair(filter.title, String(count)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// One plugin row: the mark, the name over its second line, the chevron that
/// says the row opens something, and the switch. The whole row but the switch
/// opens the detail.
///
/// The second line is `IntegrationRowModel.subtitle`, which is where it stands
/// once it is installed and what it does while it is not.
///
/// The chevron and the hover fill are the row's whole claim to being
/// clickable. Without them the row opened a sheet on a click nothing had
/// advertised: no pointer change, no highlight, and a trailing switch that
/// read as the only control on the line.
struct IntegrationRow: View {
    let row: IntegrationRowModel
    let open: () -> Void
    let setEnabled: (IntegrationRowModel, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button(action: open) {
                HStack(spacing: Spacing.s) {
                    PluginMarkTile(name: row.name, size: IntegrationMetrics.tileSize)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .fermixType(Typography.style(.callout).weight(.medium))
                            .foregroundStyle(Palette.ink.color)
                            .lineLimit(1, reservesSpace: true)

                        Text(row.subtitle)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                            .lineLimit(1, reservesSpace: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint.color)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityLabel)

            // Stated for the same reason `ChannelRow` states it: this row is
            // hand-built rather than a grouped-form row, so the switch has to
            // be asked for or the control arrives as a checkbox.
            Toggle(row.title, isOn: enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.integrationEnabled], row.title))
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.xs)
        .background(hovering ? Palette.base200.color : .clear, in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { row.enabled }, set: { isOn in setEnabled(row, isOn) })
    }
}

/// The page's own geometry: one number, the icon tile.
enum IntegrationMetrics {
    /// The rounded square holding the vendor mark, from redlines §5.8.
    static let tileSize: Double = 28
    /// The search field at the trailing edge of the pill row.
    static let searchWidth: Double = 200
}
