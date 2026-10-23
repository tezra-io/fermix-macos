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
        case .added(let ref, _, let unstored):
            let field = unstored?.field.map(ManagementCueSecretField.init(wireValue:))
            return .source(ref, at: field?.isTyped == true ? field : nil)
        }
    }
}

/// A token Fermix handed out for one source, shown once.
public struct CueHandedToken: Equatable, Sendable {
    public let ref: String
    public let value: String

    public init(ref: String, value: String) {
        precondition(!value.isEmpty, "a handed token has a value")
        self.ref = ref
        self.value = value
    }
}

/// The sheet's page, and what it holds only for as long as that page shows:
/// a token handed out on it, and the refusal of a secret the add could not
/// store. Turning the page drops both, which is the rule that keeps a token
/// out of the view once its page has changed (§4.3).
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

    /// The add's outcome: the new source's detail, its token and the
    /// refusal of a secret it could not store, all on that one page.
    public mutating func added(_ outcome: CueSourceAddOutcome) {
        guard let next = CuesSheetPage.after(outcome), case .added(let ref, let token, let unstored) = outcome else { return }

        turn(to: next)
        self.token = token.map { CueHandedToken(ref: ref, value: $0) }
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
    /// How long changes to the kind, the preset or the check rest before the
    /// daemon is asked for the form again.
    static let formPause: TimeInterval = 0.25
}

/// The cue rows' times as the pane draws them: the time alone today, the date
/// beside it otherwise.
enum CueTimes {
    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Settings, Connections, Cues (M60 app surface §4.2).
///
/// The top block is the `cues` section's own descriptor rows, with the
/// default filter model drawn by the model rows. Below it, the proposals
/// waiting, then the three lists, each in the daemon's words. Drawn at all
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
                CuesSwitchesSection(model: model, router: router)
                CuesFilterSection(model: model) { modelPick = CueModelPick(provider: $0) }
                CuesWaitingSection(model: model)
                CuesSourcesSection(model: model, notice: $notice) { sheet = CuesSheetTarget(page: $0) }
                CuesWatchersSection(model: model) { sheet = CuesSheetTarget(page: $0) }
                CuesMandatesSection(model: model, notice: $notice) { sheet = CuesSheetTarget(page: $0) }
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
}

/// The switches, the line under them, and the door.
struct CuesSwitchesSection: View {
    @ObservedObject var model: SettingsModel
    let router: any CommandPerforming

    var body: some View {
        Section {
            DescriptorRows(
                model: model,
                section: CueFilterPair.section,
                specialised: specialised,
                excluding: [CueFilterPair.providerKey, CueFilterPair.modelKey, CuesPaneKeys.doorPort]
            )

            if let door = model.cueStatus.value?.door {
                CueNote(text: door.sentence)
            }
        } header: {
            Text(ProductStrings[.cuesSubtitle])
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Cues switch carries the line under it: the restart the daemon
    /// asks for, from the pane's own restart transaction, or the status
    /// sentence.
    private func specialised(_ row: ManagementSettingRow) -> AnyView? {
        guard row.key == CuesPaneKeys.enabled else { return nil }

        return AnyView(
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                DescriptorRow(model: model, section: CueFilterPair.section, row: row)
                statusLine
            }
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        let reasons = model.restart.reasons.filter { $0.section == CueFilterPair.section }

        if !reasons.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                CueNote(text: reasons.map(\.sentence).joined(separator: " "))
                Spacer(minLength: Spacing.s)
                Button(ProductStrings[.settingsRestartAction]) { router.perform(.restartDaemon) }
                    .disabled(!router.canPerform(.restartDaemon))
            }
        } else if let status = model.cueStatus.value {
            CueNote(text: status.statusSentence)
        }
    }
}

/// The `cues` section's keys the pane places itself.
enum CuesPaneKeys {
    static let enabled = "cues_enabled"
    static let mandatesEnabled = "cues_mandates_enabled"
    static let doorPort = "cues_door_port"
}

/// The default filter model: Provider, then Model, applied together (§4.6).
/// The door port folds under Advanced here, after the model.
struct CuesFilterSection: View {
    @ObservedObject var model: SettingsModel
    /// Opens the model listing for a provider just chosen.
    let pickModel: (String) -> Void

    var body: some View {
        Section(ProductStrings[.cuesFilterTitle]) {
            DescriptorRows(
                model: model,
                section: CueFilterPair.section,
                specialised: specialised,
                excluding: [CuesPaneKeys.enabled, CuesPaneKeys.mandatesEnabled]
            )
        }
    }

    private func specialised(_ row: ManagementSettingRow) -> AnyView? {
        switch row.key {
        case CueFilterPair.providerKey: return AnyView(providerRow(row))
        case CueFilterPair.modelKey: return modelRow(row)
        default: return nil
        }
    }

    /// The provider pop-up. Choosing one holds it and opens the model
    /// listing at once; choosing None clears both.
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

    /// The model row, for the provider in force: the typeahead where the
    /// daemon offers suggestions, the listing where its list is the
    /// account's own. With no provider there is no model to choose.
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

/// "Waiting for you": Fermix's record of each proposal waiting, drawn only
/// while one waits. Deciding happens on the card in Chat, in one place.
struct CuesWaitingSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let proposals = model.cueProposals.value?.proposals, !proposals.isEmpty {
            Section(ProductStrings[.cuesWaitingTitle]) {
                ForEach(proposals, id: \.proposalId) { proposal in
                    CuesWaitingRow(proposal: proposal) { model.showChat(at: proposal.proposalId) }
                }
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
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Palette.warning.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: ProductStrings[.cuesWaitingRowFormat], proposal.mandate, proposal.tool))
                    .foregroundStyle(Palette.ink.color)
                CueNote(text: waits)
            }

            Spacer(minLength: Spacing.s)

            Button(ProductStrings[.cuesWaitingShowInChat], action: show)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesWaitingShowInChat], proposal.mandate))
        }
    }

    private var waits: String {
        let expiry = ManagementCueTime.date(proposal.expiresAt).map(CueTimes.time) ?? proposal.expiresAt
        return String(format: ProductStrings[.proposalWaitsUntilFormat], expiry)
    }
}

/// A section's title with its one action beside it.
struct CuesSectionHeader: View {
    let title: ProductStringKey
    let action: ProductStringKey?
    let perform: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(ProductStrings[title])
            Spacer(minLength: Spacing.s)
            if let action {
                Button(ProductStrings[action], action: perform)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .textCase(nil)
            }
        }
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

/// The sources (§4.3).
struct CuesSourcesSection: View {
    @ObservedObject var model: SettingsModel
    @Binding var notice: String?
    let open: (CuesSheetPage) -> Void

    var body: some View {
        Section {
            CuesListState(state: model.cueSources) { list in
                if list.sources.isEmpty {
                    CueNote(text: ProductStrings[.cuesSourcesEmpty])
                }
                ForEach(list.sources, id: \.ref) { source in
                    CuesSourceRow(source: source, setEnabled: setEnabled) { open(CuesSheetPage.opening(source)) }
                }
            }
            if let notice {
                CueNote(text: notice, attention: true)
            }
        } header: {
            CuesSectionHeader(title: .cuesSourcesTitle, action: canAdd ? .cuesSourcesAdd : nil) { open(.addSource) }
        }
    }

    private var canAdd: Bool { model.cueSources.value?.canAdd == true }

    private func setEnabled(_ source: ManagementCueSource, _ isOn: Bool) {
        Task { notice = await model.setCueSourceEnabled(isOn, ref: source.ref)?.sentence }
    }
}

/// One source: the integration row's anatomy over the daemon's sentence.
struct CuesSourceRow: View {
    let source: ManagementCueSource
    let setEnabled: (ManagementCueSource, Bool) -> Void
    let open: () -> Void

    var body: some View {
        IntegrationRowLayout(
            title: source.ref,
            subtitle: source.statusSentence,
            accessibilityLabel: ProductStrings.commaPair(source.ref, source.statusSentence),
            isOn: CueSourceProjection.switchShown(source)
                ? Binding(get: { source.enabled }, set: { setEnabled(source, $0) })
                : nil,
            open: open
        ) {
            CuesSourceTile(source: source)
        }
    }
}

/// The 28-point tile a source is drawn with, a symbol by kind until marks
/// exist, labelled with the kind's name.
struct CuesSourceTile: View {
    let source: ManagementCueSource

    var body: some View {
        VendorMarkView(symbol: CueSourceProjection.symbol(for: source.kind), size: IntegrationMetrics.tileSize)
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
            CueNote(text: ProductStrings[.cuesWatchersFooter])
        } header: {
            CuesSectionHeader(title: .cuesWatchersTitle, action: nil) {}
        }
    }
}

/// One watcher: its name and sources, the daemon's sentence, and the day's
/// counts. Never anything a watcher read.
struct CuesWatcherRow: View {
    let watcher: ManagementCueWatcher
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(watcher.name)
                            .fermixType(Typography.style(.callout).weight(.medium))
                            .foregroundStyle(Palette.ink.color)
                        Text(watcher.sources.joined(separator: ", "))
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                    }
                    CueNote(text: watcher.statusSentence, attention: watcher.state.drawsAttention)
                    CueNote(text: CueWatcherProjection.lastDay(watcher.counts))
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
        .accessibilityLabel(ProductStrings.commaPair(watcher.name, watcher.statusSentence))
    }
}

/// What a watcher's rows say, from its published counts.
public enum CueWatcherProjection {
    public static func lastDay(_ counts: ManagementCueWatcher.Counts) -> String {
        String(format: ProductStrings[.cuesWatchersLastDayFormat], counts.passed, counts.dropped, counts.acted)
    }
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
            CuesSectionHeader(title: .cuesMandatesTitle, action: canAdd ? .cuesMandatesAdd : nil) { open(.addMandate) }
        }
    }

    private var canAdd: Bool { model.cueMandates.value?.canAdd == true }
}

/// One mandate: its name, its mode in the app's words and its task, the
/// daemon's sentence, the primary action and the switch.
struct CuesMandateRow: View {
    let mandate: ManagementCueMandate
    let blocked: Bool
    let setEnabled: (Bool) -> Void
    let approve: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mandate.name)
                        .fermixType(Typography.style(.callout).weight(.medium))
                        .foregroundStyle(Palette.ink.color)
                    CueNote(text: CueMandateProjection.summary(mandate))
                    CueNote(text: mandate.statusSentence)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ProductStrings.commaPair(mandate.name, mandate.statusSentence))

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
}

/// What a mandate's rows say and offer, from its published facts.
public enum CueMandateProjection {
    /// The mode in the app's words, or nil for one this build does not know.
    public static func modeTitle(_ mode: ManagementCueMandateMode) -> String? {
        switch mode {
        case .approve: return ProductStrings[.cuesMandateModeApprove]
        case .auto: return ProductStrings[.cuesMandateModeAuto]
        case .unrecognized: return nil
        }
    }

    /// "Ask me first · Release watch".
    public static func summary(_ mandate: ManagementCueMandate) -> String {
        let task = mandate.job.name ?? mandate.job.id
        guard let mode = modeTitle(mandate.mode) else { return task }

        return ProductStrings.middot(mode, task)
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

/// One line of the pane's small print, or the daemon's sentence in the
/// attention style where §4.9 asks for it.
struct CueNote: View {
    let text: String
    var attention = false

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle((attention ? Palette.warning : Palette.secondary).color)
            .fixedSize(horizontal: false, vertical: true)
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
            // Escape goes back a page, or closes the sheet from the page it
            // opened on. A field being edited answers it first.
            .onExitCommand(perform: escape)
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .addSource, .editSource:
            CuesSourceFormPage(page: state.page, form: $sourceForm, model: model, added: added) { turn(back) }
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
    /// forgotten, and the sheet turns to the new source.
    private func added(_ outcome: CueSourceAddOutcome) {
        sourceForm = CueSourceFormState()
        state.added(outcome)
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
