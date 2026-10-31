import SwiftUI

/// The pages of the one Cues sheet (M60 app surface §4.3 to §4.5).
///
/// The sheet adds and shows a source, shows a watcher, and shows, approves
/// and writes a mandate without ever raising a second popup: each step is a
/// page it turns to, or a state drawn in place (§4.10).
public enum CuesSheetPage: Equatable, Sendable {
    case addSource
    /// A source's detail, with the secret it waits for drawn first where a
    /// row opened it to store that secret.
    case source(String, at: ManagementCueSecretField?)
    case editSource(String)
    case watcher(String)
    /// A mandate's detail, with Approve already asked where the row's own
    /// Approve opened it.
    case mandate(String, approving: Bool)
    case addMandate
    case editMandate(String)

    /// Where Escape and the back control go. Nil closes the sheet: every
    /// page a row opens is a page the sheet opens on.
    public var back: CuesSheetPage? {
        switch self {
        case .addSource, .source, .watcher, .mandate, .addMandate: return nil
        case .editSource(let ref): return .source(ref, at: nil)
        case .editMandate(let name): return .mandate(name, approving: false)
        }
    }

    /// Where a source row opens: its detail, at the secret the daemon says
    /// it waits for where its primary action points at one: `set_secret` at
    /// a secret the owner types, `new_token` at the token only Fermix makes.
    /// Read from the published action and field, never from the state.
    public static func opening(_ source: ManagementCueSource) -> CuesSheetPage {
        guard let primary = source.primaryAction, source.actions.contains(primary),
              let field = source.missingSecret
        else { return .source(source.ref, at: nil) }

        switch primary {
        case .setSecret where field.isTyped, .newToken where field == .token:
            return .source(source.ref, at: field)
        default:
            return .source(source.ref, at: nil)
        }
    }

    /// Where the add form turns once it has sent: nowhere while the daemon
    /// refused the add, and otherwise the new source's detail, at the secret
    /// whose store was refused where one was.
    public static func after(_ outcome: CueSourceAddOutcome) -> CuesSheetPage? {
        switch outcome {
        case .refused:
            return nil
        case .added(let ref, _, _, let unstored):
            let field = unstored?.field.map(ManagementCueSecretField.init(wireValue:))
            return .source(ref, at: field?.isTyped == true ? field : nil)
        }
    }
}

/// A value Fermix handed out for one source, shown once: a local push
/// source's token, or the secret it made for a GitHub source with the notes
/// of the form it was added from, which say where that secret goes.
public struct CueHandedToken: Equatable, Sendable {
    public let ref: String
    /// Which of the source's secrets it is: `token` or `secret`.
    public let field: ManagementCueSecretField
    public let value: String
    public let notes: [String]

    public init(ref: String, field: ManagementCueSecretField = .token, value: String, notes: [String] = []) {
        precondition(!value.isEmpty, "a handed token has a value")
        precondition(field == .token || field == .secret, "Fermix hands out a token, or a secret it made")
        self.ref = ref
        self.field = field
        self.value = value
        self.notes = notes
    }
}

/// The sheet's page, and what it holds only for as long as that page shows:
/// a token or a secret handed out on it, and the refusal of a secret the add
/// could not store. Turning the page drops both, which is the rule that
/// keeps a handed value out of the view once its page has changed (§4.3).
public struct CuesSheetState: Equatable, Sendable {
    public private(set) var page: CuesSheetPage
    public private(set) var token: CueHandedToken?
    public private(set) var unstored: CueRefusal?

    public init(page: CuesSheetPage) {
        self.page = page
    }

    public mutating func turn(to page: CuesSheetPage) {
        self.page = page
        token = nil
        unstored = nil
    }

    /// The add's outcome: the new source's detail, its token or the secret
    /// Fermix made for it with the form's `notes`, and the refusal of a
    /// secret it could not store, all on that one page.
    public mutating func added(_ outcome: CueSourceAddOutcome, notes: [String] = []) {
        guard let next = CuesSheetPage.after(outcome),
              case .added(let ref, let token, let secret, let unstored) = outcome
        else { return }

        turn(to: next)
        self.token = token.map { CueHandedToken(ref: ref, value: $0) }
            ?? secret.map { CueHandedToken(ref: ref, field: .secret, value: $0, notes: notes) }
        self.unstored = unstored
    }

    public mutating func hand(_ token: CueHandedToken) {
        self.token = token
    }
}

/// What the pane presents the sheet for.
struct CuesSheetTarget: Identifiable, Equatable {
    let page: CuesSheetPage

    var id: String {
        switch page {
        case .addSource: return "source:add"
        case .source(let ref, _), .editSource(let ref): return "source:\(ref)"
        case .watcher(let name): return "watcher:\(name)"
        case .addMandate: return "mandate:add"
        case .mandate(let name, _), .editMandate(let name): return "mandate:\(name)"
        }
    }
}

/// A provider chosen for the default filter model, whose model the listing
/// sheet asks for next (§4.6).
struct CueModelPick: Identifiable, Equatable {
    let provider: String
    var id: String { provider }
}

/// The sheet's own geometry.
enum CuesSheetMetrics {
    /// The integration detail's width, so the sheets of Settings are one size
    /// across (§4.3).
    static let width: Double = SheetMetrics.pickerSize.width
    /// How long a change to the check rests before the daemon is asked for
    /// the form again.
    static let formPause: TimeInterval = 0.25
}

/// Settings, Connections, Cues (M60 app surface §4.2, simpler setup §4).
///
/// One line under the toolbar's title, then the `cues` section's own
/// descriptor rows in one group: Run cues, how watchers judge items, and,
/// folded under Advanced, the door. Below it, the proposals waiting, then
/// the lists as compact rows, each in the daemon's words, each drawn once it
/// means something: the first-run card until a source exists. Drawn at all
/// only where the daemon serves cues; with them missing the pane is empty
/// and the sidebar lists no Cues row.
struct CuesPane: View {
    @ObservedObject var model: SettingsModel
    let router: any CommandPerforming

    @State private var sheet: CuesSheetTarget?
    @State private var modelPick: CueModelPick?
    /// A refusal from a row's switch, or what a removal could not delete.
    @State private var notice: String?

    var body: some View {
        SettingsPaneForm(title: SettingsPane.cues.title) {
            if model.drawsCuesPane {
                CuesSettingsSection(model: model, router: router) { modelPick = CueModelPick(provider: $0) }
                CuesWaitingSection(model: model)
                lists
            }
        }
        .task(id: model.drawsCuesPane) {
            guard model.drawsCuesPane else { return }

            await model.refreshCues()
        }
        .sheet(item: $sheet) { target in
            CuesSheet(opening: target.page, model: model) { left in
                notice = left
                sheet = nil
            }
            .sheetGround()
        }
        .sheet(item: $modelPick) { pick in
            ModelPickerSheet(provider: pick.provider, model: model) { chosen in
                Task { await model.applyFilterModel(provider: pick.provider, model: chosen) }
            } dismiss: {
                model.dropFilterProviderDraft()
                modelPick = nil
            }
            .sheetGround()
        }
    }

    /// The sources, or the first-run card in their place, then the watchers
    /// and the mandates once each means something (simpler setup §4).
    @ViewBuilder
    private var lists: some View {
        if CuesPaneLayout.firstRun(model.cueSources) {
            CuesFirstRunSection(notice: notice, add: model.cueSources.value?.canAdd == true ? addSource : nil)
        } else {
            CuesSourcesSection(model: model, notice: $notice) { sheet = CuesSheetTarget(page: $0) }
        }
        if CuesPaneLayout.drawsWatchers(sources: model.cueSources, watchers: model.cueWatchers) {
            CuesWatchersSection(model: model) { sheet = CuesSheetTarget(page: $0) }
        }
        if CuesPaneLayout.drawsMandates(watchers: model.cueWatchers, mandates: model.cueMandates) {
            CuesMandatesSection(model: model, notice: $notice) { sheet = CuesSheetTarget(page: $0) }
        }
    }

    private func addSource() {
        sheet = CuesSheetTarget(page: .addSource)
    }
}

/// Which of the pane's lists are drawn (simpler setup §4), from what their
/// reads answered. Only a loaded list counts: one still being read, or one
/// the daemon refused, is neither empty nor holding anything.
public enum CuesPaneLayout {
    /// The first-run card stands where the sources would be while the
    /// daemon lists none.
    public static func firstRun(_ sources: SettingsReadState<ManagementCueSourceList>) -> Bool {
        sources.value?.sources.isEmpty == true
    }

    /// Watchers once a source exists, or a watcher does.
    public static func drawsWatchers(
        sources: SettingsReadState<ManagementCueSourceList>,
        watchers: SettingsReadState<ManagementCueWatcherList>
    ) -> Bool {
        sources.value?.sources.isEmpty == false || watchers.value?.watchers.isEmpty == false
    }

    /// Mandates once a watcher exists, since a mandate needs a task that
    /// runs on cues, or a mandate does.
    public static func drawsMandates(
        watchers: SettingsReadState<ManagementCueWatcherList>,
        mandates: SettingsReadState<ManagementCueMandateList>
    ) -> Bool {
        watchers.value?.watchers.isEmpty == false || mandates.value?.mandates.isEmpty == false
    }
}

/// The first run (simpler setup §4): while no source exists, one card in
/// place of the lists says how cues work in three steps, with the way to add
/// the first source under them.
struct CuesFirstRunSection: View {
    /// What a removal could not delete, said once as on the sources list.
    let notice: String?
    /// Opens the add sheet, where the daemon lets a source be added.
    let add: (() -> Void)?

    private static let steps: [ProductStringKey] = [.cuesFirstRunSource, .cuesFirstRunWatcher, .cuesFirstRunTask]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(ProductStrings[.cuesFirstRunTitle])
                    .fermixType(Typography.style(.callout))
                    .foregroundStyle(Palette.ink.color)

                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: "\(index + 1).circle")
                            .foregroundStyle(Palette.secondary.color)
                            .accessibilityHidden(true)
                        CueNote(text: ProductStrings[step])
                    }
                }

                if let add {
                    PrimaryAction(ProductStrings[.cuesFirstRunAdd], size: .row, action: add)
                        .padding(.top, Spacing.xxs)
                }
                if let notice {
                    CueNote(text: notice, attention: true)
                }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.s)
        }
    }
}

/// The pane's one line, and the way to the cues guide beside it.
struct CuesPaneLead: View {
    @ObservedObject var model: SettingsModel
    @Binding var refusal: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(ProductStrings[.cuesSubtitle])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.s)

            LinkButton(title: ProductStrings[.cuesLearnMore]) { refusal = model.openCuesGuide() }
                .fermixType(Typography.style(.calloutSmall))
        }
        .textCase(nil)
    }
}

/// The `cues` section's rows in one group (§4.2, §4.6, simpler setup §4),
/// in the order the section publishes them: Run cues with the status under
/// it, Let watchers act, then how watchers judge items, the Screen where the
/// section publishes one and the filter model, then any other row, and the
/// door's port with the door's line folded under Advanced. A door that could
/// not open says so in the open.
struct CuesSettingsSection: View {
    @ObservedObject var model: SettingsModel
    let router: any CommandPerforming
    /// Opens the model listing for a provider just chosen.
    let pickModel: (String) -> Void

    @State private var guideRefusal: String?

    var body: some View {
        Section {
            DescriptorRows(model: model, section: CueFilterPair.section, specialised: specialised)

            if let door, CueTone.door(door) == .warn {
                CueStatusLine(text: door.sentence, tone: .warn, attention: true)
            }
            if let guideRefusal {
                CueNote(text: guideRefusal, attention: true)
            }
        } header: {
            CuesPaneLead(model: model, refusal: $guideRefusal)
        }
    }

    private var door: ManagementCueStatus.Door? { model.cueStatus.value?.door }

    /// The row the pane places itself, under the heading where it is the
    /// first of how watchers judge items. Every other row is drawn as the
    /// section publishes it.
    private func specialised(_ row: ManagementSettingRow) -> AnyView? {
        let placed = placedRow(row)
        guard row.key == judgingHeadingKey else { return placed }

        return AnyView(
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(ProductStrings[.cuesJudgingTitle])
                    .fermixType(Typography.style(.callout))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                placed ?? AnyView(DescriptorRow(model: model, section: CueFilterPair.section, row: row))
            }
        )
    }

    private var judgingHeadingKey: String? {
        CuesPaneKeys.judgingHeadingKey(in: model.section(CueFilterPair.section).value?.rows ?? [])
    }

    private func placedRow(_ row: ManagementSettingRow) -> AnyView? {
        switch row.key {
        case CuesPaneKeys.enabled: return AnyView(enabledRow(row))
        case CuesPaneKeys.doorPort: return AnyView(doorRow(row))
        case CueFilterPair.providerKey: return AnyView(providerRow(row))
        case CueFilterPair.modelKey: return modelRow(row)
        default: return nil
        }
    }

    /// The Cues switch carries the line under it: the restart the daemon
    /// asks for, from the pane's own restart transaction, or the status
    /// sentence.
    private func enabledRow(_ row: ManagementSettingRow) -> some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            DescriptorRow(model: model, section: CueFilterPair.section, row: row)
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let reasons = model.restart.reasons.filter { $0.section == CueFilterPair.section }

        if !reasons.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                CueStatusLine(text: reasons.map(\.sentence).joined(separator: " "), tone: .warn)
                Spacer(minLength: Spacing.s)
                Button(ProductStrings[.settingsRestartAction]) { router.perform(.restartDaemon) }
                    .disabled(!router.canPerform(.restartDaemon))
            }
        } else if let status = model.cueStatus.value {
            CueStatusLine(text: status.statusSentence, tone: CueTone.status(status))
        }
    }

    /// The door's port, folded under Advanced by the daemon's mark, with the
    /// door's own line under it while it has nothing to warn of.
    private func doorRow(_ row: ManagementSettingRow) -> some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            DescriptorRow(model: model, section: CueFilterPair.section, row: row)

            if let door, CueTone.door(door) != .warn {
                CueStatusLine(text: door.sentence, tone: CueTone.door(door))
            }
        }
    }

    /// The filter model's pop-up: the main model first, as the daemon names
    /// it, then the providers that are set up. Choosing a provider holds it
    /// and opens the model listing at once; choosing the main model clears
    /// the pair.
    private func providerRow(_ row: ManagementSettingRow) -> DescriptorRow {
        let key = SettingsDraftKey(section: CueFilterPair.section, key: row.key)

        return DescriptorRow(
            model: model,
            section: CueFilterPair.section,
            row: row,
            held: DescriptorHeldValue(
                value: model.value(of: row, in: CueFilterPair.section),
                refusal: model.message(for: key),
                change: { value in
                    let provider = DescriptorValue.text(value)
                    guard !provider.isEmpty else {
                        Task { await model.clearFilterModel() }
                        return
                    }

                    model.holdFilterProvider(provider)
                    pickModel(provider)
                }
            )
        )
    }

    /// The model row, for the provider chosen: the typeahead where the
    /// daemon offers suggestions, the listing where its list is the
    /// account's own. On the main model there is no model to choose here.
    private func modelRow(_ row: ManagementSettingRow) -> AnyView? {
        let provider = model.savedFilterProvider
        guard !provider.isEmpty else { return AnyView(EmptyView()) }

        switch row.modelRowForm {
        case .typeahead:
            return AnyView(ModelTypeaheadRow(row: row, section: CueFilterPair.section, provider: provider, model: model))
        case .listing:
            return AnyView(ModelChoiceRow(row: row, section: CueFilterPair.section, model: model) { pickModel(provider) })
        case nil:
            return nil
        }
    }
}

/// The `cues` section's keys the pane places itself.
enum CuesPaneKeys {
    static let enabled = "cues_enabled"
    static let screen = "cues_screen_provider"
    static let doorPort = "cues_door_port"

    /// The row "How watchers judge items" heads: the Screen, which newer
    /// engines publish just before the filter model, or else the filter
    /// model.
    static func judgingHeadingKey(in rows: [ManagementSettingRow]) -> String? {
        rows.first { $0.key == screen || $0.key == CueFilterPair.providerKey }?.key
    }
}

/// "Waiting for you": Fermix's record of each proposal waiting, drawn only
/// while one waits. Deciding happens on the card in Chat, in one place.
struct CuesWaitingSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let proposals = model.cueProposals.value?.proposals, !proposals.isEmpty {
            Section {
                ForEach(proposals, id: \.proposalId) { proposal in
                    CuesWaitingRow(proposal: proposal) { model.showChat(at: proposal.proposalId) }
                }
            } header: {
                CuesSectionHeader(title: .cuesWaitingTitle, count: proposals.count, action: nil) {}
            }
        }
    }
}

/// One proposal waiting: the mandate, the tool and the expiry, and the way to
/// its card. No argument and no cue text is on the record, so none is here.
struct CuesWaitingRow: View {
    let proposal: ManagementCueProposal
    let show: () -> Void

    var body: some View {
        CueRow(
            symbol: "hand.raised",
            title: line,
            status: waits,
            tone: .warn,
            accessibilityLabel: ProductStrings.commaPair(line, waits)
        ) {
            Button(ProductStrings[.cuesWaitingShowInChat], action: show)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesWaitingShowInChat], proposal.mandate))
        }
    }

    private var line: String {
        String(format: ProductStrings[.cuesWaitingRowFormat], proposal.mandate, proposal.tool)
    }

    private var waits: String {
        let expiry = ManagementCueTime.date(proposal.expiresAt).map { CueTimes.time($0) } ?? proposal.expiresAt
        return String(format: ProductStrings[.proposalWaitsUntilFormat], expiry)
    }
}

/// A list the daemon refused or has not answered yet, in its own words.
struct CuesListState<Value: Equatable & Sendable, Rows: View>: View {
    let state: SettingsReadState<Value>
    @ViewBuilder let rows: (Value) -> Rows

    var body: some View {
        switch state {
        case .unread, .loading:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .loaded(let value):
            rows(value)
        case .unavailable(let sentence):
            CueNote(text: sentence, attention: true)
        case .requiresNewerEngine:
            EmptyView()
        }
    }
}

/// The sources (§4.3). With none, the first-run card stands here instead.
struct CuesSourcesSection: View {
    @ObservedObject var model: SettingsModel
    @Binding var notice: String?
    let open: (CuesSheetPage) -> Void

    var body: some View {
        Section {
            CuesListState(state: model.cueSources) { list in
                ForEach(list.sources, id: \.ref) { source in
                    CuesSourceRow(source: source, setEnabled: setEnabled) { open(CuesSheetPage.opening(source)) }
                }
            }
            if let notice {
                CueNote(text: notice, attention: true)
            }
        } header: {
            CuesSectionHeader(
                title: .cuesSourcesTitle,
                count: model.cueSources.value?.sources.count,
                action: canAdd ? .cuesSourcesAdd : nil
            ) { open(.addSource) }
        }
    }

    private var canAdd: Bool { model.cueSources.value?.canAdd == true }

    private func setEnabled(_ source: ManagementCueSource, _ isOn: Bool) {
        Task { notice = await model.setCueSourceEnabled(isOn, ref: source.ref)?.sentence }
    }
}

/// One source: its kind's symbol, its name, the daemon's sentence after the
/// dot, and its switch.
struct CuesSourceRow: View {
    let source: ManagementCueSource
    let setEnabled: (ManagementCueSource, Bool) -> Void
    let open: () -> Void

    var body: some View {
        CueRow(
            symbol: CueSourceProjection.symbol(for: source.kind),
            mark: CueSourceProjection.mark(for: source),
            title: source.ref,
            status: source.statusSentence,
            tone: CueTone.source(source),
            attention: CueTone.isLoud(CueTone.source(source)),
            accessibilityLabel: ProductStrings.commaPair(ProductStrings.commaPair(source.ref, source.label), source.statusSentence),
            open: open
        ) {
            // Stated as `IntegrationRowLayout` states it: this row is hand
            // built, so the switch has to be asked for.
            if CueSourceProjection.switchShown(source) {
                Toggle(source.ref, isOn: Binding(get: { source.enabled }, set: { setEnabled(source, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.integrationEnabled], source.ref))
            }
        }
    }
}

/// The 28-point tile a source is drawn with: its vendor's mark where the
/// app ships one for its preset, a symbol by kind otherwise, labelled with
/// the kind's name.
struct CuesSourceTile: View {
    let source: ManagementCueSource

    var body: some View {
        Group {
            if let mark = CueSourceProjection.mark(for: source) {
                VendorMarkView(mark: mark, kind: .plugin, size: IntegrationMetrics.tileSize)
            } else {
                VendorMarkView(symbol: CueSourceProjection.symbol(for: source.kind), size: IntegrationMetrics.tileSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.label)
    }
}

/// What a source row draws, from its published facts.
public enum CueSourceProjection {
    public static func symbol(for kind: ManagementCueSourceKind) -> String {
        switch kind {
        case .feed: return "newspaper"
        case .stream: return "antenna.radiowaves.left.and.right"
        case .webhook: return "link"
        case .localPush: return "terminal"
        case .unrecognized: return "dot.radiowaves.left.and.right"
        }
    }

    /// The plugin marks the app ships for two presets: X accounts reads with
    /// the X plugin's sign-in, and GitHub is GitHub's.
    static let pluginMarks = ["x_accounts": "x", "github": "github"]

    /// The vendor mark a source of this preset is drawn with, light and dark
    /// as the plugin rows draw it, or nil for its kind's symbol.
    public static func mark(forPreset preset: String?) -> VendorMark? {
        preset.flatMap { pluginMarks[$0] }.flatMap { VendorMarks.mark(.plugin, $0) }
    }

    public static func mark(for source: ManagementCueSource) -> VendorMark? {
        mark(forPreset: source.preset)
    }

    /// The switch is drawn where the daemon publishes a way to throw it.
    public static func switchShown(_ source: ManagementCueSource) -> Bool {
        source.actions.contains(.enable) || source.actions.contains(.disable)
    }

    /// The secrets the detail draws, the one a row opened it for first.
    public static func secrets(_ source: ManagementCueSource, first field: ManagementCueSecretField?) -> [ManagementCueSecretSlot] {
        guard let field, let index = source.secrets.firstIndex(where: { $0.field == field }) else { return source.secrets }

        var ordered = source.secrets
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}

/// The watchers, read-only (§4.4).
struct CuesWatchersSection: View {
    @ObservedObject var model: SettingsModel
    let open: (CuesSheetPage) -> Void

    var body: some View {
        Section {
            CuesListState(state: model.cueWatchers) { list in
                if list.watchers.isEmpty {
                    CueNote(text: ProductStrings[.cuesWatchersEmpty])
                }
                ForEach(list.watchers, id: \.id) { watcher in
                    CuesWatcherRow(watcher: watcher) { open(.watcher(watcher.name)) }
                }
            }
        } header: {
            CuesSectionHeader(
                title: .cuesWatchersTitle,
                count: model.cueWatchers.value?.watchers.count,
                info: .cuesWatchersFooter,
                action: nil
            ) {}
        }
    }
}

/// One watcher: its name and the sources it listens to, and the daemon's
/// sentence after the dot. The day's counts are on its page. Never anything
/// a watcher read.
struct CuesWatcherRow: View {
    let watcher: ManagementCueWatcher
    let open: () -> Void

    var body: some View {
        CueRow(
            symbol: CueWatcherProjection.symbol,
            title: watcher.name,
            qualifier: watcher.sources.joined(separator: ", "),
            status: watcher.statusSentence,
            tone: CueTone.watcher(watcher),
            attention: watcher.state.drawsAttention,
            accessibilityLabel: ProductStrings.commaPair(watcher.name, watcher.statusSentence),
            open: open
        ) {
            EmptyView()
        }
    }
}

/// How a watcher is drawn.
enum CueWatcherProjection {
    static let symbol = "eye"
}

/// The mandates (§4.5).
struct CuesMandatesSection: View {
    @ObservedObject var model: SettingsModel
    @Binding var notice: String?
    let open: (CuesSheetPage) -> Void

    var body: some View {
        Section {
            CuesListState(state: model.cueMandates) { list in
                if list.mandates.isEmpty {
                    CueNote(text: ProductStrings[.cuesMandatesEmpty])
                }
                ForEach(list.mandates, id: \.name) { mandate in
                    CuesMandateRow(
                        mandate: mandate,
                        // A write is refused while the settings file changed
                        // outside Fermix, so its controls do not move then.
                        blocked: model.writesBlocked,
                        setEnabled: { isOn in
                            Task { notice = await model.setCueMandateEnabled(isOn, name: mandate.name)?.sentence }
                        },
                        approve: { open(.mandate(mandate.name, approving: true)) },
                        open: { open(.mandate(mandate.name, approving: false)) }
                    )
                }
            }
        } header: {
            CuesSectionHeader(
                title: .cuesMandatesTitle,
                count: model.cueMandates.value?.mandates.count,
                action: canAdd ? .cuesMandatesAdd : nil
            ) { open(.addMandate) }
        }
    }

    private var canAdd: Bool { model.cueMandates.value?.canAdd == true }
}

/// One mandate: its name and task, its mode as a tag in the app's words,
/// the daemon's sentence after the dot, then Approve where the daemon leads
/// with it and the switch.
struct CuesMandateRow: View {
    let mandate: ManagementCueMandate
    let blocked: Bool
    let setEnabled: (Bool) -> Void
    let approve: () -> Void
    let open: () -> Void

    var body: some View {
        CueRow(
            symbol: CueMandateProjection.symbol,
            title: mandate.name,
            qualifier: mandate.job.name ?? mandate.job.id,
            tag: CueMandateProjection.tag(mandate),
            status: mandate.statusSentence,
            tone: CueTone.mandate(mandate),
            accessibilityLabel: ProductStrings.commaPair(mandate.name, mandate.statusSentence),
            open: open
        ) {
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        if CueMandateProjection.offersApprove(mandate) {
            Button(ProductStrings[.cuesMandateApprove], action: approve)
                .buttonStyle(SecondaryButtonStyle(.row))
                .disabled(blocked)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesMandateApprove], mandate.name))
        }

        if CueMandateProjection.switchShown(mandate) {
            Toggle(mandate.name, isOn: Binding(get: { mandate.enabled }, set: setEnabled))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(blocked)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.integrationEnabled], mandate.name))
        }
    }
}

/// What a mandate's rows say and offer, from its published facts.
public enum CueMandateProjection {
    static let symbol = "checkmark.shield"

    /// The mode in the app's words, or nil for one this build does not know.
    public static func modeTitle(_ mode: ManagementCueMandateMode) -> String? {
        switch mode {
        case .approve: return ProductStrings[.cuesMandateModeApprove]
        case .auto: return ProductStrings[.cuesMandateModeAuto]
        case .unrecognized: return nil
        }
    }

    /// The mode as the row's tag: amber where it acts without asking, and no
    /// tag for a mode this build does not know.
    public static func tag(_ mandate: ManagementCueMandate) -> CueTagModel? {
        modeTitle(mandate.mode).map { CueTagModel(text: $0, tone: mandate.mode == .auto ? .warn : .neutral) }
    }

    /// Approve is offered where the daemon leads with it and publishes it.
    /// An inactive mandate publishes neither.
    public static func offersApprove(_ mandate: ManagementCueMandate) -> Bool {
        mandate.primaryAction == .approve && mandate.actions.contains(.approve)
    }

    public static func switchShown(_ mandate: ManagementCueMandate) -> Bool {
        mandate.actions.contains(.enable) || mandate.actions.contains(.disable)
    }
}

/// The one Cues sheet: 520 points wide, sized to the page it shows, and it
/// presents nothing; every step is a page of it or a state drawn in place.
struct CuesSheet: View {
    @ObservedObject var model: SettingsModel
    /// Closes the sheet, with what a removal could not delete where it left
    /// something, for the pane to say once.
    let dismiss: (String?) -> Void

    @State private var state: CuesSheetState
    @State private var sourceForm = CueSourceFormState()
    @State private var mandateForm = CueMandateFormState()

    init(opening: CuesSheetPage, model: SettingsModel, dismiss: @escaping (String?) -> Void) {
        self.model = model
        self.dismiss = dismiss
        _state = State(initialValue: CuesSheetState(page: opening))
    }

    var body: some View {
        page
            .padding(WindowMetrics.contentPadding)
            .frame(width: CuesSheetMetrics.width)
            // As tall as its page, up to the picker's height, past which the
            // page's form scrolls (`CuesPageForm`).
            .frame(maxHeight: SheetMetrics.pickerSize.height)
            // Escape goes back a page, or closes the sheet from the page it
            // opened on. A field being edited answers it first.
            .onExitCommand(perform: escape)
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .addSource, .editSource:
            CuesSourceFormPage(page: state.page, form: $sourceForm, model: model, added: added, openPlugin: openPlugin) {
                turn(back)
            }
        case .source(let ref, let at):
            CuesSourceDetailPage(
                ref: ref, at: at, token: state.token, unstored: state.unstored, model: model,
                hand: { state.hand($0) },
                edit: { detail in
                    sourceForm = CueSourceFormState(editing: detail)
                    turn(.editSource(ref))
                },
                done: dismiss
            )
        case .watcher(let name):
            CuesWatcherPage(name: name, model: model) { dismiss(nil) }
        case .mandate(let name, let approving):
            CuesMandateDetailPage(name: name, approving: approving, model: model, edit: { mandate in
                mandateForm = CueMandateFormState(editing: mandate)
                turn(.editMandate(name))
            }, done: { dismiss(nil) })
        case .addMandate, .editMandate:
            CuesMandateFormPage(page: state.page, form: $mandateForm, model: model, done: mandateSent) { turn(back) }
        }
    }

    private var back: CuesSheetPage? { state.page.back }

    /// The add went through: the form, and every secret typed in it, is
    /// forgotten, and the sheet turns to the new source, with the form's
    /// notes beside a secret Fermix made for it.
    private func added(_ outcome: CueSourceAddOutcome) {
        let notes = sourceForm.notes
        sourceForm = CueSourceFormState()
        state.added(outcome, notes: notes)
    }

    /// A requirement's plugin: the sheet closes, and Integrations opens at
    /// that plugin's page.
    private func openPlugin(_ name: String) {
        dismiss(nil)
        model.showPluginPage(name)
    }

    private func mandateSent(_ name: String) {
        mandateForm = CueMandateFormState()
        turn(.mandate(name, approving: false))
    }

    private func turn(_ page: CuesSheetPage?) {
        guard let page else {
            dismiss(nil)
            return
        }

        state.turn(to: page)
    }

    private func escape() {
        guard model.editingRow == nil else {
            model.revertEdit()
            return
        }

        turn(back)
    }
}
